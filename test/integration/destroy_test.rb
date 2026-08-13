# frozen_string_literal: true

require "database_test_helper"
require "solid_objects/mailbox"
require "timeout"

class DestroyTest < ActiveSupport::TestCase
  class Counter < SolidObjects::Actor
    actor_type "destroy-counter"

    attribute :value, default: 0

    observable :value

    def increment(amount: 1)
      self.value += amount
    end

    def configure
      self.value += 1
      schedule(at: 1.hour.from_now).increment(amount: 1)
      emit :record_counter, value:, on_success: :recorded
    end

    def recorded(effect_id:, arguments:, result:)
      self.value += result.fetch("amount")
    end

    def poison
      raise "poison"
    end
  end

  class BlockingCounter < SolidObjects::Actor
    actor_type "destroy-blocking-counter"

    class << self
      attr_accessor :started, :release
    end

    attribute :value, default: 0

    def increment
      self.class.started << true
      self.class.release.pop
      self.value += 1
    end
  end

  class PausingReminderScheduler < SolidObjects::ReminderScheduler
    # @rbs (claimed: Thread::Queue, release: Thread::Queue) -> void
    def initialize(claimed:, release:)
      @claimed = claimed
      @release_queue = release
      super()
    end

    private

    attr_reader :claimed, :release_queue

    # @rbs (SolidObjects::Reminder, now: Time?) -> SolidObjects::MessageReference?
    def enqueue(reminder, now:)
      claimed << true
      release_queue.pop
      super
    end
  end

  class VanishingInstanceMailbox < SolidObjects::Mailbox
    private

    # @rbs (SolidObjects::Reference, Class) -> SolidObjects::Instance
    def find_or_create_instance(reference, actor_class)
      unless defined?(@instance_vanished)
        @instance_vanished = true
        raise ActiveRecord::RecordNotFound
      end

      super
    end
  end

  setup do
    SolidObjects.configuration.authorize_destroy = ->(**) { true }
    SolidObjects.configuration.max_attempts = 1
    BlockingCounter.started = Queue.new
    BlockingCounter.release = Queue.new
  end

  test "destroys the actor and all of its durable work" do
    reference = Counter.ref("global")
    reference.async.poison
    worker = SolidObjects::Worker.new
    worker.run_until_idle
    reference.async.configure
    worker.run_until_idle
    reference.async(available_at: 1.hour.from_now).increment(amount: 2)
    instance = SolidObjects::Instance.find_by!(
      actor_type: reference.actor_type,
      actor_id: reference.actor_id
    )
    instance_id = instance.id

    assert SolidObjects::DeadLetter.where(instance_id:).exists?
    assert SolidObjects::ReadyMessage.where(instance_id:).exists?
    assert SolidObjects::Reminder.where(instance_id:).exists?
    assert SolidObjects::Effect.where(instance_id:).exists?
    assert SolidObjects::Broadcast.where(instance_id:).exists?
    assert reference.destroy

    refute SolidObjects::Instance.where(id: instance_id).exists?
    assert_empty SolidObjects::Message.where(instance_id:)
    assert_empty SolidObjects::ReadyMessage.where(instance_id:)
    assert_empty SolidObjects::ClaimedMessage.where(instance_id:)
    assert_empty SolidObjects::Reminder.where(instance_id:)
    assert_empty SolidObjects::Effect.where(instance_id:)
    assert_empty SolidObjects::Broadcast.where(instance_id:)
    assert_empty SolidObjects::DeadLetter.where(instance_id:)
    refute reference.destroy
  ensure
    worker&.stop
  end

  test "authorizes destruction before revealing actor existence" do
    reference = Counter.ref("global")
    reference.increment
    authorization_context = Object.new
    received = nil
    SolidObjects.configuration.authorize_destroy = lambda do |**arguments|
      received = arguments
      false
    end

    assert_raises(SolidObjects::Unauthorized) do
      reference.destroy(authorization_context:)
    end

    assert_equal(
      {
        actor_type: "destroy-counter",
        actor_id: "global",
        authorization_context:
      },
      received
    )
    assert SolidObjects::Instance.where(
      actor_type: reference.actor_type,
      actor_id: reference.actor_id
    ).exists?
  end

  test "instruments committed destruction without actor state" do
    reference = Counter.ref("global")
    reference.increment
    event = nil
    subscription = ActiveSupport::Notifications.subscribe("solid_objects.actor.destroyed") do |notification|
      event = notification
    end

    assert reference.destroy

    assert_equal "destroy-counter", event.payload.fetch(:actor_type)
    assert_equal "global", event.payload.fetch(:actor_id)
    assert event.payload.fetch(:instance_id)
    refute event.payload.key?(:state)
  ensure
    ActiveSupport::Notifications.unsubscribe(subscription) if subscription
  end

  test "recreates a destroyed identity with fresh state and sequence" do
    reference = Counter.ref("global")
    original_message = reference.async.increment(amount: 5)
    worker = SolidObjects::Worker.new
    worker.run_until_idle
    original_instance = SolidObjects::Instance.find_by!(
      actor_type: reference.actor_type,
      actor_id: reference.actor_id
    )

    assert reference.destroy

    recreated_message = reference.async.increment(amount: 2)
    recreated_instance = SolidObjects::Instance.find_by!(
      actor_type: reference.actor_type,
      actor_id: reference.actor_id
    )
    worker.run_until_idle

    assert_not_equal original_instance.id, recreated_instance.id
    assert_equal 1, recreated_message.sequence
    assert_equal({ "value" => 2 }, recreated_instance.reload.state)
    refute SolidObjects::Message.where(id: original_message.id).exists?
  ensure
    worker&.stop
  end

  test "rejects a stale actor commit after destruction" do
    reference = BlockingCounter.ref("global")
    reference.async.increment
    worker = SolidObjects::Worker.new
    thread = Thread.new { worker.run_once }
    Timeout.timeout(2) { BlockingCounter.started.pop }

    assert reference.destroy

    BlockingCounter.release << true
    assert_equal 0, thread.value
    refute SolidObjects::Instance.where(
      actor_type: reference.actor_type,
      actor_id: reference.actor_id
    ).exists?
    assert_empty SolidObjects::Message.where(
      actor_type: reference.actor_type,
      actor_id: reference.actor_id
    )
  ensure
    BlockingCounter.release << true if thread&.alive?
    thread&.join
    worker&.stop
  end

  test "does not let a claimed reminder recreate a destroyed actor" do
    reference = Counter.ref("global")
    reference.async.configure
    worker = SolidObjects::Worker.new
    worker.run_until_idle
    SolidObjects::Reminder.first.update!(next_run_at: 1.second.ago)
    claimed = Queue.new
    release = Queue.new
    scheduler = PausingReminderScheduler.new(claimed:, release:)
    thread = Thread.new { scheduler.run_once }
    Timeout.timeout(2) { claimed.pop }

    assert reference.destroy

    release << true
    refute thread.value
    refute SolidObjects::Instance.where(
      actor_type: reference.actor_type,
      actor_id: reference.actor_id
    ).exists?
    assert_empty SolidObjects::Message.where(
      actor_type: reference.actor_type,
      actor_id: reference.actor_id
    )
  ensure
    release << true if thread&.alive?
    thread&.join
    scheduler&.stop
    worker&.stop
  end

  test "retries an enqueue when the instance disappears before locking" do
    reference = Counter.ref("global")
    message_reference = VanishingInstanceMailbox.new.enqueue(
      reference:,
      operation: :increment,
      arguments: { amount: 2 },
      delivery_mode: "async"
    )

    assert_equal 1, message_reference.sequence
    assert SolidObjects::Instance.where(
      actor_type: reference.actor_type,
      actor_id: reference.actor_id
    ).exists?
  end

  test "does not let an in-flight effect callback recreate the actor" do
    reference = Counter.ref("global")
    reference.async.configure
    worker = SolidObjects::Worker.new
    worker.run_until_idle
    instance_id = SolidObjects::Effect.first.instance_id
    started = Queue.new
    release = Queue.new
    SolidObjects.register_effect(:record_counter) do
      started << true
      release.pop
      { "amount" => 10 }
    end
    effect_executor = SolidObjects::EffectExecutor.new
    thread = Thread.new { effect_executor.run_once }
    Timeout.timeout(2) { started.pop }

    assert reference.destroy

    release << true
    refute thread.value
    refute SolidObjects::Instance.where(
      actor_type: reference.actor_type,
      actor_id: reference.actor_id
    ).exists?
    assert_empty SolidObjects::Effect.where(instance_id:)
    assert_empty SolidObjects::Message.where(
      actor_type: reference.actor_type,
      actor_id: reference.actor_id
    )
  ensure
    release << true if thread&.alive?
    thread&.join
    effect_executor&.stop
    worker&.stop
  end

  test "does not let an in-flight broadcast recreate the actor" do
    reference = Counter.ref("global")
    reference.async.increment
    worker = SolidObjects::Worker.new
    worker.run_until_idle
    instance_id = SolidObjects::Broadcast.first.instance_id
    started = Queue.new
    release = Queue.new
    SolidObjects.configuration.broadcast_adapter = lambda do |_broadcast|
      started << true
      release.pop
    end
    broadcast_executor = SolidObjects::BroadcastExecutor.new
    thread = Thread.new { broadcast_executor.run_once }
    Timeout.timeout(2) { started.pop }

    assert reference.destroy

    release << true
    refute thread.value
    refute SolidObjects::Instance.where(
      actor_type: reference.actor_type,
      actor_id: reference.actor_id
    ).exists?
    assert_empty SolidObjects::Broadcast.where(instance_id:)
  ensure
    release << true if thread&.alive?
    thread&.join
    broadcast_executor&.stop
    worker&.stop
  end

  test "wakes a sync caller when its actor is destroyed" do
    reference = Counter.ref("global")
    reference.async.increment
    instance = SolidObjects::Instance.find_by!(
      actor_type: reference.actor_type,
      actor_id: reference.actor_id
    )
    process_record = SolidObjects::Process.create!(
      id: SecureRandom.uuid,
      kind: "worker",
      hostname: "test-host",
      pid: ::Process.pid,
      started_at: Time.current,
      last_heartbeat_at: Time.current,
      metadata: {}
    )
    lease = SolidObjects::Lease.acquire(
      instance_id: instance.id,
      owner_id: process_record.id
    )
    enqueued = Queue.new
    subscription = ActiveSupport::Notifications.subscribe("solid_objects.message.enqueued") do |event|
      enqueued << true if event.payload[:actor_id] == reference.actor_id
    end
    result = Queue.new
    thread = Thread.new do
      reference.sync(timeout: 2).value
    rescue => error
      result << error
    end
    Timeout.timeout(2) { enqueued.pop }

    assert reference.destroy

    assert_instance_of SolidObjects::ActorDestroyed, Timeout.timeout(2) { result.pop }
  ensure
    ActiveSupport::Notifications.unsubscribe(subscription) if subscription
    thread&.join
    lease&.release
  end

  test "rejects synchronous destruction from actor context" do
    reference = Counter.ref("global")

    assert_raises(SolidObjects::ActorCallCycle) do
      SolidObjects::Context.with(actor: Object.new, message: nil) do
        reference.destroy
      end
    end

    assert_raises(SolidObjects::ActorCallCycle) do
      SolidObjects::Context.with(actor: Object.new, message: nil) do
        SolidObjects.client.destroy(reference)
      end
    end
  end
end
