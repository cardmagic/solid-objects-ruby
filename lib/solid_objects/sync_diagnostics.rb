# rbs_inline: enabled

module SolidObjects
  class SyncDiagnostics
    # @rbs (Message, timeout: Numeric) -> SyncTimeout
    def call(message, timeout:)
      message = Message.uncached { Message.find(message.id) }
      instance = Instance.uncached { Instance.find(message.instance_id) }
      blocker = earlier_blocker(message)
      status = message_status(message)
      waiting_on = waiting_reason(message, instance, blocker)
      activation = activation_details(instance)
      build_error(
        message,
        timeout:,
        status:,
        waiting_on:,
        activation:,
        blocker: blocker_details(blocker)
      )
    end

    # @rbs (Message, timeout: Numeric) -> SyncTimeout
    def database_contention(message, timeout:)
      build_error(
        message,
        timeout:,
        status: "unknown",
        waiting_on: "database_contention",
        activation: {},
        blocker: nil
      )
    end

    # @rbs (MessageReference, timeout: Numeric) -> SyncTimeout
    def database_contention_for(message_reference, timeout:)
      error = SyncTimeout.new(
        timeout:,
        actor_type: message_reference.actor_type,
        actor_id: message_reference.actor_id,
        message_name: "unknown",
        message_id: message_reference.id,
        request_id: message_reference.request_id,
        sequence: message_reference.sequence,
        status: "unknown",
        waiting_on: "database_contention",
        activation: {},
        blocker: nil
      )
      SolidObjects.instrument(
        :"sync.timeout",
        message_id: message_reference.id,
        request_id: message_reference.request_id,
        actor_type: message_reference.actor_type,
        actor_id: message_reference.actor_id,
        sequence: message_reference.sequence,
        status: "unknown",
        waiting_on: "database_contention",
        activation_owner_id: nil,
        activation_generation: nil
      )
      error
    end

    private

    # @rbs (Message, timeout: Numeric, status: String, waiting_on: String, activation: Hash[String, untyped], blocker: Hash[String, untyped]?) -> SyncTimeout
    def build_error(message, timeout:, status:, waiting_on:, activation:, blocker:)
      error = SyncTimeout.new(
        timeout:,
        actor_type: message.actor_type,
        actor_id: message.actor_id,
        message_name: message.message_name,
        message_id: message.id,
        request_id: message.request_id,
        sequence: message.sequence,
        status:,
        waiting_on:,
        activation:,
        blocker:
      )
      SolidObjects.instrument(
        :"sync.timeout",
        message_id: message.id,
        request_id: message.request_id,
        actor_type: message.actor_type,
        actor_id: message.actor_id,
        sequence: message.sequence,
        status:,
        waiting_on:,
        activation_owner_id: activation["owner_id"],
        activation_generation: activation["generation"]
      )
      error
    end

    # @rbs (Message) -> String
    def message_status(message)
      return "rejected" if message.rejected?
      return "completed" if message.completed?
      return "dead" if message.dead?
      return "claimed" if ClaimedMessage.where(message_id: message.id).exists?
      return "ready" if ReadyMessage.where(message_id: message.id).exists?

      "unknown"
    end

    # @rbs (Message, Instance, Message?) -> String
    def waiting_reason(message, instance, blocker)
      return "actor_paused" if instance.paused_at
      return "activation_held" if live_activation?(instance)
      return "earlier_message" if blocker
      return "message_claimed" if ClaimedMessage.where(message_id: message.id).exists?

      ready_message = ReadyMessage.find_by(message_id: message.id)
      return "not_yet_available" if future?(ready_message)
      return "ready_unclaimed" if ready_message

      "unknown"
    end

    # @rbs (ReadyMessage?) -> bool
    def future?(ready_message)
      ready_message&.available_at.present? &&
        ready_message.available_at > SolidObjects.database_adapter.database_now
    end

    # @rbs (Instance) -> bool
    def live_activation?(instance)
      instance.activation_owner_id.present? &&
        instance.activation_expires_at.present? &&
        instance.activation_expires_at > SolidObjects.database_adapter.database_now
    end

    # @rbs (Message) -> Message?
    def earlier_blocker(message)
      ready = Message
        .joins(:ready_message)
        .where(instance_id: message.instance_id, sequence: ...message.sequence)
        .order(:sequence)
        .first
      claimed = Message
        .joins(:claimed_message)
        .where(instance_id: message.instance_id, sequence: ...message.sequence)
        .order(:sequence)
        .first

      [ ready, claimed ].compact.min_by(&:sequence)
    end

    # @rbs (Instance) -> Hash[String, untyped]
    def activation_details(instance)
      process_record = Process.find_by(id: instance.activation_owner_id)
      {
        "owner_id" => instance.activation_owner_id,
        "generation" => instance.activation_generation,
        "expires_at" => instance.activation_expires_at&.iso8601(6),
        "process" => process_details(process_record)
      }
    end

    # @rbs (Process?) -> Hash[String, untyped]?
    def process_details(process_record)
      return unless process_record

      {
        "kind" => process_record.kind,
        "hostname" => process_record.hostname,
        "pid" => process_record.pid,
        "last_heartbeat_at" => process_record.last_heartbeat_at&.iso8601(6),
        "shutdown_state" => process_record.shutdown_state
      }
    end

    # @rbs (Message?) -> Hash[String, untyped]?
    def blocker_details(blocker)
      return unless blocker

      {
        "message_id" => blocker.id,
        "sequence" => blocker.sequence,
        "message_name" => blocker.message_name,
        "status" => message_status(blocker)
      }
    end
  end
end
