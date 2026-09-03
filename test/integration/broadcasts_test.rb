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

  test "recovers the oldest broadcast across pending and stale work" do
    pending_reference = PublicCounterActor.ref("pending").async.increment
    stale_reference = PublicCounterActor.ref("stale").async.increment
    worker = SolidObjects::Worker.new
    worker.run_until_idle
    stale_process_registry = SolidObjects::ProcessRegistry.new
    stale_process = stale_process_registry.register(kind: "broadcast")
    now = SolidObjects.database_adapter.database_now
    pending_broadcast = SolidObjects::Broadcast.find_by!(message_id: pending_reference.id)
    pending_broadcast.update!(available_at: now - 1.minute)
    stale_broadcast = SolidObjects::Broadcast.find_by!(message_id: stale_reference.id)
    stale_broadcast.update!(
      status: "processing",
      available_at: now - 2.minutes,
      claimed_by: stale_process.id,
      claimed_at: now - SolidObjects.configuration.process_alive_threshold - 1.second
    )
    delivered = Queue.new
    SolidObjects.configuration.broadcast_adapter = ->(broadcast) { delivered << broadcast.id }
    broadcast_executor = SolidObjects::BroadcastExecutor.new

    assert broadcast_executor.run_once

    assert_equal stale_broadcast.id, delivered.pop
    assert_equal "delivered", stale_broadcast.reload.status
    assert_equal "pending", pending_broadcast.reload.status
  ensure
    broadcast_executor&.stop
    stale_process_registry&.stop
    worker&.stop
  end

  test "concurrent executors claim different broadcasts" do
    pending_reference = PublicCounterActor.ref("pending").async.increment
    stale_reference = PublicCounterActor.ref("stale").async.increment
    worker = SolidObjects::Worker.new
    worker.run_until_idle
    stale_process_registry = SolidObjects::ProcessRegistry.new
    stale_process = stale_process_registry.register(kind: "broadcast")
    now = SolidObjects.database_adapter.database_now
    pending_broadcast = SolidObjects::Broadcast.find_by!(message_id: pending_reference.id)
    pending_broadcast.update!(available_at: now - 1.minute)
    stale_broadcast = SolidObjects::Broadcast.find_by!(message_id: stale_reference.id)
    stale_broadcast.update!(
      status: "processing",
      available_at: now - 2.minutes,
      claimed_by: stale_process.id,
      claimed_at: now - SolidObjects.configuration.process_alive_threshold - 1.second
    )
    claims = Queue.new
    release = Queue.new
    SolidObjects.configuration.broadcast_adapter = lambda do |broadcast|
      claims << broadcast.id
      release.pop
    end
    executor_a = SolidObjects::BroadcastExecutor.new
    executor_b = SolidObjects::BroadcastExecutor.new

    thread_a = Thread.new { executor_a.run_once }
    assert_equal stale_broadcast.id, Timeout.timeout(5) { claims.pop }
    thread_b = Thread.new { executor_b.run_once }
    assert_equal pending_broadcast.id, Timeout.timeout(5) { claims.pop }
    2.times { release << true }

    assert thread_a.value
    assert thread_b.value
    assert_equal %w[delivered delivered], SolidObjects::Broadcast.order(:id).pluck(:status)
  ensure
    2.times { release << true } if release
    thread_a&.join(2)
    thread_b&.join(2)
    executor_a&.stop
    executor_b&.stop
    stale_process_registry&.stop
    worker&.stop
  end

  test "polls pending and stale broadcasts separately" do
    PublicCounterActor.ref("one").async.increment
    worker = SolidObjects::Worker.new
    worker.run_until_idle
    SolidObjects.configuration.broadcast_adapter = ->(broadcast) { broadcast }
    broadcast_executor = SolidObjects::BroadcastExecutor.new
    polling_queries = []
    subscription = ActiveSupport::Notifications.subscribe("sql.active_record") do |event|
      query = event.payload.fetch(:sql).squish
      if query.match?(/SELECT .* FROM ["`]solid_objects_broadcasts["`]/) &&
          query.match?(/ORDER BY .*available_at.*id.*LIMIT/i)
        polling_queries << query
      end
    end

    assert broadcast_executor.run_once

    assert_equal 2, polling_queries.length
    assert polling_queries.one? { |query| !query.include?("claimed_at") }
    assert polling_queries.one? { |query| query.include?("claimed_at") }
    polling_queries.each { |query| refute_match(/\sOR\s/i, query) }
    if database_family != :sqlite
      polling_queries.each { |query| assert_match(/FOR UPDATE SKIP LOCKED\z/i, query) }
    end
  ensure
    ActiveSupport::Notifications.unsubscribe(subscription) if subscription
    broadcast_executor&.stop
    worker&.stop
  end
end
