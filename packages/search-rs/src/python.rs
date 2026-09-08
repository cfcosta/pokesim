//! Owned Python bindings. No raw handles or borrowed engine pointers cross PyO3.
use crate::{guard, Config, Engine, Handle, Snapshot};
use pyo3::{exceptions::PyRuntimeError, prelude::*, types::PyDict};
use std::panic::{catch_unwind, AssertUnwindSafe};

type ConfigInput = (u64, u64, u64, u64, u64, u64, u64, u64);
type SnapshotInput = (u64, u64, u64, u64, u64);

fn snapshots(rows: Vec<SnapshotInput>) -> Vec<Snapshot> {
    rows.into_iter()
        .map(
            |(handle, player_mask, enemy_mask, done, divergent)| Snapshot {
                handle,
                player_mask,
                enemy_mask,
                done,
                divergent,
            },
        )
        .collect()
}

#[pyclass(name = "Engine", module = "battle_search")]
struct PythonEngine {
    handle: Option<Handle>,
}

impl PythonEngine {
    fn engine(&self) -> PyResult<&Engine> {
        let h = self
            .handle
            .as_ref()
            .ok_or_else(|| PyRuntimeError::new_err("native search is closed"))?;
        if h.poisoned {
            return Err(PyRuntimeError::new_err(h.error.clone()));
        }
        Ok(&h.engine)
    }
    fn update(
        &mut self,
        py: Python<'_>,
        f: impl FnOnce(&mut Engine) -> crate::Result<()> + Send,
    ) -> PyResult<()> {
        let h = self
            .handle
            .as_mut()
            .ok_or_else(|| PyRuntimeError::new_err("native search is closed"))?;
        let code = py.detach(|| guard(h, f));
        if code != 0 {
            return Err(PyRuntimeError::new_err(h.error.clone()));
        }
        Ok(())
    }
}

#[pymethods]
impl PythonEngine {
    #[new]
    fn new(
        py: Python<'_>,
        actions: usize,
        configs: Vec<ConfigInput>,
        roots: Vec<SnapshotInput>,
        evaluations: Vec<f64>,
        seeds: Vec<u64>,
    ) -> PyResult<Self> {
        let result = py.detach(|| {
            catch_unwind(AssertUnwindSafe(|| {
                let configs = configs
                    .into_iter()
                    .map(
                        |(
                            owner,
                            depth,
                            root_width,
                            interior_width,
                            root_chances,
                            interior_chances,
                            split,
                            initial_divergences,
                        )| Config {
                            owner,
                            depth,
                            root_width,
                            interior_width,
                            root_chances,
                            interior_chances,
                            split,
                            initial_divergences,
                        },
                    )
                    .collect();
                Engine::new(actions, configs, snapshots(roots), &evaluations, &seeds)
            }))
        });
        let engine = result
            .map_err(|_| PyRuntimeError::new_err("native search panic"))?
            .map_err(PyRuntimeError::new_err)?;
        Ok(Self {
            handle: Some(Handle {
                engine,
                error: String::new(),
                poisoned: false,
            }),
        })
    }
    fn close(&mut self, py: Python<'_>) {
        let handle = self.handle.take();
        py.detach(|| drop(handle));
    }
    fn steps(&mut self, py: Python<'_>, rows: Vec<SnapshotInput>) -> PyResult<()> {
        self.update(py, |e| e.accept_steps(&snapshots(rows)))
    }
    fn evaluations(&mut self, py: Python<'_>, values: Vec<f64>, seeds: Vec<u64>) -> PyResult<()> {
        self.update(py, |e| e.accept_evaluations(&values, &seeds))
    }
    fn values(&mut self, py: Python<'_>, values: Vec<f64>) -> PyResult<()> {
        self.update(py, |e| e.accept_values(&values))
    }
    fn solutions(&mut self, py: Python<'_>, values: Vec<f64>) -> PyResult<()> {
        self.update(py, |e| e.accept_solutions(&values))
    }
    fn view<'py>(&self, py: Python<'py>) -> PyResult<(u64, Bound<'py, PyAny>)> {
        let e = self.engine()?;
        let rows = match e.stage {
            crate::STEPS => e
                .requests
                .iter()
                .map(|r| (r.handle, r.player, r.enemy, r.seed))
                .collect::<Vec<_>>()
                .into_pyobject(py)?
                .into_any(),
            crate::EVALUATE | crate::VALUES => e
                .rows
                .iter()
                .map(|r| (r.root, r.snapshot))
                .collect::<Vec<_>>()
                .into_pyobject(py)?
                .into_any(),
            crate::SOLVE => e
                .jobs
                .iter()
                .map(|j| (j.root, j.node, j.half))
                .collect::<Vec<_>>()
                .into_pyobject(py)?
                .into_any(),
            _ => Vec::<u64>::new().into_pyobject(py)?.into_any(),
        };
        Ok((e.stage, rows))
    }
    #[pyo3(signature = (index, full=false))]
    fn node<'py>(&self, py: Python<'py>, index: usize, full: bool) -> PyResult<Bound<'py, PyDict>> {
        let e = self.engine()?;
        let n = e
            .nodes
            .get(index)
            .ok_or_else(|| PyRuntimeError::new_err("invalid node index"))?;
        let d = PyDict::new(py);
        d.set_item("snapshot", n.snapshot)?;
        d.set_item("player_priors", &n.player)?;
        d.set_item("enemy_priors", &n.enemy)?;
        d.set_item("player_legal", &n.legal_player)?;
        d.set_item("enemy_legal", &n.legal_enemy)?;
        d.set_item("payoff", n.payoff.chunks(e.actions).collect::<Vec<_>>())?;
        d.set_item("leaf_value", n.leaf)?;
        d.set_item("root_value", n.value)?;
        d.set_item("exploitability", n.exploitability)?;
        let half_payoff: Vec<_> = n
            .half_payoff
            .iter()
            .take(if full { 2 } else { 0 })
            .map(|v| v.chunks(e.actions).collect::<Vec<_>>())
            .collect();
        let half_counts: Vec<_> = n
            .half_counts
            .iter()
            .take(if full { 2 } else { 0 })
            .map(|v| v.chunks(e.actions).collect::<Vec<_>>())
            .collect();
        d.set_item("half_payoff", half_payoff)?;
        d.set_item("half_counts", half_counts)?;
        Ok(d)
    }
    fn root<'py>(&self, py: Python<'py>, index: usize) -> PyResult<Bound<'py, PyDict>> {
        let e = self.engine()?;
        let config = e
            .configs
            .get(index)
            .ok_or_else(|| PyRuntimeError::new_err("invalid root index"))?;
        let c = &e.counters[config.owner as usize];
        let d = PyDict::new(py);
        for (name, value) in [
            ("good", e.good[index] as u64),
            ("transitions", e.transitions[index]),
            ("root_leaves", e.root_leaves[index]),
            ("expanded", c.expanded),
            ("possible_pairs", c.possible),
            ("sampled_pairs", c.sampled),
            ("chance_outcomes", c.chance),
            ("interior_nodes", c.interior),
            ("interior_divergences", c.divergences),
        ] {
            d.set_item(name, value)?;
        }
        Ok(d)
    }
}

#[pymodule]
fn battle_search(m: &Bound<'_, PyModule>) -> PyResult<()> {
    m.add("API_VERSION", 1)?;
    m.add_class::<PythonEngine>()?;
    crate::transport::register_python(m)?;
    Ok(())
}
