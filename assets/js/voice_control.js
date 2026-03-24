const VoiceControl = {
  mounted() {
    this._mediaRecorder = null;
    this._chunks = [];
    this._recording = false;
    this._audioCtx = null;
    this._analyser = null;
    this._animFrame = null;

    this._onKeyDown = (e) => {
      // Ctrl+Space → start
      if (e.ctrlKey && e.code === "Space" && !this._recording) {
        e.preventDefault();
        this.startRecording();
        // Space alone → stop (prevent page scroll while recording)
      } else if (
        e.code === "Space" &&
        !e.ctrlKey &&
        !e.altKey &&
        !e.metaKey &&
        this._recording
      ) {
        e.preventDefault();
        this.stopRecording();
      }
    };

    window.addEventListener("keydown", this._onKeyDown);

    // Button clicks dispatch DOM events to avoid a server round-trip
    this.el.addEventListener("voice:start", () => this.startRecording());
    this.el.addEventListener("voice:stop", () => this.stopRecording());

    // Handle navigate_to from the server — trigger a live navigation so the
    // root layout (and this VoiceLive) is preserved across page changes.
    this.handleEvent("navigate_to", ({ path }) => {
      let a = document.createElement("a");
      a.href = path;
      a.setAttribute("data-phx-link", "redirect");
      a.setAttribute("data-phx-link-state", "push");
      document.body.appendChild(a);
      a.click();
      a.remove();
    });
  },

  destroyed() {
    window.removeEventListener("keydown", this._onKeyDown);
    this._stopVisualization();
    if (this._mediaRecorder && this._recording) {
      this._mediaRecorder.stop();
    }
  },

  _startVisualization(stream) {
    this._audioCtx = new AudioContext();
    this._analyser = this._audioCtx.createAnalyser();
    // 64 bins gives a clean bar chart without being too dense
    this._analyser.fftSize = 64;
    this._analyser.smoothingTimeConstant = 0.75;

    const source = this._audioCtx.createMediaStreamSource(stream);
    source.connect(this._analyser);

    const bufferLength = this._analyser.frequencyBinCount; // 32
    const dataArray = new Uint8Array(bufferLength);

    const draw = () => {
      this._animFrame = requestAnimationFrame(draw);

      const canvas = document.getElementById("voice-viz-canvas");
      if (!canvas) return;
      const ctx = canvas.getContext("2d");

      // Sync pixel buffer to CSS display size
      const displayWidth = canvas.offsetWidth;
      const displayHeight = canvas.offsetHeight;
      if (canvas.width !== displayWidth) canvas.width = displayWidth;
      if (canvas.height !== displayHeight) canvas.height = displayHeight;

      this._analyser.getByteFrequencyData(dataArray);

      ctx.clearRect(0, 0, canvas.width, canvas.height);

      const totalBars = bufferLength;
      const barWidth = (canvas.width / totalBars) * 0.7;
      const gap = canvas.width / totalBars - barWidth;
      const radius = Math.max(2, barWidth / 4);

      for (let i = 0; i < totalBars; i++) {
        const value = dataArray[i] / 255;
        const barHeight = Math.max(4, value * canvas.height);
        const x = i * (barWidth + gap) + gap / 2;
        const y = canvas.height - barHeight;

        // Cyan at low amplitude → teal → green at high amplitude
        const hue = 185 - value * 80;
        const lightness = 40 + value * 25;
        ctx.fillStyle = `hsl(${hue}, 90%, ${lightness}%)`;

        ctx.beginPath();
        ctx.roundRect(x, y, barWidth, barHeight, radius);
        ctx.fill();
      }
    };

    draw();
  },

  _stopVisualization() {
    if (this._animFrame) {
      cancelAnimationFrame(this._animFrame);
      this._animFrame = null;
    }
    if (this._audioCtx) {
      this._audioCtx.close();
      this._audioCtx = null;
      this._analyser = null;
    }
  },

  async startRecording() {
    let stream;
    try {
      stream = await navigator.mediaDevices.getUserMedia({ audio: true });
    } catch (err) {
      console.error(
        "VoiceControl: microphone access denied or unavailable",
        err,
      );
      this.pushEvent("recording_error", { reason: err.message });
      return;
    }

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
        // reader.result is "data:<mime>;base64,<data>" — strip the prefix
        const base64 = reader.result.split(",")[1];
        this.pushEvent("audio_recorded", { data: base64, mime_type: mimeType });
      };
      reader.readAsDataURL(blob);

      // Release the microphone indicator in the OS browser tab
      stream.getTracks().forEach((t) => t.stop());
      this._stopVisualization();
      this._recording = false;
    };

    this._mediaRecorder.start();
    this._recording = true;
    this.pushEvent("recording_started", {});

    // Defer visualization start by one tick so LiveView has rendered the canvas
    setTimeout(() => this._startVisualization(stream), 50);
  },

  stopRecording() {
    if (this._mediaRecorder && this._mediaRecorder.state !== "inactive") {
      this._mediaRecorder.stop();
      // _recording flipped to false inside onstop after blob is ready
    }
  },
};

export { VoiceControl };
