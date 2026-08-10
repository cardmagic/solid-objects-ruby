# Repository Guidelines

## Project Structure & Module Organization

Runtime code lives in `lib/solid_objects/`; engine models, controllers, and helpers live under `app/`. Migrations are in `db/migrate/`, the executable is `exe/solid_objects`, and generated RBS signatures are in `sig/generated/`. Tests live under `test/`. `examples/`, `benchmark/`, and `docs/` hold samples, performance scripts, and guidance.

## Build, Test, and Development Commands

- `bundle install` installs development dependencies.
- `bundle exec rake test` runs the Minitest suite against SQLite.
- `SOLID_OBJECTS_DATABASE_URL=postgresql://... bundle exec rake test` runs PostgreSQL tests; use a `mysql2://...` URL for MySQL.
- `bundle exec rake` runs tests, Standard Ruby, RuboCop, RBS generation and validation, Steep, and Brakeman.
- `bundle exec rake rbs` regenerates `sig/generated/` from inline annotations.

Use dedicated, empty databases for adapter tests and benchmarks.

## Coding Style & Naming Conventions

Target Ruby 3.3+ and Rails 8+. Use two-space indentation and let Standard Ruby plus the Solid Queue-derived RuboCop policy decide formatting. Prefer descriptive `snake_case` methods and variables, `CamelCase` constants, early returns, and keyword shorthand such as `Message.new(actor_id:)`. Avoid boolean parameters and abbreviations.

Every owned Ruby file must enable inline RBS with `# rbs_inline: enabled`; annotate methods and instance variables using `# @rbs`. Keep database behavior portable across SQLite, PostgreSQL, and MySQL. Model queue state through table membership rather than partial indexes.

## Testing Guidelines

Write Minitest files as `test/**/*_test.rb`. Start behavioral changes with a focused failing test. Exercise locking, leases, fencing, and claiming against real database adapters. Synchronize races with queues, barriers, or condition variables instead of arbitrary sleeps. Host-app actor tests should include `SolidObjects::TestHelper` rather than rely on transactional tests.

## Commit & Pull Request Guidelines

Use concise imperative subjects, preferably under 50 characters; use prefixes such as `fix:`, `ci:`, or `chore:`. Pull requests should explain API, correctness, security, migration, and compatibility effects; list exact validation commands; link issues; and include screenshots for UI or reactive ERB changes. Never bypass hooks or add AI attribution.

Update `docs/roadmap.md` in the same pull request whenever the change alters
what the project claims about itself. That includes completing or advancing a
numbered milestone, moving an entry between "Implemented and tested" and
"Partially implemented", and discovering a limitation worth recording, such as a
capability that turns out to be opt-in, adapter-specific, or measured rather
than assumed. Prefer correcting a stale entry over only appending a new one: an
inaccurate claim misleads more than a missing one. State what was measured and
what was not, so a reader can tell evidence from intent. A change that only
fixes a defect, adjusts tooling, or edits prose does not need a roadmap edit.

## Release Workflow

Update the version, `CHANGELOG.md`, and `Gemfile.lock`; run `bundle exec rake`; then commit and push `main`. Publish by pushing an annotated version tag:

```bash
git tag -a v0.5.0 -m "Version 0.5.0"
git push origin v0.5.0
```

CI validates the tag and publishes through RubyGems trusted publishing.

## Security & Configuration

Preserve deny-by-default authorization. Never treat actor IDs, stream names, or signed tokens as authorization, and never commit secrets or unsafe deserialization paths.
