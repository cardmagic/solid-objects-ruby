# Solid Objects

[![CI](https://github.com/cardmagic/solid-objects-ruby/actions/workflows/ci.yml/badge.svg)](https://github.com/cardmagic/solid-objects-ruby/actions/workflows/ci.yml)

**Self-hosted, distributed Durable Objects in Rails without a daemon using your existing SQL database.**

Solid Objects ports the Durable Objects programming model to ordinary Rails
applications: addressable objects, durable state, serialized turns, alarms, and
live clients. It runs on the MySQL, PostgreSQL, or SQLite database the
application already has. No Redis, Cloudflare account, or separate actor
service is required.

> **Not a replacement for SQL transactions:** when one row update inside one
> transaction answers the question, use that and install nothing. Solid Objects
> earns its cost when the critical section outlives the transaction: a hold that
> expires in ten minutes, work that must survive a restart, or a fan-in that
> spans many jobs. See [Why not just use transactions?](#why-not-just-use-transactions).

A ticket sale for one event, with 100 seats and a hold that expires:

```ruby
class TicketSale < SolidObjects::Actor
  attribute :remaining, default: 100
  attribute :holds, default: -> { {} }
  observable :remaining, broadcast: :value
  observable :holds

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
idle. Different identities run concurrently, so two events never wait on each
other.

The invocation model is the first adoption decision. A direct call or `sync`
needs no worker fleet, because the Rails caller helps execute the actor through
the same mailbox, lease, and fencing path a worker would use. `async` only
enqueues and returns a `MessageReference`, so a runtime process handles it
later.

| Call | Returns | Worker fleet required? |
| --- | --- | --- |
| `sale.reserve(buyer: id)` | Committed handler result | No |
| `sale.remaining` | Ordered, committed query result | No |
| `sale.snapshot.remaining` | Committed state without a mailbox message | No |
| `sale.async.reserve(buyer: id)` | `MessageReference` immediately | Yes |

Actor handlers may read application records, but direct Active Record writes
are rejected so they cannot escape a later actor failure. Use a same-database
[`commit_action`](#application-database-writes) for atomic database changes and
[`emit`](#effects) for external I/O.

## Contents

- [Why not just use transactions?](#why-not-just-use-transactions)
- [Is it worth installing here?](#is-it-worth-installing-here)
- [Cloudflare Durable Objects for Rails](#cloudflare-durable-objects-for-rails)
- [Reactive ERB](#reactive-erb)
- [Installation](#installation)
- [Worker requirements](#worker-requirements)
- [Defining an actor](#defining-an-actor)
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
- [Development and contributing](#development-and-contributing)
- [Status](#status)
- [License](#license)

## Why not just use transactions?

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
sweeper, and the race are what a Solid Objects actor replaces.

Three things a lock cannot reach:

- work that fires at a future moment, when no transaction of yours is open;
- work that must survive a process restart, which rules out an in-process
  timer; and
- a fan-in whose critical section spans many jobs over minutes, such as an
  import that counts its own chunks as each one finishes.

If it all happens inside one request, use a lock.

## Is it worth installing here?

Worth it when several requests, jobs, or processes act on the same cart, chat
room, device twin, game room, or long-lived workflow, and each next action
needs the last committed state. Worth it when that same thing also owns work
that fires later, or a number a live page must show.

Not worth it for a plain counter, a single-row update inside one transaction, a
stateless job, bulk ingestion or a data-parallel pipeline, CPU-heavy work, a
large JSON document that belongs in normalized rows, high-QPS request reads, or
a global rate-limit counter that every request touches. One hot identity is
serialized on purpose, so making everything one identity makes a queue.

High-QPS reads and hot identities are where this runtime stops being the right
tool on its own. [Solid Objects Pro](https://solidobjects.pro/) is a commercial
performance layer for this gem that adds grouped commits, which coalesce
concurrent writes into fewer database commits; optional ephemeral operations,
which take loss-tolerant calls out of the durable journal; and materialized
projections, which build read models after commit so reads stop competing with
mailbox work.

Before moving an existing surface, read the
[fit and anti-pattern guide](docs/fit.md), the
[measured costs](docs/benchmarks.md), and the
[migration cookbook](docs/migrating-existing-state.md). This ports the
programming model, not Cloudflare's edge runtime; the exact Rails guarantees
are in [correctness](docs/correctness.md), and this is an early release with no
production-readiness claim.

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

Every enqueue allocates a monotonically increasing sequence number, and an
activation always takes the lowest live one, which is stronger than a
concurrency limit: Solid Queue's
[`limits_concurrency`](https://github.com/rails/solid_queue#concurrency-controls)
caps simultaneous executions sharing a key but explicitly does not guarantee
their order. Every commit verifies an activation generation, the lease owner,
an unexpired database-time lease, and claimed-message membership, so a stale
worker can finish running Ruby but cannot commit.

## Reactive ERB

For a comment count or a dashboard number, lock the row, update it, and call
`broadcast_replace_to`. That is less code than this gem and it works.

It gets harder when several people write to the same record at once. Each
request renders the fragment in its own process and pushes it. The lock decided
who wrote first, but it has no say over which push arrives last, so a viewer
can be left looking at the older number. The second gap is that the push is not
part of the save: if the process dies after the database commits and before the
push goes out, the browser keeps a wrong number and nothing corrects it.

An observable is the alternative. The state change and the broadcast row commit
together, a worker delivers that row and retries until it succeeds, and Cable
ignores an older `(instance_id, state_revision)` pair after a newer one. A
viewer cannot end up on an older number, though delivery itself is still at
least once.

```erb
<%= solid_object @sale, authorization_context: current_user do |sale| %>
  <span class="seats"><%= sale.remaining %> seats left</span>
  <%= sale.component :buyers, observes: :holds %>
<% end %>
```

The two observables in the ticket sale are what make that template live: a
committed turn that changes `remaining` replaces the span, and one that changes
`holds` re-renders the component from `actors/ticket_sale/_buyers`. Observables
are invalidation-only unless declared `broadcast: :value`, which is why
`remaining` carries it and `holds` does not: only an opted-in scalar sends its
value to every authorized subscriber, and rendering an invalidation-only
observable as a span raises. Per-viewer state belongs in `broadcast_payload`.
Signed tokens protect integrity, not access: rendering, Cable, and every
refresh each authorize again.

Reactive views require `turbo-rails`, an Action Cable adapter, and
`mount SolidObjects::Engine => "/solid_objects"`. They are optional; the actor
runtime does not depend on Turbo. The [realtime guide](docs/realtime.md) covers
keyed components and signed locals, `refresh: :morph`, reconnect fencing,
subscription limits, and the per-refresh cost model.

## Installation

Ruby 3.3 or newer and Rails 7.1 or newer. CI runs the suite against Rails 7.1,
7.2, 8.0, and 8.1.

```bash
bundle add solid_objects
bin/rails generate solid_objects:install
bin/rails db:migrate
bin/rails solid_objects:doctor
```

The doctor validates configuration and schema shape, reports authorization
posture and live roles, and completes a real synchronous actor round-trip
without a worker.

The generated initializer is intentionally inert: all five policies deny by
default. Replace them before sending messages, querying state, destroying
actors, subscribing to streams, or mounting administration routes. Knowledge of
an actor ID or a signed stream token is never authorization. Read the
[policy reference](docs/authorization.md) first. Upgrades, the RuboCop
exclusion for engine migrations, and Sorbet RBI generation are in the
[operations guide](docs/operations.md#installing-and-upgrading).

## Worker requirements

Synchronous actors can be adopted without adding a long-running process. Start
the runtime when the feature introduces asynchronous delivery or outboxes:

| Feature | Runtime roles required |
| --- | --- |
| Direct actor method, `sync`, query read, `snapshot`, or `destroy` | None; the caller executes it |
| `async` including delayed delivery | Actor worker |
| One-shot or recurring `schedule` | Reminder scheduler and actor worker |
| `emit`, with or without an actor callback | Effect worker, plus actor worker for callbacks |
| Actor-to-actor `async` or `send_to` | Effect worker and actor worker |
| Scalar or component Turbo updates | Broadcast worker, Action Cable, and the actor execution path |

`bundle exec solid_objects start` runs every role. A missing worker never makes
a durable `async` message disappear, but it leaves the message pending
indefinitely. An extension gem can register its own long-running component to
run beside the built-in roles; see the
[operations guide](docs/operations.md#running-an-extension-in-the-same-process).

## Defining an actor

`TicketSale` above is the whole shape. Class-level `attribute` declarations are
the per-object durable storage schema. Public instance methods are durable
message handlers, so declare helpers private. Attributes also become ordered
read queries on a reference: `sale.remaining` goes through the mailbox, while
`sale.snapshot.remaining` reads the most recently committed state without one
and does not activate a missing actor.

State, arguments, results, effects, and reminder arguments accept
JSON-compatible values only, and Solid Objects never deserializes Ruby
`Marshal` data. Returned values are deeply frozen, so mutating one cannot
bypass the mailbox; use `SolidObjects.mutable_copy(value)` to change a copy.

Lifecycle hooks `on_activate` and `on_deactivate` are available. They should be
deterministic and must not perform slow network I/O. See the
[architecture guide](docs/architecture.md) for their persistence semantics.

The durable identity is `actor_type` plus `actor_id`, which together play the
role of a Durable Objects namespace and object name. The type is inferred from
the class name; declare `actor_type "ticket_sale"` when the persisted name
should survive a constant rename. Types resolve only through the explicit
registry, and Solid Objects never constantizes a type supplied by a client.

## Invoking an object

As with a Durable Object stub, declared operations are available directly on a
reference. A direct call is synchronous from the caller's perspective: Solid
Objects durably enqueues it, executes the actor locally when its fenced
activation is available, and returns the committed, deeply frozen result.

Use `async` for durable fire-and-forget work, and explicit `sync` for a
timeout, idempotency key, or authorization context different from the defaults:

```ruby
order.async(idempotency_key: "submit-order-123").submit
order.async(available_at: 10.minutes.from_now).evaluate
order.sync(timeout: 5.seconds, authorization_context: Current.user).status
```

`async` needs a running actor worker, and installing the engine starts no role.
Until `bundle exec solid_objects start` runs, the message stays ready rather
than lost.

Delivery configuration belongs on `async(...)` or `sync(...)` before the
operation, so keywords on the final call are always message arguments:
`order.sync(timeout: 5.seconds).record(timeout: "payload")` keeps the two
apart. A timeout never cancels the durable invocation, so the call can finish
after its caller gives up; `SolidObjects::SyncTimeout` carries a
`message_reference` that can reauthorize and wait for the result. Do not wrap a
synchronous call in `ApplicationRecord.transaction`: Solid Objects raises
`SolidObjects::SyncInsideTransaction` before enqueue.

Actor code cannot use direct calls or `sync` on another actor, because
synchronous actor-to-actor waits can deadlock in cycles. Use `async` or
`send_to`, which stages delivery with the current turn, returns `nil`, is
discarded if the turn does not commit, and accepts messages rather than
queries:

```ruby
send_to(audit_log, idempotency_key: event_id).record(event_name: "account_disabled")
```

### Domain rejection and redelivery

`reject :validation_failed, "Response is not valid"` ends a turn without
retrying or dead-lettering. The caller receives `SolidObjects::Rejected` with a
stable code, message, and JSON-compatible details; the rejected message stays
durable for audit, actor state rolls back, and no later turn is blocked. A code
must match `\A[A-Za-z_][A-Za-z0-9_]*\z`, and an invalid one raises
`SolidObjects::InvalidRejectionCode`.

Sequential does not mean once. A handler can run again after a crash or lease
loss, so guard logical transitions in durable actor state and deduplicate
external effects on the stable effect ID. See
[handler idempotency](docs/correctness.md#handler-idempotency).

## Application database writes

Actor handlers execute outside the fenced commit. They may query application
records, but Solid Objects rejects direct Active Record writes from all
user-supplied actor code, so an application row cannot commit before the actor
later raises or loses its fence.

For a short database-only change that must commit atomically with actor state,
stage a named action and register its implementation at boot. The registered
block runs inside the fenced transaction, so its writes, actor state, message
completion, and outboxes commit or roll back together:

```ruby
def finish(attempt_id:, score:)
  self.status = "complete"
  commit_action :complete_attempt, attempt_id:, score:
end
```

See
[registering handlers](docs/architecture.md#registering-effect-and-commit-action-handlers).

## Effects

Solid Objects does not hold a database transaction across slow external I/O.
`emit` stages a transactional outbox entry alongside state and message
completion, and an effect worker performs the call afterwards:

```ruby
def checkout(payment_id:)
  self.checkout_status = "pending"
  emit(:charge_payment, payment_id:,
    on_success: :payment_succeeded, on_failure: :payment_failed)
end
```

A success callback receives `effect_id:`, `arguments:`, and `result:`. The
provider call can repeat if a process dies after external success but before
recording completion, so the consumer must deduplicate on the stable effect ID.
See [registering handlers](docs/architecture.md#registering-effect-and-commit-action-handlers).

## Reminders

A reminder is a per-object alarm. When due it becomes an ordinary mailbox
message under the same ordering, retry, lease, and fencing rules as every other
turn:

```ruby
schedule(at: 30.minutes.from_now).expire
schedule(at: entry.fetch("wait_until"), key: entry.fetch("id")).deliver
```

A reminder is named for its operation, so re-arming `expire` moves the same
alarm rather than adding one. Pass `key:` when the actor waits on several items
at once and each needs its own alarm. Without a key, scheduling per item is a
data-loss bug: every entry overwrites the previous entry's alarm, nothing
raises, and only a `solid_objects.reminder.replaced` event records it.

There is no `unschedule`; a reminder stops when its handler does not re-arm it.
The [reminders guide](docs/reminders.md) covers the naming rules, one alarm for
a whole queue, and reconciliation for self-scheduling actors.

## Destroying an object

`Counter.ref("global").destroy` is synchronous and idempotent. In one
transaction it locks and deletes the instance, and cascading foreign keys
remove state, message history, mailbox rows, dead letters, reminders, effects,
and broadcasts. It has its own deny-by-default `authorize_destroy` policy,
cannot be called synchronously from actor code, and does not run
`on_deactivate`. A stale activation cannot commit afterwards, and addressing
the same type and ID later creates a fresh incarnation with sequence 1. Read
[destruction semantics](docs/correctness.md#destruction) first.

## State migrations

Actor state has an independent schema version. An actor refuses activation when
stored state is newer than the running code, and published migration blocks
cannot be squashed, because a long-idle actor may still hold an old
representation:

```ruby
state_version 2

migrate_state from: 1, to: 2 do |state|
  state["currency"] ||= "USD"
  state
end
```

Read the [state migration guide](docs/state-migrations.md) before changing
persisted state.

## Configuration

Configure Solid Objects in `config/initializers/solid_objects.rb`. Invalid
lease intervals, component counts, and size limits fail fast at boot. The
[operations guide](docs/operations.md#configuration) lists every setting with
its default, and covers polling intervals and cross-process wake-up adapters.

```ruby
SolidObjects.configure do |configuration|
  configuration.worker_count = 4
  configuration.lease_duration = 30.seconds
end
```

## Workers and operations

`solid_objects start` runs actor, effect, reminder, and broadcast roles under
one supervisor. Administration commands require the administration policy:

```bash
bundle exec solid_objects start
bundle exec solid_objects status
bundle exec solid_objects prune_messages
bundle exec solid_objects retry_dead_letter 123
```

Prune commands preview counts by default; add `--execute` after reviewing the
retention policy. Graceful shutdown stops new claims, drains active loops,
releases cached leases, and marks process rows stopped. A hard-killed worker's
claimed turn is recovered once its heartbeat or lease goes stale. The engine
loads `app/actors` in every process that boots the application, so a web
process can resolve an actor by name for a Cable subscription or a component
render. See the [operations guide](docs/operations.md).

## Dashboard

`SolidObjects::Web` is a Rack application showing instances and their state,
the mailbox, reminders, effects, broadcasts, dead letters, and processes. Mount
it inside the application routes so the Rails session middleware runs first:

```ruby
require "solid_objects/web"

mount SolidObjects::Web => "/solid_objects/dashboard"
```

It is not loaded by `require "solid_objects"`, because a worker process must
not carry a web stack. Every page asks `authorize_administration` first, and
that policy denies by default, so a mount alone exposes nothing. See the
[dashboard guide](docs/dashboard.md).

## Database support

PostgreSQL 14 or newer, MySQL 8.0 or newer on InnoDB through either the
`mysql2` or `trilogy` client, and SQLite 3.35 or newer. PostgreSQL and MySQL
claim hot-table rows with `FOR UPDATE SKIP LOCKED`; SQLite uses its serialized
writer. All three run the same locking, fencing, mailbox, outbox, and engine
test suite, and no Redis or Kafka service is required.

Actor tables use the application's Active Record connection by default. A
separate database role is optional, and every table participating in an actor
commit must share one database:

```ruby
configuration.connects_to = { database: { writing: :actors, reading: :actors } }
```

## Guarantees

For one actor identity, messages are durably enqueued with explicit sequence
numbers, processed sequentially in that order, delivered at least once, and
committed by at most one valid activation owner and fencing generation.
Different identities may execute concurrently. One successful turn commits
actor state and version, the message result and completion, effect outbox
entries, reminder changes, actor-to-actor messages, and observable broadcasts
together, or none of them.

Solid Objects does not promise:

- exactly-once handler or effect execution;
- global order across actors, or distributed transactions;
- bounded end-to-end latency;
- cancellation when a synchronous caller times out; or
- that a lease stops stale Ruby code from running.

The fencing generation is what stops stale code from committing. Read
[correctness](docs/correctness.md) for the full contract.

## Comparisons

| Tool | What Solid Objects adds or changes |
| --- | --- |
| `with_lock` or `SELECT ... FOR UPDATE` | A lock serializes writers for one transaction, on one connection, in one process, and needs nothing installed. Solid Objects covers the part that outlives the transaction: an alarm that fires later, work that survives a restart, and a broadcast that commits with the state change. Prefer the lock when the whole job fits inside one request. |
| Cloudflare Durable Objects | The same named, stateful, serialized-object model, on your SQL database and Rails workers rather than Cloudflare's globally distributed runtime, placement, and storage APIs. |
| Active Job and Solid Queue | Jobs are independent work units, and Solid Queue's concurrency controls cap overlap without guaranteeing order. Solid Objects adds addressable identity, durable state, per-identity order, activation leases, and fencing. |
| Action Cable | Cable transports transient realtime messages. Solid Objects owns the durable state and work; Cable is an optional delivery path for committed observable projections. |
| Orleans | The virtual-actor lineage behind the model. Solid Objects is a smaller Rails-native runtime and does not match Orleans clustering or placement breadth. |
| Active Record service object | A service object runs directly against records. Solid Objects adds durable ordering, retries, fencing, reminders, and outboxes at greater operational cost. |

## Development and contributing

Solid Objects uses Minitest and follows Solid Queue's test organization and
RuboCop policy. Ruby source carries inline RBS annotations, and concurrency
tests use real database locks rather than mocked locking. `bundle exec rake`
runs the SQLite suite and static checks; set `SOLID_OBJECTS_DATABASE_URL` for
PostgreSQL or MySQL.

A change here can affect durable state and recovery, so start with a failing
test and quote the observed failure in the pull request:

- [Contributing](CONTRIBUTING.md) covers setup, the quality gates, and what a
  correctness change must show.
- [Development guide](docs/development.md) covers the test layout and the
  adapter matrix.
- [Changelog](CHANGELOG.md) and the
  [roadmap](docs/roadmap.md) record what shipped and what is still open.
- Report a vulnerability through
  [GitHub security advisories](https://github.com/cardmagic/solid-objects-ruby/security/advisories/new)
  rather than a public issue.

## Status

The correctness core is implemented and tested against SQLite, PostgreSQL, and
MySQL: ordered mailboxes, fenced activation, retries and dead letters,
reminders, effects, commit actions, destruction, and reactive views. Still
open: Turbo append actions, distributed rate limits and global admission
control, and scheduled maintenance beyond the pruning commands.

There is no production-ready claim; that needs hardening and operational soak
evidence. The [roadmap](docs/roadmap.md) tracks what is done, what is partial,
and what is measured rather than assumed.

## License

Solid Objects is MIT Licensed by Lucas Carlson. See
[MIT-LICENSE](MIT-LICENSE).

Solid Objects is an independent open-source project. It is not affiliated with,
sponsored by, or endorsed by Cloudflare, Inc. “Cloudflare” and “Durable
Objects” are trademarks of Cloudflare, Inc. and are used here to identify the
programming model this gem ports to Rails.
