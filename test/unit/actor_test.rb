# frozen_string_literal: true

require "test_helper"

class ActorTest < ActiveSupport::TestCase
  class CartActor < SolidObjects::Actor
    actor_type "test-carts"

    attribute :items, default: -> { [] }
    attribute :status, default: "open"

    def add(product_id:, quantity: 1)
      items << { "product_id" => product_id, "quantity" => quantity }
    end

    def close
      self.status = "closed"
    end

    query :count do
      items.sum { |item| item.fetch("quantity") }
    end

    observable :count do
      items.sum { |item| item.fetch("quantity") }
    end
  end

  class CounterActor < SolidObjects::Actor
    attribute :value, default: 0

    def increment(amount: 1)
      self.value += amount
    end

    private

    def reset
      self.value = 0
    end
  end

  test "builds references from a registered logical actor type" do
    reference = CartActor.ref("alice")

    assert_equal "test-carts", reference.actor_type
    assert_equal "alice", reference.actor_id
    assert_equal CartActor, SolidObjects.registry.fetch(reference.actor_type)
    assert_respond_to reference, :items
    assert_respond_to reference, :add
    assert_respond_to reference, :count
  end

  test "executes messages and queries against actor state" do
    actor = build_actor

    actor.invoke("add", { "product_id" => "shirt", "quantity" => 2 })
    actor.invoke("close", {})

    assert_equal 2, actor.invoke("count", {})
    assert_equal [ { "product_id" => "shirt", "quantity" => 2 } ], actor.items
    assert_equal "closed", actor.status
  end

  test "exposes declared attributes as queries" do
    actor = build_actor

    assert_equal [], actor.invoke("items", {})
    assert CartActor.definition.queries.key?(:items)
  end

  test "reads and writes attributes through actor methods" do
    actor = SolidObjects::State.new(CounterActor.definition.state_definition).then do |state|
      CounterActor.new(actor_id: "global", state:)
    end

    actor.invoke("increment", { "amount" => 5 })

    assert_equal 5, actor.value
  end

  test "exposes public actor methods as messages" do
    assert CounterActor.definition.messages.key?(:increment)
    assert_respond_to CounterActor.ref("global"), :increment
  end

  test "does not expose private actor methods as messages" do
    assert_not CounterActor.definition.messages.key?(:reset)
    assert_not_respond_to CounterActor.ref("global"), :reset
  end

  test "rejects messages that were not declared" do
    assert_raises(SolidObjects::UnknownMessage) do
      build_actor.invoke("destroy_everything", {})
    end
  end

  test "rejects attributes that overwrite actor methods" do
    error = assert_raises(SolidObjects::InvalidActor) do
      Class.new(SolidObjects::Actor) do
        attribute :state
      end
    end

    assert_match(/conflicts with actor method state/, error.message)
  end

  test "rejects actor methods that overwrite attributes" do
    actor_class = Class.new(SolidObjects::Actor) do
      attribute :value, default: 0
    end
    actor_class.send(:remove_method, :value)
    actor_class.class_eval { define_method(:value) { 42 } }

    error = assert_raises(SolidObjects::InvalidActor) { actor_class.definition }

    assert_match(/actor method value overrides attribute :value/, error.message)
  end

  test "does not share mutable defaults between activations" do
    first_actor = build_actor("first")
    second_actor = build_actor("second")

    first_actor.items << { "product_id" => "shirt", "quantity" => 1 }

    assert_empty second_actor.items
  end

  test "reads observable values from current state" do
    actor = build_actor
    actor.invoke("add", { "product_id" => "shirt", "quantity" => 3 })

    assert_equal({ "count" => 3 }, actor.observable_values)
  end

  test "rejects synchronous queries from actor context" do
    reference = CartActor.ref("other")

    error = assert_raises(SolidObjects::ActorCallCycle) do
      SolidObjects::Context.with(actor: build_actor, message: nil) do
        reference.count
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
