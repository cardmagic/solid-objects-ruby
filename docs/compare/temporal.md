# Temporal Ruby SDK and Solid Objects: general availability, ordered work, and timers in Rails

Yes, the Temporal Ruby SDK (the `temporalio` gem) is generally available. Temporal announced general availability on October 1, 2025, after a public preview that started on May 1, 2025 ([Temporal changelog](https://temporal.io/changelog/ruby-sdk-generally-available), checked October 18, 2026). The SDK runs workflows and activities in your Ruby worker processes, and a Temporal Service keeps the event history of each workflow. Solid Objects (the `solid_objects` gem) gives each key an actor with an ordered mailbox, durable state, and reminders, in the SQL database that the Rails app already uses. Choose Temporal for long workflows of many steps that must resume after a failure. Choose Solid Objects when one key, such as a customer or a game room, has state that each update reads and changes in order.

Solid Objects is an independent project. It is not affiliated with Temporal Technologies or Rails.

## The short answer

| Question | Temporal Ruby SDK | Solid Objects |
| --- | --- | --- |
| Status | Generally available since October 1, 2025. The 1.0.0 release says "the Ruby SDK is now considered stable" | Stable public API since October 13, 2026, under semantic versioning |
| What has state | A workflow execution with a workflow ID | An actor class and an actor ID |
| One at a time for each key | "only one Workflow Execution with a given Workflow Id can be in an Open state at any given time" | One turn at a time for each actor |
| Order of messages | Temporal processes messages "in the order they were received". Handlers that wait "can run interleaved with the main Workflow and with one another" | Messages run in the order that the runtime stores them, one turn at a time |
| Where the state lives | The event history in the Temporal Service. The service stores it in Cassandra, PostgreSQL, or MySQL. SQLite is "only for development and testing" | Tables in your SQLite, PostgreSQL, or MySQL database |
| Code rules | Workflow code must be deterministic. "Temporal Workflows by default disallow use of IO during the Workflow run" | Ordinary Ruby. External calls go in effects, outside the turn |
| Timers | `Temporalio::Workflow.sleep` and `Temporalio::Workflow.timeout`. "Timers are persisted" | Reminders with `schedule(at:, key:)`, stored as rows |
| Retries | Activities retry with exponential backoff. The default waits 1 second, doubles the wait up to 100 seconds, and has no limit on attempts | Effect retries (the global `max_attempts` and `retry_delay` settings), then `on_failure` and a reminder |
| History size | "limited to 51,200 Events or 50 MB". A long-lived workflow continues as new | No event history. Each turn saves the current state |
| What you run | A Temporal Service (the Temporal Server and a database) or Temporal Cloud, and your worker processes | Your Rails app and `bundle exec solid_objects start` |
| Ruby and platforms | Ruby 3.3, 3.4, and 4.0. Gems for Linux and macOS. "MinGW-based Windows is not currently supported" | Ruby 3.3 or newer and Rails 7.1 or newer |
| Licence | SDK: MIT. Temporal Server: MIT | MIT |

The Temporal facts come from the [Temporal documentation](https://docs.temporal.io/develop/ruby), the [Ruby SDK README](https://github.com/temporalio/sdk-ruby), and the [Temporal changelog](https://temporal.io/changelog/product-area/ruby-sdk) (checked October 18, 2026).

## Choose Temporal when

- The work is a long workflow of many steps, for example an order that waits days for a payment, a shipment, and a refund.
- You want the event history of each workflow, and you want to replay it.
- A step must wait for a person or a system for days, with durable timers and signals.
- You already run a Temporal Service, or you can use Temporal Cloud.

## Choose Solid Objects when

- The updates for one key must apply one at a time, in the order they arrived.
- Each key has state that the updates read and change, for example the last synced version or the current turn.
- You want that state in the SQL database that you already back up and query, not in a workflow history.
- You want a state change and its effects and reminders to commit in one SQL transaction.
- You do not want to run a Temporal Service.

## The same terms in each

| Temporal Ruby SDK | Solid Objects |
| --- | --- |
| Workflow ID | Actor ID |
| A class that extends `Temporalio::Workflow::Definition` | A class that extends `SolidObjects::Actor` |
| Signal (`workflow_signal`) | `ref(id).async.method(...)` |
| Update (`workflow_update`) with a validator | `ref(id).method(...)` and `reject` |
| Query (`workflow_query`) | `query` or `snapshot` |
| Activity | Effect (`emit` and `SolidObjects.register_effect`) |
| Activity retry policy | Effect retries (the global `max_attempts` and `retry_delay` settings) |
| `Temporalio::Workflow.sleep` or `Temporalio::Workflow.timeout` | `schedule(at:, key:)` and an operation |
| Signal-With-Start | The first message to an actor ID |
| Continue-As-New | No equivalent. An actor keeps only its current state |

## One billing sync for each customer

The task: a Rails 8 app on PostgreSQL syncs each customer's subscription with an external billing API. The updates for one customer must run one at a time and in the order they arrived. Different customers run in parallel. Each customer has state: the last synced version, a retry count, and the next retry time. A failed sync must retry with backoff and survive a restart.

### With the Temporal Ruby SDK

There is one `CustomerBillingWorkflow` for each customer. This code follows the Temporal Ruby documentation. On October 18, 2026, it ran with the `temporalio` gem in the Temporal time-skipping test environment: three updates reached the billing API in order, and a failed push ran again with the same key. The Continue-As-New branch did not run in that check. The Solid Objects test suite does not run it.

```ruby
require "temporalio/activity"
require "temporalio/retry_policy"
require "temporalio/workflow"

class PushSubscriptionActivity < Temporalio::Activity::Definition
  def execute(update)
    BillingApi.push_subscription(
      idempotency_key: update.fetch("key"),
      customer_id: update.fetch("customer_id"),
      version: update.fetch("version"),
      plan: update.fetch("plan")
    )
  end
end

class CustomerBillingWorkflow < Temporalio::Workflow::Definition
  PUSH_RETRY_POLICY = Temporalio::RetryPolicy.new(initial_interval: 120, backoff_coefficient: 2.0, max_interval: 3600)

  workflow_query_attr_reader :last_synced_version

  workflow_init
  def initialize(state)
    @last_synced_version = state.fetch("last_synced_version")
    @pending = state.fetch("pending")
  end

  def execute(_state)
    loop do
      Temporalio::Workflow.wait_condition { @pending.any? || Temporalio::Workflow.continue_as_new_suggested }
      break if Temporalio::Workflow.continue_as_new_suggested

      update = @pending.first
      Temporalio::Workflow.execute_activity(
        PushSubscriptionActivity, update,
        start_to_close_timeout: 30, retry_policy: PUSH_RETRY_POLICY
      )
      @last_synced_version = update.fetch("version")
      @pending.shift
    end
    Temporalio::Workflow.wait_condition { Temporalio::Workflow.all_handlers_finished? }
    raise Temporalio::Workflow::ContinueAsNewError.new(
      { "last_synced_version" => @last_synced_version, "pending" => @pending }
    )
  end

  workflow_signal
  def update_subscription(update)
    newest_version = @pending.last&.fetch("version") || @last_synced_version
    @pending << update if update.fetch("version") > newest_version
  end
end
```

The Rails app sends each update with Signal-With-Start. It starts the workflow if it does not run yet. `TEMPORAL_CLIENT` is a `Temporalio::Client` that an initializer connects:

```ruby
operation = Temporalio::Client::WithStartWorkflowOperation.new(
  CustomerBillingWorkflow, { "last_synced_version" => 0, "pending" => [] },
  id: "billing-#{customer.id}", task_queue: "billing"
)
TEMPORAL_CLIENT.signal_with_start_workflow(
  CustomerBillingWorkflow.update_subscription,
  { "key" => "billing-#{customer.id}-v#{subscription.version}", "customer_id" => customer.id.to_s,
    "version" => subscription.version, "plan" => subscription.plan },
  start_workflow_operation: operation
)
```

A worker process runs the workflow and the activity:

```ruby
Temporalio::Worker.new(
  client: TEMPORAL_CLIENT, task_queue: "billing",
  workflows: [CustomerBillingWorkflow], activities: [PushSubscriptionActivity]
).run(shutdown_signals: ["SIGINT"])
```

What this code gets from Temporal:

- One workflow runs for each customer, because the workflow ID holds the customer ID.
- The signal handler waits for nothing, so the updates go into `@pending` in the order that Temporal received them.
- The main loop pushes one update at a time. While the activity retries, newer updates wait, so the order holds.
- The retry policy waits 2 minutes, then 4, then 8, up to 60 minutes, with no limit on attempts.

What to know:

- Workflow code must be deterministic. It cannot read Active Record or call the billing API. The activity does that.
- The state (`@pending` and `@last_synced_version`) lives in the event history, not in your tables. The app reads `last_synced_version` with a query.
- Temporal counts the attempts of each activity. This workflow does not copy the retry count or the next retry time into its own state.
- Each signal and each activity adds events to the history. The history is "limited to 51,200 Events or 50 MB", so the workflow continues as new when Temporal suggests it. It carries the pending updates into the new run.
- Activities run at least once. The docs say that an activity "may be executed multiple times". The billing API must accept the idempotency key.
- You operate a Temporal Service, or you use Temporal Cloud, and you run a worker process beside the Rails app.

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

- The runtime stores each message in SQL before `async` returns. Messages for one customer run one at a time, in the order that the runtime stores them.
- `update_subscription` appends the update to `pending`. It ignores a version that is not newer than the newest one it knows, so a repeated delivery changes nothing.
- `push_next` stages one effect for the oldest pending update. `pushing` stays true until that effect succeeds or fails. So the billing API gets the versions in order, one at a time.
- Each pending update carries its own idempotency key. So a billing API that accepts the key applies an update once, even when a crash runs the effect again.
- If every effect attempt fails, `push_failed` counts the failure, stores the next retry time, and schedules `retry_push` with backoff: 2, 4, 8 minutes, up to 60 minutes. The update keeps its place.
- The state is in actor attributes, and the reminder is a row in the database. Both survive a deploy or a restart.

### What the tests prove

[The tests](../../test/compare/customer_billing_sync_test.rb) show these results:

- Three updates for one customer reach the billing API one at a time, as versions 1, 2, and 3.
- Two customers each have a staged push at the same time. One customer does not wait for the other.
- A push that runs again after a lost response, or after the backoff, uses the same idempotency key, and the billing API applies it once.
- A newer update that arrives during the backoff waits for the retry.
- After the test resets the caller process and runs the reminders that are due 3 minutes later, the reminder runs and the push succeeds.

## Game rooms with turn timers in each

The task: turn-based game rooms in a Rails 8 app on PostgreSQL. Players send moves over Action Cable, and the app runs on several servers. The moves for one room must apply strictly in order. The room state must survive deploys. Each turn has a 60-second timer that must fire even if the server that started it restarts.

### With the Temporal Ruby SDK

There is one `GameRoomWorkflow` for each room. This code also ran in the Temporal time-skipping test environment on October 18, 2026. A move out of turn was rejected, and the timer skipped a turn after 60 seconds. The Continue-As-New branch did not run in that check.

```ruby
require "temporalio/workflow"

class GameRoomWorkflow < Temporalio::Workflow::Definition
  TURN_SECONDS = 60

  workflow_query_attr_reader :turn_number, :skipped_turns

  workflow_init
  def initialize(state)
    @players = state.fetch("players")
    @turn_number = state.fetch("turn_number")
    @moves = state.fetch("moves")
    @skipped_turns = state.fetch("skipped_turns")
  end

  def execute(_state)
    loop do
      break if Temporalio::Workflow.continue_as_new_suggested

      turn = @turn_number
      Temporalio::Workflow.timeout(TURN_SECONDS) do
        Temporalio::Workflow.wait_condition { @turn_number > turn }
      end
    rescue Timeout::Error
      @skipped_turns << turn
      @turn_number += 1
    end
    Temporalio::Workflow.wait_condition { Temporalio::Workflow.all_handlers_finished? }
    raise Temporalio::Workflow::ContinueAsNewError.new(
      { "players" => @players, "turn_number" => @turn_number, "moves" => @moves, "skipped_turns" => @skipped_turns }
    )
  end

  workflow_update_validator(:play)
  def validate_play(move)
    return if move.fetch("turn_number") == @turn_number && move.fetch("player_id") == current_player

    raise Temporalio::Error::ApplicationError, "It is not your turn"
  end

  workflow_update
  def play(move)
    @moves << move
    @turn_number += 1
  end

  private

  def current_player
    @players[@turn_number % @players.size]
  end
end
```

- An update with a validator can reject a move, and the caller gets the error. A signal cannot do that. The server answers a signal "without waiting for the Workflow to process the Signal".
- The workflow continues as new when Temporal suggests it, and carries the room state into the new run. So a long game stays inside the history limit.
- `Temporalio::Workflow.timeout` starts a durable timer. "Timers are persisted", so the timer fires after a worker restart.
- The Action Cable channel calls `execute_update` on the workflow handle. The docs say that a client that sends an update "must wait until the Server delivers the Update to a Worker".

### With Solid Objects

There is one `GameRoom` actor for each room.

```ruby
class GameRoom < SolidObjects::Actor
  TURN_DURATION = 60.seconds

  attribute :players, default: -> { [] }
  attribute :turn_number, default: 0
  attribute :moves, default: -> { [] }
  attribute :skipped_turns, default: -> { [] }

  def start(players:)
    return turn_number if self.players.any?
    reject(:not_enough_players, "The game needs two players") if players.uniq.size < 2

    self.players = players.uniq
    start_turn_timer
    turn_number
  end

  def play(player_id:, move:, turn_number:)
    reject(:not_started, "The game has not started") if players.empty?
    reject(:stale_turn, "That turn already ended") unless turn_number == self.turn_number
    reject(:not_your_turn, "It is not your turn") unless player_id == current_player

    self.moves = moves + [ { "player_id" => player_id, "move" => move, "turn_number" => turn_number } ]
    next_turn
  end

  def turn_timeout(turn_number:)
    return self.turn_number unless turn_number == self.turn_number

    self.skipped_turns = skipped_turns + [ turn_number ]
    next_turn
  end

  private

  def current_player
    players[turn_number % players.size]
  end

  def next_turn
    self.turn_number += 1
    start_turn_timer
    turn_number
  end

  def start_turn_timer
    schedule(at: TURN_DURATION.from_now).turn_timeout(turn_number:)
  end
end
```

- `reject` returns an error to a direct call, for example `GameRoom.ref(room_id).play(player_id:, move:, turn_number:)` from the Action Cable channel. The rejected move changes nothing.
- With no key, `schedule(at:)` gives an actor one alarm for each operation. Each new turn moves the alarm, so one room has one timer.
- The reminder is a row in the database. Another process runs it after a restart.

[The tests](../../test/compare/game_room_test.rb) show that moves apply in the order they arrived, that a move out of turn or for an old turn is rejected, that a move moves the timer, that an old timeout behind a move does not skip the next turn, and that the timer skips the turn after a restart.

## Questions that teams ask

**Is the Temporal Ruby SDK generally available?** Yes. Temporal announced general availability on October 1, 2025. The GitHub release 1.0.0 says: "With this 1.0.0 release, the Ruby SDK is now considered stable." The README marks two sections as experimental: FIPS support and type signatures.

**Is Solid Objects mature enough?** Here are the facts:

- First public release: August 6, 2026.
- Version 1.0.0: October 13, 2026. The public API follows [semantic versioning](../versioning.md).
- [Maintenance and continuity](../maintenance.md) tells you who maintains the project and how a release is made.
- One first-party application with more than 100,000 users runs it in production. That is a count of users, not a measure of load. No production use by other people is known.
- The [benchmarks](../benchmarks.md) are development measurements. Longer soak tests are open work.

The Temporal Ruby SDK has been generally available since October 2025. If a longer history matters more than keeping the state in your own database, choose Temporal.

**Does it need another process?** Both do. Temporal needs a Temporal Service, or Temporal Cloud, and a worker process. Solid Objects needs `bundle exec solid_objects start`, which runs async messages, effects, and reminders. While that process is down, pending work stays in SQL.

**Is delivery exactly once?** Not for external calls, in either. Temporal runs workflow code "exactly once and to completion", but an activity "may be executed multiple times". In Solid Objects, a turn can run again after a crash, and effects run at least once. Give each external call a stable idempotency key. See [correctness and delivery semantics](../correctness.md).

**Can I use both?** Yes. Use Temporal for long workflows of many steps. Use Solid Objects for state for each key that many requests change in order. A Temporal activity can send a message to an actor.

## Sources

Checked October 18, 2026:

- [Temporal Ruby SDK general availability](https://temporal.io/changelog/ruby-sdk-generally-available)
- [Temporal Ruby SDK public preview](https://temporal.io/changelog/ruby-sdk-public-preview)
- [Ruby SDK release 1.0.0](https://github.com/temporalio/sdk-ruby/releases/tag/v1.0.0)
- [Ruby SDK README](https://github.com/temporalio/sdk-ruby)
- [Temporal Ruby workflow basics](https://docs.temporal.io/develop/ruby/workflows/basics)
- [Temporal Ruby message passing](https://docs.temporal.io/develop/ruby/workflows/message-passing)
- [Temporal Ruby timers](https://docs.temporal.io/develop/ruby/workflows/timers)
- [Temporal Ruby Continue-As-New](https://docs.temporal.io/develop/ruby/workflows/continue-as-new)
- [Temporal Ruby and Rails](https://docs.temporal.io/develop/ruby/integrations/rails-integration)
- [Temporal message handling](https://docs.temporal.io/handling-messages)
- [Temporal retry policies](https://docs.temporal.io/encyclopedia/retry-policies)
- [Temporal activity definition](https://docs.temporal.io/activity-definition)
- [Temporal workflow execution limits](https://docs.temporal.io/workflow-execution/limits)
- [Temporal workflow IDs](https://docs.temporal.io/workflow-execution/workflowid-runid)
- [Temporal Service persistence](https://docs.temporal.io/temporal-service/persistence)
- [What is Temporal?](https://docs.temporal.io/temporal)

## More information

- [All comparisons](../comparisons.md)
- [Solid Queue limits_concurrency and Solid Objects](solid-queue.md)
- [Run jobs in order for each customer in Rails](../guides/ordered-jobs.md)
- [Guide for coding agents](../agents.md)
