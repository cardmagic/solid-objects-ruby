# frozen_string_literal: true

require "database_test_helper"

class TelemetryTest < ActiveSupport::TestCase
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
    assert events.any? { |event| event.fetch("name") == "solid_objects.recovery.failed" }
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
    assert_operator event.fetch("metrics").last.fetch("value"), :>=, 0
  ensure
    executor&.stop
  end
end
