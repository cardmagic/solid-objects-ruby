# Compare Solid Objects with other Rails tools

Each page compares Solid Objects with one tool on one real task. Each page says when the other tool is the better choice. The Solid Objects actor and effect code on each page runs in the test suite.

| Page | The other tool | The task |
| --- | --- | --- |
| [Solid Queue limits_concurrency and Solid Objects](compare/solid-queue.md) | Solid Queue, the Rails 8 default job backend | Ordered billing sync for each customer |
| [GoodJob concurrency controls and Solid Objects](compare/good-job.md) | GoodJob, a PostgreSQL job backend | Ordered billing sync for each customer |
| [Temporal Ruby SDK and Solid Objects](compare/temporal.md) | Temporal, a durable workflow engine (the `temporalio` gem) | Ordered billing sync for each customer, and game rooms with turn timers |

## Choose the smallest tool that works

- The whole rule fits in one request: use a row lock (`with_lock`), a constraint, or a short transaction.
- Independent background work: use a job queue such as Solid Queue or GoodJob.
- One job at a time for each key, order not important: use the concurrency controls of your job queue.
- A long workflow of many steps, with an event history to replay: use a workflow engine such as Temporal.
- Order for each key, state for each key, reminders, and recovery after a restart: use an actor for each key.

The problem guides start from the same choices:

- [Prevent race conditions in Rails](guides/race-conditions.md)
- [Run jobs in order for each customer in Rails](guides/ordered-jobs.md)
- [Expiring reservations](guides/expiring-reservations.md)
- [Save state and queue work together](guides/transactional-outbox.md)

## Status

Solid Objects 1.0.0 shipped on October 13, 2026. The first public release was on August 6, 2026. One first-party application with more than 100,000 users runs it in production. That is a count of users, not a measure of load. No production use by other people is known. See [versioning](versioning.md) and [maintenance and continuity](maintenance.md).
