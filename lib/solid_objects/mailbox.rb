# rbs_inline: enabled

module SolidObjects
  class Mailbox
    INSTANCE_RETRY_LIMIT = 3

    # @rbs @database_adapter: DatabaseAdapter

    # @rbs (?database_adapter: DatabaseAdapter) -> void
    def initialize(database_adapter: SolidObjects.database_adapter)
      @database_adapter = database_adapter
    end

    # @rbs (reference: Reference, operation: Symbol | String, arguments: Hash[Symbol | String, untyped], delivery_mode: String, ?available_at: Time?, idempotency_key: String?) -> MessageReference
    def enqueue(reference:, operation:, arguments:, delivery_mode:, available_at: nil, idempotency_key: nil)
      actor_class = SolidObjects.registry.fetch(reference.actor_type)
      normalized_arguments = Serialization.dump(
        arguments,
        max_bytes: SolidObjects.configuration.max_payload_bytes
      )
      message = with_instance_retry do
        database_adapter.transaction do
          enqueue_in_transaction(
            reference:,
            operation:,
            arguments: normalized_arguments,
            delivery_mode:,
            available_at:,
            idempotency_key:,
            actor_class:
          )
        end
      end

      announce(message)
      MessageReference.from_message(message)
    end

    # @rbs (reference: Reference, operation: Symbol | String, arguments: Hash[Symbol | String, untyped], delivery_mode: String, ?available_at: Time?, idempotency_key: String?, ?actor_class: Class?) -> Message
    def enqueue_in_transaction(
      reference:,
      operation:,
      arguments:,
      delivery_mode:,
      available_at: nil,
      idempotency_key: nil,
      actor_class: nil
    )
      actor_class ||= SolidObjects.registry.fetch(reference.actor_type)
      normalized_arguments = Serialization.dump(
        arguments,
        max_bytes: SolidObjects.configuration.max_payload_bytes
      )
      instance = find_or_create_instance(reference, actor_class)
      instance.lock!

      existing = find_idempotent_message(instance, idempotency_key)
      if existing
        return validate_idempotent_message!(
          existing_message: existing,
          operation:,
          delivery_mode:,
          arguments: normalized_arguments
        )
      end

      enforce_mailbox_limit!(instance)
      create_message(
        instance:,
        reference:,
        operation:,
        arguments: normalized_arguments,
        delivery_mode:,
        available_at:,
        idempotency_key:
      )
    end

    # @rbs (Message) -> void
    def announce(message)
      SolidObjects.instrument(
        :"message.enqueued",
        message_id: message.id,
        actor_type: message.actor_type,
        actor_id: message.actor_id,
        sequence: message.sequence,
        request_id: message.request_id
      )
      SolidObjects.wake_up.signal
    end

    private

    attr_reader :database_adapter

    # @rbs () { () -> Message } -> Message
    def with_instance_retry
      attempts = 0
      begin
        yield
      rescue ActiveRecord::RecordNotFound
        attempts += 1
        retry if attempts < INSTANCE_RETRY_LIMIT

        raise ActorDestroyed, "actor changed repeatedly while enqueueing"
      end
    end

    # @rbs (Reference, Class) -> Instance
    def find_or_create_instance(reference, actor_class)
      Instance.create_or_find_by!(
        actor_type: reference.actor_type,
        actor_id: reference.actor_id
      ) do |instance|
        instance.state = {}
        instance.state_version = actor_class.state_version
      end
    end

    # @rbs (Instance, String?) -> Message?
    def find_idempotent_message(instance, idempotency_key)
      return unless idempotency_key

      Message.find_by(instance_id: instance.id, idempotency_key:)
    end

    # @rbs (existing_message: Message, operation: Symbol | String, delivery_mode: String, arguments: untyped) -> Message
    def validate_idempotent_message!(existing_message:, operation:, delivery_mode:, arguments:)
      matches = existing_message.operation == operation.to_s &&
        existing_message.delivery_mode == delivery_mode &&
        existing_message.arguments == arguments
      return existing_message if matches

      raise IdempotencyConflict, "idempotency key belongs to a different actor invocation"
    end

    # @rbs (Instance) -> void
    def enforce_mailbox_limit!(instance)
      live_count = ReadyMessage.where(instance_id: instance.id).count +
        ClaimedMessage.where(instance_id: instance.id).count
      return if live_count < SolidObjects.configuration.max_mailbox_length

      raise MailboxFull, "mailbox is full for #{instance.actor_type}(#{instance.actor_id.inspect})"
    end

    # @rbs (instance: Instance, reference: Reference, operation: Symbol | String, arguments: untyped, delivery_mode: String, available_at: Time?, idempotency_key: String?) -> Message
    def create_message(instance:, reference:, operation:, arguments:, delivery_mode:, available_at:, idempotency_key:)
      sequence = instance.next_message_sequence
      now = database_adapter.database_now
      scheduled_at = normalize_availability(available_at, now)
      instance.update!(next_message_sequence: sequence + 1)
      message = Message.create!(
        instance:,
        actor_type: reference.actor_type,
        actor_id: reference.actor_id,
        operation: operation.to_s,
        delivery_mode:,
        arguments:,
        sequence:,
        max_attempts: SolidObjects.configuration.max_attempts,
        request_id: SecureRandom.uuid,
        idempotency_key:,
        enqueued_at: now,
        available_at: scheduled_at
      )
      ReadyMessage.create!(
        message:,
        instance:,
        sequence:,
        available_at: scheduled_at
      )
      message
    end

    # @rbs (Time?, Time) -> Time
    def normalize_availability(available_at, now)
      return now unless available_at

      time = available_at.respond_to?(:to_time) ? available_at.to_time : available_at
      raise ArgumentError, "available_at must be a time" unless time.is_a?(Time)

      [ time, now ].max
    end
  end
end
