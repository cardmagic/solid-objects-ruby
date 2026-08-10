import assert from "node:assert/strict"
import { test, before, after, beforeEach } from "node:test"
import { startServer, openPage, loadPage, frameHtml } from "./browser_test_helper.mjs"

// A reconnecting subscription replays the current state as a burst of refresh
// and payload elements. These cover what the channel tests cannot: whether that
// burst converges the live document, and whether a replay of something already
// applied leaves the page alone.
let server
let origin
let browser
let page

const batches = new Map()
const components = new Map()
const cancelled = new Set()

before(async () => {
  const started = await startServer({
    routes: {
      "/solid_objects/components/batch": async (request, response, url) => {
        const token = url.searchParams.get("token")
        // A client abort closes the socket before the response is written, so
        // this is where a cancelled request becomes observable to a test.
        response.on("close", () => {
          if (!response.writableEnded) cancelled.add(token)
        })
        const entry = batches.get(token)
        if (entry) entry.requested = true
        await entry?.gate
        if (response.writableEnded || response.destroyed) return

        response.writeHead(200, { "Content-Type": "application/json" })
        response.end(JSON.stringify({ frames: entry?.frames ?? [] }))
      },
      "/solid_objects/components": (request, response, url) => {
        response.writeHead(200, { "Content-Type": "text/html" })
        response.end(components.get(url.searchParams.get("token")) ?? "")
      }
    }
  })
  server = started.server
  origin = started.origin
  const opened = await openPage(origin)
  browser = opened.browser
  page = opened.page
})

after(async () => {
  await browser?.close()
  server?.close()
})

beforeEach(async () => {
  batches.clear()
  components.clear()
  cancelled.clear()
  await loadPage(page, origin)
})

async function waitFor(condition, message) {
  const deadline = Date.now() + 5000
  while (Date.now() < deadline) {
    if (condition()) return
    await new Promise((resolve) => setTimeout(resolve, 20))
  }
  assert.fail(message)
}

function gate() {
  let release
  const promise = new Promise((resolve) => {
    release = resolve
  })
  return { promise, release }
}

function frame(target, revision, body) {
  return {
    target,
    revision,
    refresh_method: "morph",
    html: frameHtml(target, revision, body)
  }
}

// Mirrors what ComponentSubscriptions transmits: one element per batch,
// carrying every stale target in that batch.
async function replayBatch({ revision, token, targets }) {
  await page.evaluate(({ revision, token, targets }) => {
    const element = document.createElement("solid-objects-batch-refresh")
    element.dataset.batch = "playmat"
    element.dataset.revision = revision
    element.dataset.targets = targets.join(" ")
    const tokens = targets.map((target) => `tokens[]=${target}`).join("&")
    element.dataset.source =
      `/solid_objects/components/batch?token=${token}&${tokens}`
    document.getElementById("solid-objects-scope").append(element)
  }, { revision, token, targets })
}

async function replayComponent({ target, token }) {
  await page.evaluate(({ target, token }) => {
    const element = document.createElement("solid-objects-refresh")
    element.dataset.target = target
    element.dataset.source = `/solid_objects/components?token=${token}`
    element.dataset.refreshMethod = "morph"
    document.getElementById("solid-objects-scope").append(element)
  }, { target, token })
}

async function replayPayload({ name, revision, payload }) {
  await page.evaluate(({ name, revision, payload }) => {
    const element = document.createElement("solid-objects-payload")
    element.dataset.name = name
    element.dataset.revision = revision
    element.textContent = JSON.stringify(payload)
    document.getElementById("solid-objects-scope").append(element)
  }, { name, revision, payload })
}

function textOf(target) {
  return page.evaluate(
    (target) => document.getElementById(target).textContent,
    target
  )
}

function revisionOf(target) {
  return page.evaluate(
    (target) => document.getElementById(target).dataset.solidObjectsRevision,
    target
  )
}

test("a reconnect converges every stale component in one request", async () => {
  batches.set("reconnect", {
    frames: [
      frame("player", "1:12", "current player"),
      frame("controls", "1:12", "current controls")
    ]
  })

  await replayBatch({
    revision: "1:12",
    token: "reconnect",
    targets: [ "player", "controls" ]
  })
  await page.waitForFunction(
    () =>
      document.getElementById("player").dataset.solidObjectsRevision === "1:12" &&
      document.getElementById("controls").dataset.solidObjectsRevision === "1:12",
    null,
    { timeout: 5000 }
  )

  assert.match(await textOf("player"), /current player/)
  assert.match(await textOf("controls"), /current controls/)
})

test("a reconnect converges an unbatched component", async () => {
  components.set("single", frameHtml("player", "1:12", "current player"))

  await replayComponent({ target: "player", token: "single" })
  await page.waitForFunction(
    () => document.getElementById("player").dataset.solidObjectsRevision === "1:12",
    null,
    { timeout: 5000 }
  )

  assert.match(await textOf("player"), /current player/)
})

// A redundant replay must be inert. Morphing a frame that is already current
// would still walk the DOM, discarding anything the page put there since.
test("replaying a revision already applied leaves the frame untouched", async () => {
  batches.set("applied", { frames: [ frame("player", "1:12", "current player") ] })
  await replayBatch({ revision: "1:12", token: "applied", targets: [ "player" ] })
  await page.waitForFunction(
    () => document.getElementById("player").dataset.solidObjectsRevision === "1:12",
    null,
    { timeout: 5000 }
  )
  await page.evaluate(() => {
    const marker = document.createElement("span")
    marker.id = "marker"
    document.getElementById("player").append(marker)
  })

  batches.set("replay", { frames: [ frame("player", "1:12", "current player") ] })
  await replayBatch({ revision: "1:12", token: "replay", targets: [ "player" ] })
  await page.waitForTimeout(300)

  const marker = await page.evaluate(() => Boolean(document.getElementById("marker")))
  assert.equal(marker, true, "a replay at the applied revision should not morph")
})

// A request issued before the drop is still in flight when the reconnect
// arrives. Leaving it running risks its older response landing first and
// flashing stale content, so the reconnect has to cancel it outright.
test("a reconnect cancels the request left in flight by the drop", async () => {
  const stalled = gate()
  batches.set("before-drop", {
    gate: stalled.promise,
    frames: [ frame("player", "1:9", "state from before the drop") ]
  })
  batches.set("after-reconnect", {
    frames: [ frame("player", "1:12", "current player") ]
  })

  await replayBatch({ revision: "1:9", token: "before-drop", targets: [ "player" ] })
  await waitFor(
    () => batches.get("before-drop").requested,
    "the pre-drop request should reach the server"
  )
  await replayBatch({ revision: "1:12", token: "after-reconnect", targets: [ "player" ] })

  await waitFor(
    () => cancelled.has("before-drop"),
    "the reconnect should cancel the request from before the drop"
  )
  await page.waitForFunction(
    () => document.getElementById("player").dataset.solidObjectsRevision === "1:12",
    null,
    { timeout: 5000 }
  )
  stalled.release()
  await page.waitForTimeout(300)

  assert.equal(await revisionOf("player"), "1:12")
  assert.match(await textOf("player"), /current player/)
})

// Destroy and recreate resets the state revision, so the incarnation has to
// decide the ordering. Comparing revisions alone would reject 2:1 after 1:12.
test("a reconnect after a destroy and recreate applies the new incarnation", async () => {
  batches.set("first", { frames: [ frame("player", "1:12", "first incarnation") ] })
  await replayBatch({ revision: "1:12", token: "first", targets: [ "player" ] })
  await page.waitForFunction(
    () => document.getElementById("player").dataset.solidObjectsRevision === "1:12",
    null,
    { timeout: 5000 }
  )

  batches.set("second", { frames: [ frame("player", "2:1", "second incarnation") ] })
  await replayBatch({ revision: "2:1", token: "second", targets: [ "player" ] })
  await page.waitForFunction(
    () => document.getElementById("player").dataset.solidObjectsRevision === "2:1",
    null,
    { timeout: 5000 }
  )

  assert.match(await textOf("player"), /second incarnation/)
})

test("a reconnect delivers each payload revision once", async () => {
  await page.evaluate(() => {
    window.payloads = []
    document.addEventListener("solid-objects:payload", (event) => {
      window.payloads.push([ event.detail.instanceId, event.detail.revision ])
    })
  })

  await replayPayload({ name: "playmat_state", revision: "1:12", payload: { turn: 4 } })
  await replayPayload({ name: "playmat_state", revision: "1:12", payload: { turn: 4 } })
  await replayPayload({ name: "playmat_state", revision: "1:13", payload: { turn: 5 } })
  await page.waitForFunction(() => window.payloads.length >= 2, null, { timeout: 5000 })
  await page.waitForTimeout(200)

  const delivered = await page.evaluate(() => window.payloads)
  assert.deepEqual(delivered, [ [ 1, 12 ], [ 1, 13 ] ])
})

test("a stale payload replayed after a newer one is dropped", async () => {
  await page.evaluate(() => {
    window.payloads = []
    document.addEventListener("solid-objects:payload", (event) => {
      window.payloads.push(event.detail.payload.turn)
    })
  })

  await replayPayload({ name: "playmat_state", revision: "1:13", payload: { turn: 5 } })
  await page.waitForFunction(() => window.payloads.length === 1, null, { timeout: 5000 })
  await replayPayload({ name: "playmat_state", revision: "1:12", payload: { turn: 4 } })
  await page.waitForTimeout(200)

  assert.deepEqual(await page.evaluate(() => window.payloads), [ 5 ])
})

test("a reconnect burst applies alongside a payload in the same scope", async () => {
  await page.evaluate(() => {
    window.payloads = []
    document.addEventListener("solid-objects:payload", (event) => {
      window.payloads.push(event.detail.revision)
    })
  })
  batches.set("burst", {
    frames: [
      frame("player", "1:12", "current player"),
      frame("controls", "1:12", "current controls")
    ]
  })

  await replayBatch({
    revision: "1:12",
    token: "burst",
    targets: [ "player", "controls" ]
  })
  await replayPayload({ name: "playmat_state", revision: "1:12", payload: { turn: 4 } })
  await page.waitForFunction(
    () =>
      window.payloads.length === 1 &&
      document.getElementById("controls").dataset.solidObjectsRevision === "1:12",
    null,
    { timeout: 5000 }
  )

  assert.equal(await revisionOf("player"), "1:12")
  assert.deepEqual(await page.evaluate(() => window.payloads), [ 12 ])
})
