# Realtime integration

## Scalars and components

`solid_object` performs initial server rendering and emits one
`turbo-cable-stream-source` for the actor:

```erb
<%= solid_object ShoppingCartActor.ref(current_user.id),
  authorization_context: current_user do |cart| %>
  Items: <%= cart.items_count %>
  <%= cart.component :summary, observes: %i[items checkout_status] %>
<% end %>
```

Every observable gets a stable opaque DOM ID. Multiple values share the one
actor subscription and Action Cable multiplexes actor subscriptions over the
browser's physical WebSocket.

Scalar observable calls such as `cart.items_count` render stable `<span>`
targets. Their broadcast remains a direct escaped text replacement.

A reactive component declares one or more explicit observable dependencies.
`actor.component(:summary, observes: ...)` resolves the host partial by
convention at `actors/<actor_class>/_summary` and wraps it in a stable Turbo
Frame. Reactive components do not accept `partial:` because a client must
never influence partial resolution. The older
`actor.component(:summary, partial: "server/chosen/path")` form remains
available for initial-only static rendering.

The partial receives these built-in component locals:

- `actor`, which exposes the declared observables as deeply frozen ordinary
  Ruby values plus `actor_id` and `reference`; and
- `authorization_context`, the context for this initial render or refresh.
- `component_key`, the signed string or integer key, or `nil` for an unkeyed
  component.

Applications can declare additional JSON-compatible locals. They are
normalized, signed into the component token, deeply frozen, and supplied on
both the initial render and every refresh:

```erb
<% @players.each do |player| %>
  <%= actor.component :player,
    key: player.id,
    observes: %i[players life_totals],
    locals: { player_id: player.id } %>
<% end %>
```

This resolves every instance to the same `_player.html.erb` partial while
giving each one a distinct opaque DOM target. The `(component name, key)` pair
must be unique within one `solid_object` scope. An unkeyed component retains
the existing target and uniqueness behavior.

Local names must be valid Ruby local identifiers. `actor`,
`authorization_context`, and `component_key` are reserved. Local values must
use the same safe JSON value set as actor messages. Tokens are limited to
16 KiB and one subscription accepts at most 50 components, so locals should be
small identifiers or rendering options rather than copied actor state.

`actor.state` is unavailable in reactive components. Reading an observable not
listed in `observes:` raises `UnknownComponentDependency`. This keeps
invalidation correct and prevents a partial from silently depending on state
that cannot wake it.

```erb
<ul>
  <% actor.recent_messages.each do |message| %>
    <li><%= message.fetch("body") %></li>
  <% end %>
</ul>
```

Arrays, hashes, loops, conditionals, nested markup, and host helper output are
normal ERB. Escaping remains Action View's responsibility; Solid Objects never
marks actor strings as HTML safe.

## Replace and morph refreshes

Reactive components use `refresh: :replace` by default. The existing path
replaces the target with a Turbo Frame whose signed URL performs the authorized
request-time render.

Use `refresh: :morph` when preserving unchanged DOM nodes matters:

```erb
<%= actor.component :battlefield,
  key: player.id,
  observes: %i[battlefields zone_counts],
  locals: { player_id: player.id },
  refresh: :morph %>
```

Morph invalidations append a short-lived gem-owned browser element to the
actor scope. It fetches the same signed component endpoint with normal
same-origin cookies, aborts an older request for the same keyed target, and
converts the authorized response into Turbo's scoped
`replace method="morph"`. Before applying it, the browser compares the
response's `(instance_id, state_revision)` with the current target. An older
response cannot overwrite newer HTML.

The engine exposes the `solid_objects/component_refresh` module through the
host asset pipeline and `solid_object` includes it only when the scope contains
a morph component. No host Stimulus controller, custom channel, custom stream
action, or polling loop is required. Default Propshaft and Sprockets
applications discover the namespaced engine asset. Applications created with
`--skip-asset-pipeline` should keep the default replace strategy unless they
explicitly serve the module. Turbo's normal morph rules still apply; use
`data-turbo-permanent` for elements that must never be changed.

## Authorization

The HTML contains a signed actor identity token. Signing prevents modification;
it does not grant access. `ActorChannel` verifies the token, resolves the actor
through the registry, calls `authorize_subscription`, and streams only after
approval.

Initial scalar and component reads call `authorize_query` with the context
passed to `solid_object`. The refresh controller resolves a new request context
through `component_authorization_context`, then calls `authorize_query` again
for the component name and every declared dependency. Keyed registrations pass
their `component_key` plus all declared locals as `arguments` at both
boundaries. The default resolver supplies the engine controller; applications
commonly resolve it to `Current.user`:

```ruby
configuration.component_authorization_context = ->(controller:) { Current.user }
```

The three contexts are intentionally different:

| Boundary | Authorization context |
| --- | --- |
| Initial Action View render | Explicit `authorization_context:` passed to `solid_object` |
| Action Cable subscription | The authenticated Cable connection |
| Component refresh | Value returned by `component_authorization_context` for the engine controller request |

Do not substitute a signed token for any of them. Keys and locals are visible
to the browser and signed for integrity, not encrypted or authorized. Never
authorize solely from actor ID, token possession, stream name, component name,
component key, locals, or DOM ID.

## Broadcast durability

The actor's fenced commit compares observables before and after the turn and
inserts one broadcast row per changed value. The actor state, monotonic
`state_revision`, message completion, and broadcast rows commit atomically. A
rolled-back or fenced-out turn therefore cannot invalidate a component.

A broadcast process later sends small invalidation metadata and records
delivery. Its scalar Turbo replacement is transmitted only when that observable
target was rendered and signed into the scope's stream token. Component-only
dependencies therefore do not expose their serialized values over Cable. The
runtime never stores or broadcasts personalized component HTML. Each
authorized browser requests affected components through the engine endpoint
with its normal cookies. Responses are `private, no-store`.

Several changed dependencies from one message sequence produce one logical
refresh for each keyed component registration. An unrelated observable does
not refresh it. If a newer invalidation arrives while a replace request is in
flight, the new frame replaces the old frame element; the detached older
response has no current target. Morph requests are coalesced per target with an
`AbortController` and perform a final client-side revision comparison.

If Cable delivery is lost, reconnecting `ActorChannel` transmits replacements
from current actor state. It compares the signed component revision with the
latest `(instance_id, state_revision)` pair and refreshes stale components.
The incarnation ID handles destroy-and-recreate; the state revision handles
ordered commits within one incarnation. Out-of-order invalidations at or below
the last transmitted pair are ignored. The durable state row remains source of
truth.

The component endpoint rejects a requested revision newer than the committed
snapshot. This is a final server-side guard; browser safety primarily comes
from monotonic channel filtering plus replace-frame detachment or morph
response revision fencing.

## Cost model

The durable row cost is unchanged: one broadcast row per changed observable,
containing its JSON value and the message/instance references needed to derive
invalidation metadata. No rendered document is stored. Each affected component
adds one authorized GET and one partial render per non-coalesced state
revision. A repeated keyed component adds one GET and render per key. Signed
locals increase page and Cable subscription bytes but do not create durable
rows. Scalar observables remain the cheaper path for one text value.

## Deployment

The default adapter calls `ActionCable.server.broadcast`; configure Action
Cable's normal production pub/sub adapter for a multi-process Rails deployment.
Redis may therefore be used by Action Cable, but Solid Objects itself does not
require Redis.

Changing or removing observable names during a rolling deploy can strand old
broadcast rows or old DOM targets. Keep old names compatible until the outbox
and old pages have drained. Keep component partial names and dependency
observables compatible across a rolling deploy for the same reason.

Reactive components require the engine mount because their signed refresh path
is generated from that mount. Applications with more than one engine mount can
set `component_path_resolver` to return the intended same-origin
`components_path`.

```ruby
# config/routes.rb
mount SolidObjects::Engine => "/solid_objects"
```
