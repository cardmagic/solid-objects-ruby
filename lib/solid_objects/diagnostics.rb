# rbs_inline: enabled

module SolidObjects
  class Diagnostics
    # @rbs @reference: Reference
    # @rbs (Reference) -> void
    def initialize(reference)
      @reference = reference
    end

    # @rbs (?limit: Integer, ?authorization_context: untyped) -> Hash[String, untyped]
    def summary(limit: 100, authorization_context: nil)
      authorize!(:inspect, authorization_context:)
      raise ArgumentError, "diagnostic limit must be an integer between 1 and 100" unless limit.is_a?(Integer) && limit.between?(1, 100)

      instance = Instance.find_by(actor_type: reference.actor_type, actor_id: reference.actor_id)
      now = SolidObjects.database_adapter.database_now
      instance_id = instance&.id
      mailbox = ReadyMessage.where(instance_id:).order(:available_at).limit(limit + 1).pluck(:available_at) +
        ClaimedMessage.where(instance_id:).order(:claimed_at).limit(limit + 1).pluck(:claimed_at)
      outbox = Effect.where(instance_id:, status: %w[pending processing]).order(:available_at).limit(limit + 1).pluck(:available_at) +
        Broadcast.where(instance_id:, status: %w[pending processing]).order(:available_at).limit(limit + 1).pluck(:available_at)
      reminders = Reminder.where(instance_id:, status: %w[scheduled paused]).order(:next_run_at).limit(limit + 1).pluck(:next_run_at)
      retries = ReadyMessage.joins(:message).where(instance_id:).where.not(Message.table_name => { error: nil }).order(:available_at).limit(limit + 1).pluck(:available_at)
      recovery_messages = Message.where(instance_id:, delivery_mode: "internal").where("idempotency_key LIKE ?", "effect:%:recovery").select(:id)
      recovery_failures = DeadLetter.where(instance_id:, message_id: recovery_messages).order(:last_failed_at).limit(limit + 1).pluck(:last_failed_at)
      result = {
        "actorType" => reference.actor_type,
        "actorId" => reference.actor_id,
        "incarnation" => instance_id&.to_s,
        "revision" => instance&.state_revision&.to_s,
        "adapter" => DatabaseAdapter.family(Record.connection).to_s,
        "occurredAt" => now.utc.iso8601(3),
        "limit" => limit,
        "mailbox" => summarize(mailbox, now:, limit:),
        "outbox" => summarize(outbox, now:, limit:),
        "reminders" => summarize(reminders, now:, limit:),
        "retries" => summarize(retries, now:, limit:),
        "recoveryFailures" => summarize(recovery_failures, now:, limit:)
      }
      SolidObjects.instrument(:"mailbox.depth", actor_type: reference.actor_type, actor_id: reference.actor_id, instance_id:, count: result.fetch("mailbox").fetch("sampled"), truncated: result.fetch("mailbox").fetch("truncated"), depth: result.fetch("mailbox").fetch("truncated") ? nil : result.fetch("mailbox").fetch("sampled"))
      Serialization.readonly_copy(result)
    end

    # @rbs (?authorization_context: untyped) { (Hash[String, untyped]) -> untyped } -> Proc
    def observe(authorization_context: nil, &block)
      authorize!(:observe, authorization_context:)
      subscription = ActiveSupport::Notifications.subscribe(/\Asolid_objects\./) do |notification|
        payload = notification.payload
        next unless payload[:actor_type] == reference.actor_type && payload[:actor_id] == reference.actor_id

        begin
          block.call(Telemetry.event(notification.name.delete_prefix("solid_objects.").to_sym, payload))
        rescue
          nil
        end
      end
      -> { ActiveSupport::Notifications.unsubscribe(subscription) }
    end

    private

    attr_reader :reference

    # @rbs (Symbol, ?authorization_context: untyped) -> void
    def authorize!(action, authorization_context: nil)
      allowed = SolidObjects.configuration.authorize_administration.call(
        action:,
        resource: "actor_diagnostics",
        resource_id: [ reference.actor_type, reference.actor_id ].to_json,
        authorization_context:
      )
      raise Unauthorized, "actor diagnostics are not authorized" unless allowed
    end

    # @rbs (Array[Time?], now: Time, limit: Integer) -> Hash[String, untyped]
    def summarize(timestamps, now:, limit:)
      oldest = timestamps.compact.min
      {
        "sampled" => [ timestamps.length, limit ].min,
        "truncated" => timestamps.length > limit,
        "oldestAgeMilliseconds" => oldest ? [ ((now - oldest) * 1000).round, 0 ].max : nil
      }
    end
  end
end
