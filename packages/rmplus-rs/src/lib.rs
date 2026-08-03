//! Deterministic native regret-matching kernels for simultaneous zero-sum search.
//!
//! The update order follows the joint solver in `mcts-rs` commit
//! `afc6e5d4ca6f0ce560a52add625e2b1d883b5456`.  The optional accelerated
//! path uses alternating regret updates and linearly weighted averages (CFR+).
//! No search topology, action pruning, chance, or neural inference lives here.

use std::panic::{catch_unwind, AssertUnwindSafe};
use std::slice;

const OK: i32 = 0;
const NULL_POINTER: i32 = 1;
const INVALID_SHAPE: i32 = 2;
const INVALID_ITERATIONS: i32 = 3;
const INVALID_LEGAL_ACTION: i32 = 4;
const PANIC: i32 = 255;

#[derive(Debug)]
struct ColdResult {
    player_policy: Vec<f64>,
    enemy_policy: Vec<f64>,
    value: f64,
    exploitability: f64,
}

fn normalized_prior(priors: &[f64], legal: &[usize]) -> Vec<f64> {
    let mut result: Vec<f64> = legal.iter().map(|&action| priors[action]).collect();
    let total: f64 = result.iter().sum();
    if total > 0.0 {
        for value in &mut result {
            *value /= total;
        }
    } else {
        result.fill(1.0 / legal.len() as f64);
    }
    result
}

fn regret_strategy(regrets: &[f64], prior: &[f64], out: &mut [f64]) {
    let mut total = 0.0;
    for (target, &regret) in out.iter_mut().zip(regrets) {
        *target = regret.max(0.0);
        total += *target;
    }
    if total > 0.0 {
        for probability in out {
            *probability /= total;
        }
    } else {
        out.copy_from_slice(prior);
    }
}

fn mat_vec(matrix: &[f64], columns: usize, vector: &[f64], out: &mut [f64]) {
    for (row, target) in matrix.chunks_exact(columns).zip(out) {
        *target = row
            .iter()
            .zip(vector)
            .fold(0.0, |sum, (&left, &right)| sum + left * right);
    }
}

fn vec_mat(vector: &[f64], matrix: &[f64], columns: usize, out: &mut [f64]) {
    out.fill(0.0);
    for (row, &weight) in matrix.chunks_exact(columns).zip(vector) {
        for (target, &value) in out.iter_mut().zip(row) {
            *target += weight * value;
        }
    }
}

fn dot(left: &[f64], right: &[f64]) -> f64 {
    left.iter()
        .zip(right)
        .fold(0.0, |sum, (&a, &b)| sum + a * b)
}

fn extrema(values: &[f64]) -> (f64, f64) {
    let mut maximum = f64::NEG_INFINITY;
    let mut minimum = f64::INFINITY;
    for &value in values {
        maximum = maximum.max(value);
        minimum = minimum.min(value);
    }
    (maximum, minimum)
}

fn strategy_weight_total(cfr_plus: bool, iterations: u32) -> f64 {
    if cfr_plus {
        let count = f64::from(iterations);
        count * (count + 1.0) / 2.0
    } else {
        f64::from(iterations)
    }
}

fn compact_matrix(
    payoff: &[f64],
    action_count: usize,
    player_legal: &[usize],
    enemy_legal: &[usize],
) -> Vec<f64> {
    let mut matrix = Vec::with_capacity(player_legal.len() * enemy_legal.len());
    for &player in player_legal {
        for &enemy in enemy_legal {
            matrix.push(payoff[player * action_count + enemy]);
        }
    }
    matrix
}

fn solve_cold(
    payoff: &[f64],
    action_count: usize,
    player_priors: &[f64],
    enemy_priors: &[f64],
    player_legal: &[usize],
    enemy_legal: &[usize],
    iterations: u32,
    cfr_plus: bool,
) -> ColdResult {
    let player_len = player_legal.len();
    let enemy_len = enemy_legal.len();
    let matrix = compact_matrix(payoff, action_count, player_legal, enemy_legal);
    let player_prior = normalized_prior(player_priors, player_legal);
    let enemy_prior = normalized_prior(enemy_priors, enemy_legal);
    let mut player_regrets = vec![0.0; player_len];
    let mut enemy_regrets = vec![0.0; enemy_len];
    let mut player_sum = vec![0.0; player_len];
    let mut enemy_sum = vec![0.0; enemy_len];
    let mut player = vec![0.0; player_len];
    let mut enemy = vec![0.0; enemy_len];
    let mut row_values = vec![0.0; player_len];
    let mut column_values = vec![0.0; enemy_len];

    for iteration in 0..iterations {
        regret_strategy(&player_regrets, &player_prior, &mut player);
        regret_strategy(&enemy_regrets, &enemy_prior, &mut enemy);
        let weight = if cfr_plus {
            f64::from(iteration + 1)
        } else {
            1.0
        };
        for (sum, &probability) in player_sum.iter_mut().zip(&player) {
            *sum += weight * probability;
        }
        for (sum, &probability) in enemy_sum.iter_mut().zip(&enemy) {
            *sum += weight * probability;
        }
        mat_vec(&matrix, enemy_len, &enemy, &mut row_values);
        let current_value = dot(&player, &row_values);
        for (regret, &row_value) in player_regrets.iter_mut().zip(&row_values) {
            *regret = (*regret + row_value - current_value).max(0.0);
        }
        if cfr_plus {
            regret_strategy(&player_regrets, &player_prior, &mut player);
        }
        vec_mat(&player, &matrix, enemy_len, &mut column_values);
        let enemy_value = if cfr_plus {
            dot(&enemy, &column_values)
        } else {
            current_value
        };
        for (regret, &column_value) in enemy_regrets.iter_mut().zip(&column_values) {
            *regret = (*regret + enemy_value - column_value).max(0.0);
        }
    }

    let weight_total = strategy_weight_total(cfr_plus, iterations);
    let player_average: Vec<f64> = player_sum.iter().map(|sum| sum / weight_total).collect();
    let enemy_average: Vec<f64> = enemy_sum.iter().map(|sum| sum / weight_total).collect();
    let mut player_policy = vec![0.0; action_count];
    let mut enemy_policy = vec![0.0; action_count];
    for (index, &action) in player_legal.iter().enumerate() {
        player_policy[action] = player_average[index];
    }
    for (index, &action) in enemy_legal.iter().enumerate() {
        enemy_policy[action] = enemy_average[index];
    }
    mat_vec(&matrix, enemy_len, &enemy_average, &mut row_values);
    vec_mat(&player_average, &matrix, enemy_len, &mut column_values);
    let value = dot(&player_average, &row_values);
    let (best_response, _) = extrema(&row_values);
    let (_, worst_response) = extrema(&column_values);
    ColdResult {
        player_policy,
        enemy_policy,
        value,
        exploitability: best_response - worst_response,
    }
}

#[allow(clippy::too_many_arguments)]
fn solve_warm(
    payoff: &[f64],
    action_count: usize,
    player_priors: &[f64],
    enemy_priors: &[f64],
    player_legal: &[usize],
    enemy_legal: &[usize],
    player_regrets_full: &mut [f64],
    enemy_regrets_full: &mut [f64],
    player_strategy_sum_full: &mut [f64],
    enemy_strategy_sum_full: &mut [f64],
    solve_count: &mut u32,
    iterations: u32,
    cfr_plus: bool,
) -> ColdResult {
    let player_len = player_legal.len();
    let enemy_len = enemy_legal.len();
    let matrix = compact_matrix(payoff, action_count, player_legal, enemy_legal);
    let player_prior = normalized_prior(player_priors, player_legal);
    let enemy_prior = normalized_prior(enemy_priors, enemy_legal);
    let mut player_regrets: Vec<f64> = player_legal
        .iter()
        .map(|&action| player_regrets_full[action])
        .collect();
    let mut enemy_regrets: Vec<f64> = enemy_legal
        .iter()
        .map(|&action| enemy_regrets_full[action])
        .collect();
    let mut player_sum = vec![0.0; player_len];
    let mut enemy_sum = vec![0.0; enemy_len];
    let mut player = vec![0.0; player_len];
    let mut enemy = vec![0.0; enemy_len];
    let mut row_values = vec![0.0; player_len];
    let mut column_values = vec![0.0; enemy_len];
    let weight_base = f64::from(*solve_count);

    for iteration in 0..iterations {
        regret_strategy(&player_regrets, &player_prior, &mut player);
        regret_strategy(&enemy_regrets, &enemy_prior, &mut enemy);
        let weight = if cfr_plus {
            weight_base + f64::from(iteration + 1)
        } else {
            1.0
        };
        for (sum, &probability) in player_sum.iter_mut().zip(&player) {
            *sum += weight * probability;
        }
        for (sum, &probability) in enemy_sum.iter_mut().zip(&enemy) {
            *sum += weight * probability;
        }
        mat_vec(&matrix, enemy_len, &enemy, &mut row_values);
        let current_value = dot(&player, &row_values);
        for (regret, &row_value) in player_regrets.iter_mut().zip(&row_values) {
            *regret = (*regret + row_value - current_value).max(0.0);
        }
        if cfr_plus {
            regret_strategy(&player_regrets, &player_prior, &mut player);
        }
        vec_mat(&player, &matrix, enemy_len, &mut column_values);
        let enemy_value = if cfr_plus {
            dot(&enemy, &column_values)
        } else {
            current_value
        };
        for (regret, &column_value) in enemy_regrets.iter_mut().zip(&column_values) {
            *regret = (*regret + enemy_value - column_value).max(0.0);
        }
    }

    for (index, &action) in player_legal.iter().enumerate() {
        player_regrets_full[action] = player_regrets[index];
        player_strategy_sum_full[action] += player_sum[index];
    }
    for (index, &action) in enemy_legal.iter().enumerate() {
        enemy_regrets_full[action] = enemy_regrets[index];
        enemy_strategy_sum_full[action] += enemy_sum[index];
    }
    *solve_count += iterations;

    let mut player_policy = vec![0.0; action_count];
    let mut enemy_policy = vec![0.0; action_count];
    for (index, &action) in player_legal.iter().enumerate() {
        player_policy[action] = player[index];
    }
    for (index, &action) in enemy_legal.iter().enumerate() {
        enemy_policy[action] = enemy[index];
    }
    mat_vec(&matrix, enemy_len, &enemy, &mut row_values);
    vec_mat(&player, &matrix, enemy_len, &mut column_values);
    let value = dot(&player, &row_values);
    let (best_response, _) = extrema(&row_values);
    let (_, worst_response) = extrema(&column_values);
    ColdResult {
        player_policy,
        enemy_policy,
        value,
        exploitability: best_response - worst_response,
    }
}

fn validate_shape(
    action_count: usize,
    iterations: u32,
    player_legal: &[usize],
    enemy_legal: &[usize],
) -> Result<(), i32> {
    if action_count == 0 || player_legal.is_empty() || enemy_legal.is_empty() {
        return Err(INVALID_SHAPE);
    }
    if iterations == 0 {
        return Err(INVALID_ITERATIONS);
    }
    if player_legal
        .iter()
        .chain(enemy_legal)
        .any(|&a| a >= action_count)
    {
        return Err(INVALID_LEGAL_ACTION);
    }
    Ok(())
}

fn guarded(operation: impl FnOnce() -> Result<(), i32>) -> i32 {
    match catch_unwind(AssertUnwindSafe(operation)) {
        Ok(Ok(())) => OK,
        Ok(Err(status)) => status,
        Err(_) => PANIC,
    }
}

/// Solves a fresh matrix equilibrium. All arrays are contiguous native-endian `f64`,
/// except legal actions (`u32`). Output policies have `action_count` entries.
#[no_mangle]
#[allow(clippy::too_many_arguments)]
pub unsafe extern "C" fn battle_rmplus_solve_cold_v1(
    action_count: u32,
    iterations: u32,
    cfr_plus: u8,
    payoff: *const f64,
    player_priors: *const f64,
    enemy_priors: *const f64,
    player_legal: *const u32,
    player_legal_len: u32,
    enemy_legal: *const u32,
    enemy_legal_len: u32,
    out_player_policy: *mut f64,
    out_enemy_policy: *mut f64,
    out_value: *mut f64,
    out_exploitability: *mut f64,
) -> i32 {
    guarded(|| {
        if payoff.is_null()
            || player_priors.is_null()
            || enemy_priors.is_null()
            || player_legal.is_null()
            || enemy_legal.is_null()
            || out_player_policy.is_null()
            || out_enemy_policy.is_null()
            || out_value.is_null()
            || out_exploitability.is_null()
        {
            return Err(NULL_POINTER);
        }
        let n = action_count as usize;
        let player_actions_u32 = slice::from_raw_parts(player_legal, player_legal_len as usize);
        let enemy_actions_u32 = slice::from_raw_parts(enemy_legal, enemy_legal_len as usize);
        let player_actions: Vec<usize> = player_actions_u32.iter().map(|&a| a as usize).collect();
        let enemy_actions: Vec<usize> = enemy_actions_u32.iter().map(|&a| a as usize).collect();
        validate_shape(n, iterations, &player_actions, &enemy_actions)?;
        let result = solve_cold(
            slice::from_raw_parts(payoff, n * n),
            n,
            slice::from_raw_parts(player_priors, n),
            slice::from_raw_parts(enemy_priors, n),
            &player_actions,
            &enemy_actions,
            iterations,
            cfr_plus != 0,
        );
        slice::from_raw_parts_mut(out_player_policy, n).copy_from_slice(&result.player_policy);
        slice::from_raw_parts_mut(out_enemy_policy, n).copy_from_slice(&result.enemy_policy);
        *out_value = result.value;
        *out_exploitability = result.exploitability;
        Ok(())
    })
}

/// Advances one warm-started node solve. Regret/strategy arrays and solve count
/// are updated in place; policies, value, and exploitability are outputs.
#[no_mangle]
#[allow(clippy::too_many_arguments)]
pub unsafe extern "C" fn battle_rmplus_solve_warm_v1(
    action_count: u32,
    iterations: u32,
    cfr_plus: u8,
    payoff: *const f64,
    player_priors: *const f64,
    enemy_priors: *const f64,
    player_legal: *const u32,
    player_legal_len: u32,
    enemy_legal: *const u32,
    enemy_legal_len: u32,
    player_regrets: *mut f64,
    enemy_regrets: *mut f64,
    player_strategy_sum: *mut f64,
    enemy_strategy_sum: *mut f64,
    solve_count: *mut u32,
    out_player_policy: *mut f64,
    out_enemy_policy: *mut f64,
    out_value: *mut f64,
    out_exploitability: *mut f64,
) -> i32 {
    guarded(|| {
        if payoff.is_null()
            || player_priors.is_null()
            || enemy_priors.is_null()
            || player_legal.is_null()
            || enemy_legal.is_null()
            || player_regrets.is_null()
            || enemy_regrets.is_null()
            || player_strategy_sum.is_null()
            || enemy_strategy_sum.is_null()
            || solve_count.is_null()
            || out_player_policy.is_null()
            || out_enemy_policy.is_null()
            || out_value.is_null()
            || out_exploitability.is_null()
        {
            return Err(NULL_POINTER);
        }
        let n = action_count as usize;
        let player_actions_u32 = slice::from_raw_parts(player_legal, player_legal_len as usize);
        let enemy_actions_u32 = slice::from_raw_parts(enemy_legal, enemy_legal_len as usize);
        let player_actions: Vec<usize> = player_actions_u32.iter().map(|&a| a as usize).collect();
        let enemy_actions: Vec<usize> = enemy_actions_u32.iter().map(|&a| a as usize).collect();
        validate_shape(n, iterations, &player_actions, &enemy_actions)?;
        let result = solve_warm(
            slice::from_raw_parts(payoff, n * n),
            n,
            slice::from_raw_parts(player_priors, n),
            slice::from_raw_parts(enemy_priors, n),
            &player_actions,
            &enemy_actions,
            slice::from_raw_parts_mut(player_regrets, n),
            slice::from_raw_parts_mut(enemy_regrets, n),
            slice::from_raw_parts_mut(player_strategy_sum, n),
            slice::from_raw_parts_mut(enemy_strategy_sum, n),
            &mut *solve_count,
            iterations,
            cfr_plus != 0,
        );
        slice::from_raw_parts_mut(out_player_policy, n).copy_from_slice(&result.player_policy);
        slice::from_raw_parts_mut(out_enemy_policy, n).copy_from_slice(&result.enemy_policy);
        *out_value = result.value;
        *out_exploitability = result.exploitability;
        Ok(())
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn matching_pennies_is_uniform() {
        let payoff = vec![1.0, -1.0, -1.0, 1.0];
        let prior = vec![0.5, 0.5];
        let result = solve_cold(&payoff, 2, &prior, &prior, &[0, 1], &[0, 1], 64, false);
        assert_eq!(result.player_policy, vec![0.5, 0.5]);
        assert_eq!(result.enemy_policy, vec![0.5, 0.5]);
        assert_eq!(result.value, 0.0);
        assert_eq!(result.exploitability, 0.0);
    }

    #[test]
    fn cfr_plus_converges_faster_on_a_fixed_matrix() {
        let payoff = vec![0.71, -0.42, 0.19, -0.83, 0.37, 0.54, -0.28, 0.91, -0.66];
        let prior = vec![1.0 / 3.0; 3];
        let uniform = solve_cold(
            &payoff,
            3,
            &prior,
            &prior,
            &[0, 1, 2],
            &[0, 1, 2],
            64,
            false,
        );
        let accelerated = solve_cold(&payoff, 3, &prior, &prior, &[0, 1, 2], &[0, 1, 2], 64, true);
        assert!(accelerated.exploitability < uniform.exploitability);
    }

    #[test]
    fn split_warm_solves_match_one_long_solve() {
        let payoff = vec![0.8, -0.3, -0.6, 0.5];
        let prior = vec![0.5, 0.5];
        let mut split_regret_p = vec![0.0; 2];
        let mut split_regret_e = vec![0.0; 2];
        let mut split_sum_p = vec![0.0; 2];
        let mut split_sum_e = vec![0.0; 2];
        let mut split_count = 0;
        solve_warm(
            &payoff,
            2,
            &prior,
            &prior,
            &[0, 1],
            &[0, 1],
            &mut split_regret_p,
            &mut split_regret_e,
            &mut split_sum_p,
            &mut split_sum_e,
            &mut split_count,
            16,
            true,
        );
        let split = solve_warm(
            &payoff,
            2,
            &prior,
            &prior,
            &[0, 1],
            &[0, 1],
            &mut split_regret_p,
            &mut split_regret_e,
            &mut split_sum_p,
            &mut split_sum_e,
            &mut split_count,
            16,
            true,
        );

        let mut long_regret_p = vec![0.0; 2];
        let mut long_regret_e = vec![0.0; 2];
        let mut long_sum_p = vec![0.0; 2];
        let mut long_sum_e = vec![0.0; 2];
        let mut long_count = 0;
        let long = solve_warm(
            &payoff,
            2,
            &prior,
            &prior,
            &[0, 1],
            &[0, 1],
            &mut long_regret_p,
            &mut long_regret_e,
            &mut long_sum_p,
            &mut long_sum_e,
            &mut long_count,
            32,
            true,
        );

        let close =
            |left: &[f64], right: &[f64]| left.iter().zip(right).all(|(a, b)| (a - b).abs() <= 1e-12);
        assert_eq!(split_count, long_count);
        assert!(close(&split_regret_p, &long_regret_p));
        assert!(close(&split_regret_e, &long_regret_e));
        assert!(close(&split_sum_p, &long_sum_p));
        assert!(close(&split_sum_e, &long_sum_e));
        assert!(close(&split.player_policy, &long.player_policy));
        assert!(close(&split.enemy_policy, &long.enemy_policy));
    }
}
