# rbs_inline: enabled

module SolidObjects
  module Transmission
    REQUIRED_FIELDS = %w[effectId actorType actorId operation].freeze
    IDEMPOTENCY_PREFIX = "transmit:"

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

      private

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
