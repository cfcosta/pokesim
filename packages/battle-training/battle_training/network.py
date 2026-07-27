"""Side-canonical transformer policy/value network."""

from __future__ import annotations

import copy
from collections.abc import Sequence
from dataclasses import asdict, dataclass
from pathlib import Path

import torch
from torch import Tensor, nn

from . import FEATURE_COUNT

ACTION_COUNT = 4


@dataclass(frozen=True)
class TransformerConfig:
    feature_count: int = FEATURE_COUNT
    action_count: int = ACTION_COUNT
    d_model: int = 128
    heads: int = 8
    layers: int = 4
    feedforward: int = 512


class BattleTransformer(nn.Module):
    """Encodes each scalar as low/high-byte tokens and predicts policy/value."""

    def __init__(self, config: TransformerConfig) -> None:
        super().__init__()
        if config.d_model % config.heads:
            raise ValueError("d_model must be divisible by attention heads")
        self.config = config
        self.low_byte = nn.Embedding(256, config.d_model)
        self.high_byte = nn.Embedding(256, config.d_model)
        self.position = nn.Embedding(config.feature_count + 1, config.d_model)
        self.cls = nn.Parameter(torch.zeros(1, 1, config.d_model))
        layer = nn.TransformerEncoderLayer(
            d_model=config.d_model,
            nhead=config.heads,
            dim_feedforward=config.feedforward,
            dropout=0.0,
            activation="gelu",
            batch_first=True,
            norm_first=True,
        )
        self.encoder = nn.TransformerEncoder(
            layer, config.layers, enable_nested_tensor=False
        )
        self.final_norm = nn.LayerNorm(config.d_model)
        self.policy = nn.Linear(config.d_model, config.action_count)
        self.value = nn.Sequential(
            nn.Linear(config.d_model, config.d_model),
            nn.GELU(),
            nn.Linear(config.d_model, 1),
            nn.Tanh(),
        )
        nn.init.normal_(self.cls, std=0.02)

    def forward(self, features: Tensor) -> tuple[Tensor, Tensor]:
        if features.ndim != 2 or features.shape[1] != self.config.feature_count:
            raise ValueError(f"expected [batch,{self.config.feature_count}] features")
        values = features.long().clamp_(0, 65535)
        low = values.bitwise_and(255)
        high = values.bitwise_right_shift(8).bitwise_and(255)
        batch = values.shape[0]
        positions = torch.arange(
            self.config.feature_count + 1, device=values.device, dtype=torch.long
        )
        tokens = (
            self.low_byte(low) + self.high_byte(high) + self.position(positions[1:])
        )
        cls = self.cls.expand(batch, -1, -1) + self.position(positions[:1])
        encoded = self.encoder(torch.cat((cls, tokens), dim=1))
        pooled = self.final_norm(encoded[:, 0])
        return self.policy(pooled), self.value(pooled).squeeze(-1)

    @torch.inference_mode()
    def evaluate(
        self, features: Sequence[Sequence[int]], masks: Sequence[int]
    ) -> tuple[list[list[float]], list[float]]:
        device = next(self.parameters()).device
        tensor = torch.tensor(features, dtype=torch.long, device=device)
        logits, values = self(tensor)
        legal = torch.tensor(
            [
                [bool(mask & (1 << action)) for action in range(ACTION_COUNT)]
                for mask in masks
            ],
            dtype=torch.bool,
            device=device,
        )
        if (~legal.any(dim=1)).any():
            raise ValueError("network evaluation received an empty legal mask")
        logits = logits.masked_fill(~legal, torch.finfo(logits.dtype).min)
        probabilities = torch.softmax(logits, dim=-1)
        return probabilities.cpu().tolist(), values.cpu().tolist()

    def detached_copy(self, device: torch.device) -> BattleTransformer:
        clone = BattleTransformer(self.config).to(device)
        clone.load_state_dict(copy.deepcopy(self.state_dict()))
        clone.eval()
        return clone


def choose_device(requested: str) -> torch.device:
    if requested == "auto":
        return torch.device("cuda" if torch.cuda.is_available() else "cpu")
    device = torch.device(requested)
    if device.type == "cuda" and not torch.cuda.is_available():
        raise RuntimeError("CUDA was requested but torch cannot access a GPU")
    return device


def configure_determinism(seed: int) -> None:
    torch.manual_seed(seed)
    if torch.cuda.is_available():
        torch.cuda.manual_seed_all(seed)
    torch.use_deterministic_algorithms(True)


def save_network(
    path: Path,
    network: BattleTransformer,
    optimizer: torch.optim.Optimizer | None,
    metadata: dict[str, object],
) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    if path.exists():
        raise FileExistsError(path)
    torch.save(
        {
            "format": "battle-transformer-policy-value-v1",
            "config": asdict(network.config),
            "model": network.state_dict(),
            "optimizer": None if optimizer is None else optimizer.state_dict(),
            "metadata": metadata,
            "torch_rng": torch.random.get_rng_state(),
        },
        path,
    )


def load_network(path: Path, device: torch.device) -> BattleTransformer:
    payload = torch.load(path, map_location=device, weights_only=False)
    if payload.get("format") != "battle-transformer-policy-value-v1":
        raise ValueError("unknown transformer checkpoint format")
    network = BattleTransformer(TransformerConfig(**payload["config"])).to(device)
    network.load_state_dict(payload["model"])
    network.eval()
    return network
