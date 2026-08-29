# Solid Objects for Rails

[![CI](https://github.com/cardmagic/solid-objects-ruby/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/cardmagic/solid-objects-ruby/actions/workflows/ci.yml)
[![gem](https://img.shields.io/gem/v/solid_objects)](https://rubygems.org/gems/solid_objects)

**Open Source Durable Objects in your Rails app.**

In a shopping cart, paying twice at the same time is a big problem. The payment provider might time out, and your Rails site could be restarting before recovery finishes.

To deal with this safely, you often need logic scattered between 7-10 files like database row locks, Redis locks, delayed jobs, retries, and cleanup code to keep that process straight. They are not all large, but they must agree about the same payment state and failure rules. That coordination is the difficult part.

With Solid Objects, one actor in one file owns each shopping cart's full state and recovery work. Method calls on that object run one at a time, state lives in your existing SQL database, and scheduled recovery resume after restarts.

Solid Object Rails Actors elegantly fit anything where one identifiable thing must remember state, handle competing requests in order, or wake up later:

- Ticket holds and reservations
- Multiplayer games and shared rooms
- Shopping carts and checkout recovery
- Rate limits and account quotas
- Session expiration
- Job leases and workflows
- Connected devices
- Collaborative documents

And so much more.


## Contents

- [Installation](#installation)
- [An expiring ticket hold](#an-expiring-ticket-hold)
- [Why this exists](#why-this-exists)
- [Good uses](#good-uses)
- [When a transaction is better](#when-a-transaction-is-better)
- [Guarantees and boundaries](#guarantees-and-boundaries)
- [Read more](#read-more)
- [Status and license](#status-and-license)

## Installation

Solid Objects requires Ruby 3.3 or newer and Rails 7.1 or newer.

```bash
bundle add solid_objects
bin/rails generate solid_objects:install
bin/rails db:migrate
bin/rails solid_objects:doctor
```

The generator adds Solid Objects tables to the application's existing database.
All authorization policies deny by default, a rare example of generated code
declining to become an incident.

For the local example below, allow messages and queries in the generated
initializer:

```ruby
SolidObjects.configure do |configuration|
  configuration.authorize_message = ->(**) { true }
  configuration.authorize_query = ->(**) { true }
end
```

Those callbacks are for local testing only. Production policies must bind actor
IDs and operations to the authenticated user or tenant.

## An expiring ticket hold

Put this ordinary Ruby class in `app/actors/ticket_sale.rb`:

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

Call it from a controller, job, console, or anywhere else in the Rails app:

```ruby
result = TicketSale.ref(params.require(:event_id)).hold(
  buyer: current_user.id.to_s
)
render json: result
```

Concurrent requests for the same event enter the same durable mailbox and
commit one at a time. The successful call stores the hold and its ten-minute
reminder with the state change. The direct call needs no worker; the reminder
does:

```bash
bundle exec solid_objects start
```

Stop that process before the deadline and restart it afterwards. The reminder
is still in the Rails database and runs when the process returns. We have given
`self.available += 1` a supervisor and excellent posture.

## Why this exists

The handwritten Rails version usually starts with `with_lock`. Then it gains an
`expires_at` column, a cron job, an Active Job retry policy, and an Action Cable
broadcast that must agree with the write. A small invariant has become a rich
tapestry of callbacks and scheduled cleanup.

This is complicated, hard to test, fragile and unnecessary.

Solid Objects keeps the identity, state, ordered calls, retries, reminders, and
staged consequences together inside the Rails application. It uses SQLite,
PostgreSQL, or MySQL. Redis and a separate actor service are not required.

## Good uses

- Multiplayer rooms, chats, and collaborative sessions with ordered changes.
- Carts, reservations, and inventory holds with durable expiry.
- Account, device, assessment, and approval workflows that survive deploys.
- Reactive ERB views that must follow committed actor revisions.

Different identities can run concurrently. Put the whole application behind
one actor ID and Rails will faithfully operate your new bottleneck.

## When a transaction is better

Often. If the entire invariant fits inside one request, use `with_lock`, a
database constraint, or a short transaction. A row lock does not need a
personal brand, and it is usually the clearest answer.

Use Solid Objects when work must happen later, survive a restart, or stay
ordered across several requests or jobs. A plain counter remains one line of
SQL and should be allowed to enjoy that.

## Guarantees and boundaries

- Calls are durably ordered per identity. Different identities may run concurrently.
- Delivery is **at least once**, not exactly once. A handler can begin again after a crash or lease loss.
- One successful turn commits actor state and staged reminders, messages, effects, commit actions, and broadcasts together.
- Fencing prevents stale Ruby code from committing, but it cannot stop that code from continuing to run.
- External effects can repeat and must deduplicate with the stable effect ID or another durable idempotency key.
- Actor handlers may read application records but cannot write them directly. Use `commit_action` for bounded same-database writes and `emit` for external I/O.
- `async`, reminders, effects, and broadcasts need `bundle exec solid_objects start`. Pending work remains in SQL while it is down.
- One hot identity is intentionally sequential. There are no transactions across actor identities.

Exactly once is not hiding in a more advanced configuration. Read the
[correctness contract](docs/correctness.md) before using important data.

## Read more

- [Five-minute Rails guide](https://solidobjects.dev/5min/rails)
- [Choosing Solid Objects](docs/fit.md)
- [Operations and recovery](docs/operations.md)
- [Reminders](docs/reminders.md)
- [Reactive ERB](docs/realtime.md)
- [Detailed architecture](docs/architecture.md)
- [Detailed documentation](docs/)

The dashboard, benchmarks, migration cookbook, schema, and exhaustive API
explanations remain in `docs/`. The README is stopping before it develops a
robust interplay with its own table of contents.

## Status and license

Solid Objects 0.14.2 is a pre-1.0 early release. Its correctness core is tested
against SQLite, PostgreSQL, and MySQL, but the project makes no production-ready
claim. That requires more hardening and operational soak evidence. Pre-1.0 is
not decorative punctuation.

Solid Objects is released under the [MIT License](MIT-LICENSE). It is an
independent project and is not affiliated with, sponsored by, or endorsed by
Cloudflare.
