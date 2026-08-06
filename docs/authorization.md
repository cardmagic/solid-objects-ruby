# Authorization policies

Solid Objects treats actor identities as identifiers, never capabilities.
Knowing an actor ID, message ID, or signed stream token grants no permission.
All five policies deny by default, so a generated installation is
intentionally inert until the host application defines its trust boundary.

## Policy reference

| Policy | Gates | Caller context | Risk if opened globally |
| --- | --- | --- | --- |
| `authorize_message` | Direct actor methods, explicit `sync` messages, and public `async` enqueue | Value passed as `authorization_context:`; often a user, service principal, or trusted internal marker | Anyone reaching the call site can mutate any known actor identity |
| `authorize_query` | Attribute reads, declared queries, observable reads, and component reads | Explicit call context or the Rails view context supplied by `solid_object` | Actor state can leak across users or tenants |
| `authorize_destroy` | `reference.destroy` | Value passed as `authorization_context:` | Complete actor state, mailbox, reminders, and pending outboxes can be deleted |
| `authorize_subscription` | Action Cable subscription to one actor stream | The `ActionCable::Connection` object | Clients can receive future observable updates for other actors |
| `authorize_administration` | Engine administration controllers, process inspection/cleanup, and dead-letter inspection/retry | Rails controller or `{ source: "cli" }` | Operational metadata, arguments, errors, and retries become exposed or mutable |

Internal reminder, effect-callback, and actor-to-actor deliveries come from
already committed runtime rows and do not re-enter the public client policy.

## A tenant-aware policy

Pass the authenticated user as the call context:

```ruby
cart = ShoppingCart.ref(Current.user.id)
cart.add_item(
  product_id: "shirt-123",
  authorization_context: Current.user
)
```

Authorize only the matching user and actor type:

```ruby
SolidObjects.configure do |configuration|
  owns_actor = lambda do |actor_type:, actor_id:, authorization_context:, **|
    user = authorization_context

    actor_type == "ShoppingCart" &&
      user.present? &&
      actor_id == user.id.to_s
  end

  configuration.authorize_message = owns_actor
  configuration.authorize_query = owns_actor
  configuration.authorize_destroy = owns_actor

  configuration.authorize_subscription = lambda do |actor_type:, actor_id:, authorization_context:|
    connection = authorization_context

    actor_type == "ShoppingCart" &&
      connection.current_user.present? &&
      actor_id == connection.current_user.id.to_s
  end

  configuration.authorize_administration = lambda do |authorization_context:, **|
    context = authorization_context
    user = context.respond_to?(:current_user) ? context.current_user : nil

    user&.administrator?
  end
end
```

The policy receives normalized actor type and ID strings, message name and
arguments where relevant, and the context supplied by the caller. Avoid
authorizing from arguments alone; bind the actor identity to the authenticated
principal and tenant.

## Server-side-only pilots

Allowing `authorize_message` and `authorize_query` unconditionally can be a
reasonable short-lived pilot only when every call site is trusted server code,
actor IDs cannot come from an unauthorized request, and the feature is not
exposed through Action Cable or administration routes.

Keep `authorize_destroy`, `authorize_subscription`, and
`authorize_administration` denied until each feature has an explicit policy.
Replace unconditional policies before exposing actor IDs to controllers, API
clients, MCP tools, jobs carrying user input, or browser subscriptions.

Run `bin/rails solid_objects:doctor` after configuration. Its neutral policy
probe is deliberately conservative: a context-aware policy may correctly warn
because it denies a `nil` context.
