from __future__ import annotations

import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import torch

from battle_training.network import (
    BattleTransformer,
    TransformerConfig,
    leaf_layer_sizes,
    save_network,
    warm_start_network,
)

_CPU = torch.device("cpu")


def _leaf_config(**overrides: object) -> TransformerConfig:
    settings: dict[str, object] = {
        "feature_count": 492,
        "action_count": 2,
        "d_model": 8,
        "heads": 2,
        "layers": 1,
        "feedforward": 16,
        "distilled_leaf_evaluator": True,
    }
    settings.update(overrides)
    return TransformerConfig(**settings)


class LeafEvaluatorArchitectureTest(unittest.TestCase):
    def test_default_leaf_layout_matches_legacy_state_dict(self) -> None:
        network = BattleTransformer(_leaf_config())
        state = network.state_dict()
        self.assertEqual(state["leaf_value.0.weight"].shape, (64, 492))
        self.assertEqual(state["leaf_value.2.weight"].shape, (64, 64))
        self.assertEqual(state["leaf_value.4.weight"].shape, (1, 64))
        leaf_keys = sorted(key for key in state if key.startswith("leaf_value."))
        self.assertEqual(
            leaf_keys,
            [
                "leaf_value.0.bias",
                "leaf_value.0.weight",
                "leaf_value.2.bias",
                "leaf_value.2.weight",
                "leaf_value.4.bias",
                "leaf_value.4.weight",
            ],
        )
        self.assertEqual(leaf_layer_sizes(network.config), (64, 64))

    def test_leaf_hidden_layers_widen_and_deepen_the_head(self) -> None:
        network = BattleTransformer(_leaf_config(leaf_hidden_layers=(256, 128)))
        state = network.state_dict()
        self.assertEqual(state["leaf_value.0.weight"].shape, (256, 492))
        self.assertEqual(state["leaf_value.2.weight"].shape, (128, 256))
        self.assertEqual(state["leaf_value.4.weight"].shape, (1, 128))
        leaf_parameters = sum(
            value.numel()
            for key, value in state.items()
            if key.startswith("leaf_value.")
        )
        self.assertEqual(leaf_parameters, 159_233)
        features = torch.zeros((3, 492), dtype=torch.long)
        torch.testing.assert_close(
            network.leaf_forward(features), torch.zeros(3), rtol=0.0, atol=0.0
        )

    def test_single_hidden_layer_produces_a_shallower_head(self) -> None:
        network = BattleTransformer(_leaf_config(leaf_hidden_layers=(96,)))
        state = network.state_dict()
        self.assertEqual(state["leaf_value.0.weight"].shape, (96, 492))
        self.assertEqual(state["leaf_value.2.weight"].shape, (1, 96))
        self.assertNotIn("leaf_value.4.weight", state)

    def test_leaf_hidden_layers_accept_json_lists(self) -> None:
        from_list = _leaf_config(leaf_hidden_layers=[256, 128])
        self.assertEqual(from_list.leaf_hidden_layers, (256, 128))
        self.assertEqual(from_list, _leaf_config(leaf_hidden_layers=(256, 128)))

    def test_leaf_hidden_layers_reject_empty_and_nonpositive_sizes(self) -> None:
        for invalid in ((), (0,), (256, -1)):
            with self.assertRaisesRegex(ValueError, "leaf_hidden_layers"):
                BattleTransformer(_leaf_config(leaf_hidden_layers=invalid))

    def test_warm_start_copies_equivalent_leaf_layouts(self) -> None:
        source = BattleTransformer(_leaf_config())
        with torch.no_grad():
            source.leaf_value[-2].weight.fill_(0.25)
        with tempfile.TemporaryDirectory() as temporary:
            checkpoint = Path(temporary) / "source.pt"
            save_network(checkpoint, source, None, {})
            target = warm_start_network(
                checkpoint, _leaf_config(leaf_hidden_layers=(64, 64)), _CPU
            )
        torch.testing.assert_close(
            target.leaf_value[-2].weight, source.leaf_value[-2].weight
        )
        torch.testing.assert_close(target.policy.weight, source.policy.weight)

    def test_warm_start_reinitializes_a_changed_leaf_head(self) -> None:
        source = BattleTransformer(_leaf_config())
        with torch.no_grad():
            source.leaf_value[-2].weight.fill_(0.25)
            source.policy.bias.fill_(0.5)
        with tempfile.TemporaryDirectory() as temporary:
            checkpoint = Path(temporary) / "source.pt"
            save_network(checkpoint, source, None, {})
            target = warm_start_network(
                checkpoint, _leaf_config(leaf_hidden_layers=(256, 128)), _CPU
            )
        state = target.state_dict()
        self.assertEqual(state["leaf_value.0.weight"].shape, (256, 492))
        torch.testing.assert_close(
            state["leaf_value.4.weight"], torch.zeros((1, 128)), rtol=0.0, atol=0.0
        )
        torch.testing.assert_close(target.policy.bias, source.policy.bias)

    def test_warm_start_still_rejects_trunk_mismatch(self) -> None:
        source = BattleTransformer(_leaf_config())
        with tempfile.TemporaryDirectory() as temporary:
            checkpoint = Path(temporary) / "source.pt"
            save_network(checkpoint, source, None, {})
            with self.assertRaisesRegex(ValueError, "incompatible"):
                warm_start_network(
                    checkpoint,
                    _leaf_config(d_model=16, leaf_hidden_layers=(256, 128)),
                    _CPU,
                )


if __name__ == "__main__":
    unittest.main()
