import assert from "node:assert/strict"
import { test, before, after } from "node:test"
import { startServer, openPage, frameHtml } from "./browser_test_helper.mjs"

// These exercise what jsdom cannot: Turbo's own stream processing applying a
// morph to a live document. Every batching defect that reached production
// passed the jsdom suite.
let server
let origin
let browser
let page

const responses = new Map()

before(async () => {
  const started = await startServer({
    routes: {
      "/solid_objects/components": (request, response, url) => {
        const body = responses.get(url.searchParams.get("token")) ?? ""
        response.writeHead(200, { "Content-Type": "text/html" })
        response.end(body)
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

async function reset() {
  await page.evaluate(() => {
    document.querySelectorAll("turbo-stream").forEach((node) => node.remove())
    document.getElementById("player").dataset.solidObjectsRevision = "1:8"
    document.getElementById("player").textContent = "stale player"
  })
}

async function refresh({ target, revision, token }) {
  await page.evaluate(({ target, revision, token }) => {
    const element = document.createElement("solid-objects-refresh")
    element.dataset.target = target
    element.dataset.source = `/solid_objects/components?token=${token}&instance_id=1&revision=${revision}`
    element.dataset.refreshMethod = "morph"
    document.getElementById("solid-objects-scope").append(element)
  }, { target, revision, token })
}

test("a morph refresh replaces the frame content in a real browser", async () => {
  await reset()
  responses.set("fresh", frameHtml("player", "1:9", "fresh player"))

  await refresh({ target: "player", revision: 9, token: "fresh" })
  await page.waitForFunction(
    () => document.getElementById("player").textContent.includes("fresh player"),
    null,
    { timeout: 5000 }
  )

  const revision = await page.evaluate(
    () => document.getElementById("player").dataset.solidObjectsRevision
  )
  assert.equal(revision, "1:9")
})

test("a stale response cannot overwrite a newer frame", async () => {
  await reset()
  await page.evaluate(() => {
    document.getElementById("player").dataset.solidObjectsRevision = "1:12"
    document.getElementById("player").textContent = "newer player"
  })
  responses.set("stale", frameHtml("player", "1:9", "stale response"))

  await refresh({ target: "player", revision: 9, token: "stale" })
  await page.waitForTimeout(300)

  const text = await page.evaluate(() => document.getElementById("player").textContent)
  assert.match(text, /newer player/)
})

test("the refresh element removes itself once applied", async () => {
  await reset()
  responses.set("cleanup", frameHtml("player", "1:9", "applied"))

  await refresh({ target: "player", revision: 9, token: "cleanup" })
  await page.waitForFunction(
    () => document.querySelectorAll("solid-objects-refresh").length === 0,
    null,
    { timeout: 5000 }
  )

  const remaining = await page.evaluate(
    () => document.querySelectorAll("solid-objects-refresh").length
  )
  assert.equal(remaining, 0)
})

test("a response without the target frame reports an error", async () => {
  await reset()
  responses.set("missing", "<div>no frame here</div>")
  await page.evaluate(() => {
    window.refreshErrors = []
    document.addEventListener("solid-objects:component-refresh-error", (event) => {
      window.refreshErrors.push(event.detail.reason)
    })
  })

  await refresh({ target: "player", revision: 9, token: "missing" })
  await page.waitForFunction(() => window.refreshErrors?.length > 0, null, { timeout: 5000 })

  const errors = await page.evaluate(() => window.refreshErrors)
  assert.deepEqual(errors, [ "missing_frame" ])
})

test("morph preserves an element marked permanent", async () => {
  await reset()
  await page.evaluate(() => {
    const target = document.getElementById("player")
    target.innerHTML = '<input id="typed" data-turbo-permanent value="">'
    document.getElementById("typed").value = "user typing"
  })
  responses.set(
    "permanent",
    frameHtml("player", "1:9", '<input id="typed" data-turbo-permanent value="">')
  )

  await refresh({ target: "player", revision: 9, token: "permanent" })
  await page.waitForFunction(
    () => document.getElementById("player").dataset.solidObjectsRevision === "1:9",
    null,
    { timeout: 5000 }
  )

  const typed = await page.evaluate(() => document.getElementById("typed")?.value)
  assert.equal(typed, "user typing", "morph should preserve permanent elements")
})
