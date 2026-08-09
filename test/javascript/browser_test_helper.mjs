import { JSDOM } from "jsdom"

const MODULE_ROOT = new URL(
  "../../app/assets/javascripts/solid_objects/",
  import.meta.url
)

// Each suite gets one document. Custom element registries are per-window, and
// the modules register on import, so the window has to exist first.
export function openDocument(body = "") {
  const dom = new JSDOM(`<!doctype html><html><body>${body}</body></html>`, {
    url: "https://example.test/",
    runScripts: "outside-only"
  })

  globalThis.window = dom.window
  globalThis.document = dom.window.document
  globalThis.HTMLElement = dom.window.HTMLElement
  globalThis.customElements = dom.window.customElements
  globalThis.CustomEvent = dom.window.CustomEvent
  globalThis.DOMParser = dom.window.DOMParser
  globalThis.AbortController = dom.window.AbortController

  return dom
}

export async function loadModule(name) {
  // Cache-bust so each suite re-registers against its own window.
  return import(`${MODULE_ROOT}${name}?cache=${Math.random()}`)
}

export function nextTick() {
  return new Promise((resolve) => setTimeout(resolve, 0))
}

export function appendPayload(scope, { name, revision, payload }) {
  const element = document.createElement("solid-objects-payload")
  element.dataset.name = name
  element.dataset.revision = revision
  element.textContent = JSON.stringify(payload)
  scope.append(element)
  return element
}
