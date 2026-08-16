# rbs_inline: enabled

require "solid_objects/polling_backoff"

module SolidObjects
  class BroadcastExecutor
    # @rbs @process_registry: ProcessRegistry
    # @rbs @database_adapter: DatabaseAdapter
    # @rbs @stopped: bool
    # @rbs @shutdown_requested: bool
    # @rbs @polling_backoff: PollingBackoff

    # @rbs (?process_registry: ProcessRegistry, ?database_adapter: DatabaseAdapter) -> void
    def initialize(
      process_registry: ProcessRegistry.new,
      database_adapter: SolidObjects.database_adapter
    )
      @process_registry = process_registry
      @database_adapter = database_adapter
      process_registry.register(kind: "broadcast")
      @stopped = false
      @shutdown_requested = false
      @polling_backoff = PollingBackoff.new(
        minimum_interval: SolidObjects.configuration.polling_interval,
        maximum_interval: SolidObjects.configuration.idle_polling_interval,
        on_change: ->(transition) do
          SolidObjects.instrument(
            :"polling.interval_changed",
            role: "broadcasts",
            **transition
          )
        end
      )
    end

    # @rbs () -> bool
    def run_once
      return false if stopped?

      process_registry.heartbeat
      broadcast = claim_next
      return false unless broadcast

      broadcast_adapter.call(broadcast)
      complete(broadcast)
      true
    rescue => error
      fail_broadcast(broadcast, error) if broadcast
      false
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
      ProcessRegistry.warn_if_polling_is_only_cross_process_wake_up

      until shutdown_requested?
        wake_up = SolidObjects.wake_up
        watch = wake_up.respond_to?(:watch) ? wake_up.watch : wake_up
        worked = run_once
        if worked
          polling_backoff.reset(:work)
          next
        end

        notified = watch.wait(timeout: current_polling_interval)
        if notified == false
          polling_backoff.record_idle
        else
          polling_backoff.reset(:wake_up)
        end
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

    # @rbs () -> Float
    def current_polling_interval
      polling_backoff.current_interval
    end

    private

    attr_reader :process_registry, :database_adapter, :polling_backoff

    # @rbs () -> Broadcast?
    def claim_next
      database_adapter.transaction do
        now = database_adapter.database_now
        stale_at = now - SolidObjects.configuration.process_alive_threshold
        relation = Broadcast
          .where(status: "pending", available_at: ..now)
          .or(Broadcast.where(status: "processing", claimed_at: ..stale_at))
          .order(:available_at, :id)
        broadcast = database_adapter.lock_candidates(relation).first
        next unless broadcast

        broadcast.update!(
          status: "processing",
          attempt_count: broadcast.attempt_count + 1,
          claimed_by: process_registry.process_record.id,
          claimed_at: now
        )
        broadcast
      end
    end

    # @rbs () -> Proc | ActionCableBroadcastAdapter
    def broadcast_adapter
      SolidObjects.configuration.broadcast_adapter ||
        ActionCableBroadcastAdapter.new
    end

    # @rbs (Broadcast) -> void
    def complete(broadcast)
      database_adapter.transaction do
        locked_broadcast = Broadcast.lock.find(broadcast.id)
        verify_claim!(locked_broadcast)
        locked_broadcast.update!(
          status: "delivered",
          error: nil,
          delivered_at: database_adapter.database_now,
          claimed_by: nil,
          claimed_at: nil
        )
      end
      SolidObjects.instrument(
        :"broadcast.delivered",
        broadcast_id: broadcast.broadcast_id,
        message_id: broadcast.message_id,
        actor_type: broadcast.instance.actor_type,
        actor_id: broadcast.instance.actor_id,
        observable_name: broadcast.observable_name,
        attempt: broadcast.attempt_count
      )
    end

    # @rbs (Broadcast, Exception) -> void
    def fail_broadcast(broadcast, error)
      database_adapter.transaction do
        locked_broadcast = Broadcast.lock.find(broadcast.id)
        verify_claim!(locked_broadcast)
        dead = locked_broadcast.attempt_count >= SolidObjects.configuration.max_attempts
        locked_broadcast.update!(
          status: dead ? "dead" : "pending",
          available_at: database_adapter.database_now +
            SolidObjects.configuration.retry_delay.call(locked_broadcast.attempt_count),
          error: {
            "class" => error.class.name,
            "message" => error.message.to_s.byteslice(0, 8_192),
            "backtrace" => Array(error.backtrace).first(50)
          },
          claimed_by: nil,
          claimed_at: nil
        )
      end
    rescue ActiveRecord::RecordNotFound, LostActivation
      nil
    end

    # @rbs (Broadcast) -> void
    def verify_claim!(broadcast)
      return if broadcast.status == "processing" &&
        broadcast.claimed_by == process_registry.process_record.id

      raise LostActivation, "broadcast claim changed"
    end
  end
end
