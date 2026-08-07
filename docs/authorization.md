# Authorization policies

Solid Objects treats actor identities as identifiers, never capabilities.
Knowing an actor ID, message ID, or signed stream token grants no permission.
All five policies deny by default, so a generated installation is
intentionally inert until the host application defines its trust boundary.

## Policy reference

| Policy | Gates | Caller context | Risk if opened globally |
| --- | --- | --- | --- |
| `authorize_message` | Direct actor methods, explicit `sync` messages, and public `async` enqueue | Value passed as `authorization_context:`; often a user, service principal, or trusted internal marker | Anyone reaching the call site can mutate any known actor identity |
| `authorize_query` | Attribute reads, declared queries, committed snapshots, scalar observable reads, initial component rendering, and every component refresh dependency | Explicit call context, the context passed to `solid_object`, or the request context resolved for a component refresh | Actor state or personalized projections can leak across users or tenants |
| `authorize_destroy` | `reference.destroy` | Value passed as `authorization_context:` | Complete actor state, mailbox, reminders, and pending outboxes can be deleted |
| `authorize_subscription` | Action Cable subscription to one actor stream | The `ActionCable::Connection` object | Clients can receive future observable updates for other actors |
| `authorize_administration` | Engine administration controllers, process inspection/cleanup/pruning, message pruning, and dead-letter inspection/retry | Rails controller or `{ source: "cli" }` | Operational metadata, arguments, errors, deletion, and retries become exposed or mutable |

Waiting again through `MessageReference#wait` reauthorizes the stored
invocation as a message or query. Internal reminder, effect-callback, and
actor-to-actor deliveries come from
already committed runtime rows and do not re-enter the public client policy.

## Realtime authorization contexts

Reactive components cross three Rails execution contexts and authorize at all
three boundaries:

1. `solid_object(..., authorization_context:)` uses the explicit Action View
   render context for initial scalar and component reads.
2. `ActorChannel` passes its authenticated `ActionCable::Connection` to
   `authorize_subscription`.
3. `ComponentsController` resolves a fresh context for the cookie-bearing HTTP
   request and calls `authorize_query` for every component dependency.

Configure the refresh resolver when the query policy expects a user or service
principal rather than the engine controller:

```ruby
SolidObjects.configure do |configuration|
  configuration.component_authorization_context = lambda do |controller:|
    Current.user
  end
end
```

Authentication middleware must populate `Current.user` for the refresh
request. Do not copy an Action View object or Cable connection into the signed
token. Those objects are request-specific and the token provides integrity,
not authorization.

Component partials receive the resolved value as the
`authorization_context` local, allowing two authorized viewers to render
different projections. Responses use `Cache-Control: private, no-store`.
Durable outbox rows and shared Cable messages never contain component HTML.
The stream token also signs the scalar observable targets rendered into that
specific scope. Component-only dependencies send invalidation metadata but not
their state value to the browser.

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

For commands executed only on hosts where shell access is already the
authenticated administration boundary, the generated initializer shows an
optional CLI-scoped policy:

```ruby
configuration.authorize_administration = lambda do |authorization_context:, **|
  authorization_context.is_a?(Hash) &&
    authorization_context[:source] == "cli"
end
```

Run `bin/rails solid_objects:doctor` after configuration. Its neutral policy
probe is deliberately conservative: a context-aware policy may correctly warn
because it denies a `nil` context.
