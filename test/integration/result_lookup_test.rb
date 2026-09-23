# frozen_string_literal: true

require "database_test_helper"

class ResultLookupTest < ActiveSupport::TestCase
  class CartActor < SolidObjects::Actor
    actor_type "lookup-carts"

    attribute :items, default: 0

    class << self
      attr_accessor :fail
    end

    def checkout(order_id:)
      raise "payment declined" if self.class.fail

      self.items += 1
      { "order_id" => order_id }
    end

    def reject_checkout
      reject("closed", "the cart is closed")
    end

    query :total do
      items
    end
  end

  setup do
    SolidObjects.configuration.retry_delay = ->(_attempt) { 0 }
    SolidObjects.configuration.max_attempts = 1
    CartActor.fail = false
  end

  test "finds a completed message by request id and reads its result" do
    CartActor.ref("alice").sync.checkout(order_id: 4210)
    original = SolidObjects::Message.sole

    found = SolidObjects.client.find_by(
      request_id: original.request_id,
      authorization_context: "operator"
    )

    assert_equal original.id, found.id
    assert_equal "completed", found.status
    assert_equal({ "order_id" => 4210 }, found.result)
  end

  test "reports no result for a message that was enqueued asynchronously" do
    original = CartActor.ref("alice").async.checkout(order_id: 4210)
    run_actors

    found = SolidObjects.client.find_by(request_id: original.request_id)

    assert_equal "completed", found.status
    assert_nil found.result
  end

  test "finds a completed message by idempotency key on its reference" do
    reference = CartActor.ref("alice")
    reference.sync(idempotency_key: "checkout-7f3a").checkout(order_id: 4210)
    original = SolidObjects::Message.sole

    found = reference.find_by(idempotency_key: "checkout-7f3a", authorization_context: "operator")

    assert_equal original.id, found.id
    assert_equal({ "order_id" => 4210 }, found.result)
  end

  test "the client and the reference find the same message" do
    reference = CartActor.ref("alice")
    reference.async(idempotency_key: "checkout-7f3a").checkout(order_id: 1)

    through_reference = reference.find_by(idempotency_key: "checkout-7f3a")
    through_client = SolidObjects.client.find_by(
      reference: reference,
      idempotency_key: "checkout-7f3a"
    )

    assert_equal through_reference.id, through_client.id
  end

  test "finds a message that has not run yet" do
    original = CartActor.ref("alice").async.checkout(order_id: 1)

    found = SolidObjects.client.find_by(request_id: original.request_id)

    assert_equal "ready", found.status
  end

  test "finds a dead message and reports its error and attempts" do
    CartActor.fail = true
    original = CartActor.ref("alice").async.checkout(order_id: 1)
    run_actors

    found = SolidObjects.client.find_by(request_id: original.request_id)
    outcome = found.outcome

    assert_equal "dead", found.status
    assert_equal "dead", outcome.status
    assert_equal 1, outcome.attempts
    assert_equal "RuntimeError", outcome.error.class_name
    assert_equal "payment declined", outcome.error.message
    assert_nil outcome.result
  end

  test "finds a rejected message and reports its rejection" do
    original = CartActor.ref("alice").async.reject_checkout
    run_actors

    found = SolidObjects.client.find_by(request_id: original.request_id)
    outcome = found.outcome

    assert_equal "rejected", found.status
    assert_equal "rejected", outcome.status
    assert_equal "closed", outcome.rejection.code
    assert_equal "the cart is closed", outcome.rejection.message
  end

  test "reports a completed outcome with its result" do
    CartActor.ref("alice").sync.checkout(order_id: 9)
    original = SolidObjects::Message.sole

    outcome = SolidObjects.client.find_by(request_id: original.request_id).outcome

    assert_equal "completed", outcome.status
    assert_equal({ "order_id" => 9 }, outcome.result)
    assert_nil outcome.error
    assert_nil outcome.rejection
  end

  test "returns nil for an unknown request id and an unknown key" do
    reference = CartActor.ref("alice")
    reference.async.checkout(order_id: 1)

    assert_nil SolidObjects.client.find_by(request_id: SecureRandom.uuid)
    assert_nil reference.find_by(idempotency_key: "never-used")
  end

  test "refuses a lookup that names no key" do
    error = assert_raises(ArgumentError) { SolidObjects.client.find_by }

    assert_match(/exactly one of/, error.message)
  end

  test "refuses a lookup that names both keys" do
    error = assert_raises(ArgumentError) do
      SolidObjects.client.find_by(request_id: "one", idempotency_key: "two")
    end

    assert_match(/exactly one of/, error.message)
  end

  test "refuses an idempotency key without a reference" do
    error = assert_raises(ArgumentError) do
      SolidObjects.client.find_by(idempotency_key: "checkout-7f3a")
    end

    assert_match(/requires reference/, error.message)
  end

  test "refuses an unknown keyword" do
    assert_raises(ArgumentError) { SolidObjects.client.find_by(bogus: "one") }
  end

  test "returns nil to a caller that cannot read the message" do
    original = CartActor.ref("alice").async.checkout(order_id: 1)
    SolidObjects.configuration.authorize_message = ->(**) { false }

    assert_nil SolidObjects.client.find_by(
      request_id: original.request_id,
      authorization_context: "stranger"
    )
    assert_nil CartActor.ref("alice").find_by(idempotency_key: "never-used")
  end

  test "authorizes against the stored operation and arguments" do
    reference = CartActor.ref("alice")
    original = reference.async(idempotency_key: "checkout-7f3a").checkout(order_id: 4210)
    seen = []
    SolidObjects.configuration.authorize_message = lambda do |operation:, arguments:, **|
      seen << [ operation, arguments ]
      true
    end

    SolidObjects.client.find_by(request_id: original.request_id)

    assert_equal [ [ "checkout", { "order_id" => 4210 } ] ], seen
  end

  test "uses the query hook for a query message" do
    CartActor.ref("alice").sync.total
    original = SolidObjects::Message.sole
    hooks = []
    SolidObjects.configuration.authorize_query = ->(**) { hooks << :query and true }
    SolidObjects.configuration.authorize_message = ->(**) { hooks << :message and true }

    SolidObjects.client.find_by(request_id: original.request_id)

    assert_equal [ :query ], hooks
  end

  test "does not find a key that belongs to another instance" do
    CartActor.ref("alice").async(idempotency_key: "checkout-7f3a").checkout(order_id: 1)

    assert_nil CartActor.ref("bob").find_by(idempotency_key: "checkout-7f3a")
  end

  test "rebuilds a reference that can wait for its result" do
    reference = CartActor.ref("alice")
    reference.async(idempotency_key: "checkout-7f3a").checkout(order_id: 4210)
    found = reference.find_by(idempotency_key: "checkout-7f3a")

    run_actors
    found.wait(timeout: 2.0)

    assert_equal "completed", found.status
    assert_equal 1, CartActor.ref("alice").snapshot.items
  end

  private

  def run_actors
    worker = SolidObjects::Worker.new
    worker.run_until_idle
  ensure
    worker&.stop
  end
end
