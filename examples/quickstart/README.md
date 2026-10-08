# Rails quickstart

This recipe puts Solid Objects into a new Rails application. It uses SQLite,
one actor, and one reminder. A person or a coding agent can follow it on a
clean machine.

The recipe shows three behaviors:

- Concurrent calls to one actor identity commit one at a time.
- The actor state stays in the application's SQL database.
- A reminder that is due while the runtime is stopped runs after the runtime
  starts again.

`bundle exec rake quickstart` runs the same recipe against a gem that it builds
from this repository. See [What the check proves](#what-the-check-proves).

## Requirements

- Ruby 3.3 or newer
- Rails 7.1 or newer
- SQLite 3.35 or newer

Solid Objects needs Rails. It is not a Ruby library that you can use without
Rails.

## 1. Create the application

```bash
rails new ticket_demo
cd ticket_demo
```

Active Support 8.1.3.1 and the `json` gem 3.0.2 do not work together:
`ActiveSupport::JSON.decode` raises an `ArgumentError`, and Solid Objects
decodes its JSON columns with it. Active Support 8.1.4 does not have this
problem. If `Gemfile.lock` shows both of the incompatible versions, read
[Installing and upgrading](../../docs/operations.md#installing-and-upgrading)
before you continue.

## 2. Install Solid Objects

```bash
bundle add solid_objects
bin/rails generate solid_objects:install
bin/rails db:migrate
bin/rails solid_objects:doctor
```

The generator writes `config/initializers/solid_objects.rb` and copies the
migrations. The migrations add the Solid Objects tables to the application's
existing database.

The generated initializer denies every operation. The doctor reports this
condition as a warning:

```text
WARN authorization: all five policies denied a neutral context; review the generated initializer before use
```

On SQLite, the doctor also warns that the runtime polls for work. SQLite has no
notification channel, so a commit in one process cannot wake another process.
The runtime finds the work at the next poll.

## 3. Grant only what the local demo needs

The demo calls the actor and reads its state from a console. It needs the
message policy and the query policy. In
`config/initializers/solid_objects.rb`, change these two lines:

```ruby
configuration.authorize_message = ->(**) { false }
configuration.authorize_query = ->(**) { false }
```

to:

```ruby
configuration.authorize_message = ->(**) { true }
configuration.authorize_query = ->(**) { true }
```

Do not change `authorize_destroy`, `authorize_subscription`,
`authorize_administration`, or `authorize_transmission`. They stay denied.

These two grants are for a local demo only. They let any caller send any
message to any actor and read any actor state. A production policy must bind
the actor type, the actor ID, and the operation to the authenticated user or
tenant. Pass that principal at each call site:

```ruby
TicketSale.ref(event.id.to_s).hold(
  buyer: Current.user.id.to_s,
  authorization_context: Current.user
)
```

Then check it in the policy. `can_buy_tickets_for?` is an example method of
your application:

```ruby
configuration.authorize_message = lambda do |actor_type:, actor_id:, operation:, authorization_context:, **|
  user = authorization_context

  actor_type == "TicketSale" &&
    operation == "hold" &&
    user.present? &&
    user.can_buy_tickets_for?(actor_id)
end
```

The reminder that calls `expire` comes from a committed runtime row. It does
not go through `authorize_message` again.

[Authorization](../../docs/authorization.md) describes every policy and its
arguments.

## 4. Add the actor

Put this class in `app/actors/ticket_sale.rb`:

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

One actor owns the state of one event. The event ID is the actor ID. A
successful `hold` stores the hold and a keyed ten-minute reminder in the same
commit as the state change. The `expire` method checks that the hold still
exists, so a second delivery of the same reminder does not add a ticket.

## 5. Start the runtime

Direct calls do not need a runtime process. The caller runs the turn. Reminders,
`async` messages, effects, and broadcasts need the runtime:

```bash
bundle exec solid_objects start
```

When the runtime is stopped, due work stays in the database. Nothing else runs
it. Run the runtime as a separate process in every environment that uses
reminders.

## 6. Hold a ticket

Open a second terminal:

```bash
bin/rails console
```

```ruby
sale = TicketSale.ref("concert")
sale.hold(buyer: "ada")
sale.hold(buyer: "grace")
sale.available
```

The first call returns `{"held" => true, "available" => 0}`. The second call
returns `{"held" => false, "available" => 0}`. A synchronous call returns the
committed result as JSON data, so the keys are strings.

## 7. Restart the runtime before the reminder runs

1. Stop the runtime with Ctrl-C before ten minutes pass.
2. Wait until the ten minutes pass.
3. In the console, read `sale.available`. The value is still `0`, because no
   process ran the reminder.
4. Start the runtime again with `bundle exec solid_objects start`.
5. Read `sale.available` again. The runtime runs the due reminder, and the value
   is `1`.

## Guarantees in this demo

- Calls to one actor ID commit in order, one at a time. Different actor IDs can
  run concurrently.
- Delivery is at least once. A handler can run again after a crash. The guard
  in `expire` makes a second delivery harmless.
- Each turn commits the state and the reminder together, or commits neither.
- The demo has no external effects. An external effect, such as an email or a
  payment, can repeat. It must use the stable effect ID or another durable
  idempotency key.
- One actor ID is a sequential bottleneck. Do not use one actor ID for the
  whole application.

[Correctness](../../docs/correctness.md) gives the full contract.

## What the check proves

`bundle exec rake quickstart` runs [`smoke.rb`](smoke.rb). The check does these
steps:

1. It confirms that this recipe and every `TicketSale` sample in the README and
   in `docs/` show the exact actor in
   [`app/actors/ticket_sale.rb`](app/actors/ticket_sale.rb).
2. It builds the gem with `gem build`.
3. It runs `rails new --minimal` with SQLite in a temporary directory and runs
   `bundle install` into a temporary bundle path.
4. It copies the built gem into `vendor/cache`, adds
   `gem "solid_objects", "= <version>"` to the `Gemfile`, and runs
   `bundle install --local`. The application cannot get the gem from the
   repository or from rubygems.org.
5. It confirms which gem the application loads:
   - the `Gemfile` has no `path:` option for `solid_objects`;
   - the `Gemfile.lock` checksum is the checksum of the built gem;
   - the loaded gem files are in the temporary bundle path, not in the
     repository;
   - the installed gem file has the checksum of the built gem.
6. It runs the install generator, the migrations, and the doctor. Then it
   writes the actor and the two demo grants. It confirms that the other
   policies stay denied.
7. It starts `bundle exec solid_objects start`. Eight separate `bin/rails runner`
   processes wait at a barrier and then hold the same event at the same time.
   The check confirms that exactly one buyer holds the only ticket and that the
   durable state agrees.
8. It stops the runtime. One more process places a hold for a second event. That
   process shifts its own clock back with `travel_to`, so the ten-minute
   reminder is due eight seconds later. The reminder scheduler compares due
   times with the database clock, so the runtime does not need a shifted
   clock.
9. It waits until the reminder is past due and confirms that the hold is still
   there while no runtime runs. Then it starts the runtime again and confirms
   that the reminder released the hold exactly once.
10. It stops every child process and removes the temporary directory, also
    when a step fails.

The check needs network access for `rails new` and `bundle install`. It takes
one to three minutes. The `quickstart` CI job runs it on every push.
