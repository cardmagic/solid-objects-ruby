import http from "node:http"
import { readFile } from "node:fs/promises"
import { chromium } from "playwright"

const ROOT = new URL("../../", import.meta.url)

const FILES = {
  "/turbo.js": "node_modules/@hotwired/turbo/dist/turbo.es2017-esm.js",
  "/component_refresh.js": "app/assets/javascripts/solid_objects/component_refresh.js",
  "/component_batch_refresh.js": "app/assets/javascripts/solid_objects/component_batch_refresh.js",
  "/state_payload.js": "app/assets/javascripts/solid_objects/state_payload.js"
}

// Serves the real browser modules alongside a real Turbo build, so tests
// exercise Turbo's own stream processing rather than a stand-in for it.
export async function startServer({ routes = {} } = {}) {
  const server = http.createServer(async (request, response) => {
    const url = new URL(request.url, "http://localhost")
    const route = routes[url.pathname]
    if (route) return route(request, response, url)

    const file = FILES[url.pathname]
    if (file) {
      const body = await readFile(new URL(file, ROOT), "utf8")
      response.writeHead(200, { "Content-Type": "text/javascript" })
      return response.end(body)
    }

    if (url.pathname === "/") {
      response.writeHead(200, { "Content-Type": "text/html" })
      return response.end(page())
    }

    response.writeHead(404)
    response.end("not found")
  })

  await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve))
  const { port } = server.address()
  return { server, origin: `http://127.0.0.1:${port}` }
}

function page() {
  return `<!doctype html>
<html>
  <body>
    <div id="solid-objects-scope">
      <turbo-frame id="player" data-solid-objects-revision="1:8">stale player</turbo-frame>
      <turbo-frame id="controls" data-solid-objects-revision="1:8">stale controls</turbo-frame>
    </div>
    <script type="module" src="/turbo.js"></script>
    <script type="module" src="/component_refresh.js"></script>
    <script type="module" src="/component_batch_refresh.js"></script>
    <script type="module" src="/state_payload.js"></script>
  </body>
</html>`
}

export function frameHtml(target, revision, body) {
  return `<turbo-frame id="${target}" data-solid-objects-revision="${revision}">${body}</turbo-frame>`
}

export async function openPage(origin) {
  const browser = await chromium.launch()
  const context = await browser.newContext()
  const page = await context.newPage()
  await page.goto(`${origin}/`)
  await page.waitForFunction(() => Boolean(customElements.get("solid-objects-refresh")))
  return { browser, page }
}
