"use strict";

const $ = (id) => document.getElementById(id);
const SVG = "http://www.w3.org/2000/svg";
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
    ["Sequence", network.feature_count ? `${Math.ceil(network.feature_count / (network.token_group_size || 1)) + 1} tokens` : "—"],
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
  const stats = [
    ["Mean turns", collection ? number(collection.mean_decisions, 1) : "—"],
    ["Switch rate", collection ? pct(collection.voluntary_switch_rate) : "—"],
    ["Exploitability", collection ? number(collection.mean_search_exploitability, 3) : "—"],
    ["Deep / root", collection ? `${number(collection.deep_search_decisions)} / ${number(collection.root_only_decisions)}` : "—"],
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
  if (action < 4) return `Move ${action + 1}`;
  if (action < 10) return `Switch to slot ${action - 3}`;
  if (action === 10) return "No action";
  if (action === 11) return "Struggle";
  if (action === 12) return "Run";
  return `Action ${action}`;
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

function renderTeamState(root, label, state) {
  if (!state?.player || !state?.enemy) return;
  const section = element("section", "match-section");
  section.append(element("h3", "", label));
  const teams = element("div", "team-grid");
  for (const [sideName, sideLabel] of [["player", "Player team"], ["enemy", "Enemy team"]]) {
    const side = state[sideName];
    const card = element("div", "team-card");
    card.append(element("h4", "", `${sideLabel} · active slot ${Number(side.active) + 1}`));
    const list = element("ul", "team-list");
    for (const [index, member] of (side.party || []).entries()) {
      const item = element("li");
      item.append(
        element("strong", "", `${index === side.active ? "● " : ""}${member.name} · L${member.level}`),
        element("span", "", `${member.hp}/${member.max_hp} HP${member.status ? ` · status ${member.status}` : ""}`),
      );
      list.append(item);
    }
    card.append(list);
    if (side.moves?.length) {
      card.append(element("p", "move-list", `Active moves: ${side.moves.map((move) => move.name).join(" · ")}`));
    }
    teams.append(card);
  }
  section.append(teams);
  root.append(section);
}

function policyPreview(rows) {
  if (!rows?.length) return "";
  return rows.map((row) => `${actionLabel(row.action)} ${pct(row.probability)}`).join(" · ");
}

function renderMatchDetail(detail) {
  const body = $("match-pane-body");
  clear(body);
  const promotion = detail.kind === "promotion";
  const identity = promotion ? `Promotion game ${detail.game}` : `Self-play episode ${detail.episode}`;
  text($("match-pane-label"), promotion ? "Paired promotion" : "Training collection");
  text($("match-pane-title"), identity);

  const result = promotion ? outcomeLabel(detail) : selfplayOutcome(detail);
  const summaries = [
    ["Iteration", number(detail.iteration)],
    ["Result", result],
    ["Party", `${detail.player_party_size}v${detail.enemy_party_size}`],
    ["Stop", title(detail.stop)],
    ["Candidate side", title(detail.candidate_side)],
    [promotion ? "Pair" : "Population", promotion ? `#${detail.pair}` : (detail.opponent || title(detail.episode_kind))],
    ["Turns", number(detail.timeline?.length ?? detail.decisions)],
    ["Return", detail.candidate_return ?? detail.return_ ?? detail.return ?? "—"],
  ];
  const grid = element("div", "match-summary-grid");
  for (const [name, value] of summaries) {
    const card = element("div", "mini-stat");
    card.append(element("span", "", name), element("strong", "", String(value ?? "—")));
    grid.append(card);
  }
  body.append(grid);
  renderTeamState(body, "Initial state", detail.initial);
  renderTeamState(body, "Final recorded state", detail.final);

  const timeline = detail.timeline || [];
  const section = element("section", "match-section");
  section.append(element("h3", "", "Decision timeline"));
  if (!timeline.length) {
    section.append(element("p", "empty-state", "A decision timeline was not recorded for this historical match."));
    body.append(section);
    return;
  }
  const wrap = element("div", "table-wrap timeline-table");
  const table = element("table");
  const head = element("thead");
  const headerRow = element("tr");
  for (const heading of ["Turn", "Request", "Player", "Enemy", "Search", "Top policies"]) headerRow.append(element("th", "", heading));
  head.append(headerRow);
  const tbody = element("tbody");
  for (const turn of timeline) {
    const row = element("tr");
    const search = turn.root_value == null
      ? "—"
      : `v ${number(turn.root_value, 3)}${turn.exploitability == null ? "" : ` · ε ${number(turn.exploitability, 3)}`}${turn.tree_nodes == null ? "" : ` · ${number(turn.tree_nodes)} nodes / d${number(turn.tree_max_depth)}`}`;
    const policies = element("td", "policy-preview");
    const playerPolicy = policyPreview(turn.player_top_policy);
    const enemyPolicy = policyPreview(turn.enemy_top_policy);
    policies.textContent = playerPolicy || enemyPolicy ? `P: ${playerPolicy || "—"}\nE: ${enemyPolicy || "—"}` : "—";
    row.append(
      element("td", "", number(turn.turn)),
      element("td", "", title(turn.request)),
      element("td", "", actionLabel(turn.player_action)),
      element("td", "", actionLabel(turn.enemy_action)),
      element("td", "", search),
      policies,
    );
    tbody.append(row);
  }
  table.append(head, tbody);
  wrap.append(table);
  section.append(wrap);
  body.append(section);
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
  const rows = [
    ["Type choices", probes.type?.pass, probes.type?.delta],
    ["Status use", probes.status?.pass, probes.status?.success_rate_delta],
    ["Switching", probes.switch?.pass, probes.switch?.matchup_improvement_delta],
  ];
  for (const [name, passed, delta] of rows) {
    const row = element("div", "probe");
    row.append(element("span", "", name), element("span", passed ? "pass" : "fail", `${passed ? "Pass" : "Fail"}${delta == null ? "" : ` · ${delta >= 0 ? "+" : ""}${pct(delta)}`}`));
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

$("match-pane-close").addEventListener("click", () => $("match-pane").close());
$("match-pane").addEventListener("click", (event) => {
  if (event.target === $("match-pane")) $("match-pane").close();
});

refresh();
window.setInterval(refresh, 2000);
