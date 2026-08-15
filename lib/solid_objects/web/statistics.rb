# rbs_inline: enabled

module SolidObjects
  class Web
    # The counts behind the dashboard and behind `GET /stats`. Both read the
    # same object, so the polled JSON and the rendered page can never disagree
    # about what a number means.
    class Statistics
      EFFECT_STATUSES = %w[pending processing completed dead].freeze
      BROADCAST_STATUSES = %w[pending processing delivered dead].freeze
      REMINDER_STATUSES = %w[scheduled paused completed].freeze
      PROCESS_STATES = %w[running draining stopped].freeze

      # @rbs @now: Time

      attr_reader :now

      # @rbs (?now: Time) -> void
      def initialize(now: SolidObjects.database_adapter.database_now)
        @now = now
      end

      # @rbs () -> Hash[Symbol, untyped]
      def to_h
        {
          instances:,
          mailbox:,
          effects: grouped(Effect, :status, EFFECT_STATUSES),
          broadcasts: grouped(Broadcast, :status, BROADCAST_STATUSES),
          reminders:,
          dead_letters: { total: DeadLetter.count },
          processes: grouped(Process, :shutdown_state, PROCESS_STATES),
          server_time: now.utc.iso8601
        }
      end

      # @rbs () -> Hash[Symbol, Integer]
      def instances
        {
          total: Instance.count,
          paused: Instance.where.not(paused_at: nil).count,
          activated: Instance.where(activation_expires_at: now..).count
        }
      end

      # The oldest ready message that is already due is the queue latency of
      # this runtime: how far behind the workers are, in seconds.
      # @rbs () -> Hash[Symbol, untyped]
      def mailbox
        due = ReadyMessage.where(available_at: ..now)
        oldest = due.minimum(:available_at)
        {
          ready: ReadyMessage.count,
          due: due.count,
          claimed: ClaimedMessage.count,
          latency: oldest ? (now - oldest).round(3) : 0.0
        }
      end

      # @rbs () -> Hash[Symbol, Integer]
      def reminders
        grouped(Reminder, :status, REMINDER_STATUSES).merge(
          due: Reminder.where(status: "scheduled", next_run_at: ..now).count
        )
      end

      private

      # A status the schema allows but the table does not currently hold still
      # reports zero, so a row of counts keeps the same shape between polls.
      # @rbs (untyped, Symbol, Array[String]) -> Hash[Symbol, Integer]
      def grouped(model, column, statuses)
        counts = model.group(column).count
        statuses.to_h { |status| [ status.to_sym, counts.fetch(status, 0) ] }
      end
    end
  end
end
