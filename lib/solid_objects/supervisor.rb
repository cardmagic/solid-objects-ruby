# rbs_inline: enabled

module SolidObjects
  class Supervisor
    # @rbs @components: Array[Worker | EffectExecutor | ReminderScheduler | BroadcastExecutor]
    # @rbs @threads: Array[Thread]
    # @rbs @monitor: Thread?
    # @rbs @started: bool
    # @rbs @cleaned_up_at: Float
    # @rbs @lifecycle: Thread::Mutex

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
      @monitor = nil
      @started = false
      @cleaned_up_at = nil
      @lifecycle = Thread::Mutex.new
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
      @threads = components.map { |component| supervise(component) }
      @monitor = Thread.new { monitor_loop }
      SolidObjects.instrument(:"supervisor.started", component_count: components.length)
    end

    # @rbs () -> void
    def stop
      return unless @started

      begin
        # Flipping the flag under the same lock replacement takes means a
        # replacement either completes before shutdown reads the component
        # list, or never starts.
        @lifecycle.synchronize { @started = false }
        @monitor&.join(SolidObjects.configuration.supervisor_monitor_interval * 2)
        components.each(&:request_shutdown)
        join_until_timeout
        components.reject(&:stopped?).each(&:stop)
      ensure
        # Connections held outside the pool must be released even when a
        # component fails to stop, or they accumulate across restarts.
        release_wake_up
        @monitor = nil
        SolidObjects.instrument(:"supervisor.stopped", component_count: components.length)
      end
    end

    private

    attr_reader :components, :threads

    # A role that raises leaves its thread dead. Without replacement the
    # process keeps running while quietly doing less work, so the supervisor
    # watches its threads and restarts any that stopped before shutdown.
    # A failing pass must not stop supervision, and must not retry without
    # pacing either: a persistently failing database would otherwise spin.
    # @rbs () -> void
    def monitor_loop
      while @started
        begin
          replace_dead_roles
          cleanup_dead_processes
        rescue => error
          SolidObjects.instrument(
            :"supervisor.monitor_failed",
            error_class: error.class.name,
            error_message: error.message
          )
        end
        sleep SolidObjects.configuration.supervisor_monitor_interval
      end
    end

    # A role that raises runs its own shutdown cleanup on the way out, so a
    # crashed component reports itself stopped exactly like one that was asked
    # to stop. While the supervisor is still running, a dead thread can only
    # mean a crash, so replacement keys on the supervisor rather than on the
    # component. The crashed instance has already released its process record,
    # so a fresh one takes its place.
    # @rbs () -> void
    def replace_dead_roles
      components.each_with_index do |component, index|
        thread = threads[index]
        next if thread&.alive?

        replaced = @lifecycle.synchronize do
          next false unless @started

          replacement = component.class.new
          components[index] = replacement
          threads[index] = supervise(replacement)
          replacement
        end
        break unless replaced

        SolidObjects.instrument(
          :"supervisor.role_replaced",
          role: replaced.class.name,
          error_class: thread_error(thread)
        )
      end
    end

    # @rbs (Thread?) -> String?
    def thread_error(thread)
      thread&.join
      nil
    rescue => error
      error.class.name
    end

    # @rbs () -> void
    def cleanup_dead_processes
      interval = SolidObjects.configuration.dead_process_cleanup_interval
      return unless interval.positive?
      return if @cleaned_up_at && monotonic_now - @cleaned_up_at < interval

      @cleaned_up_at = monotonic_now
      ProcessRegistry.cleanup_dead
    end

    # @rbs (untyped) -> Thread
    def supervise(component)
      Thread.new { component.run }
    end

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
