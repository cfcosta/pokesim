"""Side-canonical transformer policy/value network."""

from __future__ import annotations

import copy
import os
import tempfile
from collections.abc import Sequence
from dataclasses import asdict, dataclass
from pathlib import Path
from typing import Any

import torch
from torch import Tensor, nn

from . import FEATURE_COUNT


@dataclass(frozen=True)
class TransformerConfig:
    feature_count: int = FEATURE_COUNT
    action_count: int = 4
    d_model: int = 128
    heads: int = 8
    layers: int = 4
    feedforward: int = 512
    precision: str = "bf16"


class BattleTransformer(nn.Module):
    """Encodes each scalar as low/high-byte tokens and predicts policy/value."""

    def __init__(self, config: TransformerConfig) -> None:
        super().__init__()
        if config.d_model % config.heads:
            raise ValueError("d_model must be divisible by attention heads")
        if config.precision not in {"bf16", "fp32"}:
            raise ValueError("precision must be bf16 or fp32")
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
        nn.init.zeros_(self.policy.weight)
        nn.init.zeros_(self.policy.bias)
        nn.init.zeros_(self.value[-2].weight)
        nn.init.zeros_(self.value[-2].bias)
        if config.action_count == 13:
            with torch.no_grad():
                self.policy.bias[4:10].fill_(-2.0)
                self.policy.bias[10].fill_(-2.0)
                self.policy.bias[12].fill_(-4.0)

    def _forward_impl(self, features: Tensor) -> tuple[Tensor, Tensor]:
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

    def forward(self, features: Tensor) -> tuple[Tensor, Tensor]:
        if features.ndim != 2 or features.shape[1] != self.config.feature_count:
            raise ValueError(f"expected [batch,{self.config.feature_count}] features")
        if self.config.precision == "fp32":
            return self._forward_impl(features)
        device_type = features.device.type
        if device_type == "cuda" and not torch.cuda.is_bf16_supported():
            raise RuntimeError("bf16 precision requires a bf16-capable CUDA device")
        if device_type not in {"cpu", "cuda"}:
            raise RuntimeError(f"bf16 precision is unsupported on {device_type}")
        with torch.autocast(device_type=device_type, dtype=torch.bfloat16):
            logits, values = self._forward_impl(features)
        # Keep policy normalization, losses, reductions, and search values in FP32.
        return logits.float(), values.float()

    @torch.inference_mode()
    def evaluate(
        self, features: Sequence[Sequence[int]], masks: Sequence[int]
    ) -> tuple[list[list[float]], list[float]]:
        device = next(self.parameters()).device
        tensor = torch.tensor(features, dtype=torch.long, device=device)
        logits, values = self(tensor)
        legal = torch.tensor(
            [
                [
                    bool(mask & (1 << action))
                    for action in range(self.config.action_count)
                ]
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


def load_checkpoint(path: Path, device: torch.device) -> dict[str, Any]:
    payload = torch.load(path, map_location=device, weights_only=False)
    if payload.get("format") != "battle-transformer-policy-value-v1":
        raise ValueError("unknown transformer checkpoint format")
    return payload


def save_network(
    path: Path,
    network: BattleTransformer,
    optimizer: torch.optim.Optimizer | None,
    metadata: dict[str, object],
) -> None:
    """Publish a checkpoint atomically without replacing an existing artifact."""
    path.parent.mkdir(parents=True, exist_ok=True)
    if path.exists():
        raise FileExistsError(path)
    payload = {
        "format": "battle-transformer-policy-value-v1",
        "config": asdict(network.config),
        "model": network.state_dict(),
        "optimizer": None if optimizer is None else optimizer.state_dict(),
        "metadata": metadata,
        "torch_rng": torch.random.get_rng_state(),
    }
    temporary_name: str | None = None
    try:
        with tempfile.NamedTemporaryFile(
            mode="w+b",
            prefix=f".{path.name}.",
            suffix=".tmp",
            dir=path.parent,
            delete=False,
        ) as temporary:
            temporary_name = temporary.name
            torch.save(payload, temporary)
            temporary.flush()
            os.fsync(temporary.fileno())
        try:
            os.link(temporary_name, path)
        except FileExistsError as error:
            raise FileExistsError(path) from error
    finally:
        if temporary_name is not None:
            Path(temporary_name).unlink(missing_ok=True)


def load_network(path: Path, device: torch.device) -> BattleTransformer:
    payload = load_checkpoint(path, device)
    raw_config = dict(payload["config"])
    # Checkpoints written before precision became explicit executed in strict FP32.
    raw_config.setdefault("precision", "fp32")
    network = BattleTransformer(TransformerConfig(**raw_config)).to(device)
    network.load_state_dict(payload["model"])
    network.eval()
    return network
