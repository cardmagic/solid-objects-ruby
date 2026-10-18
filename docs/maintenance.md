# Maintenance and continuity

This page tells you who maintains Solid Objects, how a release is made, and
what you keep if maintenance stops. It also tells you how to help maintain the
project.

## Who maintains it

Lucas Carlson ([@cardmagic](https://github.com/cardmagic)) is the lead
maintainer of the Ruby gem `solid_objects` and of the npm package
[`solid-objects`](https://github.com/cardmagic/solid-objects-js). The two
packages use the same model and the same correctness contract. A change to the
model goes into both packages, and the
[parity ledger](https://github.com/cardmagic/solid-objects-js/blob/main/docs/parity.md)
records each difference between them.

The same maintainer sells [Solid Objects Pro](https://solidobjects.pro), a
commercial package that batches operations at scale. Pro depends on this gem.
This gem does not depend on Pro, and it needs no account, license key, or
service from the maintainer.

## How a change is checked

CI runs on each push and each pull request:

- The full test suite on SQLite, on each pair of Ruby 3.3, 3.4, or 4.0 and
  Rails 7.1, 7.2, 8.0, or 8.1.
- The full test suite on PostgreSQL and on MySQL, with both MySQL clients.
- Standard, RuboCop, RBS, Steep, and Brakeman.

[Compatibility and maturity](virtual-actors.md#compatibility-and-maturity)
lists the supported versions. The [correctness contract](correctness.md) lists
the guarantees that the tests check.

## How a release is made

1. The maintainer pushes a version tag, for example `v1.0.3`.
2. GitHub Actions runs all test jobs again on that tag.
3. If all test jobs pass, GitHub Actions builds the gem and pushes it to
   RubyGems with trusted publishing. The repository keeps no RubyGems key.
4. The same job makes a GitHub release and attaches the gem file.

[Versioning](versioning.md) tells you what a release can change.
`CHANGELOG.md` lists each release.

## What you keep if maintenance stops

- **Your data.** Actor state, mailboxes, reminders, and effects are rows in
  your application's database. [Database schema](database-schema.md) describes
  each table. No service of the maintainer holds your data.
- **The code.** The [MIT License](../MIT-LICENSE) lets anyone use, change,
  fork, and publish the code.
- **The checks.** The tests and the CI configuration are in this repository. A
  fork can check its changes with the same suite.

## Help maintain Solid Objects

The project wants more maintainers. Experience with Rails, with locks and
transactions in PostgreSQL or MySQL, or with TypeScript and Node.js helps.

1. Read [CONTRIBUTING.md](../CONTRIBUTING.md).
2. Send a small pull request: a fix, a test, or a correction to a guide.
3. After some of your pull requests are merged, open an
   [issue](https://github.com/cardmagic/solid-objects-ruby/issues) to ask to
   become a maintainer.
