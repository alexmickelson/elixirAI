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

import "phoenix_html";
import { Socket } from "phoenix";
import { LiveSocket } from "phoenix_live_view";
import topbar from "../vendor/topbar";
import { VoiceControl } from "./voice_control";

let Hooks = {};

Hooks.VoiceControl = VoiceControl;

// Inline mic recorder for the chat input.
// Click-to-start, click-to-stop. On stop, pushes audio_recorded to the LiveView.
Hooks.ChatVoiceRecord = {
  mounted() {
    this._mediaRecorder = null;
    this._chunks = [];
    this._recording = false;
    this._audioCtx = null;
    this._analyser = null;
    this._animFrame = null;
    this._stream = null;

    this.el.addEventListener("chat-voice:start", () => this.startRecording());
    this.el.addEventListener("chat-voice:stop", () => this.stopRecording());
  },

  destroyed() {
    this._stopVisualization();
    if (this._stream) this._stream.getTracks().forEach((t) => t.stop());
  },

  async startRecording() {
    let stream;
    try {
      stream = await navigator.mediaDevices.getUserMedia({ audio: true });
    } catch (err) {
      this.pushEvent("recording_error", { reason: err.message });
      return;
    }

    this._stream = stream;
    this._chunks = [];
    this._mediaRecorder = new MediaRecorder(stream);

    this._mediaRecorder.ondataavailable = (e) => {
      if (e.data.size > 0) this._chunks.push(e.data);
    };

    this._mediaRecorder.onstop = () => {
      const mimeType = this._mediaRecorder.mimeType;
      const blob = new Blob(this._chunks, { type: mimeType });
      const reader = new FileReader();
      reader.onloadend = () => {
        const base64 = reader.result.split(",")[1];
        this.pushEvent("chat_audio_recorded", {
          data: base64,
          mime_type: mimeType,
        });
      };
      reader.readAsDataURL(blob);
      stream.getTracks().forEach((t) => t.stop());
      this._stopVisualization();
      this._recording = false;
    };

    this._mediaRecorder.start();
    this._recording = true;
    this.pushEvent("chat_recording_started", {});
    setTimeout(() => this._startVisualization(stream), 50);
  },

  stopRecording() {
    if (this._mediaRecorder && this._mediaRecorder.state !== "inactive") {
      this._mediaRecorder.stop();
    }
  },

  _startVisualization(stream) {
    this._audioCtx = new AudioContext();
    this._analyser = this._audioCtx.createAnalyser();
    this._analyser.fftSize = 64;
    this._analyser.smoothingTimeConstant = 0.75;
    const source = this._audioCtx.createMediaStreamSource(stream);
    source.connect(this._analyser);
    const bufferLength = this._analyser.frequencyBinCount;
    const dataArray = new Uint8Array(bufferLength);

    const draw = () => {
      this._animFrame = requestAnimationFrame(draw);
      const canvas = this.el.querySelector(".chat-voice-canvas");
      if (!canvas) return;
      const ctx = canvas.getContext("2d");
      if (canvas.width !== canvas.offsetWidth)
        canvas.width = canvas.offsetWidth;
      if (canvas.height !== canvas.offsetHeight)
        canvas.height = canvas.offsetHeight;
      this._analyser.getByteFrequencyData(dataArray);
      ctx.clearRect(0, 0, canvas.width, canvas.height);
      const barWidth = (canvas.width / bufferLength) * 0.7;
      const gap = canvas.width / bufferLength - barWidth;
      for (let i = 0; i < bufferLength; i++) {
        const value = dataArray[i] / 255;
        const barHeight = Math.max(2, value * canvas.height);
        const x = i * (barWidth + gap) + gap / 2;
        const y = canvas.height - barHeight;
        const hue = 185 - value * 80;
        const lightness = 40 + value * 25;
        ctx.fillStyle = `hsl(${hue}, 90%, ${lightness}%)`;
        ctx.fillRect(x, y, barWidth, barHeight);
      }
    };
    draw();
  },

  _stopVisualization() {
    if (this._animFrame) cancelAnimationFrame(this._animFrame);
    if (this._audioCtx) {
      this._audioCtx.close();
      this._audioCtx = null;
    }
  },
};

// Renders a complete markdown string client-side on mount.
// The raw markdown is passed as the data-md attribute.
Hooks.MarkdownRender = {
  mounted() {
    const smd = window.smd;
    const content = this.el.dataset.md;
    if (!content) return;
    const parser = smd.parser(smd.default_renderer(this.el));
    smd.parser_write(parser, content);
    smd.parser_end(parser);
  },
};

// Streams markdown chunks into the element using the streaming-markdown parser.
// The server sends push_event(socket, eventName, %{chunk: "..."}) for each chunk.
// data-event on the element controls which event this hook listens for.
// The server sends push_event(socket, eventName, %{chunk: "..."}) for each chunk.
// data-event on the element controls which event this hook listens for.
Hooks.MarkdownStream = {
  mounted() {
    const smd = window.smd;
    const DOMPurify = window.DOMPurify;
    this._chunks = "";
    this._parser = smd.parser(smd.default_renderer(this.el));
    const eventName = this.el.dataset.event;
    this.handleEvent(eventName, ({ chunk }) => {
      this._chunks += chunk;
      // Sanitize all accumulated chunks to detect injection attacks.
      DOMPurify.sanitize(this._chunks);
      if (DOMPurify.removed.length > 0) {
        // Insecure content detected — stop rendering immediately.
        smd.parser_end(this._parser);
        this._parser = null;
        return;
      }
      if (this._parser) smd.parser_write(this._parser, chunk);
    });
  },
  destroyed() {
    if (this._parser) {
      window.smd.parser_end(this._parser);
      this._parser = null;
    }
  },
};

// Streams raw tool output chunks into a <pre> element as they arrive.
// Matches by data-tool-call-id to scope events from multiple concurrent tools.
// Reveals the parent section div on first chunk so an empty section is never shown.
Hooks.ToolOutputStream = {
  mounted() {
    this.handleEvent("tool_chunk", ({ id, chunk }) => {
      if (this.el.dataset.toolCallId === id) {
        if (this.el.textContent === "") {
          const sectionId = this.el.dataset.sectionId;
          if (sectionId) {
            const section = document.getElementById(sectionId);
            if (section) section.classList.remove("hidden");
          }
        }
        this.el.textContent += chunk;
      }
    });
  },
};

Hooks.ScrollBottom = {
  mounted() {
    this.userScrolledUp = false;
    this.programmaticScroll = false;

    this.el.addEventListener("scroll", () => {
      if (this.programmaticScroll) return;
      this.userScrolledUp = !this.isNearBottom();
    });

    this.handleEvent("scroll_to_bottom", () => {
      this.userScrolledUp = false;
      requestAnimationFrame(() => this.scrollToBottom());
    });

    requestAnimationFrame(() => this.scrollToBottom());
  },
  updated() {
    if (!this.userScrolledUp) this.scrollToBottom();
  },
  isNearBottom() {
    return this.el.scrollTop <= 100;
  },
  scrollToBottom() {
    this.programmaticScroll = true;
    this.el.scrollTop = 0;
    requestAnimationFrame(() => {
      this.programmaticScroll = false;
    });
  },
};

let csrfToken = document
  .querySelector("meta[name='csrf-token']")
  .getAttribute("content");

const reconnectAfterMs = (tries) => [100, 250, 500][tries - 1] || 1000;
const rejoinAfterMs = (tries) => [100, 250, 500][tries - 1] || 1000;

let liveSocket = new LiveSocket("/live", Socket, {
  params: { _csrf_token: csrfToken },
  hooks: Hooks,
  reconnectAfterMs,
  rejoinAfterMs,
});

topbar.config({ barColors: { 0: "#29d" }, shadowColor: "rgba(0, 0, 0, .3)" });
window.addEventListener("phx:page-loading-start", (_info) => topbar.show(300));
window.addEventListener("phx:page-loading-stop", (_info) => topbar.hide());

liveSocket.connect();
window.liveSocket = liveSocket;
