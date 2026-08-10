# frozen_string_literal: true

require "database_test_helper"
require "timeout"

class SupervisorReplacementTest < ActiveSupport::TestCase
  # A component that crashes on its first run and records every run after.
  class CrashingRole
    class << self
      attr_accessor :shared_runs, :shared_crashes
    end

    attr_reader :runs

    def initialize(crashes: self.class.shared_crashes || 1)
      @crashes = crashes
      self.class.shared_runs ||= Queue.new
      @runs = self.class.shared_runs
      @stopped = false
      @shutdown = false
    end

    # Mirrors Worker and ReminderScheduler, which run their shutdown cleanup in
    # an ensure and therefore report themselves stopped after a crash too.
    def run
      @runs << monotonic_now
      raise "role crashed" if @runs.size <= @crashes

      sleep 0.01 until @shutdown
    ensure
      stop
    end

    def request_shutdown = @shutdown = true

    def stop = @stopped = true

    def stopped? = @stopped

    private

    def monotonic_now = ::Process.clock_gettime(::Process::CLOCK_MONOTONIC)
  end

  class HealthyRole < CrashingRole
    def initialize(**) = super(crashes: 0)
  end

  setup do
    [ CrashingRole, HealthyRole ].each do |role|
      role.shared_runs = nil
      role.shared_crashes = nil
    end
    SolidObjects.configuration.supervisor_monitor_interval = 0.02
    SolidObjects.configuration.dead_process_cleanup_interval = 0.05
  end

  teardown { @supervisor&.stop }

  test "replaces a role whose thread died" do
    role = CrashingRole.new
    @supervisor = supervisor_for(role)

    @supervisor.start

    Timeout.timeout(10) { sleep 0.01 until role.runs.size >= 2 }
    assert_operator role.runs.size, :>=, 2,
      "a crashed role should be run again"
  end

  test "keeps replacing a role that keeps crashing" do
    CrashingRole.shared_crashes = 3
    role = CrashingRole.new
    @supervisor = supervisor_for(role)

    @supervisor.start

    Timeout.timeout(10) { sleep 0.01 until role.runs.size >= 4 }
    assert_operator role.runs.size, :>=, 4
  end

  test "does not restart a healthy role" do
    role = HealthyRole.new
    @supervisor = supervisor_for(role)

    @supervisor.start
    sleep 0.2

    assert_equal 1, role.runs.size
  end

  test "does not restart roles after shutdown is requested" do
    role = CrashingRole.new(crashes: 1)
    @supervisor = supervisor_for(role)
    @supervisor.start
    Timeout.timeout(10) { sleep 0.01 until role.runs.size >= 2 }

    @supervisor.stop
    runs_at_stop = role.runs.size
    sleep 0.2

    assert_equal runs_at_stop, role.runs.size
  end

  test "no role outlives shutdown when replacement races it" do
    10.times do
      CrashingRole.shared_runs = nil
      role = CrashingRole.new
      supervisor = supervisor_for(role)
      supervisor.start
      Timeout.timeout(10) { sleep 0.001 until role.runs.size >= 1 }

      supervisor.stop

      live = supervisor.instance_variable_get(:@threads).select(&:alive?)
      assert_empty live, "a replacement started during shutdown must not survive it"
    end
  end

  test "shutdown does not return while the monitor is still alive" do
    SolidObjects.configuration.shutdown_timeout = 0.1
    @supervisor = supervisor_for(HealthyRole.new)
    blocking = Queue.new
    @supervisor.define_singleton_method(:cleanup_dead_processes) { blocking.pop }
    @supervisor.start
    sleep 0.1

    @supervisor.stop

    refute @supervisor.instance_variable_get(:@monitor)&.alive?,
      "a blocked monitor must not outlive shutdown"
  ensure
    SolidObjects.configuration.shutdown_timeout = 5.0
  end

  test "instruments a replacement" do
    events = []
    subscription = ActiveSupport::Notifications.subscribe("solid_objects.supervisor.role_replaced") do |event|
      events << event.payload
    end
    role = CrashingRole.new
    @supervisor = supervisor_for(role)

    @supervisor.start
    Timeout.timeout(10) { sleep 0.01 until events.any? }

    assert_equal "SupervisorReplacementTest::CrashingRole", events.first.fetch(:role)
  ensure
    ActiveSupport::Notifications.unsubscribe(subscription) if subscription
  end

  test "prunes processes whose heartbeat has stopped" do
    dead = SolidObjects::Process.create!(
      id: SecureRandom.uuid,
      kind: "worker",
      hostname: "dead-host",
      pid: 999_999,
      started_at: 1.hour.ago,
      last_heartbeat_at: 1.hour.ago,
      metadata: {}
    )
    @supervisor = supervisor_for(HealthyRole.new)

    @supervisor.start
    Timeout.timeout(10) { sleep 0.02 until dead.reload.shutdown_state == "stopped" }

    assert_equal "stopped", dead.reload.shutdown_state
  end

  test "a persistently failing maintenance pass stays paced" do
    failures = []
    subscription = ActiveSupport::Notifications.subscribe("solid_objects.supervisor.monitor_failed") do
      failures << ::Process.clock_gettime(::Process::CLOCK_MONOTONIC)
    end
    @supervisor = supervisor_for(HealthyRole.new)
    @supervisor.define_singleton_method(:cleanup_dead_processes) { raise "boom" }

    @supervisor.start
    sleep 0.3

    # 0.3s at a 0.02s interval bounds the passes; spinning would produce orders
    # of magnitude more.
    assert_operator failures.size, :>, 1, "the monitor should keep running"
    assert_operator failures.size, :<, 40, "the monitor should pace its retries"
  ensure
    ActiveSupport::Notifications.unsubscribe(subscription) if subscription
  end

  test "a failing maintenance pass does not stop the supervisor" do
    role = HealthyRole.new
    @supervisor = supervisor_for(role)
    @supervisor.define_singleton_method(:cleanup_dead_processes) { raise "boom" }

    @supervisor.start
    sleep 0.2

    assert_equal 1, role.runs.size, "the role should still be running"
  end

  private

  # Every instance of a role shares one run log, so replacement instances are
  # observable the way the supervisor creates them.
  def supervisor_for(*roles)
    supervisor = SolidObjects::Supervisor.new(
      worker_count: 0,
      effect_worker_count: 0,
      broadcast_worker_count: 0,
      reminder_scheduler_count: 0
    )
    supervisor.instance_variable_set(:@components, roles)
    supervisor
  end
end
