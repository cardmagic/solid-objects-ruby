# rbs_inline: enabled

require "socket"

module SolidObjects
  class ProcessRegistry
    class << self
      # @rbs (?now: Time) -> Integer
      def cleanup_dead(now: SolidObjects.database_adapter.database_now)
        stale_at = now - SolidObjects.configuration.process_alive_threshold
        dead_processes = Process
          .where.not(shutdown_state: "stopped")
          .where(last_heartbeat_at: ..stale_at)
          .to_a

        dead_processes.each { |process_record| cleanup_process(process_record, now) }
        dead_processes.length
      end

      # @rbs (Process, ?now: Time) -> bool
      def deregister(process_record, now: SolidObjects.database_adapter.database_now)
        SolidObjects.database_adapter.transaction do
          Instance.where(activation_owner_id: process_record.id).update_all(
            activation_owner_id: nil,
            activation_token: nil,
            activation_expires_at: nil
          )
          ClaimedMessage.where(process_id: process_record.id).update_all(
            process_id: nil,
            activation_token: nil
          )
          Effect.where(claimed_by: process_record.id).update_all(
            status: "pending",
            claimed_by: nil,
            claimed_at: nil,
            available_at: now
          )
          Reminder.where(claimed_by: process_record.id).update_all(
            claimed_by: nil,
            claimed_at: nil
          )
          Broadcast.where(claimed_by: process_record.id).update_all(
            status: "pending",
            claimed_by: nil,
            claimed_at: nil,
            available_at: now
          )
          process_record.update!(
            shutdown_state: "stopped",
            stopped_at: now
          )
        end
        true
      end

      private

      # @rbs (Process, Time) -> void
      def cleanup_process(process_record, now)
        deregister(process_record, now:)
        SolidObjects.instrument(
          :"process.pruned",
          process_id: process_record.id,
          process_kind: process_record.kind,
          last_heartbeat_at: process_record.last_heartbeat_at
        )
      end
    end

    # @rbs @process_record: Process?
    # @rbs @last_heartbeat_at: Float?

    attr_reader :process_record

    # @rbs () -> void
    def initialize
      @process_record = nil
      @last_heartbeat_at = nil
    end

    # @rbs (?kind: String, ?metadata: Hash[String | Symbol, untyped]) -> Process
    def register(kind: "worker", metadata: {})
      process_record = SolidObjects.database_adapter.with_lock_retry do
        now = SolidObjects.database_adapter.database_now
        Process.create!(
          id: SecureRandom.uuid,
          kind:,
          hostname: Socket.gethostname,
          pid: ::Process.pid,
          started_at: now,
          last_heartbeat_at: now,
          metadata: Serialization.dump(default_metadata.merge(metadata))
        )
      end
      @process_record = process_record
      @last_heartbeat_at = monotonic_now
      process_record
    end

    # @rbs () -> bool
    def heartbeat
      return false unless process_record
      return false if heartbeat_recent?

      updated = SolidObjects.database_adapter.with_lock_retry do
        process_record.update(
          last_heartbeat_at: SolidObjects.database_adapter.database_now
        )
      end
      @last_heartbeat_at = monotonic_now if updated
      updated
    end

    # @rbs () -> bool
    def start_draining
      return false unless process_record

      process_record.update(
        shutdown_state: "draining",
        shutdown_requested_at: SolidObjects.database_adapter.database_now
      )
    end

    # @rbs () -> bool
    def stop
      return false unless process_record

      self.class.deregister(process_record)
    end

    private

    # @rbs () -> Hash[Symbol, String]
    def default_metadata
      {
        solid_objects_version: SolidObjects::VERSION,
        ruby_version: RUBY_VERSION
      }
    end

    # @rbs () -> bool
    def heartbeat_recent?
      return false unless @last_heartbeat_at

      monotonic_now - @last_heartbeat_at <
        SolidObjects.configuration.process_heartbeat_interval
    end

    # @rbs () -> Float
    def monotonic_now
      ::Process.clock_gettime(::Process::CLOCK_MONOTONIC)
    end
  end
end
