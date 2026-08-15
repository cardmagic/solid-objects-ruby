# Operator dashboard

`SolidObjects::Web` is a Rack application that shows what the actor runtime is
doing: instances and their state, the mailbox, reminders, effects, broadcasts,
dead letters, and the registered processes. It reads the same tables the
runtime writes, so it needs no separate store and no agent.

It is deliberately not loaded by `require "solid_objects"`. A worker process
must not carry a web stack, and an application that never mounts the dashboard
must not pay for it.

## Mounting

```ruby
# config/routes.rb
require "solid_objects/web"

Rails.application.routes.draw do
  mount SolidObjects::Web => "/solid_objects/dashboard"
end
```

Mount it inside the application routes so the Rails session middleware runs
first. The dashboard needs a Rack session for CSRF protection and refuses a
state changing request without one.

The dashboard and the engine are separate mounts. Mount the engine as well if
the application uses reactive ERB, and give each one its own path:

```ruby
mount SolidObjects::Engine => "/solid_objects"
mount SolidObjects::Web => "/solid_objects/dashboard"
```

In a bare Rack application, supply the session middleware yourself:

```ruby
use Rack::Session::Cookie, secret: ENV.fetch("SESSION_SECRET"), same_site: true
run SolidObjects::Web
```

## Authorization

Every page asks `configuration.authorize_administration` before its handler
runs. That policy denies by default, so a mount alone exposes nothing. A route
declared without a policy raises at load time, which is why a new page cannot
reach the actor tables before an application has said who may read it.

The block receives the route's own action and resource:

| Page | `action` | `resource` | `resource_id` |
| --- | --- | --- | --- |
| Dashboard, `GET /stats`, `HEAD /` | `index` | `dashboard` | none |
| Instance list | `index` | `instances` | none |
| Instance detail | `show` | `instances` | instance id |
| Pause an instance | `pause` | `instances` | instance id |
| Resume an instance | `resume` | `instances` | instance id |
| Mailbox | `index` | `messages` | none |
| Message detail | `show` | `messages` | message id |
| Reminders | `index` | `reminders` | none |
| Effects | `index` | `effects` | none |
| Broadcasts | `index` | `broadcasts` | none |
| Dead letter list | `index` | `dead_letters` | none |
| Dead letter detail | `show` | `dead_letters` | dead letter id |
| Retry a dead letter | `retry` | `dead_letters` | dead letter id |
| Processes | `index` | `processes` | none |

`authorization_context:` is the request object. It answers `request`,
`session`, and `env`, so a policy can read the signed-in operator the same way
a controller does:

```ruby
SolidObjects.configure do |configuration|
  configuration.authorize_administration = lambda do |action:, authorization_context:, **|
    return false unless authorization_context.respond_to?(:session)

    operator = Operator.find_by(id: authorization_context.session[:operator_id])
    return false unless operator&.administrator?

    action == "index" || action == "show" || operator.may_write_runtime?
  end
end
```

The command line reaches the same policy with `{ source: "cli" }` rather than
a request, which is why the example checks what the context answers before
reading a session from it.

## Pages

**Dashboard.** Totals per subsystem, the registered processes, and the most
recent dead letters. The summary bar appears on every page and can poll
`GET /stats` for the same numbers; nothing else on the page refreshes, because
a table that reloads under an operator who is reading it is worse than a stale
one.

**Instances.** Filter by actor type and by an actor id substring. Each row
shows the lease state: `idle`, `activated`, `expired`, or `paused`. The detail
page shows committed state, the ready and claimed mailbox, message history,
reminders, effects, broadcasts, and dead letters for that identity.

**Mailbox.** The ready and claimed messages across every identity, oldest
first. Mailbox lag on the summary bar is the age of the oldest message that is
already due, which is how far behind the workers are.

**Reminders, effects, broadcasts, processes.** Status filtered lists.

## Charts

The dashboard draws three charts: instances per actor type, mailbox depth, and
a stacked view of effects, broadcasts, and reminders by status. Each canvas
carries its own numbers in a `data-chart-values` attribute, so the page needs
no inline script and no request to draw. Mailbox depth and the status chart
redraw when the Live poller reports new totals, because `/stats` already
carries those numbers. The instance chart does not: `/stats` does not group by
actor type, and adding that would put a `GROUP BY` on every poll.

Chart.js comes from a CDN with a subresource integrity hash, so a compromised
CDN cannot substitute other code, and the CDN host is the only external origin
the content security policy names.

A deployment with no outbound network access should vendor the file:

```ruby
SolidObjects::Web.chart_library_url = "/javascripts/chart.umd.min.js"
SolidObjects::Web.chart_library_integrity = nil
```

A path below the mount is served from the dashboard's own asset directory and
needs no policy exception. Setting the URL to `nil` renders the dashboard
without charts and names no external origin at all.

Set these before the first request. The middleware stack and the compiled
templates are built once and cached.

**Dead letters.** The exception, its message, and its backtrace, with a retry
button.

## Actions

The dashboard changes only two things.

**Retry a dead letter** goes through `SolidObjects.dead_letters.retry`, which
enqueues the original operation under an idempotency key. Pressing it twice
produces one message rather than two.

A retry re-enters the mailbox, which refuses work the runtime cannot accept: an
actor class that no longer exists, a full mailbox, a payload over the cap. The
dashboard renders the dead letter again with the reason and a 422 status,
rather than failing the request.

**Pause an instance** sets `paused_at`, and the activation manager stops
claiming that identity. Two consequences matter:

- A pass already in flight finishes its turn. Pause is not a stop.
- A synchronous caller waiting on a paused instance times out rather than
  receiving a result, because nothing will execute its message.

Resume clears the column and the mailbox drains in sequence order.

## Extensions

An extension adds pages by declaring routes on the application class. Its
routes carry an authorization policy like every other route:

```ruby
module Tenants
  def self.registered(application)
    application.get "/tenants", policy: { action: "index", resource: "tenants" } do
      @tenants = Tenant.order(:name)
      erb(:tenants)
    end
  end
end

SolidObjects::Web.register(
  Tenants,
  tab: "Tenants",
  path: "/tenants",
  views: File.expand_path("../web/views", __dir__)
)
```

A registered view directory is searched before the packaged one, so an
application can replace a single page without forking the gem. A template
reads its arguments from `locals`, and a replacement `layout.erb` renders the
page it wraps with `locals.fetch(:content)`.

Add Rack middleware in front of the dashboard with `SolidObjects::Web.use`,
for example to require HTTP basic authentication in an environment that has no
session-backed operator.

## Cost

The summary bar issues one grouped count per subsystem on every page, and each
list page counts its own relation to page it. That is a fixed set of indexed
aggregate queries, not a scan proportional to actor traffic, but it is not
free: do not put the dashboard behind an uptime monitor that loads the whole
page on an interval. `HEAD /` exists for that. It touches one table and
returns no body.
