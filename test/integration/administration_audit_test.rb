# frozen_string_literal: true

require "database_test_helper"

class AdministrationAuditTest < ActiveSupport::TestCase
  class LedgerActor < SolidObjects::Actor
    actor_type "audited-ledger"

    attribute :count, default: 0
    attribute :entries, default: 0

    observable :count

    def post
      self.entries += 1
      emit :settle, entry: "one"
    end

    def touch
      self.count += 1
    end
  end

  class PoisonActor < SolidObjects::Actor
    actor_type "audited-poison"

    class << self
      attr_accessor :fail
    end

    def run
      raise "poison message" if self.class.fail
    end
  end

  setup do
    SolidObjects.configuration.retry_delay = ->(_attempt) { 0 }
    SolidObjects.configuration.max_attempts = 1
    SolidObjects.configuration.authorize_administration = ->(**) { true }
    PoisonActor.fail = true
  end

  test "writes one audit row for an effect retry" do
    effect = dead_effect

    SolidObjects.dead_letters.effects.retry(effect.effect_id, authorization_context: "operator")

    event = SolidObjects::AdministrationEvent.sole
    assert_equal "dead_letter.retry", event.action
    assert_equal "effect", event.kind
    assert_equal effect.effect_id, event.subject_id
    assert_equal "operator", event.actor
    assert event.occurred_at
  end

  test "writes one audit row for a broadcast retry" do
    broadcast = dead_broadcast

    SolidObjects.dead_letters.broadcasts.retry(
      broadcast.broadcast_id,
      authorization_context: "operator"
    )

    event = SolidObjects::AdministrationEvent.sole
    assert_equal "dead_letter.retry", event.action
    assert_equal "broadcast", event.kind
    assert_equal broadcast.broadcast_id, event.subject_id
  end

  test "writes one audit row for a message retry" do
    PoisonActor.ref("one").async.run
    run_actors
    dead_letter = SolidObjects::DeadLetter.sole
    PoisonActor.fail = false

    SolidObjects.dead_letters.retry(dead_letter.id, authorization_context: "operator")

    event = SolidObjects::AdministrationEvent.sole
    assert_equal "dead_letter.retry", event.action
    assert_equal "message", event.kind
    assert_equal dead_letter.id.to_s, event.subject_id
  end

  test "writes one audit row for each press, including a repeat" do
    effect = dead_effect

    2.times do
      SolidObjects.dead_letters.effects.retry(effect.effect_id, authorization_context: "operator")
    end

    assert_equal 2, SolidObjects::AdministrationEvent.count
  end

  test "records the identity the application names" do
    effect = dead_effect
    SolidObjects.configuration.administration_identity = ->(context) { "user:#{context.fetch(:id)}" }

    SolidObjects.dead_letters.effects.retry(effect.effect_id, authorization_context: { id: 42 })

    assert_equal "user:42", SolidObjects::AdministrationEvent.sole.actor
  end

  test "writes no audit row when the caller is refused" do
    effect = dead_effect
    SolidObjects.configuration.authorize_administration = ->(**) { false }

    assert_raises(SolidObjects::Unauthorized) do
      SolidObjects.dead_letters.effects.retry(effect.effect_id, authorization_context: "operator")
    end

    assert_equal 0, SolidObjects::AdministrationEvent.count
  end

  test "reading dead letters writes no audit row" do
    dead_effect

    SolidObjects.dead_letters.effects.all(authorization_context: "operator").to_a

    assert_equal 0, SolidObjects::AdministrationEvent.count
  end

  private

  def dead_effect
    LedgerActor.ref("one").async.post
    run_actors
    SolidObjects.register_effect(:settle) { raise "settlement declined" }
    run_effects
    SolidObjects::Effect.find_by!(name: "settle")
  end

  def dead_broadcast
    SolidObjects.configuration.broadcast_adapter = ->(_payload) { raise "transport down" }
    LedgerActor.ref("broadcast").async.touch
    run_actors
    run_broadcasts
    SolidObjects::Broadcast.where(status: "dead").sole
  end

  def run_actors
    worker = SolidObjects::Worker.new
    worker.run_until_idle
  ensure
    worker&.stop
  end

  def run_effects
    executor = SolidObjects::EffectExecutor.new
    executor.run_once while SolidObjects::Effect.exists?(status: "pending")
  ensure
    executor&.stop
  end

  def run_broadcasts
    executor = SolidObjects::BroadcastExecutor.new
    executor.run_once while SolidObjects::Broadcast.exists?(status: "pending")
  ensure
    executor&.stop
  end
end
