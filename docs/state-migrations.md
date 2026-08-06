# State migration guide

Declare a monotonically increasing version and every adjacent migration:

```ruby
class ShoppingCartActor < SolidObjects::Actor
  state_version 2

  migrate_state from: 1, to: 2 do |state|
    state["currency"] ||= "USD"
    state
  end
end
```

Migration runs in memory during activation. The new version is persisted only
with the next successful fenced message commit.
Migration blocks may read application records but cannot write them directly;
the same Active Record write guard used for handlers applies before activation.

## Runtime rules

- Stored state newer than running code refuses activation.
- Missing migration steps fail activation.
- Every migration result must pass JSON serialization.
- Additive representation changes that old and new code both understand need
  no version bump.
- Destructive changes require expand/contract releases.
- Published actor migrations are never squashed. A year-idle actor may still
  hold a year-old blob.

## Rolling deploys

A new worker can migrate state while an old worker still exists. If the old code
cannot read the migrated shape, drain the old workers before allowing the new
version to persist it.

A safe destructive rollout normally uses:

1. Expand readers to accept old and new shapes.
2. Deploy that compatibility release everywhere.
3. Add and enable the actor migration.
4. Allow active and dormant actors to migrate over time, or run an authorized
   message-based migration campaign.
5. Remove old-shape support only after operational evidence says it is safe.

Never update actor JSON in a bulk SQL migration. Use actor messages so fencing,
ordering, observables, and outboxes remain intact.

This guide covers evolution after state belongs to Solid Objects. For moving
existing Redis, key-value, or relational state into actors without downtime,
use the [legacy-state migration cookbook](migrating-existing-state.md).
