"use strict";

const $ = (id) => document.getElementById(id);
const SVG = "http://www.w3.org/2000/svg";
const SPRITE_REVISION = "8dfa3d97e953caaafaafd4963eff7621811af08e";
const SPRITE_BASE = `https://raw.githubusercontent.com/PokeAPI/sprites/${SPRITE_REVISION}/sprites/pokemon/versions/generation-i/red-blue`;
const TYPE_NAMES = {
  0x00: "Normal", 0x01: "Fighting", 0x02: "Flying", 0x03: "Poison",
  0x04: "Ground", 0x05: "Rock", 0x07: "Bug", 0x08: "Ghost",
  0x14: "Fire", 0x15: "Water", 0x16: "Grass", 0x17: "Electric",
  0x18: "Psychic", 0x19: "Ice", 0x1a: "Dragon",
};
const STAT_NAMES = ["Attack", "Defense", "Speed", "Special", "Accuracy", "Evasion"];
const MOVE_EFFECTS = {
  0x00: "Deals damage with no additional effect.", 0x02: "May poison the target.",
  0x03: "Restores HP equal to part of the damage dealt.", 0x04: "May burn the target.",
  0x05: "May freeze the target.", 0x06: "May paralyze the target.",
  0x07: "The user faints after the attack.", 0x08: "Only works on a sleeping target and drains HP.",
  0x09: "Copies the target's last move.", 0x0a: "Raises Attack by one stage.",
  0x0b: "Raises Defense by one stage.", 0x0c: "Raises Speed by one stage.",
  0x0d: "Raises Special by one stage.", 0x0e: "Raises accuracy by one stage.",
  0x0f: "Raises evasion by one stage.", 0x11: "Ignores ordinary accuracy checks.",
  0x12: "Lowers the target's Attack by one stage.", 0x13: "Lowers the target's Defense by one stage.",
  0x14: "Lowers the target's Speed by one stage.", 0x15: "Lowers the target's Special by one stage.",
  0x16: "Lowers the target's accuracy by one stage.", 0x17: "Lowers the target's evasion by one stage.",
  0x18: "Copies the target's types.", 0x19: "Resets stat stages and several battle effects.",
  0x1a: "Stores damage, then returns double damage.", 0x1b: "Attacks repeatedly, then may confuse the user.",
  0x1c: "Ends a wild battle or switches in trainer contexts.", 0x1d: "Hits two to five times.",
  0x1f: "May make the target flinch.", 0x20: "Puts the target to sleep.",
  0x21: "May poison the target.", 0x22: "May burn the target.",
  0x23: "May freeze the target.", 0x24: "May paralyze the target.",
  0x25: "May make the target flinch.", 0x26: "Attempts a one-hit knockout.",
  0x27: "Charges on the first turn and attacks on the second.", 0x28: "Removes half of the target's current HP.",
  0x29: "Deals fixed or level-based damage.", 0x2a: "Traps the target for multiple turns.",
  0x2b: "Becomes semi-invulnerable, then attacks.", 0x2c: "Hits twice.",
  0x2d: "The user takes crash damage if it misses.", 0x2e: "Prevents stat reductions.",
  0x2f: "Raises the user's critical-hit ratio (with Gen-I behavior).", 0x30: "The user takes recoil damage.",
  0x31: "Confuses the target.", 0x32: "Raises Attack by two stages.",
  0x33: "Raises Defense by two stages.", 0x34: "Raises Speed by two stages.",
  0x35: "Raises Special by two stages.", 0x36: "Raises accuracy by two stages.",
  0x37: "Raises evasion by two stages.", 0x38: "Restores the user's HP.",
  0x39: "Transforms into the target.", 0x3a: "Lowers the target's Attack by two stages.",
  0x3b: "Lowers the target's Defense by two stages.", 0x3c: "Lowers the target's Speed by two stages.",
  0x3d: "Lowers the target's Special by two stages.", 0x3e: "Lowers the target's accuracy by two stages.",
  0x3f: "Lowers the target's evasion by two stages.", 0x40: "Halves incoming special damage.",
  0x41: "Halves incoming physical damage.", 0x42: "Poisons the target.",
  0x43: "Paralyzes the target.", 0x44: "May lower the target's Attack.",
  0x45: "May lower the target's Defense.", 0x46: "May lower the target's Speed.",
  0x47: "May lower the target's Special.", 0x4c: "May confuse the target.",
  0x4d: "Hits twice and may poison the target.", 0x4f: "Creates a substitute using the user's HP.",
  0x50: "Requires a recharge turn after a successful hit.", 0x51: "Locks the user into Rage and raises Attack when hit.",
  0x52: "Temporarily copies one of the target's moves.", 0x53: "Calls another move at random.",
  0x54: "Seeds the target and drains HP each turn.", 0x55: "Has no battle effect.",
  0x56: "Disables one of the target's moves.",
};
const stageProgress = {
  initializing: 0.03,
  ready: 0.06,
  collection: 0.18,
  training: 0.55,
  promotion: 0.7,
  probes: 0.82,
  campaign: 0.9,
  checkpoint: 0.96,
  "iteration-complete": 1,
  "final-arena": 1,
  completed: 1,
  failed: 0,
};

function number(value, digits = 0) {
  if (value === null || value === undefined || Number.isNaN(Number(value))) return "—";
  return Number(value).toLocaleString(undefined, { maximumFractionDigits: digits, minimumFractionDigits: digits });
}

function compact(value) {
  if (value === null || value === undefined) return "—";
  return Intl.NumberFormat(undefined, { notation: "compact", maximumFractionDigits: 1 }).format(value);
}

function pct(value, digits = 1) {
  if (value === null || value === undefined) return "—";
  return `${(Number(value) * 100).toFixed(digits)}%`;
}

function shortHash(value) {
  return value ? `${value.slice(0, 8)}…${value.slice(-6)}` : "—";
}

function title(value) {
  return String(value || "waiting").replaceAll("-", " ").replace(/\b\w/g, (letter) => letter.toUpperCase());
}

function text(node, value) {
  node.textContent = value;
}

function clear(node) {
  while (node.firstChild) node.removeChild(node.firstChild);
}

function element(tag, className, content) {
  const node = document.createElement(tag);
  if (className) node.className = className;
  if (content !== undefined) node.textContent = content;
  return node;
}

function latestPromotion(data) {
  return data.status?.promotion || data.latest?.promotion || data.latest?.training?.promotion || null;
}

function renderConnection(data) {
  const stage = data.status?.stage || (data.summary ? "completed" : "waiting");
  const updated = data.status?.updated_at ? new Date(data.status.updated_at) : null;
  const stale = updated && !["completed", "failed"].includes(stage) && Date.now() - updated.getTime() > 30000;
  const dot = $("connection-dot");
  dot.className = `status-dot ${stage === "failed" ? "error" : stale ? "" : "live"}`;
  text($("connection-label"), stage === "failed" ? "Training failed" : stale ? "Update delayed" : data.summary ? "Run complete" : "Live artifacts");
  text($("last-updated"), updated ? `Updated ${updated.toLocaleTimeString()}` : "Waiting for status");
}

function renderRun(data) {
  const run = data.run || {};
  const config = run.config || {};
  const status = data.status || {};
  const completed = data.iterations.length;
  const total = config.iterations || data.summary?.iterations || 0;
  const currentIteration = status.iteration || Math.min(completed + 1, total);
  const stage = status.stage || (data.summary ? "completed" : "waiting");
  const stagePart = stageProgress[stage] ?? 0;
  const overall = total ? Math.min(1, (Math.max(0, currentIteration - 1) + stagePart) / total) : 0;

  text($("run-name"), run.pipeline || "Training run");
  text($("run-path"), data.root);
  text($("stage-pill"), title(stage));
  $("stage-pill").className = `stage-pill ${stage === "failed" ? "failed" : ["waiting", "completed"].includes(stage) ? "" : "active"}`;
  text($("stage-detail"), status.message || (currentIteration ? `Iteration ${currentIteration} of ${total}` : "No iteration started"));
  text($("iteration-progress-label"), total ? `${completed} / ${total}` : "0 / 0");
  $("iteration-progress-bar").style.width = `${overall * 100}%`;
  text($("pipeline-footer"), `${run.pipeline || "Unknown pipeline"} · ${run.profile || "No profile"}`);
}

function renderKpis(data) {
  const model = data.model || {};
  const checkpoint = model.checkpoint;
  const latest = data.latest;
  const collection = data.collection || latest?.collection;
  const promotion = latestPromotion(data);
  const network = model.network || {};

  text($("checkpoint-iteration"), checkpoint ? `Policy ${String(checkpoint.iteration).padStart(3, "0")}` : "Initialising");
  text($("checkpoint-hash"), checkpoint ? `${shortHash(checkpoint.sha256)} · ${compact(checkpoint.bytes)}B` : "No checkpoint published");
  text($("promotion-score"), promotion ? pct(promotion.score_with_nonfinishes_as_losses) : "—");
  text($("promotion-ci"), promotion ? `95% CI ${pct(promotion.paired_score_ci95?.[0])}–${pct(promotion.paired_score_ci95?.[1])}` : "No completed arena");
  text($("collection-finished"), collection ? `${number(collection.finished)} / ${number((collection.finished || 0) + (collection.truncated || 0) + (collection.semantic_divergences || 0))}` : "—");
  text($("collection-detail"), collection ? `${compact(collection.examples)} examples · ${number(collection.semantic_divergences)} divergences` : "No completed shard");
  text($("parameter-count"), compact(model.parameter_count));
  text($("model-shape"), network.d_model ? `${network.layers}L × ${network.d_model}d · ${network.heads} heads · ${network.precision?.toUpperCase()}` : "Architecture unavailable");
}

function svgNode(tag, attrs = {}) {
  const node = document.createElementNS(SVG, tag);
  for (const [key, value] of Object.entries(attrs)) node.setAttribute(key, value);
  return node;
}

function lineChart(container, series, options = {}) {
  clear(container);
  if (!series.some((item) => item.values.length)) {
    container.append(element("div", "empty-cell", "No completed measurements"));
    return;
  }
  const width = 760;
  const height = options.height || 190;
  const pad = { left: 40, right: 16, top: 14, bottom: 24 };
  const all = series.flatMap((item) => item.values.map((point) => point.y)).filter(Number.isFinite);
  let min = options.min ?? Math.min(...all);
  let max = options.max ?? Math.max(...all);
  if (max === min) { max += 0.5; min -= 0.5; }
  const count = Math.max(2, ...series.map((item) => item.values.length));
  const x = (index) => pad.left + index / (count - 1) * (width - pad.left - pad.right);
  const y = (value) => pad.top + (max - value) / (max - min) * (height - pad.top - pad.bottom);
  const svg = svgNode("svg", { viewBox: `0 0 ${width} ${height}`, preserveAspectRatio: "none", "aria-hidden": "true" });

  for (let row = 0; row <= 3; row += 1) {
    const yy = pad.top + row / 3 * (height - pad.top - pad.bottom);
    svg.append(svgNode("line", { x1: pad.left, x2: width - pad.right, y1: yy, y2: yy, class: "grid-line" }));
    const label = svgNode("text", { x: 0, y: yy + 4, class: "axis-label" });
    label.textContent = (max - row / 3 * (max - min)).toFixed(options.decimals ?? 2);
    svg.append(label);
  }
  if (options.threshold !== undefined) {
    svg.append(svgNode("line", { x1: pad.left, x2: width - pad.right, y1: y(options.threshold), y2: y(options.threshold), class: "threshold" }));
  }
  for (const item of series) {
    if (!item.values.length) continue;
    const points = item.values.map((point, index) => `${x(index)},${y(point.y)}`).join(" ");
    svg.append(svgNode("polyline", { points, class: item.className }));
    if (item.intervals) {
      item.values.forEach((point, index) => {
        if (!Number.isFinite(point.low) || !Number.isFinite(point.high)) return;
        svg.append(svgNode("line", { x1: x(index), x2: x(index), y1: y(point.low), y2: y(point.high), class: "ci-line" }));
      });
    }
    item.values.forEach((point, index) => svg.append(svgNode("circle", { cx: x(index), cy: y(point.y), r: 3.1, class: item.pointClass || "point" })));
  }
  container.append(svg);
}

function renderCharts(data) {
  const policy = [];
  const value = [];
  const promotions = [];
  for (const iteration of data.iterations) {
    for (const epoch of iteration.training?.history || []) {
      policy.push({ y: Number(epoch.policy_loss) });
      value.push({ y: Number(epoch.value_loss) });
    }
    const promotion = iteration.promotion || iteration.training?.promotion;
    if (promotion) promotions.push({
      y: Number(promotion.score_with_nonfinishes_as_losses),
      low: Number(promotion.paired_score_ci95?.[0]),
      high: Number(promotion.paired_score_ci95?.[1]),
    });
  }
  lineChart($("loss-chart"), [
    { values: policy, className: "line-policy" },
    { values: value, className: "line-value" },
  ]);
  lineChart($("promotion-chart"), [
    { values: promotions, className: "promotion-line", intervals: true },
  ], { min: 0, max: 1, threshold: 0.5, decimals: 0, height: 170 });
}

function iterationDiagnostics(iteration) {
  return iteration?.training?.diagnostics?.latest || null;
}

function renderDiagnostics(data) {
  const live = data.status?.training_diagnostics;
  const latest = live || iterationDiagnostics(data.latest);
  const cards = $("diagnostic-cards");
  const history = $("diagnostic-history");
  clear(cards);
  clear(history);
  const gradient = latest?.gradient || {};
  const heldout = latest?.heldout || {};
  const summaries = [
    ["Value / policy gradient", number(gradient.value_policy_norm_ratio, 2), (gradient.value_policy_norm_ratio || 0) > 2],
    ["Gradient cosine", number(gradient.mean_cosine, 3), (gradient.mean_cosine || 0) < 0],
    ["Conflicting batches", pct(gradient.negative_cosine_fraction), (gradient.negative_cosine_fraction || 0) > 0.5],
    ["Fresh value MSE", number(heldout.value_mse_equal_row, 3), heldout.value_mse_equal_row > heldout.zero_value_mse],
    ["Equal-battle MSE", number(heldout.value_mse_equal_battle, 3), heldout.value_mse_equal_battle > heldout.zero_value_mse],
    ["Policy KL / top action", latest ? `${number(heldout.policy_kl, 3)} / ${pct(heldout.policy_top_action_agreement)}` : "—", false],
  ];
  for (const [name, value, alert] of summaries) {
    const card = element("div", "mini-stat");
    card.append(element("span", "", name), element("strong", alert ? "diagnostic-alert" : "", value));
    cards.append(card);
  }
  text(
    $("diagnostic-status"),
    latest
      ? `Epoch ${Number(latest.epoch) + 1} · ${number(gradient.samples)} gradient batches · ${number(heldout.battles)} held-out battles`
      : "Waiting for training",
  );

  const rows = data.iterations.map((iteration) => [iteration.iteration, iterationDiagnostics(iteration)]).filter(([, diagnostic]) => diagnostic);
  if (!rows.length) {
    const row = element("tr");
    const cell = element("td", "empty-cell", "No optimization diagnostics yet");
    cell.colSpan = 9;
    row.append(cell);
    history.append(row);
    return;
  }
  for (const [iteration, diagnostic] of rows.slice(-10).reverse()) {
    const g = diagnostic.gradient;
    const h = diagnostic.heldout;
    const values = [
      String(iteration).padStart(3, "0"),
      number(g.value_policy_norm_ratio, 2),
      number(g.mean_cosine, 3),
      pct(g.negative_cosine_fraction),
      number(h.value_mse_equal_row, 3),
      number(h.value_mse_equal_battle, 3),
      number(h.zero_value_mse, 3),
      number(h.policy_kl, 3),
      pct(h.policy_top_action_agreement),
    ];
    const row = element("tr");
    values.forEach((value, index) => {
      const alert = (index === 1 && g.value_policy_norm_ratio > 2) || (index === 2 && g.mean_cosine < 0) || (index === 3 && g.negative_cosine_fraction > 0.5) || (index === 4 && h.value_mse_equal_row > h.zero_value_mse) || (index === 5 && h.value_mse_equal_battle > h.zero_value_mse);
      row.append(element("td", alert ? "diagnostic-alert" : "", value));
    });
    history.append(row);
  }
}

function renderModel(data) {
  const model = data.model || {};
  const network = model.network || {};
  const rows = [
    ["Pipeline", model.pipeline],
    ["Learner", model.learning_lineage || "legacy rollback"],
    ["Deployment", model.deployment_lineage || "quality gated"],
    ["Observation", `${network.feature_count || "—"} fields`],
    ["Sequence", network.feature_count ? `${network.token_layout === "semantic-entity-v1" ? 32 : Math.ceil(network.feature_count / (network.token_group_size || 1)) + 1} tokens` : "—"],
    ["Encoder", network.layers ? `${network.layers} layers / ${network.heads} heads` : "—"],
    ["Width", network.d_model ? `${network.d_model} / FF ${network.feedforward}` : "—"],
    ["Precision", network.precision?.toUpperCase()],
    ["Device", model.device_name || model.device],
    ["Parameters", number(model.parameter_count)],
  ];
  const dl = $("model-contract");
  clear(dl);
  for (const [name, value] of rows) {
    const row = element("div");
    row.append(element("dt", "", name), element("dd", "", value || "—"));
    dl.append(row);
  }
}

function renderActors(data) {
  const root = $("actors");
  clear(root);
  if (!data.actors?.length) {
    root.className = "actors empty-state";
    root.textContent = data.status?.stage === "collection" ? "Waiting for actor heartbeat" : "No active actor reports";
    return;
  }
  root.className = "actors";
  for (const actor of data.actors) {
    const ratio = actor.total ? actor.completed / actor.total : 0;
    const row = element("div", "actor-row");
    const copy = element("div", "actor-copy");
    copy.append(element("span", "", `Actor ${actor.process}`), element("strong", "", `${actor.completed} / ${actor.total}`));
    const track = element("div", "actor-track");
    const fill = element("span");
    fill.style.width = `${Math.min(100, ratio * 100)}%`;
    track.append(fill);
    row.append(copy, track);
    root.append(row);
  }
}

function renderBattlePopulation(data) {
  const collection = data.collection || data.latest?.collection;
  const root = $("battle-stats");
  clear(root);
  const qualityAvailable = Boolean(collection?.decision_quality_version);
  const speciesCounts = collection?.species_counts || {};
  const speciesValues = Object.values(speciesCounts).map(Number);
  const speciesRange = speciesValues.length
    ? `${Math.min(...speciesValues)}–${Math.max(...speciesValues)} each`
    : "—";
  const stats = [
    ["Mean turns", collection ? number(collection.mean_decisions, 1) : "—"],
    ["Switch rate", collection ? pct(collection.voluntary_switch_rate) : "—"],
    ["Setup use", collection ? `${number(collection.setup_uses)} · ${pct(collection.setup_use_rate)}` : "—"],
    ["Exploitability", collection ? number(collection.mean_search_exploitability, 3) : "—"],
    ["Deep / root", collection ? `${number(collection.deep_search_decisions)} / ${number(collection.root_only_decisions)}` : "—"],
    ["Mirror / model / AI", collection ? `${number(collection.mirror_episodes)} / ${number(collection.model_opponent_episodes)} / ${number(collection.heuristic_opponent_episodes)}` : "—"],
    ["Species coverage", collection?.species_schedule ? `${number(speciesValues.length)} / 151 · ${speciesRange}` : "—"],
    ["Status overlap", qualityAvailable ? `${number((collection.redundant_status_same || 0) + (collection.redundant_status_other || 0))} / ${number(collection.major_status_attempts)} · ${pct(collection.redundant_status_rate)}` : "—"],
    ["Setup at +6", qualityAvailable ? `${number(collection.capped_stat_setup)} / ${number(collection.stat_setup_attempts)} · ${pct(collection.capped_stat_setup_rate)}` : "—"],
    ["OHKO vs faster", qualityAvailable ? `${number(collection.ohko_into_faster)} / ${number(collection.ohko_attempts)} · ${pct(collection.ohko_into_faster_rate)}` : "—"],
    ["Lv. 100 6v6", collection ? `${number(collection.level100_six_vs_six_battles)} / ${number(collection.six_vs_six_battles)}` : "—"],
  ];
  for (const [name, value] of stats) {
    const card = element("div", "mini-stat");
    card.append(element("span", "", name), element("strong", "", value));
    root.append(card);
  }

  const heatmap = $("party-heatmap");
  clear(heatmap);
  const counts = collection?.party_size_counts || {};
  const max = Math.max(1, ...Object.values(counts).map(Number));
  heatmap.append(element("span", "heat-label", ""));
  for (let enemy = 1; enemy <= 6; enemy += 1) heatmap.append(element("span", "heat-label", `E${enemy}`));
  for (let player = 1; player <= 6; player += 1) {
    heatmap.append(element("span", "heat-label", `P${player}`));
    for (let enemy = 1; enemy <= 6; enemy += 1) {
      const count = Number(counts[`${player}v${enemy}`] || 0);
      const cell = element("span", "heat-cell", String(count));
      cell.style.background = `rgba(240,77,85,${0.04 + 0.54 * count / max})`;
      cell.title = `${player}v${enemy}: ${count} battles`;
      heatmap.append(cell);
    }
  }
}

function selfplayOutcome(battle) {
  if (battle.stop !== "finished") return title(battle.stop);
  const result = battle.candidate_side === "both" ? battle.return : battle.candidate_return;
  if (result === 1) return "Win";
  if (result === -1) return "Loss";
  if (result === 0) return "Draw";
  return "—";
}

function renderSelfplay(data) {
  const collection = data.collection;
  const body = $("selfplay-battles");
  const stats = $("collection-results");
  clear(body);
  clear(stats);
  const completed = collection?.completed ?? ((collection?.finished || 0) + (collection?.truncated || 0) + (collection?.semantic_divergences || 0));
  const total = collection?.total ?? completed;
  const ratio = total ? completed / total : 0;
  $("collection-progress-bar").style.width = `${Math.min(100, ratio * 100)}%`;
  text($("collection-record"), collection ? `${number(completed)} / ${number(total)} battles · ${number(collection.finished)} returned` : "Waiting for results");

  const summaries = [
    ["Player W–L–D", collection ? `${number(collection.player_wins)}–${number(collection.enemy_wins)}–${number(collection.draws)}` : "—"],
    ["Candidate vs population", collection ? `${number(collection.candidate_wins)}–${number(collection.candidate_losses)}–${number(collection.candidate_draws)}` : "—"],
    ["Examples", collection ? compact(collection.examples) : "—"],
    ["Native transitions", collection ? compact(collection.transitions) : "—"],
    ["Nonreturns", collection ? number((collection.truncated || 0) + (collection.semantic_divergences || 0)) : "—"],
  ];
  for (const [name, value] of summaries) {
    const card = element("div", "mini-stat");
    card.append(element("span", "", name), element("strong", "", value));
    stats.append(card);
  }

  const battles = collection?.recent_battles || [];
  const iteration = collection?.iteration || data.status?.iteration || data.latest?.iteration;
  if (!battles.length) {
    const row = element("tr");
    const cell = element("td", "empty-cell", "No completed self-play battles yet");
    cell.colSpan = 7;
    row.append(cell);
    body.append(row);
    return;
  }
  for (const battle of battles) {
    const outcome = selfplayOutcome(battle);
    const population = battle.episode_kind === "mirror" ? "Mirror self-play" : battle.opponent;
    const values = [
      `#${battle.episode}`,
      population || title(battle.episode_kind),
      title(battle.candidate_side),
      `${battle.player_party_size}v${battle.enemy_party_size}`,
      outcome,
      number(battle.decisions),
      battle.reason ? `${title(battle.stop)} · ${battle.reason}` : title(battle.stop),
    ];
    const row = element("tr");
    values.forEach((value, index) => {
      let className = index === 1 ? "population-name" : "";
      if (index === 4) className = outcome === "Win" ? "result-win" : outcome === "Loss" ? "result-loss" : outcome === "Draw" ? "result-draw" : "";
      const cell = element("td", className, value);
      if (index === 1) cell.title = value;
      row.append(cell);
    });
    makeMatchLink(row, "selfplay", iteration, battle.episode);
    body.append(row);
  }
}

function gateRow(name, passed, detail = "") {
  const row = element("div", "gate");
  row.append(element("span", "", detail ? `${name} · ${detail}` : name));
  row.append(element("span", passed === null ? "pending" : passed ? "pass" : "fail", passed === null ? "Pending" : passed ? "Pass" : "Fail"));
  return row;
}

function renderGates(data) {
  const root = $("gates");
  const promotion = latestPromotion(data);
  clear(root);
  if (!promotion) { root.className = "gate-list empty-state"; root.textContent = "No completed promotion"; return; }
  root.className = "gate-list";
  root.append(
    gateRow("Paired confidence", promotion.statistically_superior ?? null, `low ${pct(promotion.paired_score_ci95?.[0])}`),
    gateRow("Data quality", promotion.data_quality_pass ?? null),
    gateRow("Party strata", promotion.stratified_party_gate ?? null),
    gateRow("Skill probes", promotion.held_out_probes?.pass ?? null),
    gateRow("Campaign suite", promotion.campaign_gate ?? null),
  );
  const badge = $("latest-decision");
  const accepted = promotion.accepted;
  badge.className = `decision-badge ${accepted ? "accepted" : "rejected"}`;
  text(badge, accepted ? "Promoted" : "Incumbent kept");
}

function actionLabel(action) {
  if (action === null || action === undefined) return "—";
  if (action < 4) return `move slot ${action + 1}`;
  if (action < 10) return `switch to slot ${action - 3}`;
  if (action === 10) return "take no action";
  if (action === 11) return "use Struggle";
  if (action === 12) return "attempt to run";
  return `action ${action}`;
}

function makeMatchLink(row, kind, iteration, match) {
  row.classList.add("match-link");
  row.tabIndex = 0;
  row.setAttribute("role", "button");
  row.setAttribute("aria-label", `Open ${kind} match ${match} details`);
  const open = () => openMatchPane(kind, iteration, match);
  row.addEventListener("click", open);
  row.addEventListener("keydown", (event) => {
    if (event.key === "Enter" || event.key === " ") {
      event.preventDefault();
      open();
    }
  });
}

function statusLabel(raw) {
  const value = Number(raw || 0);
  const labels = [];
  const sleep = value & 0x07;
  if (sleep) labels.push(`Sleep ${sleep}`);
  if (value & 0x08) labels.push("Poisoned");
  if (value & 0x10) labels.push("Burned");
  if (value & 0x20) labels.push("Frozen");
  if (value & 0x40) labels.push("Paralyzed");
  return labels.length ? labels.join(" · ") : "Healthy";
}

function maximumPp(move) {
  const base = Number(move.base_pp || 0);
  return base + Math.floor(base / 5) * Number(move.pp_ups || 0);
}

function moveDescription(move) {
  const power = Number(move.power || 0) ? `Power ${move.power}` : "Status move";
  const accuracy = `${Math.round(Number(move.accuracy || 0) * 100 / 255)}% accuracy`;
  const effect = MOVE_EFFECTS[Number(move.effect)] || "Uses its cartridge-defined Gen-I effect.";
  return `${power} · ${accuracy}. ${effect}`;
}

function renderMove(move, activeLegal = null) {
  const item = element("li", `move-card${activeLegal === false ? " move-unavailable" : ""}`);
  const heading = element("div", "move-heading");
  heading.append(
    element("strong", "", move.name),
    element("span", `type-badge type-${String(TYPE_NAMES[move.type] || "unknown").toLowerCase()}`, TYPE_NAMES[move.type] || `Type ${move.type}`),
  );
  const pp = move.pp === undefined ? "PP unavailable" : `${move.pp}/${maximumPp(move)} PP`;
  item.append(heading, element("p", "move-description", moveDescription(move)), element("span", "move-pp", `${pp}${activeLegal === false ? " · unavailable now" : ""}`));
  return item;
}

function pokemonSprite(member, className = "") {
  if (!member?.dex) return null;
  const image = document.createElement("img");
  image.className = className;
  image.src = `${SPRITE_BASE}/${member.dex}.png`;
  image.alt = "";
  image.loading = "eager";
  image.decoding = "async";
  image.setAttribute("aria-hidden", "true");
  image.addEventListener("error", () => image.remove());
  return image;
}

function renderPokemon(member, index, side, activeMask, showMoves = true) {
  const active = index === Number(side.active);
  const card = element("article", `pokemon-card${active ? " active-pokemon" : ""}${Number(member.hp) === 0 ? " fainted-pokemon" : ""}`);
  const header = element("div", "pokemon-header");
  const portrait = element("div", "pokemon-portrait");
  const image = pokemonSprite(member);
  if (image) portrait.append(image);
  const identity = element("div", "pokemon-identity");
  const nameLine = element("div", "pokemon-name");
  nameLine.append(element("strong", "", member.name), element("span", "", `Lv. ${member.level}`));
  if (active) nameLine.append(element("span", "active-badge", "Active"));
  identity.append(nameLine, element("div", "pokemon-health", `${member.hp}/${member.max_hp} HP · ${statusLabel(member.status)}`));
  const hpTrack = element("div", "hp-track");
  const hpFill = element("span");
  hpFill.style.width = `${Math.max(0, Math.min(100, 100 * Number(member.hp) / Math.max(1, Number(member.max_hp))))}%`;
  hpTrack.append(hpFill);
  identity.append(hpTrack);
  header.append(portrait, identity);
  card.append(header);
  if (showMoves) {
    const moves = member.moves?.length ? member.moves : active ? side.moves || [] : [];
    const moveList = element("ul", "pokemon-moves");
    for (const [slot, move] of moves.entries()) {
      const legal = active && activeMask != null ? Boolean(activeMask & (1 << slot)) : null;
      moveList.append(renderMove(move, legal));
    }
    if (!moves.length) moveList.append(element("li", "empty-state", "Moves were not recorded for this historical state."));
    card.append(element("div", "moveset-label", "Move slots"), moveList);
  }
  return card;
}

function renderTeamState(root, label, state, masks = {}, showAttribution = true, showMoves = true) {
  if (!state?.player || !state?.enemy) return;
  const section = element("section", `match-section${showMoves ? "" : " final-team-section"}`);
  section.append(element("h3", "", label));
  const teams = element("div", "team-grid");
  for (const [sideName, sideLabel] of [["player", "Player team"], ["enemy", "Enemy team"]]) {
    const side = state[sideName];
    const card = element("div", "team-card");
    const alive = (side.party || []).filter((member) => Number(member.hp) > 0).length;
    const teamSummary = showMoves ? `${side.party?.length || 0} Pokémon` : `${alive} alive · ${(side.party?.length || 0) - alive} fainted`;
    card.append(element("h4", "", `${sideLabel} · ${teamSummary}`));
    const list = element("div", "pokemon-list");
    for (const [index, member] of (side.party || []).entries()) list.append(renderPokemon(member, index, side, masks[sideName], showMoves));
    card.append(list);
    teams.append(card);
  }
  section.append(teams);
  if (showAttribution) section.append(element("p", "sprite-attribution", "Generation I sprites are loaded from the pinned PokeAPI sprites repository; Pokémon imagery belongs to its respective rights holders."));
  root.append(section);
}

function choiceText(choice, action) {
  if (!choice) return title(actionLabel(action));
  if (choice.kind === "move") return choice.move ? `${choice.actor} used ${choice.move.name}` : `${choice.actor} selected ${actionLabel(action)}`;
  if (choice.kind === "switch") return `${choice.actor} switched to ${choice.target || `slot ${Number(choice.target_slot) + 1}`}`;
  if (choice.kind === "struggle") return `${choice.actor} used Struggle`;
  if (choice.kind === "run") return `${choice.actor} attempted to run`;
  if (choice.kind === "no-action") return `${choice.actor} took no action`;
  return `${choice.actor} selected ${actionLabel(action)}`;
}

function policyPreview(rows) {
  if (!rows?.length) return "";
  return rows.map((row) => `${choiceText(row, row.action)} ${pct(row.probability)}`).join(" · ");
}

function sideKey(side) {
  return Number(side) === 0 ? "player" : "enemy";
}

function sideTitle(side) {
  return Number(side) === 0 ? "Player" : "Enemy";
}

function rosterMember(rosters, state, side, slot) {
  const key = sideKey(side);
  const recorded = state?.[key]?.party?.[slot] || {};
  const original = rosters?.[key]?.[slot] || {};
  return { ...original, ...recorded };
}

function activeMember(rosters, state, side, activeSlots) {
  const key = sideKey(side);
  const slot = activeSlots?.[Number(side)] ?? Number(state?.[key]?.active || 0);
  return rosterMember(rosters, state, side, slot);
}

function pokemonReference(member, side, fallback = "Pokémon") {
  const reference = element("span", `pokemon-ref side-${sideKey(side)}`);
  const image = pokemonSprite(member, "pokemon-ref-icon");
  if (image) reference.append(image);
  reference.append(element("strong", "", member?.name || fallback));
  return reference;
}

function appendParts(root, parts) {
  for (const part of parts) {
    if (part?.nodeType) root.append(part);
    else root.append(document.createTextNode(String(part)));
  }
}

function eventLine(kind, side, label, parts) {
  const sideClass = side === null ? "" : ` side-${sideKey(side)}`;
  const item = element("li", `battle-event event-${kind}${sideClass}`);
  const content = element("div", "battle-event-content");
  const meta = element("div", "battle-event-meta");
  meta.append(element("span", "event-kind", label));
  if (side !== null) meta.append(element("span", "event-side", sideTitle(side)));
  const copy = element("p", "battle-event-copy");
  appendParts(copy, parts);
  content.append(meta, copy);
  item.append(content);
  return item;
}

function choiceForSide(turn, side) {
  return Number(side) === 0 ? turn.player_choice : turn.enemy_choice;
}

function actionForSide(turn, side) {
  return Number(side) === 0 ? turn.player_action : turn.enemy_action;
}

function inferStatusSide(before, after, applied) {
  const changed = [0, 1].filter((side) => {
    const key = sideKey(side);
    return before?.[key]?.status !== after?.[key]?.status;
  });
  const exact = changed.find((side) => Number(after?.[sideKey(side)]?.status) === Number(applied));
  return exact ?? changed[0] ?? null;
}

function stageDescription(event, side, before, after, lastActionSide) {
  const beforeStages = before?.[sideKey(side)]?.stages;
  const afterStages = after?.[sideKey(side)]?.stages;
  let stat = Number.isInteger(Number(event.stat)) ? Number(event.stat) : null;
  if (stat === null && beforeStages && afterStages) {
    stat = beforeStages.findIndex((value, index) => Number(value) !== Number(afterStages[index]));
  }
  const statName = STAT_NAMES[stat] || "A stat";
  if (stat >= 0 && beforeStages?.[stat] !== undefined && afterStages?.[stat] !== undefined) {
    const delta = Number(afterStages[stat]) - Number(beforeStages[stat]);
    if (delta > 0) return `${statName} rose by ${delta === 1 ? "1 stage" : `${delta} stages`}.`;
    if (delta < 0) return `${statName} fell by ${delta === -1 ? "1 stage" : `${Math.abs(delta)} stages`}.`;
  }
  if (event.amount && lastActionSide !== null) {
    const direction = Number(side) === Number(lastActionSide) ? "rose" : "fell";
    return `${statName} ${direction} by ${number(event.amount)} ${Number(event.amount) === 1 ? "stage" : "stages"}.`;
  }
  return `${statName} changed${event.amount ? ` by ${number(event.amount)} ${Number(event.amount) === 1 ? "stage" : "stages"}` : ""}.`;
}

function collapseBattleEvents(events, turn) {
  const skipped = new Set();
  for (const [index, event] of events.entries()) {
    if (event.kind !== "action" || event.side === undefined) continue;
    const side = Number(event.side);
    const action = Number(event.action ?? actionForSide(turn, side));
    if ((action >= 0 && action <= 3) || action === 11) {
      const nextActionIndex = events.findIndex((candidate, candidateIndex) =>
        candidateIndex > index && candidate.kind === "action",
      );
      const executedIndex = events.findIndex((candidate, candidateIndex) =>
        candidateIndex > index && candidate.kind === "move-executed" &&
        Number(candidate.side) === side,
      );
      if (executedIndex !== -1 && (nextActionIndex === -1 || executedIndex < nextActionIndex)) skipped.add(index);
      continue;
    }
    if (action >= 4 && action <= 9) {
      const target = action - 4;
      const switchIndex = events.findIndex((candidate, candidateIndex) =>
        candidateIndex > index && candidate.kind === "switch" &&
        Number(candidate.side) === side && Number(candidate.target) === target,
      );
      if (switchIndex !== -1) skipped.add(index);
    }
  }

  const moveDetails = new Map();
  for (const [index, event] of events.entries()) {
    if (!["critical-hit", "super-effective"].includes(event.kind) || event.side === undefined) continue;
    let moveIndex = -1;
    for (let candidateIndex = index - 1; candidateIndex >= 0; candidateIndex -= 1) {
      const candidate = events[candidateIndex];
      if (candidate.kind === "action") break;
      if (candidate.kind === "move-executed") {
        if (Number(candidate.side) === Number(event.side)) moveIndex = candidateIndex;
        break;
      }
    }
    if (moveIndex === -1) continue;
    const details = moveDetails.get(moveIndex) || {};
    details[event.kind === "critical-hit" ? "critical" : "super_effective"] = true;
    moveDetails.set(moveIndex, details);
    skipped.add(index);
  }

  return events.flatMap((event, index) => {
    if (skipped.has(index)) return [];
    if (event.kind === "move-executed" && moveDetails.has(index)) {
      return [{ ...event, ...moveDetails.get(index) }];
    }
    if (event.kind === "faint") {
      const lethalDamage = events.findIndex((candidate, candidateIndex) =>
        candidateIndex < index && candidate.kind === "damage" &&
        Number(candidate.side) === Number(event.side) && Number(candidate.hp) === 0,
      );
      if (lethalDamage !== -1) return [];
    }
    if (event.kind === "damage" && Number(event.amount) === 0) return [];
    if (event.kind === "damage" && Number(event.hp) === 0) return [{ ...event, kind: "damage-faint" }];
    return [event];
  });
}

function renderActionEvent(turn, side, rosters, before, activeSlots, recordedAction) {
  const choice = choiceForSide(turn, side);
  const action = choice?.action ?? recordedAction ?? actionForSide(turn, side);
  const actorSlot = choice?.actor_slot ?? activeSlots[side];
  const actor = rosterMember(rosters, before, side, actorSlot);
  const actorRef = pokemonReference(actor, side, choice?.actor || sideTitle(side));
  if (choice?.kind === "move" && choice.move) {
    return eventLine("action", side, "Move selected", [actorRef, " selected ", element("strong", "event-move", choice.move.name), "."]);
  }
  if (choice?.kind === "switch") {
    const target = rosterMember(rosters, before, side, Number(choice.target_slot));
    return eventLine("action", side, "Switch chosen", [actorRef, " committed to switch to ", pokemonReference(target, side, choice.target || "another Pokémon"), "."]);
  }
  if (choice?.kind === "struggle") return eventLine("action", side, "Move selected", [actorRef, " selected ", element("strong", "event-move", "Struggle"), "."]);
  if (choice?.kind === "no-action") return eventLine("action", side, "Automatic turn", [actorRef, " bypassed move selection."]);
  if (choice?.kind === "run") return eventLine("action", side, "Run", [actorRef, " attempted to leave the battle."]);
  return eventLine("action", side, "Action", [actorRef, ` selected ${actionLabel(action)}.`]);
}

function renderMechanicsEvent(event, turn, rosters, before, after, activeSlots, lastActionSide, replacementMember = null) {
  const explicitSide = event.side === undefined ? null : Number(event.side);
  const inferredStatusSide = event.kind === "status-applied" ? inferStatusSide(before, after, event.value) : null;
  const side = explicitSide ?? inferredStatusSide ?? (
    ["healed", "recoil", "screen", "transformed", "disobedience"].includes(event.kind) ? lastActionSide :
      ["seeded", "disabled"].includes(event.kind) && lastActionSide !== null ? 1 - lastActionSide : null
  );
  const member = side === null ? null : activeMember(rosters, before, side, activeSlots);
  const ref = side === null ? null : pokemonReference(member, side, sideTitle(side));

  if (event.kind === "action" && explicitSide !== null) {
    return renderActionEvent(turn, explicitSide, rosters, before, activeSlots, event.action);
  }
  if (event.kind === "move-executed") {
    const parts = [ref, " used ", element("strong", "event-move", event.move || `move ${number(event.move_id)}`), "."];
    if (event.critical) parts.push(element("span", "attack-tag attack-critical", "Critical hit"));
    if (event.super_effective) parts.push(element("span", "attack-tag attack-super-effective", "Super effective"));
    return eventLine("action", side, "Move used", parts);
  }
  if (event.kind === "critical-hit") return eventLine("action", side, "Critical hit", [ref, " landed a critical hit."]);
  if (event.kind === "super-effective") return eventLine("action", side, "Super effective", [ref, " used a super-effective attack."]);
  if (event.kind === "missed") return eventLine("miss", side, "Missed", [ref, "'s move missed its target."]);
  if (event.kind === "ineffective") return eventLine("miss", side, "No effect", [ref, "'s move did not affect its target."]);
  if (event.kind === "damage") return eventLine("damage", side, "Damage", [ref, ` lost ${number(event.amount)} HP and has ${number(event.hp)} HP left.`]);
  if (event.kind === "residual-damage") return eventLine("damage", side, "Residual damage", [ref, ` lost ${number(event.amount)} HP from its status or Leech Seed and has ${number(event.hp)} HP left.`]);
  if (event.kind === "damage-faint") return eventLine("faint", side, "Knocked out", [ref, ` lost ${number(event.amount)} HP and fainted.`]);
  if (event.kind === "substitute-damage") return eventLine("damage", side, "Substitute", [ref, `'s substitute absorbed ${number(event.amount)} damage and has ${number(event.hp)} HP left.`]);
  if (event.kind === "faint") return eventLine("faint", side, "Fainted", [ref, " fainted."]);
  if (event.kind === "forced-replacement") return eventLine("replacement", side, "Replacement needed", [sideTitle(side), " must choose a replacement for ", ref, "."]);
  if (event.kind === "switch") {
    const outgoing = activeMember(rosters, before, side, activeSlots);
    const targetSlot = Number(event.target);
    const incoming = rosterMember(rosters, before, side, targetSlot);
    activeSlots[side] = targetSlot;
    if (replacementMember) {
      return eventLine("switch", side, "Replacement", [pokemonReference(replacementMember, side), " was replaced by ", pokemonReference(incoming, side, `slot ${targetSlot + 1}`), "."]);
    }
    return eventLine("switch", side, "Switched", [pokemonReference(outgoing, side), " was withdrawn; ", pokemonReference(incoming, side, `slot ${targetSlot + 1}`), " entered the battle."]);
  }
  if (event.kind === "status-applied") {
    const previous = side === null ? "Healthy" : statusLabel(before?.[sideKey(side)]?.status);
    const condition = side === null ? statusLabel(event.value) : statusLabel(after?.[sideKey(side)]?.status ?? event.value);
    return eventLine("status", side, "Status changed", side === null ? [`A Pokémon changed from ${previous} to ${condition}.`] : [ref, ` changed from ${previous} to ${condition}.`]);
  }
  if (event.kind === "status-blocked") {
    const condition = event.reason ? title(event.reason) :
      side === null ? "its status" : statusLabel(before?.[sideKey(side)]?.status);
    return eventLine("status", side, "Unable to move", [ref, ` could not act because of ${condition}.`]);
  }
  if (event.kind === "stage-changed") return eventLine("status", side, "Stat changed", [ref, `: ${stageDescription(event, side, before, after, lastActionSide)}`]);
  if (event.kind === "healed") return eventLine("heal", side, "Recovered", side === null ? [`A Pokémon recovered ${number(event.amount)} HP.`] : [ref, ` recovered ${number(event.amount)} HP.`]);
  if (event.kind === "recoil") return eventLine("damage", side, "Recoil", side === null ? [`A Pokémon took ${number(event.amount)} recoil damage.`] : [ref, ` took ${number(event.amount)} recoil damage.`]);
  if (event.kind === "screen") return eventLine("status", side, "Screen", side === null ? ["A defensive screen was established."] : [ref, " established a defensive screen."]);
  if (event.kind === "transformed") return eventLine("status", side, "Transform", side === null ? ["Transform completed."] : [ref, " transformed."]);
  if (event.kind === "seeded") return eventLine("status", side, "Leech Seed", side === null ? ["Leech Seed took hold."] : [ref, " was seeded."]);
  if (event.kind === "disabled") return eventLine("status", side, "Disabled", side === null ? ["A move was disabled."] : [ref, " had a move disabled."]);
  if (event.kind === "disobedience") return eventLine("status", side, "Disobeyed", side === null ? ["A Pokémon disobeyed."] : [ref, " disobeyed its command."]);
  if (event.kind === "terminal") return eventLine("terminal", null, "Battle over", ["The battle reached its final result."]);
  return eventLine("status", side, title(event.kind), side === null ? [`${title(event.kind)} occurred.`] : [ref, `: ${title(event.kind)}.`]);
}

function renderTurnState(after, rosters) {
  if (!after?.player || !after?.enemy) return null;
  const summary = element("div", "turn-state-grid");
  for (const side of [0, 1]) {
    const key = sideKey(side);
    const slot = Number(after[key].active || 0);
    const member = rosterMember(rosters, after, side, slot);
    const hp = Number(after[key].hp ?? member.hp ?? 0);
    const maxHp = Number(after[key].max_hp ?? member.max_hp ?? 0);
    const state = element("div", `turn-state-side side-${key}${hp === 0 ? " is-fainted" : ""}`);
    state.append(pokemonReference(member, side), element("span", "", `${number(hp)}/${number(maxHp)} HP`));
    const status = statusLabel(after[key].status);
    if (status !== "Healthy") state.append(element("span", "turn-status", status));
    summary.append(state);
  }
  return summary;
}

function renderTurn(turn, rosters, context) {
  const before = turn.before || {};
  const after = turn.after || {};
  const activeSlots = [Number(before.player?.active || 0), Number(before.enemy?.active || 0)];
  const rawEvents = after.events || [];
  const recorded = collapseBattleEvents(rawEvents, turn);
  const events = rawEvents.some((event) => event.kind === "action") ? recorded : [
    { kind: "action", side: 0, action: turn.player_action, synthetic: true },
    { kind: "action", side: 1, action: turn.enemy_action, synthetic: true },
    ...recorded,
  ];
  const search = turn.root_value == null ? null : `Search value ${number(turn.root_value, 3)}${turn.exploitability == null ? "" : ` · exploitability ${number(turn.exploitability, 3)}`}${turn.tree_nodes == null ? "" : ` · ${number(turn.tree_nodes)} nodes · depth ${number(turn.tree_max_depth)}`}`;
  const turnMarker = eventLine("turn", null, `Turn ${number(turn.turn)}`, [element("strong", "turn-request", title(turn.request)), search ? ` · ${search}` : ""]);
  const playerPolicy = policyPreview(turn.player_top_policy);
  const enemyPolicy = policyPreview(turn.enemy_top_policy);
  if (playerPolicy || enemyPolicy) {
    const details = element("details", "policy-details turn-policy-details");
    details.append(element("summary", "", "Search policy"), element("p", "", `Player: ${playerPolicy || "—"}`), element("p", "", `Enemy: ${enemyPolicy || "—"}`));
    turnMarker.append(details);
  }

  const output = [turnMarker];
  let lastActionSide = null;
  for (const event of events) {
    const eventSide = event.side === undefined ? null : Number(event.side);
    if (event.kind === "forced-replacement" && eventSide !== null) {
      context.pendingReplacements.set(eventSide, activeMember(rosters, before, eventSide, activeSlots));
      continue;
    }
    if (event.kind === "action" && eventSide !== null) {
      lastActionSide = eventSide;
      const action = Number(event.action ?? actionForSide(turn, eventSide));
      if (action === 10 && context.pendingReplacements.size) continue;
      if (action >= 4 && action <= 9 && context.pendingReplacements.has(eventSide)) continue;
    }
    const replacement = event.kind === "switch" && eventSide !== null
      ? context.pendingReplacements.get(eventSide) || null
      : null;
    const rendered = renderMechanicsEvent(event, turn, rosters, before, after, activeSlots, lastActionSide, replacement);
    output.push(rendered);
    if (replacement) context.pendingReplacements.delete(eventSide);
  }
  if (!rawEvents.length) {
    output.push(eventLine("note", null, "Reduced trace", ["Detailed mechanics events were not recorded; only the committed actions are available."]));
  }
  const state = renderTurnState(after, rosters);
  if (state) output.push(eventLine("state", null, "After turn", [state]));
  return output;
}

function renderMatchDetail(detail) {
  const body = $("match-pane-body");
  window.BattleEmulator?.dispose();
  clear(body);
  const promotion = detail.kind === "promotion";
  const identity = promotion ? `Promotion game ${detail.game}` : `Self-play episode ${detail.episode}`;
  text($("match-pane-label"), promotion ? "Paired promotion" : "Training collection");
  text($("match-pane-title"), identity);

  const result = promotion ? outcomeLabel(detail) : selfplayOutcome(detail);
  const summaries = [
    ["Iteration", number(detail.iteration)], ["Result", result],
    ["Party", `${detail.player_party_size}v${detail.enemy_party_size}`], ["Levels", detail.level_profile === "level100" ? "All Lv. 100" : "Generated range"],
    ["Stop", detail.reason ? title(detail.reason) : title(detail.stop)], ["Candidate side", title(detail.candidate_side)],
    [promotion ? "Pair" : "Population", promotion ? `#${detail.pair}` : (detail.opponent || title(detail.episode_kind))],
    ["Turns", number(detail.timeline?.length ?? detail.decisions)],
  ];
  const grid = element("div", "match-summary-grid");
  for (const [name, value] of summaries) {
    const card = element("div", "mini-stat");
    card.append(element("span", "", name), element("strong", "", String(value ?? "—")));
    grid.append(card);
  }
  const emulatorActions = element("div", "emulator-launch-row");
  const emulatorCopy = element("div");
  emulatorCopy.append(element("strong", "", "Replay through the original game"), element("span", "", "Exact parties, choices, link RNG, and WRAM checkpoints · canonical ROM required"));
  const emulatorButton = element("button", "emulator-launch-button", "Open emulator");
  emulatorButton.type = "button";
  const emulatorHost = element("section", "emulator-host");
  emulatorHost.hidden = true;
  emulatorButton.addEventListener("click", () => {
    emulatorHost.hidden = false;
    emulatorButton.disabled = true;
    emulatorButton.textContent = "Emulator open";
    window.BattleEmulator?.mount(emulatorHost, detail);
    emulatorHost.scrollIntoView({ block: "nearest" });
  });
  emulatorActions.append(emulatorCopy, emulatorButton);
  body.append(grid, emulatorActions, emulatorHost);
  const firstTurn = detail.timeline?.[0];
  renderTeamState(body, "Starting teams and move slots", detail.initial, { player: firstTurn?.player_legal_mask, enemy: firstTurn?.enemy_legal_mask });

  const timeline = detail.timeline || [];
  const rosters = {
    player: detail.initial?.player?.party || [],
    enemy: detail.initial?.enemy?.party || [],
  };
  const section = element("section", "match-section");
  section.append(element("h3", "", "Battle log"));
  if (!timeline.length) section.append(element("p", "empty-state", "A turn-by-turn record was not captured for this historical match."));
  else {
    const events = element("ol", "battle-event-list battle-timeline");
    const context = { pendingReplacements: new Map() };
    for (const turn of timeline) events.append(...renderTurn(turn, rosters, context));
    section.append(events);
  }
  body.append(section);
  renderTeamState(body, "Final recorded teams", detail.final, {}, false, false);
}

async function openMatchPane(kind, iteration, match) {
  const pane = $("match-pane");
  text($("match-pane-label"), "Recorded match");
  text($("match-pane-title"), "Loading details…");
  clear($("match-pane-body"));
  $("match-pane-body").append(element("p", "empty-state", "Reading the immutable match record…"));
  if (!pane.open) pane.showModal();
  try {
    const response = await fetch(`/api/match?kind=${encodeURIComponent(kind)}&iteration=${iteration}&match=${match}`, { cache: "no-store" });
    if (!response.ok) throw new Error(`Match detail unavailable (HTTP ${response.status})`);
    renderMatchDetail(await response.json());
  } catch (error) {
    clear($("match-pane-body"));
    $("match-pane-body").append(element("p", "empty-state", error.message));
  }
}

function outcomeLabel(battle) {
  if (battle.stop !== "finished") return title(battle.stop);
  if (battle.candidate_return === 1) return "Win";
  if (battle.candidate_return === -1) return "Loss";
  return "Draw";
}

function renderPromotionBattles(data) {
  const promotion = latestPromotion(data);
  const body = $("promotion-battles");
  clear(body);
  text($("battle-record"), promotion ? `${number(promotion.wins)}–${number(promotion.losses)} · ${number(promotion.draws)} draws` : "—");
  const battles = promotion?.battles || [];
  const iteration = data.status?.promotion ? data.status.iteration : data.latest?.iteration;
  if (!battles.length) {
    const row = element("tr");
    const cell = element("td", "empty-cell", "No battle-level records yet");
    cell.colSpan = 6;
    row.append(cell);
    body.append(row);
    return;
  }
  for (const battle of battles.slice(-20).reverse()) {
    const row = element("tr");
    const outcome = outcomeLabel(battle);
    const values = [
      `#${battle.game}`,
      title(battle.candidate_side),
      `${battle.player_party_size}v${battle.enemy_party_size}`,
      outcome,
      title(battle.stop),
      number(battle.score, 1),
    ];
    values.forEach((value, index) => {
      const cell = element("td", index === 3 ? (outcome === "Win" ? "pass" : outcome === "Loss" ? "fail" : "") : "", value);
      row.append(cell);
    });
    makeMatchLink(row, "promotion", iteration, battle.game);
    body.append(row);
  }
}

function renderCampaign(data) {
  const root = $("campaign-cases");
  const cases = latestPromotion(data)?.campaign_arena?.campaign?.cases;
  clear(root);
  if (!cases) { root.className = "campaign-grid empty-state"; root.textContent = "No campaign evaluation"; return; }
  root.className = "campaign-grid";
  for (const [name, result] of Object.entries(cases)) {
    const card = element("div", `campaign-case ${result.pass ? "pass-case" : "fail-case"}`);
    card.append(element("span", "", name), element("strong", result.pass ? "pass" : "fail", pct(result.score)));
    root.append(card);
  }
}

function renderProbes(data) {
  const root = $("probes");
  const probes = latestPromotion(data)?.held_out_probes;
  clear(root);
  if (!probes) { root.className = "probe-list empty-state"; root.textContent = "No probe evaluation"; return; }
  root.className = "probe-list";
  const setupCounts = Object.entries(probes.setup?.candidate_move_counts || {})
    .sort((left, right) => Number(right[1]) - Number(left[1]))
    .slice(0, 3)
    .map(([name, count]) => `${name} ${count}`)
    .join(", ");
  const quality = probes.decision_quality || {};
  const candidateQuality = quality.candidate || {};
  const baselineQuality = quality.baseline || {};
  const qualityRows = quality.gated === false ? [
    ["Status overlap", quality.pass, null, `candidate ${pct(candidateQuality.redundant_status_rate)} · baseline ${pct(baselineQuality.redundant_status_rate)}`],
    ["Setup at +6", quality.pass, null, `candidate ${pct(candidateQuality.capped_stat_setup_rate)} · baseline ${pct(baselineQuality.capped_stat_setup_rate)}`],
    ["OHKO vs faster", quality.pass, null, `candidate ${pct(candidateQuality.ohko_into_faster_rate)} · baseline ${pct(baselineQuality.ohko_into_faster_rate)}`],
  ] : [];
  const rows = [
    ["Type choices", probes.type?.pass, probes.type?.delta, ""],
    ["Status use", probes.status?.pass, probes.status?.success_rate_delta, ""],
    ...qualityRows,
    ["Setup moves", probes.setup?.pass, probes.setup?.use_rate_delta, `${number(probes.setup?.candidate_uses)} uses${setupCounts ? ` · ${setupCounts}` : ""}`],
    ["Switching", probes.switch?.pass, probes.switch?.matchup_improvement_delta, ""],
  ];
  for (const [name, passed, delta, detail] of rows) {
    const row = element("div", "probe");
    const observed = passed == null;
    const status = observed ? "Observed" : passed ? "Pass" : "Fail";
    row.append(element("span", "", name), element("span", observed ? "pending" : passed ? "pass" : "fail", `${status}${detail ? ` · ${detail}` : ""}${delta == null ? "" : ` · ${delta >= 0 ? "+" : ""}${pct(delta)}`}`));
    root.append(row);
  }
}

function renderHistory(data) {
  const body = $("iteration-history");
  clear(body);
  if (!data.iterations.length) {
    const row = element("tr");
    const cell = element("td", "empty-cell", "No completed iterations");
    cell.colSpan = 8;
    row.append(cell);
    body.append(row);
    return;
  }
  for (const item of [...data.iterations].reverse()) {
    const training = item.training || {};
    const loss = training.history?.at(-1) || {};
    const promotion = item.promotion || training.promotion || {};
    const accepted = promotion.accepted;
    const values = [
      String(item.iteration).padStart(3, "0"),
      compact(item.collection?.examples),
      number(item.collection?.mean_decisions, 1),
      number(loss.policy_loss, 3),
      number(loss.value_loss, 3),
      pct(promotion.score_with_nonfinishes_as_losses),
      pct(promotion.paired_score_ci95?.[0]),
      accepted === undefined ? "Pending" : accepted ? "Promoted" : "Rejected",
    ];
    const row = element("tr");
    values.forEach((value, index) => row.append(element("td", index === 7 ? (accepted ? "pass" : "fail") : "", value)));
    body.append(row);
  }
}

function render(data) {
  renderConnection(data);
  renderRun(data);
  renderKpis(data);
  renderCharts(data);
  renderDiagnostics(data);
  renderModel(data);
  renderActors(data);
  renderBattlePopulation(data);
  renderSelfplay(data);
  renderGates(data);
  renderPromotionBattles(data);
  renderCampaign(data);
  renderProbes(data);
  renderHistory(data);
}

async function refresh() {
  try {
    const response = await fetch("/api/dashboard", { cache: "no-store" });
    if (!response.ok) throw new Error(`HTTP ${response.status}`);
    render(await response.json());
  } catch (error) {
    $("connection-dot").className = "status-dot error";
    text($("connection-label"), "Monitor offline");
    text($("last-updated"), error.message);
  }
}

$("match-pane-close").addEventListener("click", () => {
  window.BattleEmulator?.dispose();
  $("match-pane").close();
});
$("match-pane").addEventListener("click", (event) => {
  if (event.target === $("match-pane")) {
    window.BattleEmulator?.dispose();
    $("match-pane").close();
  }
});

refresh();
window.setInterval(refresh, 2000);
