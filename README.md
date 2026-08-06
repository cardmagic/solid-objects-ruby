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

# from anywhere in your app — addressed by name:
Counter.ref("global").increment(amount: 5)
```

`Counter / global` is a logical identity. Like a Durable Object named with
`idFromName`, it can be addressed from anywhere without first creating or
locating a Ruby object. Solid Objects activates it when work arrives, commits
its ordered turns one at a time, persists its state, and deactivates it when
idle. Different identities can run concurrently.

This is a port of the programming model, not Cloudflare's edge runtime or
platform. Read the conceptual overview at [solidobjects.dev](https://solidobjects.dev/)
and the exact Rails guarantees in [Correctness and delivery semantics](docs/correctness.md).

Version 0.1 is an early release. Its correctness core is implemented and tested,
but the project does not yet claim production readiness. See
[Status](#status) and the [roadmap](docs/roadmap.md).

## Table of contents

- [Cloudflare Durable Objects for Rails](#cloudflare-durable-objects-for-rails)
- [Reactive ERB](#reactive-erb)
- [Installation](#installation)
- [Defining an actor](#defining-an-actor)
- [Actor identity](#actor-identity)
- [Messages and queries](#messages-and-queries)
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
  schedule :expire, at: 30.minutes.from_now, arguments: {}
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
class ShoppingCart < SolidObjects::Actor
  attribute :items, default: -> { [] }

  observable :items_count do
    items.sum { |item| item.fetch("quantity") }
  end
end
```

Render it:

```erb
<%= solid_object current_cart do |cart| %>
  Cart items: <%= cart.items_count %>
<% end %>
```

That template provides initial server rendering, a stable opaque DOM target,
and live Turbo replacements after committed actor turns. One `solid_object`
block makes one Action Cable subscription for all values inside it, and Action
Cable multiplexes subscriptions over the browser's WebSocket.

No client-side state store, custom Stimulus controller, channel class, manual
broadcast, or one-WebSocket-per-value setup is required. Signed stream tokens
protect integrity, an application policy authorizes every subscription,
broadcasts are delivered from a durable outbox, and reconnecting clients
refresh from current actor state.

`cart.component(:summary)` supports initial rendering of
`actors/shopping_cart/_summary`. Durable live component replacement and
Turbo append actions are roadmap work; observable replacement is the live path
implemented in 0.1.

Reactive views require `turbo-rails` and a working Action Cable adapter in the
host application. They are optional; the actor runtime itself does not depend
on Turbo.

## Installation

Solid Objects requires Ruby 3.3 or newer and Rails 8.0 or newer.

Add the gem, install its initializer and migration, then migrate:

```bash
bundle add solid_objects
bin/rails generate solid_objects:install
bin/rails db:migrate
```

The generated initializer denies all externally initiated operations. Replace
the policy blocks with application-specific authorization before sending
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

Start the runtime:

```bash
bundle exec solid_objects start
```

The engine uses the application's primary Active Record connection by default.
See [Database support](#database-support) for a separate database configuration.

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

Attributes also become ordered read queries on a reference. Declared messages
become asynchronous methods:

```ruby
cart = ShoppingCart.ref("alice")
message = cart.add_item(product_id: "shirt-123", quantity: 2)
items = cart.items
```

`message` is a `SolidObjects::MessageReference`. `items` is a deeply frozen
JSON snapshot; mutating it cannot bypass the actor mailbox. State changes must
go through public actor message methods.

State, arguments, results, effects, and reminder arguments accept
JSON-compatible values. Solid Objects never deserializes Ruby `Marshal` data.

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

## Messages and queries

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
message = counter.increment(amount: 5)
value = counter.value
```

Public actor methods are messages and become asynchronous syntax over `tell`,
returning a durable `MessageReference`. Declared queries and attribute readers
are synchronous syntax over `ask`. Unlike Cloudflare RPC, the initial `ask`
implementation waits by polling the durable database row.
The `message(:name) { ... }` DSL remains available for dynamic definitions.
The explicit `tell` and `ask` forms remain available for dynamic operation
names or names that collide with Ruby or reference methods.

### `tell`

`tell` durably enqueues work and immediately returns a message reference:

```ruby
message = order.tell(
  :submit,
  idempotency_key: "submit-order-123"
)
```

Use `available_at:` to spread bulk work or delay one message:

```ruby
order.tell(:evaluate, available_at: 10.minutes.from_now)
```

### `ask`

`ask` durably enqueues a query or message and waits for its result:

```ruby
status = order.ask(:status, timeout: 5.seconds)
```

The initial cross-process implementation polls the durable message row. It is
intended for background callers and control paths, not latency-sensitive HTTP
request handling. A timeout does not cancel the actor message.

Actor code cannot call `ask`; synchronous actor-to-actor waits can deadlock in
cycles. Use `tell` or `send_to` and a result message.

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

def payment_succeeded(effect_id:, result:)
  self.checkout_status = "paid"
end

def payment_failed(effect_id:, error:)
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

## Reminders

Reminders are Solid Objects' durable equivalent of the Durable Objects Alarms
API. One-shot and recurring alarms are actor-owned database records:

```ruby
def schedule_evaluation
  schedule :evaluate, at: 1.hour.from_now, every: 1.hour, missed: :latest
end
```

Use `missed: :latest` to coalesce missed occurrences or `missed: :all` to
enqueue each one.

Self-scheduling actors should also have a low-frequency application reconciler.
It may read `SolidObjects::Instance.states_for`, `.without_pending_work`, and
`.orphaned`, but every repair must go through `tell`. Never bulk-update actor
state around the lease and fencing checks.

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
| `ask_polling_interval` | 0.05 seconds |
| `lease_duration` | 30 seconds |
| `lease_renewal_interval` | 10 seconds |
| `idle_deactivation_timeout` | 30 seconds |
| `max_messages_per_activation_pass` | 50 |
| `max_activation_duration` | 5 seconds |
| `max_mailbox_length` | 10,000 |
| `max_attempts` | 5 |
| `process_heartbeat_interval` | 15 seconds |
| `process_alive_threshold` | 60 seconds |
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
bundle exec solid_objects dead_letters
bundle exec solid_objects retry_dead_letter 123
```

The supervisor stops new claims, drains active loops, releases cached leases,
and marks process rows stopped on graceful shutdown. A hard-killed worker's
claimed turn is recovered after its process heartbeat or activation lease
becomes stale.

See the [operations guide](docs/operations.md) for monitoring, reconciliation,
shutdown, retention, and backup guidance.

## Database support

Solid Objects supports:

- PostgreSQL 14 or newer
- MySQL 8.0 or newer using InnoDB
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
- cancellation when an `ask` caller times out; or
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

Implemented and tested in 0.1:

- Rails engine, install generator, migrations, and `solid_objects` executable;
- actor registry, references, JSON state, and state migrations;
- durable message history plus ready and claimed membership tables;
- concurrent sequence allocation and actor creation;
- activation leases, renewal, fencing generations, and stale-write rejection;
- bounded activation passes, idle activation cache, and hot-actor fairness;
- retries, strict poison ordering, dead letters, and retry tooling;
- transactional effects and asynchronous actor-to-actor messages;
- one-shot and recurring per-actor reminders;
- authorized actor destruction with fenced stale-write rejection and cascading
  durable-work cleanup;
- durable observable broadcasts and authorized Action Cable refresh;
- process registration, heartbeats, cleanup, and graceful shutdown; and
- SQLite, PostgreSQL, and MySQL integration tests.

Partially implemented:

- the supervisor starts and drains roles but does not replace a crashed role or
  run periodic maintenance automatically;
- cross-process wake-up uses polling; PostgreSQL notifications and optional
  Redis acceleration are not implemented;
- live observable replacement works, while live component replacement and
  Turbo append actions remain future work;
- local admission limits exist, but distributed rate limits and global
  admission control do not; and
- administration views exist, but retention automation and richer audit tools
  do not.

Production readiness requires hardening and operational soak evidence. The
[roadmap](docs/roadmap.md) tracks that work.

## License

Solid Objects is MIT Licensed by Lucas Carlson. See
[MIT-LICENSE](MIT-LICENSE).

Solid Objects is an independent open-source project. It is not affiliated with,
sponsored by, or endorsed by Cloudflare, Inc. “Cloudflare” and “Durable
Objects” are trademarks of Cloudflare, Inc. and are used here to identify the
programming model this gem ports to Rails.
