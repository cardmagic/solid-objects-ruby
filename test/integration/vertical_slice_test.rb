# frozen_string_literal: true

require "database_test_helper"
require "timeout"

class VerticalSliceTest < ActiveSupport::TestCase
  class CartActor < SolidObjects::Actor
    actor_type "vertical-carts"

    attribute :items, default: -> { [] }

    def add(product_id:, quantity: 1)
      items << { "product_id" => product_id, "quantity" => quantity }
    end
  end

  class OlderCodeActor < SolidObjects::Actor
    actor_type "older-code"

    class << self
      attr_accessor :invoked
    end

    def run
      self.class.invoked = true
    end
  end

  test "processes one actor mailbox sequentially and persists every turn" do
    reference = CartActor.ref("alice")
    first_message = reference.add(product_id: "shirt", quantity: 2)
    second_message = reference.add(product_id: "pants")

    worker = SolidObjects::Worker.new
    processed_count = worker.run_until_idle

    assert_equal 2, processed_count
    assert_equal "completed", first_message.status
    assert_equal "completed", second_message.status
    assert_empty SolidObjects::ReadyMessage.all
    assert_empty SolidObjects::ClaimedMessage.all
    assert_equal(
      {
        "items" => [
          { "product_id" => "shirt", "quantity" => 2 },
          { "product_id" => "pants", "quantity" => 1 }
        ]
      },
      SolidObjects::Instance.find_by!(actor_type: "vertical-carts", actor_id: "alice").state
    )
  ensure
    worker&.stop
  end

  test "ask returns the durable result produced by another worker" do
    enqueued = Queue.new
    subscription = ActiveSupport::Notifications.subscribe("solid_objects.message.enqueued") do
      enqueued << true
    end
    result = Queue.new

    caller = Thread.new do
      result << CartActor.ref("alice").ask(:items, timeout: 2)
    rescue => error
      result << error
    end

    Timeout.timeout(2) { enqueued.pop }
    worker = SolidObjects::Worker.new
    worker.run_until_idle

    assert_equal [], Timeout.timeout(2) { result.pop }
    caller.join
  ensure
    ActiveSupport::Notifications.unsubscribe(subscription) if subscription
    worker&.stop
  end

  test "reads declared attributes through ordered query methods" do
    reference = CartActor.ref("alice")
    message_reference = reference.add(product_id: "shirt", quantity: 2)
    enqueued = Queue.new
    subscription = ActiveSupport::Notifications.subscribe("solid_objects.message.enqueued") do |event|
      enqueued << true if event.payload[:sequence] == 2
    end
    result = Queue.new

    caller = Thread.new do
      result << reference.items
    rescue => error
      result << error
    end

    Timeout.timeout(2) { enqueued.pop }
    worker = SolidObjects::Worker.new
    worker.run_until_idle
    items = Timeout.timeout(2) { result.pop }

    assert_equal(
      [ { "product_id" => "shirt", "quantity" => 2 } ],
      items
    )
    assert_predicate items, :frozen?
    assert_predicate items.first, :frozen?
    assert_raises(FrozenError) { items << { "product_id" => "pants" } }
    assert_equal "completed", message_reference.status
    query = SolidObjects::Message.order(:sequence).last
    assert_equal "items", query.message_name
    assert_equal "ask", query.message_kind
    caller.join
  ensure
    ActiveSupport::Notifications.unsubscribe(subscription) if subscription
    worker&.stop
  end

  test "refuses activation when persisted state is newer than running code" do
    OlderCodeActor.invoked = false
    message_reference = OlderCodeActor.ref("one").run
    instance = SolidObjects::Instance.find_by!(actor_type: "older-code")
    instance.update!(state_version: 2)
    worker = SolidObjects::Worker.new

    assert_equal 0, worker.run_once

    assert_not OlderCodeActor.invoked
    assert_equal "ready", message_reference.status
    assert_nil instance.reload.activation_owner_id
  ensure
    worker&.stop
  end
end
