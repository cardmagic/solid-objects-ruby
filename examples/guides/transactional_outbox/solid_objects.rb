# rbs_inline: enabled

SolidObjects.register_commit_action(:record_order) do |arguments, _context|
  Order.create!(reference: arguments.fetch("reference"), total_cents: arguments.fetch("total_cents"))
end

SolidObjects.register_effect(:request_shipment) do |arguments, context|
  ShippingProvider.create_shipment(
    idempotency_key: context.id,
    order_reference: arguments.fetch("order_reference")
  )
end
