# Solid Objects

[![CI](https://github.com/cardmagic/solid_objects/actions/workflows/ci.yml/badge.svg)](https://github.com/cardmagic/solid_objects/actions/workflows/ci.yml)

**Cloudflare Durable Objects, ported to Rails.**

Solid Objects brings the Durable Objects programming model—addressable objects,
durable state, serialized turns, alarms, and live clients—to ordinary Rails
applications. It runs on the MySQL, PostgreSQL, or SQLite database the
application already has, following the database-backed operating model of the
Solid family. No Redis, Cloudflare account, or separate actor service is
required.

```ruby
class Counter < SolidObjects::Actor
  attribute :value, default: 0

  def increment(amount: 1)
    self.value += amount
  end
end

# Synchronous caller-assisted RPC. No worker fleet is required.
counter = Counter.ref("global")
count = counter.increment(amount: 5)
current_count = counter.value
current_snapshot = counter.snapshot.value

# Durable fire-and-forget delivery. A worker processes it later.
message = counter.async.increment(amount: 5)
```

`Counter / global` is a logical identity. Like a Durable Object named with
`idFromName`, it can be addressed from anywhere without first creating or
locating a Ruby object. Solid Objects activates it when work arrives, commits
its ordered turns one at a time, persists its state, and deactivates it when
idle. Different identities can run concurrently.

The invocation model is the first adoption decision:

| Call | Returns | Worker fleet required? |
| --- | --- | --- |
| `counter.increment(amount: 5)` | Committed handler result | No |
| `counter.sync(timeout: 5.seconds).increment(amount: 5)` | Committed handler result | No |
| `counter.value` | Ordered, committed query result | No |
| `counter.snapshot.value` | Current committed state without a mailbox message | No |
| `counter.async.increment(amount: 5)` | `MessageReference` immediately | Yes |

Direct methods and `sync` durably enqueue the call, then the Rails caller helps
execute the actor through the same mailbox, lease, and fencing path as a
worker. `async` only enqueues; a runtime process handles it later.

Synchronous calls fail before enqueue when the Solid Objects database
connection is already inside a transaction. Actor handlers may read application
records, but direct Active Record writes are rejected so they cannot escape a
later actor failure. Use a same-database
[`commit_action`](#application-database-writes) for atomic database changes and
[`emit`](#effects) for external I/O.

Before adopting a latency-sensitive or high-volume surface, read
[Is Solid Objects a good fit?](docs/fit.md) and the
[measured performance and row-growth costs](docs/benchmarks.md).

This is a port of the programming model, not Cloudflare's edge runtime or
platform. Read the conceptual overview at [solidobjects.dev](https://solidobjects.dev/)
and the exact Rails guarantees in [Correctness and delivery semantics](docs/correctness.md).

Solid Objects is an early release. Its correctness core is implemented and
tested, but the project does not yet claim production readiness. See
[Status](#status) and the [roadmap](docs/roadmap.md).

## Table of contents

- [Cloudflare Durable Objects for Rails](#cloudflare-durable-objects-for-rails)
- [Reactive ERB](#reactive-erb)
- [Installation](#installation)
- [Upgrading](#upgrading)
- [Worker requirements](#worker-requirements)
- [Defining an actor](#defining-an-actor)
- [Actor identity](#actor-identity)
- [Invoking an object](#invoking-an-object)
- [Application database writes](#application-database-writes)
- [Effects](#effects)
- [Reminders](#reminders)
- [Destroying an object](#destroying-an-object)
- [State migrations](#state-migrations)
- [Configuration](#configuration)
- [Workers and operations](#workers-and-operations)
- [Database support](#database-support)
- [Guarantees](#guarantees)
- [When to use it](#when-to-use-it)
- [Comparisons](#comparisons)
- [Development](#development)
- [Status](#status)
- [License](#license)

## Cloudflare Durable Objects for Rails

Cloudflare Durable Objects combine a name, durable storage, serialized
execution, alarms, and live connections in one stateful object. Solid Objects
maps those ideas into Rails:

| Cloudflare Durable Objects | Solid Objects |
| --- | --- |
| Namespace plus `idFromName("id")` | Actor class plus `.ref("id")` |
| RPC method on a stub | Public Ruby method on a reference |
| Per-object transactional storage | Declared attributes in native JSON |
| Single-threaded input handling | Ordered mailbox plus fenced activation |
| Alarms API | Per-object `schedule` |
| WebSockets | Reactive ERB over Action Cable and Turbo Streams |
| Hibernation when idle | Idle activation deactivation |
| Storage deletion | Authorized `reference.destroy` |
| Cloudflare Workers platform | Your Rails processes and SQL database |

Rails already has excellent tools for jobs, records, and realtime transport.
None of those primitives alone provides this complete stateful-object shape.
Solid Objects adds five capabilities:

### Ordered delivery per identity

Every enqueue locks the actor instance and allocates an explicit, monotonically
increasing sequence number. An activation always takes the lowest live sequence
for that actor. A retryable failure keeps later messages blocked until the
failed message succeeds or reaches its dead letter.

This is stronger than a concurrency limit. Solid Queue's
[`limits_concurrency`](https://github.com/rails/solid_queue#concurrency-controls)
caps simultaneous executions sharing a key, but explicitly does not guarantee
their execution order. Solid Objects turns each actor identity into an ordered
mailbox.

### Fenced activation

A lease expiration by itself cannot stop a paused worker from resuming with
stale state. Solid Objects combines the lease owner with a monotonically
increasing activation generation. Every state commit verifies the current
owner, generation, unexpired database-time lease, and claimed-message
membership.

A stale worker may finish running Ruby code, but it cannot commit stale state,
complete the message, or publish outbox entries.

### Addressable objects with durable state

An actor is addressed by `(actor_type, actor_id)`, not by a process, thread, or
database row ID. Code anywhere in the application can refer to the same logical
cart, room, device, or workflow. Its JSON state survives worker restarts and
idle deactivation.

### Per-object alarms

Cloudflare Durable Objects give each object an alarm. Rails recurring schedules
are normally global task definitions. Solid Objects ports per-object alarms as
durable reminders owned by one logical identity:

```ruby
def schedule_expiration
  schedule(at: 30.minutes.from_now).expire
end
```

When due, a reminder becomes an ordinary mailbox message and follows the same
ordering, retry, lease, and fencing rules as every other turn.

### Durable Objects that render themselves

Cloudflare Durable Objects can coordinate WebSocket clients. Solid Objects adds
a Rails-native extension: an actor observable becomes a live Turbo target with
one helper call. The actor commit and durable broadcast outbox are atomic, so a
rolled-back state change cannot leak into the page.

## Reactive ERB

Define an observable:

```ruby
class ChatRoom < SolidObjects::Actor
  attribute :recent_messages, default: -> { [] }
  attribute :status, default: "open"

  observable :message_count do
    recent_messages.length
  end

  observable :recent_messages
  observable :status
end
```

Scalar observables remain stable `<span>` targets:

```erb
<%= solid_object @room, authorization_context: current_user do |room| %>
  Messages: <%= room.message_count %>
<% end %>
```

Reactive components rerender a host ERB partial when one of their explicit
dependencies changes:

```erb
<%= solid_object @room, authorization_context: current_user do |room| %>
  <%= room.component :messages, observes: :recent_messages %>
  <%= room.component :presence, observes: %i[recent_messages status] %>
<% end %>
```

An observable's value is shared with every authorized subscriber by default
and is stored in `solid_objects_broadcasts`. Use an invalidation-only observable
for component dependencies whose value is private or subscriber-specific:

```ruby
observable :player_one, broadcast: :invalidation do
  player_in_seat(1)
end
```

Its value is still available to the authorized component renderer, but the
durable row and Action Cable frame carry only invalidation metadata. It cannot
be rendered as a scalar `<span>`. Put per-viewer state in `broadcast_payload`,
which computes a fresh projection for each connection.

Component names can repeat when each instance has a stable key. Signed
JSON-compatible locals let one conventional partial render the matching
projection:

```erb
<%= solid_object @room, authorization_context: current_user do |room| %>
  <% @players.each do |player| %>
    <%= room.component :player,
      key: player.id,
      observes: %i[players life_totals],
      locals: { player_id: player.id },
      refresh: :morph %>
  <% end %>
<% end %>
```

The host partial still resolves only to `actors/chat_room/_player`. It receives
`actor`, `authorization_context`, `component_key`, and the declared locals:

```erb
<article id="player_<%= player_id %>">
  Life: <%= actor.life_totals.fetch(player_id.to_s) %>
</article>
```

The default refresh strategy is `:replace`. `refresh: :morph` loads the
authorized component HTML through a gem-owned browser element, rejects stale
responses by actor revision, and applies the result using Turbo's scoped
`replace method="morph"`. Superseded requests for the same keyed target are
aborted. This preserves unchanged DOM nodes where Turbo's morphing rules allow
it, including focus and `data-turbo-permanent` content.

`room.component(:messages)` resolves only
`actors/chat_room/_messages`. Its partial receives `actor` and
`authorization_context` locals, plus a `component_key` of `nil` when the
component is unkeyed:

```erb
<ul>
  <% actor.recent_messages.each do |message| %>
    <li><%= message.fetch("body") %></li>
  <% end %>
</ul>
```

Declared observables are deeply frozen ordinary Ruby values inside a
component. Arrays support loops, hashes support ordinary lookup, conditionals
work normally, and ERB still escapes user strings. A reactive component cannot
read `actor.state`, access an undeclared observable, or choose a dynamic
partial path. A component name and key pair must be unique within its
`solid_object` scope.

Component keys and locals are signed into the refresh token and cannot be
modified without invalidating it, but they are visible to the browser and are
not secrets. Every initial render and refresh passes the signed locals and
`component_key` to `authorize_query` as `arguments`. Authorization must still
bind them to the authenticated request context.

That template provides initial server rendering, stable opaque DOM targets,
and live updates after committed actor turns. One `solid_object` block makes
one Action Cable subscription for all scalar values and components inside it,
and Action Cable multiplexes subscriptions over the browser's WebSocket.

No client-side state store, custom Stimulus controller, channel class, manual
broadcast, or one-WebSocket-per-value setup is required. Signed stream tokens
protect integrity, not access. Initial rendering authorizes with the
`authorization_context` passed to `solid_object`; Cable authorizes with its
connection; every component refresh authorizes again with a request-specific
context:

```ruby
SolidObjects.configure do |configuration|
  configuration.component_authorization_context = ->(controller:) { Current.user }
end
```

The durable outbox stores one row per changed observable, never personalized
HTML. Cable sends invalidation metadata over the shared actor stream, then a
Turbo Frame requests the component with normal cookies. Only scalar targets
that the server rendered into this `solid_object` scope are signed into its
stream token and receive value payloads; component-only dependencies do not
send their values to the browser. The endpoint renders the latest committed
snapshot, returns `private, no-store`, and reauthorizes the component name plus
every declared dependency. Two viewers can therefore receive different HTML
for the same actor without sharing either projection.

Reconnect compares the component's signed initial revision with the latest
actor incarnation and state revision, then refreshes stale components. Cable
coalesces several dependency changes from one actor turn into one component
refresh and ignores older out-of-order invalidations. Replace refreshes detach
an older in-flight frame. Morph refreshes abort the older request and compare
the returned revision with the current target before applying HTML.

Reactive components add no HTML to durable rows, but each affected component
causes an authorized HTTP render. One actor turn still inserts one broadcast
row per changed observable; several dependencies from that turn coalesce at
the subscriber. Keep components bounded, declare only necessary dependencies,
keep signed locals small, and use scalar observables for inexpensive
single-value replacement. Each keyed component counts toward the 50-component
subscription limit and carries its own signed token.

Reactive views require `turbo-rails` and a working Action Cable adapter in the
host application. The Solid Objects engine must be mounted so its signed
component endpoint is reachable. Reactive views are optional; the actor
runtime itself does not depend on Turbo. Morph components automatically include
the engine's `solid_objects/component_refresh` JavaScript module; the host does
not need a Stimulus controller or custom stream action. The default Rails
Propshaft and Sprockets setups discover namespaced engine assets automatically.
An application created with `--skip-asset-pipeline` should use replace refreshes
unless it explicitly serves that module.

```ruby
# config/routes.rb
mount SolidObjects::Engine => "/solid_objects"
```

## Installation

Solid Objects requires Ruby 3.3 or newer and Rails 8.0 or newer.

Add the gem, install its initializer and migration, then migrate:

```bash
bundle add solid_objects
bin/rails generate solid_objects:install
bin/rails db:migrate
bin/rails solid_objects:doctor
```

The doctor validates configuration and required schema shape, reports
authorization posture and live runtime roles, and completes a real synchronous
actor round-trip without a worker. It checks required tables and columns instead
of a copied migration timestamp, which the host application rewrites. It exits
unsuccessfully when configuration, schema, or the round-trip is broken.

The generated initializer is intentionally inert: all five policies deny by
default. Replace them with application-specific authorization before sending
messages, querying state, destroying actors, subscribing to streams, or
mounting administration routes:

```ruby
SolidObjects.configure do |configuration|
  configuration.authorize_message = ->(**) { false }
  configuration.authorize_query = ->(**) { false }
  configuration.authorize_destroy = ->(**) { false }
  configuration.authorize_subscription = ->(**) { false }
  configuration.authorize_administration = ->(**) { false }
end
```

Knowledge of an actor ID or signed stream token is never authorization.
Read the [policy reference and tenant-aware example](docs/authorization.md)
before opening a policy. Unconditionally allowing message and query calls is
reasonable only for a controlled server-side pilot. Keep destroy,
subscription, and administration denied until each has an authenticated
caller.

The engine uses the application's primary Active Record connection by default.
See [Database support](#database-support) for a separate database configuration.

### Host application tooling

Installed engine migrations are copied as
`db/migrate/*_create_solid_objects_tables.solid_objects.rb`. If the host enables
`Rails/CreateTableWithTimestamps`, exclude engine-owned migrations rather than
editing their intentionally specialized hot tables:

```yaml
Rails/CreateTableWithTimestamps:
  Exclude:
    - "db/migrate/*.solid_objects.rb"
```

Solid Objects ships inline RBS signatures, not RBI files. Sorbet applications
can generate the gem RBI with:

```bash
bundle exec tapioca gem solid_objects
```

## Upgrading

Review [CHANGELOG.md](CHANGELOG.md) for compatibility and deployment-order
notes, then update the gem:

```bash
bundle update solid_objects
```

If the `Gemfile` pins an exact version, update that constraint first and run
`bundle install`. Commit both `Gemfile.lock` and the copied Solid Objects
migrations.

Copy only migrations that the newer gem has added, migrate, and verify the
installation:

```bash
bin/rails solid_objects:install:migrations
bin/rails db:migrate
bin/rails solid_objects:doctor
```

The migration task skips engine migrations already present in the application
and gives new migrations host-specific timestamps. Inspect the resulting
`db/migrate/*.solid_objects.rb` files before applying them. Do not rerun
`generate solid_objects:install` during an upgrade because that also attempts
to regenerate the application initializer.

When Solid Objects uses a separate database configuration named `actors`, copy
and run migrations through that database's configured migration path:

```bash
DATABASE=actors bin/rails solid_objects:install:migrations
bin/rails db:migrate:actors
bin/rails solid_objects:doctor
```

For production, back up the actor database and run new migrations before
starting application or Solid Objects worker processes that require the new
schema. Restart the web and Solid Objects worker fleet after the bundle and
schema are current. For releases that change actor state versions, also follow
the [state migration and rolling-deployment guide](docs/state-migrations.md);
Rails schema migrations and actor state migrations are separate concerns.

## Worker requirements

Synchronous actors can be adopted without adding a long-running process. Start
the runtime when the feature introduces asynchronous delivery or outboxes:

| Feature | Runtime roles required |
| --- | --- |
| Direct actor method or explicit `sync` | None; the caller executes it |
| Attribute or declared query read | None; the caller executes it |
| Committed `snapshot` read | None; reads the instance row directly |
| `destroy` | None |
| `async` including delayed delivery | Actor worker |
| One-shot or recurring `schedule` | Reminder scheduler and actor worker |
| `emit` without an actor callback | Effect worker |
| `emit` with success or failure callback | Effect worker and actor worker |
| Actor-to-actor `async` or `send_to` | Effect worker and actor worker |
| Scalar or component Turbo updates | Broadcast worker, Action Cable, and the actor execution path |
| Initial `solid_object` server render | No Solid Objects worker; normal Rails rendering |

One command starts every Solid Objects role:

```bash
bundle exec solid_objects start
```

Deploy and monitor that process before enabling any feature marked as requiring
a runtime role. A missing worker never makes a durable `async` message
disappear, but it leaves the message pending indefinitely.

### Running an extension in the same process

An extension gem can register its own long-running component, and
`solid_objects start` runs it beside the built-in roles. The component joins the
same supervision, the same replacement after a crash, and the same shutdown
timeout, so an operator deploys and monitors one process instead of two:

```ruby
SolidObjects.configure do |configuration|
  configuration.register_component { MyExtension::FlushEngine.new }
end
```

Pass `count:` for more than one instance. The block runs once for each instance,
and again when the supervisor replaces a crashed one, so no two components share
an object.

A registered component answers four methods, the contract the built-in roles
already keep:

| Method | Purpose |
| --- | --- |
| `run` | Runs the loop. The supervisor calls it in its own thread |
| `request_shutdown` | Asks the loop to finish. It must make `run` return |
| `stopped?` | Reports whether the component already finished |
| `stop` | Forces cleanup when the shutdown timeout expires first |

The supervisor checks that contract when it builds the component, and a missing
method raises `ArgumentError` as the supervisor starts, rather than hanging a
shutdown later. Registration itself never calls the block, so a component is
free to need a database connection that the application does not have while it
boots.

## Defining an actor

The Durable Object class becomes an ordinary Ruby class:

```ruby
class ShoppingCart < SolidObjects::Actor
  attribute :items, default: -> { [] }
  attribute :checkout_status, default: "open"

  def add_item(product_id:, quantity: 1)
    item = items.find do |candidate|
      candidate.fetch("product_id") == product_id
    end

    if item
      item["quantity"] += quantity
    else
      items << {
        "product_id" => product_id,
        "quantity" => quantity
      }
    end
  end

  observable :items_count do
    items.sum { |item| item.fetch("quantity") }
  end
end
```

Class-level `attribute` declarations are the per-object durable storage schema
and generate actor instance readers and writers. Public instance methods
declared on the actor are durable message handlers. They can use `items`,
`self.checkout_status = "pending"`, or the lower-level `state` object. Declare
helper methods as private or protected so they are not exposed as messages.

Attributes also become ordered read queries on a reference. Public actor
methods and attribute readers are synchronous caller-assisted invocations:

```ruby
cart = ShoppingCart.ref("alice")
cart.add_item(product_id: "shirt-123", quantity: 2)
items = cart.items
```

Use `cart.async.add_item(product_id: "shirt-123", quantity: 2)` to enqueue
without waiting; that call returns a `SolidObjects::MessageReference`. `items`
is a deeply frozen JSON snapshot, so mutating it cannot bypass the actor
mailbox. State changes must go through public actor methods or explicit
`async`.

State, arguments, results, effects, and reminder arguments accept
JSON-compatible values. Solid Objects never deserializes Ruby `Marshal` data.

Attribute readers are ordered mailbox queries and retain message history. For
a read that does not need mailbox ordering, use an authorized committed
snapshot:

```ruby
snapshot = cart.snapshot
items = snapshot.items
```

Snapshots and synchronous results are deeply frozen. Use
`SolidObjects.mutable_copy(items)` before changing a returned collection.
Snapshot reads can race with an in-flight turn; they return the most recently
committed state and do not create or activate a missing actor.

Lifecycle hooks are also available:

```ruby
class DeviceActor < SolidObjects::Actor
  on_activate do
  end

  on_deactivate do
  end
end
```

Hooks should be deterministic and must not perform slow network I/O. See the
[architecture](docs/architecture.md) for their persistence semantics.

## Actor identity

The durable identity is:

```text
actor_type + actor_id
```

`actor_type` is inferred from the Ruby class name, so the normal API needs no
declaration. The pair plays the role of a Durable Objects namespace and object
name:

```ruby
ShoppingCart.ref("alice")
```

Use an explicit stable type when the persisted name should be independent of a
future Ruby constant rename:

```ruby
class ShoppingCart < SolidObjects::Actor
  actor_type "shopping_cart"
end
```

Actor types resolve only through the explicit registry. Solid Objects never
constantizes a type supplied by a client.

## Invoking an object

As with a Durable Object stub, declared actor operations are available directly
on a reference:

```ruby
class Counter < SolidObjects::Actor
  attribute :value, default: 0

  def increment(amount: 1)
    self.value += amount
  end
end

counter = Counter.ref("global")
value = counter.increment(amount: 5)
value = counter.value
```

Like RPC on a Durable Object stub, a direct call is synchronous from the
caller's perspective. Solid Objects first durably enqueues the invocation, then
executes that actor locally when its fenced activation is available. It returns
the committed, deeply frozen result. Earlier mailbox entries still run first,
and a remote worker may win the activation without changing the result
semantics.

The `message(:name) { ... }` and `query(:name) { ... }` DSLs remain available
for dynamic definitions.

### `async`

Use `async` for durable fire-and-forget work. It returns a
`MessageReference` immediately and leaves execution to the worker fleet:

```ruby
message = order.async(
  idempotency_key: "submit-order-123",
  authorization_context: Current.user
).submit
```

Use `available_at:` to spread bulk work or delay one message:

```ruby
order.async(available_at: 10.minutes.from_now).evaluate
```

### `sync`

Use explicit `sync` when the invocation needs a timeout, idempotency key, or
authorization context different from the defaults:

```ruby
status = order.sync(
  timeout: 5.seconds,
  authorization_context: Current.user
).status
```

Delivery configuration belongs on `async(...)` or `sync(...)` before the
operation. Keywords on the final method call are always actor message
arguments, so `order.sync(timeout: 5.seconds).record(timeout: "payload")`
keeps the invocation timeout separate from the payload value.

Direct calls and `sync` use the same caller-assisted execution path. A healthy
actor normally needs no worker round trip, making this path suitable for HTTP
and MCP request/response boundaries when the handler itself fits the
application's latency budget. If another process owns the activation, the
caller waits for the durable result using wake-up hints with bounded database
polling as the fallback. A timeout never cancels the durable invocation.
`SolidObjects::SyncTimeout` includes actor identity, message ID, sequence,
durable status, mailbox blocker, and activation-owner diagnostics without
including message arguments. The configured timeout also bounds adapter
database lock waits from the enqueue attempt through result observation.
PostgreSQL uses transaction lock and statement timeouts, SQLite retries busy
coordination operations only until the original call deadline, and MySQL uses
its execution timeout plus InnoDB's one-second minimum lock-wait granularity.

The durable call can finish after its original caller gives up. Reauthorize and
recover its eventual result through the durable message identity:

```ruby
begin
  order.sync(timeout: 250.milliseconds).submit
rescue SolidObjects::SyncTimeout => error
  result = error.message_reference.wait(
    timeout: 5.seconds,
    authorization_context: Current.user
  )
end
```

If the enqueue transaction itself cannot finish within the budget, Solid
Objects raises `SyncEnqueueTimeout`; no durable message exists to recover.
Timeouts do not preempt Ruby handler code that has already started.

Do not wrap a synchronous actor call in `ApplicationRecord.transaction`.
Solid Objects raises `SolidObjects::SyncInsideTransaction` before enqueue when
its connection already has an open transaction. Move the actor call before the
transaction, use `async`, or let the actor own the coordinated change through a
commit action.

Actor code cannot use direct calls or `sync` on another actor; synchronous
actor-to-actor waits can deadlock in cycles. Use `async` or `send_to` and a
result message.

```ruby
send_to(
  audit_log,
  available_at: 5.minutes.from_now,
  idempotency_key: event_id
).record(event_id:, event_name: "account_disabled")
```

Actor-to-actor delivery is staged with the current turn, returns `nil`, and is
discarded if that turn does not commit. It accepts messages, not queries.

### Domain rejection

Reject invalid input without retrying or creating a dead letter:

```ruby
def submit(response:)
  reject :validation_failed, "Response is not valid" unless valid?(response)

  self.response = response
end
```

The caller receives `SolidObjects::Rejected` with a stable code, message, and
JSON-compatible details. The rejected message remains durable for audit, actor
state is rolled back, and no later mailbox turn is blocked.

`Rejected#code` is a `String`, even when `reject` receives a symbol. Codes must
match `\A[A-Za-z_][A-Za-z0-9_]*\z`. Invalid codes raise
`SolidObjects::InvalidRejectionCode` and fail the turn without retrying.

### Redelivery

Sequential does not mean once. A handler can run again after a process crash or
lease loss, so guard logical transitions in durable actor state:

```ruby
def launch
  return if status == "launched"

  self.status = "launched"
  emit :launch_vehicle, launch_id: actor_id
end
```

External systems must also deduplicate effects using the stable effect ID.

## Application database writes

Actor handlers execute outside the fenced commit. They may query application
records, but Solid Objects rejects direct Active Record writes from all
user-supplied actor code: handlers, observables, activation/deactivation hooks,
and state migrations. Otherwise an application row could commit before the
actor later raises or loses its activation fence.

For a short database-only change that must commit atomically with actor state,
stage a named action:

```ruby
class Assessment < SolidObjects::Actor
  attribute :status, default: "open"

  def finish(attempt_id:, score:)
    self.status = "complete"
    commit_action :complete_attempt, attempt_id:, score:
  end
end
```

Register its implementation during application boot:

```ruby
SolidObjects.register_commit_action(:complete_attempt) do |arguments, context|
  AssessmentAttempt.find(arguments.fetch("attempt_id")).update!(
    score: arguments.fetch("score"),
    actor_message_id: context.message_id
  )
end
```

The registered block runs inside the short fenced transaction. Its database
writes, actor state, message completion, and outboxes all commit or roll back
together. Commit actions require Solid Objects and `ActiveRecord::Base` to
share one connection pool. They may be invoked again after a database rollback,
so keep them deterministic, bounded, and database-only. Never perform network
I/O, wait for another actor, or enqueue nontransactional work from a commit
action.

When Solid Objects uses a separate actor database, use `emit` and an idempotent
effect consumer instead; the two databases cannot share one transaction.

## Effects

Cloudflare Durable Objects can call external services directly. Solid Objects
does not hold a Rails database transaction across slow external I/O. `emit`
creates a transactional outbox entry alongside state and message completion:

```ruby
def checkout(payment_id:, amount_cents:)
  return unless checkout_status == "open"

  self.checkout_status = "pending"
  emit(
    :charge_payment,
    payment_id:,
    amount_cents:,
    on_success: :payment_succeeded,
    on_failure: :payment_failed
  )
end

def payment_succeeded(effect_id:, arguments:, result:)
  self.checkout_status = "paid"
end

def payment_failed(effect_id:, arguments:, error:)
  self.checkout_status = "failed"
end
```

Register an effect handler during application boot:

```ruby
SolidObjects.register_effect(:charge_payment) do |arguments, context|
  Payments.charge(
    idempotency_key: context.id,
    payment_id: arguments.fetch("payment_id"),
    amount_cents: arguments.fetch("amount_cents")
  )
end
```

The provider call can repeat if a process dies after external success but
before recording completion. The stable effect ID is the idempotency key.
Success callbacks receive `effect_id:`, the originally staged `arguments:`,
and `result:`. Failure callbacks receive `effect_id:`, `arguments:`, and
`error:`, so an actor can correlate concurrent effects without storing a
separate callback ledger.

## Reminders

Reminders are Solid Objects' durable equivalent of the Durable Objects Alarms
API. One-shot and recurring alarms are actor-owned database records:

```ruby
def schedule_evaluation
  schedule(
    at: 1.hour.from_now,
    every: 1.hour,
    missed: :latest
  ).evaluate(account_id:)
end
```

Use `missed: :latest` to coalesce missed occurrences or `missed: :all` to
enqueue each one.

### A reminder is one named alarm per actor

The uniqueness key is `(actor, reminder name)`. Scheduling a name that is
already armed **moves the existing alarm** rather than adding a second one. The
database enforces this with a unique index on `(instance_id, name)`.

This is the same model as Orleans reminders and Durable Objects alarms, and it
is what makes a reminder safe to re-arm from a handler that may run more than
once. It also means this is a data-loss bug:

```ruby
# Wrong. Every entry overwrites the previous entry's alarm.
def add(entry:)
  self.entries = entries + [ entry ]
  schedule(at: entry.fetch("wait_until")).deliver
end
```

Two entries leave one reminder. The earlier wake-up never happens, nothing
raises, and nothing is logged except a `solid_objects.reminder.replaced` event.

Arm one alarm for the earliest item instead, and let the handler drain
everything now due before arming the next:

```ruby
def add(entry:)
  self.entries = (entries + [ entry ]).sort_by { |item| item.fetch("wait_until") }
  arm_next
end

def deliver
  now = Time.current.to_i
  due, pending = entries.partition { |item| item.fetch("wait_until") <= now }
  due.each { |item| emit :send_push, **item.symbolize_keys }
  self.entries = pending
  arm_next
end

private

def arm_next
  earliest = entries.first
  return unless earliest

  schedule(at: Time.at(earliest.fetch("wait_until"))).deliver
end
```

`deliver` drains every due item rather than one, so a single alarm serves a
whole queue and a missed or coalesced occurrence cannot strand an entry. Use a
distinct reminder name only when you genuinely need two independent alarms on
one actor, such as `:deliver` and `:sweep`.

Solid Objects has no `unschedule`. A reminder stops when its handler does not
re-arm it, and destroying an actor removes its reminders.

Self-scheduling actors should also have a low-frequency application reconciler.
It may read `SolidObjects::Instance.states_for`, `.without_pending_work`, and
`.orphaned`, but every repair must go through `async`. Never bulk-update actor
state around the lease and fencing checks.

Suspended actors should be reported rather than silently resumed. Spread large
repair batches with `available_at:` so reconciliation cannot stampede one
mailbox or the worker fleet.

## Destroying an object

Destroy an actor incarnation through its reference:

```ruby
Counter.ref("global").destroy
```

`destroy` is synchronous and idempotent. It returns `true` when it deletes an
existing incarnation and `false` when none exists. In one transaction it locks
and deletes the actor instance; cascading foreign keys remove state, message
history, ready and claimed mailbox rows, dead letters, reminders, effects, and
broadcasts.

Destruction has its own deny-by-default `authorize_destroy` policy and cannot be
called synchronously from actor code. It does not run `on_deactivate`. A stale
activation cannot commit after deletion because its fenced write targets the
deleted instance primary key. Addressing the same type and ID later creates a
fresh incarnation with default state and message sequence 1.

Pending outboxes are deleted. An external effect, actor-to-actor delivery, or
broadcast that already started cannot be recalled, but its stale completion
cannot enqueue a callback or recreate the source actor. See
[destruction semantics](docs/correctness.md#destruction) before using deletion
as application workflow.

## State migrations

Actor state has an independent schema version:

```ruby
class ShoppingCart < SolidObjects::Actor
  state_version 2

  migrate_state from: 1, to: 2 do |state|
    state["currency"] ||= "USD"
    state
  end
end
```

An actor refuses activation when stored state is newer than the running code.
Published migration blocks cannot be squashed because a long-idle actor may
still hold an old representation. Destructive changes need an expand/contract
rolling deployment. Read the [state migration guide](docs/state-migrations.md)
before changing persisted state.

## Configuration

Configure Solid Objects in `config/initializers/solid_objects.rb`:

```ruby
SolidObjects.configure do |configuration|
  configuration.worker_count = 4
  configuration.lease_duration = 30.seconds
  configuration.lease_renewal_interval = 10.seconds
  configuration.max_messages_per_activation_pass = 50
  configuration.max_activation_duration = 5.seconds
end
```

Important defaults:

| Setting | Default |
| --- | ---: |
| `polling_interval` | 0.1 seconds |
| `sync_polling_interval` | 0.05 seconds |
| `lease_duration` | 30 seconds |
| `lease_renewal_interval` | 10 seconds |
| `idle_deactivation_timeout` | 30 seconds |
| `max_messages_per_activation_pass` | 50 |
| `max_activation_duration` | 5 seconds |
| `max_mailbox_length` | 10,000 |
| `max_attempts` | 5 |
| `process_heartbeat_interval` | 15 seconds |
| `process_alive_threshold` | 60 seconds |
| `message_retention` | 30 days |
| `message_retention_by_actor_type` | `{}` |
| `instance_retention_by_actor_type` | `{}`; instances never expire unless listed |
| `process_retention` | 7 days |
| `prune_batch_size` | 1,000 |
| `worker_count` | 1 |
| `effect_worker_count` | 1 |
| `broadcast_worker_count` | 1 |
| `reminder_scheduler_count` | 1 |

Payload, state, and result limits; retry delay; table prefix; logging; wake-up;
broadcast; database; and authorization adapters are also configurable. Invalid
lease intervals, component counts, and size limits fail fast at boot.

## Workers and operations

`solid_objects start` runs actor, effect, reminder, and broadcast roles under
one supervisor:

```bash
bundle exec solid_objects start
```

Worker and outbox counts can be overridden:

```bash
bundle exec solid_objects start \
  --workers 4 \
  --effect-workers 2 \
  --broadcast-workers 2 \
  --reminder-schedulers 1
```

Administration commands require the administration policy:

```bash
bundle exec solid_objects status
bundle exec solid_objects cleanup
bundle exec solid_objects prune_messages
bundle exec solid_objects prune_instances
bundle exec solid_objects prune_processes
bundle exec solid_objects dead_letters
bundle exec solid_objects retry_dead_letter 123
```

The prune commands preview counts by default. Add `--execute` only after
reviewing the configured retention policy.

The supervisor stops new claims, drains active loops, releases cached leases,
and marks process rows stopped on graceful shutdown. A hard-killed worker's
claimed turn is recovered after its process heartbeat or activation lease
becomes stale.

Before any role starts, the CLI loads actors from the host application's
`app/actors` directories through Rails' main autoloader. This works when
development eager loading is disabled and does not require actor references in
an initializer.

See the [operations guide](docs/operations.md) for monitoring, reconciliation,
shutdown, retention, and backup guidance.

## Database support

Solid Objects supports:

- PostgreSQL 14 or newer
- MySQL 8.0 or newer using InnoDB, through either the `mysql2` or `trilogy`
  client
- SQLite 3.35 or newer

PostgreSQL and MySQL use `FOR UPDATE SKIP LOCKED` when claiming hot-table rows.
SQLite uses its serialized writer behavior. All three adapters run the same
locking, fencing, mailbox, outbox, and engine integration test suite.

No Redis or Kafka service is required.

By default, actor tables use the application's Active Record connection. A
separate database role is optional:

```ruby
SolidObjects.configure do |configuration|
  configuration.connects_to = {
    database: {
      writing: :actors,
      reading: :actors
    }
  }
end
```

Every table participating in an actor commit must share one database.

Completed message history lives in `solid_objects_messages`, while ready and
claimed work lives in small membership tables. Polling indexes stay
proportional to live work, and no partial indexes are required.

## Guarantees

For one actor identity, messages are:

- durably enqueued with explicit sequence numbers;
- processed sequentially in sequence order;
- delivered at least once; and
- committed by at most one valid activation owner and fencing generation.

Different actor identities may execute concurrently.

Actor destruction is authorized, synchronous, and linearized by the instance
row lock. It removes the current incarnation and all actor-owned durable rows.
A later message may create a fresh incarnation of the same logical identity.

The following writes are atomic for one successful turn:

- actor state and state version;
- message result and completion;
- effect outbox entries;
- reminder changes;
- actor-to-actor messages; and
- observable broadcast entries.

Solid Objects does not promise:

- exactly-once handler or effect execution;
- global order across actors;
- distributed transactions;
- bounded end-to-end latency;
- cancellation when a synchronous caller times out; or
- that a lease prevents stale Ruby code from continuing to run.

The fencing generation prevents stale code from committing.

Read [Correctness and delivery semantics](docs/correctness.md) for the full
contract and crash matrix.

## When to use it

Solid Objects fits the same coordination-heavy domains that lead developers to
Cloudflare Durable Objects, when the application belongs in Rails and its
existing database:

- shopping carts;
- chat rooms and presence;
- device twins;
- user-specific schedules;
- long-lived workflows;
- collaborative sessions; and
- game rooms.

Do not use it for stateless work, bulk pipelines, CPU-heavy computation,
cross-actor transactions, slow network calls inside handlers, or domains that
are clearer as normalized Active Record models and direct service objects.

High-QPS request reads, rate-limit counters, impression pipelines, large JSON
documents, and latency budgets that cannot tolerate several coordination
transactions are explicit anti-patterns. Read the full
[fit and anti-pattern guide](docs/fit.md) before migrating an existing
surface, and use the [legacy-state migration cookbook](docs/migrating-existing-state.md)
for staged cutovers.

## Comparisons

| Tool | What Solid Objects adds or changes |
| --- | --- |
| Cloudflare Durable Objects | Solid Objects ports the named, stateful, serialized-object model to Ruby and Rails. It uses your SQL database and Rails workers rather than Cloudflare's globally distributed serverless runtime, placement, and storage APIs. |
| Active Job | Jobs are independent work units. Solid Objects adds addressable identity, durable state, explicit per-identity order, activation leases, and fencing. |
| Solid Queue | Solid Queue is an excellent database backend for Active Job. Its concurrency controls cap overlap but do not guarantee order. Solid Objects provides actor mailboxes, state, fencing, per-identity reminders, and state-driven views. |
| Action Cable | Cable transports transient realtime messages. Solid Objects owns durable state and work; Cable is an optional delivery path for committed observable projections. |
| Orleans | Orleans provides the virtual-actor lineage behind the model, with grains, reminders, and activation lifecycle. Solid Objects is a smaller Rails-native runtime and does not match Orleans clustering or placement breadth. |
| Active Record service object | A service object runs directly against records. Solid Objects adds durable asynchronous ordering, retries, activation fencing, reminders, and outboxes at greater operational cost. |

## Development

Solid Objects uses Minitest and follows Solid Queue's test organization and
RuboCop policy. Ruby source carries inline RBS annotations.

Run the full SQLite suite and static checks:

```bash
bundle install
bundle exec rake
```

Run the database integration suite against PostgreSQL or MySQL:

```bash
SOLID_OBJECTS_DATABASE_URL=postgresql://localhost/solid_objects_test \
  bundle exec rake test

SOLID_OBJECTS_DATABASE_URL=mysql2://localhost/solid_objects_test \
  bundle exec rake test
```

Concurrency tests use real database locks and deterministic synchronization,
not mocked locking behavior.

See the [development guide](docs/development.md) and
[local benchmarks](docs/benchmarks.md).

## Status

Implemented and tested in 0.4:

- Rails engine, install generator, migrations, and `solid_objects` executable;
- actor registry, references, JSON state, and state migrations;
- direct synchronous actor RPC, explicit `sync`, and durable `async`;
- guarded transaction boundaries, same-database commit actions, adapter lock
  deadlines, structured synchronous timeout diagnostics, and result recovery;
- durable message history plus ready and claimed membership tables;
- concurrent sequence allocation and actor creation;
- activation leases, per-activation tokens, fencing generations, and
  stale-write rejection;
- bounded activation passes, idle activation cache, and hot-actor fairness;
- retries, terminal domain rejection, strict poison ordering, dead letters,
  and retry tooling;
- transactional effects and asynchronous actor-to-actor messages;
- one-shot and recurring per-actor reminders;
- authorized actor destruction with fenced stale-write rejection and cascading
  durable-work cleanup;
- durable observable invalidations, scalar Turbo replacement, and authorized
  request-time ERB component refresh;
- process registration, heartbeats, caller shutdown, cleanup, and bounded
  message/process retention plus opt-in actor-instance expiration;
- an opt-in Minitest helper for actor-state isolation and deterministic async
  actor/reminder/effect/broadcast draining;
- authorized mailbox-free state snapshots and mutable JSON copies; and
- SQLite, PostgreSQL, and MySQL integration tests.

Partially implemented:

- the supervisor starts and drains roles but does not replace a crashed role or
  run periodic maintenance automatically;
- cross-process wake-up uses polling; PostgreSQL notifications and optional
  Redis acceleration are not implemented;
- live observable and component replacement work, while Turbo append actions
  remain future work;
- local admission limits exist, but distributed rate limits and global
  admission control do not; and
- administration views and pruning commands exist, but scheduled maintenance
  and richer audit tools do not.

Production readiness requires hardening and operational soak evidence. The
[roadmap](docs/roadmap.md) tracks that work.

## License

Solid Objects is MIT Licensed by Lucas Carlson. See
[MIT-LICENSE](MIT-LICENSE).

Solid Objects is an independent open-source project. It is not affiliated with,
sponsored by, or endorsed by Cloudflare, Inc. “Cloudflare” and “Durable
Objects” are trademarks of Cloudflare, Inc. and are used here to identify the
programming model this gem ports to Rails.
