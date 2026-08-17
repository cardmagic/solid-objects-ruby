# frozen_string_literal: true

require "database_test_helper"
require "solid_objects/polling_backoff"
require "timeout"

class PollingTest < ActiveSupport::TestCase
  class WakeLatencyActor < SolidObjects::Actor
    actor_type "polling-wake-latency"

    attribute :count, default: 0

    def increment
      self.count += 1
    end
  end

  class RecordingLogger
    attr_reader :warnings

    def initialize
      @warnings = []
    end

    def warn(entry)
      warnings << entry
    end
  end

  class ImmediateTimeoutWakeUp
    attr_reader :intervals
    attr_accessor :on_wait

    def initialize
      @intervals = []
      @on_wait = method(:itself)
    end

    def wait(timeout:)
      intervals << timeout
      on_wait.call
      false
    end

    def signal
    end
  end

  class LegacyWakeUp
    attr_reader :intervals
    attr_accessor :on_wait

    def initialize
      @intervals = []
      @on_wait = method(:itself)
    end

    def wait(timeout:)
      intervals << timeout
      on_wait.call
      nil
    end

    def signal
    end
  end

  class SnapshotWakeUp
    class Watch
      def initialize(adapter)
        @adapter = adapter
      end

      def wait(timeout:)
        @adapter.watched_wait(timeout:)
      end
    end

    attr_reader :events
    attr_accessor :on_wait

    def initialize
      @events = []
      @on_wait = method(:itself)
    end

    def watch
      events << :watch
      Watch.new(self)
    end

    def wait(timeout:)
      raise "runtime role waited without a wake-up snapshot"
    end

    def watched_wait(timeout:)
      events << :wait
      on_wait.call
      false
    end

    def signal
    end
  end

  test "backs an idle worker off to the configured ceiling and reports each transition" do
    wake_up = ImmediateTimeoutWakeUp.new
    SolidObjects.configuration.polling_interval = 0.025
    SolidObjects.configuration.idle_polling_interval = 1.0
    SolidObjects.configuration.wake_up_adapter = wake_up
    events = []
    subscription = ActiveSupport::Notifications.subscribe(
      "solid_objects.polling.interval_changed"
    ) { |event| events << event.payload }
    worker = SolidObjects::Worker.new
    wake_up.on_wait = -> { worker.request_shutdown if wake_up.intervals.length == 7 }

    worker.run

    assert_equal [ 0.025, 0.05, 0.1, 0.2, 0.4, 0.8, 1.0 ], wake_up.intervals
    assert_equal 1.0, worker.current_polling_interval
    assert_equal({
      role: "actors",
      reason: :idle,
      previous_interval: 0.8,
      current_interval: 1.0
    }, events.last)
  ensure
    ActiveSupport::Notifications.unsubscribe(subscription) if subscription
    worker&.stop
  end

  test "backs idle effect, reminder, and broadcast roles off to the configured ceiling" do
    component = nil
    {
      SolidObjects::EffectExecutor => "effects",
      SolidObjects::ReminderScheduler => "reminders",
      SolidObjects::BroadcastExecutor => "broadcasts"
    }.each do |component_class, role|
      wake_up = ImmediateTimeoutWakeUp.new
      SolidObjects.configuration.polling_interval = 0.025
      SolidObjects.configuration.idle_polling_interval = 1.0
      SolidObjects.configuration.wake_up_adapter = wake_up
      SolidObjects.instance_variable_set(:@wake_up, nil)
      component = component_class.new
      wake_up.on_wait = -> { component.request_shutdown if wake_up.intervals.length == 7 }

      component.run

      assert_equal [ 0.025, 0.05, 0.1, 0.2, 0.4, 0.8, 1.0 ], wake_up.intervals, role
      assert_equal 1.0, component.current_polling_interval, role
      component.stop
    end
  ensure
    component&.stop
  end

  test "never backs an actor worker off beyond its lease renewal interval" do
    wake_up = ImmediateTimeoutWakeUp.new
    SolidObjects.configuration.polling_interval = 0.025
    SolidObjects.configuration.idle_polling_interval = 1.0
    SolidObjects.configuration.lease_duration = 0.3
    SolidObjects.configuration.lease_renewal_interval = 0.1
    SolidObjects.configuration.wake_up_adapter = wake_up
    worker = SolidObjects::Worker.new
    wake_up.on_wait = -> { worker.request_shutdown if wake_up.intervals.length == 5 }

    worker.run

    assert_equal [ 0.025, 0.05, 0.1, 0.1, 0.1 ], wake_up.intervals
  ensure
    worker&.stop
  end

  test "keeps a legacy wake-up adapter at the fast interval" do
    wake_up = LegacyWakeUp.new
    SolidObjects.configuration.polling_interval = 0.025
    SolidObjects.configuration.idle_polling_interval = 1.0
    SolidObjects.configuration.wake_up_adapter = wake_up
    worker = SolidObjects::Worker.new
    wake_up.on_wait = -> { worker.request_shutdown if wake_up.intervals.length == 3 }

    worker.run

    assert_equal [ 0.025, 0.025, 0.025 ], wake_up.intervals
  ensure
    worker&.stop
  end

  test "captures wake-up state before checking for actor work" do
    wake_up = SnapshotWakeUp.new
    SolidObjects.configuration.wake_up_adapter = wake_up
    worker = SolidObjects::Worker.new
    wake_up.on_wait = -> { worker.request_shutdown }

    worker.run

    assert_equal [ :watch, :wait ], wake_up.events
  ensure
    worker&.stop
  end

  test "processes local work promptly after reaching the idle ceiling" do
    SolidObjects.configuration.polling_interval = 0.025
    SolidObjects.configuration.idle_polling_interval = 1.0
    worker = SolidObjects::Worker.new
    worker_thread = Thread.new { worker.run }
    Timeout.timeout(3) do
      sleep 0.005 until worker.current_polling_interval >= 1.0
    end

    started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    message = WakeLatencyActor.ref("local").async.increment
    Timeout.timeout(0.4) do
      sleep 0.005 until message.status == "completed"
    end
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at

    assert_operator elapsed, :<, 0.4
  ensure
    worker&.request_shutdown
    worker_thread&.join(2)
    worker&.stop
  end

  test "warns once when another process shares the database without a wake-up adapter" do
    logger = RecordingLogger.new
    SolidObjects.configuration.logger = logger
    SolidObjects.configuration.polling_interval = 0.025
    SolidObjects.configuration.idle_polling_interval = 1.0
    SolidObjects::Process.create!(
      id: SecureRandom.uuid,
      kind: "worker",
      hostname: "another-host",
      pid: ::Process.pid + 1,
      started_at: Time.current,
      last_heartbeat_at: Time.current,
      metadata: {}
    )
    workers = [ SolidObjects::Worker.new, SolidObjects::Worker.new ]
    workers.each(&:request_shutdown)

    workers.each(&:run)

    assert_equal [ {
      event: "solid_objects.polling_only_cross_process_wake_up",
      polling_interval: 0.025,
      idle_polling_interval: 1.0
    } ], logger.warnings
  ensure
    workers&.each(&:stop)
  end

  test "does not warn when all observed processes share the current Ruby process" do
    logger = RecordingLogger.new
    SolidObjects.configuration.logger = logger
    SolidObjects::Process.create!(
      id: SecureRandom.uuid,
      kind: "worker",
      hostname: Socket.gethostname,
      pid: ::Process.pid,
      started_at: Time.current,
      last_heartbeat_at: Time.current,
      metadata: {}
    )

    SolidObjects::ProcessRegistry.warn_if_polling_is_only_cross_process_wake_up

    assert_empty logger.warnings
  end

  test "does not warn when a cross-process wake-up adapter is configured" do
    logger = RecordingLogger.new
    SolidObjects.configuration.logger = logger
    SolidObjects.configuration.wake_up_adapter = ImmediateTimeoutWakeUp.new
    SolidObjects::Process.create!(
      id: SecureRandom.uuid,
      kind: "worker",
      hostname: "another-host",
      pid: ::Process.pid + 1,
      started_at: Time.current,
      last_heartbeat_at: Time.current,
      metadata: {}
    )

    SolidObjects::ProcessRegistry.warn_if_polling_is_only_cross_process_wake_up

    assert_empty logger.warnings
  end
end
