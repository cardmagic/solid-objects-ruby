# Contributing

Solid Objects changes can affect durable state and recovery. A contribution
should explain the invariant it changes and include a regression test at the
lowest layer that can prove it.

## Setup

Install Ruby 3.3 or newer and Rails 7.1 or newer, then install the locked
dependencies:

```bash
bundle install
```

The full database matrix needs SQLite 3.35 or newer, PostgreSQL 14 or newer,
and MySQL 8.0 or newer on InnoDB. Use disposable databases. Do not include
credentials, production data, customer identifiers, or other personal
information in fixtures or reports.

## Validation

Run the local quality gates before opening a pull request. `bundle exec rake`
runs the Minitest suite against SQLite, Standard Ruby, the Solid Queue RuboCop
policy, RBS generation and validation, Steep, and Brakeman:

```bash
bundle exec rake
```

Run the adapter suites against a real server before changing anything that
touches locking, claiming, or schema:

```bash
SOLID_OBJECTS_DATABASE_URL=postgresql://localhost/solid_objects_test bundle exec rake test
SOLID_OBJECTS_DATABASE_URL=mysql2://localhost/solid_objects_test bundle exec rake test
```

A skipped test looks exactly like a passing one in the summary line, so check
the skip count when a change touches an adapter.

## Writing the test first

Start a behavioral change with a focused failing test, watch it fail, and quote
the observed failure in the pull request. A test that has never failed has not
been shown to test anything. When a change fixes a defect, revert the fix and
confirm the test fails for the expected reason rather than some other one.

Exercise locking, leases, fencing, and claiming against real database adapters.
Synchronize races with queues, barriers, or condition variables instead of
arbitrary sleeps.

## Correctness changes

For mailbox, lease, fencing, retry, effect, reminder, or migration changes,
include the failure sequence the test exercises. Update
[Correctness and delivery semantics](docs/correctness.md) when a guarantee or
limitation changes, and [the roadmap](docs/roadmap.md) when the change alters
what the project claims about itself.

## Style

Ruby source carries inline RBS annotations, so every owned file enables
`# rbs_inline: enabled` and annotates methods with `# @rbs`. Prefer early
returns, descriptive names over abbreviations, and options over boolean
parameters. Keep database behavior portable across SQLite, PostgreSQL, and
MySQL.

Use concise imperative commit subjects under 50 characters, prefixed with
`fix:`, `docs:`, `ci:`, or `chore:` where one applies. Explain why the change
is needed rather than restating what it does.

## Reporting a vulnerability

Report security issues privately through
[GitHub security advisories](https://github.com/cardmagic/solid-objects-ruby/security/advisories/new)
rather than a public issue.
