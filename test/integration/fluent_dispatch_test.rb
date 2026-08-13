# rbs_inline: enabled
# frozen_string_literal: true

require "database_test_helper"

class FluentDispatchTest < ActiveSupport::TestCase
  class TargetActor < SolidObjects::Actor
    actor_type "fluent-dispatch-target"

    attribute :received, default: -> { [] }

    def record(value:, timeout: nil, available_at: nil, idempotency_key: nil, authorization_context: nil)
      entry = {
        "value" => value,
        "timeout" => timeout,
        "available_at" => available_at,
        "idempotency_key" => idempotency_key,
        "authorization_context" => authorization_context
      }
      self.received = received + [ entry ]
      entry
    end

    query :status do
      "ready"
    end

    private

    def hidden
      "private"
    end
  end

  class SourceActor < SolidObjects::Actor
    actor_type "fluent-dispatch-source"

    attribute :delivery_returned_nil, default: false

    def forward(target_id:, value:, available_at: nil, idempotency_key: nil)
      result = send_to(
        TargetActor.ref(target_id),
        available_at: available_at && Time.at(available_at).utc,
        idempotency_key:
      ).record(value:)
      self.delivery_returned_nil = result.nil?
    end

    def forward_with_reference(target_id:, value:)
      result = TargetActor.ref(target_id).async.record(value:)
      self.delivery_returned_nil = result.nil?
    end

    def forward_then_fail(target_id:)
      send_to(TargetActor.ref(target_id)).record(value: "discarded")
      raise "rollback"
    end

    def forward_query(target_id:)
      send_to(TargetActor.ref(target_id)).status
    end

    def forward_unknown(target_id:)
      send_to(TargetActor.ref(target_id)).missing
    end

    def configure_reminder(at:, every:, missed:, account_id:)
      schedule(
        at: Time.at(at).utc,
        every:,
        missed:
      ).evaluate(
        account_id:,
        at: "message at",
        every: "message every",
        missed: "message missed"
      )
    end

    def configure_query_reminder(at:)
      schedule(at: Time.at(at).utc).summary
    end

    def configure_unknown_reminder(at:)
      schedule(at: Time.at(at).utc).missing
    end

    def wait_on_target(target_id:)
      TargetActor.ref(target_id).sync(timeout: 1).status
    end

    def evaluate(account_id:, at: nil, every: nil, missed: nil)
      [ account_id, at, every, missed ]
    end

    query :summary do
      "summary"
    end
  end

  test "fluent external async enqueues the selected message and returns its reference" do
    message_reference = TargetActor.ref("external").async.record(value: "one")
    message = SolidObjects::Message.find(message_reference.id)

    assert_instance_of SolidObjects::MessageReference, message_reference
    assert_equal "record", message.message_name
    assert_equal "async", message.message_kind
  end

  test "fluent external async forwards message arguments unchanged" do
    message_reference = TargetActor.ref("arguments").async.record(
      value: "one",
      timeout: "message timeout",
      available_at: "message available at",
      idempotency_key: "message idempotency key",
      authorization_context: "message authorization context"
    )

    assert_equal(
      {
        "value" => "one",
        "timeout" => "message timeout",
        "available_at" => "message available at",
        "idempotency_key" => "message idempotency key",
        "authorization_context" => "message authorization context"
      },
      SolidObjects::Message.find(message_reference.id).arguments
    )
  end

  test "fluent external async applies delivery options before selecting the message" do
    authorization_calls = []
    SolidObjects.configuration.authorize_message = ->(**arguments) do
      authorization_calls << arguments
      true
    end
    available_at = 10.minutes.from_now

    message_reference = TargetActor.ref("configured-async").async(
      available_at:,
      idempotency_key: "record-once",
      authorization_context: "operator"
    ).record(value: "one")
    message = SolidObjects::Message.find(message_reference.id)

    assert_in_delta available_at.to_f, message.ready_message.available_at.to_f, 0.01
    assert_equal "record-once", message.idempotency_key
    assert_equal "operator", authorization_calls.sole.fetch(:authorization_context)
    assert_equal({ value: "one" }, authorization_calls.sole.fetch(:arguments))
  end

  test "fluent configured sync returns message and query results" do
    reference = TargetActor.ref("configured-sync")

    assert_equal "ready", reference.sync(timeout: 2).status
    assert_equal "one", reference.sync(timeout: 2).record(value: "one").fetch("value")
  end

  test "direct committed calls continue returning message and query results" do
    reference = TargetActor.ref("direct")

    assert_equal "ready", reference.status
    assert_equal "one", reference.record(value: "one").fetch("value")
  end

  test "fluent sync keeps invocation options separate from message arguments" do
    authorization_calls = []
    SolidObjects.configuration.authorize_message = ->(**arguments) do
      authorization_calls << arguments
      true
    end

    result = TargetActor.ref("separated-sync").sync(
      timeout: 2,
      idempotency_key: "record-once",
      authorization_context: "operator"
    ).record(
      value: "one",
      timeout: "message timeout",
      idempotency_key: "message idempotency key",
      authorization_context: "message authorization context"
    )
    message = SolidObjects::Message.find_by!(actor_id: "separated-sync")

    assert_equal "message timeout", result.fetch("timeout")
    assert_equal "message idempotency key", result.fetch("idempotency_key")
    assert_equal "message authorization context", result.fetch("authorization_context")
    assert_equal "record-once", message.idempotency_key
    assert_equal "operator", authorization_calls.sole.fetch(:authorization_context)
  end

  test "fluent actor send_to stages delivery and returns nil" do
    available_at = 5.minutes.from_now

    SourceActor.ref("sender").forward(
      target_id: "receiver",
      value: "one",
      available_at: available_at.to_f,
      idempotency_key: "forward-once"
    )
    source = SolidObjects::Instance.find_by!(actor_id: "sender")
    effect = SolidObjects::Effect.find_by!(name: SolidObjects::EffectExecutor::ACTOR_MESSAGE_EFFECT)

    assert source.state.fetch("delivery_returned_nil")
    assert_equal "record", effect.arguments.fetch("message_name")
    assert_equal({ "value" => "one" }, effect.arguments.fetch("arguments"))
    assert_in_delta available_at.to_f, Time.iso8601(effect.arguments.fetch("available_at")).to_f, 0.01
    assert_equal "forward-once", effect.arguments.fetch("idempotency_key")
  end

  test "fluent async inside an actor stages delivery and returns nil" do
    SourceActor.ref("reference-sender").forward_with_reference(
      target_id: "receiver",
      value: "one"
    )

    source = SolidObjects::Instance.find_by!(actor_id: "reference-sender")
    effect = SolidObjects::Effect.find_by!(name: SolidObjects::EffectExecutor::ACTOR_MESSAGE_EFFECT)
    assert source.state.fetch("delivery_returned_nil")
    assert_equal "record", effect.arguments.fetch("message_name")
  end

  test "a staged fluent send_to delivery disappears when the source turn rolls back" do
    SolidObjects.configuration.max_attempts = 1

    assert_raises(SolidObjects::MessageFailed) do
      SourceActor.ref("rollback-source").forward_then_fail(target_id: "receiver")
    end

    assert_empty SolidObjects::Effect.where(name: SolidObjects::EffectExecutor::ACTOR_MESSAGE_EFFECT)
  end

  test "fluent schedule persists its message arguments and recurrence options" do
    scheduled_at = 1.hour.from_now.change(usec: 0)

    assert_nil SourceActor.ref("scheduler").configure_reminder(
      at: scheduled_at.to_f,
      every: 3600,
      missed: :all,
      account_id: "account-1"
    )
    reminder = SolidObjects::Reminder.find_by!(actor_id: "scheduler")

    assert_equal "evaluate", reminder.name
    assert_equal "evaluate", reminder.message_name
    assert_equal(
      {
        "account_id" => "account-1",
        "at" => "message at",
        "every" => "message every",
        "missed" => "message missed"
      },
      reminder.arguments
    )
    assert_equal scheduled_at, reminder.next_run_at
    assert_equal 3600, reminder.interval_seconds
    assert_equal "all", reminder.missed_policy
  end

  test "scheduling the same fluent reminder again moves it" do
    reference = SourceActor.ref("moving-scheduler")
    first = 1.hour.from_now.change(usec: 0)
    second = 2.hours.from_now.change(usec: 0)

    reference.configure_reminder(at: first.to_f, every: 60, missed: :latest, account_id: "one")
    reference.configure_reminder(at: second.to_f, every: 120, missed: :all, account_id: "two")
    reminders = SolidObjects::Reminder.where(actor_id: "moving-scheduler", name: "evaluate")

    assert_equal 1, reminders.count
    assert_equal second, reminders.sole.next_run_at
    assert_equal 120, reminders.sole.interval_seconds
    assert_equal "two", reminders.sole.arguments.fetch("account_id")
  end

  test "message-only fluent dispatch rejects queries unknown messages and private methods" do
    assert_raises(SolidObjects::UnknownMessage) { TargetActor.ref("query").async.status }
    assert_raises(SolidObjects::UnknownMessage) { TargetActor.ref("unknown").async.missing }
    assert_raises(SolidObjects::UnknownMessage) { TargetActor.ref("private").async.hidden }

    assert_empty SolidObjects::Message.all
  end

  test "fluent send_to rejects queries and unknown messages before staging delivery" do
    SolidObjects.configuration.max_attempts = 1

    query_error = assert_raises(SolidObjects::MessageFailed) do
      SourceActor.ref("query-source").forward_query(target_id: "receiver")
    end
    unknown_error = assert_raises(SolidObjects::MessageFailed) do
      SourceActor.ref("unknown-source").forward_unknown(target_id: "receiver")
    end

    assert_equal "SolidObjects::UnknownMessage", query_error.details.fetch("class")
    assert_equal "SolidObjects::UnknownMessage", unknown_error.details.fetch("class")
    assert_empty SolidObjects::Effect.where(name: SolidObjects::EffectExecutor::ACTOR_MESSAGE_EFFECT)
  end

  test "fluent schedule rejects queries and unknown messages before persisting reminders" do
    SolidObjects.configuration.max_attempts = 1
    scheduled_at = 1.hour.from_now.to_f

    query_error = assert_raises(SolidObjects::MessageFailed) do
      SourceActor.ref("query-reminder").configure_query_reminder(at: scheduled_at)
    end
    unknown_error = assert_raises(SolidObjects::MessageFailed) do
      SourceActor.ref("unknown-reminder").configure_unknown_reminder(at: scheduled_at)
    end

    assert_equal "SolidObjects::UnknownMessage", query_error.details.fetch("class")
    assert_equal "SolidObjects::UnknownMessage", unknown_error.details.fetch("class")
    assert_empty SolidObjects::Reminder.all
  end

  test "actors remain prohibited from fluent synchronous actor calls" do
    SolidObjects.configuration.max_attempts = 1

    error = assert_raises(SolidObjects::MessageFailed) do
      SourceActor.ref("waiting-source").wait_on_target(target_id: "receiver")
    end

    assert_equal "SolidObjects::ActorCallCycle", error.details.fetch("class")
    assert_empty SolidObjects::Message.where(actor_type: TargetActor.actor_type)
  end

  test "fluent dispatchers report only operations supported by their delivery mode" do
    reference = TargetActor.ref("reflection")
    state = SolidObjects::State.new(SourceActor.definition.state_definition)
    actor = SourceActor.new(actor_id: "reflection", state:)

    assert reference.async.respond_to?(:record)
    refute reference.async.respond_to?(:status)
    refute reference.async.respond_to?(:hidden)
    assert reference.sync.respond_to?(:record)
    assert reference.sync.respond_to?(:status)
    assert actor.send_to(reference).respond_to?(:record)
    refute actor.send_to(reference).respond_to?(:status)
    assert actor.schedule(at: 1.hour.from_now).respond_to?(:evaluate)
    refute actor.schedule(at: 1.hour.from_now).respond_to?(:summary)
  end

  test "positional transport selection is not supported" do
    reference = TargetActor.ref("positional")
    state = SolidObjects::State.new(SourceActor.definition.state_definition)
    actor = SourceActor.new(actor_id: "positional", state:)

    assert_raises(ArgumentError) { reference.async(:record) }
    assert_raises(ArgumentError) { reference.sync(:status) }
    assert_raises(ArgumentError) { actor.send_to(reference, :record) }
    assert_raises(ArgumentError) { actor.schedule(:evaluate, at: 1.hour.from_now) }
  end
end
