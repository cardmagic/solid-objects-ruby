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
      state.define_singleton_method(:to_h) do |*arguments|
        actor_class.state_copies += 1
        super(*arguments)
      end
    end
  end

  class LargeStateActor < SolidObjects::Actor
    actor_type "state-commit-large"

    attribute :filler, default: ""

    def grow(size:)
      self.filler = "x" * size
    end
  end

  setup do
    CountingActor.state_copies = 0
  end

  test "a committed message builds one state image after its handler runs" do
    CountingActor.ref("message").async.increment
    worker = SolidObjects::Worker.new
    worker.run_until_idle

    assert_equal 1, CountingActor.state_copies
    instance = SolidObjects::Instance.find_by!(actor_type: "state-commit-counting", actor_id: "message")
    assert_equal({ "count" => 1 }, instance.state)
  ensure
    worker&.stop
  end

  test "a committed query builds one state image after its handler runs" do
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

  test "reports committed state above the soft threshold" do
    SolidObjects.configuration.state_size_warning_bytes = 64
    events = []
    subscription = ActiveSupport::Notifications.subscribe("solid_objects.state.large") do |event|
      events << event.payload
    end

    LargeStateActor.ref("big").async.grow(size: 512)
    worker = SolidObjects::Worker.new
    worker.run_until_idle

    assert_equal 1, events.length
    assert_equal %i[actor_type actor_id state_bytes threshold_bytes].sort, events.sole.keys.sort
    assert_equal "state-commit-large", events.sole.fetch(:actor_type)
    assert_equal "big", events.sole.fetch(:actor_id)
    assert_equal 64, events.sole.fetch(:threshold_bytes)
    assert_operator events.sole.fetch(:state_bytes), :>, 512
  ensure
    ActiveSupport::Notifications.unsubscribe(subscription) if subscription
    worker&.stop
  end

  test "stays silent for committed state under the soft threshold" do
    SolidObjects.configuration.state_size_warning_bytes = 4_096
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
end
