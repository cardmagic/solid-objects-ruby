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

Target Ruby 3.3+ and Rails 7.1+. Use two-space indentation and let Standard Ruby plus the Solid Queue-derived RuboCop policy decide formatting. Prefer descriptive `snake_case` methods and variables, `CamelCase` constants, early returns, and keyword shorthand such as `Message.new(actor_id:)`. Avoid boolean parameters and abbreviations.

Every owned Ruby file must enable inline RBS with `# rbs_inline: enabled`; annotate methods and instance variables using `# @rbs`. Keep database behavior portable across SQLite, PostgreSQL, and MySQL. Model queue state through table membership rather than partial indexes.

## Testing Guidelines

Write Minitest files as `test/**/*_test.rb`. Start behavioral changes with a focused failing test. Exercise locking, leases, fencing, and claiming against real database adapters. Synchronize races with queues, barriers, or condition variables instead of arbitrary sleeps. Host-app actor tests should include `SolidObjects::TestHelper` rather than rely on transactional tests.

Watch the test fail before making it pass, and quote the observed failure in the pull request. A test that has never failed has not been shown to test anything, and the ways it can pass while proving nothing are not exotic: a regression test written after the fix, a double that lacks the `ensure` its real collaborator runs, a mock that ignores the signal under test, or a second guard that covers for the one being removed. When a change fixes a defect, revert the fix and confirm the test fails for the expected reason rather than some other one.

Run code in the process and environment it actually runs in. A runtime role gets only what `require "solid_objects"` defines, so verify it through `solid_objects start` rather than in a test process that has already loaded the constant it needs; `test/integration/load_contract_test.rb` enforces that boundary and is the place to record a deliberate exception. Browser modules go through a real browser as well as jsdom. Adapter behavior goes through the real database and every supported client, and because a skipped test looks exactly like a passing one in the summary line, check the skip count when a change touches an adapter.

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

A release goes through a pull request and then a version tag. Do not push a
release commit directly to `main`.

1. In a pull request, add a commit with the subject
   `chore: prepare version X.Y.Z`. The commit updates
   `lib/solid_objects/version.rb`, the `CHANGELOG.md` section for the version,
   and `Gemfile.lock`.
2. Read `docs/virtual-actors.md` and `docs/agents.md` against the release.
   Correct each requirement, compatibility, or guarantee statement that changed.
3. Run `bundle exec rake` before you push.
4. Get a Greptile 5/5 summary on the head commit, green CI, and the approval of
   the maintainer. Then merge the pull request with a merge commit.
5. Tag the merge commit on `main` and push the tag:

   ```bash
   git tag -a vX.Y.Z -m "Version X.Y.Z"
   git push origin vX.Y.Z
   ```

   CI validates the tag and publishes through RubyGems trusted publishing.
6. After the gem is on RubyGems, update and deploy solidobjects.dev with the
   workspace `solid-objects-tag-to-prod` skill. Refresh the documentation
   snapshot from the tag. The `check:release` step of the site refuses a
   snapshot that is not the latest published tag.

Before 1.0, a feature or a behavior change gets a minor version, and a fix gets
a patch version.

The Context7 refresh workflow refreshes the index after each push to `main` that
changes the documentation. Confirm that its run succeeded.

## Security & Configuration

Preserve deny-by-default authorization. Never treat actor IDs, stream names, or signed tokens as authorization, and never commit secrets or unsafe deserialization paths.
