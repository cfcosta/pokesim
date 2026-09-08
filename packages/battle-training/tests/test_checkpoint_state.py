from __future__ import annotations

import sys
import tempfile
import unittest
from pathlib import Path

import torch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from battle_training.network import (
    BattleTransformer,
    TransformerConfig,
    load_network,
    save_network,
)


class CheckpointStateTest(unittest.TestCase):
    def test_explicit_state_loads_the_requested_model_even_when_promotion_failed(self):
        deployed = BattleTransformer(
            TransformerConfig(
                feature_count=8,
                action_count=2,
                d_model=8,
                heads=2,
                layers=1,
                feedforward=16,
                precision="fp32",
            )
        ).eval()
        learner = deployed.detached_copy(torch.device("cpu"))
        with torch.no_grad():
            learner.policy.bias.add_(torch.tensor([2.0, -2.0]))
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "rejected-iteration.pt"
            save_network(
                path,
                deployed,
                None,
                {"promotion": {"accepted": False}},
                {"learner_model": learner.state_dict()},
            )
            for state, expected in (("deployed", deployed), ("learner", learner)):
                with self.subTest(state=state):
                    loaded = load_network(path, torch.device("cpu"), state=state)
                    self.assertFalse(loaded.training)
                    for name, value in expected.state_dict().items():
                        self.assertTrue(
                            torch.equal(loaded.state_dict()[name], value), name
                        )
            default = load_network(path, torch.device("cpu"))
            self.assertTrue(torch.equal(default.policy.bias, deployed.policy.bias))
            self.assertFalse(torch.equal(default.policy.bias, learner.policy.bias))

    def test_missing_requested_learner_state_never_silently_loads_deployed(self):
        network = BattleTransformer(
            TransformerConfig(
                feature_count=8,
                action_count=2,
                d_model=8,
                heads=2,
                layers=1,
                feedforward=16,
                precision="fp32",
            )
        )
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "legacy.pt"
            save_network(path, network, None, {})
            with self.assertRaisesRegex(ValueError, "requested learner state"):
                load_network(path, torch.device("cpu"), state="learner")

    def test_unknown_state_is_rejected_before_opening_any_checkpoint(self):
        with self.assertRaisesRegex(ValueError, "deployed or learner"):
            load_network(
                Path("/does-not-exist.pt"), torch.device("cpu"), state="latest"
            )


if __name__ == "__main__":
    unittest.main()
