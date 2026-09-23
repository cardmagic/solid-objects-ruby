# frozen_string_literal: true

require "database_test_helper"

class DeadLetterScopesTest < ActiveSupport::TestCase
  class OrderActor < SolidObjects::Actor
    actor_type "scoped-dead-letter-orders"

    attribute :count, default: 0
    attribute :orders, default: 0

    observable :count

    def place
      self.orders += 1
      emit :charge_order, order_id: "order-1"
    end

    def touch
      self.count += 1
    end

    def send_elsewhere
      transmit.touch
    end
  end

  class PoisonActor < SolidObjects::Actor
    actor_type "scoped-dead-letter-poison"

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
    @charges = []
  end

  test "returns a dead effect to pending and runs it again" do
    effect = dead_effect

    SolidObjects.dead_letters.effects.retry(effect.effect_id, authorization_context: "operator")

    assert_equal "pending", effect.reload.status
    assert_equal 0, effect.attempt_count
    assert_nil effect.claimed_by
    SolidObjects.register_effect(:charge_order) { |arguments, _context| @charges << arguments }
    run_effects

    assert_equal "completed", effect.reload.status
    assert_equal [ { "order_id" => "order-1" } ], @charges
  end

  test "reuses the stable effect id when it retries" do
    effect = dead_effect
    original_id = effect.effect_id

    SolidObjects.dead_letters.effects.retry(original_id, authorization_context: "operator")

    assert_equal original_id, effect.reload.effect_id
    assert_equal 1, SolidObjects::Effect.count
  end

  test "leaves an effect that is already pending alone" do
    effect = dead_effect
    SolidObjects.dead_letters.effects.retry(effect.effect_id, authorization_context: "operator")
    available_at = effect.reload.available_at

    SolidObjects.dead_letters.effects.retry(effect.effect_id, authorization_context: "operator")

    assert_equal "pending", effect.reload.status
    assert_equal available_at, effect.available_at
    assert_equal 1, SolidObjects::Effect.count
  end

  test "returns a dead broadcast to pending and delivers it" do
    broadcast = dead_broadcast

    SolidObjects.dead_letters.broadcasts.retry(
      broadcast.broadcast_id,
      authorization_context: "operator"
    )

    assert_equal "pending", broadcast.reload.status
    assert_equal 0, broadcast.attempt_count
    delivered = []
    SolidObjects.configuration.broadcast_adapter = ->(payload) { delivered << payload }
    run_broadcasts

    assert_equal "delivered", broadcast.reload.status
    assert_equal 1, delivered.size
  end

  test "replays a dead transmit effect" do
    OrderActor.ref("one").async.send_elsewhere
    run_actors
    transmitted = []
    SolidObjects.register_effect(SolidObjects::Transmission::EFFECT_NAME) { raise "carrier down" }
    run_effects
    effect = SolidObjects::Effect.find_by!(name: SolidObjects::Transmission::EFFECT_NAME)
    assert_equal "dead", effect.status

    SolidObjects.register_effect(SolidObjects::Transmission::EFFECT_NAME) do |arguments, _context|
      transmitted << arguments
    end
    SolidObjects.dead_letters.effects.retry(effect.effect_id, authorization_context: "operator")
    run_effects

    assert_equal "completed", effect.reload.status
    assert_equal [ "touch" ], transmitted.map { |arguments| arguments.fetch("operation") }
  end

  test "reads and retries message dead letters as it always has" do
    PoisonActor.ref("one").async.run
    run_actors
    dead_letter = SolidObjects::DeadLetter.sole
    PoisonActor.fail = false

    listed = SolidObjects.dead_letters.all(authorization_context: "operator")
    reference = SolidObjects.dead_letters.retry(dead_letter.id, authorization_context: "operator")
    run_actors

    assert_equal [ dead_letter.id ], listed.map(&:id)
    assert_equal reference.id, dead_letter.reload.retried_message_id
    assert_equal "completed", reference.status
  end

  test "each scope reads only its own kind" do
    effect = dead_effect
    broadcast = dead_broadcast
    PoisonActor.ref("one").async.run
    run_actors

    effects = SolidObjects.dead_letters.effects.all(authorization_context: "operator")
    broadcasts = SolidObjects.dead_letters.broadcasts.all(authorization_context: "operator")
    messages = SolidObjects.dead_letters.all(authorization_context: "operator")

    assert_equal [ effect.effect_id ], effects.map(&:id)
    assert_equal [ broadcast.broadcast_id ], broadcasts.map(&:id)
    assert_equal 1, messages.count
  end

  test "lists a dead row whose id retry accepts" do
    effect = dead_effect

    row = SolidObjects.dead_letters.effects.all(authorization_context: "operator").sole

    assert_equal effect.effect_id, row.id
    assert_equal "effect", row.kind
    assert_equal "dead", row.status
    assert_equal "scoped-dead-letter-orders", row.actor_type
    assert_equal "one", row.actor_id
    SolidObjects.dead_letters.effects.retry(row.id, authorization_context: "operator")

    assert_equal "pending", effect.reload.status
  end

  test "reads only dead rows, not pending ones" do
    dead = dead_effect
    OrderActor.ref("two").async.place
    run_actors

    effects = SolidObjects.dead_letters.effects.all(authorization_context: "operator")

    assert_equal 2, SolidObjects::Effect.count
    assert_equal [ dead.effect_id ], effects.map(&:id)
  end

  test "refuses an unauthorized caller" do
    effect = dead_effect
    broadcast = dead_broadcast
    SolidObjects.configuration.authorize_administration = ->(**) { false }

    assert_raises(SolidObjects::Unauthorized) do
      SolidObjects.dead_letters.effects.all(authorization_context: "operator")
    end
    assert_raises(SolidObjects::Unauthorized) do
      SolidObjects.dead_letters.effects.retry(effect.effect_id, authorization_context: "operator")
    end
    assert_raises(SolidObjects::Unauthorized) do
      SolidObjects.dead_letters.broadcasts.retry(
        broadcast.broadcast_id,
        authorization_context: "operator"
      )
    end
  end

  test "names the scope it authorizes" do
    effect = dead_effect
    seen = []
    SolidObjects.configuration.authorize_administration = lambda do |action:, resource:, **|
      seen << [ action, resource ]
      true
    end

    SolidObjects.dead_letters.effects.retry(effect.effect_id, authorization_context: "operator")

    assert_equal [ [ "retry", "effect_dead_letters" ] ], seen
  end

  private

  def dead_effect
    OrderActor.ref("one").async.place
    run_actors
    SolidObjects.register_effect(:charge_order) { raise "charge declined" }
    run_effects
    SolidObjects::Effect.find_by!(name: "charge_order").tap do |effect|
      assert_equal "dead", effect.status
    end
  end

  def dead_broadcast
    SolidObjects.configuration.broadcast_adapter = ->(_payload) { raise "transport down" }
    OrderActor.ref("broadcast").async.touch
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
