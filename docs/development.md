# Development guide

## Requirements

- Ruby 3.3 or newer
- Rails 8.0 or newer
- SQLite 3.35+, PostgreSQL 14+, and MySQL 8.0/InnoDB for the full matrix

Install dependencies:

```bash
bundle install
```

## Tests

The suite uses Minitest and follows Solid Queue's broad structure: unit tests,
model/schema tests, engine boot tests, and real database integration tests.
Concurrency tests use queues and notification barriers instead of timing-only
sleeps.

```bash
bundle exec rake test
SOLID_OBJECTS_DATABASE_URL=postgresql://... bundle exec rake test
SOLID_OBJECTS_DATABASE_URL=mysql2://... bundle exec rake test
```

Each database run must start from an empty dedicated test database because the
test helper applies the engine migration.

## Host application tests

Rails transactional tests keep the application connection inside an outer
transaction. Synchronous actor invocation deliberately rejects that condition
because nested savepoints retain actor locks until the test transaction ends
and make durable behavior unlike production.

Use an actor-specific base class:

```ruby
require "solid_objects/test_helper"

class SolidObjectsTestCase < ActiveSupport::TestCase
  include SolidObjects::TestHelper
end
```

The helper disables transactional tests for that class and removes Solid
Objects instances and process registrations before and after each test. It
preserves application configuration, actor registration, and effect/commit
action registration. If actor commit actions create application records, clean
those records with fixtures or explicit teardown because they are no longer
covered by Rails' transaction rollback.

Use `drain_solid_objects` to process actor, reminder, effect, callback, and
broadcast work to a deterministic fixed point without arbitrary sleeps:

```ruby
message = Counter.ref("test").async(:increment)

assert_equal 1, drain_solid_objects
assert_equal "completed", message.status
```

Pass `roles: [:actors]` when a test intentionally wants to leave outboxes or
reminders pending.

`SolidObjects::TestHelper.reset_actors!` is also available for explicit suite
boundaries. It deletes every actor-owned row itself rather than deleting actor
instances and letting the database cascade remove the rest: SQLite has to be
asked for foreign keys, MySQL has to be on InnoDB, and a host application may
have stripped the constraints out of the copied migration. Where the cascade
does not fire, a row that survives a reset carries an `instance_id` pointing at
nothing, and the next test that reads reminders or dead letters sees another
test's data.

## Inline RBS

Ruby source starts with:

```ruby
# rbs_inline: enabled
```

Methods and instance variables use `# @rbs` annotations. Generate and validate
signatures with:

```bash
bundle exec rake rbs
```

This follows the inline convention used by `cardmagic/classifier`.

## Formatting and security

```bash
bundle exec standardrb
bundle exec rubocop
bundle exec rake rbs steep
bundle exec brakeman --force --no-pager -q .
bundle exec rake
```

`.rubocop.yml` is pinned to the policy shape in Solid Queue main at commit
`86f3d92f1dd68547ec0ebe960fc9933c203d9e51`: Rails Omakase, Ruby 3.3, and its
schema/template exclusions. Rails Omakase is canonical where the policies
conflict. Standard remains an additional gate with only its opposing
array/hash-bracket whitespace cops ignored.

Run a failing Minitest first for behavioral changes, implement the smallest
correct change, rerun the focused test, then the complete database matrix.

## Benchmarks

Scripts in `benchmark/` cover adoption latency and durable row growth, enqueue,
claim, processing, cold actors, a hot actor, concurrent actors, synchronous
latency, cache reuse, and query counts. Results describe one machine and
database configuration; they are not universal capacity guarantees.

```bash
COUNT=25 bundle exec ruby -Ilib benchmark/adoption_latency.rb
COUNT=500 bundle exec ruby -Ilib benchmark/enqueue.rb
COUNT=500 bundle exec ruby -Ilib benchmark/claim.rb
COUNT=500 bundle exec ruby -Ilib benchmark/processing.rb
COUNT=500 bundle exec ruby -Ilib benchmark/cold_actors.rb
COUNT=500 bundle exec ruby -Ilib benchmark/hot_actor.rb
COUNT=500 CONCURRENCY=4 bundle exec ruby -Ilib benchmark/concurrent_actors.rb
COUNT=100 bundle exec ruby -Ilib benchmark/sync_latency.rb
COUNT=500 bundle exec ruby -Ilib benchmark/activation_cache.rb
bundle exec ruby -Ilib benchmark/query_count.rb
```

SQLite is the default. Set `SOLID_OBJECTS_DATABASE_URL` to benchmark a dedicated
empty PostgreSQL or MySQL database.
