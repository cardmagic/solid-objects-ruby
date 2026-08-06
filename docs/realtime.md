# Realtime integration

## Rendering

`actor_scope` performs initial server rendering and emits one
`turbo-cable-stream-source` for the actor:

```erb
<%= actor_scope ShoppingCartActor.ref(current_user.id) do |cart| %>
  Items: <%= cart.items_count %>
<% end %>
```

Every observable gets a stable opaque DOM ID. Multiple values share the one
actor subscription and Action Cable multiplexes actor subscriptions over the
browser's physical WebSocket.

`actor.component(:summary)` renders a host partial by convention at
`actors/<actor_class>/_summary`. Initial component rendering is implemented;
durable background component replacement is not yet implemented.

## Authorization

The HTML contains a signed actor identity token. Signing prevents modification;
it does not grant access. `ActorChannel` verifies the token, resolves the actor
through the registry, calls `authorize_subscription`, and streams only after
approval.

Initial observable method reads separately call `authorize_query`. Never
authorize solely from actor ID, token possession, stream name, or DOM ID.

## Broadcast durability

The actor's fenced commit compares observables before and after the turn and
inserts one broadcast row per changed value. A broadcast process later sends a
Turbo replacement and records delivery. No direct broadcast occurs inside the
actor transaction.

If Cable delivery is lost, reconnecting `ActorChannel` transmits replacements
from current actor state. The durable state row remains source of truth.

## Deployment

The default adapter calls `ActionCable.server.broadcast`; configure Action
Cable's normal production pub/sub adapter for a multi-process Rails deployment.
Redis may therefore be used by Action Cable, but Solid Objects itself does not
require Redis.

Changing or removing observable names during a rolling deploy can strand old
broadcast rows or old DOM targets. Keep old names compatible until the outbox
and old pages have drained.
