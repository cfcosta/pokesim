import createSameBoy from "./sameboy-core.js?v=9";

let core = null;
let loaded = false;
let playing = false;
let speed = 1;
let timer = null;
let frameCredit = 0;
let frameNumber = 0;
let emulatedFrames = 0;
let demoState = 0;
let demoAPressed = false;
let demoStartPressed = false;

function sendError(error) {
  self.postMessage({ type: "error", message: error instanceof Error ? error.message : String(error) });
}

function publishFrame() {
  const pointer = core._sb_framebuffer();
  const size = core._sb_framebuffer_size();
  const frame = core.HEAPU8.slice(pointer, pointer + size).buffer;
  frameNumber += 1;
  self.postMessage({
    type: "frame",
    frame,
    frameNumber,
    programCounter: core._sb_program_counter(),
  }, [frame]);
}

function tick() {
  if (!core || !loaded || !playing) return;
  frameCredit += speed;
  let ran = false;
  while (frameCredit >= 1) {
    if (core._sb_run_frame() !== 0) throw new Error("SameBoy could not advance the loaded ROM");
    emulatedFrames += 1;
    if (demoState === 2) {
      const shouldPressA = emulatedFrames % 24 < 2;
      if (shouldPressA !== demoAPressed) {
        demoAPressed = shouldPressA;
        core._sb_set_key(4, demoAPressed ? 1 : 0);
      }
      const shouldPressStart = emulatedFrames % 120 >= 60 && emulatedFrames % 120 < 62;
      if (shouldPressStart !== demoStartPressed) {
        demoStartPressed = shouldPressStart;
        core._sb_set_key(7, demoStartPressed ? 1 : 0);
      }
    }
    frameCredit -= 1;
    ran = true;
  }
  if (ran) {
    publishFrame();
    const nextDemoState = core._sb_test_battle_state();
    if (nextDemoState !== demoState) {
      demoState = nextDemoState;
      self.postMessage({ type: "demo-state", state: demoState });
    }
  }
}

function startClock() {
  if (timer !== null) return;
  timer = self.setInterval(() => {
    try {
      tick();
    } catch (error) {
      playing = false;
      sendError(error);
    }
  }, 1000 / 60);
}

async function initialize(rom) {
  core ||= await createSameBoy({ locateFile: (path) => path.endsWith(".wasm") ? "/sameboy-core.wasm?v=9" : path });
  core._sb_create();
  const bytes = new Uint8Array(rom);
  const pointer = core._malloc(bytes.byteLength);
  try {
    core.HEAPU8.set(bytes, pointer);
    if (core._sb_load_rom(pointer, bytes.byteLength) !== 0) {
      throw new Error("SameBoy rejected the supplied ROM");
    }
  } finally {
    core._free(pointer);
  }
  loaded = true;
  playing = true;
  frameCredit = 0;
  frameNumber = 0;
  emulatedFrames = 0;
  demoState = 0;
  demoAPressed = false;
  demoStartPressed = false;
  startClock();
  self.postMessage({ type: "ready" });
}

async function saveState(request) {
  const size = core._sb_state_size();
  const pointer = core._malloc(size);
  try {
    const written = core._sb_save_state(pointer, size);
    if (written <= 0) throw new Error("SameBoy could not create a save state");
    const state = core.HEAPU8.slice(pointer, pointer + written).buffer;
    self.postMessage({ type: "state", request, state }, [state]);
  } finally {
    core._free(pointer);
  }
}

function loadState(state) {
  const bytes = new Uint8Array(state);
  const pointer = core._malloc(bytes.byteLength);
  try {
    core.HEAPU8.set(bytes, pointer);
    if (core._sb_load_state(pointer, bytes.byteLength) !== 0) {
      throw new Error("SameBoy rejected the save state");
    }
  } finally {
    core._free(pointer);
  }
  publishFrame();
}

self.addEventListener("message", async (event) => {
  const message = event.data || {};
  try {
    if (message.type === "load") {
      await initialize(message.rom);
    } else if (message.type === "play") {
      playing = true;
    } else if (message.type === "pause") {
      playing = false;
    } else if (message.type === "speed") {
      speed = Math.max(0.25, Math.min(8, Number(message.value) || 1));
    } else if (message.type === "reset") {
      core._sb_reset();
      frameCredit = 0;
      frameNumber = 0;
      emulatedFrames = 0;
      demoState = 0;
      demoAPressed = false;
      demoStartPressed = false;
      playing = true;
      self.postMessage({ type: "demo-state", state: 0 });
    } else if (message.type === "demo-battle") {
      core._sb_start_test_battle();
    } else if (message.type === "key") {
      core._sb_set_key(Number(message.key), message.pressed ? 1 : 0);
    } else if (message.type === "save-state") {
      await saveState(message.request);
    } else if (message.type === "load-state") {
      loadState(message.state);
    } else if (message.type === "read-memory") {
      const value = core._sb_read_memory(Number(message.address) & 0xffff);
      self.postMessage({ type: "memory", request: message.request, value });
    } else if (message.type === "write-memory") {
      core._sb_write_memory(Number(message.address) & 0xffff, Number(message.value) & 0xff);
    }
  } catch (error) {
    sendError(error);
  }
});
