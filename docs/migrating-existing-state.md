# Migrating existing state

Moving an existing Redis, cache, or key-value state machine into Solid Objects
is a data migration and a coordination cutover. Treat it as a staged production
change, not a rewrite that switches storage in one deploy.

## 1. Write down the existing contract

Inventory:

- every read and write path;
- the current canonical and secondary keys;
- expiration and cleanup behavior;
- concurrency guards and idempotency keys;
- external effects;
- expected request latency and volume; and
- rollback requirements.

Run the [fit checklist](fit.md#decision-checklist) before migrating. A hot
counter or append pipeline may be better left in its existing store.

## 2. Choose one canonical identity

Solid Objects addresses an actor with one `(actor_type, actor_id)` pair. Do not
hide two competing identities inside actor code or reintroduce a scan.

When existing state is written by `(user_id, assessment_short)` but read by
`session_id`, create a normalized lookup record:

```ruby
class AssessmentSession < ApplicationRecord
  validates :session_id, uniqueness: true
  validates :assessment_short, uniqueness: { scope: :user_id }

  def actor
    Assessment.ref(id)
  end
end
```

The lookup row gives both old keys one stable primary key. The actor ID is the
lookup record ID, and ordinary indexed Active Record queries resolve either
external key. This is clearer and safer than delimiter-joining composite values
or preserving a `LIKE` scan.

Create and backfill the lookup table before actor traffic begins. Enforce every
identity invariant with unique database indexes.

## 3. Add an idempotent bootstrap message

Never bulk-update `solid_objects_instances.state`. Direct writes bypass actor
ordering, state migrations, observables, activation ownership, and fencing.

Import through a normal actor message:

```ruby
class Assessment < SolidObjects::Actor
  attribute :imported, default: false
  attribute :answers, default: -> { [] }

  def bootstrap(answers:)
    return if imported

    self.answers = answers
    self.imported = true
  end
end
```

Give every bootstrap call an idempotency key derived from the legacy record:

```ruby
session.actor.async(
  :bootstrap,
  answers: legacy.answers,
  idempotency_key: "legacy-assessment:#{legacy.id}",
  available_at: jittered_time
)
```

Spread large backfills over a dispatch window and monitor mailbox age,
failures, and dead letters. Asynchronous backfill requires the worker runtime.

## 4. Prefer shadow comparison over blind dual writes

Two independent stores cannot be updated atomically without a shared
transaction or outbox. A controller that writes Redis and an actor in sequence
can leave them divergent after a timeout or crash.

A safer rollout:

1. Keep the legacy store authoritative.
2. Bootstrap the actor from a consistent legacy snapshot.
3. Mirror new changes to the actor with stable idempotency keys.
4. Read both stores in a background comparison path.
5. Record divergence counts without changing the user response.
6. Repair through actor messages, never direct actor-state SQL.
7. Cut reads over only after divergence remains acceptably low.

If the actor becomes authoritative before the legacy system is retired, emit a
transactional effect that updates the legacy store. The effect is at least once,
so the legacy write still needs idempotency.

## 5. Cut over in reversible stages

A typical zero-downtime sequence is:

1. Deploy the lookup table and dual-key resolution.
2. Deploy actor code and policies with reads still on the legacy store.
3. Start the required runtime roles.
4. Backfill actors in bounded batches.
5. Enable shadow comparison and reconcile drift.
6. Move a small cohort of reads to actors.
7. Expand the cohort while watching latency, database growth, retries, and
   divergence.
8. Move writes to the actor.
9. Retain the legacy state through an explicit rollback window.
10. Remove dual writes and legacy data only after the rollback window closes.

Use a feature flag whose rollback restores legacy reads and writes without
requiring actor deletion. Do not assume a timed-out synchronous actor call did
not commit; query the durable result or use an idempotency key before retrying.

## 6. Plan for dormant state and future changes

Actor state migrations and legacy-store migration solve different problems:

- this cookbook moves ownership from another store into an actor;
- `state_version` evolves actor JSON after that ownership exists.

Keep every published actor migration step. A dormant actor can reactivate years
later with an old state representation. See the
[state migration guide](state-migrations.md) for rolling-deployment rules.
