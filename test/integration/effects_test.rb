# frozen_string_literal: true

require "database_test_helper"

class EffectsTest < ActiveSupport::TestCase
  class CheckoutActor < SolidObjects::Actor
    actor_type "checkout-effects"

    attribute :status, default: "open"

    def checkout(payment_id:)
      self.status = "pending"
      emit :charge_payment, payment_id:, amount_cents: 1_000
    end

    def broken_checkout
      self.status = "pending"
      emit :charge_payment, payment_id: "broken", amount_cents: 1_000
      raise "checkout failed"
    end

    def checkout_with_result(payment_id:)
      emit(
        :charge_payment,
        payment_id:,
        on_success: :payment_charged,
        on_failure: :payment_failed
      )
    end

    def payment_charged(effect_id:, result:)
      self.status = "#{effect_id}:#{result.fetch("provider_id")}"
    end

    def payment_failed(effect_id:, error:)
      self.status = "#{effect_id}:#{error.fetch("class")}"
    end
  end

  setup do
    SolidObjects.configuration.retry_delay = ->(_attempt) { 0 }
  end

  test "commits state, message completion, and effect together" do
    message_reference = CheckoutActor.ref("order-1").checkout(payment_id: "payment-1")
    worker = SolidObjects::Worker.new

    worker.run_until_idle

    effect = SolidObjects::Effect.find_by!(message_id: message_reference.id)
    assert_equal "pending", effect.status
    assert_equal "charge_payment", effect.name
    assert_equal({ "payment_id" => "payment-1", "amount_cents" => 1_000 }, effect.arguments)
    assert_equal({ "status" => "pending" }, effect.instance.state)
    assert SolidObjects::Message.find(message_reference.id).completed?
  ensure
    worker&.stop
  end

  test "does not persist an effect from a rolled-back actor turn" do
    CheckoutActor.ref("order-1").broken_checkout
    worker = SolidObjects::Worker.new

    worker.run_once

    assert_empty SolidObjects::Effect.all
    assert_equal({}, SolidObjects::Instance.find_by!(actor_id: "order-1").state)
  ensure
    worker&.stop
  end

  test "delivers an effect with a stable idempotency context" do
    delivered = Queue.new
    SolidObjects.register_effect(:charge_payment) do |arguments, context|
      delivered << [ arguments, context.id ]
      { "provider_id" => "provider-1" }
    end
    CheckoutActor.ref("order-1").checkout(payment_id: "payment-1")
    worker = SolidObjects::Worker.new
    worker.run_until_idle
    effect = SolidObjects::Effect.first
    effect_executor = SolidObjects::EffectExecutor.new

    assert effect_executor.run_once

    arguments, effect_id = delivered.pop
    assert_equal effect.effect_id, effect_id
    assert_equal "payment-1", arguments.fetch("payment_id")
    assert_equal "completed", effect.reload.status
    assert_equal({ "provider_id" => "provider-1" }, effect.result)
  ensure
    effect_executor&.stop
    worker&.stop
  end

  test "enqueues a success result message back to the actor atomically" do
    SolidObjects.register_effect(:charge_payment) do
      { "provider_id" => "provider-1" }
    end
    CheckoutActor.ref("order-1").checkout_with_result(payment_id: "payment-1")
    worker = SolidObjects::Worker.new
    worker.run_until_idle
    effect_executor = SolidObjects::EffectExecutor.new

    effect_executor.run_once

    effect = SolidObjects::Effect.first
    result_message = SolidObjects::Message.find_by!(
      idempotency_key: "effect:#{effect.effect_id}:success"
    )
    assert_equal "payment_charged", result_message.message_name
    assert_equal effect.effect_id, result_message.arguments.fetch("effect_id")

    worker.run_until_idle
    assert_equal(
      "#{effect.effect_id}:provider-1",
      SolidObjects::Instance.find_by!(actor_id: "order-1").state.fetch("status")
    )
  ensure
    effect_executor&.stop
    worker&.stop
  end

  test "enqueues one failure result after effect retries are exhausted" do
    SolidObjects.configuration.max_attempts = 1
    SolidObjects.register_effect(:charge_payment) { raise "provider unavailable" }
    CheckoutActor.ref("order-1").checkout_with_result(payment_id: "payment-1")
    worker = SolidObjects::Worker.new
    worker.run_until_idle
    effect_executor = SolidObjects::EffectExecutor.new

    refute effect_executor.run_once

    effect = SolidObjects::Effect.first
    assert_equal "dead", effect.status
    failure_message = SolidObjects::Message.find_by!(
      idempotency_key: "effect:#{effect.effect_id}:failure"
    )
    assert_equal "payment_failed", failure_message.message_name
    assert_equal "RuntimeError", failure_message.arguments.dig("error", "class")
  ensure
    effect_executor&.stop
    worker&.stop
  end
end
