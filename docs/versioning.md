# Versioning

From version 1.0.0, Solid Objects follows
[Semantic Versioning](https://semver.org/).

## The promise

The public API is the set of classes, methods, generators, commands, and
configuration options that `README.md` and the files in `docs/` describe.

| Release | What it can change |
| --- | --- |
| Patch, for example 1.0.1 | Corrections of defects. No new behavior |
| Minor, for example 1.1.0 | New behavior. Code that uses the public API continues to work |
| Major, for example 2.0.0 | A change that breaks code that uses the public API |

## Supported versions

A minor release can raise the minimum version of Ruby, Rails, SQLite,
PostgreSQL, or MySQL. It does this only for a version that its own project no
longer supports, and `CHANGELOG.md` names the change. A patch release does not
raise a minimum version.
[Compatibility and maturity](virtual-actors.md#compatibility-and-maturity)
lists the current minimum versions.

## Outside the promise

- Classes, methods, and constants that the documentation does not describe.
- The database schema. A minor release can add tables, columns, and indexes,
  and it supplies a migration for each change.
  [Installing and upgrading](operations.md#installing-and-upgrading) gives the
  steps.
- The text of error messages and log lines. The error classes are part of the
  public API.
- The timing of background work, where no configuration option sets it.
- A correction of behavior that is different from the
  [correctness contract](correctness.md). A patch release can make such a
  correction.

## What version 1.0 does not claim

Version 1.0 is a promise about the API. It is not a claim of measured scale.
The [benchmarks](benchmarks.md) are development measurements and do not
guarantee capacity. Longer soak tests are open work. No production use by
other people is known.

## Releases before 1.0

The 0.x releases changed the API between minor versions. `CHANGELOG.md` lists
each change.
