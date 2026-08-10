# rbs_inline: enabled

module SolidObjects
  class Supervisor
    # @rbs @components: Array[Worker | EffectExecutor | ReminderScheduler | BroadcastExecutor]
    # @rbs @threads: Array[Thread]
    # @rbs @started: bool

    # @rbs (?worker_count: Integer, ?effect_worker_count: Integer, ?broadcast_worker_count: Integer, ?reminder_scheduler_count: Integer) -> void
    def initialize(
      worker_count: SolidObjects.configuration.worker_count,
      effect_worker_count: SolidObjects.configuration.effect_worker_count,
      broadcast_worker_count: SolidObjects.configuration.broadcast_worker_count,
      reminder_scheduler_count: SolidObjects.configuration.reminder_scheduler_count
    )
      @components = build_components(
        worker_count:,
        effect_worker_count:,
        broadcast_worker_count:,
        reminder_scheduler_count:
      )
      @threads = []
      @started = false
    end

    # @rbs () -> void
    def run
      start
      threads.each(&:join)
    ensure
      stop
    end

    # @rbs () -> void
    def start
      return if @started

      @started = true
      @threads = components.map { |component| Thread.new { component.run } }
      SolidObjects.instrument(:"supervisor.started", component_count: components.length)
    end

    # @rbs () -> void
    def stop
      return unless @started

      begin
        components.each(&:request_shutdown)
        join_until_timeout
        components.reject(&:stopped?).each(&:stop)
      ensure
        # Connections held outside the pool must be released even when a
        # component fails to stop, or they accumulate across restarts.
        release_wake_up
        @started = false
        SolidObjects.instrument(:"supervisor.stopped", component_count: components.length)
      end
    end

    private

    attr_reader :components, :threads

    # A wake-up adapter may hold connections outside the pool, which would
    # otherwise accumulate across restarts in one process.
    # @rbs () -> void
    def release_wake_up
      wake_up = SolidObjects.wake_up
      return unless wake_up.respond_to?(:stop)

      wake_up.stop
    rescue
      nil
    end

    # @rbs (worker_count: Integer, effect_worker_count: Integer, broadcast_worker_count: Integer, reminder_scheduler_count: Integer) -> Array[Worker | EffectExecutor | ReminderScheduler | BroadcastExecutor]
    def build_components(
      worker_count:,
      effect_worker_count:,
      broadcast_worker_count:,
      reminder_scheduler_count:
    )
      Array.new(worker_count) { Worker.new } +
        Array.new(effect_worker_count) { EffectExecutor.new } +
        Array.new(broadcast_worker_count) { BroadcastExecutor.new } +
        Array.new(reminder_scheduler_count) { ReminderScheduler.new }
    end

    # @rbs () -> void
    def join_until_timeout
      deadline = monotonic_now + SolidObjects.configuration.shutdown_timeout
      threads.each do |thread|
        remaining = deadline - monotonic_now
        break unless remaining.positive?

        thread.join(remaining)
      end
    end

    # @rbs () -> Float
    def monotonic_now
      ::Process.clock_gettime(::Process::CLOCK_MONOTONIC)
    end
  end
end
