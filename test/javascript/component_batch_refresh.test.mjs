import assert from "node:assert/strict"
import { test, before, beforeEach } from "node:test"
import { openDocument, loadModule, nextTick } from "./browser_test_helper.mjs"

const ENDPOINT = "/solid_objects/components/batch"

let requests
let responder

before(async () => {
  const dom = openDocument()
  dom.window.fetch = async (url) => {
    requests.push(url.toString())
    return responder(url)
  }
  globalThis.fetch = dom.window.fetch
  await loadModule("component_batch_refresh.js")
})

beforeEach(() => {
  document.body.innerHTML = ""
  // Applied frames are appended to documentElement, outside body.
  document.querySelectorAll("turbo-stream").forEach((stream) => stream.remove())
  requests = []
  responder = async () => jsonResponse({ frames: [] })
})

function jsonResponse(body, { ok = true, status = 200 } = {}) {
  return {
    ok,
    status,
    json: async () => body
  }
}

function frameHtml(target, revision) {
  return `<turbo-frame id="${target}" data-solid-objects-revision="${revision}">fresh</turbo-frame>`
}

function addTarget(target, revision) {
  const frame = document.createElement("turbo-frame")
  frame.id = target
  frame.dataset.solidObjectsRevision = revision
  frame.textContent = "stale"
  document.body.append(frame)
  return frame
}

function notify({ batch, revision, targets, tokens }) {
  const element = document.createElement("solid-objects-batch-refresh")
  element.dataset.batch = batch
  element.dataset.revision = revision
  element.dataset.targets = targets.join(" ")
  const query = tokens.map((token) => `tokens[]=${token}`).join("&")
  element.dataset.source = `${ENDPOINT}?instance_id=1&revision=9&${query}`
  document.body.append(element)
  return element
}

test("three components changing together issue one request", async () => {
  notify({ batch: "playmat", revision: "1:9", targets: [ "player" ], tokens: [ "t1" ] })
  notify({ batch: "playmat", revision: "1:9", targets: [ "controls" ], tokens: [ "t2" ] })
  notify({ batch: "playmat", revision: "1:9", targets: [ "library" ], tokens: [ "t3" ] })
  await nextTick()

  assert.equal(requests.length, 1)
})

test("the merged request asks for every changed component", async () => {
  notify({ batch: "playmat", revision: "1:9", targets: [ "player" ], tokens: [ "t1" ] })
  notify({ batch: "playmat", revision: "1:9", targets: [ "controls" ], tokens: [ "t2" ] })
  await nextTick()

  const url = new URL(requests[0], "https://example.test/")
  assert.deepEqual(url.searchParams.getAll("tokens[]").sort(), [ "t1", "t2" ])
})

test("a token requested twice is only sent once", async () => {
  notify({ batch: "playmat", revision: "1:9", targets: [ "player" ], tokens: [ "t1" ] })
  notify({ batch: "playmat", revision: "1:9", targets: [ "player" ], tokens: [ "t1" ] })
  await nextTick()

  const url = new URL(requests[0], "https://example.test/")
  assert.deepEqual(url.searchParams.getAll("tokens[]"), [ "t1" ])
})

test("separate batches issue separate requests", async () => {
  notify({ batch: "playmat", revision: "1:9", targets: [ "player" ], tokens: [ "t1" ] })
  notify({ batch: "sidebar", revision: "1:9", targets: [ "chat" ], tokens: [ "t2" ] })
  await nextTick()

  assert.equal(requests.length, 2)
})

test("a later revision issues its own request", async () => {
  notify({ batch: "playmat", revision: "1:9", targets: [ "player" ], tokens: [ "t1" ] })
  await nextTick()
  notify({ batch: "playmat", revision: "1:10", targets: [ "player" ], tokens: [ "t1" ] })
  await nextTick()

  assert.equal(requests.length, 2)
})

test("applies a newer frame to its target", async () => {
  addTarget("player", "1:8")
  responder = async () => jsonResponse({
    frames: [ { target: "player", revision: "1:9", html: frameHtml("player", "1:9") } ]
  })
  notify({ batch: "playmat", revision: "1:9", targets: [ "player" ], tokens: [ "t1" ] })
  await nextTick()

  const stream = document.querySelector("turbo-stream[target='player']")
  assert.ok(stream, "expected a turbo-stream to be emitted for the target")
})

test("a stale frame cannot overwrite a newer target", async () => {
  addTarget("player", "1:12")
  responder = async () => jsonResponse({
    frames: [ { target: "player", revision: "1:9", html: frameHtml("player", "1:9") } ]
  })
  notify({ batch: "playmat", revision: "1:9", targets: [ "player" ], tokens: [ "t1" ] })
  await nextTick()

  assert.equal(document.querySelector("turbo-stream[target='player']"), null)
})

test("a frame for an absent target is ignored", async () => {
  responder = async () => jsonResponse({
    frames: [ { target: "missing", revision: "1:9", html: frameHtml("missing", "1:9") } ]
  })
  notify({ batch: "playmat", revision: "1:9", targets: [ "missing" ], tokens: [ "t1" ] })
  await nextTick()

  assert.equal(document.querySelector("turbo-stream"), null)
})

test("reports a failed response", async () => {
  const errors = []
  document.addEventListener("solid-objects:batch-refresh-error", (event) => {
    errors.push(event.detail.reason)
  })
  responder = async () => jsonResponse({}, { ok: false, status: 403 })
  notify({ batch: "playmat", revision: "1:9", targets: [ "player" ], tokens: [ "t1" ] })
  await nextTick()

  assert.deepEqual(errors, [ "http_403" ])
})

test("reports a malformed response", async () => {
  const errors = []
  document.addEventListener("solid-objects:batch-refresh-error", (event) => {
    errors.push(event.detail.reason)
  })
  responder = async () => jsonResponse({ frames: "nope" })
  notify({ batch: "playmat", revision: "1:9", targets: [ "player" ], tokens: [ "t1" ] })
  await nextTick()

  assert.deepEqual(errors, [ "invalid_response" ])
})

test("the notification element removes itself", async () => {
  const element = notify({
    batch: "playmat",
    revision: "1:9",
    targets: [ "player" ],
    tokens: [ "t1" ]
  })
  await nextTick()

  assert.equal(element.isConnected, false)
})
