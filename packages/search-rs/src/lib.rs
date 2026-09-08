//! Native storage and scheduler for the exhaustive simultaneous matrix tree.
//!
//! The host supplies simulator snapshots, neural evaluations, matrix solutions,
//! and RNG draws. This engine owns tree topology, stable action ordering, shared
//! chance-world request generation, frontier grouping, fail-closed propagation,
//! arithmetic-ordered backups, split halves, and work counters. It never calls
//! Python, selects a new search algorithm, or changes evaluator/solver arithmetic.

use std::{
    panic::{catch_unwind, AssertUnwindSafe},
    slice,
};

const STEPS: u64 = 1;
const EVALUATE: u64 = 2;
const VALUES: u64 = 3;
const SOLVE: u64 = 4;
const FINISHED: u64 = 5;
type Result<T> = std::result::Result<T, &'static str>;

#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct Config {
    owner: u64,
    depth: u64,
    root_width: u64,
    interior_width: u64,
    root_chances: u64,
    interior_chances: u64,
    split: u64,
    initial_divergences: u64,
}
#[repr(C)]
#[derive(Clone, Copy, Debug, Default)]
pub struct Snapshot {
    handle: u64,
    player_mask: u64,
    enemy_mask: u64,
    done: u64,
    divergent: u64,
}
#[repr(C)]
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct Request {
    handle: u64,
    player: u64,
    enemy: u64,
    seed: u64,
}
#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct Row {
    root: u64,
    snapshot: u64,
}
#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct Job {
    root: u64,
    node: u64,
    half: u64, // 0 = mean, 1 and 2 = split halves
}
#[repr(C)]
#[derive(Clone, Copy, Debug, Default)]
pub struct Status {
    stage: u64,
    rows: u64,
    requests: u64,
    jobs: u64,
    seed_count: u64,
}
#[repr(C)]
#[derive(Clone, Copy, Debug, Default)]
pub struct RootStatus {
    good: u64,
    transitions: u64,
    root_leaves: u64,
    expanded: u64,
    possible_pairs: u64,
    sampled_pairs: u64,
    chance_outcomes: u64,
    interior_nodes: u64,
    interior_divergences: u64,
}
#[derive(Clone, Debug, Default)]
struct Counters {
    expanded: u64,
    possible: u64,
    sampled: u64,
    chance: u64,
    interior: u64,
    divergences: u64,
}

struct Node {
    root: usize,
    snapshot: usize,
    player: Vec<f64>,
    enemy: Vec<f64>,
    leaf: f64,
    legal_player: Vec<u64>,
    legal_enemy: Vec<u64>,
    payoff: Vec<f64>,
    counts: Vec<u64>,
    half_payoff: Vec<Vec<f64>>,
    half_counts: Vec<Vec<u64>>,
    value: f64,
    exploitability: f64,
}

#[repr(C)]
pub struct NodeView {
    root: u64,
    snapshot: u64,
    player_len: u64,
    enemy_len: u64,
    player: *const f64,
    enemy: *const f64,
    legal_player: *const u64,
    legal_enemy: *const u64,
    payoff: *const f64,
    counts: *const u64,
    half0: *const f64,
    half1: *const f64,
    counts0: *const u64,
    counts1: *const u64,
    leaf: f64,
    value: f64,
    exploitability: f64,
}

#[derive(Debug)]
struct Expansion {
    node: usize,
    root: usize,
    samples: Vec<(usize, usize, usize)>,
    successors: Vec<usize>,
    children: Vec<Option<usize>>,
    values: Vec<Option<f64>>,
}
struct Staged {
    node: usize,
    parent: Option<(usize, usize)>, // expansion and successor position
    samples: Vec<(usize, usize, usize)>,
    offset: usize,
    count: usize,
}

pub struct Engine {
    actions: usize,
    configs: Vec<Config>,
    snapshots: Vec<Snapshot>,
    nodes: Vec<Node>,
    expansions: Vec<Expansion>,
    levels: Vec<Vec<usize>>,
    staged: Vec<Staged>,
    opening: Vec<(usize, usize)>,
    leaf_slots: Vec<(usize, usize)>,
    rows: Vec<Row>,
    requests: Vec<Request>,
    jobs: Vec<Job>,
    counters: Vec<Counters>,
    transitions: Vec<u64>,
    root_leaves: Vec<u64>,
    good: Vec<bool>,
    stage: u64,
    next_depth: u64,
    backup_level: Option<usize>,
}

fn legal(mask: u64, priors: &[f64], width: u64) -> Vec<u64> {
    let mut actions: Vec<_> = (0..priors.len())
        .filter(|&a| mask & (1 << a) != 0)
        .collect();
    // Python sorts (-prior, action): ties retain the ascending action index.
    actions.sort_by(|&a, &b| priors[b].partial_cmp(&priors[a]).unwrap().then(a.cmp(&b)));
    actions.truncate(width.min(actions.len() as u64) as usize);
    actions.into_iter().map(|a| a as u64).collect()
}

impl Engine {
    fn new(
        actions: usize,
        configs: Vec<Config>,
        snapshots: Vec<Snapshot>,
        evaluations: &[f64],
        seeds: &[u64],
    ) -> Result<Self> {
        let n = configs.len();
        if n == 0
            || actions == 0
            || actions > 63
            || snapshots.len() != n
            || evaluations.len() != n * (2 * actions + 1)
        {
            return Err("invalid root or action shape");
        }
        for (i, c) in configs.iter().enumerate() {
            if c.owner as usize > i
                || c.depth == 0
                || c.root_width == 0
                || c.interior_width == 0
                || c.root_chances == 0
                || c.interior_chances == 0
                || c.split > 1
            {
                return Err("invalid search configuration");
            }
            if configs[c.owner as usize].owner != c.owner || snapshots[i].done != 0 {
                return Err("invalid owner or terminal root");
            }
        }
        let mut engine = Self {
            actions,
            configs,
            snapshots,
            nodes: Vec::new(),
            expansions: Vec::new(),
            levels: Vec::new(),
            staged: Vec::new(),
            opening: Vec::new(),
            leaf_slots: Vec::new(),
            rows: Vec::new(),
            requests: Vec::new(),
            jobs: Vec::new(),
            counters: vec![Counters::default(); n],
            transitions: vec![0; n],
            root_leaves: vec![0; n],
            good: vec![true; n],
            stage: STEPS,
            next_depth: 2,
            backup_level: None,
        };
        for i in 0..n {
            engine.counters[i].divergences = engine.configs[i].initial_divergences;
            engine.make_node(
                i,
                i,
                &evaluations[i * (2 * actions + 1)..(i + 1) * (2 * actions + 1)],
                engine.configs[i].root_width,
            )?;
        }
        if seeds.len()
            != engine
                .configs
                .iter()
                .map(|c| c.root_chances as usize)
                .sum::<usize>()
        {
            return Err("root chance seed count mismatch");
        }
        let mut offset = 0;
        for i in 0..n {
            let count = engine.configs[i].root_chances as usize;
            engine.stage_node(i, None, &seeds[offset..offset + count]);
            engine.root_leaves[i] = engine.staged.last().unwrap().count as u64;
            offset += count;
        }
        Ok(engine)
    }

    fn make_node(
        &mut self,
        root: usize,
        snapshot: usize,
        evaluation: &[f64],
        width: u64,
    ) -> Result<usize> {
        let a = self.actions;
        if evaluation.len() != 2 * a + 1 || evaluation.iter().any(|x| !x.is_finite()) {
            return Err("invalid evaluation");
        }
        let player = evaluation[..a].to_vec();
        let enemy = evaluation[a..2 * a].to_vec();
        let leaf = evaluation[2 * a];
        let legal_player = legal(self.snapshots[snapshot].player_mask, &player, width);
        let legal_enemy = legal(self.snapshots[snapshot].enemy_mask, &enemy, width);
        if legal_player.is_empty() || legal_enemy.is_empty() {
            return Err("empty legal action set");
        }
        let mut payoff = vec![0.; a * a];
        for &p in &legal_player {
            for &e in &legal_enemy {
                payoff[p as usize * a + e as usize] = leaf;
            }
        }
        let half_payoff = if self.configs[root].split != 0 {
            vec![payoff.clone(), payoff.clone()]
        } else {
            vec![]
        };
        let half_counts = vec![vec![0; a * a]; half_payoff.len()];
        let id = self.nodes.len();
        self.nodes.push(Node {
            root,
            snapshot,
            player,
            enemy,
            leaf,
            legal_player,
            legal_enemy,
            payoff,
            counts: vec![0; a * a],
            half_payoff,
            half_counts,
            value: 0.,
            exploitability: 0.,
        });
        Ok(id)
    }

    fn stage_node(&mut self, node: usize, parent: Option<(usize, usize)>, seeds: &[u64]) {
        let n = &self.nodes[node];
        let offset = self.requests.len();
        let mut samples = Vec::new();
        for &p in &n.legal_player {
            for &e in &n.legal_enemy {
                for (world, &seed) in seeds.iter().enumerate() {
                    samples.push((p as usize, e as usize, world));
                    self.requests.push(Request {
                        handle: self.snapshots[n.snapshot].handle,
                        player: p,
                        enemy: e,
                        seed,
                    });
                }
            }
        }
        self.staged.push(Staged {
            node,
            parent,
            count: samples.len(),
            samples,
            offset,
        });
    }

    fn accept_steps(&mut self, snapshots: &[Snapshot]) -> Result<()> {
        if self.stage != STEPS || snapshots.len() != self.requests.len() {
            return Err("unexpected simulator response shape or phase");
        }
        let base = self.snapshots.len();
        self.snapshots.extend_from_slice(snapshots);
        let mut level = Vec::new();
        for staged in self.staged.drain(..) {
            let root = self.nodes[staged.node].root;
            let divergent = snapshots[staged.offset..staged.offset + staged.count]
                .iter()
                .any(|s| s.divergent != 0);
            if divergent {
                if staged.parent.is_some() {
                    self.counters[self.configs[root].owner as usize].divergences += 1;
                } else {
                    self.good[root] = false;
                }
                continue;
            }
            if let Some((parent, position)) = staged.parent {
                self.expansions[parent].children[position] = Some(staged.node);
                self.counters[self.configs[root].owner as usize].interior += 1;
            }
            level.push(self.expansions.len());
            self.expansions.push(Expansion {
                node: staged.node,
                root,
                samples: staged.samples,
                successors: (base + staged.offset..base + staged.offset + staged.count).collect(),
                children: vec![None; staged.count],
                values: vec![None; staged.count],
            });
        }
        self.requests.clear();
        // Python retains an empty root level but stops on an empty interior level.
        if self.levels.is_empty() || !level.is_empty() {
            self.levels.push(level);
        } else {
            return self.prepare_leaves();
        }
        self.prepare_frontier()
    }

    fn prepare_frontier(&mut self) -> Result<()> {
        self.opening.clear();
        self.rows.clear();
        for &id in self.levels.last().unwrap() {
            let ex = &self.expansions[id];
            if self.configs[ex.root].depth < self.next_depth {
                continue;
            }
            for (position, &snapshot) in ex.successors.iter().enumerate() {
                if self.snapshots[snapshot].done != 0 {
                    continue;
                }
                self.opening.push((id, position));
                self.rows.push(Row {
                    root: ex.root as u64,
                    snapshot: snapshot as u64,
                });
            }
        }
        if self.rows.is_empty() {
            self.prepare_leaves()
        } else {
            self.stage = EVALUATE;
            Ok(())
        }
    }

    fn seed_roots(&self) -> Vec<usize> {
        let mut roots = Vec::new();
        for row in &self.rows {
            let root = row.root as usize;
            if !roots.contains(&root) {
                roots.push(root);
            }
        }
        roots
    }

    fn accept_evaluations(&mut self, evaluations: &[f64], seeds: &[u64]) -> Result<()> {
        let width = 2 * self.actions + 1;
        if self.stage != EVALUATE || evaluations.len() != self.rows.len() * width {
            return Err("unexpected evaluation shape or phase");
        }
        let seed_roots = self.seed_roots();
        if seeds.len()
            != seed_roots
                .iter()
                .map(|&r| self.configs[r].interior_chances as usize)
                .sum::<usize>()
        {
            return Err("interior chance seed count mismatch");
        }
        let mut offsets = vec![(0, 0); self.configs.len()];
        let mut offset = 0;
        for root in seed_roots {
            let count = self.configs[root].interior_chances as usize;
            offsets[root] = (offset, offset + count);
            offset += count;
        }
        for index in 0..self.rows.len() {
            let row = self.rows[index];
            let root = row.root as usize;
            let node = self.make_node(
                root,
                row.snapshot as usize,
                &evaluations[index * width..(index + 1) * width],
                self.configs[root].interior_width,
            )?;
            let (left, right) = offsets[root];
            self.stage_node(node, Some(self.opening[index]), &seeds[left..right]);
        }
        self.rows.clear();
        self.opening.clear();
        self.next_depth += 1;
        self.stage = STEPS;
        Ok(())
    }

    fn prepare_leaves(&mut self) -> Result<()> {
        self.rows.clear();
        self.leaf_slots.clear();
        for level in &self.levels {
            for &id in level {
                let ex = &self.expansions[id];
                for (position, &snapshot) in ex.successors.iter().enumerate() {
                    if ex.children[position].is_none() {
                        self.rows.push(Row {
                            root: ex.root as u64,
                            snapshot: snapshot as u64,
                        });
                        self.leaf_slots.push((id, position));
                    }
                }
            }
        }
        self.backup_level = self.levels.len().checked_sub(1);
        if self.rows.is_empty() {
            self.prepare_backup()
        } else {
            self.stage = VALUES;
            Ok(())
        }
    }

    fn accept_values(&mut self, values: &[f64]) -> Result<()> {
        if self.stage != VALUES
            || values.len() != self.leaf_slots.len()
            || values.iter().any(|v| !v.is_finite())
        {
            return Err("unexpected leaf value shape, value or phase");
        }
        for (&(id, position), &value) in self.leaf_slots.iter().zip(values) {
            self.expansions[id].values[position] = Some(value);
        }
        self.rows.clear();
        self.leaf_slots.clear();
        self.prepare_backup()
    }

    fn install(&mut self, id: usize) -> Result<()> {
        let ex = &mut self.expansions[id];
        for (position, child) in ex.children.iter().enumerate() {
            if let Some(child) = child {
                ex.values[position] = Some(self.nodes[*child].value);
            }
        }
        let n = &mut self.nodes[ex.node];
        for (&(p, e, world), value) in ex.samples.iter().zip(&ex.values) {
            let value = value.ok_or("tree backup left a payoff cell unpriced")?;
            let cell = p * self.actions + e;
            let count = n.counts[cell];
            // Preserve the Python arithmetic order; do not replace with a sum
            // reduction or incremental-difference mean (different rounding).
            n.payoff[cell] = (n.payoff[cell] * count as f64 + value) / (count + 1) as f64;
            n.counts[cell] += 1;
            if !n.half_payoff.is_empty() {
                let h = world % 2;
                let count = n.half_counts[h][cell];
                n.half_payoff[h][cell] =
                    (n.half_payoff[h][cell] * count as f64 + value) / (count + 1) as f64;
                n.half_counts[h][cell] += 1;
            }
        }
        let counts = &mut self.counters[self.configs[ex.root].owner as usize];
        counts.expanded += 1;
        let pairs = n.legal_player.len() * n.legal_enemy.len();
        counts.possible += pairs as u64;
        counts.sampled += pairs as u64;
        counts.chance += ex.values.len() as u64;
        self.transitions[ex.root] += ex.values.len() as u64;
        Ok(())
    }

    fn prepare_backup(&mut self) -> Result<()> {
        self.jobs.clear();
        while let Some(depth) = self.backup_level {
            self.backup_level = depth.checked_sub(1);
            for id in self.levels[depth].clone() {
                let ex = &self.expansions[id];
                if self.counters[self.configs[ex.root].owner as usize].divergences != 0 {
                    continue;
                }
                let (root, node) = (ex.root, ex.node);
                self.install(id)?;
                if depth != 0 {
                    self.jobs.push(Job {
                        root: root as u64,
                        node: node as u64,
                        half: 0,
                    });
                }
            }
            if depth == 0 {
                for root in 0..self.configs.len() {
                    if !self.good[root]
                        || self.counters[self.configs[root].owner as usize].divergences != 0
                    {
                        self.good[root] = false;
                        continue;
                    }
                    self.jobs.push(Job {
                        root: root as u64,
                        node: root as u64,
                        half: 0,
                    });
                    let n = &self.nodes[root];
                    if !n.half_counts.is_empty()
                        && n.half_counts.iter().all(|counts| {
                            n.legal_player.iter().all(|&p| {
                                n.legal_enemy
                                    .iter()
                                    .all(|&e| counts[p as usize * self.actions + e as usize] > 0)
                            })
                        })
                    {
                        for half in 1..=2 {
                            self.jobs.push(Job {
                                root: root as u64,
                                node: root as u64,
                                half,
                            });
                        }
                    }
                }
            }
            if !self.jobs.is_empty() {
                self.stage = SOLVE;
                return Ok(());
            }
        }
        self.stage = FINISHED;
        Ok(())
    }

    fn accept_solutions(&mut self, solutions: &[f64]) -> Result<()> {
        if self.stage != SOLVE
            || solutions.len() != self.jobs.len() * 2
            || solutions.iter().any(|v| !v.is_finite())
        {
            return Err("unexpected solution shape, value or phase");
        }
        for (job, value) in self.jobs.iter().zip(solutions.chunks_exact(2)) {
            if job.half == 0 {
                let node = &mut self.nodes[job.node as usize];
                node.value = value[0];
                node.exploitability = value[1];
            }
        }
        self.prepare_backup()
    }

    fn status(&self) -> Status {
        Status {
            stage: self.stage,
            rows: self.rows.len() as u64,
            requests: self.requests.len() as u64,
            jobs: self.jobs.len() as u64,
            seed_count: if self.stage == EVALUATE {
                self.seed_roots()
                    .iter()
                    .map(|&r| self.configs[r].interior_chances)
                    .sum()
            } else {
                0
            },
        }
    }
}

// Versioned, checked C ABI. Pointers must reference initialized buffers of the
// declared lengths. A handle is owned by one caller, used serially and freed once.
// Returned views borrow engine buffers and expire on the next mutation or free.
// No unwind is permitted to cross the ABI; errors are retrieved from the handle.
pub struct Handle {
    engine: Engine,
    error: String,
    poisoned: bool,
}
fn guard(handle: &mut Handle, f: impl FnOnce(&mut Engine) -> Result<()>) -> i32 {
    if handle.poisoned {
        return 1;
    }
    match catch_unwind(AssertUnwindSafe(|| f(&mut handle.engine))) {
        Ok(Ok(())) => 0,
        Ok(Err(e)) => {
            handle.error = e.into();
            handle.poisoned = true;
            1
        }
        Err(_) => {
            handle.error = "native search panic".into();
            handle.poisoned = true;
            255
        }
    }
}
unsafe fn input<'a, T>(ptr: *const T, len: usize) -> Result<&'a [T]> {
    if len == 0 {
        return Ok(&[]);
    }
    if ptr.is_null() || len > isize::MAX as usize / std::mem::size_of::<T>() {
        return Err("null or oversized input buffer");
    }
    Ok(slice::from_raw_parts(ptr, len))
}

#[no_mangle]
pub extern "C" fn battle_search_abi_v1() -> u64 {
    1
}

/// # Safety
/// All input pointers must hold their declared lengths; `out` must be writable.
#[no_mangle]
pub unsafe extern "C" fn battle_search_new_v1(
    actions: usize,
    configs: *const Config,
    roots: *const Snapshot,
    n: usize,
    evaluations: *const f64,
    eval_len: usize,
    seeds: *const u64,
    seed_len: usize,
    out: *mut *mut Handle,
) -> i32 {
    if out.is_null() {
        return 1;
    }
    *out = std::ptr::null_mut();
    match catch_unwind(AssertUnwindSafe(|| -> Result<Engine> {
        Engine::new(
            actions,
            input(configs, n)?.to_vec(),
            input(roots, n)?.to_vec(),
            input(evaluations, eval_len)?,
            input(seeds, seed_len)?,
        )
    })) {
        Ok(Ok(engine)) => {
            *out = Box::into_raw(Box::new(Handle {
                engine,
                error: String::new(),
                poisoned: false,
            }));
            0
        }
        Ok(Err(_)) => 1,
        Err(_) => 255,
    }
}
/// # Safety
/// `handle` is null or a live handle returned by new, freed exactly once.
#[no_mangle]
pub unsafe extern "C" fn battle_search_free_v1(handle: *mut Handle) {
    if !handle.is_null() {
        drop(Box::from_raw(handle));
    }
}

macro_rules! submit {
    ($name:ident, $ty:ty, $method:ident) => {
        /// # Safety
        /// The handle is live and exclusive; data holds `len` initialized entries.
        #[no_mangle]
        pub unsafe extern "C" fn $name(handle: *mut Handle, data: *const $ty, len: usize) -> i32 {
            if handle.is_null() {
                return 1;
            }
            guard(&mut *handle, |e| e.$method(input(data, len)?))
        }
    };
}
submit!(battle_search_steps_v1, Snapshot, accept_steps);
submit!(battle_search_values_v1, f64, accept_values);
submit!(battle_search_solutions_v1, f64, accept_solutions);
/// # Safety
/// The handle is live and exclusive; input buffers hold their declared lengths.
#[no_mangle]
pub unsafe extern "C" fn battle_search_evaluations_v1(
    handle: *mut Handle,
    values: *const f64,
    len: usize,
    seeds: *const u64,
    seed_len: usize,
) -> i32 {
    if handle.is_null() {
        return 1;
    }
    guard(&mut *handle, |e| {
        e.accept_evaluations(input(values, len)?, input(seeds, seed_len)?)
    })
}
/// # Safety
/// The handle is live; output pointers are writable. Views expire on mutation.
#[no_mangle]
pub unsafe extern "C" fn battle_search_view_v1(
    handle: *const Handle,
    status: *mut Status,
    rows: *mut *const Row,
    requests: *mut *const Request,
    jobs: *mut *const Job,
) -> i32 {
    if handle.is_null() || status.is_null() || rows.is_null() || requests.is_null() || jobs.is_null()
    {
        return 1;
    }
    let h = &*handle;
    if h.poisoned {
        return 1;
    }
    *status = h.engine.status();
    *rows = h.engine.rows.as_ptr();
    *requests = h.engine.requests.as_ptr();
    *jobs = h.engine.jobs.as_ptr();
    0
}
/// # Safety
/// The handle is live and out writable. Returned views expire on mutation.
#[no_mangle]
pub unsafe extern "C" fn battle_search_node_v1(
    handle: *const Handle,
    index: usize,
    out: *mut NodeView,
) -> i32 {
    if handle.is_null() || out.is_null() {
        return 1;
    }
    let h = &*handle;
    let Some(n) = h.engine.nodes.get(index) else {
        return 1;
    };
    let halves = !n.half_payoff.is_empty();
    *out = NodeView {
        root: n.root as u64,
        snapshot: n.snapshot as u64,
        player_len: n.legal_player.len() as u64,
        enemy_len: n.legal_enemy.len() as u64,
        player: n.player.as_ptr(),
        enemy: n.enemy.as_ptr(),
        legal_player: n.legal_player.as_ptr(),
        legal_enemy: n.legal_enemy.as_ptr(),
        payoff: n.payoff.as_ptr(),
        counts: n.counts.as_ptr(),
        half0: if halves {
            n.half_payoff[0].as_ptr()
        } else {
            std::ptr::null()
        },
        half1: if halves {
            n.half_payoff[1].as_ptr()
        } else {
            std::ptr::null()
        },
        counts0: if halves {
            n.half_counts[0].as_ptr()
        } else {
            std::ptr::null()
        },
        counts1: if halves {
            n.half_counts[1].as_ptr()
        } else {
            std::ptr::null()
        },
        leaf: n.leaf,
        value: n.value,
        exploitability: n.exploitability,
    };
    0
}
/// # Safety
/// The handle is live and out writable.
#[no_mangle]
pub unsafe extern "C" fn battle_search_root_v1(
    handle: *const Handle,
    root: usize,
    out: *mut RootStatus,
) -> i32 {
    if handle.is_null() || out.is_null() {
        return 1;
    }
    let e = &(*handle).engine;
    let Some(config) = e.configs.get(root) else {
        return 1;
    };
    let c = &e.counters[config.owner as usize];
    *out = RootStatus {
        good: e.good[root] as u64,
        transitions: e.transitions[root],
        root_leaves: e.root_leaves[root],
        expanded: c.expanded,
        possible_pairs: c.possible,
        sampled_pairs: c.sampled,
        chance_outcomes: c.chance,
        interior_nodes: c.interior,
        interior_divergences: c.divergences,
    };
    0
}
/// # Safety
/// The handle is live and the output buffer is writable for `len` bytes.
#[no_mangle]
pub unsafe extern "C" fn battle_search_error_v1(
    handle: *const Handle,
    out: *mut u8,
    len: usize,
) -> usize {
    if handle.is_null() {
        return 0;
    }
    let bytes = (*handle).error.as_bytes();
    if !out.is_null() && len > 0 {
        std::ptr::copy_nonoverlapping(bytes.as_ptr(), out, len.min(bytes.len()));
    }
    bytes.len()
}

#[cfg(test)]
mod tests {
    use super::*;
    fn config() -> Config {
        Config {
            owner: 0,
            depth: 1,
            root_width: 2,
            interior_width: 2,
            root_chances: 2,
            interior_chances: 1,
            split: 1,
            initial_divergences: 0,
        }
    }
    fn root() -> Snapshot {
        Snapshot {
            handle: 10,
            player_mask: 3,
            enemy_mask: 3,
            ..Snapshot::default()
        }
    }
    fn engine() -> Engine {
        Engine::new(
            2,
            vec![config()],
            vec![root()],
            &[0.5, 0.5, 0.5, 0.5, 0.25],
            &[7, 9],
        )
        .unwrap()
    }
    #[test]
    fn ties_and_chance_worlds_preserve_request_order() {
        let e = engine();
        let expected: Vec<_> = (0..2)
            .flat_map(|p| {
                (0..2).flat_map(move |enemy| {
                    [7, 9].map(move |seed| Request {
                        handle: 10,
                        player: p,
                        enemy,
                        seed,
                    })
                })
            })
            .collect();
        assert_eq!(e.requests, expected);
    }
    #[test]
    fn backup_keeps_mean_distinct_from_half_solutions() {
        let mut e = engine();
        e.accept_steps(&[Snapshot { done: 1, ..root() }; 8])
            .unwrap();
        assert_eq!(e.stage, VALUES);
        e.accept_values(&[0.9, -0.5, 0.9, -0.5, 0.1, 0.1, 0.1, 0.1])
            .unwrap();
        assert_eq!(e.stage, SOLVE);
        assert_eq!(e.jobs.len(), 3);
        assert_eq!(e.nodes[0].payoff, vec![0.2, 0.2, 0.1, 0.1]);
        e.accept_solutions(&[0.2, 0.0, 0.9, 0.0, 0.1, 0.0]).unwrap();
        assert_eq!(e.nodes[0].value, 0.2);
        assert_eq!(e.stage, FINISHED);
    }
    #[test]
    fn one_world_does_not_claim_split_half_coverage() {
        let mut c = config();
        c.root_chances = 1;
        let mut e = Engine::new(2, vec![c], vec![root()], &[0.5, 0.5, 0.5, 0.5, 0.0], &[7]).unwrap();
        e.accept_steps(&[Snapshot { done: 1, ..root() }; 4])
            .unwrap();
        e.accept_values(&[0.; 4]).unwrap();
        assert_eq!(e.jobs.len(), 1);
    }
    #[test]
    fn divergent_root_has_no_value_or_solver_jobs() {
        let mut e = engine();
        e.accept_steps(
            &[Snapshot {
                divergent: 1,
                ..root()
            }; 8],
        )
        .unwrap();
        assert_eq!(e.stage, FINISHED);
        assert!(!e.good[0]);
        assert_eq!(e.counters[0].expanded, 0);
        assert!(e.jobs.is_empty());
    }
    #[test]
    fn invalid_phase_and_lengths_poison_handle() {
        let mut h = Handle {
            engine: engine(),
            error: String::new(),
            poisoned: false,
        };
        assert_ne!(guard(&mut h, |e| e.accept_values(&[])), 0);
        assert!(h.poisoned);
        assert_ne!(guard(&mut h, |_| Ok(())), 0);
        let mut e = engine();
        assert!(e.accept_steps(&[]).is_err());
        assert!(Engine::new(2, vec![config()], vec![root()], &[0.5; 4], &[7, 9]).is_err());
        assert!(Engine::new(2, vec![config()], vec![root()], &[f64::NAN; 5], &[7, 9]).is_err());
    }
    #[test]
    fn null_abi_arguments_fail_without_unwinding() {
        unsafe {
            assert_eq!(
                battle_search_steps_v1(std::ptr::null_mut(), std::ptr::null(), 0),
                1
            );
            let mut out = std::ptr::null_mut();
            assert_eq!(
                battle_search_new_v1(
                    2,
                    std::ptr::null(),
                    std::ptr::null(),
                    1,
                    std::ptr::null(),
                    0,
                    std::ptr::null(),
                    0,
                    &mut out
                ),
                1
            );
            assert!(out.is_null());
            battle_search_free_v1(out);
        }
    }
}
