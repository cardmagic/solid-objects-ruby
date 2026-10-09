# Save state and queue work together in Rails

A database commit and a job enqueue are two separate steps. If the process stops between them, the database keeps the data, but the queue receives no work. The transactional outbox pattern writes the work into the same database transaction as the data. A separate process delivers the work later. A Solid Objects actor, from the `solid_objects` gem, commits its state, its database writes, and its staged effects in one transaction.

## Reproduce the lost job

```ruby
class Order < ApplicationRecord
  def self.place_and_enqueue!(reference:, total_cents:)
    order = create!(reference:, total_cents:)
    ShipmentJob.perform_later(order_id: order.id)
    order
  end

  def self.place_with_outbox!(reference:, total_cents:)
    transaction do
      order = create!(reference:, total_cents:)
      OutboxMessage.create!(name: "request_shipment", arguments: { "order_id" => order.id })
      order
    end
  end
end
```

```ruby
class ShipmentJob < ApplicationJob
  def perform(order_id:)
    order = Order.find(order_id)
    ShippingProvider.create_shipment(idempotency_key: "order-#{order.id}", order_reference: order.reference)
  end
end
```

In `place_and_enqueue!`, `create!` commits the order. Then `perform_later` sends the job to the queue. The test uses a queue adapter that stops the process before the job reaches the queue. The order exists, but no job exists.

`after_commit` and `enqueue_after_transaction_commit` have the same gap: they enqueue the job after the database commit.

The Rails Guides state that `enqueue_after_transaction_commit` defers the enqueue until the Active Record transaction commits successfully. If the transaction rolls back, Rails does not enqueue the job. Rails 8 configures Solid Queue on a separate database by default. With this default, the job row and the order row use two databases. See [the Rails Guides, section 6.6.1](https://guides.rubyonrails.org/active_job_basics.html) (checked October 9, 2026).

[The transactional outbox tests](../../test/guides/transactional_outbox_test.rb) demonstrate the crash gap.

## The plain outbox pattern

In `place_with_outbox!`, the model writes the order and an outbox row in one transaction.

```ruby
class OutboxMessage < ApplicationRecord
  JOBS = { "request_shipment" => ShipmentJob }.freeze

  scope :pending, -> { where(delivered_at: nil).order(:id) }

  def self.relay(limit: 100)
    pending.limit(limit).each do |message|
      JOBS.fetch(message.name).perform_later(**message.arguments.symbolize_keys)
      message.update!(delivered_at: Time.current)
    end
  end
end
```

The `relay` method uses these steps:

1. It sends each undelivered row to the queue.
2. It marks the row as delivered.

If the process stops after the enqueue and before the mark, the next relay sends the row again. The job must be idempotent. `ShipmentJob` passes `order-<id>` to the provider as the idempotency key.

Rails Event Store uses this pattern. Its scheduler writes the job into the same database table within the same transaction. A separate `res_outbox` process sends those rows to the background jobs tool. See [Rails Event Store](https://railseventstore.org/docs/advanced-topics/outbox) (checked October 9, 2026).

The plain outbox pattern is a good choice for an application that does not use actors.

## The atomic boundary of an actor turn

```ruby
class Checkout < SolidObjects::Actor
  attribute :status, default: "open"
  attribute :total_cents, default: 0
  attribute :shipment_id, default: nil

  def place(total_cents:)
    return status unless status == "open"

    self.status = "placed"
    self.total_cents = total_cents
    commit_action(:record_order, reference: actor_id, total_cents:)
    emit(:request_shipment, order_reference: actor_id, on_success: :shipment_requested)
    status
  end

  def shipment_requested(effect_id:, arguments:, result:)
    self.status = "shipping"
    self.shipment_id = result.fetch("shipment_id")
  end
end
```

```ruby
SolidObjects.register_commit_action(:record_order) do |arguments, _context|
  Order.create!(reference: arguments.fetch("reference"), total_cents: arguments.fetch("total_cents"))
end

SolidObjects.register_effect(:request_shipment) do |arguments, context|
  ShippingProvider.create_shipment(
    idempotency_key: context.id,
    order_reference: arguments.fetch("order_reference")
  )
end
```

One successful turn commits the actor state, the staged effects, the same-database commit actions, the reminders, and the outbound messages together. Actor Ruby code and external I/O run outside the actor-state transaction.

- `commit_action(:record_order, ...)` writes the `orders` row inside that transaction. A commit action requires Solid Objects and `ActiveRecord::Base` to share one connection pool. It can run again after a database rollback. Keep each commit action deterministic, bounded, and database-only.
- `emit(:request_shipment, ...)` stages an effect row in the same transaction. After the commit, an effect worker calls the handler outside any database transaction.
- The handler passes `context.id` to the provider as the idempotency key. `context.id` is the effect ID. It stays the same on every attempt.
- `on_success: :shipment_requested` sends the provider result back to the actor as a normal message.
- If the turn raises, it commits no state, no order row, and no effect row.
- `place` returns early when the checkout is not open. A repeated call stages no additional order or effect.

## What Solid Objects does not do

- Solid Objects does not wrap ordinary Active Record writes. Code outside an actor keeps its own transactions.
- A direct Active Record write inside an actor operation raises `SolidObjects::ApplicationWriteForbidden`. A registered commit action provides the only path for application row writes inside the actor commit.
- A commit action is unavailable when Solid Objects uses a separate database. Use `emit` with an idempotent effect consumer. Two databases cannot share one transaction.
- Solid Objects does not provide exactly-once delivery. An effect can run more than once.

## What the tests prove

- A stop before the enqueue saves the order and loses the job.
- A failure between the order insert and the outbox insert saves neither row.
- The relay sends a message twice after a lost mark, and the provider creates one shipment.
- A failed turn keeps no state, no order row, and no effect row.
- A successful turn stores the state, the order row, and the effect row together.
- Repeated `place` calls stage one order and one effect in total.
- The provider response fails to reach the effect worker once. The effect runs again with the same `context.id`. The provider creates one shipment, and the actor records the shipment ID.

## Run it in production

- Run `bundle exec solid_objects start`. Effects and their callbacks run only while this process runs. The SQL database keeps undelivered effects while the process does not run.
- Register effects and commit actions in an initializer at boot.
- The generated policies deny every call. Write a policy. Pass `authorization_context:` on each call. See [authorization policies](../authorization.md).
- See [effect recovery](../effect-recovery.md) for effects whose worker stopped during a call.

## Limits

- Solid Objects requires Ruby 3.3 or newer and Rails 7.1 or newer.
- Delivery is at least once. Each effect handler must deduplicate with `context.id`.
- Solid Objects provides no transactions across actors.
- The gem is pre-1.0 and makes no production-ready claim.

## More information

- [The example files](../../examples/guides/transactional_outbox/checkout.rb)
- [The tests for this guide](../../test/guides/transactional_outbox_test.rb)
- [Correctness and delivery semantics](../correctness.md)
- [Expiring reservations](expiring-reservations.md)
- [Prevent race conditions in Rails](race-conditions.md)
