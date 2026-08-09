const pendingBatches = new Map()
const activeBatches = new Map()
const appliedRevisions = new Map()
let requestSequence = 0

class SolidObjectsBatchRefreshElement extends HTMLElement {
  connectedCallback() {
    if (this.dataset.started === "true") return

    this.dataset.started = "true"
    this.enqueue()
  }

  // Several observables changing in one commit produce several notifications
  // for the same batch and revision. Merging them in a microtask turns those
  // into a single request.
  enqueue() {
    const batch = this.dataset.batch
    const revision = this.dataset.revision
    const source = this.dataset.source
    const scope = this.closest("[id]")?.id
    if (!batch || !revision || !source || !scope) return this.remove()

    // Two actor scopes may reuse a batch name on one page. Keying by scope
    // keeps their requests from merging or cancelling each other.
    const group = `${scope}:${batch}`
    const key = `${group}:${revision}`
    const pending = pendingBatches.get(key)
    if (pending) {
      pending.sources.add(source)
      this.remove()
      return
    }

    const merged = { sources: new Set([ source ]) }
    pendingBatches.set(key, merged)
    queueMicrotask(() => {
      pendingBatches.delete(key)
      requestBatch(group, batch, revision, merged.sources)
    })
    this.remove()
  }
}

// Invalidations for one revision arrive in separate WebSocket messages, so the
// microtask merge cannot see them all. Requests are tracked per revision and a
// request is only cancelled by a strictly newer one; same-revision requests run
// alongside each other and every frame is applied.
async function requestBatch(group, batch, revision, sources) {
  const parsed = parseRevision(revision)
  supersedeOlderRequests(group, parsed)

  // Same-revision requests run concurrently, so each needs its own entry.
  // Sharing one key per revision would leave all but the last untracked and
  // therefore impossible to supersede.
  const key = `${group}:${revision}:${(requestSequence += 1)}`
  const controller = new AbortController()
  activeBatches.set(key, { controller, group, revision: parsed })

  try {
    const url = mergedUrl(sources)
    if (!url) return

    const response = await fetch(url, {
      credentials: "same-origin",
      headers: { Accept: "application/json" },
      redirect: "error",
      signal: controller.signal
    })
    if (!response.ok) return dispatchBatchError(batch, `http_${response.status}`)

    const body = await response.json()
    if (!Array.isArray(body?.frames)) {
      return dispatchBatchError(batch, "invalid_response")
    }

    body.frames.forEach(applyFrame)
  } catch (error) {
    if (error.name !== "AbortError") dispatchBatchError(batch, "request_failed")
  } finally {
    if (activeBatches.get(key)?.controller === controller) activeBatches.delete(key)
  }
}

function supersedeOlderRequests(group, revision) {
  if (!revision) return

  activeBatches.forEach((entry, key) => {
    if (entry.group !== group) return
    if (!olderRevision(entry.revision, revision)) return

    entry.controller.abort()
    activeBatches.delete(key)
  })
}

function olderRevision(candidate, current) {
  if (!candidate || !current) return false

  return candidate[0] < current[0] ||
    (candidate[0] === current[0] && candidate[1] < current[1])
}

// Every notification for one batch and revision carries the same endpoint and
// differs only by which components changed, so the union of their tokens is the
// complete set to render.
function mergedUrl(sources) {
  const urls = [ ...sources ].map((source) => new URL(source, window.location.href))
  const first = urls[0]
  if (!first || first.origin !== window.location.origin) return

  const tokens = new Set()
  urls.forEach((url) => {
    url.searchParams.getAll("tokens[]").forEach((token) => tokens.add(token))
  })
  first.searchParams.delete("tokens[]")
  tokens.forEach((token) => first.searchParams.append("tokens[]", token))
  return first
}

function applyFrame(frame) {
  const target = document.getElementById(frame?.target)
  if (!target || !frame.html) return
  if (!newerRevision(frame.revision, target.dataset.solidObjectsRevision)) return
  // Concurrent same-revision responses can carry the same frame. The target's
  // own revision only advances once Turbo applies the stream, so what has
  // already been applied is tracked here as well.
  const applied = appliedRevisions.get(frame.target)
  if (applied && !newerRevision(frame.revision, applied)) return

  appliedRevisions.set(frame.target, frame.revision)

  const parsed = new DOMParser().parseFromString(frame.html, "text/html")
  const replacement = parsed.getElementById(frame.target)
  if (!replacement) return

  const stream = document.createElement("turbo-stream")
  stream.setAttribute("action", "replace")
  if (frame.refresh_method === "morph") stream.setAttribute("method", "morph")
  stream.setAttribute("target", frame.target)

  const template = document.createElement("template")
  template.content.append(document.importNode(replacement, true))
  stream.append(template)
  document.documentElement.append(stream)
}

function newerRevision(candidate, current) {
  const candidateRevision = parseRevision(candidate)
  const currentRevision = parseRevision(current)
  if (!candidateRevision || !currentRevision) return false

  return candidateRevision[0] > currentRevision[0] ||
    (candidateRevision[0] === currentRevision[0] &&
      candidateRevision[1] > currentRevision[1])
}

function parseRevision(revision) {
  if (!revision) return

  const values = String(revision).split(":").map(Number)
  if (
    values.length !== 2 ||
    values.some((value) => !Number.isSafeInteger(value) || value < 0)
  ) return

  return values
}

function dispatchBatchError(batch, reason) {
  document.dispatchEvent(
    new CustomEvent("solid-objects:batch-refresh-error", {
      bubbles: true,
      detail: { batch, reason }
    })
  )
}

if (!customElements.get("solid-objects-batch-refresh")) {
  customElements.define(
    "solid-objects-batch-refresh",
    SolidObjectsBatchRefreshElement
  )
}
