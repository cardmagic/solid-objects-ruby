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

## Cross-process wake-up

Runtime roles poll for work and are woken early by an in-process signal. That
signal cannot cross process boundaries, so a commit in a Puma process does not
wake a broadcast executor in a worker process, and delivery waits out
`polling_interval`, 100 ms by default.

On PostgreSQL, install the notification adapter to remove that delay:

```ruby
# config/initializers/solid_objects.rb
configuration.wake_up_adapter = SolidObjects::WakeUpAdapters.for
```

`WakeUpAdapters.for` returns notifications on PostgreSQL and the in-process
default on SQLite and MySQL, so the same line is safe across adapters. Name
`SolidObjects::WakeUpAdapters::Postgresql.new` directly to require it.

MySQL has no notification primitive. MySQL applications either keep polling and
tune `polling_interval`, or configure the Redis adapter:

```ruby
configuration.wake_up_adapter = SolidObjects::WakeUpAdapters::Redis.new(
  url: ENV["REDIS_URL"]
)
```

Measured latency for a cross-process wake-up drops from 103.8 ms to 5.7 ms at
p50. The `redis` gem is not a dependency of this gem, so applications add it
themselves. One background subscription per process fans out to every waiting
role in memory, rather than one connection per thread, and `WakeUpAdapters.for`
does not select it: Redis is infrastructure this gem otherwise does not require,
so choosing it is explicit.

Measured latency for a cross-process wake-up drops from 103.7 ms to 2.9 ms at
p50. The adapter keeps `polling_interval` as the upper bound: a missed or failed
notification costs latency, never correctness, and signalling never raises into
the caller that committed. `LISTEN` needs its own connection, so the adapter
opens one outside the pool and releases it on `stop`.

Applications on SQLite or MySQL, or that do not configure the adapter, keep the
existing polling behaviour.

## Batched component refreshes

A component refresh costs one browser request. When one actor mutation changes
several components, the page pays one request per component. Adding `batch:`
groups them so a revision costs one request no matter how many components in the
group changed:

```erb
<%= actor.component :player, key: 1,
      observes: :player_one, batch: :playmat, refresh: :morph %>

<%= actor.component :player_controls, key: 1,
      observes: :player_one_controls, batch: :playmat, refresh: :morph %>

<%= actor.component :library_search, key: 1,
      observes: :library, batch: :playmat, refresh: :morph %>
```

Before, one mutation touching all three observables produced three requests:

```
commit -> 3 invalidations -> 3 refresh elements -> 3 GET /solid_objects/components
```

After, the three notifications coalesce in the browser into one request:

```
commit -> 3 invalidations -> 1 GET /solid_objects/components/batch -> 3 frames
```

### The batch endpoint

`GET /solid_objects/components/batch` takes the signed `tokens[]` of the
components to render plus the `instance_id` and `revision` the browser holds. It
returns HTML frames inside a JSON envelope:

```json
{
  "actor_type": "playmat_room",
  "actor_id": "table-1",
  "batch": "playmat",
  "instance_id": 12,
  "revision": 48,
  "frames": [
    {
      "target": "solid-objects-component-...",
      "revision": "12:48",
      "refresh_method": "morph",
      "html": "<turbo-frame id=\"...\" data-solid-objects-revision=\"12:48\">...</turbo-frame>"
    }
  ]
}
```

**Why frames inside JSON rather than one HTML document or pure JSON state.** HTML
alone would force the browser to pick frames out of an undocumented document.
Pure JSON would mean a second renderer and would give up ERB and Turbo morph. A
JSON envelope of frame descriptors keeps `ComponentRenderer` and Turbo exactly as
they are while giving the client a documented contract with per-frame revisions.

### What the protocol guarantees

Only components whose dependencies changed are requested; the rest are never
named in the batch. Notifications for the same batch and revision that arrive in
one task merge into a single request. Notifications that arrive in separate
WebSocket messages issue their own requests and all of their frames are applied,
because cancelling a same-revision request would drop the components it carried.
Only a strictly newer revision supersedes an in-flight request. Each
frame carries its own revision and cannot overwrite a target that already holds a
newer one. Authorization is unchanged: every component in the batch passes the
same `authorize_query` boundary an individual refresh uses, and the batch name is
signed into the component token, so a browser cannot invent or widen a group. A
batch mixing actors or groups is rejected.

Components without `batch:` keep issuing their own request, and a scope can mix
batched and unbatched components freely.

## Personalized state payloads

Reactive ERB components cost one browser request per changed component. When a
single actor mutation changes several components, an application pays several
round trips for one logical update. A payload broadcast collapses that into one
message on the stream the page already has open.

Declare the payload on the actor. The block runs against the actor instance,
like every other block in the actor DSL, and receives the actor and the
subscriber's authorization context as arguments. It runs **once per
subscriber**, so two sessions watching the same actor never see each other's
private state:

```ruby
class PlaymatRoom < SolidObjects::Actor
  actor_type "playmat_room"

  attribute :hands, default: -> { {} }
  attribute :turn, default: 1

  observable :turn

  broadcast_payload :playmat_state do |room, authorization_context|
    {
      "turn" => room.turn,
      "hand" => room.hands.fetch(authorization_context.session_id, [])
    }
  end
end
```

Because the block runs against the actor, an actor instance method is reachable
without a receiver, so shared logic does not have to be duplicated into the
block:

```ruby
broadcast_payload :playmat_state do |_room, authorization|
  { "turn" => turn, "hand" => hand_for(authorization.session_id) }
end
```

Subscribe the scope to it:

```erb
<%= solid_object room, payloads: :playmat_state do |actor| %>
  <div data-playmat></div>
<% end %>
```

Handle it with any JavaScript. The gem dispatches a DOM event and requires no
framework:

```javascript
document.addEventListener("solid-objects:payload", (event) => {
  const { name, revision, payload } = event.detail
  if (name !== "playmat_state") return

  renderPlaymat(payload)
})
```

### What the protocol guarantees

The payload travels as a Turbo Stream element on the existing actor stream, so
applications do not run a second WebSocket system. Each message carries the
actor identity plus the `instance_id` and monotonic `state_revision` that fence
component refreshes, and both the channel and the browser drop a payload that
is not newer than the last one delivered for that scope and name. A reconnecting
client receives the current payload on subscribe.

Authorization is the same `authorize_query` boundary that components use, called
with the payload name and the subscriber's Cable connection. A subscriber that
fails the check is skipped rather than served a partial payload, and the payload
name is signed into the stream token, so a browser cannot ask for a payload the
server did not offer.

Payload blocks read committed actor state through the same snapshot components
use. They cannot write application records, and the return value must be a JSON
object or array so the wire format stays inspectable.

A payload is one subscriber's view of one name, so a failure is confined to it.
A raising block does not reject the subscription, stop the other payload names,
or stop component refreshes on the same connection. The failure is reported as
`solid_objects.payload_broadcast_failed` carrying the actor type, actor id,
payload name, and exception class. The exception message is deliberately not
included: a payload block reads subscriber state, so its message is the one
place that state could leak into logs.

A revision with a failed payload does not advance the delivery watermark, so a
transient failure is retried on the next broadcast rather than being recorded as
delivered. Retries are driven by broadcasts rather than a timer, so a payload
that fails persistently retries once per actor mutation and reports each
attempt. A repeating stream of `payload_broadcast_failed` for one `payload_name`
therefore means a persistent fault in that block, not a one-off; a single event
that does not recur was transient and has already been recovered.

A payload the subscriber cannot query is skipped rather than served partially;
that decision is stable, so it settles the revision and the skip is silent by
design.

### mtg-playmat before and after

Before, one mutation that touched three observables produced three refresh
elements and three HTTP requests:

```
commit -> 3 Action Cable messages -> 3 GET /solid_objects/components -> 3 renders
```

After, the same mutation delivers one personalized payload and the page renders
once:

```
commit -> 1 Action Cable message -> 0 HTTP requests -> 1 render
```

Components remain the default. An actor with no `broadcast_payload` and a scope
with no `payloads:` option behave exactly as before.

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

A callback may also accept `registrations:`, which receives one registration for
a single component refresh and every registration in the group for a batch
refresh. This avoids decoding `params[:tokens]` by hand when a policy depends on
which components were requested:

```ruby
configuration.component_authorization_context = lambda do |controller:, registrations:|
  Current.user if registrations.all? { |registration| registration.component_key == controller.session[:seat] }
end
```

Callbacks that accept only `controller:` continue to work; the extra keyword is
passed only to callables that declare it.

Payloads have the same resolver, because they are computed inside the channel
rather than in a controller. Without one, a payload block and its
`authorize_query` call receive the Cable connection while a controller render
passes an application object, and the authorization hook has to tell them
apart. Resolve both to the same type and it does not:

```ruby
configuration.component_authorization_context = ->(controller:) { controller.current_account }
configuration.payload_authorization_context = ->(connection:) { connection.current_account }
```

The resolved value is what the payload block receives as its second argument and
what `authorize_query` receives as `authorization_context`. A resolver may also
accept `payload_name:` when the subject depends on which payload was requested.
The default returns the connection unchanged, so an application that has not
configured one is unaffected.

The contexts are intentionally different:

| Boundary | Authorization context |
| --- | --- |
| Initial Action View render | Explicit `authorization_context:` passed to `solid_object` |
| Action Cable subscription | The authenticated Cable connection |
| Component refresh | Value returned by `component_authorization_context` for the engine controller request |
| State payload | Value returned by `payload_authorization_context` for the Cable connection |

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

Stale components that share a `batch:` are refreshed together, exactly as a
live invalidation refreshes them, so reconnecting costs one request per batch
rather than one per component. That matters most on a restart, when every
client reconnects at once.

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
