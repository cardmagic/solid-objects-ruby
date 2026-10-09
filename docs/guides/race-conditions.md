# Prevent race conditions in Rails

Most Rails races need a database constraint, an atomic update, a row lock, or optimistic locking. A virtual actor helps when one resource has a lifecycle. Requests, jobs, and timers change it, and these changes must occur in order and survive a restart. Solid Objects (the `solid_objects` gem) provides that actor on the SQL database that the application already uses.

## Choose the right tool

| Problem | Start with | When Solid Objects becomes relevant |
| --- | --- | --- |
| Duplicate records | A unique index in the database | A larger entity lifecycle also needs ordered durable work |
| Concurrent increments or an inventory decrement | An atomic SQL update or a short transaction | The operation is part of holds, expiry, retries, and later commands |
| Two people edit from an old form | Optimistic locking or a revision check | The entity also needs coordination across jobs and requests |
| Several database changes in one request | A transaction and the correct row locks | Work must continue after that transaction and survive failures |
| Commands that arrive through requests, jobs, and reminders | An explicit coordination design | This is the main use for an actor. The rest of this guide shows it |

## Use the Rails tools first

### Unique index

A Rails uniqueness validation does not create a uniqueness constraint in the database. Two database connections can create two records with the same value. The validation alone does not stop duplicates.

Create a unique index on the column in the database. See the [Rails Guides, section 2.10: uniqueness](https://guides.rubyonrails.org/active_record_validations.html) (checked October 9, 2026).

### Pessimistic locking

Rails supports row-level locks through `SELECT … FOR UPDATE`. The `with_lock` method wraps the block in a transaction. It reloads the object with a lock before it runs the block.

```ruby
event.with_lock do
  event.update!(seats_available: event.seats_available - 1) if event.seats_available.positive?
end
```

See the [Rails pessimistic locking reference](https://api.rubyonrails.org/classes/ActiveRecord/Locking/Pessimistic.html) (checked October 9, 2026).

### Optimistic locking

Active Record uses an integer `lock_version` column for optimistic locking. Each update increments `lock_version`. A stale save raises `ActiveRecord::StaleObjectError`.

The Rails documentation recommends a hidden `lock_version` field in the form. That field lets the check work across web requests. See the [Rails optimistic locking reference](https://api.rubyonrails.org/classes/ActiveRecord/Locking/Optimistic.html) (checked October 9, 2026).

## A worked example: ticket holds

An event has a fixed number of seats. Buyers hold seats before they pay.

### Step 1: Reproduce the race

Two requests load the same event. Each request sees one free seat. Each request writes the value it computed. Both holds succeed, although the event has only one seat.

```ruby
class Event < ApplicationRecord
  def hold_seat_unsafely
    return false if seats_available.zero?

    update!(seats_available: seats_available - 1)
    true
  end

  def hold_seat
    self.class.where(id:).where("seats_available > 0")
      .update_all("seats_available = seats_available - 1") == 1
  end
end
```

The `hold_seat_unsafely` method shows the race. The `hold_seat` method provides the fix in step 2.

The test reproduces the race without timed delays. It loads two copies of the event, then holds a seat with each copy. Both holds succeed. See [the race condition tests](../../test/guides/race_conditions_test.rb).

### Step 2: Fix it with one SQL statement

The `hold_seat` method lets the database decide. The `UPDATE` changes the row only when a seat is free. The method returns `true` only when the statement changes one row.

In the test, ten requests load the event before they wait at a barrier. Then they try to hold seats at the same time. The event has three seats. Exactly three holds succeed.

Stop here if a hold never expires and no later operation changes it. An atomic SQL update is the correct fix for a simple counter.

### Step 3: The lifecycle needs more than a lock

A real ticket hold has more requirements:

- A hold expires after 10 minutes if the buyer does not pay.
- The buyer confirms the hold after payment.
- A client retries a hold or a confirmation after a timeout.
- The process restarts before the holds expire.
- An expiry that arrives late must not release a newer hold.

A pure SQL design needs a holds table, an expiry job, retry keys, and recovery after a restart. Every path must take the same lock in the same order.

### Step 4: One actor owns the event

There is one `EventTickets` actor for each event ID. Calls for one actor run one at a time, in order. Different events can run at the same time.

```ruby
class EventTickets < SolidObjects::Actor
  HOLD_DURATION = 10.minutes

  attribute :opened, default: false
  attribute :seats_available, default: 0
  attribute :holds, default: -> { {} }
  attribute :sold, default: -> { [] }
  attribute :title, default: ""
  attribute :revision, default: 0

  def open_sales(seats:)
    return seats_available if opened

    self.opened = true
    self.seats_available = seats
  end

  def hold(buyer:, hold_id:)
    release_expired_holds
    return { held: true, hold_id: } if holds.dig(buyer, "hold_id") == hold_id
    return { held: false, reason: "already_held" } if holds.key?(buyer)
    return { held: false, reason: "sold_out" } if seats_available.zero?

    deadline = HOLD_DURATION.from_now
    self.seats_available -= 1
    self.holds = holds.merge(buyer => { "hold_id" => hold_id, "expires_at" => deadline.to_i })
    schedule(at: deadline, key: buyer).expire(buyer:, hold_id:, expires_at: deadline.to_i)
    { held: true, hold_id: }
  end

  def confirm(buyer:, hold_id:)
    return { confirmed: true } if sold.include?(hold_id)

    release_expired_holds
    reject(:no_hold, "The hold expired or does not exist") unless holds.dig(buyer, "hold_id") == hold_id

    self.holds = holds.except(buyer)
    self.sold = sold + [ hold_id ]
    unschedule(:expire, key: buyer)
    { confirmed: true }
  end

  def expire(buyer:, hold_id:, expires_at:)
    return seats_available unless holds[buyer] == { "hold_id" => hold_id, "expires_at" => expires_at }

    self.holds = holds.except(buyer)
    self.seats_available += 1
  end

  def update_details(title:, base_revision:)
    reject(:stale_revision, "Reload the event and try again") unless base_revision == revision

    self.title = title
    self.revision += 1
  end

  private

  def release_expired_holds
    expired_buyers = holds.select { |_buyer, hold| hold.fetch("expires_at") <= Time.current.to_i }.keys
    self.holds = holds.except(*expired_buyers)
    self.seats_available += expired_buyers.length
  end
end
```

The actor owns the lifecycle:

- The `hold` method takes a seat and stores the deadline, `expires_at`, beside `hold_id` in the hold. It schedules a reminder with `schedule(at:, key: buyer)`. The database stores the reminder.
- The `hold` and `confirm` methods first call the private `release_expired_holds` method. This method removes each hold at or past its deadline and returns its seat.
- The stored deadline is the rule. After the deadline, the actor rejects confirmation, even before the reminder runs. A stopped or slow runtime process does not extend a hold.
- The `confirm` method moves the hold to `sold` and cancels the reminder with `unschedule`.
- The reminder passes the stored deadline: `expire(buyer:, hold_id:, expires_at:)`. The `expire` method releases the seat only when both the hold ID and the deadline still match the stored hold. An expiry for an old hold does nothing. An expiry that the scheduler queued before a retry created a fresh hold with the same hold ID also does nothing. The reminder cleans up the hold if no other call releases it first.
- A retry of `hold` with the same IDs returns the same result while that hold exists. A retry of `confirm` with the same IDs returns the same result after the confirmation. These retries make no further changes.
- The `reject` method ends the call with a business result. The caller receives `SolidObjects::Rejected`. The runtime does not retry a rejection.

Call the actor from a controller:

```ruby
result = EventTickets.ref(event.id.to_s).hold(
  buyer: Current.user.id.to_s,
  hold_id: params.require(:hold_id),
  authorization_context: Current.user
)
```

### Step 5: What the tests prove

- **Concurrent holds:** Ten concurrent hold calls against three seats produce exactly three successful holds.
- **Restart before expiry:** The test resets the caller process. It runs due reminders at 9 minutes and at 11 minutes. Nothing runs at 9 minutes. The expiry runs at 11 minutes, and the seat returns.
- **Stale expiry:** The first hold expires. The buyer holds again with a new hold ID. The old expiry arrives again, and the new hold stays.
- **Retries:** Two identical holds and two identical confirmations sell one seat.
- **Confirmation after expiry:** The actor rejects the confirmation with the code `no_hold`.
- **Past the deadline, before the reminder runs:** The test moves the clock 11 minutes forward and delivers no reminder. The actor rejects the confirmation with `no_hold`, and another buyer holds the seat.
- **A retry with the same hold ID after the deadline:** the test moves the clock 11 minutes forward. The retry creates a fresh hold, and then the old expiry arrives. The fresh hold stays.
- **Stale form:** The actor rejects the update with the code `stale_revision`. The next section explains this check.

## Serial execution does not stop a stale form

An actor runs one call at a time. A stale form can still replace newer data. If two people load revision 0 and both submit, the second submit still runs after the first.

Use a domain operation or a revision check. The example's `update_details` method rejects a call when `base_revision` differs from the current revision.

## Run it in production

### Authorization

The install generator creates policies that deny every call. Write a policy that checks the caller and the actor type. For example, the policy can check a signed-in user.

Pass `authorization_context:` on each call. An actor ID is not a permission. See [authorization policies](../authorization.md).

### The runtime process

Reminders run only while `bundle exec solid_objects start` runs. SQL keeps the unfinished work while the runtime process is down. The runtime process runs an overdue reminder after it starts again. See [reminders](../reminders.md).

### Retention cost

Every actor call creates a durable message row. The default `message_retention` keeps terminal message history for 30 days. Actor state stays until you destroy the actor or configure `instance_retention_by_actor_type`.

In this example, the event capacity bounds the state. See [retention and backups](../operations.md#retention-and-backups).

### External effects

Do not call a payment provider inside the actor. Use `emit` and an effect handler. Pass `context.id` to the provider as the idempotency key.

Delivery is at least once, so an effect can run more than once. See [effect idempotency](../agents.md#8-make-external-effects-idempotent).

## Limits

- Solid Objects requires Ruby 3.3 or newer and Rails 7.1 or newer.
- Delivery is at least once, not exactly once. Write each operation so that it can run again.
- There are no transactions across actors. A change that must touch two events atomically needs one SQL transaction on normal tables.
- One busy event runs its calls one at a time. Many events can run at the same time.
- The gem is pre-1.0 and makes no production-ready claim.

## More information

- [The example files](../../examples/guides/race_conditions/event_tickets.rb)
- [The tests for this guide](../../test/guides/race_conditions_test.rb)
- [Correctness and delivery semantics](../correctness.md)
- [Virtual actors in Ruby on Rails](../virtual-actors.md)
- [Expiring reservations](expiring-reservations.md)
- [Ordered jobs for each customer](ordered-jobs.md)
