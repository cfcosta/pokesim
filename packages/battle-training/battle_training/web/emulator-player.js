"use strict";

(() => {
  const CANONICAL_ROM_SHA256 = "5ca7ba01642a3b27b0cc0b5349b52792795b62d3ed977e98a09390659af96b7b";
  const ROM_BYTES = 1024 * 1024;
  const REPLAY_FAILURES = {
    "-2": "the cartridge opened the ordinary battle menu during a forced replacement",
    "-3": "the recorded action was not valid in the cartridge battle menu",
    "-4": "the cartridge opened move selection for a recorded automatic action",
    "-5": "the recorded replacement did not match the cartridge replacement request",
    "-8": "the cartridge reached a terminal screen before consuming every recorded action",
    "-9": "the canonical-ROM replay patches could not be installed",
    "-10": "the replay action trampoline was unavailable",
  };
  let activePlayer = null;
  let sessionRom = null;

  function node(tag, className, content) {
    const result = document.createElement(tag);
    if (className) result.className = className;
    if (content !== undefined) result.textContent = content;
    return result;
  }

  function hex(bytes) {
    return [...bytes].map((value) => value.toString(16).padStart(2, "0")).join("");
  }

  async function sha256(bytes) {
    return hex(new Uint8Array(await crypto.subtle.digest("SHA-256", bytes)));
  }

  function findEndOfCentralDirectory(bytes) {
    const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
    const lowerBound = Math.max(0, bytes.byteLength - 65557);
    for (let offset = bytes.byteLength - 22; offset >= lowerBound; offset -= 1) {
      if (view.getUint32(offset, true) === 0x06054b50) return offset;
    }
    throw new Error("The ZIP central directory is missing");
  }

  async function romFromZip(bytes) {
    const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
    const eocd = findEndOfCentralDirectory(bytes);
    const entries = view.getUint16(eocd + 10, true);
    let offset = view.getUint32(eocd + 16, true);
    const decoder = new TextDecoder();
    for (let index = 0; index < entries; index += 1) {
      if (view.getUint32(offset, true) !== 0x02014b50) throw new Error("The ZIP directory is corrupt");
      const method = view.getUint16(offset + 10, true);
      const compressedSize = view.getUint32(offset + 20, true);
      const uncompressedSize = view.getUint32(offset + 24, true);
      const nameLength = view.getUint16(offset + 28, true);
      const extraLength = view.getUint16(offset + 30, true);
      const commentLength = view.getUint16(offset + 32, true);
      const localOffset = view.getUint32(offset + 42, true);
      const name = decoder.decode(bytes.subarray(offset + 46, offset + 46 + nameLength));
      if (/\.(gb|gbc)$/i.test(name)) {
        if (view.getUint32(localOffset, true) !== 0x04034b50) throw new Error("The ZIP entry is corrupt");
        const localNameLength = view.getUint16(localOffset + 26, true);
        const localExtraLength = view.getUint16(localOffset + 28, true);
        const start = localOffset + 30 + localNameLength + localExtraLength;
        const compressed = bytes.slice(start, start + compressedSize);
        let rom;
        if (method === 0) {
          rom = compressed;
        } else if (method === 8 && typeof DecompressionStream !== "undefined") {
          const stream = new Blob([compressed]).stream().pipeThrough(new DecompressionStream("deflate-raw"));
          rom = new Uint8Array(await new Response(stream).arrayBuffer());
        } else {
          throw new Error("This browser cannot decompress the ROM ZIP; select the extracted .gb file instead");
        }
        if (rom.byteLength !== uncompressedSize) throw new Error("The decompressed ROM length is incorrect");
        return rom;
      }
      offset += 46 + nameLength + extraLength + commentLength;
    }
    throw new Error("The ZIP does not contain a .gb or .gbc file");
  }

  async function readRom(file) {
    const bytes = new Uint8Array(await file.arrayBuffer());
    return file.name.toLowerCase().endsWith(".zip") ? romFromZip(bytes) : bytes;
  }

  function openRomDatabase() {
    return new Promise((resolve, reject) => {
      const request = indexedDB.open("redline-local-roms", 1);
      request.addEventListener("upgradeneeded", () => request.result.createObjectStore("roms"));
      request.addEventListener("success", () => resolve(request.result));
      request.addEventListener("error", () => reject(request.error));
    });
  }

  async function cachedRom() {
    if (sessionRom) return sessionRom;
    try {
      const database = await openRomDatabase();
      const value = await new Promise((resolve, reject) => {
        const request = database.transaction("roms").objectStore("roms").get(CANONICAL_ROM_SHA256);
        request.addEventListener("success", () => resolve(request.result));
        request.addEventListener("error", () => reject(request.error));
      });
      database.close();
      if (value instanceof ArrayBuffer) sessionRom = new Uint8Array(value);
    } catch {
      // Private browsing and storage policies may disable IndexedDB; session playback still works.
    }
    return sessionRom;
  }

  async function rememberRom(bytes) {
    sessionRom = bytes;
    try {
      const database = await openRomDatabase();
      await new Promise((resolve, reject) => {
        const transaction = database.transaction("roms", "readwrite");
        transaction.objectStore("roms").put(bytes.slice().buffer, CANONICAL_ROM_SHA256);
        transaction.addEventListener("complete", resolve);
        transaction.addEventListener("error", () => reject(transaction.error));
      });
      database.close();
    } catch {
      // Storage is an optimization, never a prerequisite for local ROM playback.
    }
  }

  async function forgetRom() {
    sessionRom = null;
    try {
      const database = await openRomDatabase();
      await new Promise((resolve, reject) => {
        const transaction = database.transaction("roms", "readwrite");
        transaction.objectStore("roms").delete(CANONICAL_ROM_SHA256);
        transaction.addEventListener("complete", resolve);
        transaction.addEventListener("error", () => reject(transaction.error));
      });
      database.close();
    } catch {
      // Nothing else to clear when storage is unavailable.
    }
  }

  class SameBoyPlayer {
    constructor(root, detail) {
      this.root = root;
      this.detail = detail;
      this.worker = null;
      this.playing = false;
      this.romReady = false;
      this.manifest = null;
      this.manifestError = null;
      this.abortController = new AbortController();
      this.replayStarted = false;
      this.audioContext = null;
      this.audioBus = null;
      this.monitorGain = null;
      this.recordingDestination = null;
      this.audioSources = new Set();
      this.audioNextTime = 0;
      this.soundEnabled = false;
      this.exporting = false;
      this.discardVideo = false;
      this.recorder = null;
      this.recordedChunks = [];
      this.build();
    }

    build() {
      this.root.replaceChildren();
      this.root.className = "emulator-replay";
      const header = node("div", "emulator-header");
      const heading = node("div");
      heading.append(node("span", "label", "SameBoy · DMG-B"), node("h3", "", "Recorded battle replay"));
      this.status = node("span", "emulator-status", "Reconstructing the exact battle manifest…");
      header.append(heading, this.status);

      const screenShell = node("div", "emulator-screen-shell");
      this.canvas = node("canvas", "emulator-screen");
      this.canvas.width = 640;
      this.canvas.height = 576;
      this.context = this.canvas.getContext("2d", { alpha: false });
      this.context.imageSmoothingEnabled = false;
      this.frameCanvas = document.createElement("canvas");
      this.frameCanvas.width = 160;
      this.frameCanvas.height = 144;
      this.frameContext = this.frameCanvas.getContext("2d", { alpha: false });
      screenShell.append(this.canvas);

      const controls = node("div", "emulator-toolbar");
      this.playButton = node("button", "secondary-button", "Pause");
      this.playButton.type = "button";
      this.playButton.disabled = true;
      this.playButton.addEventListener("click", () => this.togglePlayback());
      this.resetButton = node("button", "secondary-button", "Restart replay");
      this.resetButton.type = "button";
      this.resetButton.disabled = true;
      this.resetButton.addEventListener("click", () => this.restartReplay());
      this.speed = node("select", "emulator-speed");
      this.speed.setAttribute("aria-label", "Playback speed");
      for (const value of [0.5, 1, 2, 4, 8]) {
        const option = node("option", "", `${value}×`);
        option.value = value;
        option.selected = value === 1;
        this.speed.append(option);
      }
      this.speed.addEventListener("change", () => {
        this.resetAudioTimeline();
        this.worker?.postMessage({ type: "speed", value: Number(this.speed.value) });
      });
      this.soundButton = node("button", "secondary-button", "Sound off");
      this.soundButton.type = "button";
      this.soundButton.setAttribute("aria-pressed", "false");
      this.soundButton.addEventListener("click", () => this.toggleSound());
      this.exportButton = node("button", "primary-button", "Export video");
      this.exportButton.type = "button";
      this.exportButton.disabled = true;
      this.exportButton.addEventListener("click", () => this.exportVideo());
      controls.append(this.playButton, this.resetButton, this.speed, this.soundButton, this.exportButton);

      const picker = node("div", "rom-picker");
      const pickerCopy = node("div");
      pickerCopy.append(node("strong", "", "Canonical Pokémon Red required"), node("p", "", "Choose the .zip or extracted .gb file. It is hash-checked and stays in this browser; ROM bytes are never uploaded."));
      const fileLabel = node("label", "primary-button", "Choose ROM");
      this.file = node("input", "visually-hidden");
      this.file.type = "file";
      this.file.accept = ".zip,.gb,.gbc,application/zip";
      this.file.addEventListener("change", () => this.loadSelectedFile());
      fileLabel.append(this.file);
      this.clearButton = node("button", "text-button", "Forget stored ROM");
      this.clearButton.type = "button";
      this.clearButton.addEventListener("click", async () => {
        await forgetRom();
        this.disposeWorker();
        this.setStatus("Stored ROM removed", "waiting");
        this.clearButton.hidden = true;
      });
      this.clearButton.hidden = true;
      const pickerActions = node("div", "rom-picker-actions");
      pickerActions.append(fileLabel, this.clearButton);
      picker.append(pickerCopy, pickerActions);

      const decisions = (this.detail.timeline || []).length;
      const note = node("p", "emulator-note", `The server replays all ${decisions} recorded decisions through the deterministic Lean engine before playback. SameBoy stages both parties and the link RNG in the canonical ROM, injects every recorded choice, and synchronizes active Pokémon, volatile multi-turn state, move scratch, and RNG to the validated trace at each decision boundary. Background music is disabled while cartridge cries and sound effects remain. Export video restarts the replay at normal speed and downloads a 640×576 browser-encoded video with those original sound effects. Any corrected cartridge bytes are reported at completion.`);
      const attribution = node("p", "emulator-attribution");
      attribution.append("SameBoy core pinned at 213a12ce · ", Object.assign(node("a", "", "license"), { href: "/sameboy-LICENSE.txt", target: "_blank", rel: "noreferrer" }), ". No ROM is included with this application.");
      this.root.append(header, screenShell, controls, picker, note, attribution);

      this.loadReplayManifest();
      this.tryCachedRom();
    }

    setStatus(message, state = "") {
      this.status.textContent = message;
      this.status.className = `emulator-status${state ? ` ${state}` : ""}`;
    }

    async loadReplayManifest() {
      const match = this.detail.episode ?? this.detail.game;
      const query = new URLSearchParams({
        kind: this.detail.kind,
        iteration: String(this.detail.iteration),
        match: String(match),
      });
      try {
        const response = await fetch(`/api/replay?${query}`, { signal: this.abortController.signal });
        const payload = await response.json();
        if (!response.ok) throw new Error(payload.error || "Exact replay manifest is unavailable");
        this.manifest = payload;
        this.updateReadyStatus();
        this.maybeStartReplay();
      } catch (error) {
        if (error?.name === "AbortError") return;
        this.manifestError = error instanceof Error ? error.message : String(error);
        this.setStatus(this.manifestError, "error");
      }
    }

    updateReadyStatus() {
      if (this.manifestError) return;
      if (this.romReady && this.manifest) {
        this.setStatus(`Exact ${this.manifest.decision_count}-decision replay ready`, "ready");
      } else if (this.romReady) {
        this.setStatus("Canonical ROM verified · reconstructing battle…", "loading");
      } else if (this.manifest) {
        this.setStatus("Exact replay reconstructed · choose the canonical ROM", "waiting");
      }
    }

    maybeStartReplay() {
      if (this.replayStarted || !this.worker || !this.manifest || !this.romReady) return;
      this.startRecordedBattle();
    }

    startRecordedBattle() {
      if (!this.worker || !this.manifest || !this.romReady) return;
      this.replayStarted = true;
      this.resetButton.disabled = false;
      this.exportButton.disabled = !this.canExportVideo();
      this.worker.postMessage({ type: "recorded-battle", manifest: this.manifest });
      this.setStatus("Launching the selected battle through Pokémon Red…", "loading");
    }

    restartReplay() {
      if (!this.worker || !this.manifest || !this.romReady || this.exporting) return;
      this.stopScheduledAudio();
      this.worker.postMessage({ type: "reset" });
      this.worker.postMessage({ type: "speed", value: Number(this.speed.value) });
      this.worker.postMessage({ type: "recorded-battle", manifest: this.manifest });
      this.replayStarted = true;
      this.setStatus("Restarting the recorded battle…", "loading");
    }

    canExportVideo() {
      return typeof MediaRecorder !== "undefined"
        && typeof this.canvas.captureStream === "function"
        && Boolean(window.AudioContext || window.webkitAudioContext);
    }

    videoMimeType() {
      return [
        "video/webm;codecs=vp9,opus",
        "video/webm;codecs=vp8,opus",
        "video/webm",
        "video/mp4",
      ].find((type) => MediaRecorder.isTypeSupported(type)) || "";
    }

    async ensureAudio() {
      if (!this.audioContext) {
        const AudioContextClass = window.AudioContext || window.webkitAudioContext;
        if (!AudioContextClass) throw new Error("This browser cannot play or record emulator audio");
        this.audioContext = new AudioContextClass({ sampleRate: 48000 });
        this.audioBus = this.audioContext.createGain();
        this.monitorGain = this.audioContext.createGain();
        this.recordingDestination = this.audioContext.createMediaStreamDestination();
        this.audioBus.connect(this.monitorGain);
        this.audioBus.connect(this.recordingDestination);
        this.monitorGain.connect(this.audioContext.destination);
        this.monitorGain.gain.value = this.soundEnabled ? 0.35 : 0;
      }
      if (this.audioContext.state === "suspended") await this.audioContext.resume();
    }

    async toggleSound() {
      try {
        await this.ensureAudio();
        this.soundEnabled = !this.soundEnabled;
        this.monitorGain.gain.setTargetAtTime(this.soundEnabled ? 0.35 : 0, this.audioContext.currentTime, 0.01);
        this.soundButton.textContent = this.soundEnabled ? "Sound on" : "Sound off";
        this.soundButton.setAttribute("aria-pressed", String(this.soundEnabled));
        if (!this.soundEnabled && !this.exporting) this.stopScheduledAudio();
      } catch (error) {
        this.setStatus(error instanceof Error ? error.message : String(error), "error");
      }
    }

    resetAudioTimeline() {
      this.audioNextTime = 0;
    }

    stopScheduledAudio() {
      for (const source of this.audioSources) {
        try {
          source.stop();
        } catch {
          // A source that has already ended needs no cleanup.
        }
      }
      this.audioSources.clear();
      this.resetAudioTimeline();
    }

    queueAudio(message) {
      if (!this.audioContext || this.audioContext.state !== "running" || (!this.soundEnabled && !this.exporting)) return;
      const frames = Number(message.frames) || 0;
      if (!frames) return;
      const pcm = new Int16Array(message.samples);
      const buffer = this.audioContext.createBuffer(2, frames, Number(message.sampleRate) || 48000);
      const left = buffer.getChannelData(0);
      const right = buffer.getChannelData(1);
      for (let index = 0; index < frames; index += 1) {
        left[index] = pcm[index * 2] / 32768;
        right[index] = pcm[index * 2 + 1] / 32768;
      }
      const source = this.audioContext.createBufferSource();
      const playbackSpeed = Math.max(0.25, Number(message.speed) || 1);
      source.buffer = buffer;
      source.playbackRate.value = playbackSpeed;
      source.connect(this.audioBus);
      source.addEventListener("ended", () => {
        source.disconnect();
        this.audioSources.delete(source);
      }, { once: true });
      const now = this.audioContext.currentTime;
      if (!this.audioNextTime || this.audioNextTime < now - 0.02 || this.audioNextTime > now + 0.25) {
        this.audioNextTime = now + 0.04;
      }
      source.start(this.audioNextTime);
      this.audioNextTime += frames / buffer.sampleRate / playbackSpeed;
      this.audioSources.add(source);
    }

    async exportVideo() {
      if (!this.canExportVideo() || !this.worker || !this.manifest || !this.romReady || this.exporting) return;
      try {
        await this.ensureAudio();
        this.stopScheduledAudio();
        this.exporting = true;
        this.discardVideo = false;
        this.recordedChunks = [];
        this.speed.value = "1";
        this.speed.disabled = true;
        this.playButton.disabled = true;
        this.resetButton.disabled = true;
        this.exportButton.disabled = true;
        this.exportButton.textContent = "Exporting…";

        const canvasStream = this.canvas.captureStream(60);
        this.recordingStream = new MediaStream([
          ...canvasStream.getVideoTracks(),
          ...this.recordingDestination.stream.getAudioTracks(),
        ]);
        const mimeType = this.videoMimeType();
        this.recorder = new MediaRecorder(this.recordingStream, {
          ...(mimeType ? { mimeType } : {}),
          videoBitsPerSecond: 4_000_000,
          audioBitsPerSecond: 128_000,
        });
        this.recorder.addEventListener("dataavailable", (event) => {
          if (event.data.size) this.recordedChunks.push(event.data);
        });
        this.recorder.addEventListener("error", (event) => {
          this.failVideoExport(event.error || new Error("The browser could not record this replay"));
        });
        this.recorder.addEventListener("stop", () => {
          if (this.discardVideo) this.resetVideoExport();
          else this.downloadVideo();
        }, { once: true });
        this.recorder.start(1000);
        this.worker.postMessage({ type: "reset" });
        this.worker.postMessage({ type: "speed", value: 1 });
        this.worker.postMessage({ type: "recorded-battle", manifest: this.manifest });
        this.replayStarted = true;
        this.setStatus("Exporting video with cartridge sound effects · entering battle…", "loading");
      } catch (error) {
        this.failVideoExport(error);
      }
    }

    finishVideoExport() {
      if (!this.exporting || !this.recorder || this.recorder.state === "inactive") return;
      this.setStatus("Finalizing replay video and sound effects…", "loading");
      window.setTimeout(() => {
        if (this.recorder?.state !== "inactive") this.recorder.stop();
      }, 350);
    }

    downloadVideo() {
      const mimeType = this.recorder?.mimeType || this.videoMimeType() || "video/webm";
      const blob = new Blob(this.recordedChunks, { type: mimeType });
      if (blob.size) {
        const extension = mimeType.includes("mp4") ? "mp4" : "webm";
        const match = this.detail.episode ?? this.detail.game;
        const filename = `pokemon-red-${this.detail.kind}-${this.detail.iteration}-${match}.${extension}`;
        const url = URL.createObjectURL(blob);
        const anchor = document.createElement("a");
        anchor.href = url;
        anchor.download = filename;
        anchor.click();
        window.setTimeout(() => URL.revokeObjectURL(url), 60_000);
        this.setStatus(`Video downloaded · ${(blob.size / 1_048_576).toFixed(1)} MiB · sound effects included`, "ready");
      } else {
        this.setStatus("The browser produced an empty replay video", "error");
      }
      this.resetVideoExport();
    }

    failVideoExport(error) {
      this.discardVideo = true;
      this.setStatus(error instanceof Error ? error.message : String(error), "error");
      if (this.recorder?.state && this.recorder.state !== "inactive") {
        try {
          this.recorder.stop();
          return;
        } catch {
          // The recorder may already be stopping after an encoder error.
        }
      }
      this.resetVideoExport();
    }

    resetVideoExport() {
      this.recordingStream?.getVideoTracks().forEach((track) => track.stop());
      this.recordingStream = null;
      this.recorder = null;
      this.recordedChunks = [];
      this.exporting = false;
      this.discardVideo = false;
      this.speed.disabled = false;
      this.playButton.disabled = !this.romReady;
      this.resetButton.disabled = !this.romReady || !this.manifest;
      this.exportButton.disabled = !this.romReady || !this.manifest || !this.canExportVideo();
      this.exportButton.textContent = "Export video";
      if (!this.soundEnabled) this.stopScheduledAudio();
    }

    async tryCachedRom() {
      const rom = await cachedRom();
      if (rom && activePlayer === this) {
        this.clearButton.hidden = false;
        this.start(rom);
      }
    }

    async loadSelectedFile() {
      const file = this.file.files?.[0];
      if (!file) return;
      this.setStatus("Reading and checking ROM…", "loading");
      try {
        const rom = await readRom(file);
        if (rom.byteLength !== ROM_BYTES) throw new Error(`Expected a 1 MiB ROM, received ${rom.byteLength.toLocaleString()} bytes`);
        const digest = await sha256(rom);
        if (digest !== CANONICAL_ROM_SHA256) throw new Error(`ROM hash mismatch (${digest.slice(0, 12)}…); expected canonical Pokémon Red`);
        await rememberRom(rom);
        this.clearButton.hidden = false;
        this.start(rom);
      } catch (error) {
        this.setStatus(error instanceof Error ? error.message : String(error), "error");
      } finally {
        this.file.value = "";
      }
    }

    start(rom) {
      this.disposeWorker();
      this.romReady = false;
      this.replayStarted = false;
      this.setStatus("Starting SameBoy…", "loading");
      this.worker = new Worker("/sameboy-worker.js?v=29", { type: "module" });
      this.worker.addEventListener("message", (event) => this.onMessage(event.data));
      this.worker.addEventListener("error", (event) => this.setStatus(event.message || "SameBoy worker failed", "error"));
      const payload = rom.slice().buffer;
      this.worker.postMessage({ type: "load", rom: payload }, [payload]);
    }

    onMessage(message) {
      if (message.type === "ready") {
        this.playing = true;
        this.romReady = true;
        this.playButton.disabled = false;
        this.resetButton.disabled = !this.manifest;
        this.exportButton.disabled = !this.manifest || !this.canExportVideo();
        this.playButton.textContent = "Pause";
        this.updateReadyStatus();
        this.maybeStartReplay();
      } else if (message.type === "frame") {
        const pixels = new Uint8ClampedArray(message.frame);
        this.frameContext.putImageData(new ImageData(pixels, 160, 144), 0, 0);
        this.context.drawImage(this.frameCanvas, 0, 0, this.canvas.width, this.canvas.height);
        this.canvas.dataset.programCounter = Number(message.programCounter).toString(16).padStart(4, "0");
        this.canvas.dataset.replayState = String(message.replayState);
        this.canvas.dataset.replayAction = String(message.replayActionIndex);
        this.canvas.dataset.replayHook = String(message.replayLastHook);
        this.canvas.dataset.replayMismatches = String(message.replayMismatchCount);
        this.canvas.dataset.replayFirstMismatch = String(message.replayFirstMismatch);
        this.canvas.dataset.replayFirstExpected = String(message.replayFirstExpected);
        this.canvas.dataset.replayFirstActual = String(message.replayFirstActual);
      } else if (message.type === "audio") {
        this.queueAudio(message);
      } else if (message.type === "replay-state") {
        const total = this.manifest?.decision_count ?? 0;
        if (message.state === 0) {
          this.playing = true;
          this.playButton.textContent = "Pause";
          if (!this.exporting) this.updateReadyStatus();
        } else if (message.state === 1 || message.state === 2) {
          this.playing = true;
          this.playButton.textContent = "Pause";
          this.setStatus(this.exporting ? "Exporting video with cartridge sound effects · entering battle…" : "Entering the recorded battle…", "loading");
        } else if (message.state === 3) {
          this.playing = true;
          this.playButton.textContent = "Pause";
          const prefix = this.exporting ? "Exporting video" : "Replaying";
          this.setStatus(`${prefix} · decision ${Math.min(message.actionIndex + 1, total)} of ${total}`, "loading");
        } else if (message.state === 4) {
          this.playing = false;
          this.playButton.textContent = "Play";
          if (this.exporting) {
            this.finishVideoExport();
          } else if (message.mismatchCount === 0) {
            this.setStatus(`Replay complete · ${total} cartridge checkpoints matched`, "ready");
          } else {
            this.setStatus(`Replay complete · ${total} decisions reproduced · ${message.mismatchCount} boundary bytes resynchronized`, "ready");
          }
        } else if (message.state < 0) {
          const reason = REPLAY_FAILURES[String(message.state)] || "the cartridge and recorded action stream diverged";
          const decision = Math.min(message.actionIndex + 1, total);
          const error = new Error(`Replay stopped at decision ${decision}: ${reason} (code ${message.state})`);
          if (this.exporting) this.failVideoExport(error);
          else this.setStatus(error.message, "error");
        }
      } else if (message.type === "error") {
        if (this.exporting) this.failVideoExport(new Error(message.message));
        else this.setStatus(message.message, "error");
        this.playButton.disabled = true;
        this.resetButton.disabled = true;
        this.exportButton.disabled = true;
      }
    }

    togglePlayback() {
      if (!this.worker || this.exporting) return;
      this.playing = !this.playing;
      this.worker.postMessage({ type: this.playing ? "play" : "pause" });
      this.playButton.textContent = this.playing ? "Pause" : "Play";
      this.setStatus(this.playing ? "Canonical ROM verified · running locally" : "Paused", this.playing ? "ready" : "waiting");
    }

    disposeWorker() {
      this.stopScheduledAudio();
      this.worker?.terminate();
      this.worker = null;
      this.playing = false;
      this.playButton.disabled = true;
      this.resetButton.disabled = true;
      this.exportButton.disabled = true;
      this.romReady = false;
      this.replayStarted = false;
    }

    dispose() {
      this.abortController.abort();
      if (this.exporting) this.failVideoExport(new Error("Video export canceled"));
      this.disposeWorker();
      this.audioContext?.close();
      this.audioContext = null;
      this.root.replaceChildren();
    }
  }

  window.BattleEmulator = {
    mount(root, detail) {
      activePlayer?.dispose();
      activePlayer = new SameBoyPlayer(root, detail);
      return activePlayer;
    },
    dispose() {
      activePlayer?.dispose();
      activePlayer = null;
    },
  };
})();
