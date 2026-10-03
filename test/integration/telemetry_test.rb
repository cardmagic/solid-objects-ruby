# frozen_string_literal: true

require "database_test_helper"
require "portable_telemetry_assertions"

class TelemetryTest < ActiveSupport::TestCase
  include PortableTelemetryAssertions

  class RecordingLogger
    attr_reader :errors

    def initialize
      @errors = []
    end

    def error(entry)
      errors << entry
    end

    def info(_entry)
    end

    def warn(_entry)
    end
  end

  class ActivationFailure < SolidObjects::Actor
    actor_type "telemetry-activation-failure"

    on_activate { raise "private activation failure" }

    def run
      nil
    end
  end

  class Counter < SolidObjects::Actor
    actor_type "telemetry-counter"
    attribute :count, default: 0
    observable :count, broadcast: :value

    def arrange
      emit :telemetry_effect, secret: "private effect"
      schedule(at: 1.minute.ago).increment
    end

    def fail_operation
      raise "private failure"
    end

    def refuse
      reject :refused, "private rejection"
    end

    def commit
      commit_action :telemetry_action
      nil
    end

    def commit_badly
      commit_action :telemetry_failure
      nil
    end

    def increment
      self.count += 1
    end
  end

  test "portable polling transitions keep millisecond intervals and reasons" do
    events = []
    SolidObjects.configuration.instrumentation = ->(event) { events << event }
    backoff = SolidObjects::PollingBackoff.new(minimum_interval: 0.1, maximum_interval: 1, on_change: ->(transition) { SolidObjects.instrument(:"polling.interval_changed", role: "actors", **transition) })
    backoff.record_idle
    assert_equal({ "role" => "actors", "previousIntervalMilliseconds" => 100, "currentIntervalMilliseconds" => 200, "reason" => "idle" }, events.last.fetch("attributes"))
    assert_equal %({"role":"actors","previousIntervalMilliseconds":100,"currentIntervalMilliseconds":200,"reason":"idle"}), JSON.generate(events.last.fetch("attributes"))
    assert_portable_attributes(events.last)
  end

  test "the portable attribute allowlist matches the shared contract" do
    assert_equal TELEMETRY_CONTRACT.fetch("attributes").sort, SolidObjects::Telemetry::FIELDS.sort
  end

  test "portable SQL lifecycle events match the shared attribute contract" do
    events = []
    SolidObjects.configuration.instrumentation = ->(event) { events << event }
    SolidObjects.configuration.max_attempts = 2
    SolidObjects.configuration.retry_delay = ->(_) { 0 }
    SolidObjects.configuration.authorize_administration = ->(**) { true }
    SolidObjects.register_effect(:telemetry_effect) { "delivered" }
    SolidObjects.register_commit_action(:telemetry_action) { |_arguments, _context| nil }
    SolidObjects.register_commit_action(:telemetry_failure) { |_arguments, _context| raise "private commit failure" }
    reference = Counter.ref("contract")
    reference.increment
    reference.async.refuse
    reference.async.fail_operation
    reference.async.commit
    reference.async.commit_badly
    reference.async.arrange
    SolidObjects::Mailbox.new.enqueue(reference:, operation: "increment", arguments: {}, delivery_mode: "internal", idempotency_key: "effect:contract:recovery")
    reference.diagnostics(limit: 1)
    worker = SolidObjects::Worker.new
    worker.run_until_idle
    ActivationFailure.ref("contract").async.run
    assert_raises(RuntimeError) { worker.run_once }
    worker.stop
    effect_executor = SolidObjects::EffectExecutor.new
    effect_executor.run_once
    scheduler = SolidObjects::ReminderScheduler.new
    scheduler.run_once
    reference.snapshot

    assert_portable_events(events, %w[
      activation.started activation.completed activation.failed
      message.enqueued message.started message.completed message.rejected message.failed message.retry dead_letter.created
      commit_action.started commit_action.completed commit_action.failed
      recovery.completed mailbox.depth outbox.age reminder.enqueued snapshot.read
    ])
    failures = events.select { |event| event.fetch("name") == "solid_objects.message.failed" }.map { |event| event.fetch("attributes").slice("retryable", "outcome") }
    assert_includes failures, { "retryable" => true, "outcome" => "retrying" }
    assert_includes failures, { "retryable" => true, "outcome" => "dead" }
    depth = events.find { |event| event.fetch("name") == "solid_objects.mailbox.depth" }.fetch("attributes")
    assert depth.fetch("truncated")
    assert_nil depth.fetch("depth")
    refute_includes events.to_json, "private"
  ensure
    worker&.stop
    effect_executor&.stop
    scheduler&.stop
  end

  test "a failing exporter is logged and cannot fail a turn" do
    logger = RecordingLogger.new
    SolidObjects.configuration.logger = logger
    SolidObjects.configuration.instrumentation = ->(_) { raise "private exporter failure" }

    assert_equal 1, Counter.ref("logged-exporter").increment

    assert_includes logger.errors, { event: "solid_objects.instrumentation.failed", instrumentation_event: "solid_objects.message.completed", error_class: "RuntimeError" }
    refute_includes logger.errors.to_s, "private"
  end

  test "a failing observer is logged and cannot fail a turn" do
    logger = RecordingLogger.new
    SolidObjects.configuration.logger = logger
    SolidObjects.configuration.authorize_administration = ->(**) { true }
    reference = Counter.ref("logged-observer")
    stop = reference.observe { raise "private observer failure" }

    assert_equal 1, reference.increment

    assert_includes logger.errors, { event: "solid_objects.instrumentation.failed", instrumentation_event: "solid_objects.message.completed", error_class: "RuntimeError" }
    refute_includes logger.errors.to_s, "private"
  ensure
    stop&.call
  end

  test "observers require a block" do
    SolidObjects.configuration.authorize_administration = ->(**) { true }
    reference = Counter.ref("blockless")

    assert_raises(ArgumentError) { reference.observe }
    assert_raises(ArgumentError) { reference.on("message.completed") }
  end

  test "a process accepts at most 1000 local observers" do
    SolidObjects.configuration.authorize_administration = ->(**) { true }
    reference = Counter.ref("observer-limit")
    stops = Array.new(1000) { reference.observe { nil } }

    error = assert_raises(ArgumentError) { reference.observe { nil } }

    assert_equal "at most 1000 local observers may be registered", error.message
    stops.pop.call
    stops << reference.observe { nil }
  ensure
    stops&.each(&:call)
  end

  test "reset removes registered observers" do
    SolidObjects.configuration.authorize_administration = ->(**) { true }
    events = []
    Counter.ref("reset-observer").observe { |event| events << event }

    SolidObjects.reset!
    SolidObjects.configuration.authorize_message = ->(**) { true }
    Counter.ref("reset-observer").increment

    assert_empty events
  end

  JSON.parse(File.read(File.expand_path("../../compatibility/sync-timeout.json", __dir__))).each do |fixture|
    test "portable timeout telemetry preserves #{fixture.fetch("waitingOn")} diagnostics" do
      attributes = SolidObjects::Telemetry.event(:"sync.timeout",
        waiting_on: fixture.fetch("rubyReason"),
        activation_owner_id: "worker-1",
        activation_generation: 7,
        arguments: { secret: "private" }).fetch("attributes")

      assert_equal({ "waitingOn" => fixture.fetch("waitingOn"), "activationOwnerId" => "worker-1", "activationGeneration" => "7" }, attributes)
    end
  end

  test "portable database contention telemetry preserves unknown activation fields" do
    events = []
    SolidObjects.configuration.instrumentation = ->(event) { events << event }
    reference = Counter.ref("contention").async.increment

    error = SolidObjects::SyncDiagnostics.new.database_contention_for(reference, timeout: 1)

    assert_equal "database_contention", error.waiting_on
    attributes = events.last.fetch("attributes")
    assert_equal "databaseContention", attributes.fetch("waitingOn")
    assert_nil attributes.fetch("activationOwnerId")
    assert_nil attributes.fetch("activationGeneration")
  end

  test "a failing started subscriber cannot fail a turn" do
    subscriber = ActiveSupport::Notifications.subscribe("solid_objects.message.started") { raise "private sink failure" }
    assert_equal 1, Counter.ref("one").increment
    assert_equal 1, Counter.ref("one").snapshot.count
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber)
  end

  test "portable events carry correlation and bounded metric labels" do
    events = []
    SolidObjects.configuration.instrumentation = ->(event) { events << event }
    Counter.ref("one").increment
    event = events.find { |entry| entry.fetch("name") == "solid_objects.message.completed" }
    assert_equal 1, event.fetch("schemaVersion")
    assert_equal database_family.to_s, event.fetch("adapter")
    assert_equal "one", event.fetch("actorId")
    assert_equal 1, event.fetch("attempt")
    assert event.fetch("incarnation")
    refute_includes event.fetch("metrics").to_json, "actorId"
    started = events.find { |entry| entry.fetch("name") == "solid_objects.message.started" }
    refute_includes started.fetch("metrics").map { |metric| metric.fetch("name") }, "solid_objects.duration"
  end
  test "diagnostics and observers require authorization and are bounded" do
    reference = Counter.ref("diagnostics")
    assert_raises(SolidObjects::Unauthorized) { reference.diagnostics }
    assert_raises(SolidObjects::Unauthorized) { reference.observe { nil } }
    SolidObjects.configuration.authorize_administration = ->(authorization_context:, **) { authorization_context == "operator" }
    events = []
    stop = reference.on("message.enqueued", authorization_context: "operator") { |event| events << event }
    2.times { reference.async.increment }
    Counter.ref("other").async.increment
    assert_equal 2, events.length
    stop.call
    reference.async.increment
    assert_equal 2, events.length
    summary = reference.diagnostics(authorization_context: "operator", limit: 1)
    assert_equal 1, summary.fetch("mailbox").fetch("sampled")
    assert summary.fetch("mailbox").fetch("truncated")
    assert summary.fetch("mailbox").frozen?
    assert_raises(ArgumentError) { reference.diagnostics(authorization_context: "operator", limit: 101) }
  end

  test "events cover retry failure snapshot reminder and outbox without private data" do
    events = []
    SolidObjects.configuration.instrumentation = ->(event) { events << event }
    SolidObjects.configuration.max_attempts = 2
    SolidObjects.configuration.retry_delay = ->(_) { 0 }
    SolidObjects.configuration.authorize_administration = ->(**) { true }
    SolidObjects.register_effect(:telemetry_effect) { "private provider response" }
    reference = Counter.ref("lifecycle")
    reference.async.fail_operation
    worker = SolidObjects::Worker.new
    worker.run_once
    reference.async.arrange
    worker.run_once
    summary = reference.diagnostics
    assert_equal 1, summary.fetch("outbox").fetch("sampled")
    assert_equal 1, summary.fetch("reminders").fetch("sampled")
    effect_executor = SolidObjects::EffectExecutor.new
    effect_executor.run_once
    scheduler = SolidObjects::ReminderScheduler.new
    scheduler.run_once
    reference.snapshot
    names = events.map { |event| event.fetch("name") }
    %w[activation.started activation.completed message.retry dead_letter.created reminder.enqueued outbox.age snapshot.read].each do |name|
      assert_includes names, "solid_objects.#{name}"
    end
    refute_includes events.to_json, "private"
  ensure
    worker&.stop
    effect_executor&.stop
    scheduler&.stop
  end

  test "portable observers exclude unknown attributes and cannot mask application errors" do
    events = []
    SolidObjects.configuration.instrumentation = ->(event) { events << event }
    error = assert_raises(RuntimeError) do
      SolidObjects.instrument(:custom, arguments: "private", state: { secret: "private" }, password: "private") { raise "application failure" }
    end
    assert_equal "application failure", error.message
    assert_empty events.last.fetch("attributes")
    SolidObjects.configuration.instrumentation = ->(_) { raise "exporter failure" }
    assert_equal 1, Counter.ref("safe").increment
  end
  test "reports failed durable recovery callbacks in diagnostics" do
    events = []
    SolidObjects.configuration.instrumentation = ->(event) { events << event }
    SolidObjects.configuration.authorize_administration = ->(**) { true }
    SolidObjects.configuration.max_attempts = 1
    reference = Counter.ref("recovery")
    SolidObjects::Mailbox.new.enqueue(reference:, operation: "fail_operation", arguments: {}, delivery_mode: "internal", idempotency_key: "effect:test:recovery")
    worker = SolidObjects::Worker.new
    worker.run_once
    assert_equal 1, reference.diagnostics.fetch("recoveryFailures").fetch("sampled")
    assert_portable_events(events, %w[recovery.failed])
  ensure
    worker&.stop
  end
  test "outbox measurement failure cannot fail delivery" do
    SolidObjects.configuration.instrumentation = ->(_) { true }
    Counter.ref("measurement").arrange
    calls = []
    SolidObjects.register_effect(:telemetry_effect) {
      calls << :delivered
      "result"
    }
    executor = SolidObjects::EffectExecutor.new
    executor.define_singleton_method(:claim_next) do
      super().tap do |effect|
        effect.define_singleton_method(:available_at) { raise "measurement failed" }
      end
    end
    assert executor.run_once
    assert_equal [ :delivered ], calls
    assert_equal "completed", SolidObjects::Effect.first.status
  ensure
    executor&.stop
  end

  test "samples broadcast age and caps the combined outbox category" do
    events = []
    SolidObjects.configuration.instrumentation = ->(event) { events << event }
    SolidObjects.configuration.authorize_administration = ->(**) { true }
    SolidObjects.configuration.broadcast_adapter = ->(_) { true }
    reference = Counter.ref("broadcast")
    reference.increment
    reference.arrange
    summary = reference.diagnostics(limit: 1)
    assert_equal 1, summary.fetch("outbox").fetch("sampled")
    assert summary.fetch("outbox").fetch("truncated")
    executor = SolidObjects::BroadcastExecutor.new
    assert executor.run_once
    event = events.find { |entry| entry.fetch("name") == "solid_objects.outbox.age" && entry.fetch("attributes")["outboxKind"] == "broadcast" }
    assert event
    assert_portable_attributes(event)
    assert_operator event.fetch("metrics").last.fetch("value"), :>=, 0
  ensure
    executor&.stop
  end
end
