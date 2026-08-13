# frozen_string_literal: true

require "database_test_helper"

class EnqueueTest < ActiveSupport::TestCase
  class CartActor < SolidObjects::Actor
    actor_type "enqueue-carts"

    attribute :items, default: -> { [] }

    def add(product_id:)
      items << product_id
    end
  end

  test "async atomically creates durable history and ready membership" do
    message_reference = CartActor.ref("alice").async.add(product_id: "shirt")
    message = SolidObjects::Message.find(message_reference.id)

    assert_equal 1, message.sequence
    assert_equal "async", message.message_kind
    assert_equal({ "product_id" => "shirt" }, message.arguments)
    assert message.ready?
    assert_not message.completed?
    assert_equal message.id, message_reference.id
  end

  test "allocates explicit per-actor sequences" do
    reference = CartActor.ref("alice")

    references = 3.times.map do |index|
      reference.async.add(product_id: "product-#{index}")
    end

    assert_equal [ 1, 2, 3 ], references.map(&:sequence)
    assert_equal 4, SolidObjects::Instance.find_by!(actor_type: "enqueue-carts", actor_id: "alice").next_message_sequence
  end

  test "allocates unique sequences under concurrent enqueue" do
    reference = CartActor.ref("alice")
    start = Queue.new
    results = Queue.new
    errors = Queue.new

    threads = 8.times.map do |index|
      Thread.new do
        SolidObjects::Record.connection_pool.with_connection do
          start.pop
          results << reference.async.add(product_id: "product-#{index}").sequence
        rescue => error
          errors << error
        end
      end
    end

    threads.length.times { start << true }
    threads.each(&:join)

    assert_empty errors.size.times.map { errors.pop }
    assert_equal (1..8).to_a, results.size.times.map { results.pop }.sort
  end

  test "deduplicates the same idempotent enqueue" do
    reference = CartActor.ref("alice")

    first = reference.async(idempotency_key: "cart-add-shirt").add(product_id: "shirt")
    second = reference.async(idempotency_key: "cart-add-shirt").add(product_id: "shirt")

    assert_equal first.id, second.id
    assert_equal 1, SolidObjects::Message.count
    assert_equal 1, SolidObjects::ReadyMessage.count
  end

  test "rejects an idempotency key reused for another invocation" do
    reference = CartActor.ref("alice")
    reference.async(idempotency_key: "cart-add").add(product_id: "shirt")

    assert_raises(SolidObjects::IdempotencyConflict) do
      reference.async(idempotency_key: "cart-add").add(product_id: "pants")
    end
  end

  test "rejects an undeclared message before persistence" do
    assert_raises(SolidObjects::UnknownMessage) do
      CartActor.ref("alice").async.erase
    end

    assert_empty SolidObjects::Message.all
  end

  test "enforces message authorization before persistence" do
    SolidObjects.configuration.authorize_message = ->(**) { false }

    assert_raises(SolidObjects::Unauthorized) do
      CartActor.ref("alice").async.add(product_id: "shirt")
    end

    assert_empty SolidObjects::Message.all
  end

  test "enforces the actor mailbox limit" do
    SolidObjects.configuration.max_mailbox_length = 1
    reference = CartActor.ref("alice")
    reference.async.add(product_id: "shirt")

    assert_raises(SolidObjects::MailboxFull) do
      reference.async.add(product_id: "pants")
    end
  end

  test "schedules a delayed asynchronous message without passing availability to the actor" do
    available_at = 30.minutes.from_now

    message_reference = CartActor.ref("alice").async(available_at:).add(product_id: "shirt")
    ready_message = SolidObjects::ReadyMessage.find_by!(message_id: message_reference.id)

    assert_in_delta available_at.to_f, ready_message.available_at.to_f, 0.01
    assert_equal({ "product_id" => "shirt" }, SolidObjects::Message.find(message_reference.id).arguments)
  end
end
