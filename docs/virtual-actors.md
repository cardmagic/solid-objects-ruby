# Virtual actors in Ruby on Rails

## Short answer

Yes. Solid Objects is a SQL-backed virtual actor library for Ruby on Rails.
The gem is `solid_objects`. It gives each actor a stable identity, durable
state, ordered operations, and automatic activation.

Solid Objects requires Rails. It is a Rails engine for Ruby 3.3 or newer and
Rails 7.1 or newer. It is not a framework-independent Ruby actor runtime.
State and mailboxes live in the SQLite, PostgreSQL, or MySQL database that the
Rails application already uses. Redis and a separate actor service are not
necessary.

Solid Objects is a pre-1.0 release. It makes no production-ready claim. Read
[Compatibility and maturity](#compatibility-and-maturity) before you choose it.

## What a virtual actor is

A virtual actor is a logical object that always exists by name. The caller
does not create it, start it, or stop it. The runtime loads it when a message
arrives and releases it when it is idle. Microsoft Orleans made this model
known as "virtual actors".

Solid Objects implements four properties of that model:

| Property | What it means | How Solid Objects does it |
| --- | --- | --- |
| Stable identity | An actor is addressed by type and ID, for example one cart per user. | `ShoppingCart.ref(user.id)` returns a cheap reference. The reference does not load the actor. |
| Automatic activation | The first message activates the actor. An idle actor is released. | A process claims a fenced activation lease when work arrives. The lease is released after the idle timeout. |
| Durable state | State survives process restarts and deploys. | Actor attributes are a JSON document in the application database. |
| Ordered turns | One identity runs one operation at a time, in a fixed order. | Each call is a durable mailbox message with a per-actor sequence number. |

Different identities run concurrently. One identity is a serialization point
on purpose.

## A small example

This actor holds one ticket for a buyer and releases the hold after ten
minutes. Put it in `app/actors/ticket_sale.rb`:

```ruby
class TicketSale < SolidObjects::Actor
  attribute :available, default: 1
  attribute :holds, default: -> { {} }

  def hold(buyer:)
    return { held: false, available: } if available.zero? || holds.key?(buyer)

    self.available -= 1
    self.holds = holds.merge(buyer => Time.current.to_i)
    schedule(at: 10.minutes.from_now, key: buyer).expire(buyer:)
    { held: true, available: }
  end

  def expire(buyer:)
    return available unless holds.key?(buyer)

    self.holds = holds.except(buyer)
    self.available += 1
  end
end
```

Call it from a controller, a job, or the console:

```ruby
TicketSale.ref("event-42").hold(buyer: "ada")
```

Two concurrent `hold` calls for `event-42` enter the same mailbox. They commit
one at a time, so only one buyer gets the ticket. The hold and its reminder
commit in one transaction. The reminder runs in the Solid Objects runtime
process:

```bash
bundle exec solid_objects start
```

If that process stops, the reminder stays in SQL. It runs when the process
starts again.

The example needs installation, migrations, and an authorization policy. The
generated policies deny every operation by default. For the complete setup,
use one of these guides:

- [Installation](../README.md#installation) in the README.
- [The clean-install quickstart](../examples/quickstart/README.md), which a
  smoke check runs against the built gem in a new Rails application.
- [The agent guide](agents.md), which gives setup and verification steps for
  coding agents.

## When to use it

Solid Objects is a good candidate when most of these conditions are true:

- State belongs to one durable identity, such as a cart, room, booking,
  device, account, or workflow.
- Writes for that identity must be serialized across requests, jobs, and
  processes.
- The work must happen later, survive a restart, or stay ordered across more
  than one request.
- The state is a bounded JSON document.
- The identity needs reminders, external effects, or reactive Rails views that
  follow its committed state.

## When to use something else

Do not use an actor when a simpler tool enforces the invariant:

- One short transaction, `with_lock`, or a database constraint is enough. A row
  lock is often the clearest answer.
- The work is CPU-intensive or data-parallel. An actor serializes work. It does
  not add CPU parallelism.
- One hot identity must accept many writes for each second, for example a
  request-path rate limiter or a page-view counter.
- The state is large, relational, or query-heavy. Keep that data in normal
  tables.
- The operation must change two actor identities in one atomic transaction.
  Solid Objects has no cross-actor transactions.
- You need exactly-once calls to an external API. No actor library can promise
  that through every network failure. Solid Objects gives at-least-once
  delivery and stable effect IDs for idempotency keys.
- You need replay of named workflow steps from a step log. That is a durable
  execution engine, not an actor.

[Choosing Solid Objects](fit.md) has the full checklist and the cost model.

## How it compares

This table compares coordination models for a Rails application. It does not
rank the projects. Facts about other projects were checked on October 7, 2026,
against the sources in [Primary references](#primary-references).

| Approach | Unit of order | Durable state | Delayed work | Extra service | Good for |
| --- | --- | --- | --- | --- | --- |
| `with_lock` or a short SQL transaction | Rows in one transaction | Application tables | None | No | An invariant that fits in one request |
| Active Job with Solid Queue | None. `limits_concurrency` limits overlap for each key, but it does not set an order | Application tables, owned by the application | Scheduled jobs | No; Solid Queue uses the database | Background work that does not own entity state |
| Sidekiq | None in the open-source gem. Unique jobs and rate limits are Sidekiq Enterprise features | Application tables, owned by the application | Scheduled jobs | Redis | High-volume background jobs |
| In-process concurrency: Ractor, `concurrent-ruby-edge` actors, Async | One Ruby object in one process | None. State is lost when the process stops | In process only | No | Parallel or concurrent work inside one process. Ractor is experimental in Ruby 4.0 |
| Solid Objects | Actor type and ID | JSON state in the application database | Durable per-actor reminders | No; the `solid_objects start` process runs in the app | Durable per-identity state with ordered operations |
| Dapr actors | Actor type and ID, one turn at a time | A transactional Dapr state store | Durable reminders through the Dapr Scheduler service | A Dapr sidecar, plus the placement and Scheduler services. Dapr has no official Ruby SDK | Polyglot services on a Dapr platform |
| Temporal (`temporalio` gem) | A workflow execution | Temporal event history | Durable timers | A Temporal Service, self-hosted or Temporal Cloud | Long-running workflows that replay deterministic code |

### Orleans concept map

Orleans is the reference design for virtual actors on .NET. Solid Objects
uses the same programming model on a SQL database. It does not copy the
Orleans cluster, placement, or feature set.

| Orleans | Solid Objects | Difference |
| --- | --- | --- |
| Grain class | `SolidObjects::Actor` subclass | None in concept |
| Grain identity (key) | Actor type and actor ID | None in concept |
| Activation on first call | Activation lease on first claimed message | Solid Objects fences each activation with a database generation |
| Turn-based execution | Ordered mailbox, one turn at a time | Orleans can enable reentrancy. Solid Objects turns for one identity never interleave |
| Grain persistence | JSON attributes in the application database | An Orleans grain calls `WriteStateAsync`. Solid Objects persists state with the turn that changed it |
| Reminders | `schedule` | Both are durable. Orleans skips a tick that falls due while the cluster is down. A due Solid Objects reminder runs when a runtime process starts. Solid Objects has no non-durable timers |
| Silos and cluster membership | Any Rails process that runs `solid_objects start` | Solid Objects has no placement, directory, or cluster membership. The database is the coordination point |
| Streams | Observables, broadcasts, and reactive ERB | Solid Objects delivers committed revisions to Action Cable |

Solid Objects delivery is at least once. Write each handler so that it can run
again without harm.

## Guarantees and boundaries

- Calls are durably ordered per identity. Different identities can run
  concurrently.
- Delivery is at least once, not exactly once. A handler can start again after
  a crash or a lost lease.
- Ordered turns do not cancel stale Ruby code. Fencing stops a stale activation
  from a commit, but that code can continue to run.
- External effects can run more than once. Use the stable effect ID, or
  another durable key, as the idempotency key at the provider.
- There are no transactions across actor identities, and there is no replay of
  durable function steps.
- Reminders, `async` calls, effects, and broadcasts need the
  `bundle exec solid_objects start` process. When that process stops, the work
  waits in SQL. The gem does not supply a hosted worker.
- One hot identity is sequential. The core gem is not a high-throughput
  request-path rate limiter.
- The guarantees apply only to changes made through the actor APIs. Actor
  fencing does not protect direct writes to the same data or other external
  requests.

The [correctness contract](correctness.md) states each guarantee and the crash
matrix.

## Compatibility and maturity

- Ruby 3.3 or newer and Rails 7.1 or newer. CI runs Ruby 3.3, 3.4, and 4.0
  against Rails 7.1, 7.2, 8.0, and 8.1.
- SQLite 3.35 or newer, PostgreSQL 14 or newer, or MySQL 8.0 or newer with
  InnoDB. MySQL works through `mysql2` or `trilogy`.
- SQLite is correct for the same contract, but it is best for development and
  modest single-host workloads.
- Pre-1.0. Expect changes that break compatibility. The correctness core has tests against all
  three databases. The project has no production-ready claim and no measured
  scale claim.

The [roadmap](roadmap.md) records what is tested, what is partial, and what is
next. For TypeScript and Node.js, use the
[solid-objects](https://github.com/cardmagic/solid-objects-js) package.

## Primary references

- Orleans: [Overview](https://learn.microsoft.com/en-us/dotnet/orleans/overview),
  [Request scheduling](https://learn.microsoft.com/en-us/dotnet/orleans/grains/request-scheduling),
  [Timers and reminders](https://learn.microsoft.com/en-us/dotnet/orleans/grains/timers-and-reminders),
  [Grain persistence](https://learn.microsoft.com/en-us/dotnet/orleans/grains/grain-persistence/),
  and [Grain placement](https://learn.microsoft.com/en-us/dotnet/orleans/grains/grain-placement).
- Ruby: [Ractor](https://docs.ruby-lang.org/en/4.0/Ractor.html) and the
  [Ruby 4.0.0 release notes](https://www.ruby-lang.org/en/news/2025/12/25/ruby-4-0-0-released/).
- concurrent-ruby: [repository](https://github.com/ruby-concurrency/concurrent-ruby)
  and [`Concurrent::Actor`](https://ruby-concurrency.github.io/concurrent-ruby/master/Concurrent/Actor.html).
- Solid Queue: [concurrency controls](https://github.com/rails/solid_queue#concurrency-controls).
- Sidekiq: [Enterprise unique jobs](https://github.com/sidekiq/sidekiq/wiki/Ent-Unique-Jobs)
  and [Enterprise rate limiting](https://github.com/sidekiq/sidekiq/wiki/Ent-Rate-Limiting).
- Dapr: [Actors overview](https://docs.dapr.io/developing-applications/building-blocks/actors/actors-overview/),
  [Actor timers and reminders](https://docs.dapr.io/developing-applications/building-blocks/actors/actors-timers-reminders/),
  and [SDKs](https://docs.dapr.io/developing-applications/sdks/).
- Temporal: [Ruby SDK](https://github.com/temporalio/sdk-ruby) and
  [Event History](https://docs.temporal.io/encyclopedia/event-history).

Other projects change. Check these sources again before you base an
architecture decision on one row.
