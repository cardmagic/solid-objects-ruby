# Solid Objects for coding agents (Rails)

This guide is for a coding agent that evaluates or adds Solid Objects in a
Ruby on Rails application. It gives the facts and steps in a fixed order. Each
step links to the maintained documentation for more detail.

## 1. Check the fit first

Use Solid Objects only if you can answer yes to most of these questions:

1. Does one identity, such as a cart, room, booking, account, or device, own
   the state?
2. Must writes for that identity happen one at a time across requests, jobs,
   and processes?
3. Must some work happen later or continue after a process restart?
4. Is the state a bounded JSON document, not a large relational dataset?
5. Can the application run one more process, `bundle exec solid_objects start`,
   for reminders and background work?

Select a simpler tool in these cases:

| Requirement | Use instead |
| --- | --- |
| The invariant fits in one request | `with_lock`, a unique index, or a short transaction |
| CPU-intensive or parallel work | Background jobs or Ractors. An actor serializes work |
| Thousands of writes for each second to one key | A counter column, a cache, or Solid Objects Pro |
| One atomic change across two actor identities | One SQL transaction on normal tables |
| Exactly-once calls to an external API | Not available from any actor library. Use provider idempotency keys |

The full checklist is in [Choosing Solid Objects](fit.md). The category guide
is [Virtual actors in Ruby on Rails](virtual-actors.md).

## 2. Package identity

| Item | Value |
| --- | --- |
| Gem | `solid_objects` |
| Repository | <https://github.com/cardmagic/solid-objects-ruby> |
| Website | <https://solidobjects.dev/ruby> |
| Node.js package | `solid-objects` on npm, a separate port with the same model |
| Commercial extension | `solid_objects_pro`, a separate paid gem. The open-source gem does not need it |

Solid Objects is not part of Rails. It is not Solid Queue, Solid Cache, or
Solid Cable. It is not affiliated with Cloudflare.

## 3. Requirements

- Ruby 3.3 or newer.
- Rails 7.1 or newer. The gem is a Rails engine. It does not run without
  Rails.
- SQLite 3.35 or newer, PostgreSQL 14 or newer, or MySQL 8.0 or newer with
  InnoDB.
- No Redis and no separate actor service.

## 4. Install

```bash
bundle add solid_objects
bin/rails generate solid_objects:install
bin/rails db:migrate
bin/rails solid_objects:doctor
```

The generator adds an initializer and copies migrations into the application.
The doctor checks the configuration, the tables, and one real actor round trip.

Install the current release. `bundle add solid_objects` selects it. Do not pin
a version that you remember from earlier work; the API changed between
releases. The current version is on <https://rubygems.org/gems/solid_objects>.

The generated policies deny every call. Do step 5 before you call an actor.

The `json` gem 3.x works only with Active Support 8.1.4 or newer. On Rails
7.1, 7.2, 8.0, or 8.1 before 8.1.4, pin `gem "json", "~> 2"` in the
`Gemfile`. Without the pin, Active Support raises an `ArgumentError`, such as
`unknown keyword: quirks_mode`, for every JSON column.

[Installing and upgrading](operations.md#installing-and-upgrading) has the
details.

## 5. Authorize

Every policy in the generated initializer denies by default. A new
installation answers no actor call until you write a policy. Do not remove
this behavior.

For a local demonstration only, grant messages and queries:

```ruby
SolidObjects.configure do |configuration|
  configuration.authorize_message = ->(**) { true }
  configuration.authorize_query = ->(**) { true }
end
```

Keep `authorize_destroy`, `authorize_subscription`,
`authorize_administration`, and `authorize_transmission` denied in a
demonstration.

A production policy must bind the actor type and ID to the authenticated user
or tenant. An actor ID is not a permission:

```ruby
SolidObjects.configure do |configuration|
  owns_cart = lambda do |actor_type:, actor_id:, authorization_context:, **|
    user = authorization_context

    actor_type == "ShoppingCart" &&
      user.present? &&
      actor_id == user.id.to_s
  end

  configuration.authorize_message = owns_cart
  configuration.authorize_query = owns_cart
end
```

Pass the context on each call:

```ruby
ShoppingCart.ref(Current.user.id.to_s).add_item(
  product_id: "shirt-123",
  authorization_context: Current.user
)
```

[Authorization policies](authorization.md) lists each policy and its risk.

## 6. Define an actor

Put actors in `app/actors/`. This actor is the example from the README:

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

Obey these rules in actor code:

- Keep state in `attribute` values. State must be JSON-compatible.
- Use `schedule(at:, key:)` for delayed work. A reminder is one named alarm
  for each actor and key. A new `schedule` with the same key moves the alarm.
- Use `reject(code, message)` for a business rule failure that must not retry.
  It takes a code and a message, for example
  `reject(:room_full, "The room is full")`.
- Do not write Active Record models directly in a handler. The runtime raises
  `SolidObjects::ApplicationWriteForbidden`. Use `commit_action` for a short
  write in the same database.
- Do not call an external API in a handler. Use `emit` and an effect handler.
- Write each handler so that it can run again. Delivery is at least once.
- A reminder changes state only when it runs, and it runs only while
  `solid_objects start` runs. Do not compute expiry from the clock in a query;
  read the state that the reminder committed.

Avoid these mistakes:

| Mistake | Correct form |
| --- | --- |
| `schedule(at: deadline)` with no operation after it | `schedule(at: deadline, key: buyer).expire(buyer:)`. `schedule` stages a reminder only when you call an operation on its result |
| `reject "room full"` | `reject(:room_full, "The room is full")` |
| `id` inside an actor | `actor_id`. An actor has no `id` method |
| `register_effect(:name) { \|context, arguments\| ... }` | `register_effect(:name) { \|arguments, context\| ... }`. The arguments come first |

[Reminders](reminders.md) and the [architecture guide](architecture.md) give
the full actor API.

## 7. Run the runtime process

A direct call, such as `TicketSale.ref("event-42").hold(buyer: "ada")`, runs in
the caller. It needs no worker. These features need the runtime process:

- Reminders from `schedule`.
- `async` calls.
- Effects from `emit` and their callbacks.
- Broadcasts to Action Cable.

Start it beside the web process:

```bash
bundle exec solid_objects start
```

Add it to the `Procfile`, the process manager, or the deployment
configuration. When it stops, pending work stays in SQL and runs after it
starts again. [Operations](operations.md#runtime) covers roles and shutdown.

## 8. Make external effects idempotent

Register an effect handler at boot. Use `context.id` as the provider
idempotency key:

```ruby
SolidObjects.register_effect(:charge_payment) do |arguments, context|
  Payments.charge(
    idempotency_key: context.id,
    payment_id: arguments.fetch("payment_id"),
    amount_cents: arguments.fetch("amount_cents")
  )
end
```

Stage it from the actor:

```ruby
emit :charge_payment, payment_id:, amount_cents:, on_success: :charged
```

The effect can run more than once after a crash. The `context.id` value is the
same each time. [Effect recovery](effect-recovery.md) explains how to retire
abandoned work.

## 9. Verify the implementation

Do these checks before you report that the work is complete:

1. Run `bin/rails solid_objects:doctor`. It must report no failures.
2. Write a test that includes `SolidObjects::TestHelper`. Send concurrent
   calls to one identity from several threads. Assert the final state, for
   example that only one hold succeeded.
3. Use `run_due_reminders(now:)` and `drain_solid_objects` to test delayed
   work without sleeps.
4. Start `bundle exec solid_objects start`, schedule a short reminder, and stop
   the process. Start it again after the deadline and confirm that the reminder
   ran.
5. Confirm that each effect handler deduplicates with `context.id`.
6. Confirm that production policies do not grant access to every caller.

[Host application tests](development.md#host-application-tests) describes the
test helper. The [clean-install quickstart](../examples/quickstart/README.md)
runs checks 2 and 4 against a new Rails application.

## 10. Troubleshooting

| Symptom | Cause and fix |
| --- | --- |
| `SolidObjects::Unauthorized` | A policy denied the call. Write the policy, and pass `authorization_context:` |
| A reminder or `async` call does not run | The runtime process is not running. Start `bundle exec solid_objects start` |
| `SolidObjects::SyncInsideTransaction` | The call ran inside an open transaction. Call the actor outside the transaction. In tests, include `SolidObjects::TestHelper` |
| `SolidObjects::SyncTimeout` | The call did not finish in time. The message is still durable. Use its `message_reference` to wait for the result |
| `SolidObjects::ApplicationWriteForbidden` | A handler wrote a model directly. Use `commit_action` or `emit` |
| `SolidObjects::Rejected` | The actor called `reject`. This is a business result, not a retry |
| `ArgumentError` from `ActiveSupport::JSON`, such as `unknown keyword: quirks_mode` | `json` 3.x with Active Support before 8.1.4. Upgrade Rails to 8.1.4 or newer, or pin `gem "json", "~> 2"` |

## 11. Guarantees to state correctly

When you explain Solid Objects to a user, state these limits:

- Delivery is at least once, not exactly once.
- Calls for one identity are ordered. Different identities run concurrently.
- There are no transactions across actor identities.
- Fencing stops a stale activation from a commit, but its code can continue to
  run.
- The gem is pre-1.0 and makes no production-ready claim.

The [correctness contract](correctness.md) is the source for each guarantee.
