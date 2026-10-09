# Run jobs in order for each customer in Rails

A Rails job queue does not keep one customer's job order when several workers run jobs or a job retries. You can serialize one queue, limit concurrency for each customer, or check a sequence number in the database. Solid Objects (the `solid_objects` gem) fits when each customer needs ordered commands, durable state, reminders, and recovery after a restart. Different customers still progress at the same time.

## Reproduce the problem

An account starts with a balance of 0 cents. The caller enqueues a deposit of 100 cents, then a withdrawal of 80 cents. If the withdrawal runs first, it fails because the balance is 0 cents.

```ruby
class Account < ApplicationRecord
  class InsufficientFunds < StandardError; end
  class OutOfSequence < StandardError; end

  def apply_entry!(kind:, amount_cents:)
    change = (kind == "deposit") ? amount_cents : -amount_cents
    raise InsufficientFunds, "balance #{balance_cents}, change #{change}" if balance_cents + change < 0

    update!(balance_cents: balance_cents + change)
  end

  def apply_entry_in_sequence!(sequence:, kind:, amount_cents:)
    with_lock do
      raise OutOfSequence, "expected #{next_sequence}, received #{sequence}" if sequence > next_sequence
      next if sequence < next_sequence

      apply_entry!(kind:, amount_cents:)
      update!(next_sequence: next_sequence + 1)
    end
  end
end
```

`apply_entry!` adds a deposit or subtracts a withdrawal, then updates the balance. It raises `Account::InsufficientFunds` if the result is below 0. The later section uses `apply_entry_in_sequence!` to fix the order.

The plain job calls `apply_entry!`:

```ruby
class ApplyEntryUnorderedJob < ApplicationJob
  def perform(account_id:, kind:, amount_cents:)
    Account.find(account_id).apply_entry!(kind:, amount_cents:)
  end
end
```

Order breaks for these reasons:

- Several workers take jobs from the queue at the same time.
- A job that fails and retries runs after newer jobs.
- A job that waits for a lock can finish after a later job.

The test performs the withdrawal job before the deposit job. The withdrawal raises `Account::InsufficientFunds`. See [the ordered jobs tests](../../test/guides/ordered_jobs_test.rb).

## Native options

| Option | What it gives | What it costs |
| --- | --- | --- |
| One serial queue (a Sidekiq capsule with concurrency 1) | One job at a time for the queues of that capsule, in each Sidekiq process | Every customer in that queue waits for every other customer. Sidekiq sets concurrency for each process. One order across the deployment needs one process for that queue. |
| Solid Queue `limits_concurrency` with the customer as the key | At most `to` jobs at a time for each key (`to` is 1 by default) | Solid Queue gives “no guarantee about the order of execution, only about jobs being performed at the same time”. |
| A sequence number and a row lock | Order for each customer | The code that enqueues must assign the sequence numbers. An early job raises an exception and retries. A job that fails on each attempt holds back the later jobs. |

Sidekiq supports capsules from Sidekiq 7.0. A capsule can provide serial execution for a queue. The wiki says, “Do not declare a capsule for each queue.” Concurrency applies to each process. By default, one Sidekiq process creates five threads ([checked October 9, 2026](https://github.com/sidekiq/sidekiq/wiki/Advanced-Options#capsules)).

```ruby
Sidekiq.configure_server do |config|
  config.capsule("unsafe") do |cap|
    cap.concurrency = 1
    cap.queues = %w[queue_a queue_b] # strict priority
    # cap.queues = %w[queue_a,3 queue_b,1] # weighted
  end
end
```

Solid Queue accepts `key`, `to`, `duration`, and `on_conflict` for concurrency controls. It requires `key` and sets `to` to 1 by default. A blocked job stays blocked until another job finishes or the duration expires. These controls do not guarantee execution order. Solid Queue does not use queue order to unblock jobs ([checked October 9, 2026](https://github.com/rails/solid_queue#concurrency-controls)).

If one serial queue is fast enough for your volume, it is the simplest choice. If order does not matter, `limits_concurrency` is enough for one job at a time per customer.

## Keep order with a sequence number

`apply_entry_in_sequence!` locks the account row and checks the sequence number:

- If the entry arrives early, the method raises `Account::OutOfSequence`.
- If the account already applied that sequence, the method skips the entry.
- If the entry has the expected sequence, the method applies it and moves `next_sequence` forward.

The job calls this method:

```ruby
class ApplyEntryJob < ApplicationJob
  retry_on Account::OutOfSequence, wait: 5.seconds, attempts: 20

  def perform(account_id:, sequence:, kind:, amount_cents:)
    Account.find(account_id).apply_entry_in_sequence!(sequence:, kind:, amount_cents:)
  end
end
```

`retry_on` re-enqueues the job when its entry arrives early.

The tests show these results:

- Sequence 2 first raises `Account::OutOfSequence`.
- Sequences 1 and 2 then apply in order.
- A repeated sequence 1 causes no change.
- The job enqueues a retry when its entry arrives early.

This approach has two costs:

- The caller allocates the sequence numbers.
- A broken entry blocks the account until someone fixes it.

## One actor for each account

There is one `LedgerAccount` actor for each account ID.

```ruby
class LedgerAccount < SolidObjects::Actor
  RECENT_ENTRY_LIMIT = 100

  attribute :balance_cents, default: 0
  attribute :recent_entry_ids, default: -> { [] }
  attribute :statement_balance_cents, default: nil

  def apply(entry_id:, kind:, amount_cents:)
    return balance_cents if recent_entry_ids.include?(entry_id)

    change = (kind == "deposit") ? amount_cents : -amount_cents
    reject(:insufficient_funds, "The balance is too low for this withdrawal") if balance_cents + change < 0

    self.balance_cents += change
    self.recent_entry_ids = (recent_entry_ids + [ entry_id ]).last(RECENT_ENTRY_LIMIT)
    schedule(at: 1.day.from_now, key: "daily").close_statement
    balance_cents
  end

  def close_statement
    self.statement_balance_cents = balance_cents
  end
end
```

The caller sends each entry with `async` and an idempotency key:

```ruby
LedgerAccount.ref(account.id.to_s)
  .async(idempotency_key: entry.id.to_s, authorization_context: Current.user)
  .apply(entry_id: entry.id.to_s, kind: entry.kind, amount_cents: entry.amount_cents)
```

The runtime stores the message in SQL before `async` returns. Messages for one actor run one at a time, in the order the runtime receives them. Different accounts run at the same time on different workers.

The actor treats a business rejection and an exception differently:

- `reject` ends an entry with a business result, such as `insufficient_funds`. The runtime does not retry the rejection. The next entry runs.
- An exception causes the runtime to retry that message. The message holds back later messages for that account until it succeeds or moves to dead letters.

A repeated enqueue with the same idempotency key creates one message. A repeated delivery runs the method again. `apply` checks `recent_entry_ids` and returns without a change if the list contains the entry ID.

`schedule(at: 1.day.from_now, key: "daily")` keeps one statement reminder for each account. Each new entry moves the reminder. The database stores the reminder, and the reminder runs after a restart.

You do not assign sequence numbers. The actor mailbox gives the order.

## What the tests prove

- The tests enqueue five entries for two accounts in one mixed order. Two workers process them. Each account applies its own entries in enqueue order. The balances are 25 and 0 cents.
- The actor rejects a withdrawal that is too large. The deposit after it applies.
- Two enqueues share the same idempotency key. One more direct delivery repeats the entry. The account applies the entry once.
- The statement reminder runs after the test resets the caller process.

## Choose

- Independent jobs: use a normal queue.
- One job at a time for each customer, order not important: use `limits_concurrency`.
- Low volume and one order for everything: use one serial queue.
- Order for each customer plus durable state, reminders, and recovery: use an actor for each customer.

## Run it in production

- Run `bundle exec solid_objects start`. Async messages and reminders run only while this process runs. The database keeps unfinished work in SQL while the process does not run.
- The generated policies deny every call. Write a policy. Pass `authorization_context:` to `async`. See [authorization policies](../authorization.md).
- A message that fails on every attempt moves to dead letters after five attempts by default. Later messages then run. An operator can retry a dead letter. See [dead letters, retry, and redrive](../operations.md#dead-letters-retry-and-redrive).
- The actor remembers the idempotency keys of its last finished turns. It retains 64 keys by default. See [retention and backups](../operations.md#retention-and-backups).

## Limits

- Solid Objects requires Ruby 3.3 or newer and Rails 7.1 or newer.
- Delivery is at least once. Each operation must be safe to run again.
- The gem provides no transactions across actors. A transfer between two accounts needs its own design, for example one SQL transaction on normal tables.
- One busy account runs its entries one at a time.
- The gem is pre-1.0 and makes no production-ready claim.

## More information

- [The example files](../../examples/guides/ordered_jobs/ledger_account.rb)
- [The tests for this guide](../../test/guides/ordered_jobs_test.rb)
- [Correctness and delivery semantics](../correctness.md)
- [Reminders](../reminders.md)
- [Prevent race conditions in Rails](race-conditions.md)
