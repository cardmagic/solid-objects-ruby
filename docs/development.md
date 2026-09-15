# Development guide

## Requirements

- Ruby 3.3 or newer
- Rails 7.1 or newer
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
message = Counter.ref("test").async.increment

assert_equal 1, drain_solid_objects
assert_equal "completed", message.status
```

Pass `roles: [:actors]` when a test intentionally wants to leave outboxes or
reminders pending.

Rails time travel does not move the database clock used by reminder claims. Run
future reminders against an explicit test instant instead of updating runtime
rows or sleeping:

```ruby
assert_equal 1, run_due_reminders(now: 5.minutes.from_now)
assert_equal 1, drain_solid_objects(roles: [ :actors ])
```

The explicit instant controls due selection and recurring schedule advancement.
Claim timestamps and stale-process recovery still use database time.

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

### Public effect payload signatures

The packaged `sig/public` directory owns the reusable effect payload aliases and
survives `rake rbs` regeneration. A host application's Steep target can load the
installed gem's complete signature tree alongside its own signatures:

```ruby
target :app do
  library "solid_objects"
  signature "sig"
  check "app/actors"
  configure_code_diagnostics(Diagnostic::Ruby.strict)
end
```

This requires no internal runtime imports. See the
[typed callback example](architecture.md#typing-your-on_failure-handler).
The gem's strict payload target checks the actual constructors; its packaged
consumer test also verifies that missing keys and incorrect field types fail.

### Actor-specific dispatch signatures

Typed applications can opt into `SolidObjects::ActorSignatures` to check ordinary
`schedule`, `transmit`, and effect callback names inside actor methods. Add `rbs`
and `steep` to the application's development dependencies. This tool is loaded
explicitly and is not required by workers or ordinary Ruby applications.

Declare application operation types first, including inherited operations and
block-defined `message` operations. Inline RBS can generate this input, or keep
handwritten declarations in a separate directory such as `sig/actors`:

```rbs
class ChatRun < SolidObjects::Actor
  def recover_if_stuck: (generation: Integer) -> nil
  def fail_turn: (effect_id: String, arguments: Hash[String, untyped], error: Hash[String, untyped]) -> nil
  def start: () -> nil
end
```

After loading the application's actor classes, generate a separate output file:

```ruby
require "solid_objects/actor_signatures"

Rails.application.reloader.wrap do
  signatures = SolidObjects::ActorSignatures.generate(
    actors: [ChatRun],
    signatures: [Rails.root.join("sig/actors").to_s]
  )
  FileUtils.mkdir_p(Rails.root.join("sig/generated"))
  File.write(Rails.root.join("sig/generated/solid_objects.rbs"), signatures)
end
```

Run that script with `bin/rails runner` during development or CI. Outside Rails,
require the actor definitions and call `generate` directly. The generator returns
a string and does not write files, execute actor operations, start workers, or run
migrations. Rails boot follows the application's normal loading configuration;
the explicit actor list resolves its autoloaded classes within the reloader boundary.
Keep generated output out of the input signature paths, and regenerate after a
message is renamed or removed. Output is deterministic; handwritten signatures
remain separate.

Load the gem and both application signature directories in `Steepfile`:

```ruby
target :actors do
  library "solid_objects"
  signature "sig/actors"
  signature "sig/generated"
  check "app/actors"
  configure_code_diagnostics(Diagnostic::Ruby.strict)
end
```

The usual Ruby code now passes Steep without a dispatcher cast:

```ruby
schedule(at: Time.now, key: "watchdog").recover_if_stuck(generation: 1)
transmit.recover_if_stuck(generation: 1)
emit :run_model, generation: 1, on_failure: :fail_turn
```

Misspelled operations/callbacks, queries, attributes, private methods, infrastructure
methods, and incorrect keyword arguments fail the strict check. Both string and
symbol callback literals work. Staging returns `nil` even when an operation's own
return type differs. Effect and commit-action names remain global registry names;
registry contract inference is separate work.

Reflection supplies message names only. Values come from declared RBS signatures;
missing signatures and positional/block arguments are rejected. Block-defined
messages require explicit method declarations in RBS; annotate their block-local
values separately when checking the block body. Generic actor classes currently
require application-owned dispatcher signatures. The generator preserves method
overloads and method type parameters.

Deliberately dynamic names can use Ruby's explicit dynamic dispatch:

```ruby
schedule(at: Time.now).public_send(operation_name, generation: generation)
public_send(:emit, :run_model, on_failure: callback_name, generation: generation)
```

Those calls opt out of name/argument checking and retain the existing runtime
validation. Ordinary calls on the generated dispatcher have no string-name fallback.
`send_to`, `Reference#async`, direct calls, and queries retain their existing
signatures and runtime behavior; this generator does not provide complete reference
typing or Sorbet/Tapioca actor-specific RBI generation. The corresponding TypeScript
work is tracked in [solid-objects-js#46](https://github.com/cardmagic/solid-objects-js/issues/46).

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
bundle exec ruby -Ilib benchmark/idle_polling.rb
```

SQLite is the default. Set `SOLID_OBJECTS_DATABASE_URL` to benchmark a dedicated
empty PostgreSQL or MySQL database.
