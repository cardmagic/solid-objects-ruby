# frozen_string_literal: true

require "database_test_helper"

class StateCommitTest < ActiveSupport::TestCase
  class CountingActor < SolidObjects::Actor
    actor_type "state-commit-counting"

    class << self
      attr_accessor :state_copies
    end

    attribute :count, default: 0

    def increment
      count_state_copies
      self.count = count + 1
    end

    query :current do
      count_state_copies
      count
    end

    query :mutating do
      self.count = count + 1
    end

    private

    def count_state_copies
      actor_class = self.class
      %i[to_h to_h_with_byte_size].each do |name|
        state.define_singleton_method(name) do |*arguments|
          actor_class.state_copies += 1
          super(*arguments)
        end
      end
    end
  end

  class ObservableMutatingActor < SolidObjects::Actor
    actor_type "state-commit-observable"

    class << self
      attr_accessor :mutate_on_read
    end

    attribute :count, default: 0

    observable :reads do
      self.count = count + 1 if self.class.mutate_on_read
      count
    end

    query :current do
      self.class.mutate_on_read = true
      count
    end
  end

  class LargeStateActor < SolidObjects::Actor
    actor_type "state-commit-large"

    attribute :filler, default: ""

    def grow(size:)
      self.filler = "x" * size
    end
  end

  class RollingBackActor < SolidObjects::Actor
    actor_type "state-commit-rollback"

    attribute :filler, default: ""

    def grow(size:)
      self.filler = "x" * size
      commit_action :state_commit_failure
    end
  end

  class RaisingLogger
    def error(*)
      raise "logger failed"
    end

    def method_missing(*)
      nil
    end

    def respond_to_missing?(*)
      true
    end
  end

  setup do
    CountingActor.state_copies = 0
    ObservableMutatingActor.mutate_on_read = false
  end

  test "a state above the hard limit fails its message and commits nothing" do
    SolidObjects.configuration.max_state_bytes = 512
    SolidObjects.configuration.warn_state_bytes = 256
    SolidObjects.configuration.max_attempts = 1

    LargeStateActor.ref("over").async.grow(size: 4_096)
    worker = SolidObjects::Worker.new
    worker.run_until_idle

    message = SolidObjects::Message.find_by!(actor_type: "state-commit-large", actor_id: "over")
    assert_equal "SolidObjects::PayloadTooLarge", message.error.fetch("class")
    instance = SolidObjects::Instance.find_by!(actor_type: "state-commit-large", actor_id: "over")
    assert_empty instance.state
  ensure
    worker&.stop
  end

  test "a committed message copies the state once after its handler runs" do
    CountingActor.ref("message").async.increment
    worker = SolidObjects::Worker.new
    worker.run_until_idle

    assert_equal 1, CountingActor.state_copies
    instance = SolidObjects::Instance.find_by!(actor_type: "state-commit-counting", actor_id: "message")
    assert_equal({ "count" => 1 }, instance.state)
  ensure
    worker&.stop
  end

  test "a committed message does not encode the state a second time" do
    CountingActor.ref("encodes").async.increment
    worker = SolidObjects::Worker.new

    assert_equal 1, measured_dumps { worker.run_until_idle },
      "only the result should reach a byte-limited dump; the state carries its own size"
  ensure
    worker&.stop
  end

  test "a committed query copies the state once after its handler runs" do
    assert_equal 0, CountingActor.ref("query").sync.current

    assert_equal 1, CountingActor.state_copies
  end

  test "a query that mutates state fails its message" do
    SolidObjects.configuration.max_attempts = 1

    error = assert_raises(SolidObjects::MessageFailed) do
      CountingActor.ref("guard").sync.mutating
    end

    assert_equal "SolidObjects::InvalidActor", error.details.fetch("class")
    instance = SolidObjects::Instance.find_by!(actor_type: "state-commit-counting", actor_id: "guard")
    assert_empty instance.state, "the rejected mutation must not reach the committed row"
  end

  test "a query whose observable mutates state fails its message" do
    SolidObjects.configuration.max_attempts = 1

    error = assert_raises(SolidObjects::MessageFailed) do
      ObservableMutatingActor.ref("observable").sync.current
    end

    assert_equal "SolidObjects::InvalidActor", error.details.fetch("class")
    instance = SolidObjects::Instance.find_by!(actor_type: "state-commit-observable", actor_id: "observable")
    assert_empty instance.state, "the observable mutation must not reach the committed row"
  end

  test "reports committed state above the soft threshold" do
    SolidObjects.configuration.warn_state_bytes = 64
    events = []
    subscription = ActiveSupport::Notifications.subscribe("solid_objects.state.large") do |event|
      events << event.payload
    end

    LargeStateActor.ref("big").async.grow(size: 512)
    worker = SolidObjects::Worker.new
    worker.run_until_idle

    assert_equal 1, events.length
    assert_equal %i[actor_type actor_id byte_count threshold_bytes].sort, events.sole.keys.sort
    assert_equal "state-commit-large", events.sole.fetch(:actor_type)
    assert_equal "big", events.sole.fetch(:actor_id)
    assert_equal 64, events.sole.fetch(:threshold_bytes)
    assert_operator events.sole.fetch(:byte_count), :>, 512
  ensure
    ActiveSupport::Notifications.unsubscribe(subscription) if subscription
    worker&.stop
  end

  test "stays silent for committed state under the soft threshold" do
    SolidObjects.configuration.warn_state_bytes = 4_096
    events = []
    subscription = ActiveSupport::Notifications.subscribe("solid_objects.state.large") do |event|
      events << event.payload
    end

    LargeStateActor.ref("small").async.grow(size: 512)
    worker = SolidObjects::Worker.new
    worker.run_until_idle

    assert_empty events
  ensure
    ActiveSupport::Notifications.unsubscribe(subscription) if subscription
    worker&.stop
  end

  test "stays silent for state a rolled back turn never wrote" do
    SolidObjects.configuration.warn_state_bytes = 64
    SolidObjects.configuration.max_attempts = 1
    SolidObjects.register_commit_action(:state_commit_failure) { raise "commit action failed" }
    events = []
    subscription = ActiveSupport::Notifications.subscribe("solid_objects.state.large") do |event|
      events << event.payload
    end

    RollingBackActor.ref("rolled-back").async.grow(size: 512)
    worker = SolidObjects::Worker.new
    worker.run_until_idle

    assert_empty events
    instance = SolidObjects::Instance.find_by!(actor_type: "state-commit-rollback", actor_id: "rolled-back")
    assert_empty instance.state
  ensure
    ActiveSupport::Notifications.unsubscribe(subscription) if subscription
    worker&.stop
  end

  test "a reporting failure does not disturb a turn that already committed" do
    SolidObjects.configuration.warn_state_bytes = 64
    completions = []
    failures = []
    subscriptions = [
      ActiveSupport::Notifications.subscribe("solid_objects.state.large") { raise "subscriber failed" },
      ActiveSupport::Notifications.subscribe("solid_objects.message.completed") { completions << true },
      ActiveSupport::Notifications.subscribe("solid_objects.instrumentation.failed") { |event| failures << event.payload }
    ]

    LargeStateActor.ref("noisy").async.grow(size: 512)
    worker = SolidObjects::Worker.new
    worker.run_until_idle

    message = SolidObjects::Message.find_by!(actor_type: "state-commit-large", actor_id: "noisy")
    assert_predicate message, :completed?
    assert_equal 1, completions.length, "a committed turn must still report completion"
    assert_equal 1, failures.length
    assert_equal "solid_objects.state.large", failures.sole.fetch(:instrumentation_event)
    assert_empty SolidObjects::ReadyMessage.all, "a committed turn must not run again"
  ensure
    subscriptions&.each { |subscription| ActiveSupport::Notifications.unsubscribe(subscription) }
    worker&.stop
  end

  test "a failure that reports a failure does not disturb a committed turn" do
    SolidObjects.configuration.warn_state_bytes = 64
    SolidObjects.configuration.logger = RaisingLogger.new
    completions = []
    subscriptions = [
      ActiveSupport::Notifications.subscribe("solid_objects.state.large") { raise "subscriber failed" },
      ActiveSupport::Notifications.subscribe("solid_objects.instrumentation.failed") { raise "reporter failed" },
      ActiveSupport::Notifications.subscribe("solid_objects.message.completed") { completions << true }
    ]

    LargeStateActor.ref("hostile").async.grow(size: 512)
    worker = SolidObjects::Worker.new
    worker.run_until_idle

    message = SolidObjects::Message.find_by!(actor_type: "state-commit-large", actor_id: "hostile")
    assert_predicate message, :completed?
    assert_equal 1, completions.length, "a committed turn must still report completion"
    assert_empty SolidObjects::ReadyMessage.all, "a committed turn must not run again"
  ensure
    subscriptions&.each { |subscription| ActiveSupport::Notifications.unsubscribe(subscription) }
    worker&.stop
  end

  private

  def measured_dumps
    calls = 0
    trace = TracePoint.new(:call) do |point|
      calls += 1 if point.method_id == :dump_with_byte_size
    end
    trace.enable { yield }
    calls
  end
end
