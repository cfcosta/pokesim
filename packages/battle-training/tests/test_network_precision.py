from __future__ import annotations

import sys
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

import torch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from battle_training.network import BattleTransformer, TransformerConfig


class NetworkPrecisionContractTest(unittest.TestCase):
    def model(self, precision: str) -> BattleTransformer:
        torch.manual_seed(57)
        network = BattleTransformer(
            TransformerConfig(
                feature_count=4,
                action_count=3,
                d_model=8,
                heads=2,
                layers=1,
                feedforward=16,
                precision=precision,
                joint_policy_heads=True,
                distilled_leaf_evaluator=True,
                distilled_leaf_policy=True,
                leaf_hidden=8,
            )
        ).eval()
        # Exercise nontrivial policies and values rather than zero-initialized
        # heads, whose outputs can conceal a change in arithmetic precision.
        with torch.no_grad():
            for module in network.modules():
                if isinstance(module, torch.nn.Linear):
                    module.weight.normal_(std=0.1)
                    if module.bias is not None:
                        module.bias.normal_(std=0.1)
        return network

    def test_bf16_training_keeps_losses_gradients_and_optimizer_moments_fp32(
        self,
    ) -> None:
        network = self.model("bf16").train()
        optimizer = torch.optim.AdamW(network.parameters(), lr=1e-3)
        logits, opponent, values = network.forward_joint(
            torch.ones((2, 4), dtype=torch.long)
        )
        self.assertEqual(
            (logits.dtype, opponent.dtype, values.dtype), (torch.float32,) * 3
        )
        loss = (
            torch.nn.functional.cross_entropy(logits, torch.tensor([0, 1]))
            + torch.nn.functional.cross_entropy(opponent, torch.tensor([1, 2]))
            + torch.nn.functional.mse_loss(values, torch.tensor([1.0, -1.0]))
        )
        self.assertEqual(loss.dtype, torch.float32)
        loss.backward()
        gradients = [
            parameter.grad
            for parameter in network.parameters()
            if parameter.grad is not None
        ]
        self.assertTrue(gradients)
        self.assertEqual({gradient.dtype for gradient in gradients}, {torch.float32})
        optimizer.step()
        self.assertTrue(optimizer.state)
        for parameter, state in optimizer.state.items():
            self.assertEqual(parameter.dtype, torch.float32)
            self.assertEqual(state["exp_avg"].dtype, torch.float32)
            self.assertEqual(state["exp_avg_sq"].dtype, torch.float32)

    def test_all_compiled_entrypoints_preserve_requested_arithmetic_and_eager_outputs(
        self,
    ) -> None:
        features = torch.tensor([[0, 12, 38, 250], [2, 0, 1000, 10]])
        masks = torch.tensor([3, 5])
        for precision in ("fp32", "bf16"):
            network = self.model(precision)
            expected_dtype = torch.float32 if precision == "fp32" else torch.bfloat16
            observed = []
            handles = [
                module.register_forward_hook(
                    lambda module, inputs, output, observed=observed: observed.append(
                        output.dtype
                    )
                )
                for module in network.modules()
                if isinstance(module, torch.nn.Linear)
            ]
            for method, args in (
                ("_evaluation_outputs", (features, masks)),
                ("_joint_evaluation_outputs", (features, masks, masks)),
                ("_leaf_evaluation_outputs", (features,)),
                ("_leaf_joint_evaluation_outputs", (features, masks, masks)),
            ):
                with self.subTest(precision=precision, method=method):
                    network._inference_engine = "eager"
                    observed.clear()
                    eager = getattr(network, method)(*args)
                    self.assertTrue(observed)
                    self.assertEqual(set(observed), {expected_dtype})
                    network._inference_engine = "compiled"
                    observed.clear()
                    # Identity compilation keeps real network arithmetic while
                    # isolating the precision wrapper from compiler/hardware.
                    with patch(
                        "torch.compile", side_effect=lambda function, **kwargs: function
                    ):
                        actual = getattr(network, method)(*args)
                    self.assertTrue(observed)
                    self.assertEqual(set(observed), {expected_dtype})
                    self.assertEqual(actual.dtype, torch.float32)
                    torch.testing.assert_close(actual, eager, rtol=0, atol=0)
            for handle in handles:
                handle.remove()

    def test_fp32_contract_disables_surrounding_autocast(self) -> None:
        network = self.model("fp32")
        features = torch.ones((2, 4), dtype=torch.long)
        for engine in ("eager", "compiled"):
            network._inference_engine = engine
            with (
                self.subTest(engine=engine),
                patch("torch.compile", side_effect=lambda function, **kwargs: function),
            ):
                expected = network._leaf_evaluation_outputs(features)
                observed = []
                handle = network.leaf_trunk[0].register_forward_hook(
                    lambda module, inputs, output, observed=observed: observed.append(
                        output.dtype
                    )
                )
                with torch.autocast("cpu", dtype=torch.bfloat16):
                    actual = network._leaf_evaluation_outputs(features)
                handle.remove()
                self.assertEqual(observed, [torch.float32])
                torch.testing.assert_close(actual, expected, rtol=0, atol=0)

    def test_compiled_bf16_checks_cuda_capability_before_evaluation(self) -> None:
        network = self.model("bf16")
        network._inference_engine = "compiled"
        features = SimpleNamespace(ndim=2, shape=(2, 4), device=torch.device("cuda"))
        masks = torch.tensor([3, 5])
        for method, args in (
            ("_evaluation_outputs", (features, masks)),
            ("_joint_evaluation_outputs", (features, masks, masks)),
            ("_leaf_evaluation_outputs", (features,)),
            ("_leaf_joint_evaluation_outputs", (features, masks, masks)),
        ):
            with (
                self.subTest(method=method),
                patch("torch.cuda.is_bf16_supported", return_value=False),
                self.assertRaisesRegex(RuntimeError, "bf16-capable"),
            ):
                getattr(network, method)(*args)


if __name__ == "__main__":
    unittest.main()
