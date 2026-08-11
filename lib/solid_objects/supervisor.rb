# rbs_inline: enabled

module SolidObjects
  class Supervisor
    MAXIMUM_RETENTION_BACKOFF_DOUBLINGS = 16

    # @rbs @components: Array[Worker | EffectExecutor | ReminderScheduler | BroadcastExecutor]
    # @rbs @threads: Array[Thread]
    # @rbs @monitor: Thread?
    # @rbs @started: bool
    # @rbs @cleaned_up_at: Float
    # @rbs @retention: Thread?
    # @rbs @lifecycle: Thread::Mutex

    # @rbs (?worker_count: Integer, ?effect_worker_count: Integer, ?broadcast_worker_count: Integer, ?reminder_scheduler_count: Integer) -> void
    def initialize(
      worker_count: SolidObjects.configuration.worker_count,
      effect_worker_count: SolidObjects.configuration.effect_worker_count,
      broadcast_worker_count: SolidObjects.configuration.broadcast_worker_count,
      reminder_scheduler_count: SolidObjects.configuration.reminder_scheduler_count
    )
      @builders = component_builders(
        worker_count:,
        effect_worker_count:,
        broadcast_worker_count:,
        reminder_scheduler_count:
      )
      @components = @builders.map(&:call)
      @threads = []
      @monitor = nil
      @started = false
      @cleaned_up_at = nil
      @retention = nil
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
      @retention = Thread.new { retention_loop }
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
        stop_monitor
        stop_retention
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

    attr_reader :components, :threads, :builders

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

          # A component built by this supervisor has a builder, which carries
          # whatever the constructor was given. A component put in place by
          # other means has none, so the class is the only thing left to go on.
          builder = builders[index] || -> { component.class.new }
          replacement = builder.call
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

    # Retention gets its own thread rather than sharing the monitor's. A large
    # backlog or a lock wait can make a pass slow, and role replacement must not
    # wait behind housekeeping.
    # @rbs () -> void
    def retention_loop
      failures = 0
      while @started
        begin
          prune_expired_records
          failures = 0
        rescue => error
          failures += 1
          SolidObjects.instrument(
            :"supervisor.retention_failed",
            error_class: error.class.name,
            error_message: error.message
          )
        end
        wait_for_next_retention(failures)
      end
    end

    # Sleeping the whole interval would make shutdown wait out an hour-long
    # nap, so the pause is taken in short steps that notice a stop request.
    # @rbs (Integer) -> void
    def wait_for_next_retention(failures)
      deadline = monotonic_now + retention_pause(failures)
      step = SolidObjects.configuration.supervisor_monitor_interval
      while @started && monotonic_now < deadline
        sleep [ step, deadline - monotonic_now ].min
      end
    end

    # Every actor call writes a durable message row, so retention that is only
    # configured and never run leaves those rows to grow without bound. The
    # supervisor runs it rather than requiring every application to schedule
    # its own job.
    # @rbs () -> void
    def prune_expired_records
      return unless SolidObjects.configuration.retention_interval.positive?

      MessagePruner.new.prune
      ProcessPruner.new.prune
    end

    # A transient lock or connection error must not defer retention for the
    # whole interval, so a failed pass retries at monitor cadence. The pause
    # then doubles per consecutive failure, capped by the interval, so a
    # database that stays down is not polled once a second forever.
    # @rbs (Integer) -> Float
    def retention_pause(failures)
      interval = SolidObjects.configuration.retention_interval
      interval = SolidObjects.configuration.supervisor_monitor_interval unless interval.positive?
      return interval if failures.zero?

      backoff = SolidObjects.configuration.supervisor_monitor_interval *
        (2**[ failures - 1, MAXIMUM_RETENTION_BACKOFF_DOUBLINGS ].min)
      [ backoff, interval ].min
    end

    # @rbs () -> void
    def stop_retention
      retention = @retention
      @retention = nil
      return unless retention

      retention.join(SolidObjects.configuration.shutdown_timeout)
      retention.kill if retention.alive?
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

    # The monitor only performs maintenance, so shutdown must never return while
    # it is still alive: a pass blocked on the database would otherwise outlive
    # the supervisor that owns it.
    # @rbs () -> void
    def stop_monitor
      monitor = @monitor
      @monitor = nil
      return unless monitor

      monitor.join(SolidObjects.configuration.shutdown_timeout)
      monitor.kill if monitor.alive?
      monitor.join(SolidObjects.configuration.supervisor_monitor_interval)
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

    # Each component keeps the builder that made it, so a replacement after a
    # crash is built the same way as the original. Components registered
    # through the configuration run beside the built in ones, under the same
    # supervision, restart, and shutdown timeout.
    # @rbs (worker_count: Integer, effect_worker_count: Integer, broadcast_worker_count: Integer, reminder_scheduler_count: Integer) -> Array[^() -> untyped]
    def component_builders(
      worker_count:,
      effect_worker_count:,
      broadcast_worker_count:,
      reminder_scheduler_count:
    )
      Array.new(worker_count) { -> { Worker.new } } +
        Array.new(effect_worker_count) { -> { EffectExecutor.new } } +
        Array.new(broadcast_worker_count) { -> { BroadcastExecutor.new } } +
        Array.new(reminder_scheduler_count) { -> { ReminderScheduler.new } } +
        SolidObjects.configuration.additional_components
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
