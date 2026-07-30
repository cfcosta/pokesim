"use strict";

(() => {
  const CANONICAL_ROM_SHA256 = "5ca7ba01642a3b27b0cc0b5349b52792795b62d3ed977e98a09390659af96b7b";
  const ROM_BYTES = 1024 * 1024;
  const KEY_CODES = {
    ArrowRight: 0, ArrowLeft: 1, ArrowUp: 2, ArrowDown: 3,
    z: 4, x: 5, Shift: 6, Enter: 7,
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
      this.pressed = new Set();
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
      this.canvas.width = 160;
      this.canvas.height = 144;
      this.canvas.tabIndex = 0;
      this.context = this.canvas.getContext("2d", { alpha: false });
      this.context.imageSmoothingEnabled = false;
      screenShell.append(this.canvas);

      const controls = node("div", "emulator-toolbar");
      this.playButton = node("button", "secondary-button", "Pause");
      this.playButton.type = "button";
      this.playButton.disabled = true;
      this.playButton.addEventListener("click", () => this.togglePlayback());
      const reset = node("button", "secondary-button", "Restart ROM");
      reset.type = "button";
      reset.addEventListener("click", () => this.worker?.postMessage({ type: "reset" }));
      this.replayButton = node("button", "secondary-button", "Start recorded battle");
      this.replayButton.type = "button";
      this.replayButton.disabled = true;
      this.replayButton.addEventListener("click", () => this.startRecordedBattle());
      this.speed = node("select", "emulator-speed");
      this.speed.setAttribute("aria-label", "Playback speed");
      for (const value of [0.5, 1, 2, 4, 8]) {
        const option = node("option", "", `${value}×`);
        option.value = value;
        option.selected = value === 1;
        this.speed.append(option);
      }
      this.speed.addEventListener("change", () => this.worker?.postMessage({ type: "speed", value: Number(this.speed.value) }));
      controls.append(this.playButton, reset, this.replayButton, this.speed);

      const pad = node("div", "emulator-pad");
      const directional = node("div", "emulator-dpad");
      directional.append(this.keyButton("↑", 2, "dpad-up"), this.keyButton("←", 1, "dpad-left"), this.keyButton("→", 0, "dpad-right"), this.keyButton("↓", 3, "dpad-down"));
      const system = node("div", "emulator-system-buttons");
      system.append(this.keyButton("Select", 6), this.keyButton("Start", 7));
      const actions = node("div", "emulator-action-buttons");
      actions.append(this.keyButton("B", 5, "button-b"), this.keyButton("A", 4, "button-a"));
      pad.append(directional, system, actions);

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
      const note = node("p", "emulator-note", `The server replays all ${decisions} recorded decisions through the deterministic Lean engine before playback. SameBoy stages both parties and the link RNG in the canonical ROM, injects every recorded choice, and synchronizes HP, status, PP, active slots, and RNG to the validated trace at each decision boundary. Any corrected cartridge bytes are reported at completion.`);
      const attribution = node("p", "emulator-attribution");
      attribution.append("SameBoy core pinned at 213a12ce · ", Object.assign(node("a", "", "license"), { href: "/sameboy-LICENSE.txt", target: "_blank", rel: "noreferrer" }), ". No ROM is included with this application.");
      this.root.append(header, screenShell, controls, pad, picker, note, attribution);

      this.canvas.addEventListener("keydown", (event) => this.keyboard(event, true));
      this.canvas.addEventListener("keyup", (event) => this.keyboard(event, false));
      this.canvas.addEventListener("blur", () => this.releaseAll());
      this.loadReplayManifest();
      this.tryCachedRom();
    }

    keyButton(label, key, className = "") {
      const button = node("button", `emulator-key ${className}`, label);
      button.type = "button";
      button.setAttribute("aria-label", `${label} button`);
      const press = (event) => {
        event.preventDefault();
        this.canvas.focus({ preventScroll: true });
        this.setKey(key, true);
        button.classList.add("is-pressed");
      };
      const release = (event) => {
        event.preventDefault();
        this.setKey(key, false);
        button.classList.remove("is-pressed");
      };
      button.addEventListener("pointerdown", press);
      button.addEventListener("pointerup", release);
      button.addEventListener("pointercancel", release);
      button.addEventListener("pointerleave", (event) => {
        if (event.buttons) release(event);
      });
      return button;
    }

    keyboard(event, pressed) {
      const lookup = event.key.length === 1 ? event.key.toLowerCase() : event.key;
      const key = KEY_CODES[lookup];
      if (key === undefined) return;
      event.preventDefault();
      if (!event.repeat || !pressed) this.setKey(key, pressed);
    }

    setKey(key, pressed) {
      if (!this.worker) return;
      if (pressed) this.pressed.add(key);
      else this.pressed.delete(key);
      this.worker.postMessage({ type: "key", key, pressed });
    }

    releaseAll() {
      for (const key of this.pressed) this.worker?.postMessage({ type: "key", key, pressed: false });
      this.pressed.clear();
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
        this.replayButton.disabled = !this.romReady;
        this.updateReadyStatus();
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

    startRecordedBattle() {
      if (!this.worker || !this.manifest || !this.romReady) return;
      this.replayButton.disabled = true;
      this.worker.postMessage({ type: "recorded-battle", manifest: this.manifest });
      this.setStatus("Launching the selected battle through Pokémon Red…", "loading");
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
      this.setStatus("Starting SameBoy…", "loading");
      this.worker = new Worker("/sameboy-worker.js?v=26", { type: "module" });
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
        this.replayButton.disabled = !this.manifest;
        this.playButton.textContent = "Pause";
        this.updateReadyStatus();
        this.canvas.focus({ preventScroll: true });
      } else if (message.type === "frame") {
        const pixels = new Uint8ClampedArray(message.frame);
        this.context.putImageData(new ImageData(pixels, 160, 144), 0, 0);
        this.canvas.dataset.programCounter = Number(message.programCounter).toString(16).padStart(4, "0");
        this.canvas.dataset.replayState = String(message.replayState);
        this.canvas.dataset.replayAction = String(message.replayActionIndex);
        this.canvas.dataset.replayHook = String(message.replayLastHook);
        this.canvas.dataset.replayMismatches = String(message.replayMismatchCount);
        this.canvas.dataset.replayFirstMismatch = String(message.replayFirstMismatch);
        this.canvas.dataset.replayFirstExpected = String(message.replayFirstExpected);
        this.canvas.dataset.replayFirstActual = String(message.replayFirstActual);
      } else if (message.type === "replay-state") {
        const total = this.manifest?.decision_count ?? 0;
        if (message.state === 0) {
          this.playing = true;
          this.playButton.textContent = "Pause";
          this.replayButton.disabled = !this.manifest || !this.romReady;
          this.updateReadyStatus();
        } else if (message.state === 1 || message.state === 2) {
          this.playing = true;
          this.playButton.textContent = "Pause";
          this.setStatus("Entering the recorded battle…", "loading");
        } else if (message.state === 3) {
          this.playing = true;
          this.playButton.textContent = "Pause";
          this.setStatus(`Replaying decision ${Math.min(message.actionIndex + 1, total)} of ${total}`, "loading");
        } else if (message.state === 4 && message.mismatchCount === 0) {
          this.playing = false;
          this.playButton.textContent = "Play";
          this.setStatus(`Replay complete · ${total} cartridge checkpoints matched`, "ready");
        } else if (message.state === 4) {
          this.playing = false;
          this.playButton.textContent = "Play";
          this.setStatus(`Replay complete · ${total} decisions reproduced · ${message.mismatchCount} boundary bytes resynchronized`, "ready");
        } else if (message.state < 0) {
          this.setStatus(`Replay adapter stopped with code ${message.state}`, "error");
        }
      } else if (message.type === "error") {
        this.setStatus(message.message, "error");
        this.playButton.disabled = true;
        this.replayButton.disabled = true;
      }
    }

    togglePlayback() {
      if (!this.worker) return;
      this.playing = !this.playing;
      this.worker.postMessage({ type: this.playing ? "play" : "pause" });
      this.playButton.textContent = this.playing ? "Pause" : "Play";
      this.setStatus(this.playing ? "Canonical ROM verified · running locally" : "Paused", this.playing ? "ready" : "waiting");
    }

    disposeWorker() {
      this.releaseAll();
      this.worker?.terminate();
      this.worker = null;
      this.playing = false;
      this.playButton.disabled = true;
      this.replayButton.disabled = true;
      this.romReady = false;
    }

    dispose() {
      this.abortController.abort();
      this.disposeWorker();
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
