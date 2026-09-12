# rbs_inline: enabled

require "database_test_helper"
require "timeout"

class PostCommitTest < ActiveSupport::TestCase
  class CallbackFailure < StandardError
  end

  class CallbackRecord < SolidObjectsTestDomainRecord
    # @rbs @commit_callback: Proc?
    # @rbs @before_commit_callback: Proc?

    attr_accessor :commit_callback, :before_commit_callback

    before_commit :run_before_commit_callback
    after_commit :run_commit_callback

    # @rbs () -> void
    def run_before_commit_callback
      before_commit_callback&.call
    end

    # @rbs () -> void
    def run_commit_callback
      commit_callback&.call
    end
  end

  class Counter < SolidObjects::Actor
    actor_type "post-commit-counter"

    attribute :count, default: 0

    class << self
      # @rbs @before_increment: Proc?

      attr_accessor :before_increment
    end

    # @rbs () -> Integer
    def increment
      self.class.before_increment&.call
      self.count += 1
      commit_action(:write_counter, count:)
      count
    end
  end

  class WaitingWakeUp
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
      waiting << true
      release.pop
    end
  end

  test "caller assistance exposes the original after commit error and preserves the completed turn" do
    failure = CallbackFailure.new("distinctive committed callback failure")
    SolidObjects.register_commit_action(:write_counter) do |arguments, _context|
      CallbackRecord.create!(name: arguments.fetch("count").to_s, commit_callback: -> { raise failure })
    end

    error = assert_raises(StandardError) { Counter.ref("inline").increment }

    assert_equal [ "1" ], CallbackRecord.pluck(:name)
    instance = SolidObjects::Instance.sole
    assert_equal({ "count" => 1 }, instance.state)
    message = SolidObjects::Message.sole
    assert message.completed?
    assert_equal 1, message.result
    assert_equal 1, message.attempt_count
    assert_nil message.error
    assert_nil message.rejected_at
    assert_nil message.last_failed_at
    assert_empty SolidObjects::ReadyMessage.all
    assert_empty SolidObjects::ClaimedMessage.all
    assert_empty SolidObjects::DeadLetter.all
    assert_nil instance.activation_owner_id
    assert_instance_of CallbackFailure, error
    assert_same failure, error
    assert_equal "distinctive committed callback failure", error.message
    assert error.backtrace.any? { |line| line.include?("run_commit_callback") }
  end

  test "a rejection raised after commit remains a callback error instead of a domain outcome" do
    failure = SolidObjects::Rejected.new(code: "callback", message: "rejected after commitment")
    SolidObjects.register_commit_action(:write_counter) do |arguments, _context|
      CallbackRecord.create!(name: arguments.fetch("count").to_s, commit_callback: -> { raise failure })
    end

    error = assert_raises(StandardError) { Counter.ref("rejection").increment }

    assert_same failure, error
    assert_nil SolidObjects::Message.sole.rejected_at
    assert_equal 1, SolidObjects::Message.sole.result
    assert_equal({ "count" => 1 }, SolidObjects::Instance.sole.state)
    assert_empty SolidObjects::DeadLetter.all
  end

  test "a successful callback runs outside the transaction and later messages advance the same actor" do
    depths = []
    SolidObjects.register_commit_action(:write_counter) do |arguments, _context|
      CallbackRecord.create!(name: arguments.fetch("count").to_s,
        commit_callback: -> { depths << ActiveRecord::Base.connection.open_transactions })
    end
    reference = Counter.ref("success")

    assert_equal 1, reference.sync(idempotency_key: "once").increment
    assert_equal 1, reference.sync(idempotency_key: "once").increment
    assert_equal 2, reference.increment
    assert_equal [ 0, 0 ], depths
    assert_equal [ "1", "2" ], CallbackRecord.order(:id).pluck(:name)
    assert_equal [ 1, 2 ], SolidObjects::Message.order(:sequence).pluck(:result)
    assert_equal({ "count" => 2 }, SolidObjects::Instance.sole.state)
  end

  test "a before commit callback failure rolls back even after the fenced block finishes" do
    SolidObjects.configuration.max_attempts = 1
    SolidObjects.register_commit_action(:write_counter) do |arguments, _context|
      CallbackRecord.create!(name: arguments.fetch("count").to_s,
        before_commit_callback: -> { raise CallbackFailure, "failed before SQL commit" })
    end

    error = assert_raises(SolidObjects::MessageFailed) { Counter.ref("before").increment }

    assert_equal "PostCommitTest::CallbackFailure", error.details.fetch("class")
    assert_equal "failed before SQL commit", error.details.fetch("message")
    assert_empty CallbackRecord.all
    assert_equal({}, SolidObjects::Instance.sole.state)
    message = SolidObjects::Message.sole
    refute message.completed?
    assert message.dead?
    assert_nil message.result
    assert_equal 1, message.attempt_count
    assert_empty SolidObjects::ReadyMessage.all
    assert_empty SolidObjects::ClaimedMessage.all
    assert_equal 1, SolidObjects::DeadLetter.count
  end

  test "a rolled back callback retries from the previous actor state" do
    attempts = 0
    SolidObjects.configuration.max_attempts = 2
    SolidObjects.configuration.retry_delay = ->(_attempt) { 0 }
    SolidObjects.register_commit_action(:write_counter) do |arguments, _context|
      attempts += 1
      CallbackRecord.create!(name: arguments.fetch("count").to_s,
        before_commit_callback: -> { raise CallbackFailure, "retry before commit" if attempts == 1 })
    end

    assert_equal 1, Counter.ref("retry").increment
    assert_equal 2, attempts
    assert_equal [ "1" ], CallbackRecord.pluck(:name)
    assert_equal({ "count" => 1 }, SolidObjects::Instance.sole.state)
    assert_equal 2, SolidObjects::Message.sole.attempt_count
    assert_nil SolidObjects::Message.sole.error
    assert_empty SolidObjects::DeadLetter.all
  end

  test "a rejection before commit rolls back and lets the next message proceed" do
    SolidObjects.register_commit_action(:write_counter) do |arguments, _context|
      CallbackRecord.create!(name: arguments.fetch("count").to_s,
        before_commit_callback: -> { raise SolidObjects::Rejected.new(code: "invalid", message: "before commit") })
    end
    reference = Counter.ref("domain")

    error = assert_raises(SolidObjects::Rejected) { reference.increment }
    assert_equal "invalid", error.code
    assert SolidObjects::Message.sole.rejected?
    assert_nil SolidObjects::Message.sole.result
    assert_equal({}, SolidObjects::Instance.sole.state)
    assert_empty CallbackRecord.all
    assert_empty SolidObjects::DeadLetter.all

    SolidObjects.register_commit_action(:write_counter) do |arguments, _context|
      CallbackRecord.create!(name: arguments.fetch("count").to_s)
    end
    assert_equal 1, reference.increment
  end

  test "a waiting caller receives completion before a separate worker exposes its callback failure" do
    started = Queue.new
    run_handler = Queue.new
    committed = Queue.new
    run_callback = Queue.new
    wake_up = WaitingWakeUp.new
    SolidObjects.configuration.wake_up_adapter = wake_up
    Counter.before_increment = lambda do
      started << true
      run_handler.pop
    end
    failure = CallbackFailure.new("worker callback failed after caller returned")
    SolidObjects.register_commit_action(:write_counter) do |arguments, _context|
      callback = lambda do
        next unless arguments.fetch("count") == 1

        committed << true
        run_callback.pop
        raise failure
      end
      CallbackRecord.create!(name: arguments.fetch("count").to_s, commit_callback: callback)
    end
    reference = Counter.ref("worker")
    message_reference = SolidObjects::Mailbox.new.enqueue(
      reference:, operation: :increment, arguments: {}, delivery_mode: "sync"
    )
    worker = SolidObjects::Worker.new
    worker_thread = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection { worker.run_once }
    rescue => error
      error
    end
    Timeout.timeout(10) { started.pop }
    caller_thread = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection { message_reference.wait(timeout: 10) }
    end
    Timeout.timeout(10) { wake_up.waiting.pop }
    run_handler << true
    Timeout.timeout(10) { committed.pop }
    wake_up.release << true

    assert_equal 1, Timeout.timeout(10) { caller_thread.value }
    assert worker_thread.alive?
    run_callback << true
    assert_same failure, Timeout.timeout(10) { worker_thread.value }
    assert failure.backtrace.any? { |line| line.include?("run_commit_callback") }
    message = SolidObjects::Message.find(message_reference.id)
    assert message.completed?
    assert_equal 1, message.result
    assert_equal 1, message.attempt_count
    assert_nil message.error
    assert_nil message.last_failed_at
    assert_nil message.rejected_at
    assert_empty SolidObjects::ReadyMessage.all
    assert_empty SolidObjects::ClaimedMessage.all
    assert_empty SolidObjects::DeadLetter.all

    Counter.before_increment = nil
    reference.async.increment
    assert_equal 1, worker.run_once
    assert_equal [ "1", "2" ], CallbackRecord.order(:id).pluck(:name)
    assert_equal({ "count" => 2 }, SolidObjects::Instance.sole.state)
    assert_equal [ 1, 1 ], SolidObjects::Message.order(:sequence).pluck(:attempt_count)
  ensure
    Counter.before_increment = nil
    run_handler&.push(true)
    run_callback&.push(true)
    wake_up&.release&.push(true)
    Timeout.timeout(10) do
      worker_thread&.join
      caller_thread&.join
    end
    worker&.stop
  end

  test "a lost activation exception from an after commit callback escapes the worker unchanged" do
    failure = SolidObjects::LostActivation.new("callback raised lost activation after commit")
    SolidObjects.register_commit_action(:write_counter) do |arguments, _context|
      CallbackRecord.create!(name: arguments.fetch("count").to_s, commit_callback: -> { raise failure })
    end
    reference = Counter.ref("lost")
    reference.async.increment
    worker = SolidObjects::Worker.new

    error = assert_raises(SolidObjects::LostActivation) { worker.run_once }

    assert_same failure, error
    assert SolidObjects::Message.sole.completed?
    assert_nil SolidObjects::Message.sole.error
    assert_equal({ "count" => 1 }, SolidObjects::Instance.sole.state)
    assert_empty SolidObjects::DeadLetter.all
  ensure
    worker&.stop
  end

  test "a deadline exception after commit is not retried or replaced by caller coordination" do
    failure = SolidObjects::DatabaseDeadlineExceeded.new("callback deadline after commit")
    SolidObjects.register_commit_action(:write_counter) do |arguments, _context|
      CallbackRecord.create!(name: arguments.fetch("count").to_s, commit_callback: -> { raise failure })
    end

    error = assert_raises(StandardError) { Counter.ref("deadline").increment }

    assert_same failure, error
    assert_equal [ "1" ], CallbackRecord.pluck(:name)
    assert_equal 1, SolidObjects::Message.sole.result
    assert_equal 1, SolidObjects::Message.sole.attempt_count
    assert_empty SolidObjects::DeadLetter.all
  end

  test "caller assistance never retries a database busy error raised after commit" do
    failure = if database_family == :sqlite
      SQLite3::BusyException.new("callback database busy after commit")
    else
      ActiveRecord::LockWaitTimeout.new("callback database busy after commit")
    end
    SolidObjects.register_commit_action(:write_counter) do |arguments, _context|
      CallbackRecord.create!(name: arguments.fetch("count").to_s, commit_callback: -> { raise failure })
    end

    error = assert_raises(StandardError) { Counter.ref("busy").increment }

    assert_same failure, error
    assert_equal [ "1" ], CallbackRecord.pluck(:name)
    assert_equal 1, SolidObjects::Message.sole.result
    assert_nil SolidObjects::Message.sole.error
    assert_empty SolidObjects::ReadyMessage.all
    assert_empty SolidObjects::DeadLetter.all
  end

  test "a worker never retries a database busy error raised after commit" do
    failure = if database_family == :sqlite
      SQLite3::BusyException.new("worker callback database busy after commit")
    else
      ActiveRecord::LockWaitTimeout.new("worker callback database busy after commit")
    end
    SolidObjects.register_commit_action(:write_counter) do |arguments, _context|
      CallbackRecord.create!(name: arguments.fetch("count").to_s, commit_callback: -> { raise failure })
    end
    Counter.ref("worker-busy").async.increment
    worker = SolidObjects::Worker.new

    error = assert_raises(StandardError) { worker.run_once }

    assert_same failure, error
    assert_equal [ "1" ], CallbackRecord.pluck(:name)
    assert SolidObjects::Message.sole.completed?
    assert_nil SolidObjects::Message.sole.error
    assert_empty SolidObjects::ReadyMessage.all
    assert_empty SolidObjects::DeadLetter.all
  ensure
    worker&.stop
  end

  test "caller cleanup preserves a callback record lookup error and its original cause" do
    original_cause = CallbackFailure.new("original callback cause")
    failure = ActiveRecord::RecordNotFound.new("callback record missing after commit")
    SolidObjects.register_commit_action(:write_counter) do |arguments, _context|
      CallbackRecord.create!(name: arguments.fetch("count").to_s,
        commit_callback: -> { raise failure, cause: original_cause })
    end

    error = assert_raises(ActiveRecord::RecordNotFound) { Counter.ref("lookup").increment }

    assert_same failure, error
    assert_same original_cause, error.cause
    assert error.backtrace.any? { |line| line.include?("run_commit_callback") }
    assert_nil SolidObjects::Instance.sole.activation_owner_id
    assert SolidObjects::Message.sole.completed?
  end
end
