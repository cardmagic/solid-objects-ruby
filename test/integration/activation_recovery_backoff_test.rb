# rbs_inline: enabled

require "database_test_helper"
require "portable_telemetry_assertions"

class ActivationRecoveryBackoffTest < ActiveSupport::TestCase
  include PortableTelemetryAssertions

  class Counter < SolidObjects::Actor
    actor_type "activation-recovery-backoff"
    attribute :count, default: 0

    class << self
      attr_accessor :before_commit
    end

    def increment(label:)
      self.count += 1
      emit(:applied, label:)
      self.class.before_commit&.call(label)
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
    Counter.before_commit = ->(label) { clock[:now] += 0.201 if label == "slow" }
    @events = []
    SolidObjects.configuration.instrumentation = ->(event) { @events << event }
    @workers = []
  end

  teardown do
    @workers.each(&:stop)
    SolidObjects.database_adapter.singleton_class.remove_method(:database_now)
    Counter.before_commit = nil
  end

  test "recovers once immediately then delays without blocking other actors or reordering" do
    worker = new_worker
    first = Counter.ref("one").async.increment(label: "slow")
    later = Counter.ref("one").async.increment(label: "later")
    assert_equal 0, worker.run_once
    assert_equal 0, worker.run_once
    assert_equal 2, stored_message(first).attempt_count
    assert_equal 0, worker.run_once
    assert_in_delta 1, remaining_delay(first)
    other = Counter.ref("other").async.increment(label: "other")
    assert_equal 1, worker.run_once
    assert_equal 1, stored_message(other).result
    assert_equal 0, stored_message(later).attempt_count
    assert_empty stored_message(first).instance.state

    @clock[:now] += 0.999
    assert_equal 0, worker.run_once
    @clock[:now] += 0.001
    assert_equal 0, worker.run_once
    assert_equal 3, stored_message(first).attempt_count
    assert_equal 0, worker.run_once
    assert_in_delta 2, remaining_delay(first)
    assert_empty SolidObjects::DeadLetter.all

    Counter.before_commit = nil
    @clock[:now] += 2
    assert_equal 2, worker.run_once
    assert_equal 1, stored_message(first).result
    assert_equal 2, stored_message(later).result
    assert_equal %w[later other slow], SolidObjects::Effect.all.map { |effect| effect.arguments.fetch("label") }.sort
  end

  %w[stop cleanup replacement].each do |recovery|
    test "preserves custom recovery waits through #{recovery}" do
      delay_arguments = []
      SolidObjects.configuration.retry_delay = ->(attempt) {
        delay_arguments << attempt
        attempt * 0.025
      }
      worker = new_worker
      reference = Counter.ref("one").async.increment(label: "slow")
      2.times { worker.run_once }
      worker.stop if recovery == "stop"
      if recovery == "cleanup"
        @clock[:now] += SolidObjects.configuration.process_alive_threshold + 1
        SolidObjects::ProcessRegistry.cleanup_dead
      end
      replacement = new_worker
      assert_equal 0, replacement.run_once
      assert_equal [ 1 ], delay_arguments
      assert_in_delta 0.025, remaining_delay(reference)
      worker.stop
      assert_in_delta 0.025, remaining_delay(reference)

      @clock[:now] += 0.025
      replacement.run_once
      assert_equal 3, stored_message(reference).attempt_count
      assert_equal 0, replacement.run_once
      assert_equal [ 1, 2 ], delay_arguments
      assert_in_delta 0.05, remaining_delay(reference)
    end
  end

  test "caps default recovery waits without dead lettering lease loss" do
    worker = new_worker
    reference = Counter.ref("one").async.increment(label: "slow")
    2.times { worker.run_once }
    [ 1, 2, 4, 8, 16, 32, 60, 60 ].each do |delay|
      worker.run_once
      assert_in_delta delay, remaining_delay(reference)
      assert_empty SolidObjects::DeadLetter.all
      @clock[:now] += delay
      worker.run_once
    end
  end

  %w[completion failure rejection].each do |outcome|
    test "reports each lost #{outcome} and stops from its instrumentation callback" do
      worker = new_worker
      reference = Counter.ref("one").async.increment(label: "slow")
      Counter.before_commit = ->(_) do
        @clock[:now] += 0.201
        raise SolidObjects::Rejected.new(code: "declined", message: "declined") if outcome == "rejection"
        raise "handler failed" if outcome == "failure"
      end
      observed = []
      SolidObjects.configuration.retry_delay = ->(_) { 0 }
      SolidObjects.configuration.instrumentation = ->(event) do
        next unless event.fetch("name") == "solid_objects.activation.lost"

        observed << event
        worker.request_shutdown if observed.length == 3
      end
      forced_shutdown = false
      guard = Thread.new do
        sleep 2
        forced_shutdown = true
        worker.request_shutdown
      end
      begin
        worker.run
      ensure
        guard.kill
        guard.join
      end
      assert_not forced_shutdown
      assert_predicate worker, :stopped?
      assert_equal [ 1, 2, 3 ], observed.map { |event| event.fetch("attempt") }
      assert observed.all? { |event| event.fetch("messageId") == reference.id.to_s }
      observed.each { |event| assert_portable_attributes(event) }
      assert worker.shutdown_requested?
      assert_empty stored_message(reference).instance.state
      assert_empty SolidObjects::DeadLetter.all
    end
  end

  %w[failure rejection].each do |outcome|
    test "reports lease loss while saving a handler #{outcome} and recovers" do
      worker = new_worker
      reference = Counter.ref("one").async.increment(label: "slow")
      Counter.before_commit = ->(_) do
        @clock[:now] += 0.201
        raise SolidObjects::Rejected.new(code: "declined", message: "declined") if outcome == "rejection"

        raise "handler failed"
      end
      assert_equal 0, worker.run_once
      losses = @events.select { |event| event.fetch("name") == "solid_objects.activation.lost" }
      assert_equal [ 1 ], losses.map { |event| event.fetch("attempt") }
      assert_equal [ reference.id.to_s ], losses.map { |event| event.fetch("messageId") }
      losses.each { |event| assert_portable_attributes(event) }
      assert_empty stored_message(reference).instance.state
      assert_nil stored_message(reference).error
      assert_nil stored_message(reference).rejection
      assert_empty SolidObjects::DeadLetter.all
      assert_empty SolidObjects::Effect.all
      assert_not @events.any? { |event| %w[solid_objects.message.failed solid_objects.message.rejected].include?(event.fetch("name")) }

      Counter.before_commit = nil
      assert_equal 1, worker.run_once
      assert_equal 1, stored_message(reference).result
      assert_equal 2, stored_message(reference).attempt_count
      assert_equal 1, SolidObjects::Effect.count
    end
  end

  test "keeps a handler failure terminal with one allowed attempt" do
    Counter.before_commit = ->(_) { raise "handler failure" }
    worker = new_worker
    reference = Counter.ref("one").async.increment(label: "fail")
    worker.run_once
    assert_predicate stored_message(reference), :dead?
    assert_equal 1, stored_message(reference).attempt_count
  end

  test "uses total claims for recovery after an earlier handler failure" do
    delay_arguments = []
    SolidObjects.configuration.max_attempts = 3
    SolidObjects.configuration.retry_delay = ->(attempt) {
      delay_arguments << attempt
      attempt * 0.025
    }
    worker = new_worker
    reference = Counter.ref("mixed").async.increment(label: "slow")
    Counter.before_commit = ->(_) { raise "handler failure" }
    worker.run_once
    assert_equal [ 1 ], delay_arguments
    @clock[:now] += 0.025
    Counter.before_commit = ->(_) { @clock[:now] += 0.201 }
    worker.run_once
    assert_equal 0, worker.run_once
    assert_equal [ 1, 1 ], delay_arguments
    assert_in_delta 0.025, remaining_delay(reference)
    assert_equal 2, stored_message(reference).attempt_count
    @clock[:now] += 0.025
    Counter.before_commit = ->(_) { raise "handler failed again" }
    worker.run_once
    assert_predicate stored_message(reference), :dead?
    assert_equal 3, stored_message(reference).attempt_count
  end

  private

  def new_worker
    SolidObjects::Worker.new.tap { |worker| @workers << worker }
  end

  def stored_message(reference)
    SolidObjects::Message.find(reference.id)
  end

  def remaining_delay(reference)
    ready = SolidObjects::ReadyMessage.find_by(message_id: reference.id)
    assert ready, "expected recovered claim to wait in ready membership"
    ready.available_at - @clock.fetch(:now)
  end
end
