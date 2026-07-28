"""Side-canonical transformer policy/value network."""

from __future__ import annotations

import copy
import os
import tempfile
from collections.abc import Sequence
from dataclasses import asdict, dataclass
from pathlib import Path
from typing import Any

import numpy as np
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
    token_group_size: int = 1


class BattleTransformer(nn.Module):
    """Encodes each scalar as low/high-byte tokens and predicts policy/value."""

    def __init__(self, config: TransformerConfig) -> None:
        super().__init__()
        if config.d_model % config.heads:
            raise ValueError("d_model must be divisible by attention heads")
        if config.precision not in {"bf16", "fp32"}:
            raise ValueError("precision must be bf16 or fp32")
        if config.token_group_size not in {1, 2, 4, 8}:
            raise ValueError("token_group_size must be one of 1, 2, 4, or 8")
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
        masks = torch.arange(1 << config.action_count, dtype=torch.long).unsqueeze(1)
        actions = torch.arange(config.action_count, dtype=torch.long).unsqueeze(0)
        self.register_buffer(
            "_legal_mask_lookup",
            masks.bitwise_and(1 << actions).ne(0),
            persistent=False,
        )
        pooled_tokens = (
            config.feature_count + config.token_group_size - 1
        ) // config.token_group_size
        counts = torch.full(
            (pooled_tokens, 1), float(config.token_group_size), dtype=torch.float32
        )
        remainder = config.feature_count % config.token_group_size
        if remainder:
            counts[-1].fill_(float(remainder))
        self.register_buffer("_token_pool_counts", counts, persistent=False)
        self._pinned_feature_buffers: dict[int, Tensor] = {}
        self._pinned_mask_buffers: dict[int, Tensor] = {}
        self._inference_engine = "eager"
        self._compiled_forwards: dict[int, Any] = {}
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
        values = features.long().clamp(0, 65535)
        low = values.bitwise_and(255)
        high = values.bitwise_right_shift(8).bitwise_and(255)
        batch = values.shape[0]
        tokens = (
            self.low_byte(low)
            + self.high_byte(high)
            + self.position.weight[1:].unsqueeze(0)
        )
        group = self.config.token_group_size
        if group > 1:
            padding = (-tokens.shape[1]) % group
            if padding:
                tokens = torch.nn.functional.pad(tokens, (0, 0, 0, padding))
            tokens = tokens.reshape(batch, -1, group, tokens.shape[-1]).sum(dim=2)
            tokens = tokens / self._token_pool_counts.unsqueeze(0)
        cls = self.cls.expand(batch, -1, -1) + self.position.weight[:1].unsqueeze(0)
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

    @property
    def sequence_length(self) -> int:
        return (
            self.config.feature_count + self.config.token_group_size - 1
        ) // self.config.token_group_size + 1

    @property
    def inference_engine(self) -> str:
        return self._inference_engine

    def configure_inference(self, engine: str) -> None:
        if engine not in {"auto", "eager", "compiled"}:
            raise ValueError("inference engine must be auto, eager, or compiled")
        device = next(self.parameters()).device
        selected = "compiled" if engine == "auto" and device.type == "cuda" else engine
        if selected == "auto":
            selected = "eager"
        if selected == "compiled" and device.type != "cuda":
            raise ValueError("compiled inference requires CUDA")
        if selected == "compiled":
            driver = Path("/run/opengl-driver/lib")
            if "TRITON_LIBCUDA_PATH" not in os.environ and driver.is_dir():
                os.environ["TRITON_LIBCUDA_PATH"] = str(driver)
        if selected != self._inference_engine:
            self._compiled_forwards.clear()
            self._inference_engine = selected

    @staticmethod
    def _inference_bucket(batch: int) -> int:
        for bucket in (2, 4, 8, 16, 32, 64, 96, 128, 192, 256):
            if batch <= bucket:
                return bucket
        return batch

    def _compiled_forward(self, features: Tensor) -> tuple[Tensor, Tensor]:
        batch = features.shape[0]
        bucket = self._inference_bucket(batch)
        if bucket != batch:
            padded = torch.zeros(
                (bucket, features.shape[1]), dtype=features.dtype, device=features.device
            )
            padded[:batch].copy_(features)
        else:
            padded = features
        compiled = self._compiled_forwards.get(bucket)
        if compiled is None:
            compiled = torch.compile(
                self._forward_impl,
                mode="reduce-overhead",
                fullgraph=True,
                dynamic=False,
            )
            self._compiled_forwards[bucket] = compiled
        logits, values = compiled(padded)
        return logits[:batch], values[:batch]

    def _staged_tensor(
        self,
        values: np.ndarray,
        buffers: dict[int, Tensor],
        device: torch.device,
    ) -> Tensor:
        source = torch.from_numpy(values)
        if device.type != "cuda":
            return source.to(device)
        batch = len(values)
        staging = buffers.get(batch)
        if (
            staging is None
            or staging.shape != source.shape
            or staging.dtype != source.dtype
        ):
            staging = torch.empty(source.shape, dtype=source.dtype, pin_memory=True)
            buffers[batch] = staging
        staging.copy_(source)
        return staging.to(device, non_blocking=True)

    @torch.inference_mode()
    def evaluate(
        self, features: Sequence[Sequence[int]], masks: Sequence[int]
    ) -> tuple[list[list[float]], list[float]]:
        device = next(self.parameters()).device
        feature_array = np.stack(features)
        if feature_array.ndim != 2:
            raise ValueError("network evaluation requires a rectangular feature batch")
        tensor = self._staged_tensor(
            feature_array, self._pinned_feature_buffers, device
        ).long()
        if self._inference_engine == "compiled":
            device_type = tensor.device.type
            with torch.autocast(device_type=device_type, dtype=torch.bfloat16):
                logits, values = self._compiled_forward(tensor)
            logits, values = logits.float(), values.float()
        else:
            logits, values = self(tensor)
        mask_array = np.asarray(masks, dtype=np.uint16)
        mask_indexes = self._staged_tensor(
            mask_array, self._pinned_mask_buffers, device
        ).long()
        legal = self._legal_mask_lookup.index_select(0, mask_indexes)
        if (~legal.any(dim=1)).any():
            raise ValueError("network evaluation received an empty legal mask")
        logits = logits.masked_fill(~legal, torch.finfo(logits.dtype).min)
        probabilities = torch.softmax(logits, dim=-1)
        outputs = torch.cat((probabilities, values.unsqueeze(1)), dim=1).cpu().numpy()
        return outputs[:, :-1].tolist(), outputs[:, -1].tolist()

    def detached_copy(self, device: torch.device) -> BattleTransformer:
        clone = BattleTransformer(self.config).to(device)
        clone.load_state_dict(copy.deepcopy(self.state_dict()))
        clone.eval()
        clone.configure_inference(self._inference_engine)
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


def warm_start_network(
    path: Path, target_config: TransformerConfig, device: torch.device
) -> BattleTransformer:
    """Extend only the positional table while preserving every old parameter."""
    source = load_network(path, device)
    source_config = source.config
    comparable_source = asdict(source_config)
    comparable_target = asdict(target_config)
    source_features = comparable_source.pop("feature_count")
    target_features = comparable_target.pop("feature_count")
    # Precision changes execution, not stored parameter shape, and is governed by
    # the new run's explicit contract.
    comparable_source.pop("precision")
    comparable_target.pop("precision")
    if comparable_source != comparable_target:
        raise ValueError("warm-start checkpoint architecture is incompatible")
    if source_features >= target_features:
        raise ValueError("warm-start requires a smaller source observation schema")

    target = BattleTransformer(target_config).to(device)
    source_state = source.state_dict()
    target_state = target.state_dict()
    with torch.no_grad():
        for name, source_value in source_state.items():
            target_value = target_state[name]
            if name == "position.weight":
                if source_value.shape[1:] != target_value.shape[1:]:
                    raise ValueError("warm-start positional width is incompatible")
                target_value[: source_value.shape[0]].copy_(source_value)
            else:
                if source_value.shape != target_value.shape:
                    raise ValueError(f"warm-start parameter shape differs: {name}")
                target_value.copy_(source_value)
    target.load_state_dict(target_state)
    target.eval()
    return target
