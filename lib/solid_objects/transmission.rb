# rbs_inline: enabled

module SolidObjects
  module Transmission
    REQUIRED_FIELDS = %w[effectId actorType actorId operation].freeze
    IDEMPOTENCY_PREFIX = "transmit:"
    EFFECT_NAME = "solid-objects.transmit"
    UNDELIVERED_STATUSES = %w[pending processing].freeze

    class << self
      # @rbs (untyped envelope, ?resolve_actor_type: ^(String) -> (String | Symbol), ?mailbox: Mailbox) -> MessageReference
      def receive(envelope, resolve_actor_type: :itself.to_proc, mailbox: Mailbox.new)
        validate!(envelope)

        actor_type = resolve_actor_type.call(envelope["actorType"]).to_s
        actor_class = SolidObjects.registry.fetch(actor_type)
        operation = envelope["operation"].to_sym
        unless actor_class.definition.messages.key?(operation)
          raise UnknownMessage, "unknown operation #{envelope["operation"].inspect}"
        end

        mailbox.enqueue(
          reference: Reference.new(actor_type:, actor_id: envelope["actorId"]),
          operation:,
          arguments: envelope.fetch("arguments", {}),
          delivery_mode: "internal",
          idempotency_key: "#{IDEMPOTENCY_PREFIX}#{envelope["effectId"]}"
        )
      end

      # @rbs (effect_name: String, arguments: Hash[String, untyped], context: EffectContext, deliver: Proc) -> nil
      def deliver_through(effect_name:, arguments:, context:, deliver:)
        staged_envelope(
          arguments,
          effect_id: context.id,
          actor_type: context.actor_type,
          actor_id: context.actor_id
        )
        undelivered_envelopes_through(effect_name:, context:).each do |envelope|
          deliver.call(envelope)
        end
        nil
      end

      private

      # @rbs (Hash[String, untyped], effect_id: String, actor_type: String, actor_id: String) -> Hash[String, untyped]
      def staged_envelope(arguments, effect_id:, actor_type:, actor_id:)
        operation = arguments["operation"]
        unless operation.is_a?(String) && !operation.empty?
          raise InvalidTransmission, "transmit effect arguments require a non-empty operation"
        end

        target_arguments = arguments["arguments"]
        target_arguments = {} if target_arguments.nil?
        unless target_arguments.is_a?(Hash)
          raise InvalidTransmission, %(transmit effect arguments must hold a JSON object in "arguments")
        end

        target_type = arguments["actorType"].nil? ? actor_type : arguments["actorType"]
        target_id = arguments["actorId"].nil? ? actor_id : arguments["actorId"]
        { "actorType" => target_type, "actorId" => target_id }.each do |field, value|
          next if value.is_a?(String) && !value.empty?

          raise InvalidTransmission, "transmit effect #{field} must be a non-empty string"
        end

        {
          "effectId" => effect_id,
          "actorType" => target_type,
          "actorId" => target_id,
          "operation" => operation,
          "arguments" => target_arguments
        }
      end

      # @rbs (effect_name: String, context: EffectContext) -> Array[Hash[String, untyped]]
      def undelivered_envelopes_through(effect_name:, context:)
        source_sequence = Message.find(context.source_message_id).sequence
        effects = Effect
          .joins(:message)
          .where(name: effect_name, status: UNDELIVERED_STATUSES)
          .merge(
            Message.where(
              actor_type: context.actor_type,
              actor_id: context.actor_id,
              sequence: ..source_sequence
            )
          )
          .order(Message.arel_table[:sequence].asc, :id)

        effects.filter_map do |effect|
          staged_envelope(
            effect.arguments,
            effect_id: effect.effect_id,
            actor_type: context.actor_type,
            actor_id: context.actor_id
          )
        rescue InvalidTransmission
          nil
        end
      end

      # @rbs (untyped) -> void
      def validate!(envelope)
        raise InvalidTransmission, "envelope must be a JSON object" unless envelope.is_a?(Hash)

        REQUIRED_FIELDS.each do |field|
          value = envelope[field]
          next if value.is_a?(String) && !value.empty?

          raise InvalidTransmission, "envelope field #{field.inspect} must be a non-empty string"
        end

        arguments = envelope.fetch("arguments", {})
        return if arguments.is_a?(Hash)

        raise InvalidTransmission, %(envelope field "arguments" must be a JSON object)
      end
    end
  end
end
