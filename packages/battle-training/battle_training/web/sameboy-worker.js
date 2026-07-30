import createSameBoy from "./sameboy-core.js?v=23";

let core = null;
let loaded = false;
let playing = false;
let speed = 1;
let timer = null;
let frameCredit = 0;
let frameNumber = 0;
let emulatedFrames = 0;
let demoState = 0;
let replayState = 0;
let replayActionIndex = 0;
let autoAPressed = false;
let autoStartPressed = false;

const REQUEST_CODES = { battle: 0, "forced-player": 1, "forced-enemy": 2 };
const REPLAY_VERSION = "pokered-recorded-link-replay-v2";

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
    replayState: core._sb_replay_state(),
    replayActionIndex: core._sb_replay_action_index(),
    replayLastHook: core._sb_replay_last_hook(),
    replayMismatchCount: core._sb_replay_mismatch_count(),
    replayFirstMismatch: core._sb_replay_first_mismatch(),
    replayFirstExpected: core._sb_replay_first_expected(),
    replayFirstActual: core._sb_replay_first_actual(),
  }, [frame]);
}

function setAutomaticInput(enabled) {
  const shouldPressA = enabled && emulatedFrames % 24 < 2;
  if (shouldPressA !== autoAPressed) {
    autoAPressed = shouldPressA;
    core._sb_set_key(4, autoAPressed ? 1 : 0);
  }
  const shouldPressStart = enabled && emulatedFrames % 120 >= 60 && emulatedFrames % 120 < 62;
  if (shouldPressStart !== autoStartPressed) {
    autoStartPressed = shouldPressStart;
    core._sb_set_key(7, autoStartPressed ? 1 : 0);
  }
}

function publishRuntimeState() {
  const nextDemoState = core._sb_test_battle_state();
  if (nextDemoState !== demoState) {
    demoState = nextDemoState;
    self.postMessage({ type: "demo-state", state: demoState });
  }
  const nextReplayState = core._sb_replay_state();
  const nextActionIndex = core._sb_replay_action_index();
  if (nextReplayState !== replayState || nextActionIndex !== replayActionIndex) {
    replayState = nextReplayState;
    replayActionIndex = nextActionIndex;
    const message = {
      type: "replay-state",
      state: replayState,
      actionIndex: replayActionIndex,
      mismatchCount: core._sb_replay_mismatch_count(),
      firstMismatch: core._sb_replay_first_mismatch(),
    };
    self.postMessage(message);
    if (replayState === 4 || replayState < 0) {
      playing = false;
      setAutomaticInput(false);
    }
  }
}

function tick() {
  if (!core || !loaded || !playing) return;
  frameCredit += speed;
  let ran = false;
  while (frameCredit >= 1) {
    if (core._sb_run_frame() !== 0) throw new Error("SameBoy could not advance the loaded ROM");
    emulatedFrames += 1;
    setAutomaticInput(demoState === 2 || replayState === 1 || replayState === 2 || replayState === 3);
    publishRuntimeState();
    frameCredit -= 1;
    ran = true;
    if (!playing) break;
  }
  if (ran) publishFrame();
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
  core ||= await createSameBoy({ locateFile: (path) => path.endsWith(".wasm") ? "/sameboy-core.wasm?v=23" : path });
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
  replayState = 0;
  replayActionIndex = 0;
  autoAPressed = false;
  autoStartPressed = false;
  startClock();
  self.postMessage({ type: "ready" });
}

function checked(result, label) {
  if (result !== 0) throw new Error(`SameBoy rejected replay ${label}`);
}

function stageBytes(region, values, label) {
  values.forEach((value, offset) => {
    checked(core._sb_replay_set_byte(region, offset, value), `${label} byte ${offset}`);
  });
}

function configureReplay(manifest) {
  if (manifest?.version !== REPLAY_VERSION) throw new Error("Recorded replay manifest version is unsupported");
  const player = manifest.initial?.player;
  const enemy = manifest.initial?.enemy;
  const actions = manifest.actions || [];
  checked(core._sb_replay_configure(player.count, enemy.count, actions.length, manifest.outcome, manifest.presentation?.trainer_class), "header");
  [player, enemy].forEach((side, sideIndex) => {
    const base = sideIndex * 4;
    stageBytes(base, side.species, `${sideIndex ? "enemy" : "player"} species`);
    stageBytes(base + 1, side.structures, `${sideIndex ? "enemy" : "player"} party`);
    stageBytes(base + 2, side.ot_names, `${sideIndex ? "enemy" : "player"} OT names`);
    stageBytes(base + 3, side.nicknames, `${sideIndex ? "enemy" : "player"} nicknames`);
  });
  manifest.initial.rng.list.forEach((value, index) => {
    checked(core._sb_replay_set_rng(index, value), `RNG byte ${index}`);
  });
  checked(core._sb_replay_set_rng_index(manifest.initial.rng.index), "RNG index");
  actions.forEach((action, index) => {
    const request = REQUEST_CODES[action.request];
    if (request === undefined) throw new Error(`Recorded replay request ${action.request} is unsupported`);
    checked(core._sb_replay_set_action(index, action.player, action.enemy, request), `action ${index + 1}`);
  });
  (manifest.checkpoints || []).forEach((checkpoint, index) => {
    checkpoint.memory.forEach(([address, value]) => {
      checked(core._sb_replay_expect(index, address, value), `checkpoint ${index + 1}`);
    });
  });
  checked(core._sb_start_recorded_battle(), "start");
  replayState = 1;
  replayActionIndex = 0;
  playing = true;
  self.postMessage({ type: "replay-state", state: replayState, actionIndex: 0, mismatchCount: 0, firstMismatch: 0 });
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
      replayState = 0;
      replayActionIndex = 0;
      setAutomaticInput(false);
      playing = true;
      self.postMessage({ type: "demo-state", state: 0 });
      self.postMessage({ type: "replay-state", state: 0, actionIndex: 0, mismatchCount: 0, firstMismatch: 0 });
    } else if (message.type === "demo-battle") {
      core._sb_start_test_battle();
    } else if (message.type === "recorded-battle") {
      configureReplay(message.manifest);
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
    playing = false;
    sendError(error);
  }
});
