import assert from "node:assert/strict"
import { test, before, beforeEach } from "node:test"
import { openDocument, loadModule, nextTick } from "./browser_test_helper.mjs"

const ENDPOINT = "/solid_objects/components/batch"
const ORIGIN = "https://example.test/"

let requests
let aborted
let responder
let recordedErrors
let defaultScope
let run = 0

before(async () => {
  const dom = openDocument()
  // Honour the abort signal, otherwise cancelled requests still resolve and no
  // test can observe cancellation.
  dom.window.fetch = async (url, options = {}) => {
    requests.push(url.toString())
    const signal = options.signal
    if (signal?.aborted) throw abortError()

    return Promise.race([
      responder(url),
      new Promise((_resolve, reject) => {
        signal?.addEventListener("abort", () => {
          aborted.push(url.toString())
          reject(abortError())
        })
      })
    ])
  }
  globalThis.fetch = dom.window.fetch
  // Registered once; re-registering per test would record each error N times.
  dom.window.document.addEventListener(
    "solid-objects:batch-refresh-error",
    (event) => recordedErrors.push(event.detail.reason)
  )
  await loadModule("component_batch_refresh.js")
})

beforeEach(() => {
  document.body.innerHTML = ""
  document.querySelectorAll("turbo-stream").forEach((stream) => stream.remove())
  requests = []
  aborted = []
  recordedErrors = []
  // Scope and target identity are page-lifetime state in the module, so each
  // test needs its own names.
  run += 1
  defaultScope = scopeNamed(id("scope"))
})

function id(name) {
  return `${name}-${run}`
}

function abortError() {
  const error = new Error("aborted")
  error.name = "AbortError"
  return error
}

function jsonResponse(body, { ok = true, status = 200 } = {}) {
  return { ok, status, json: async () => body }
}

function frameHtml(target, revision) {
  return `<turbo-frame id="${target}" data-solid-objects-revision="${revision}">fresh</turbo-frame>`
}

function scopeNamed(name) {
  const scope = document.createElement("div")
  scope.id = name
  document.body.append(scope)
  return scope
}

function addTarget(target, revision) {
  const frame = document.createElement("turbo-frame")
  frame.id = target
  frame.dataset.solidObjectsRevision = revision
  frame.textContent = "stale"
  document.body.append(frame)
  return frame
}

function notify({ revision, tokens, scope, batch = "playmat", queryRevision = "9" }) {
  const element = document.createElement("solid-objects-batch-refresh")
  element.dataset.batch = batch
  element.dataset.revision = revision
  element.dataset.targets = tokens.join(" ")
  const query = tokens.map((token) => `tokens[]=${token}`).join("&")
  element.dataset.source = `${ENDPOINT}?instance_id=1&revision=${queryRevision}&${query}`
  ;(scope ?? defaultScope).append(element)
  return element
}

function appliedTargets() {
  return [ ...document.querySelectorAll("turbo-stream") ].map(
    (stream) => stream.getAttribute("target")
  )
}

function tokensIn(request) {
  return new URL(request, ORIGIN).searchParams.getAll("tokens[]")
}

// Answers each request with a frame per requested token, after a delay so that
// responses are genuinely in flight when the next notification arrives.
function respondPerToken({ revision = "1:9", delay = 15 } = {}) {
  responder = async (url) => {
    await new Promise((resolve) => setTimeout(resolve, delay))
    return jsonResponse({
      frames: tokensIn(url).map((token) => ({
        target: token,
        revision,
        html: frameHtml(token, revision)
      }))
    })
  }
}

function settle(milliseconds = 80) {
  return new Promise((resolve) => setTimeout(resolve, milliseconds))
}

test("three same-revision invalidations in separate tasks all get applied", async () => {
  const targets = [ id("player"), id("controls"), id("library") ]
  targets.forEach((target) => addTarget(target, "1:8"))
  respondPerToken()

  for (const target of targets) {
    notify({ revision: "1:9", tokens: [ target ] })
    await nextTick()
  }
  await settle()

  assert.deepEqual(appliedTargets().sort(), [ ...targets ].sort())
})

test("a same-revision request does not abort another same-revision request", async () => {
  respondPerToken({ delay: 20 })

  notify({ revision: "1:9", tokens: [ id("player") ] })
  await nextTick()
  notify({ revision: "1:9", tokens: [ id("controls") ] })
  await nextTick()
  await settle()

  assert.equal(requests.length, 2)
  assert.deepEqual(recordedErrors, [])
})

test("a newer revision supersedes an in-flight older request", async () => {
  const target = id("player")
  addTarget(target, "1:8")
  responder = async (url) => {
    const queryRevision = new URL(url, ORIGIN).searchParams.get("revision")
    await new Promise((resolve) => setTimeout(resolve, 25))
    return jsonResponse({
      frames: [ {
        target,
        revision: `1:${queryRevision}`,
        html: frameHtml(target, `1:${queryRevision}`)
      } ]
    })
  }

  notify({ revision: "1:9", tokens: [ target ], queryRevision: "9" })
  await nextTick()
  notify({ revision: "1:10", tokens: [ target ], queryRevision: "10" })
  await settle(120)

  assert.deepEqual(appliedTargets(), [ target ])
})

test("an older frame cannot overwrite a newer target", async () => {
  const target = id("player")
  addTarget(target, "1:12")
  responder = async () => jsonResponse({
    frames: [ { target, revision: "1:9", html: frameHtml(target, "1:9") } ]
  })

  notify({ revision: "1:9", tokens: [ target ] })
  await settle(40)

  assert.deepEqual(appliedTargets(), [])
})

test("a duplicate frame is applied only once", async () => {
  const target = id("player")
  addTarget(target, "1:8")
  respondPerToken({ delay: 5 })

  notify({ revision: "1:9", tokens: [ target ] })
  await nextTick()
  notify({ revision: "1:9", tokens: [ target ] })
  await settle()

  assert.deepEqual(appliedTargets(), [ target ])
})

test("notifications merged in one task issue a single request", async () => {
  respondPerToken({ delay: 5 })

  notify({ revision: "1:9", tokens: [ id("player") ] })
  notify({ revision: "1:9", tokens: [ id("controls") ] })
  notify({ revision: "1:9", tokens: [ id("library") ] })
  await settle()

  assert.equal(requests.length, 1)
})

test("duplicate tokens are sent only once", async () => {
  respondPerToken({ delay: 5 })

  notify({ revision: "1:9", tokens: [ id("player") ] })
  notify({ revision: "1:9", tokens: [ id("player") ] })
  await settle()

  assert.deepEqual(tokensIn(requests[0]), [ id("player") ])
})

test("different scopes stay isolated", async () => {
  const other = scopeNamed(id("other-scope"))
  respondPerToken({ delay: 20 })

  notify({ revision: "1:9", tokens: [ id("player") ] })
  notify({ revision: "1:9", tokens: [ id("chat") ], scope: other })
  await settle()

  assert.equal(requests.length, 2)
  assert.deepEqual(recordedErrors, [])
})

test("different batch names stay independent", async () => {
  respondPerToken({ delay: 20 })

  notify({ revision: "1:9", tokens: [ id("player") ] })
  notify({ revision: "1:9", tokens: [ id("chat") ], batch: "sidebar" })
  await settle()

  assert.equal(requests.length, 2)
})

test("a frame for an absent target is ignored", async () => {
  responder = async () => jsonResponse({
    frames: [ { target: id("missing"), revision: "1:9", html: frameHtml(id("missing"), "1:9") } ]
  })

  notify({ revision: "1:9", tokens: [ id("missing") ] })
  await settle(40)

  assert.deepEqual(appliedTargets(), [])
})

test("reports a failed response", async () => {
  responder = async () => jsonResponse({}, { ok: false, status: 403 })

  notify({ revision: "1:9", tokens: [ id("player") ] })
  await settle(40)

  assert.deepEqual(recordedErrors, [ "http_403" ])
})

test("reports a malformed response", async () => {
  responder = async () => jsonResponse({ frames: "nope" })

  notify({ revision: "1:9", tokens: [ id("player") ] })
  await settle(40)

  assert.deepEqual(recordedErrors, [ "invalid_response" ])
})

test("a superseded request reports no error", async () => {
  respondPerToken({ delay: 30 })

  notify({ revision: "1:9", tokens: [ id("player") ] })
  await nextTick()
  notify({ revision: "1:10", tokens: [ id("player") ], queryRevision: "10" })
  await settle(120)

  assert.deepEqual(recordedErrors, [])
})

test("the notification element removes itself", async () => {
  const element = notify({ revision: "1:9", tokens: [ id("player") ] })
  await settle(40)

  assert.equal(element.isConnected, false)
})

test("a cross-origin source is refused", async () => {
  const element = document.createElement("solid-objects-batch-refresh")
  element.dataset.batch = "playmat"
  element.dataset.revision = "1:9"
  element.dataset.targets = id("player")
  element.dataset.source = `https://elsewhere.test${ENDPOINT}?tokens[]=t1`
  defaultScope.append(element)
  await settle(40)

  assert.equal(requests.length, 0)
})

test("a newer revision supersedes every concurrent older request", async () => {
  const targets = [ id("player"), id("controls") ]
  targets.forEach((target) => addTarget(target, "1:8"))
  respondPerToken({ delay: 40 })

  notify({ revision: "1:9", tokens: [ targets[0] ] })
  await nextTick()
  notify({ revision: "1:9", tokens: [ targets[1] ] })
  await nextTick()
  responder = async (url) => {
    await new Promise((resolve) => setTimeout(resolve, 5))
    return jsonResponse({
      frames: tokensIn(url).map((token) => ({
        target: token,
        revision: "1:10",
        html: frameHtml(token, "1:10")
      }))
    })
  }
  notify({ revision: "1:10", tokens: [ targets[0] ], queryRevision: "10" })
  await settle(150)

  assert.equal(aborted.length, 2, "both older same-revision requests should be superseded")
  assert.deepEqual(recordedErrors, [])
})
