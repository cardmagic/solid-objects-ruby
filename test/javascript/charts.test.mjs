import { strict as assert } from "node:assert"
import { readFileSync } from "node:fs"
import { test } from "node:test"
import { JSDOM } from "jsdom"

const SOURCE = readFileSync(
  new URL("../../web/assets/javascripts/charts.js", import.meta.url),
  "utf8"
)

const INSTANCES = { ShoppingCart: 6, ChatRoom: 4 }
const MAILBOX = { Ready: 12, Due: 9, Claimed: 3 }
const WORK = {
  Effects: { pending: 2, processing: 1, completed: 5, dead: 1 },
  Broadcasts: { pending: 3, processing: 0, delivered: 4, dead: 0 },
  Reminders: { scheduled: 7, paused: 1, completed: 2 }
}

function canvas(name, values) {
  return `<canvas data-chart="${name}" data-chart-values='${JSON.stringify(values)}'></canvas>`
}

// A stand-in for Chart.js that records what the page asked it to draw. The
// real library needs a 2d canvas context jsdom does not provide, and what is
// worth asserting is the data and the axis, not the pixels.
function openCharts(markup) {
  const dom = new JSDOM(`<!doctype html><html><body>${markup}</body></html>`, {
    url: "https://example.test/solid_objects/",
    runScripts: "outside-only"
  })

  const drawn = []
  dom.window.Chart = function (element, configuration) {
    this.data = configuration.data
    this.options = configuration.options
    this.type = configuration.type
    this.updates = 0
    this.update = () => {
      this.updates += 1
    }
    drawn.push(this)
  }

  dom.window.eval(SOURCE)

  return { dom, drawn, close: () => dom.window.close() }
}

function settle() {
  return new Promise((resolve) => setTimeout(resolve, 0))
}

function chartOf(drawn, label) {
  return drawn.find((chart) => chart.data.labels.includes(label))
}

// Arrays built inside the jsdom realm have a different Array.prototype, so
// deepStrictEqual rejects them as not reference-equal. Copying into this
// realm compares the values, which is what these tests are about.
function plain(values) {
  return Array.from(values)
}

test("draws each canvas from the data the page rendered", async () => {
  const charts = openCharts(
    canvas("instances_by_type", INSTANCES) +
      canvas("mailbox_depth", MAILBOX) +
      canvas("work_by_status", WORK)
  )
  try {
    await settle()

    assert.equal(charts.drawn.length, 3)

    const instances = chartOf(charts.drawn, "ShoppingCart")
    assert.deepEqual(plain(instances.data.labels), ["ShoppingCart", "ChatRoom"])
    assert.deepEqual(plain(instances.data.datasets[0].data), [6, 4])
    assert.equal(instances.options.indexAxis, "y")

    const mailbox = chartOf(charts.drawn, "Ready")
    assert.deepEqual(plain(mailbox.data.datasets[0].data), [12, 9, 3])
    assert.equal(mailbox.options.indexAxis, undefined)
  } finally {
    charts.close()
  }
})

test("gives a subsystem a zero for a status it does not have", async () => {
  const charts = openCharts(canvas("work_by_status", WORK))
  try {
    await settle()

    const work = charts.drawn[0]
    const scheduled = work.data.datasets.find((set) => set.label === "scheduled")
    const delivered = work.data.datasets.find((set) => set.label === "delivered")

    assert.deepEqual(plain(work.data.labels), ["Effects", "Broadcasts", "Reminders"])
    // Only reminders are scheduled; only broadcasts are delivered.
    assert.deepEqual(plain(scheduled.data), [0, 0, 7])
    assert.deepEqual(plain(delivered.data), [0, 4, 0])
    assert.equal(work.options.scales.x.stacked, true)
  } finally {
    charts.close()
  }
})

test("redraws the polled charts when the poller reports new totals", async () => {
  const charts = openCharts(
    canvas("instances_by_type", INSTANCES) +
      canvas("mailbox_depth", MAILBOX) +
      canvas("work_by_status", WORK)
  )
  try {
    await settle()
    const instances = chartOf(charts.drawn, "ShoppingCart")
    const mailbox = chartOf(charts.drawn, "Ready")
    const work = chartOf(charts.drawn, "Effects")

    charts.dom.window.document.dispatchEvent(
      new charts.dom.window.CustomEvent("solid-objects:statistics", {
        detail: {
          mailbox: { ready: 1, due: 0, claimed: 5 },
          effects: { pending: 9, processing: 0, completed: 0, dead: 0 },
          broadcasts: { pending: 0, processing: 0, delivered: 0, dead: 2 },
          reminders: { scheduled: 0, paused: 0, completed: 0, due: 4 }
        }
      })
    )

    assert.deepEqual(plain(mailbox.data.datasets[0].data), [1, 0, 5])
    assert.equal(
      work.data.datasets.find((set) => set.label === "pending").data[0],
      9
    )
    assert.equal(mailbox.updates, 1)
    // /stats carries no instance counts, so that chart is left alone.
    assert.equal(instances.updates, 0)
    assert.deepEqual(plain(instances.data.datasets[0].data), [6, 4])
  } finally {
    charts.close()
  }
})

test("leaves the drawn charts alone when a payload is missing a section", async () => {
  const charts = openCharts(canvas("mailbox_depth", MAILBOX))
  try {
    await settle()
    const mailbox = charts.drawn[0]

    charts.dom.window.document.dispatchEvent(
      new charts.dom.window.CustomEvent("solid-objects:statistics", { detail: {} })
    )

    assert.deepEqual(plain(mailbox.data.datasets[0].data), [12, 9, 3])
  } finally {
    charts.close()
  }
})

test("draws nothing when the chart library did not load", async () => {
  const dom = new JSDOM(
    `<!doctype html><html><body>${canvas("mailbox_depth", MAILBOX)}</body></html>`,
    { url: "https://example.test/", runScripts: "outside-only" }
  )
  try {
    dom.window.eval(SOURCE)
    await settle()

    assert.equal(dom.window.document.querySelectorAll("[data-chart]").length, 1)
  } finally {
    dom.window.close()
  }
})

test("skips a canvas whose data attribute is not valid JSON", async () => {
  const charts = openCharts(
    `<canvas data-chart="mailbox_depth" data-chart-values='not json'></canvas>`
  )
  try {
    await settle()

    assert.equal(charts.drawn.length, 0)
  } finally {
    charts.close()
  }
})
