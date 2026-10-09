# frozen_string_literal: true

require_relative "guide_test_helper"
require_relative "../../examples/guides/transactional_outbox/shipment_job"
require_relative "../../examples/guides/transactional_outbox/order"
require_relative "../../examples/guides/transactional_outbox/outbox_message"
require_relative "../../examples/guides/transactional_outbox/checkout"

module ShippingProvider
  class LostResponse < StandardError; end

  class << self
    attr_accessor :shipments, :calls, :lose_next_response

    def reset
      self.shipments = {}
      self.calls = []
      self.lose_next_response = false
    end

    def create_shipment(idempotency_key:, order_reference:)
      calls << idempotency_key
      shipments[idempotency_key] ||= { "shipment_id" => "shipment-#{shipments.length + 1}", "order" => order_reference }
      if lose_next_response
        self.lose_next_response = false
        raise LostResponse, "the worker stopped before it recorded the result"
      end

      shipments.fetch(idempotency_key)
    end
  end
end

class TransactionalOutboxGuideTest < ActiveSupport::TestCase
  include SolidObjects::TestHelper
  include ActiveJob::TestHelper
  include GuideTestSupport

  class ProcessStopped < StandardError; end

  class StoppedProcessAdapter
    def enqueue(*)
      raise ProcessStopped, "the process stopped before the job reached the queue"
    end

    def enqueue_at(*)
      raise ProcessStopped, "the process stopped before the job reached the queue"
    end
  end

  setup do
    GuideSchema.reset
    ShippingProvider.reset
    SolidObjects.configuration.retry_delay = ->(_attempt) { 0 }
    load File.expand_path("../../examples/guides/transactional_outbox/solid_objects.rb", __dir__)
    Checkout.ensure_registered!
  end

  test "an order commits but its job is lost when the process stops before the enqueue" do
    test_adapter = ShipmentJob.queue_adapter
    ShipmentJob.queue_adapter = StoppedProcessAdapter.new

    assert_raises(ProcessStopped) { Order.place_and_enqueue!(reference: "order-1", total_cents: 1_500) }

    assert_equal 1, Order.count
    assert_empty test_adapter.enqueued_jobs
  ensure
    ShipmentJob.queue_adapter = test_adapter
  end

  test "the outbox message commits with the order or not at all" do
    OutboxMessage.define_singleton_method(:create!) { |**| raise ProcessStopped, "the disk is full" }

    assert_raises(ProcessStopped) { Order.place_with_outbox!(reference: "order-rolled-back", total_cents: 1_500) }
    OutboxMessage.singleton_class.remove_method(:create!)
    Order.place_with_outbox!(reference: "order-2", total_cents: 1_500)

    assert_equal [ "order-2" ], Order.pluck(:reference)
    assert_equal 1, OutboxMessage.pending.count
  ensure
    OutboxMessage.singleton_class.remove_method(:create!) if OutboxMessage.singleton_class.method_defined?(:create!, false)
  end

  test "the relay can send a message twice, so the job must be idempotent" do
    order = Order.place_with_outbox!(reference: "order-3", total_cents: 1_500)
    OutboxMessage.relay
    OutboxMessage.update_all(delivered_at: nil)
    OutboxMessage.relay

    perform_enqueued_jobs

    assert_equal [ "order-#{order.id}", "order-#{order.id}" ], ShippingProvider.calls
    assert_equal 1, ShippingProvider.shipments.length
    assert_equal 0, OutboxMessage.pending.count
  end

  test "a failed turn keeps no state, no order row, and no shipment request" do
    checkout = Checkout.ref("cart-failed")

    assert_raises(SolidObjects::MessageFailed) { checkout.place(total_cents: nil) }

    assert_equal "open", checkout.snapshot.status
    assert_equal 0, Order.count
    assert_equal 0, SolidObjects::Effect.count
  end

  test "a committed turn stores the state, the order row, and the shipment request together" do
    checkout = Checkout.ref("cart-placed")

    checkout.place(total_cents: 2_400)

    assert_equal "placed", checkout.snapshot.status
    assert_equal [ "cart-placed" ], Order.pluck(:reference)
    assert_equal [ "request_shipment" ], SolidObjects::Effect.pluck(:name)
  end

  test "a repeated place call stages one order and one shipment request" do
    checkout = Checkout.ref("cart-repeated")

    2.times { checkout.place(total_cents: 2_400) }

    assert_equal 1, Order.count
    assert_equal 1, SolidObjects::Effect.count
  end

  test "the effect runs again after a lost response and the provider creates one shipment" do
    checkout = Checkout.ref("cart-shipping")
    checkout.place(total_cents: 2_400)
    ShippingProvider.lose_next_response = true

    drain_solid_objects(roles: [ :effects, :actors ])
    assert_equal [ "pending" ], SolidObjects::Effect.pluck(:status)
    drain_solid_objects(roles: [ :effects, :actors ])

    assert_equal 2, ShippingProvider.calls.length
    assert_equal 1, ShippingProvider.calls.uniq.length
    assert_equal 1, ShippingProvider.shipments.length
    assert_equal "shipping", checkout.snapshot.status
    assert_equal "shipment-1", checkout.snapshot.shipment_id
  end
end
