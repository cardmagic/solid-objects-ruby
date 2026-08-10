# Local testing

The default suite runs against SQLite and needs nothing extra:

```bash
bundle exec rake
```

Everything below is optional. Each adapter and each optional service skips its
tests when the service is absent, so a missing container degrades coverage
rather than breaking the run. That is convenient, and it is also a trap: a
skipped test looks identical to a passing one in the summary line. Check the
skip count when a change touches an adapter.

## PostgreSQL

```bash
brew services start postgresql@17
createuser -h 127.0.0.1 -s solid_objects
psql -h 127.0.0.1 -d postgres -c "ALTER USER solid_objects WITH PASSWORD 'solid_objects';"
createdb -h 127.0.0.1 -O solid_objects solid_objects_test

SOLID_OBJECTS_DATABASE_URL=postgresql://solid_objects:solid_objects@127.0.0.1:5432/solid_objects_test \
  bundle exec rake test
```

Running this locally is worth the setup: it is what caught the PostgreSQL
version comparison reading a packed integer, where `170010` compared greater
than any minimum and made the check useless on the adapter it mattered most for.

## MySQL and Redis in Docker

These use non-default ports so they cannot collide with a MySQL or Redis that
another project is already running:

```bash
docker run -d --name so-mysql -p 3307:3306 \
  -e MYSQL_ROOT_PASSWORD=solid_objects \
  -e MYSQL_DATABASE=solid_objects_test \
  -e MYSQL_USER=solid_objects \
  -e MYSQL_PASSWORD=solid_objects \
  mysql:8

docker run -d --name so-redis -p 6380:6379 redis:7-alpine
```

```bash
SOLID_OBJECTS_DATABASE_URL=mysql2://solid_objects:solid_objects@127.0.0.1:3307/solid_objects_test \
  bundle exec rake test

SOLID_OBJECTS_DATABASE_URL=trilogy://solid_objects:solid_objects@127.0.0.1:3307/solid_objects_test \
  bundle exec rake test

SOLID_OBJECTS_REDIS_URL=redis://127.0.0.1:6380/15 \
  bundle exec rake test TEST=test/integration/redis_wake_up_test.rb
```

Run both MySQL clients. They report different adapter names, negotiate
different connection collations, and name the same error code differently, so a
pass on one says nothing about the other. Recreate the database between them.

Stop them with `docker rm -f so-mysql so-redis`.

## Recreating a database between runs

The test helper migrates unconditionally, so a second run against a database
that already has the tables fails with a duplicate-table error rather than a
test failure. Recreate first:

```bash
dropdb -h 127.0.0.1 solid_objects_test && createdb -h 127.0.0.1 -O solid_objects solid_objects_test

docker exec so-mysql mysql -u root -psolid_objects \
  -e "DROP DATABASE IF EXISTS solid_objects_test; CREATE DATABASE solid_objects_test;
      GRANT ALL ON solid_objects_test.* TO 'solid_objects'@'%';"
```

## Rails and Ruby span

`RAILS_VERSION` pins the Rails line the gemspec advertises:

```bash
RAILS_VERSION=8.0 bundle install
RAILS_VERSION=8.0 bundle exec rake test
```

## Browser modules

```bash
npm install
npm test                                  # jsdom, fast
npx playwright install chromium
npm run test:browser                      # real Chromium and a real Turbo build
```

The jsdom suite covers logic; the browser suite covers integration with Turbo.
Both matter: every batching defect that reached production passed the jsdom
suite alone.
