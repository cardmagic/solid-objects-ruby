# frozen_string_literal: true

require "database_test_helper"
require "solid_objects/mailbox"
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

  class DomainWritingActor < SolidObjects::Actor
    actor_type "synchronous-domain-writing"

    attribute :completed, default: false

    def persist_domain_record(name:)
      SolidObjectsTestDomainRecord.create!(name:)
      self.completed = true
    end

    def persist_atomically(name:)
      self.completed = true
      commit_action :create_domain_record, name:
    end

    def persist_then_fail(name:)
      self.completed = true
      commit_action :create_domain_record_then_fail, name:
    end
  end

  class DeadlineActor < SolidObjects::Actor
    actor_type "synchronous-deadline"

    class << self
      attr_accessor :reached, :continue
    end

    attribute :value, default: 0

    def run
      self.class.reached << actor_id
      self.class.continue.pop
      self.value += 1
    end
  end

  class LockRetryActor < SolidObjects::Actor
    actor_type "synchronous-lock-retry"

    class << self
      attr_accessor :executions
    end

    attribute :value, default: 0

    def increment
      self.class.executions += 1
      self.value += 1
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
    DeadlineActor.reached = Queue.new
    DeadlineActor.continue = Queue.new
    LockRetryActor.executions = 0
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

  test "sync fails before enqueue inside an ambient transaction" do
    events = []
    subscription = ActiveSupport::Notifications.subscribe(
      "solid_objects.sync.transaction_rejected"
    ) { |event| events << event.payload }

    error = SolidObjects::Record.transaction do
      assert_raises(SolidObjects::SyncInsideTransaction) do
        CounterActor.ref("transactional").increment
      end
    end

    assert_equal "synchronous-counter", error.actor_type
    assert_equal "transactional", error.actor_id
    assert_equal "increment", error.message_name
    assert_empty SolidObjects::Message.where(
      actor_type: "synchronous-counter",
      actor_id: "transactional"
    )
    assert_predicate events, :one?
    assert_equal "synchronous-counter", events.first.fetch(:actor_type)
    assert_equal "increment", events.first.fetch(:message_name)
  ensure
    ActiveSupport::Notifications.unsubscribe(subscription) if subscription
  end

  test "handler application writes are rejected before they persist" do
    SolidObjects.configuration.retry_delay = ->(_attempt) { 0 }

    error = assert_raises(SolidObjects::MessageFailed) do
      DomainWritingActor.ref("isolated").persist_domain_record(name: "escaped")
    end
    message = SolidObjects::Message.find(error.message_id)

    assert_empty SolidObjectsTestDomainRecord.all
    assert_equal "SolidObjects::ApplicationWriteForbidden", error.details.fetch("class")
    assert_equal({}, message.instance.state)
    assert message.dead?
    assert_equal 1, message.attempt_count
  end

  test "registered commit actions persist application writes with actor state" do
    events = []
    subscription = ActiveSupport::Notifications.subscribe(
      /\Asolid_objects\.commit_action\./
    ) { |event| events << [ event.name, event.payload ] }
    SolidObjects.register_commit_action(:create_domain_record) do |arguments, context|
      SolidObjectsTestDomainRecord.create!(name: arguments.fetch("name"))
      assert_equal "synchronous-domain-writing", context.actor_type
      assert_equal "isolated", context.actor_id
    end

    DomainWritingActor.ref("isolated").persist_atomically(name: "committed")

    assert_equal [ "committed" ], SolidObjectsTestDomainRecord.pluck(:name)
    assert_equal(
      { "completed" => true },
      SolidObjects::Instance.find_by!(
        actor_type: "synchronous-domain-writing",
        actor_id: "isolated"
      ).state
    )
    assert_equal(
      [
        "solid_objects.commit_action.started",
        "solid_objects.commit_action.completed"
      ],
      events.map(&:first)
    )
    assert events.all? { |_name, payload| payload.fetch(:commit_action_name) == "create_domain_record" }
    assert events.none? { |_name, payload| payload.key?(:arguments) }
  ensure
    ActiveSupport::Notifications.unsubscribe(subscription) if subscription
  end

  test "failing commit actions roll back application writes and actor state" do
    events = []
    subscription = ActiveSupport::Notifications.subscribe(
      "solid_objects.commit_action.failed"
    ) { |event| events << event.payload }
    SolidObjects.configuration.max_attempts = 1
    SolidObjects.register_commit_action(:create_domain_record_then_fail) do |arguments, _context|
      SolidObjectsTestDomainRecord.create!(name: arguments.fetch("name"))
      raise "commit action failed"
    end

    assert_raises(SolidObjects::MessageFailed) do
      DomainWritingActor.ref("rolled-back").persist_then_fail(name: "escaped")
    end

    assert_empty SolidObjectsTestDomainRecord.all
    assert_equal(
      {},
      SolidObjects::Instance.find_by!(
        actor_type: "synchronous-domain-writing",
        actor_id: "rolled-back"
      ).state
    )
    assert_predicate events, :one?
    assert_equal "RuntimeError", events.first.fetch(:error_class)
    assert_equal "create_domain_record_then_fail", events.first.fetch(:commit_action_name)
  ensure
    ActiveSupport::Notifications.unsubscribe(subscription) if subscription
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

    error = assert_raises(SolidObjects::SyncTimeout) do
      reference.sync(:increment, timeout: 0.01)
    end

    timed_out_message = SolidObjects::Message.find(error.message_id)
    assert_equal "synchronous-counter", error.actor_type
    assert_equal "leased", error.actor_id
    assert_equal "increment", error.message_name
    assert_equal timed_out_message.request_id, error.request_id
    assert_equal timed_out_message.sequence, error.sequence
    assert_equal "ready", error.status
    assert_equal "activation_held", error.waiting_on
    assert_equal process_record.id, error.activation.fetch("owner_id")
    assert_equal "worker", error.activation.fetch("process").fetch("kind")
    assert_equal "test-host", error.activation.fetch("process").fetch("hostname")
    assert_equal 1, error.blocker.fetch("sequence")
    assert_equal "increment", error.blocker.fetch("message_name")
    assert_includes error.message, "synchronous-counter(\"leased\").increment"
    assert_includes error.message, "waiting_on=activation_held"
    assert_equal process_record.id, instance.reload.activation_owner_id
    assert_equal 2, SolidObjects::ReadyMessage.where(instance:).count

    assert_equal error.message_id, error.message_reference.id
    assert_equal error.request_id, error.message_reference.request_id

    lease.release
    lease = nil

    assert_equal 2, error.message_reference.wait(timeout: 1)
  ensure
    lease&.release
  end

  test "message reference wait enforces invocation authorization" do
    message_reference = CounterActor.ref("protected").async(:increment)
    SolidObjects.configuration.authorize_message = ->(**) { false }

    assert_raises(SolidObjects::Unauthorized) do
      message_reference.wait(timeout: 1)
    end
    assert_equal "ready", message_reference.status
  end

  test "sync database lock waits are bounded by the invocation deadline" do
    reference = DeadlineActor.ref("locked")
    message_reference = SolidObjects::Mailbox.new.enqueue(
      reference,
      :run,
      {},
      kind: "sync"
    )
    result = Queue.new
    invocation = Thread.new do
      result << capture_exception do
        SolidObjects::SynchronousInvocation.new.call(message_reference, timeout: 0.25)
      end
    end

    assert_equal "locked", Timeout.timeout(2) { DeadlineActor.reached.pop }
    instance = SolidObjects::Instance.find_by!(
      actor_type: "synchronous-deadline",
      actor_id: "locked"
    )
    locked = Queue.new
    release_lock = Queue.new
    blocker = Thread.new do
      SolidObjects::Record.connection_pool.with_connection do
        SolidObjects::Record.transaction do
          instance = SolidObjects::Instance.find(instance.id)
          instance.update!(updated_at: Time.current)
          locked << true
          release_lock.pop
        end
      end
    end
    Timeout.timeout(2) { locked.pop }

    started_at = monotonic_now
    DeadlineActor.continue << true
    error = Timeout.timeout(2) { result.pop }
    elapsed = monotonic_now - started_at

    assert_instance_of SolidObjects::SyncTimeout, error
    assert_operator elapsed, :<, 1.5
    assert_equal message_reference.id, error.message_id
  ensure
    DeadlineActor.continue << true if invocation&.alive?
    release_lock&.push(true)
    blocker&.join
    invocation&.join
  end

  test "sync bounds database lock waits while durably enqueueing" do
    reference = CounterActor.ref("enqueue-locked")
    reference.increment
    instance = actor_instance("enqueue-locked")
    locked = Queue.new
    release_lock = Queue.new
    blocker = Thread.new do
      SolidObjects::Record.connection_pool.with_connection do
        SolidObjects::Record.transaction do
          locked_instance = SolidObjects::Instance.find(instance.id)
          locked_instance.update!(updated_at: Time.current)
          locked << true
          release_lock.pop
        end
      end
    end
    Timeout.timeout(2) { locked.pop }
    message_count = SolidObjects::Message.count
    started_at = monotonic_now

    error = assert_raises(SolidObjects::SyncEnqueueTimeout) do
      reference.sync(:increment, timeout: 0.25)
    end

    assert_operator monotonic_now - started_at, :<, 1.5
    assert_equal "synchronous-counter", error.actor_type
    assert_equal "enqueue-locked", error.actor_id
    assert_equal "increment", error.message_name
    assert_equal message_count, SolidObjects::Message.count
  ensure
    release_lock&.push(true)
    blocker&.join
  end

  test "sync bounds SQLite contention while registering its caller process" do
    skip unless SolidObjects::Record.connection.adapter_name.match?(/sqlite/i)

    message_reference = SolidObjects::Mailbox.new.enqueue(
      LockRetryActor.ref("registration"),
      :increment,
      {},
      kind: "sync"
    )
    lock = hold_sqlite_write_lock

    error, elapsed = invoke_with_immediate_sqlite_lock_failure(message_reference)

    assert_instance_of SolidObjects::SyncTimeout, error
    assert_equal message_reference.id, error.message_id
    assert_operator elapsed, :<, 0.5
    assert_equal 0, LockRetryActor.executions

    release_sqlite_write_lock(lock)
    lock = nil

    assert_equal 1, message_reference.wait(timeout: 1)
    assert_equal 1, LockRetryActor.executions
  ensure
    release_sqlite_write_lock(lock) if lock
  end

  test "sync bounds SQLite contention while reusing and heartbeating its caller process" do
    skip unless SolidObjects::Record.connection.adapter_name.match?(/sqlite/i)

    SolidObjects.configuration.process_heartbeat_interval = 0
    process_record = SolidObjects.caller_process.process_registry.process_record
    message_reference = SolidObjects::Mailbox.new.enqueue(
      LockRetryActor.ref("heartbeat"),
      :increment,
      {},
      kind: "sync"
    )
    lock = hold_sqlite_write_lock

    error, elapsed = invoke_with_immediate_sqlite_lock_failure(message_reference)

    assert_instance_of SolidObjects::SyncTimeout, error
    assert_equal message_reference.id, error.message_id
    assert_operator elapsed, :<, 0.5
    assert_equal 0, LockRetryActor.executions

    release_sqlite_write_lock(lock)
    lock = nil

    assert_equal process_record.id, SolidObjects.caller_process.process_registry.process_record.id
    assert_equal 1, message_reference.wait(timeout: 1)
    assert_equal 1, LockRetryActor.executions
  ensure
    release_sqlite_write_lock(lock) if lock
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

  test "concurrent synchronous executions for different actors run together" do
    mailbox = SolidObjects::Mailbox.new
    message_references = [
      mailbox.enqueue(
        BlockingActor.ref("alice"),
        :append,
        { value: 1 },
        kind: "sync"
      ),
      mailbox.enqueue(
        BlockingActor.ref("bob"),
        :append,
        { value: 2 },
        kind: "sync"
      )
    ]
    results = Queue.new
    threads = message_references.map do |message_reference|
      Thread.new { results << message_reference.wait }
    end

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

  def capture_exception
    yield
  rescue => error
    error
  end

  def monotonic_now
    ::Process.clock_gettime(::Process::CLOCK_MONOTONIC)
  end

  def hold_sqlite_write_lock
    locked = Queue.new
    release = Queue.new
    thread = Thread.new do
      SolidObjects::Record.connection_pool.with_connection do
        SolidObjects::Record.transaction do
          SolidObjects::Process.create!(
            id: SecureRandom.uuid,
            kind: "lock-holder",
            hostname: "test-host",
            pid: ::Process.pid,
            started_at: Time.current,
            last_heartbeat_at: Time.current,
            metadata: {}
          )
          locked << true
          release.pop
        end
      end
    end
    Timeout.timeout(2) { locked.pop }
    [ thread, release ]
  end

  def release_sqlite_write_lock(lock)
    thread, release = lock
    release << true
    thread.join
  end

  def invoke_with_immediate_sqlite_lock_failure(message_reference)
    result = Queue.new
    invocation = Thread.new do
      error = nil
      elapsed = nil
      SolidObjects::Record.connection_pool.with_connection do |connection|
        previous_timeout = connection.select_value("PRAGMA busy_timeout").to_i
        connection.execute("PRAGMA busy_timeout = 0")
        started_at = monotonic_now
        error = capture_exception do
          SolidObjects::SynchronousInvocation.new.call(message_reference, timeout: 0.1)
        end
        elapsed = monotonic_now - started_at
      ensure
        connection.execute("PRAGMA busy_timeout = #{previous_timeout}")
      end
      result << [ error, elapsed ]
    end
    captured = Timeout.timeout(2) { result.pop }
    invocation.join
    captured
  end

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
