const deliveredRevisions = new Map()

class SolidObjectsPayloadElement extends HTMLElement {
  connectedCallback() {
    if (this.dataset.started === "true") return

    this.dataset.started = "true"
    this.deliver()
  }

  deliver() {
    try {
      const name = this.dataset.name
      const revision = revisionFor(this)
      const scope = this.closest("[id]")
      if (!name || !revision || !scope) return

      const key = `${scope.id}:${name}`
      if (!newerRevision(revision, deliveredRevisions.get(key))) return

      const payload = JSON.parse(this.textContent)
      deliveredRevisions.set(key, revision)
      scope.dispatchEvent(
        new CustomEvent("solid-objects:payload", {
          bubbles: true,
          detail: {
            name,
            instanceId: revision[0],
            revision: revision[1],
            payload
          }
        })
      )
    } catch {
      this.dispatchEvent(
        new CustomEvent("solid-objects:payload-error", {
          bubbles: true,
          detail: { reason: "invalid_payload" }
        })
      )
    } finally {
      this.remove()
    }
  }
}

function newerRevision(candidate, current) {
  if (!current) return true

  return candidate[0] > current[0] ||
    (candidate[0] === current[0] && candidate[1] > current[1])
}

function revisionFor(element) {
  const revision = element.dataset.revision
  if (!revision) return

  const values = revision.split(":").map(Number)
  if (
    values.length !== 2 ||
    values.some((value) => !Number.isSafeInteger(value) || value < 0)
  ) return

  return values
}

if (!customElements.get("solid-objects-payload")) {
  customElements.define("solid-objects-payload", SolidObjectsPayloadElement)
}
