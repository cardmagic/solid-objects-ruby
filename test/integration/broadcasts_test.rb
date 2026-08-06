# frozen_string_literal: true

require "database_test_helper"

class BroadcastsTest < ActiveSupport::TestCase
  class CounterActor < SolidObjects::Actor
    actor_type "broadcast-counter"

    attribute :count, default: 0

    observable :count

    def increment
      self.count += 1
    end

    def broken_increment
      self.count += 1
      raise "increment failed"
    end
  end

  setup do
    SolidObjects.configuration.retry_delay = ->(_attempt) { 0 }
  end

  test "enqueues changed observables in the state commit" do
    message_reference = CounterActor.ref("one").async(:increment)
    worker = SolidObjects::Worker.new

    worker.run_until_idle

    broadcast = SolidObjects::Broadcast.find_by!(message_id: message_reference.id)
    assert_equal "count", broadcast.observable_name
    assert_equal 1, broadcast.value
    assert_equal "pending", broadcast.status
    assert_equal 1, broadcast.state_version
    assert_equal 1, broadcast.activation_generation
  ensure
    worker&.stop
  end

  test "does not enqueue a broadcast when the actor turn rolls back" do
    CounterActor.ref("one").async(:broken_increment)
    worker = SolidObjects::Worker.new

    worker.run_once

    assert_empty SolidObjects::Broadcast.all
  ensure
    worker&.stop
  end

  test "delivers the durable broadcast after commit" do
    delivered = Queue.new
    SolidObjects.configuration.broadcast_adapter = ->(broadcast) { delivered << broadcast.value }
    CounterActor.ref("one").async(:increment)
    worker = SolidObjects::Worker.new
    worker.run_until_idle
    broadcast_executor = SolidObjects::BroadcastExecutor.new

    assert broadcast_executor.run_once

    assert_equal 1, delivered.pop
    broadcast = SolidObjects::Broadcast.first
    assert_equal "delivered", broadcast.status
    assert broadcast.delivered_at
  ensure
    broadcast_executor&.stop
    worker&.stop
  end

  test "retries a failed broadcast delivery" do
    attempts = 0
    SolidObjects.configuration.broadcast_adapter = lambda do |_broadcast|
      attempts += 1
      raise "cable unavailable" if attempts == 1
    end
    CounterActor.ref("one").async(:increment)
    worker = SolidObjects::Worker.new
    worker.run_until_idle
    broadcast_executor = SolidObjects::BroadcastExecutor.new

    refute broadcast_executor.run_once
    assert_equal "pending", SolidObjects::Broadcast.first.status
    assert broadcast_executor.run_once

    broadcast = SolidObjects::Broadcast.first
    assert_equal 2, broadcast.attempt_count
    assert_equal "delivered", broadcast.status
  ensure
    broadcast_executor&.stop
    worker&.stop
  end
end
