# frozen_string_literal: true

require "database_test_helper"
require "timeout"

class SynchronousInvocationTest < ActiveSupport::TestCase
  class CounterActor < SolidObjects::Actor
    actor_type "synchronous-counter"

    attribute :value, default: 0

    def increment(amount: 1)
      self.value += amount
    end

    def increment_if(valid:)
      reject :validation_failed, "The increment is invalid", details: { reason: "invalid" } unless valid

      self.value += 1
    end
  end

  class BlockingActor < SolidObjects::Actor
    actor_type "synchronous-blocking"

    class << self
      attr_accessor :started, :release
    end

    attribute :values, default: -> { [] }

    def append(value:)
      self.class.started << [ actor_id, value ]
      self.class.release.pop
      values << value
      values
    end
  end

  class IntentActor < SolidObjects::Actor
    actor_type "synchronous-intents"

    def configure(target_id:)
      schedule :refresh, at: 1.hour.from_now, arguments: {}
      emit :record_configuration
      CounterActor.ref(target_id).async(:increment)
    end

    def refresh
    end
  end

  class RetryingActor < SolidObjects::Actor
    actor_type "synchronous-retrying"

    attribute :executions, default: 0

    def run
      self.executions += 1
      raise "first attempt" if current_message.attempt == 1

      executions
    end

    def fail
      raise "permanent failure"
    end
  end

  class BlockingWakeUp
    # @rbs @waiting: Thread::Queue
    # @rbs @release: Thread::Queue

    attr_reader :waiting, :release

    # @rbs () -> void
    def initialize
      @waiting = Queue.new
      @release = Queue.new
    end

    # @rbs () -> void
    def signal
    end

    # @rbs (timeout: Numeric) -> void
    def wait(timeout:)
      waiting << timeout
      release.pop
    end
  end

  setup do
    BlockingActor.started = Queue.new
    BlockingActor.release = Queue.new
  end

  test "direct actor method durably executes without a worker" do
    result = CounterActor.ref("global").increment(amount: 2)

    message = SolidObjects::Message.find_by!(
      actor_type: "synchronous-counter",
      actor_id: "global"
    )
    instance = message.instance

    assert_equal 2, result
    assert_equal "sync", message.message_kind
    assert message.completed?
    assert_equal({ "value" => 2 }, instance.state)
    assert_empty SolidObjects::ReadyMessage.all
    assert_empty SolidObjects::ClaimedMessage.all
  end

  test "sync explicitly invokes an actor method" do
    result = CounterActor.ref("explicit").sync(:increment, amount: 3)

    assert_equal 3, result
    assert_equal(
      { "value" => 3 },
      SolidObjects::Instance.find_by!(
        actor_type: "synchronous-counter",
        actor_id: "explicit"
      ).state
    )
  end

  test "async durably enqueues and returns immediately" do
    reference = CounterActor.ref("later")

    message_reference = reference.async(:increment, amount: 4)

    assert_instance_of SolidObjects::MessageReference, message_reference
    assert_equal "ready", message_reference.status
    assert_equal(
      {},
      SolidObjects::Instance.find_by!(
        actor_type: "synchronous-counter",
        actor_id: "later"
      ).state
    )

    worker = SolidObjects::Worker.new
    worker.run_until_idle

    assert_equal "completed", message_reference.status
    assert_equal(
      { "value" => 4 },
      SolidObjects::Instance.find_by!(
        actor_type: "synchronous-counter",
        actor_id: "later"
      ).state
    )
  ensure
    worker&.stop
  end

  test "sync drains earlier asynchronous messages in sequence" do
    reference = CounterActor.ref("ordered")
    first_message = reference.async(:increment, amount: 2)

    result = reference.increment(amount: 3)

    messages = SolidObjects::Message
      .where(actor_type: "synchronous-counter", actor_id: "ordered")
      .order(:sequence)

    assert_equal 5, result
    assert_equal "completed", first_message.status
    assert_equal [ "async", "sync" ], messages.pluck(:message_kind)
    assert_equal [ 1, 2 ], messages.pluck(:sequence)
  end

  test "sync does not steal an unexpired activation" do
    reference = CounterActor.ref("leased")
    reference.async(:increment)
    instance = SolidObjects::Instance.find_by!(
      actor_type: "synchronous-counter",
      actor_id: "leased"
    )
    process_record = create_process
    lease = SolidObjects::Lease.acquire(
      instance_id: instance.id,
      owner_id: process_record.id,
      activation_token: SecureRandom.uuid
    )

    assert_raises(SolidObjects::SyncTimeout) do
      reference.sync(:increment, timeout: 0.01)
    end

    assert_equal process_record.id, instance.reload.activation_owner_id
    assert_equal 2, SolidObjects::ReadyMessage.where(instance:).count
  ensure
    lease&.release
  end

  test "concurrent sync calls for one actor execute sequentially" do
    wake_up = BlockingWakeUp.new
    SolidObjects.configuration.wake_up_adapter = wake_up
    reference = BlockingActor.ref("same")
    results = Queue.new

    first_thread = Thread.new { results << reference.append(value: 1) }
    assert_equal [ "same", 1 ], Timeout.timeout(2) { BlockingActor.started.pop }

    second_thread = Thread.new { results << reference.append(value: 2) }
    Timeout.timeout(2) { wake_up.waiting.pop }

    assert_raises(ThreadError) { BlockingActor.started.pop(true) }
    assert_equal 1, SolidObjects::ClaimedMessage.count
    assert_equal 1, SolidObjects::ReadyMessage.count

    BlockingActor.release << true
    first_thread.join
    wake_up.release << true
    assert_equal [ "same", 2 ], Timeout.timeout(2) { BlockingActor.started.pop }
    BlockingActor.release << true
    second_thread.join

    assert_equal [ [ 1 ], [ 1, 2 ] ], 2.times.map { results.pop }
  ensure
    BlockingActor.release << true if first_thread&.alive?
    BlockingActor.release << true if second_thread&.alive?
    wake_up&.release&.push(true) if second_thread&.alive?
    first_thread&.join
    second_thread&.join
  end

  test "concurrent sync calls for different actors execute together" do
    results = Queue.new
    threads = [
      Thread.new { results << BlockingActor.ref("alice").append(value: 1) },
      Thread.new { results << BlockingActor.ref("bob").append(value: 2) }
    ]

    started = 2.times.map { Timeout.timeout(2) { BlockingActor.started.pop } }

    assert_equal [ [ "alice", 1 ], [ "bob", 2 ] ], started.sort

    2.times { BlockingActor.release << true }
    threads.each(&:join)

    assert_equal [ [ 1 ], [ 2 ] ], 2.times.map { results.pop }.sort
  ensure
    threads&.count { |thread| thread.alive? }&.times { BlockingActor.release << true }
    threads&.each(&:join)
  end

  test "sync reuses an idempotent committed result" do
    reference = CounterActor.ref("idempotent")

    first_result = reference.sync(
      :increment,
      amount: 2,
      idempotency_key: "increment-once"
    )
    second_result = reference.sync(
      :increment,
      amount: 2,
      idempotency_key: "increment-once"
    )

    assert_equal 2, first_result
    assert_equal first_result, second_result
    assert_equal 1, SolidObjects::Message.where(instance: actor_instance("idempotent")).count
    assert_equal({ "value" => 2 }, actor_instance("idempotent").state)
  end

  test "actor intents commit without leaking internal return values" do
    result = IntentActor.ref("configured").configure(target_id: "target")

    assert_nil result
    assert SolidObjects::Reminder.where(
      actor_type: "synchronous-intents",
      actor_id: "configured",
      name: "refresh"
    ).exists?
    assert_equal(
      [ "__actor_message__", "record_configuration" ],
      SolidObjects::Effect.order(:name).pluck(:name)
    )
  end

  test "reject is terminal and rolls back actor state" do
    events = []
    subscription = ActiveSupport::Notifications.subscribe("solid_objects.message.rejected") do |event|
      events << event.payload
    end

    error = assert_raises(SolidObjects::Rejected) do
      CounterActor.ref("rejected").increment_if(valid: false)
    end

    message = SolidObjects::Message.find_by!(
      actor_type: "synchronous-counter",
      actor_id: "rejected"
    )

    assert_equal "validation_failed", error.code
    assert_equal "The increment is invalid", error.message
    assert_equal({ "reason" => "invalid" }, error.details)
    assert_equal message.id, error.message_id
    assert message.rejected?
    assert message.completed?
    assert_equal 1, message.attempt_count
    assert_equal(
      {
        "code" => "validation_failed",
        "message" => "The increment is invalid",
        "details" => { "reason" => "invalid" }
      },
      message.rejection
    )
    assert_equal({}, message.instance.state)
    assert_nil message.dead_letter
    assert_empty SolidObjects::ReadyMessage.all
    assert_empty SolidObjects::ClaimedMessage.all
    assert_equal "validation_failed", events.fetch(0).fetch(:code)
  ensure
    ActiveSupport::Notifications.unsubscribe(subscription) if subscription
  end

  test "sync retries infrastructure failures and returns the committed result" do
    SolidObjects.configuration.retry_delay = ->(_attempt) { 0 }

    result = RetryingActor.ref("eventual").run
    message = SolidObjects::Message.find_by!(
      actor_type: "synchronous-retrying",
      actor_id: "eventual"
    )

    assert_equal 1, result
    assert_equal 2, message.attempt_count
    assert message.completed?
    assert_equal({ "executions" => 1 }, message.instance.state)
  end

  test "sync raises after the message is dead lettered" do
    SolidObjects.configuration.max_attempts = 2
    SolidObjects.configuration.retry_delay = ->(_attempt) { 0 }

    error = assert_raises(SolidObjects::MessageFailed) do
      RetryingActor.ref("failed").fail
    end
    message = SolidObjects::Message.find(error.message_id)

    assert_equal "dead", SolidObjects::MessageReference.from_message(message).status
    assert_equal 2, message.attempt_count
    assert_equal "RuntimeError", error.details.fetch("class")
    assert message.dead_letter
  end

  test "async rejection is observable without retry or dead letter" do
    message_reference = CounterActor.ref("async-rejected").async(:increment_if, valid: false)
    worker = SolidObjects::Worker.new

    assert_equal 1, worker.run_until_idle
    assert_equal "rejected", message_reference.status
    assert_equal "validation_failed", SolidObjects::Message.find(message_reference.id).rejection.fetch("code")
    assert_empty SolidObjects::DeadLetter.all
  ensure
    worker&.stop
  end

  private

  def actor_instance(actor_id)
    SolidObjects::Instance.find_by!(
      actor_type: "synchronous-counter",
      actor_id:
    )
  end

  def create_process
    SolidObjects::Process.create!(
      id: SecureRandom.uuid,
      kind: "worker",
      hostname: "test-host",
      pid: ::Process.pid,
      started_at: Time.current,
      last_heartbeat_at: Time.current,
      metadata: {}
    )
  end
end
