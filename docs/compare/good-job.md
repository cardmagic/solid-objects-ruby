# GoodJob concurrency controls and Solid Objects: ordered work for each customer in Rails

GoodJob is a PostgreSQL-backed Active Job backend. Its concurrency controls limit how many jobs with the same label run at a time, but they do not guarantee first-in, first-out order. Solid Objects (the `solid_objects` gem) gives each customer one actor with an ordered mailbox, its own durable state, and reminders, in the SQL database that the app already uses. Use GoodJob when jobs are independent or order does not matter. Use Solid Objects when the updates for one customer must apply in the order they arrived, and each customer has state that a retry must keep.

Solid Objects is an independent project. It is not affiliated with GoodJob or Rails.

## The short answer

| Question | GoodJob with a concurrency rule | Solid Objects |
| --- | --- | --- |
| What runs one at a time | Jobs with the same label, with `perform_limit: 1` | Calls to the same actor ID |
| How a second job waits | It raises `ConcurrencyExceededError` and retries with backoff. With the `good_job_concurrency_claims` table, the longest-waiting job is rescheduled to run at once when the key becomes free | It waits in the actor mailbox |
| Order for each key | Not guaranteed. The README says "First-in-first-out job execution order is not strictly preserved" | Kept. Messages for one actor run in the order that the runtime stores them |
| State for each key | Your own table | Actor attributes, stored by the gem |
| Later work | `set(wait:)`, `retry_on`, cron, and batches | Reminders with `schedule(at:, key:)` |
| A worker stops in the middle of a run | GoodJob retries the job automatically | The lease expires and the turn runs again. Delivery is at least once |
| Process to run | `bundle exec good_job start`, or async mode in the web process | `bundle exec solid_objects start` |
| Databases | PostgreSQL only | SQLite, PostgreSQL, MySQL |
| Licence | MIT | MIT |

The GoodJob facts come from the [GoodJob 4.22.1 README](https://github.com/bensheldon/good_job/blob/v4.22.1/README.md) (checked October 15, 2026).

## Choose GoodJob when

- The jobs are independent.
- You need a limit on jobs at a time for each label, and order does not matter.
- The job keeps no state of its own between runs.
- You need cron for the whole app, batches, or a job dashboard. Solid Objects has no batches and no app-wide cron. Its reminders can repeat with `every:` for one actor, and its dashboard shows actors, not jobs.

## Choose Solid Objects when

- The updates for one customer must apply in the order they arrived.
- Each customer has state that the updates read and change, for example the last synced version.
- A failed update must wait with backoff, keep its place in the order, and survive a restart.
- You run MySQL or SQLite, or you want the same model on PostgreSQL.

## The same terms in each

| GoodJob and Active Job | Solid Objects |
| --- | --- |
| The `label:` of `good_job_concurrency_rule` | The actor ID |
| A job class with `perform` | An actor method (an operation) |
| `perform_later` | `ref(id).async.method(...)` |
| `retry_on` with `wait:` | Effect retries (`max_attempts`, `retry_delay`), then `on_failure` and a reminder |
| `set(wait:)` | `ref(id).async(available_at:)`, or `schedule(at:, key:)` inside the actor |
| A row in your own table | `attribute` on the actor |
| Cron and batches | No equivalent. Keep them in GoodJob |

GoodJob 4.21.0 deprecated rules with both `label:` and `key:`. GoodJob 4.22.0 deprecated `good_job_control_concurrency_with` and rules with `key:` alone. The README says that they "will raise in GoodJob v5". The current form is `good_job_concurrency_rule` with `label:`.

## One billing sync for each customer

The task: a Rails 8 app on PostgreSQL syncs each customer's subscription with an external billing API. The updates for one customer must run one at a time and in the order they arrived. Different customers run in parallel. Each customer has state: the last synced version, a retry count, and the next retry time. A failed sync must retry with backoff and survive a restart.

### With GoodJob

This job follows the GoodJob and Active Job documentation. It was not run by the Solid Objects test suite.

```ruby
class SyncSubscriptionJob < ApplicationJob
  include GoodJob::ActiveJobExtensions::Concurrency

  BACKOFF = ->(executions) { (executions**4) + 2 }

  good_job_concurrency_rule(label: -> { "customer-#{arguments.first}" }, apply_label: true, perform_limit: 1)
  retry_on BillingApi::TransientError, wait: BACKOFF, attempts: 10

  def perform(customer_id, version)
    sync = BillingSyncState.find_or_create_by!(customer_id:)
    return if version <= sync.last_synced_version

    BillingApi.push_subscription(customer_id, version)
    sync.update!(last_synced_version: version, retry_count: 0, next_retry_at: nil)
  rescue BillingApi::TransientError
    failures = exception_executions["[BillingApi::TransientError]"].to_i + 1
    sync.update!(retry_count: sync.retry_count + 1, next_retry_at: BACKOFF.call(failures).seconds.from_now)
    raise
  end
end
```

`BillingSyncState` is a plain Active Record model. Its `last_synced_version` and `retry_count` columns are integers with a default of 0, and `next_retry_at` is a timestamp. `exception_executions` counts the earlier failures for one error class, and `retry_on` uses the same count for its delay.

What this job gets from GoodJob:

- At most one `SyncSubscriptionJob` runs at a time for each customer.
- A job that was running when its process stopped runs again.
- The `version` check skips an update that is older than the last synced one.

What it does not get:

- Order. GoodJob says that "a waiting job that is re-scheduled can be overtaken by a newly enqueued job, and jobs retried with incremental back-off run in backoff order". When version 2 fails, version 3 can run first, and the retry of version 2 skips. That is correct only if each update carries the full state. If each update is a change that must apply in order, the job needs its own sequence check.
- A quiet wait. A second job for the same customer raises `ConcurrencyExceededError` and retries with backoff. With the `good_job_concurrency_claims` table, GoodJob reschedules the longest-waiting job to run at once when the key becomes free. The backoff stays as a fallback.

GoodJob also says that its strategy "assumes that collisions are atypical". The updates for one busy customer collide often.

### With Solid Objects

There is one `CustomerBillingSync` actor for each customer ID.

```ruby
class CustomerBillingSync < SolidObjects::Actor
  MAXIMUM_BACKOFF_MINUTES = 60

  attribute :last_synced_version, default: 0
  attribute :pending, default: -> { [] }
  attribute :pushing, default: false
  attribute :retry_count, default: 0
  attribute :next_retry_at, default: nil

  def update_subscription(version:, plan:)
    return newest_version if version <= newest_version

    self.pending = pending + [ { "version" => version, "plan" => plan, "key" => "billing-#{actor_id}-v#{version}" } ]
    push_next unless pushing || next_retry_at
    version
  end

  def pushed(effect_id:, arguments:, result:)
    self.pushing = false
    self.last_synced_version = arguments.fetch("version")
    self.pending = pending.drop(1)
    self.retry_count = 0
    self.next_retry_at = nil
    push_next
  end

  def push_failed(effect_id:, arguments:, error:)
    self.pushing = false
    self.retry_count += 1
    retry_at = [ 2**retry_count, MAXIMUM_BACKOFF_MINUTES ].min.minutes.from_now
    self.next_retry_at = retry_at.iso8601
    schedule(at: retry_at, key: "retry").retry_push
  end

  def retry_push
    self.next_retry_at = nil
    push_next unless pushing
  end

  private

  def newest_version
    pending.last&.fetch("version") || last_synced_version
  end

  def push_next
    update = pending.first
    return unless update

    self.pushing = true
    emit :push_subscription,
      idempotency_key: update.fetch("key"),
      customer_id: actor_id,
      version: update.fetch("version"),
      plan: update.fetch("plan"),
      on_success: :pushed,
      on_failure: :push_failed
  end
end
```

The initializer registers the effect that calls the billing API:

```ruby
SolidObjects.register_effect(:push_subscription) do |arguments, _context|
  BillingApi.push_subscription(
    idempotency_key: arguments.fetch("idempotency_key"),
    customer_id: arguments.fetch("customer_id"),
    version: arguments.fetch("version"),
    plan: arguments.fetch("plan")
  )
end
```

The app sends each update with `async`:

```ruby
CustomerBillingSync.ref(customer.id.to_s)
  .async(idempotency_key: "subscription-#{subscription.id}-v#{subscription.version}", authorization_context: Current.user)
  .update_subscription(version: subscription.version, plan: subscription.plan)
```

The generated policies deny every call. Allow this call in your `authorize_message` policy. See [authorization policies](../authorization.md).

How it works:

- The runtime stores each message in SQL before `async` returns. Messages for one customer run one at a time, in the order that the runtime stores them. A second message waits in the mailbox. It does not fail and retry.
- `update_subscription` appends the update to `pending`. It ignores a version that is not newer than the newest one it knows, so a repeated delivery changes nothing.
- `push_next` stages one effect for the oldest pending update. `pushing` stays true until that effect succeeds or fails. So the billing API never gets two pushes for one customer at the same time, and it gets the versions in order.
- Each pending update carries its own idempotency key, made from the customer ID and the version. The effect handler sends that key. So the billing API applies an update once, even when a crash runs the effect again or a backoff reminder stages a new effect.
- The runtime retries a failed effect with a short delay (5 attempts by default). If every attempt fails, `push_failed` counts the failure and schedules `retry_push` with backoff: 2, 4, 8 minutes, up to 60 minutes. The update stays first in `pending`, so it keeps its place. A newer update waits for the retry too.
- The reminder is a row in the database. It runs after a deploy or a restart.

### What the tests prove

[The tests](../../test/compare/customer_billing_sync_test.rb) show these results:

- Three updates for one customer reach the billing API one at a time, as versions 1, 2, and 3.
- Two customers each have a staged push at the same time. One customer does not wait for the other.
- A push that runs again after a lost response uses the same idempotency key, and the billing API applies it once.
- A push that runs again after the backoff also uses the same idempotency key, and the billing API applies it once.
- A repeated or older update sends no push to the billing API.
- A newer update that arrives during the backoff waits for the retry.
- A failed push records the retry count and the next retry time. After the test resets the caller process and moves the clock 3 minutes ahead, the reminder runs, the push succeeds, and the retry count goes back to 0.

## Questions that teams ask

**Is Solid Objects mature enough?** Here are the facts:

- First public release: August 6, 2026.
- Version 1.0.0: October 13, 2026. The public API follows [semantic versioning](../versioning.md).
- One maintainer.
- One first-party application with more than 100,000 users runs it in production. That is a count of users, not a measure of load. No production use by other people is known.
- The [benchmarks](../benchmarks.md) are development measurements. Longer soak tests are open work.

GoodJob is older and has more users. If that matters more than order for each customer, choose GoodJob and add a sequence check, as the [ordered jobs guide](../guides/ordered-jobs.md) shows.

**Does it need another process?** Yes. `bundle exec solid_objects start` runs async messages, effects, and reminders. GoodJob in external mode also needs a process: `bundle exec good_job start`. While the Solid Objects process is down, pending work stays in SQL.

**Is delivery exactly once?** No. Delivery is at least once. A turn can run again after a crash. Give each external call a stable idempotency key. The effect ID (`context.id`) is stable across the retries of one effect. The example stores a key with each update, so the key also survives a backoff retry. See [correctness and delivery semantics](../correctness.md).

**Can actor code write my tables?** Not directly. An actor reads application records. To write a row in the same transaction as the actor state, use a commit action. The [ordered jobs guide](../guides/ordered-jobs.md) shows one.

**What if one customer is very busy?** One actor runs one turn at a time. If one customer has independent streams of work, give each stream its own actor ID, for example one for each subscription.

**Can I use both?** Yes. Keep your other jobs in GoodJob. The two use different tables in the same database.

## Sources

Checked October 15, 2026:

- [GoodJob 4.22.1 README: concurrency controls](https://github.com/bensheldon/good_job/blob/v4.22.1/README.md#concurrency-controls)
- [GoodJob 4.22.1 README: how concurrency controls work](https://github.com/bensheldon/good_job/blob/v4.22.1/README.md#how-concurrency-controls-work)
- [GoodJob 4.22.1 README: migrating from concurrency keys to labels](https://github.com/bensheldon/good_job/blob/v4.22.1/README.md#migrating-from-concurrency-keys-to-labels)
- [GoodJob 4.22.1 README: interrupts, graceful shutdown, and SIGKILL](https://github.com/bensheldon/good_job/blob/v4.22.1/README.md#interrupts-graceful-shutdown-and-sigkill)
- [GoodJob changelog](https://github.com/bensheldon/good_job/blob/v4.22.1/CHANGELOG.md)
- [Active Job `retry_on`](https://api.rubyonrails.org/classes/ActiveJob/Exceptions/ClassMethods.html)

## More information

- [All comparisons](../comparisons.md)
- [Solid Queue limits_concurrency and Solid Objects](solid-queue.md)
- [Run jobs in order for each customer in Rails](../guides/ordered-jobs.md)
- [Guide for coding agents](../agents.md)
