# Voice Recording + Whisper

Reference: [`alexmickelson/office-infrastructure`](https://github.com/alexmickelson/office-infrastructure/tree/master/ai-office-server/nginx/html)

---

## Recording

```js
let mediaStream = null;
let recorder = null;
let chunks = [];

async function startRecording() {
  if (!mediaStream) {
    mediaStream = await navigator.mediaDevices.getUserMedia({ audio: true, video: false });
  }

  const mimeType = ["audio/webm;codecs=opus", "audio/webm", "audio/ogg;codecs=opus", "audio/ogg"]
    .find((t) => MediaRecorder.isTypeSupported(t)) || "";

  chunks = [];
  recorder = new MediaRecorder(mediaStream, mimeType ? { mimeType } : undefined);
  recorder.ondataavailable = (e) => { if (e.data?.size > 0) chunks.push(e.data); };
  recorder.onstop = async () => {
    const blob = new Blob(chunks, { type: recorder.mimeType || "audio/webm" });
    const text = await sendToWhisper(blob, "your prompt context here");
    console.log(text);
  };
  recorder.start(100); // fires ondataavailable every 100ms
}

function stopRecording() {
  if (recorder?.state === "recording") recorder.stop();
}
```

---

## Sending to Whisper

`POST {serverUrl}/inference` as `multipart/form-data`. Returns `{ "text": "..." }`.

```js
async function sendToWhisper(blob, prompt) {
  const formData = new FormData();
  formData.append("file", blob, "audio.webm");
  formData.append("response_format", "json");
  formData.append("language", "en"); // or "" for auto-detect
  if (prompt) formData.append("prompt", prompt);

  const res = await fetch("https://your-whisper-server/inference", {
    method: "POST",
    body: formData,
  });
  const data = await res.json();
  return (data.text || "").trim();
}
```

The `prompt` field accepts the last ~20 words of prior transcript — Whisper uses it as context to improve continuity across chunks.

---

## Visualization

Requires a `<canvas id="volumeCanvas">` in the HTML.

```js
const canvas = document.getElementById("volumeCanvas");
const ctx = canvas.getContext("2d");
const MAX_BARS = 180; // 6s × 30fps
const volHistory = [];
let vizRaf = null;

function startViz(stream) {
  const audioCtx = new AudioContext();
  const analyser = audioCtx.createAnalyser();
  audioCtx.createMediaStreamSource(stream).connect(analyser);
  analyser.fftSize = 1024;
  const buf = new Uint8Array(analyser.frequencyBinCount);

  function tick() {
    vizRaf = requestAnimationFrame(tick);
    analyser.getByteFrequencyData(buf);
    const rms = Math.sqrt(buf.reduce((s, v) => s + v * v, 0) / buf.length) / 255;
    volHistory.push(rms);
    if (volHistory.length > MAX_BARS) volHistory.shift();

    const W = canvas.offsetWidth * devicePixelRatio;
    const H = canvas.offsetHeight * devicePixelRatio;
    if (canvas.width !== W || canvas.height !== H) { canvas.width = W; canvas.height = H; }
    ctx.clearRect(0, 0, W, H);
    const barW = W / MAX_BARS;
    volHistory.forEach((v, i) => {
      ctx.fillStyle = `hsl(${120 - v * 120}, 80%, 45%)`; // green → red
      ctx.fillRect(i * barW, H - v * H, Math.max(1, barW - 1), v * H);
    });
  }
  tick();
}

function stopViz() {
  cancelAnimationFrame(vizRaf);
  vizRaf = null;
}
```

Call `startViz(mediaStream)` right after `getUserMedia`, and `stopViz()` after `recorder.stop()`.
