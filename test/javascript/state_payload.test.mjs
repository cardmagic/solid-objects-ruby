import assert from "node:assert/strict"
import { test, before, beforeEach } from "node:test"
import {
  openDocument,
  loadModule,
  nextTick,
  appendPayload
} from "./browser_test_helper.mjs"

before(async () => {
  openDocument()
  await loadModule("state_payload.js")
})

let scope
let received
let scopeCount = 0

beforeEach(() => {
  document.body.innerHTML = ""
  scope = document.createElement("div")
  // The module tracks delivered revisions per scope for the life of the page,
  // so each test needs its own scope identity.
  scope.id = `solid-objects-scope-${(scopeCount += 1)}`
  document.body.append(scope)
  received = []
  scope.addEventListener("solid-objects:payload", (event) => {
    received.push(event.detail)
  })
})

test("dispatches the payload with its identity and revision", async () => {
  appendPayload(scope, {
    name: "playmat_state",
    revision: "7:12",
    payload: { turn: 3, hand: ["Island"] }
  })
  await nextTick()

  assert.equal(received.length, 1)
  assert.equal(received[0].name, "playmat_state")
  assert.equal(received[0].instanceId, 7)
  assert.equal(received[0].revision, 12)
  assert.deepEqual(received[0].payload, { turn: 3, hand: ["Island"] })
})

test("removes itself after delivering", async () => {
  const element = appendPayload(scope, {
    name: "playmat_state",
    revision: "7:12",
    payload: {}
  })
  await nextTick()

  assert.equal(element.isConnected, false)
})

test("drops a stale revision", async () => {
  appendPayload(scope, { name: "playmat_state", revision: "7:12", payload: { turn: 3 } })
  await nextTick()
  appendPayload(scope, { name: "playmat_state", revision: "7:9", payload: { turn: 1 } })
  await nextTick()

  assert.equal(received.length, 1)
  assert.equal(received[0].revision, 12)
})

test("drops a duplicate revision", async () => {
  appendPayload(scope, { name: "playmat_state", revision: "7:12", payload: {} })
  await nextTick()
  appendPayload(scope, { name: "playmat_state", revision: "7:12", payload: {} })
  await nextTick()

  assert.equal(received.length, 1)
})

test("accepts a newer revision after a stale one", async () => {
  appendPayload(scope, { name: "playmat_state", revision: "7:12", payload: {} })
  await nextTick()
  appendPayload(scope, { name: "playmat_state", revision: "7:9", payload: {} })
  await nextTick()
  appendPayload(scope, { name: "playmat_state", revision: "7:13", payload: {} })
  await nextTick()

  assert.deepEqual(received.map((detail) => detail.revision), [12, 13])
})

test("a newer instance supersedes an older one", async () => {
  appendPayload(scope, { name: "playmat_state", revision: "7:99", payload: {} })
  await nextTick()
  appendPayload(scope, { name: "playmat_state", revision: "8:1", payload: {} })
  await nextTick()

  assert.deepEqual(received.map((detail) => detail.instanceId), [7, 8])
})

test("tracks revisions per payload name", async () => {
  appendPayload(scope, { name: "playmat_state", revision: "7:12", payload: {} })
  await nextTick()
  appendPayload(scope, { name: "sideboard_state", revision: "7:5", payload: {} })
  await nextTick()

  assert.deepEqual(received.map((detail) => detail.name), [
    "playmat_state",
    "sideboard_state"
  ])
})

test("reports malformed payloads without dispatching", async () => {
  const errors = []
  scope.addEventListener("solid-objects:payload-error", (event) => {
    errors.push(event.detail.reason)
  })
  const element = document.createElement("solid-objects-payload")
  element.dataset.name = "playmat_state"
  element.dataset.revision = "7:12"
  element.textContent = "{not json"
  scope.append(element)
  await nextTick()

  assert.equal(received.length, 0)
  assert.deepEqual(errors, ["invalid_payload"])
})

test("ignores an element with no revision", async () => {
  const element = document.createElement("solid-objects-payload")
  element.dataset.name = "playmat_state"
  element.textContent = "{}"
  scope.append(element)
  await nextTick()

  assert.equal(received.length, 0)
})

test("ignores a malformed revision", async () => {
  appendPayload(scope, { name: "playmat_state", revision: "seven:twelve", payload: {} })
  await nextTick()

  assert.equal(received.length, 0)
})
