# Expiring reservations in Rails

A reservation holds stock for a short time, until the buyer confirms it or the hold expires. The stock must never go below zero. A retry must not take stock twice. A late expiry must not cancel a newer state. Solid Objects (the gem solid_objects) puts the stock and its holds in one actor, with durable reminders for the deadlines.

## Put the stock under the right identity

An actor for each reservation cannot prevent an oversold show. Two reservations can take the same stock. Two reservation actors are two identities. They run at the same time, and neither actor sees the other actor's hold.

Put the stock and all of its holds in the actor that owns the stock. This guide uses one actor for each show.

## The plain SQL design

- Store each hold in a table with its seats and an `expires_at` time.
- Count free seats as the capacity minus confirmed seats minus holds whose `expires_at` is still in the future.
- Insert a hold inside a transaction that locks the show row. Two holds cannot then both see the last seat.
- This design needs no timer. An old hold no longer counts when its time passes.

This design is not enough when an action must occur at the deadline. You need a timer for these actions:

- Release a payment authorization.
- Tell the buyer that the hold expired.
- Update state that other code reads without the clock.
- Start the next step of a workflow.

The timer, a confirmation, and a client retry can all touch the same hold. Each path must take the same lock. Each path must handle a duplicate or late delivery.

## The actor

```ruby
class SeatInventory < SolidObjects::Actor
  HOLD_DURATION = 15.minutes
  EXTENSION = 5.minutes
  MAX_EXTENSIONS = 2

  attribute :capacity, default: 0
  attribute :holds, default: -> { {} }
  attribute :confirmed, default: -> { {} }

  query :seats_left do
    seats_available
  end

  def open_show(capacity:)
    self.capacity = capacity if self.capacity.zero?
    seats_available
  end

  def hold(hold_id:, buyer:, seats:)
    reject(:invalid_seats, "Hold at least one seat") unless seats.is_a?(Integer) && seats.positive?
    return hold_result(hold_id) if active_hold?(hold_id)
    return { status: "confirmed" } if confirmed.key?(hold_id)
    reject(:not_enough_seats, "Only #{seats_available} seats are left") if seats > seats_available

    deadline = HOLD_DURATION.from_now
    self.holds = holds.merge(
      hold_id => { "buyer" => buyer, "seats" => seats, "expires_at" => deadline.to_i, "extensions" => 0 }
    )
    schedule(at: deadline, key: hold_id).expire(hold_id:, expires_at: deadline.to_i)
    hold_result(hold_id)
  end

  def extend_hold(hold_id:)
    reject(:no_hold, "The hold expired or does not exist") unless active_hold?(hold_id)

    hold = holds.fetch(hold_id)
    reject(:extension_limit, "The hold cannot be extended again") if hold.fetch("extensions") >= MAX_EXTENSIONS

    deadline = Time.at(hold.fetch("expires_at")) + EXTENSION
    self.holds = holds.merge(
      hold_id => hold.merge("expires_at" => deadline.to_i, "extensions" => hold.fetch("extensions") + 1)
    )
    schedule(at: deadline, key: hold_id).expire(hold_id:, expires_at: deadline.to_i)
    hold_result(hold_id)
  end

  def confirm(hold_id:)
    return { status: "confirmed" } if confirmed.key?(hold_id)
    reject(:no_hold, "The hold expired or does not exist") unless active_hold?(hold_id)

    hold = holds.fetch(hold_id)
    self.holds = holds.except(hold_id)
    self.confirmed = confirmed.merge(hold_id => hold.fetch("seats"))
    unschedule(:expire, key: hold_id)
    { status: "confirmed" }
  end

  def expire(hold_id:, expires_at:)
    return seats_available unless holds.dig(hold_id, "expires_at") == expires_at

    self.holds = holds.except(hold_id)
    seats_available
  end

  private

  def active_hold?(hold_id)
    holds.key?(hold_id) && holds.dig(hold_id, "expires_at") > Time.current.to_i
  end

  def seats_available
    held_seats = holds.each_key.select { |hold_id| active_hold?(hold_id) }.sum { |hold_id| holds.dig(hold_id, "seats") }
    capacity - held_seats - confirmed.values.sum
  end

  def hold_result(hold_id)
    { status: "held", expires_at: holds.dig(hold_id, "expires_at") }
  end
end
```

- `open_show` sets the capacity once.
- `hold` takes seats and records a deadline 15 minutes from now. It schedules one reminder with the hold ID as its key. A retry with the same hold ID returns the same hold and takes no more seats. When too few seats remain, `hold` rejects the request with the code `not_enough_seats`. `hold` rejects a seat count that is not a positive integer with the code `invalid_seats`. Without this check, a hold for -5 seats adds seats to the show.
- `extend_hold` adds 5 minutes, at most two times. It schedules the reminder again with the same key, which moves the alarm. It rejects a third extension with the code `extension_limit`. It accepts only an active hold: a hold whose stored deadline is still in the future. After the deadline, it rejects the request with the code `no_hold`, even before the expiry reminder runs. A stopped or slow runtime process does not extend a hold.
- `confirm` moves the hold to `confirmed` and cancels the reminder with `unschedule`. A confirmation retry returns the same result. `confirm` accepts only an active hold whose stored deadline is still in the future. After the deadline, it rejects the request with the code `no_hold`, even before the expiry reminder runs.
- The stored deadline is the rule. `expire` removes the old hold from the state only if the deadline in the message still matches the hold. After an extension, an expiry for the old deadline does nothing.
- `seats_left` is a query. A query runs as an ordered read in the actor mailbox. `reference.snapshot` reads the committed state without a message row. A hold past its deadline no longer counts against the seats. `seats_left` and new holds see the seats again at the deadline.

Active holds and confirmed seats are bounded by the show capacity. An expired hold stays in the state until its reminder runs.

## Deadlines that survive a restart

Use durable reminders for persistent timers in Rails.

`schedule(at:, key:)` stores the reminder in the database in the same commit as the state change. A reminder is one named alarm for each actor and key. A new schedule with the same key moves the alarm. `unschedule(:expire, key: hold_id)` cancels it. The deadline check in `confirm` and `extend_hold` does not wait for the reminder.

Reminders run only while `bundle exec solid_objects start` runs. A reminder that falls due while the process is stopped runs after the process starts again. A reminder runs an ordinary actor message, so it runs in order with the other calls for that show.

Delivery is at least once, so `expire` checks the deadline before it changes anything. See [reminders](../reminders.md).

## What the tests prove

- Eight concurrent holds request one seat each against a capacity of five. Five succeed, and three receive the rejection code `not_enough_seats`.
- A hold retry takes its seats once.
- An extension moves the reminder to the new deadline. At 16 minutes, nothing runs. At 21 minutes, the expiry runs and the seats return.
- An expiry for the old deadline changes nothing after an extension.
- The actor rejects a third extension with the code `extension_limit`.
- A confirmation retry returns the same result. The hold moves to `confirmed` once, and the confirmation cancels the reminder.
- A confirmation after expiry receives the rejection code `no_hold`.
- Past the deadline, before the reminder runs: the test moves the clock 16 minutes forward and delivers no reminder. The actor rejects the confirmation and the extension with `no_hold`, and both seats are free.
- A hold for zero seats or for -5 seats is rejected with `invalid_seats`, and the free seats do not change.
- A hold that falls due while the runtime is stopped expires after a restart.

See [the tests for this guide](../../test/guides/expiring_reservations_test.rb).

## Payment and other side effects

Do not call a payment provider inside the actor. An effect can run more than once.

- Stage the payment with `emit`.
- Pass `context.id` to the provider as the idempotency key.
- Confirm the hold in the actor after the payment succeeds.

See [the transactional outbox guide](transactional-outbox.md).

## Run it in production

- Authorization: the generated policies deny every call. Write a policy. Pass `authorization_context:` on each call. See [authorization policies](../authorization.md).
- Run `bundle exec solid_objects start` beside the web process.
- Every actor call creates a durable message row. Solid Objects keeps terminal message history for 30 days by default. See [retention and backups](../operations.md#retention-and-backups).

## Limits

- Solid Objects requires Ruby 3.3 or newer and Rails 7.1 or newer.
- Delivery is at least once. Each operation must be safe to run again.
- There are no transactions across actors. A reservation that spans two shows needs its own design.
- One busy show runs its calls one at a time. Many shows run at the same time.
- The gem is pre-1.0 and makes no production-ready claim.

## More information

- [The example file](../../examples/guides/expiring_reservations/seat_inventory.rb)
- [The tests for this guide](../../test/guides/expiring_reservations_test.rb)
- [Prevent race conditions in Rails](race-conditions.md)
- [Correctness and delivery semantics](../correctness.md)
- [Virtual actors in Ruby on Rails](../virtual-actors.md)
