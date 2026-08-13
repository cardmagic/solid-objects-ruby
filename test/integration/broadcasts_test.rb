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

  class PublicCounterActor < SolidObjects::Actor
    actor_type "public-broadcast-counter"

    attribute :count, default: 0

    observable :count, broadcast: :value

    def increment
      self.count += 1
    end
  end

  class PrivateRoomActor < SolidObjects::Actor
    actor_type "private-broadcast-room"

    attribute :secret, default: nil

    observable :secret

    def reveal(secret:)
      self.secret = secret
    end
  end

  setup do
    SolidObjects.configuration.retry_delay = ->(_attempt) { 0 }
  end

  test "observables default to invalidation-only broadcasts" do
    message_reference = CounterActor.ref("one").async.increment
    worker = SolidObjects::Worker.new

    worker.run_until_idle

    broadcast = SolidObjects::Broadcast.find_by!(message_id: message_reference.id)
    assert_equal "count", broadcast.observable_name
    assert_equal({}, broadcast.value)
    refute broadcast.broadcasts_value?
    assert_equal "pending", broadcast.status
    assert_equal 1, broadcast.state_version
    assert_equal 1, broadcast.activation_generation
    assert_equal message_reference.sequence, broadcast.instance.state_revision
  ensure
    worker&.stop
  end

  test "value broadcasts require an explicit opt-in" do
    message_reference = PublicCounterActor.ref("one").async.increment
    worker = SolidObjects::Worker.new

    worker.run_until_idle

    broadcast = SolidObjects::Broadcast.find_by!(message_id: message_reference.id)
    assert_equal 1, broadcast.value
    assert broadcast.broadcasts_value?
  ensure
    worker&.stop
  end

  test "does not enqueue a broadcast when the actor turn rolls back" do
    CounterActor.ref("one").async.broken_increment
    worker = SolidObjects::Worker.new

    worker.run_once

    assert_empty SolidObjects::Broadcast.all
    assert_equal 0, SolidObjects::Instance.first.state_revision
  ensure
    worker&.stop
  end

  test "invalidation-only observables do not persist or render their values" do
    PrivateRoomActor.ref("one").async.reveal(secret: "Black Lotus")
    worker = SolidObjects::Worker.new

    worker.run_until_idle

    broadcast = SolidObjects::Broadcast.find_by!(observable_name: "secret")
    assert_equal({}, broadcast.value)

    stream = SolidObjects::TurboStreamRenderer.observable(broadcast)
    refute_includes stream, "Black Lotus"
    refute_includes stream, "turbo-stream"
    refute_nil SolidObjects::TurboStreamRenderer.invalidation(stream)
  ensure
    worker&.stop
  end

  test "delivers the durable broadcast after commit" do
    delivered = Queue.new
    SolidObjects.configuration.broadcast_adapter = ->(broadcast) { delivered << broadcast.value }
    PublicCounterActor.ref("one").async.increment
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
    CounterActor.ref("one").async.increment
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
