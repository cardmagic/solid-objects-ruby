# rbs_inline: enabled

SolidObjects.register_effect(:push_subscription) do |arguments, _context|
  BillingApi.push_subscription(
    idempotency_key: arguments.fetch("idempotency_key"),
    customer_id: arguments.fetch("customer_id"),
    version: arguments.fetch("version"),
    plan: arguments.fetch("plan")
  )
end
