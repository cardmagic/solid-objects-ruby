# Solid Objects

[![CI](https://github.com/cardmagic/solid-objects-ruby/actions/workflows/ci.yml/badge.svg)](https://github.com/cardmagic/solid-objects-ruby/actions/workflows/ci.yml)

**Self-hosted, distributed Durable Objects in Rails without a daemon using your existing SQL database.**

Solid Objects ports the Durable Objects programming model to ordinary Rails
applications: addressable objects, durable state, serialized turns, alarms,
and live clients. It runs on the MySQL, PostgreSQL, or SQLite database that
the application already has, in the database-backed operating model of the
Solid family. No Redis, Cloudflare account, or separate actor service is
required.

> **Not a replacement for SQL transactions:** when one row update inside one
> transaction answers the question, use that and install nothing. Solid Objects
> earns its cost when the critical section outlives the transaction: a hold that
> expires in ten minutes, work that must survive a restart, or a fan-in that
> spans many jobs. See [Why not just use `with_lock`?](#why-not-just-use-with_lock).

A ticket sale for one event, with 100 seats and a hold that expires:

```ruby
class TicketSale < SolidObjects::Actor
  attribute :remaining, default: 100
  attribute :holds, default: -> { {} }
  observable :remaining

  def reserve(buyer:)
    return false if remaining.zero? || holds.key?(buyer)

    self.remaining -= 1
    self.holds = holds.merge(buyer => Time.now.utc.to_i)
    schedule(at: 10.minutes.from_now, key: buyer).expire(buyer:)
    true
  end

  def expire(buyer:)
    return unless holds.key?(buyer)

    self.holds = holds.except(buyer)
    self.remaining += 1
  end
end

# Synchronous caller-assisted RPC. No worker fleet is required.
sale = TicketSale.ref("event-42")
sale.reserve(buyer: current_user.id)
```

That example wants three things from the same number. It must never go below
zero. It must give the seat back if the buyer does not pay within ten minutes.
It must show the current count to everyone watching the page.

The first is one line of SQL. The second is an `expires_at` column plus a cron
job that sweeps it. The third is a broadcast on every code path that changes
the number. The combination is what costs, not any one of them. Here the guard,
the ten-minute alarm, and the live count are one class, and they commit
together.

`TicketSale / event-42` is a logical identity. Like a Durable Object named with
`idFromName`, it can be addressed from anywhere without first creating or
locating a Ruby object. Solid Objects activates it when work arrives, commits
its ordered turns one at a time, persists its state, and deactivates it when
idle. Different identities can run concurrently, so two events never wait on
each other.

The invocation model is the first adoption decision:

| Call | Returns | Worker fleet required? |
| --- | --- | --- |
| `sale.reserve(buyer: id)` | Committed handler result | No |
| `sale.sync(timeout: 5.seconds).reserve(buyer: id)` | Committed handler result | No |
| `sale.remaining` | Ordered, committed query result | No |
| `sale.snapshot.remaining` | Current committed state without a mailbox message | No |
| `sale.async.reserve(buyer: id)` | `MessageReference` immediately | Yes |

Direct methods and `sync` durably enqueue the call, then the Rails caller helps
execute the actor through the same mailbox, lease, and fencing path as a
worker. `async` only enqueues; a runtime process handles it later.

Synchronous calls fail before enqueue when the Solid Objects database
connection is already inside a transaction. Actor handlers may read application
records, but direct Active Record writes are rejected so they cannot escape a
later actor failure. Use a same-database
[`commit_action`](#application-database-writes) for atomic database changes and
[`emit`](#effects) for external I/O.

## Why not just use `with_lock`?

Often you should. If the whole job is read a row, decide, write it back, and
answer the user, then `with_lock` does that and you need nothing else
installed. Reach for it first.

The argument for an actor is scope, not discipline. A lock is scoped to one
transaction, on one connection, in one process. The ticket sale above leaves
that scope on one line: the hold expires in ten minutes, and no transaction
stays open for ten minutes.

Any column named `expires_at`, `scheduled_at`, or `next_run_at` is evidence
that the critical section already outlived the lock that was supposed to cover
it. What follows such a column is a sweeper that looks for due rows, and then a
race between that sweeper and the next writer of the same row. The column, the
sweeper, and the race are what an actor replaces.

Three cases a lock cannot reach:

- work that fires at a future moment, when no transaction of yours is open;
- work that must survive a process restart, which rules out an in-process
  timer; and
- a fan-in whose critical section spans many jobs over minutes, such as an
  import that counts its own chunks as each one finishes.

If it all happens inside one request, use a lock. If something has to happen
later, or has to survive a restart, that is when this is worth installing.

## Is it worth installing here?

Worth it when several requests, jobs, or processes act on the same cart, chat
room, device twin, game room, collaborative session, or long-lived workflow,
and each next action needs the last committed state. Worth it when that same
thing also owns work that fires later, or a number a live page must show.

Not worth it for a plain counter, a single-row update inside one transaction, a
stateless job, bulk ingestion or a data-parallel pipeline, CPU-heavy work, a
large JSON document that belongs in normalized rows, high-QPS request reads, or
a global rate-limit counter that every request touches. One hot identity is
serialized on purpose, so making everything one identity makes a queue.

Before moving an existing surface, read the
[fit and anti-pattern guide](docs/fit.md), the
[measured performance and row-growth costs](docs/benchmarks.md), and the
[legacy-state migration cookbook](docs/migrating-existing-state.md).

This is a port of the programming model, not Cloudflare's edge runtime or
platform. The exact Rails guarantees are in
[Correctness and delivery semantics](docs/correctness.md). This is an early
release with no production-readiness claim; see [Status](#status).

## Table of contents

- [Why not just use `with_lock`?](#why-not-just-use-with_lock)
- [Is it worth installing here?](#is-it-worth-installing-here)
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
- [Dashboard](#dashboard)
- [Database support](#database-support)
- [Guarantees](#guarantees)
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

Rails already has tools for jobs, records, and realtime transport. None of
those primitives alone provides this complete stateful-object shape. Solid
Objects adds five capabilities:

**Ordered delivery per identity.** Every enqueue locks the actor instance and
allocates a monotonically increasing sequence number, and an activation always
takes the lowest live sequence. This is stronger than a concurrency limit:
Solid Queue's
[`limits_concurrency`](https://github.com/rails/solid_queue#concurrency-controls)
caps simultaneous executions sharing a key, but explicitly does not guarantee
their order.

**Fenced activation.** A lease expiration alone cannot stop a paused worker
from resuming with stale state, so every commit also verifies an activation
generation, the lease owner, an unexpired database-time lease, and
claimed-message membership. A stale worker can finish running Ruby, but it
cannot commit.

**Addressable objects with durable state.** An actor is addressed by
`(actor_type, actor_id)`, not by a process, thread, or row ID. Its JSON state
survives restarts and idle deactivation.

**Per-object alarms.** Rails recurring schedules are global task definitions.
A reminder is owned by one identity, and when due it becomes an ordinary
mailbox message under the same ordering, retry, and fencing rules.

**Objects that render themselves.** An observable becomes a live Turbo target
with one helper call, and the broadcast row commits with the state change, so
a rolled-back turn cannot leak into the page.

## Reactive ERB

For a comment count or a dashboard number, lock the row, update it, and call
`broadcast_replace_to`. That is less code than this gem and it works.

It gets harder when several people write to the same record at once. Each
request renders the fragment in its own process and pushes it. The lock decided
who wrote first, but it has no say over which of the two pushes arrives last,
so a viewer can be left looking at the older number. The second gap is that the
push is not part of the save: if the process dies after the database commits
and before the push goes out, the browser keeps a wrong number and nothing
corrects it.

An observable is the alternative. The state change and the broadcast row commit
together, so no crash can leave one without the other. A worker delivers that
row afterwards and retries until it succeeds, and Cable ignores an older
`(instance_id, state_revision)` pair after a newer one, so a late arrival
cannot overwrite a newer number. Delivery is still at least once, so the
guarantee is that a viewer cannot end up on an older number, not that a
fragment is pushed exactly once.

Define an observable, then render it. A committed turn that changes
`message_count` replaces that span, and a turn that changes `recent_messages`
re-renders the component:

```ruby
class ChatRoom < SolidObjects::Actor
  attribute :recent_messages, default: -> { [] }
  attribute :status, default: "open"

  observable :message_count, broadcast: :value do
    recent_messages.length
  end

  observable :recent_messages
  observable :status
end
```

```erb
<%= solid_object @room, authorization_context: current_user do |room| %>
  Messages: <%= room.message_count %>
  <%= room.component :messages, observes: :recent_messages %>
<% end %>
```

The partial resolves only to `actors/chat_room/_messages` and receives `actor`
and `authorization_context`. Observables are invalidation-only by default:
durable rows and Cable frames carry change metadata, and only a
`broadcast: :value` observable sends its value to every authorized subscriber.
Per-viewer state belongs in `broadcast_payload`, which computes a projection
per connection.

One `solid_object` block makes one Cable subscription for everything inside it.
No client-side store, Stimulus controller, channel class, or manual broadcast
is required. Signed tokens protect integrity, not access: initial rendering
authorizes with the context passed to `solid_object`, Cable authorizes with its
connection, and every refresh authorizes again.

Reactive views require `turbo-rails`, a working Action Cable adapter, and the
mounted engine. They are optional; the actor runtime itself does not depend on
Turbo.

```ruby
# config/routes.rb
mount SolidObjects::Engine => "/solid_objects"
```

The [realtime guide](docs/realtime.md) covers keyed components and signed
locals, `refresh: :morph`, reconnect fencing, subscription and payload limits,
and the per-refresh cost model. [Authorization](docs/authorization.md) covers
the three authorization points.

## Installation

Solid Objects requires Ruby 3.3 or newer and Rails 7.1 or newer. CI runs the
suite against Rails 7.1, 7.2, 8.0, and 8.1.

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
    item = items.find { |candidate| candidate.fetch("product_id") == product_id }
    return item["quantity"] += quantity if item

    items << { "product_id" => product_id, "quantity" => quantity }
  end

  observable :items_count, broadcast: :value do
    items.sum { |item| item.fetch("quantity") }
  end
end
```

Class-level `attribute` declarations are the per-object durable storage schema
and generate readers and writers. Public instance methods are durable message
handlers; declare helpers private or protected so they are not exposed as
messages. Attributes also become ordered read queries on a reference:

```ruby
cart = ShoppingCart.ref("alice")
cart.add_item(product_id: "shirt-123", quantity: 2)
items = cart.items
```

`cart.async.add_item(...)` enqueues without waiting and returns a
`SolidObjects::MessageReference`. State, arguments, results, effects, and
reminder arguments accept JSON-compatible values only, and Solid Objects never
deserializes Ruby `Marshal` data. Returned values are deeply frozen, so
mutating one cannot bypass the mailbox; use `SolidObjects.mutable_copy(items)`
to change a copy.

Attribute readers are ordered mailbox queries, so they retain message history.
For a read that does not need mailbox ordering, take an authorized committed
snapshot instead. It returns the most recently committed state, races with an
in-flight turn, and does not create or activate a missing actor:

```ruby
items = cart.snapshot.items
```

Lifecycle hooks `on_activate` and `on_deactivate` are available. They should be
deterministic and must not perform slow network I/O. See the
[architecture guide](docs/architecture.md) for their persistence semantics.

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

As with a Durable Object stub, declared operations are available directly on a
reference:

```ruby
sale = TicketSale.ref("event-42")
sale.reserve(buyer: current_user.id)
sale.remaining
```

A direct call is synchronous from the caller's perspective. Solid Objects
durably enqueues the invocation, then executes that actor locally when its
fenced activation is available, and returns the committed, deeply frozen
result. Earlier mailbox entries still run first, and a remote worker may win
the activation without changing the result. The `message(:name) { ... }` and
`query(:name) { ... }` DSLs remain available for dynamic definitions.

### `async`

Use `async` for durable fire-and-forget work. It returns a `MessageReference`
immediately and leaves execution to the worker fleet:

```ruby
message = order.async(
  idempotency_key: "submit-order-123",
  authorization_context: Current.user
).submit

order.async(available_at: 10.minutes.from_now).evaluate
```

`async` needs a running actor worker. Installing the engine and migrating the
schema starts no role, so a process that only serves web requests leaves the
message ready. Nothing is lost. The message waits until
`bundle exec solid_objects start` runs the roles. See
[Worker requirements](#worker-requirements) for the feature-by-role table.

### `sync`

Use explicit `sync` when the invocation needs a timeout, idempotency key, or
authorization context different from the defaults:

```ruby
status = order.sync(timeout: 5.seconds, authorization_context: Current.user).status
```

Delivery configuration belongs on `async(...)` or `sync(...)` before the
operation. Keywords on the final method call are always actor message
arguments, so `order.sync(timeout: 5.seconds).record(timeout: "payload")`
keeps the invocation timeout separate from the payload value.

Direct calls and `sync` share the caller-assisted path, which suits HTTP and
MCP request boundaries when the handler fits the latency budget. A timeout
never cancels the durable invocation, so the call can finish after its caller
gives up. Reauthorize and recover the result through the durable message:

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

If the enqueue itself cannot finish in the budget, `SyncEnqueueTimeout` is
raised and no durable message exists to recover. Do not wrap a synchronous
call in `ApplicationRecord.transaction`: Solid Objects raises
`SolidObjects::SyncInsideTransaction` before enqueue. Move the call outside the
transaction, use `async`, or let the actor own the change through a commit
action. [Correctness and delivery semantics](docs/correctness.md) documents the
per-adapter lock and statement deadlines.

Actor code cannot use direct calls or `sync` on another actor, because
synchronous actor-to-actor waits can deadlock in cycles. Use `async` or
`send_to` and a result message:

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
JSON-compatible details. The rejected message stays durable for audit, actor
state is rolled back, and no later turn is blocked. `Rejected#code` is a
`String` even when `reject` receives a symbol, and must match
`\A[A-Za-z_][A-Za-z0-9_]*\z`; an invalid code raises
`SolidObjects::InvalidRejectionCode` and fails the turn without retrying.

### Redelivery

Sequential does not mean once. A handler can run again after a crash or lease
loss, so guard logical transitions in durable actor state:

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
once. Without a key the name is the operation, so this is a data-loss bug:

```ruby
# Wrong. Every entry overwrites the previous entry's alarm.
def add(entry:)
  self.entries = entries + [ entry ]
  schedule(at: entry.fetch("wait_until")).deliver
end
```

Two entries leave one reminder. The earlier wake-up never happens, nothing
raises, and nothing is logged except a `solid_objects.reminder.replaced` event.

### An alarm per item, with `key:`

Pass `key:` when an actor is waiting on several things at once. The key is your
own identifier for the item, and it names that item's alarm, so each item gets
one:

```ruby
def add(entry:)
  self.entries = entries + [ entry ]
  schedule(at: entry.fetch("wait_until"), key: entry.fetch("id")).deliver
end
```

Two entries now leave two reminders. Scheduling the same key again moves that
item's alarm and leaves the others alone, which is what makes a keyed reminder
as safe to re-arm as an unkeyed one. The operation still decides which handler
runs; the key only decides which alarm is which.

A key must be non-empty, and the name it becomes must fit the 191-character
column, which is checked on the composed name rather than the key alone so a
long operation and a short key are caught too.

The key is separated from the operation by a colon, so an operation may not hold
one. Otherwise an unkeyed `deliver:item` and a `deliver` keyed `item` would be
one name, and the second would silently take the first one's alarm. A key may
hold colons of its own, because the operation before the first one cannot.

### One alarm for a whole queue

A key per item is not always what you want. An actor that only ever needs to
know "what is next" can keep one alarm and let the handler drain everything now
due before arming the next:

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

That costs one reminder row instead of one per item, and a coalesced occurrence
cannot strand an entry because the handler drains by time rather than by alarm.
Prefer it when the queue is large and the items are interchangeable; prefer
`key:` when an item needs its own alarm that can be moved on its own.

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
| `idle_polling_interval` | 1 second |
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

`polling_interval` is the fast interval after work or a wake-up. Consecutive
empty passes double it up to `idle_polling_interval`. Actor workers never wait
longer than `lease_renewal_interval`. Set the fast and idle values equal for a
fixed cadence. The default wake-up reaches only the current Ruby process;
configure PostgreSQL notifications or optional Redis Pub/Sub when separate
processes need low-latency delivery. The runtime warns once when it sees that
topology without an adapter.

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

The engine loads actors from the host application's `app/actors` directories
through Rails' main autoloader, in every process that boots the application.
This works when eager loading is disabled and does not require actor
references in an initializer. A web process therefore resolves an actor by
name for a Cable subscription or a component render without having loaded that
class through an earlier request.

See the [operations guide](docs/operations.md) for monitoring, reconciliation,
shutdown, retention, and backup guidance.

## Dashboard

`SolidObjects::Web` is a Rack application that shows instances and their state,
the mailbox, reminders, effects, broadcasts, dead letters, and the registered
processes. Mount it inside the application routes, so the Rails session
middleware runs first:

```ruby
# config/routes.rb
require "solid_objects/web"

Rails.application.routes.draw do
  mount SolidObjects::Web => "/solid_objects/dashboard"
end
```

It is not loaded by `require "solid_objects"`: a worker process must not carry
a web stack. Every page asks `authorize_administration` first, and that policy
denies by default, so a mount alone exposes nothing.

The [dashboard guide](docs/dashboard.md) covers the policy table, the two
mutating actions, charts without a CDN, extension registration, and query cost.

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

## Comparisons

| Tool | What Solid Objects adds or changes |
| --- | --- |
| `with_lock` or `SELECT ... FOR UPDATE` | A lock serializes writers for the length of one transaction, on one connection, in one process, and it needs nothing installed. Solid Objects covers the part that outlives the transaction: an alarm that fires later, work that survives a restart, and a broadcast that commits with the state change. Prefer the lock when the whole job fits inside one request. |
| Cloudflare Durable Objects | Solid Objects ports the named, stateful, serialized-object model to Ruby and Rails. It uses your SQL database and Rails workers rather than Cloudflare's globally distributed serverless runtime, placement, and storage APIs. |
| Active Job | Jobs are independent work units. Solid Objects adds addressable identity, durable state, explicit per-identity order, activation leases, and fencing. |
| Solid Queue | Solid Queue is a database backend for Active Job. Its concurrency controls cap overlap but do not guarantee order. Solid Objects provides actor mailboxes, state, fencing, per-identity reminders, and state-driven views. |
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

The correctness core is implemented and tested against SQLite, PostgreSQL, and
MySQL: ordered mailboxes, fenced activation, retries and dead letters,
reminders, effects, commit actions, destruction, and reactive views.

Still open: Turbo append actions, distributed rate limits and global admission
control, and scheduled maintenance beyond the pruning commands.

There is no production-ready claim. That needs hardening and operational soak
evidence. The [roadmap](docs/roadmap.md) tracks what is done, what is partial,
and what is measured rather than assumed.

## License

Solid Objects is MIT Licensed by Lucas Carlson. See
[MIT-LICENSE](MIT-LICENSE).

Solid Objects is an independent open-source project. It is not affiliated with,
sponsored by, or endorsed by Cloudflare, Inc. “Cloudflare” and “Durable
Objects” are trademarks of Cloudflare, Inc. and are used here to identify the
programming model this gem ports to Rails.
