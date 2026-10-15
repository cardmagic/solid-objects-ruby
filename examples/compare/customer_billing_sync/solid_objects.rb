# rbs_inline: enabled

SolidObjects.register_effect(:push_subscription) do |arguments, context|
  BillingApi.push_subscription(
    idempotency_key: context.id,
    customer_id: arguments.fetch("customer_id"),
    version: arguments.fetch("version"),
    plan: arguments.fetch("plan")
  )
end
