# Reminders

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

## A reminder is one named alarm per actor

The uniqueness key is `(actor, reminder name)`. Scheduling a name that is
already armed **moves the existing alarm** rather than adding a second one. The
database enforces this with a unique index on `(instance_id, name)`.

This is the same model as Orleans reminders and Durable Objects alarms. It
makes a reminder safe to re-arm from a handler that may run more than once.
Without a key the name is the operation, so this is a data-loss bug:

```ruby
# Wrong. Every entry overwrites the previous entry's alarm.
def add(entry:)
  self.entries = entries + [ entry ]
  schedule(at: entry.fetch("wait_until")).deliver
end
```

Two entries leave one reminder. The earlier wake-up never happens, nothing
raises, and nothing is logged except a `solid_objects.reminder.replaced` event.

## An alarm per item, with `key:`

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
item's alarm and leaves the others alone, so a keyed reminder is as safe to
re-arm as an unkeyed one. The operation still decides which handler runs; the
key only decides which alarm is which.

A key must be non-empty, and the name it becomes must fit the 191-character
column, which is checked on the composed name rather than the key alone so a
long operation and a short key are caught too.

The key is separated from the operation by a colon, so an operation may not hold
one. Otherwise an unkeyed `deliver:item` and a `deliver` keyed `item` would be
one name, and the second would silently take the first one's alarm. A key may
hold colons of its own, because the operation before the first one cannot.

## One alarm for a whole queue

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
