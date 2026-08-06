# frozen_string_literal: true

require "test_helper"

class ActorTest < ActiveSupport::TestCase
  class CartActor < SolidObjects::Actor
    actor_type "test-carts"

    attribute :items, default: -> { [] }
    attribute :status, default: "open"

    message :add do |product_id:, quantity: 1|
      state.items << { "product_id" => product_id, "quantity" => quantity }
    end

    query :count do
      state.items.sum { |item| item.fetch("quantity") }
    end

    observable :count do
      state.items.sum { |item| item.fetch("quantity") }
    end
  end

  test "builds references from a registered logical actor type" do
    reference = CartActor.ref("alice")

    assert_equal "test-carts", reference.actor_type
    assert_equal "alice", reference.actor_id
    assert_equal CartActor, SolidObjects.registry.fetch(reference.actor_type)
  end

  test "executes messages and queries against actor state" do
    actor = build_actor

    actor.invoke("add", { "product_id" => "shirt", "quantity" => 2 })

    assert_equal 2, actor.invoke("count", {})
    assert_equal [ { "product_id" => "shirt", "quantity" => 2 } ], actor.state.items
  end

  test "rejects messages that were not declared" do
    assert_raises(SolidObjects::UnknownMessage) do
      build_actor.invoke("destroy_everything", {})
    end
  end

  test "does not share mutable defaults between activations" do
    first_actor = build_actor("first")
    second_actor = build_actor("second")

    first_actor.state.items << { "product_id" => "shirt", "quantity" => 1 }

    assert_empty second_actor.state.items
  end

  test "reads observable values from current state" do
    actor = build_actor
    actor.invoke("add", { "product_id" => "shirt", "quantity" => 3 })

    assert_equal({ "count" => 3 }, actor.observable_values)
  end

  test "rejects synchronous ask from actor context" do
    reference = CartActor.ref("other")

    error = assert_raises(SolidObjects::ActorCallCycle) do
      SolidObjects::Context.with(actor: build_actor, message: nil) do
        reference.ask(:count)
      end
    end

    assert_match(/cannot synchronously wait/, error.message)
  end

  private

  def build_actor(actor_id = "alice")
    SolidObjects::State.new(CartActor.definition.state_definition).then do |state|
      CartActor.new(actor_id:, state:)
    end
  end
end
