# frozen_string_literal: true

require "database_test_helper"

class SupervisorAdditionalComponentsTest < ActiveSupport::TestCase
  class RecordingComponent
    attr_reader :label

    def initialize(label: "default")
      @label = label
      @started = Concurrent::AtomicBoolean.new(false)
      @stopped = Concurrent::AtomicBoolean.new(false)
      @shutdown_requested = Concurrent::AtomicBoolean.new(false)
      @gate = Queue.new
    end

    def run
      @started.make_true
      @gate.pop
      @stopped.make_true
    end

    def request_shutdown
      @shutdown_requested.make_true
      @gate << :stop
    end

    def stop
      @stopped.make_true
    end

    def stopped? = @stopped.true?

    def started? = @started.true?

    def shutdown_requested? = @shutdown_requested.true?

    # Ends the run loop without a shutdown request, the way a crash does.
    def simulate_crash
      @gate << :crash
    end
  end

  setup do
    SolidObjects.reset!
  end

  teardown do
    SolidObjects.reset!
  end

  test "runs a registered component alongside the built in ones" do
    component = register_component
    supervisor = new_supervisor
    supervisor.start

    wait_until { component.started? }

    assert component.started?, "the supervisor never ran the registered component"
  ensure
    supervisor&.stop
  end

  test "asks a registered component to shut down" do
    component = register_component
    supervisor = new_supervisor
    supervisor.start
    wait_until { component.started? }

    supervisor.stop

    assert component.shutdown_requested?, "the supervisor never asked the component to stop"
  end

  test "leaves the built in processes unchanged" do
    component = register_component
    supervisor = new_supervisor
    supervisor.start
    wait_until { component.started? }

    assert_equal(
      %w[broadcast effect reminder worker],
      SolidObjects::Process.order(:kind).pluck(:kind)
    )
  ensure
    supervisor&.stop
  end

  test "runs the requested count of a registered component" do
    built = Concurrent::AtomicFixnum.new(0)
    SolidObjects.configuration.register_component(count: 2) do
      built.increment
      RecordingComponent.new
    end

    supervisor = new_supervisor
    supervisor.start

    # One call validates the registration, then one call for each instance.
    assert_equal 3, built.value
  ensure
    supervisor&.stop
  end

  # The supervisor used to rebuild a dead component with component.class.new,
  # which throws away whatever the factory configured.
  test "replaces a crashed component through its own factory" do
    components = Queue.new
    SolidObjects.configuration.register_component do
      component = RecordingComponent.new(label: "from-factory")
      components << component
      component
    end

    supervisor = new_supervisor
    supervisor.start
    components.pop # the instance built during validation
    first = components.pop
    wait_until { first.started? }

    first.simulate_crash

    wait_until { components.size.positive? }
    replacement = components.pop

    assert_equal "from-factory", replacement.label
    assert_not_same first, replacement
  ensure
    supervisor&.stop
  end

  private

  def register_component(label: "default")
    component = RecordingComponent.new(label:)
    SolidObjects.configuration.register_component { component }
    component
  end

  def new_supervisor
    SolidObjects::Supervisor.new(
      worker_count: 1,
      effect_worker_count: 1,
      broadcast_worker_count: 1,
      reminder_scheduler_count: 1
    )
  end

  def wait_until(timeout: 5)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    sleep 0.01 until yield || Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
  end
end
