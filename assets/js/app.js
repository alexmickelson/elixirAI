// If you want to use Phoenix channels, run `mix help phx.gen.channel`
// to get started and then uncomment the line below.
// import "./user_socket.js"

// You can include dependencies in two ways.
//
// The simplest option is to put them in assets/vendor and
// import them using relative paths:
//
//     import "../vendor/some-package.js"
//
// Alternatively, you can `npm install some-package --prefix assets` and import
// them using a path starting with the package name:
//
//     import "some-package"
//

// Include phoenix_html to handle method=PUT/DELETE in forms and buttons.
import "phoenix_html"
// Establish Phoenix Socket and LiveView configuration.
import {Socket} from "phoenix"
import {LiveSocket} from "phoenix_live_view"
import topbar from "../vendor/topbar"

let Hooks = {}

// Renders a complete markdown string client-side on mount.
// The raw markdown is passed as the data-md attribute.
Hooks.MarkdownRender = {
  mounted() {
    const smd = window.smd
    const content = this.el.dataset.md
    if (!content) return
    const parser = smd.parser(smd.default_renderer(this.el))
    smd.parser_write(parser, content)
    smd.parser_end(parser)
  }
}

// Streams markdown chunks into the element using the streaming-markdown parser.
// The server sends push_event(socket, eventName, %{chunk: "..."}) for each chunk.
// data-event on the element controls which event this hook listens for.
// The server sends push_event(socket, eventName, %{chunk: "..."}) for each chunk.
// data-event on the element controls which event this hook listens for.
Hooks.MarkdownStream = {
  mounted() {
    const smd = window.smd
    const DOMPurify = window.DOMPurify
    this._chunks = ""
    this._parser = smd.parser(smd.default_renderer(this.el))
    const eventName = this.el.dataset.event
    this.handleEvent(eventName, ({chunk}) => {
      this._chunks += chunk
      // Sanitize all accumulated chunks to detect injection attacks.
      DOMPurify.sanitize(this._chunks)
      if (DOMPurify.removed.length > 0) {
        // Insecure content detected — stop rendering immediately.
        smd.parser_end(this._parser)
        this._parser = null
        return
      }
      if (this._parser) smd.parser_write(this._parser, chunk)
    })
  },
  destroyed() {
    if (this._parser) {
      window.smd.parser_end(this._parser)
      this._parser = null
    }
  }
}

Hooks.ScrollBottom = {
  mounted() {
    requestAnimationFrame(() => this.scrollToBottom())
    this.observer = new MutationObserver(() => {
      if (this.isNearBottom()) this.scrollToBottom()
    })
    this.observer.observe(this.el, {childList: true, subtree: true})
    this.handleEvent("scroll_to_bottom", () => {
      this.scrollToBottom()
    })
  },
  updated() {
    if (this.isNearBottom()) this.scrollToBottom()
  },
  destroyed() {
    this.observer.disconnect()
  },
  isNearBottom() {
    const closeToBottomThreshold = 200
    return this.el.scrollHeight - this.el.scrollTop - this.el.clientHeight <= closeToBottomThreshold
  },
  scrollToBottom() {
    this.el.scrollTop = this.el.scrollHeight
  }
}

let csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content")

// Retry very aggressively: 100ms, 250ms, 500ms, then cap at 1s indefinitely.
const reconnectAfterMs = (tries) => [100, 250, 500][tries - 1] || 1000
const rejoinAfterMs    = (tries) => [100, 250, 500][tries - 1] || 1000

let liveSocket = new LiveSocket("/live", Socket, {
  params: {_csrf_token: csrfToken},
  hooks: Hooks,
  reconnectAfterMs,
  rejoinAfterMs
})

// Show progress bar on live navigation and form submits
topbar.config({barColors: {0: "#29d"}, shadowColor: "rgba(0, 0, 0, .3)"})
window.addEventListener("phx:page-loading-start", _info => topbar.show(300))
window.addEventListener("phx:page-loading-stop", _info => topbar.hide())

// connect if there are any LiveViews on the page
liveSocket.connect()

// expose liveSocket on window for web console debug logs and latency simulation:
// >> liveSocket.enableDebug()
// >> liveSocket.enableLatencySim(1000)  // enabled for duration of browser session
// >> liveSocket.disableLatencySim()
window.liveSocket = liveSocket

