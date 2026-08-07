const activeRefreshes = new Map()

class SolidObjectsRefreshElement extends HTMLElement {
  connectedCallback() {
    if (this.dataset.started === "true") return

    this.dataset.started = "true"
    this.refresh()
  }

  disconnectedCallback() {
    this.refreshController?.abort()
  }

  async refresh() {
    const targetName = this.dataset.target
    const source = this.dataset.source
    if (!targetName || !document.getElementById(targetName) || !source) {
      return this.remove()
    }

    const previousRefresh = activeRefreshes.get(targetName)
    previousRefresh?.abort()

    const refresh = new AbortController()
    this.refreshController = refresh
    activeRefreshes.set(targetName, refresh)

    try {
      const sourceUrl = this.sourceUrl(source)
      const response = await fetch(sourceUrl, {
        credentials: "same-origin",
        headers: {
          Accept: "text/html",
          "Turbo-Frame": targetName
        },
        redirect: "error",
        signal: refresh.signal
      })
      if (!response.ok) {
        this.dispatchRefreshError(`http_${response.status}`)
        return
      }

      const responseDocument = new DOMParser().parseFromString(
        await response.text(),
        "text/html"
      )
      const replacement = responseDocument.getElementById(targetName)
      if (!replacement || replacement.tagName !== "TURBO-FRAME") {
        this.dispatchRefreshError("missing_frame")
        return
      }
      const currentTarget = document.getElementById(targetName)
      if (!currentTarget || !newerRevision(replacement, currentTarget)) return

      renderMorph(targetName, replacement)
    } catch (error) {
      if (error.name !== "AbortError") {
        this.dispatchRefreshError("request_failed")
      }
    } finally {
      if (activeRefreshes.get(targetName) === refresh) {
        activeRefreshes.delete(targetName)
      }
      this.remove()
    }
  }

  sourceUrl(source) {
    const sourceUrl = new URL(source, window.location.href)
    if (sourceUrl.origin === window.location.origin) return sourceUrl

    throw new Error("cross_origin_source")
  }

  dispatchRefreshError(reason) {
    this.dispatchEvent(
      new CustomEvent("solid-objects:component-refresh-error", {
        bubbles: true,
        detail: { reason }
      })
    )
  }
}

function newerRevision(candidate, current) {
  const candidateRevision = revisionFor(candidate)
  const currentRevision = revisionFor(current)
  if (!candidateRevision || !currentRevision) return false

  return candidateRevision[0] > currentRevision[0] ||
    (candidateRevision[0] === currentRevision[0] &&
      candidateRevision[1] > currentRevision[1])
}

function revisionFor(element) {
  const revision = element.dataset.solidObjectsRevision
  if (!revision) return

  const values = revision.split(":").map(Number)
  if (
    values.length !== 2 ||
    values.some((value) => !Number.isSafeInteger(value) || value < 0)
  ) return

  return values
}

function renderMorph(targetName, replacement) {
  const stream = document.createElement("turbo-stream")
  stream.setAttribute("action", "replace")
  stream.setAttribute("method", "morph")
  stream.setAttribute("target", targetName)

  const template = document.createElement("template")
  template.content.append(document.importNode(replacement, true))
  stream.append(template)
  document.documentElement.append(stream)
}

if (!customElements.get("solid-objects-refresh")) {
  customElements.define("solid-objects-refresh", SolidObjectsRefreshElement)
}
