# rbs_inline: enabled

SolidObjects.configure do |configuration|
  configuration.authorize_message = lambda do |actor_type:, actor_id:, authorization_context:, **|
    user = if authorization_context.respond_to?(:current_user)
      authorization_context.current_user
    else
      authorization_context
    end
    next false unless user

    if actor_type == ShoppingCartActor.actor_type
      user.id.to_s == actor_id
    else
      ChatRoomPolicy.new(user).access?(actor_id)
    end
  end
  configuration.authorize_query = configuration.authorize_message
  configuration.authorize_subscription = configuration.authorize_message
  configuration.component_authorization_context = ->(controller:) { Current.user }
end

SolidObjects.register_effect(:charge_payment) do |arguments, context|
  Payments.charge(
    idempotency_key: context.id,
    payment_id: arguments.fetch("payment_id"),
    amount_cents: arguments.fetch("amount_cents")
  )
end
