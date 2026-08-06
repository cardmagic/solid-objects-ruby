# rbs_inline: enabled

module SolidObjects
  class ReminderScheduler
    # @rbs @process_registry: ProcessRegistry
    # @rbs @database_adapter: DatabaseAdapter
    # @rbs @stopped: bool
    # @rbs @shutdown_requested: bool

    # @rbs (?process_registry: ProcessRegistry, ?database_adapter: DatabaseAdapter) -> void
    def initialize(
      process_registry: ProcessRegistry.new,
      database_adapter: SolidObjects.database_adapter
    )
      @process_registry = process_registry
      @database_adapter = database_adapter
      process_registry.register(kind: "reminder")
      @stopped = false
      @shutdown_requested = false
    end

    # @rbs () -> bool
    def run_once
      return false if stopped?

      process_registry.heartbeat
      reminder = claim_next
      return false unless reminder

      enqueue(reminder).present?
    rescue
      release(reminder) if reminder
      raise
    end

    # @rbs () -> void
    def stop
      return if stopped?

      @stopped = true
      process_registry.start_draining
      process_registry.stop
    end

    # @rbs () -> void
    def run
      until shutdown_requested?
        worked = run_once
        next if worked

        SolidObjects.wake_up.wait(timeout: SolidObjects.configuration.polling_interval)
      end
    ensure
      stop
    end

    # @rbs () -> void
    def request_shutdown
      @shutdown_requested = true
      SolidObjects.wake_up.signal
    end

    # @rbs () -> bool
    def stopped?
      @stopped
    end

    # @rbs () -> bool
    def shutdown_requested?
      @shutdown_requested
    end

    private

    attr_reader :process_registry, :database_adapter

    # @rbs () -> Reminder?
    def claim_next
      database_adapter.transaction do
        now = database_adapter.database_now
        stale_at = now - SolidObjects.configuration.process_alive_threshold
        relation = Reminder
          .where(status: "scheduled", next_run_at: ..now)
          .where("claimed_by IS NULL OR claimed_at <= ?", stale_at)
          .order(:next_run_at, :id)
        reminder = database_adapter.lock_candidates(relation).first
        next unless reminder

        reminder.update!(
          claimed_by: process_registry.process_record.id,
          claimed_at: now
        )
        reminder
      end
    end

    # @rbs (Reminder) -> MessageReference?
    def enqueue(reminder)
      actor_class = SolidObjects.registry.fetch(reminder.actor_type)
      unless actor_class.definition.messages.key?(reminder.message_name.to_sym)
        raise UnknownMessage, "unknown reminder message #{reminder.message_name.inspect}"
      end

      mailbox = Mailbox.new(database_adapter:)
      message = database_adapter.transaction do
        instance = Instance.lock.find_by(id: reminder.instance_id)
        next unless instance

        locked_reminder = Reminder.lock.find_by(id: reminder.id)
        next unless locked_reminder
        verify_claim!(locked_reminder)
        now = database_adapter.database_now
        message = mailbox.enqueue_in_transaction(
          Reference.new(actor_type: instance.actor_type, actor_id: instance.actor_id),
          locked_reminder.message_name,
          locked_reminder.arguments,
          kind: "internal",
          idempotency_key: "reminder:#{locked_reminder.id}:#{locked_reminder.occurrence}",
          actor_class:
        )
        recurring = locked_reminder.interval_seconds.present?
        locked_reminder.update!(
          status: recurring ? "scheduled" : "completed",
          occurrence: locked_reminder.occurrence + 1,
          next_run_at: recurring ? next_run_at(locked_reminder, now) : locked_reminder.next_run_at,
          claimed_by: nil,
          claimed_at: nil
        )
        message
      end
      return unless message

      mailbox.announce(message)
      SolidObjects.instrument(
        :"reminder.enqueued",
        reminder_id: reminder.id,
        actor_type: reminder.actor_type,
        actor_id: reminder.actor_id,
        occurrence: reminder.occurrence
      )
      MessageReference.from_message(message)
    end

    # @rbs (Reminder) -> void
    def release(reminder)
      Reminder
        .where(id: reminder.id, claimed_by: process_registry.process_record.id)
        .update_all(claimed_by: nil, claimed_at: nil)
    end

    # @rbs (Reminder) -> void
    def verify_claim!(reminder)
      return if reminder.claimed_by == process_registry.process_record.id

      raise LostActivation, "reminder claim changed"
    end

    # @rbs (Reminder, Time) -> Time
    def next_run_at(reminder, now)
      interval = reminder.interval_seconds.to_f
      next_run = reminder.next_run_at + interval
      return next_run if reminder.missed_policy == "all" || next_run > now

      missed_intervals = ((now - next_run) / interval).floor + 1
      next_run + (missed_intervals * interval)
    end
  end
end
