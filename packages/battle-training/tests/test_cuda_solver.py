from __future__ import annotations

import os
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from battle_training.cuda_runtime import configure_triton_runtime
from battle_training.rmplus_native import native_available
from battle_training.solver_cuda import cuda_solver_available, solve_anchored_batch


class CudaRuntimeDiscoveryTest(unittest.TestCase):
    def test_discovers_existing_tools_and_preserves_explicit_paths(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "bin").mkdir()
            (root / "bin" / "ptxas").touch()
            with (
                patch.dict(
                    os.environ,
                    {"CUDA_HOME": directory, "TRITON_LIBCUDA_PATH": "/explicit/driver"},
                    clear=True,
                ),
                patch("battle_training.cuda_runtime._NIX_DRIVER_DIRECTORY", root),
            ):
                configure_triton_runtime()
                self.assertEqual(os.environ["TRITON_LIBCUDA_PATH"], "/explicit/driver")
                self.assertEqual(
                    os.environ["TRITON_PTXAS_PATH"], str(root / "bin" / "ptxas")
                )
                self.assertNotIn("TRITON_CUOBJDUMP_PATH", os.environ)
                del os.environ["TRITON_LIBCUDA_PATH"]
                configure_triton_runtime()
                self.assertEqual(os.environ["TRITON_LIBCUDA_PATH"], directory)


def cases(batch: int = 16, actions: int = 13) -> tuple[np.ndarray, ...]:
    rng = np.random.default_rng(731)
    matrix = rng.uniform(-1, 1, (batch, actions, actions))
    player = rng.random((batch, actions))
    enemy = rng.random((batch, actions))
    player_mask = rng.random((batch, actions)) > 0.3
    enemy_mask = rng.random((batch, actions)) > 0.3
    player_mask[:, 0] = True
    enemy_mask[:, -1] = True
    player[0] = 0
    enemy[0] = 0
    matrix[0] = 0
    if batch > 1:
        player[1, 0] = 0
        matrix[1, 0] = 1
        matrix[1, 1:] = -1
    return matrix, player, enemy, player_mask, enemy_mask


class BatchSolverValidationTest(unittest.TestCase):
    def test_rejects_empty_masks_before_dispatch(self) -> None:
        args = list(cases())
        args[3][0] = False
        with self.assertRaisesRegex(ValueError, "legal action"):
            solve_anchored_batch(*args, iterations=32, temperature=0.02)

    def test_rejects_invalid_inputs_before_dispatch(self) -> None:
        for field, value in ((0, float("nan")), (1, -1.0)):
            args = list(cases())
            args[field].flat[0] = value
            with self.assertRaises(ValueError):
                solve_anchored_batch(*args, iterations=32, temperature=0.02)
        for temperature in (0, -1, float("nan"), float("inf")):
            with self.assertRaisesRegex(ValueError, "temperature"):
                solve_anchored_batch(*cases(), iterations=32, temperature=temperature)

    def test_cuda_request_reports_missing_runtime(self) -> None:
        with (
            patch(
                "battle_training.solver_cuda.cuda_solver_available", return_value=False
            ),
            self.assertRaisesRegex(RuntimeError, "unavailable"),
        ):
            solve_anchored_batch(
                *cases(), iterations=32, temperature=0.02, backend="cuda"
            )


@unittest.skipUnless(native_available(), "native RM+ library unavailable")
class BatchSolverNativeTest(unittest.TestCase):
    def test_auto_falls_back_when_cuda_is_unavailable(self) -> None:
        args = cases()
        with patch(
            "battle_training.solver_cuda.cuda_solver_available", return_value=False
        ):
            result = solve_anchored_batch(*args, iterations=32, temperature=0.02)
        self.assertEqual(result.backend, "rust-anchored-f64-v1")
        self.assertIsNotNone(result.fallback_reason)
        np.testing.assert_allclose(result.player_policy.sum(axis=1), 1, atol=1e-12)


@unittest.skipUnless(
    cuda_solver_available() and native_available(), "CUDA and native RM+ required"
)
class CudaSolverDifferentialTest(unittest.TestCase):
    def test_single_opponent_action_matches_analytic_regularized_best_response(
        self,
    ) -> None:
        matrix = np.array([[[0.3, 0.1], [-0.2, 0.9]]])
        prior = np.array([[0.2, 0.8]])
        player_mask = np.array([[True, True]])
        enemy_mask = np.array([[True, False]])
        actual = solve_anchored_batch(
            matrix, prior, prior, player_mask, enemy_mask, 2048, 0.5, backend="cuda"
        )
        logits = np.log(prior[0]) + matrix[0, :, 0] / 0.5
        expected = np.exp(logits - logits.max())
        expected /= expected.sum()
        np.testing.assert_allclose(actual.player_policy[0], expected, atol=2e-6, rtol=0)
        np.testing.assert_array_equal(actual.enemy_policy[0], [1, 0])
        self.assertAlmostEqual(
            float(actual.value[0]), float(expected @ matrix[0, :, 0]), places=6
        )

    def assert_matches_native(
        self, args: tuple[np.ndarray, ...], iterations: int, temperature: float
    ) -> None:
        reference = solve_anchored_batch(
            *args, iterations=iterations, temperature=temperature, backend="rust"
        )
        actual = solve_anchored_batch(
            *args,
            iterations=iterations,
            temperature=temperature,
            backend="cuda",
            precision="fp64",
        )
        self.assertEqual(actual.backend, "triton-anchored-f64-v1")
        for field in ("player_policy", "enemy_policy", "value", "exploitability"):
            np.testing.assert_allclose(
                getattr(actual, field),
                getattr(reference, field),
                atol=2e-10,
                rtol=2e-10,
            )
        self.assertTrue(np.isfinite(actual.player_policy).all())
        np.testing.assert_array_equal(actual.player_policy[~args[3]], 0)
        np.testing.assert_array_equal(actual.enemy_policy[~args[4]], 0)
        np.testing.assert_allclose(actual.player_policy.sum(axis=1), 1, atol=1e-12)
        np.testing.assert_allclose(actual.enemy_policy.sum(axis=1), 1, atol=1e-12)

    def test_masks_zero_priors_and_dominant_zero_prior_action(self) -> None:
        self.assert_matches_native(cases(), 2048, 0.02)
        actual = solve_anchored_batch(*cases(), 2048, 0.02, backend="cuda")
        self.assertGreater(actual.player_policy[1, 0], 0.999)

    def test_small_shapes_wide_payoffs_and_temperature_extremes(self) -> None:
        for actions, temperature in ((1, 0.02), (2, 0.005), (7, 0.5), (13, 1e-5)):
            with self.subTest(actions=actions, temperature=temperature):
                args = cases(3, actions)
                args[0][:] *= 4
                self.assert_matches_native(args, 64, temperature)

    def test_matching_pennies(self) -> None:
        matrix = np.array([[[1.0, -1.0], [-1.0, 1.0]]])
        prior = np.array([[0.9, 0.1]])
        mask = np.ones((1, 2), dtype=bool)
        self.assert_matches_native((matrix, prior, prior, mask, mask), 2048, 0.02)

    def test_f32_matches_native_over_masks_and_temperature_range(self) -> None:
        for temperature, iterations in ((0.005, 8192), (0.02, 2048), (1.0, 128)):
            with self.subTest(temperature=temperature):
                args = cases(128)
                args[1][2] *= 1e100
                reference = solve_anchored_batch(
                    *args,
                    iterations=iterations,
                    temperature=temperature,
                    backend="rust",
                )
                actual = solve_anchored_batch(
                    *args,
                    iterations=iterations,
                    temperature=temperature,
                    backend="cuda",
                    precision="fp32",
                )
                self.assertEqual(actual.backend, "triton-anchored-f32-v1")
                for field in (
                    "player_policy",
                    "enemy_policy",
                    "value",
                    "exploitability",
                ):
                    np.testing.assert_allclose(
                        getattr(actual, field),
                        getattr(reference, field),
                        atol=2e-5,
                        rtol=2e-5,
                    )
                np.testing.assert_array_equal(actual.player_policy[~args[3]], 0)
                np.testing.assert_array_equal(actual.enemy_policy[~args[4]], 0)

    def test_f32_unsupported_inputs_are_explicit(self) -> None:
        args = cases()
        with self.assertRaisesRegex(RuntimeError, "f32 CUDA requires"):
            solve_anchored_batch(
                *args, iterations=32, temperature=1e-5, backend="cuda", precision="fp32"
            )
        actual = solve_anchored_batch(
            *args, iterations=32, temperature=1e-5, precision="fp32"
        )
        self.assertEqual(actual.backend, "rust-anchored-f64-v1")
        self.assertIn("f32 CUDA requires", actual.fallback_reason)


if __name__ == "__main__":
    unittest.main()
