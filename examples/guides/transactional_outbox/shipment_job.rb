# rbs_inline: enabled

class ShipmentJob < ApplicationJob
  def perform(order_id:)
    order = Order.find(order_id)
    ShippingProvider.create_shipment(idempotency_key: "order-#{order.id}", order_reference: order.reference)
  end
end
