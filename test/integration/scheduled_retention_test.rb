# frozen_string_literal: true

require "database_test_helper"
require "timeout"

class ScheduledRetentionTest < ActiveSupport::TestCase
  class IdleRole
    # An endless method definition cannot take a modifier keyword: the modifier
    # would apply to the definition itself and loop the class body.
    def run
      sleep(0.01) until @shutdown
    end

    def request_shutdown = @shutdown = true
    def stop = @stopped = true
    def stopped? = @stopped
  end

  class CrashOnceRole < IdleRole
    class << self
      attr_accessor :shared_runs
    end

    def initialize
      self.class.shared_runs ||= 0
    end

    def runs = self.class.shared_runs

    # Crashes only after the first monitor pass has begun, so replacement is
    # needed while a slow retention pass is already running.
    def run
      self.class.shared_runs += 1
      if self.class.shared_runs == 1
        # The crash is the point of the test, so its backtrace is not news.
        Thread.current.report_on_exception = false
        sleep 0.1
        raise "role crashed"
      end

      super
    end
  end

  setup do
    CrashOnceRole.shared_runs = nil
    SolidObjects.configuration.supervisor_monitor_interval = 0.02
    SolidObjects.configuration.dead_process_cleanup_interval = 0
    SolidObjects.configuration.retention_interval = 0.05
    SolidObjects.configuration.message_retention = 0
    # A test that stalls a retention pass on purpose should not pay the
    # production join before the thread is killed.
    SolidObjects.configuration.shutdown_timeout = 0.2
  end

  teardown do
    @supervisor&.stop
    SolidObjects.configuration.retention_interval = 3600.0
    SolidObjects.configuration.dead_process_cleanup_interval = 60.0
    SolidObjects.configuration.supervisor_monitor_interval = 1.0
    SolidObjects.configuration.shutdown_timeout = 15.0
  end

  test "the supervisor prunes expired messages without being asked" do
    expired_message

    @supervisor = supervisor
    @supervisor.start

    Timeout.timeout(10) { sleep 0.02 until SolidObjects::Message.count.zero? }
    assert_equal 0, SolidObjects::Message.count
  end

  test "retention can be disabled" do
    SolidObjects.configuration.retention_interval = 0
    expired_message

    @supervisor = supervisor
    @supervisor.start
    sleep 0.3

    assert_equal 1, SolidObjects::Message.count,
      "a zero interval should disable scheduled retention"
  end

  # Retention runs once at startup and then on its interval, matching how dead
  # process records are cleaned up.
  test "retention waits for its interval after the first pass" do
    SolidObjects.configuration.retention_interval = 60
    expired_message

    @supervisor = supervisor
    @supervisor.start
    Timeout.timeout(10) { sleep 0.02 until SolidObjects::Message.count.zero? }
    expired_message
    sleep 0.2

    assert_equal 1, SolidObjects::Message.count,
      "a second pass should wait for the interval rather than run every monitor tick"
  end

  test "instruments what it pruned" do
    counts = []
    subscription = ActiveSupport::Notifications.subscribe("solid_objects.messages.pruned") do |event|
      counts << event.payload[:count]
    end
    expired_message

    @supervisor = supervisor
    @supervisor.start
    Timeout.timeout(10) { sleep 0.02 until counts.any? { |count| count.positive? } }

    assert_includes counts, 1
  ensure
    ActiveSupport::Notifications.unsubscribe(subscription) if subscription
  end

  # The interval here is far longer than the assertion window, so a retry that
  # waited it out would fail. A transient lock or connection error must not
  # defer retention for the whole hour.
  test "a failing retention pass retries rather than deferring for the interval" do
    SolidObjects.configuration.retention_interval = 600
    failures = []
    subscription = ActiveSupport::Notifications.subscribe("solid_objects.supervisor.retention_failed") do
      failures << true
    end
    role = IdleRole.new
    @supervisor = supervisor(role)
    @supervisor.define_singleton_method(:prune_expired_records) { raise "boom" }

    @supervisor.start
    Timeout.timeout(5) { sleep 0.02 until failures.length >= 3 }

    assert @supervisor.instance_variable_get(:@monitor).alive?,
      "the monitor should survive a failing retention pass"
    assert_operator failures.length, :>=, 3
  ensure
    ActiveSupport::Notifications.unsubscribe(subscription) if subscription
  end

  # Retrying at monitor cadence forever would hammer a database that stays
  # down, so the pause grows and is capped by the configured interval.
  test "repeated retention failures back off" do
    SolidObjects.configuration.retention_interval = 600
    SolidObjects.configuration.supervisor_monitor_interval = 0.05
    @supervisor = supervisor
    @supervisor.define_singleton_method(:prune_expired_records) { raise "boom" }

    pauses = (1..5).map { |failures| @supervisor.send(:retention_pause, failures) }

    assert_equal pauses.sort, pauses, "each failure should wait at least as long"
    assert_operator pauses.last, :>, pauses.first
    assert_operator pauses.max, :<=, 600
  end

  test "a recovered retention pass returns to its interval" do
    SolidObjects.configuration.retention_interval = 600
    @supervisor = supervisor

    assert_equal 600, @supervisor.send(:retention_pause, 0)
  end

  # Role replacement must not wait behind housekeeping.
  test "a slow retention pass does not block role replacement" do
    SolidObjects.configuration.retention_interval = 0.02
    role = CrashOnceRole.new
    @supervisor = supervisor(role)
    @supervisor.define_singleton_method(:prune_expired_records) { sleep 10 }

    @supervisor.start

    # Shorter than the pruning pass, so sharing a thread with it fails here.
    Timeout.timeout(3) { sleep 0.02 until role.runs >= 2 }
    assert_operator role.runs, :>=, 2,
      "a crashed role should be replaced while retention is still running"
  end

  test "rejects a negative retention interval" do
    SolidObjects.configuration.retention_interval = -1

    assert_raises ArgumentError do
      SolidObjects.configuration.validate!
    end
  end

  private

  def supervisor(role = IdleRole.new)
    SolidObjects::Supervisor.new(
      worker_count: 0,
      effect_worker_count: 0,
      broadcast_worker_count: 0,
      reminder_scheduler_count: 0
    ).tap { |supervisor| supervisor.instance_variable_set(:@components, [ role ]) }
  end

  # A message old enough that the configured retention has already expired it.
  def expired_message(actor_id = SecureRandom.hex(4))
    instance = SolidObjects::Instance.create!(
      actor_type: "retention-actor",
      actor_id:,
      state: {},
      state_version: 1,
      next_message_sequence: 2
    )
    SolidObjects::Message.create!(
      instance:,
      actor_type: "retention-actor",
      actor_id:,
      operation: "noop",
      delivery_mode: "async",
      arguments: {},
      sequence: 1,
      max_attempts: 1,
      attempt_count: 1,
      request_id: SecureRandom.uuid,
      enqueued_at: 1.hour.ago,
      completed_at: 1.hour.ago,
      created_at: 1.hour.ago,
      updated_at: 1.hour.ago
    )
  end
end
