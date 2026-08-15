import { strict as assert } from "node:assert"
import { readFileSync } from "node:fs"
import { test } from "node:test"
import { JSDOM } from "jsdom"

const SOURCE = readFileSync(
  new URL("../../web/assets/javascripts/application.js", import.meta.url),
  "utf8"
)

// The same numbers SolidObjects::Web::Helpers renders on the server. The
// polled cell sits beside server-rendered ones, so the two formatters have to
// agree; test/unit/web_helpers_test.rb asserts the Ruby side of this table.
const DURATIONS = [
  { value: 0, rendered: "0.000 s" },
  { value: 4.25, rendered: "4.250 s" },
  { value: 59.999, rendered: "59.999 s" },
  { value: 60, rendered: "1 min 0 s" },
  { value: 511.892, rendered: "8 min 32 s" }
]

const BODY = `<body data-stats-path="/stats">
  <button data-poll-toggle aria-pressed="false">Live</button>
  <span data-statistic="instances.total">0</span>
  <span data-statistic="mailbox.latency" data-format="duration">0.000 s</span>
  <span data-statistic="missing.path">untouched</span>
</body>`

function settle() {
  return new Promise((resolve) => setTimeout(resolve, 0))
}

// The window owns the poll interval, so a suite that leaves one open holds the
// Node event loop and the whole run hangs rather than fails.
//
// Async because the tag is deferred: the script binds the toggle on
// DOMContentLoaded, which jsdom fires a tick after the document is built. A
// click issued before that tick lands on nothing.
async function openDashboard(payload, { failing = false } = {}) {
  const dom = new JSDOM(`<!doctype html><html>${BODY}</html>`, {
    url: "https://example.test/solid_objects/",
    runScripts: "outside-only"
  })

  const requests = []
  dom.window.fetch = (path, options) => {
    requests.push({ path, options })
    if (failing) return Promise.reject(new Error("offline"))

    return Promise.resolve({ ok: true, json: () => Promise.resolve(payload) })
  }
  dom.window.eval(SOURCE)
  await settle()

  return {
    dom,
    requests,
    toggle: dom.window.document.querySelector("[data-poll-toggle]"),
    cell: (name) => dom.window.document.querySelector(`[data-statistic="${name}"]`),
    close: () => dom.window.close()
  }
}

test("polls nothing until the toggle is pressed", async () => {
  const dashboard = await openDashboard({ instances: { total: 5 } })
  try {
    await settle()

    assert.equal(dashboard.requests.length, 0)
    assert.equal(dashboard.cell("instances.total").textContent, "0")
  } finally {
    dashboard.close()
  }
})

test("polls the stats path once per press and updates cells", async () => {
  const dashboard = await openDashboard({
    instances: { total: 1234567 },
    mailbox: { latency: 511.892 }
  })
  try {
    dashboard.toggle.click()
    await settle()

    assert.equal(dashboard.requests.length, 1)
    assert.equal(dashboard.requests[0].path, "/stats")
    assert.equal(dashboard.requests[0].options.credentials, "same-origin")
    assert.equal(dashboard.toggle.getAttribute("aria-pressed"), "true")
    assert.equal(dashboard.cell("instances.total").textContent, "1,234,567")
    assert.equal(dashboard.cell("mailbox.latency").textContent, "8 min 32 s")
  } finally {
    dashboard.close()
  }
})

test("a cell whose path is absent from the payload keeps its rendered value", async () => {
  const dashboard = await openDashboard({ instances: { total: 2 } })
  try {
    dashboard.toggle.click()
    await settle()

    assert.equal(dashboard.cell("missing.path").textContent, "untouched")
    assert.equal(dashboard.cell("mailbox.latency").textContent, "0.000 s")
  } finally {
    dashboard.close()
  }
})

test("a failed poll leaves the last rendered totals in place", async () => {
  const dashboard = await openDashboard({ instances: { total: 2 } }, { failing: true })
  try {
    dashboard.toggle.click()
    await settle()

    assert.equal(dashboard.requests.length, 1)
    assert.equal(dashboard.cell("instances.total").textContent, "0")
  } finally {
    dashboard.close()
  }
})

test("pressing the toggle again stops polling", async () => {
  const dashboard = await openDashboard({ instances: { total: 3 } })
  try {
    dashboard.toggle.click()
    await settle()
    const polled = dashboard.requests.length
    dashboard.toggle.click()
    await settle()

    assert.equal(dashboard.toggle.getAttribute("aria-pressed"), "false")
    assert.equal(dashboard.requests.length, polled)
  } finally {
    dashboard.close()
  }
})

test("formats a duration the way the server rendered it", async () => {
  for (const { value, rendered } of DURATIONS) {
    const dashboard = await openDashboard({ mailbox: { latency: value } })
    try {
      dashboard.toggle.click()
      await settle()

      assert.equal(
        dashboard.cell("mailbox.latency").textContent,
        rendered,
        `${value} must render as ${rendered}`
      )
    } finally {
      dashboard.close()
    }
  }
})

test("formats a count without turning it into a duration", async () => {
  const dashboard = await openDashboard({ instances: { total: 0 } })
  try {
    dashboard.toggle.click()
    await settle()

    assert.equal(dashboard.cell("instances.total").textContent, "0")
  } finally {
    dashboard.close()
  }
})
