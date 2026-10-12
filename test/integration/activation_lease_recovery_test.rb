# rbs_inline: enabled

require "database_test_helper"

class ActivationLeaseRecoveryTest < ActiveSupport::TestCase
  class Counter < SolidObjects::Actor
    actor_type "activation-lease-recovery"
    attribute :count, default: 0

    class << self
      attr_accessor :before_commit
    end

    def increment
      self.count += 1
      self.class.before_commit&.call
      count
    end
  end

  setup do
    SolidObjects.configuration.lease_duration = 0.2
    SolidObjects.configuration.lease_renewal_interval = 0.05
    SolidObjects.configuration.max_attempts = 1
    @clock = { now: SolidObjects.database_adapter.database_now }
    clock = @clock
    SolidObjects.database_adapter.define_singleton_method(:database_now) { clock.fetch(:now) }
    Counter.before_commit = nil
    @events = []
    @subscription = ActiveSupport::Notifications.subscribe(/solid_objects\.(message|activation|recovery)\./) do |event|
      @events << event.name
    end
  end

  teardown do
    ActiveSupport::Notifications.unsubscribe(@subscription)
    SolidObjects.database_adapter.singleton_class.remove_method(:database_now)
    Counter.before_commit = nil
  end

  test "keeps renewing across short worker passes for five lease durations" do
    worker = SolidObjects::Worker.new
    Counter.before_commit = -> { @clock[:now] += 0.03 }
    messages = []
    first_expiration = nil

    34.times do
      messages << Counter.ref("continuous").async.increment
      assert_equal 1, worker.run_once
      first_expiration ||= instance.activation_expires_at
    end

    assert_operator instance.activation_expires_at, :>, first_expiration + 0.8
    assert_equal 1, instance.activation_generation
    messages.each_with_index do |reference, index|
      message = SolidObjects::Message.find(reference.id)
      assert_predicate message, :completed?
      assert_equal index + 1, message.result
      assert_equal 1, message.attempt_count
    end
    assert_equal 34, @events.count("solid_objects.message.completed")
  ensure
    worker&.stop
  end

  test "renews between short turns while draining without a renewal thread" do
    messages = 34.times.map { Counter.ref("draining").async.increment }
    registry = SolidObjects::ProcessRegistry.new
    process = registry.register
    activation = SolidObjects::ActivationManager.new(owner_id: process.id).claim_next
    first_expiration = instance.activation_expires_at
    Counter.before_commit = -> { @clock[:now] += 0.03 }

    assert_equal 34, activation.drain
    assert_operator instance.activation_expires_at, :>, first_expiration + 0.8
    assert_equal 1, instance.activation_generation
    assert messages.all? { |reference| SolidObjects::Message.find(reference.id).completed? }
  ensure
    activation&.deactivate
    registry&.stop
  end

  test "keeps the expired lease fence while a message claim remains" do
    worker = SolidObjects::Worker.new
    first = Counter.ref("expired").async.increment
    second = Counter.ref("expired").async.increment
    Counter.before_commit = -> { @clock[:now] += 0.22 }

    assert_equal 0, worker.run_once
    assert_empty instance.state
    assert SolidObjects::ClaimedMessage.exists?(message_id: first.id)
    assert_not_nil instance.activation_expires_at
    assert_operator instance.activation_expires_at, :<=, @clock.fetch(:now)
    Counter.before_commit = nil

    assert_equal 2, worker.run_once
    assert_equal 1, SolidObjects::Message.find(first.id).result
    assert_equal 2, SolidObjects::Message.find(first.id).attempt_count
    assert_equal 2, SolidObjects::Message.find(second.id).result
    assert_equal 1, SolidObjects::Message.find(second.id).attempt_count
    assert_empty SolidObjects::DeadLetter.all
    assert_equal 2, @events.count("solid_objects.message.completed")
  ensure
    worker&.stop
  end

  test "recovers on the same worker and preserves mailbox order with one allowed attempt" do
    worker = SolidObjects::Worker.new
    first = Counter.ref("recoverable").async.increment
    second = Counter.ref("recoverable").async.increment
    Counter.before_commit = -> { @clock[:now] += 0.22 }

    assert_equal 0, worker.run_once
    assert_empty instance.state
    Counter.before_commit = nil

    assert_equal 2, worker.run_once
    assert_equal 1, SolidObjects::Message.find(first.id).result
    assert_equal 2, SolidObjects::Message.find(second.id).result
    assert_equal 2, SolidObjects::Message.find(first.id).attempt_count
    assert_empty SolidObjects::DeadLetter.all
  ensure
    worker&.stop
  end

  test "a stale worker cannot release a second worker's activation or repeat its commits" do
    first_worker = SolidObjects::Worker.new
    second_worker = SolidObjects::Worker.new
    first = Counter.ref("takeover").async.increment
    second = Counter.ref("takeover").async.increment
    Counter.before_commit = -> do
      Counter.before_commit = nil
      @clock[:now] += 0.22
      assert_equal 2, Thread.new { second_worker.run_once }.value
    end

    assert_equal 0, first_worker.run_once
    assert_equal 1, SolidObjects::Message.find(first.id).result
    assert_equal 2, SolidObjects::Message.find(second.id).result
    assert_equal 2, SolidObjects::Message.find(first.id).attempt_count
    assert_equal 2, @events.count("solid_objects.message.completed")
    third = Counter.ref("takeover").async.increment
    assert_equal 1, second_worker.run_once
    assert_equal 3, SolidObjects::Message.find(third.id).result
  ensure
    first_worker&.stop
    second_worker&.stop
  end

  private

  def instance
    SolidObjects::Instance.find_by!(actor_type: Counter.actor_type)
  end
end
