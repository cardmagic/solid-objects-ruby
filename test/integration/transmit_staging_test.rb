# frozen_string_literal: true

require "database_test_helper"

class TransmitStagingTest < ActiveSupport::TestCase
  class CounterActor < SolidObjects::Actor
    actor_type "staging-counters"

    attribute :count, default: 0

    def increment(amount: 1)
      self.count += amount
      transmit.increment(amount:)
    end

    def increment_mirror(amount:)
      emit "solid-objects.transmit",
        operation: "increment",
        arguments: { amount: },
        actorType: "staging-mirrors",
        actorId: "mirror-1"
    end

    def stage_invalid
      emit "solid-objects.transmit", arguments: { amount: 1 }
    end
  end

  class MirrorActor < SolidObjects::Actor
    actor_type "staging-mirrors"

    attribute :count, default: 0
    attribute :applied, default: -> { [] }

    def increment(amount: 1)
      self.count += amount
      applied << amount
    end
  end

  class FixtureCounterActor < SolidObjects::Actor
    attribute :value, default: 0

    def increment(amount: 1)
      self.value += amount
      transmit.increment(amount:)
    end
  end

  FIXTURES = JSON.parse(
    File.read(File.expand_path("../../compatibility/transmit-envelopes.json", __dir__))
  )

  setup do
    SolidObjects.configuration.retry_delay = ->(_attempt) { 0 }
    SolidObjects.register_actor(CounterActor.actor_type, CounterActor)
    SolidObjects.register_actor(MirrorActor.actor_type, MirrorActor)
    SolidObjects.register_actor("transmit-counters", FixtureCounterActor)
  end

  teardown do
    @worker&.stop
    @effect_executor&.stop
  end

  def worker
    @worker ||= SolidObjects::Worker.new
  end

  def effect_executor
    @effect_executor ||= SolidObjects::EffectExecutor.new
  end

  def drain_effects(max_passes: 50)
    max_passes.times do
      break if SolidObjects::Effect.where(status: %w[pending processing]).none?

      effect_executor.run_once
    end
  end

  def mirror_state(actor_id = "alice")
    SolidObjects::Instance.find_by!(actor_type: "staging-mirrors", actor_id:).state
  end

  def deliver_to_mirror(envelope)
    SolidObjects::Transmission.receive(
      envelope,
      resolve_actor_type: ->(_actor_type) { "staging-mirrors" }
    )
  end

  test "stages the transmit effect in the actor commit" do
    message_reference = CounterActor.ref("alice").async.increment(amount: 2)

    worker.run_until_idle

    effect = SolidObjects::Effect.find_by!(message_id: message_reference.id)
    assert_equal "solid-objects.transmit", effect.name
    assert_equal "pending", effect.status
    assert_equal(
      { "operation" => "increment", "arguments" => { "amount" => 2 } },
      effect.arguments
    )
    assert_equal({ "count" => 2 }, effect.instance.state)
  end

  test "delivers a camelCase envelope carrying the effect id" do
    delivered = []
    SolidObjects.register_transmit { |envelope| delivered << envelope }
    CounterActor.ref("alice").async.increment(amount: 2)
    worker.run_until_idle
    effect = SolidObjects::Effect.sole

    assert effect_executor.run_once

    assert_equal [
      {
        "effectId" => effect.effect_id,
        "actorType" => "staging-counters",
        "actorId" => "alice",
        "operation" => "increment",
        "arguments" => { "amount" => 2 }
      }
    ], delivered
    assert_equal "completed", effect.reload.status
  end

  test "replays onto a server actor through Transmission.receive" do
    SolidObjects.register_transmit { |envelope| deliver_to_mirror(envelope) }
    CounterActor.ref("alice").async.increment(amount: 2)

    worker.run_until_idle
    drain_effects
    worker.run_until_idle

    assert_equal({ "count" => 2, "applied" => [ 2 ] }, mirror_state)
  end

  test "keeps per-actor order when an early envelope fails first" do
    failures_remaining = 1
    SolidObjects.register_transmit do |envelope|
      if envelope.dig("arguments", "amount") == 1 && failures_remaining.positive?
        failures_remaining -= 1
        raise "network down"
      end

      deliver_to_mirror(envelope)
    end
    reference = CounterActor.ref("alice")
    reference.async.increment(amount: 1)
    reference.async.increment(amount: 2)

    worker.run_until_idle
    drain_effects
    worker.run_until_idle

    assert_equal({ "count" => 3, "applied" => [ 1, 2 ] }, mirror_state)
  end

  test "a later claimed effect delivers an undelivered earlier sibling first" do
    delivered = []
    SolidObjects.register_transmit do |envelope|
      delivered << envelope.dig("arguments", "amount")
      deliver_to_mirror(envelope)
    end
    reference = CounterActor.ref("alice")
    reference.async.increment(amount: 1)
    reference.async.increment(amount: 2)
    worker.run_until_idle
    earlier_effect = SolidObjects::Effect.order(:id).first
    earlier_effect.update!(available_at: 1.hour.from_now)

    assert effect_executor.run_once

    assert_equal [ 1, 2 ], delivered
    assert_equal "pending", earlier_effect.reload.status
    worker.run_until_idle
    assert_equal({ "count" => 3, "applied" => [ 1, 2 ] }, mirror_state)
  end

  test "recovers in order after an offline period" do
    online = false
    SolidObjects.register_transmit do |envelope|
      raise "offline" unless online

      deliver_to_mirror(envelope)
    end
    reference = CounterActor.ref("alice")
    reference.async.increment(amount: 1)
    reference.async.increment(amount: 2)
    reference.async.increment(amount: 3)
    worker.run_until_idle

    5.times { effect_executor.run_once }
    worker.run_until_idle
    assert_nil SolidObjects::Instance.find_by(actor_type: "staging-mirrors", actor_id: "alice")

    online = true
    drain_effects
    worker.run_until_idle

    assert_equal({ "count" => 6, "applied" => [ 1, 2, 3 ] }, mirror_state)
  end

  test "routes an explicit raw emit target to a different actor" do
    SolidObjects.register_transmit { |envelope| SolidObjects::Transmission.receive(envelope) }
    CounterActor.ref("alice").async.increment_mirror(amount: 4)

    worker.run_until_idle
    drain_effects
    worker.run_until_idle

    assert_equal({ "count" => 4, "applied" => [ 4 ] }, mirror_state("mirror-1"))
  end

  test "retries a raised delivery and dead-letters on exhaustion" do
    SolidObjects.register_transmit { |_envelope| raise "always down" }
    CounterActor.ref("alice").async.increment(amount: 2)
    worker.run_until_idle
    effect = SolidObjects::Effect.sole

    (effect.max_attempts + 2).times { effect_executor.run_once }

    effect.reload
    assert_equal "dead", effect.status
    assert_equal effect.max_attempts, effect.attempt_count
    assert_equal "always down", effect.error.fetch("message")
  end

  test "dead-letters a malformed staged effect and skips it in the drain" do
    delivered = []
    SolidObjects.register_transmit { |envelope| delivered << envelope }
    reference = CounterActor.ref("alice")
    reference.async.stage_invalid
    reference.async.increment(amount: 2)
    worker.run_until_idle
    invalid_effect = SolidObjects::Effect.order(:id).first

    (invalid_effect.max_attempts + 4).times { effect_executor.run_once }

    assert_equal "dead", invalid_effect.reload.status
    assert_equal "SolidObjects::InvalidTransmission", invalid_effect.error.fetch("class")
    assert_equal [ "increment" ], delivered.map { |envelope| envelope.fetch("operation") }
  end

  test "stages an envelope that matches the golden fixture" do
    fixture = FIXTURES.fetch("valid").first
    delivered = []
    SolidObjects.register_transmit { |envelope| delivered << envelope }
    SolidObjects::Reference.new(actor_type: "transmit-counters", actor_id: "fixture-counter")
      .async.increment(amount: 2)

    worker.run_until_idle
    drain_effects

    envelope = delivered.fetch(0)
    assert_equal fixture.fetch("envelope").except("effectId"), envelope.except("effectId")

    message_reference = SolidObjects::Transmission.receive(envelope)

    assert_equal "transmit:#{envelope.fetch("effectId")}",
      SolidObjects::Message.find(message_reference.id).idempotency_key
  end
end
