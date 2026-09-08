"""Side-canonical transformer policy/value network."""

from __future__ import annotations

import copy
import os
import tempfile
from collections.abc import Callable, Sequence
from dataclasses import asdict, dataclass
from pathlib import Path
from typing import Any, Protocol

import numpy as np
import torch
from torch import Tensor, nn

from . import FEATURE_COUNT
from .cuda_runtime import configure_triton_runtime

_INFERENCE_BUCKETS = (2, 4, 8, 16, 32, 64, 96, 128, 192, 256)
_COMPILED_RECOMPILE_LIMIT = 32
_SEMANTIC_FEATURE_COUNT = 492
_SEMANTIC_TOKEN_COUNT = 31


class EvaluationTicket(Protocol):
    """One launched inference whose host result may be collected later."""

    def result(self) -> tuple[list[list[float]], list[float]]: ...


class JointEvaluationTicket(Protocol):
    def result(
        self,
    ) -> tuple[list[list[float]], list[list[float]], list[float]]: ...


class ValueEvaluationTicket(Protocol):
    def result(self) -> list[float]: ...


@dataclass
class _ImmediateEvaluation:
    output: tuple[list[list[float]], list[float]]

    def result(self) -> tuple[list[list[float]], list[float]]:
        return self.output


@dataclass
class _CudaEvaluation:
    output: Tensor
    ready: torch.cuda.Event
    keepalive: tuple[Tensor, ...]

    def result(self) -> tuple[list[list[float]], list[float]]:
        self.ready.synchronize()
        values = self.output.numpy()
        return values[:, :-1].tolist(), values[:, -1].tolist()


@dataclass
class _ImmediateJointEvaluation:
    output: tuple[list[list[float]], list[list[float]], list[float]]

    def result(self) -> tuple[list[list[float]], list[list[float]], list[float]]:
        return self.output


@dataclass
class _CudaJointEvaluation:
    output: Tensor
    ready: torch.cuda.Event
    action_count: int
    keepalive: tuple[Tensor, ...]

    def result(self) -> tuple[list[list[float]], list[list[float]], list[float]]:
        self.ready.synchronize()
        values = self.output.numpy()
        split = self.action_count
        return (
            values[:, :split].tolist(),
            values[:, split : 2 * split].tolist(),
            values[:, -1].tolist(),
        )


@dataclass
class _ImmediateValueEvaluation:
    output: list[float]

    def result(self) -> list[float]:
        return self.output


@dataclass
class _CudaValueEvaluation:
    output: Tensor
    ready: torch.cuda.Event
    keepalive: tuple[Tensor, ...]

    def result(self) -> list[float]:
        self.ready.synchronize()
        return self.output.numpy().tolist()


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
    token_layout: str = "scalar-v1"
    joint_policy_heads: bool = False
    distilled_leaf_evaluator: bool = False
    distilled_leaf_policy: bool = False
    leaf_hidden: int = 64
    leaf_hidden_layers: tuple[int, ...] | None = None

    def __post_init__(self) -> None:
        # JSON round-trips deliver lists; normalize so config equality between a
        # freshly built model and a loaded checkpoint stays exact.
        if self.leaf_hidden_layers is not None:
            object.__setattr__(
                self,
                "leaf_hidden_layers",
                tuple(int(size) for size in self.leaf_hidden_layers),
            )


def leaf_layer_sizes(config: TransformerConfig) -> tuple[int, ...]:
    """Resolve the hidden-layer widths of the distilled leaf evaluator."""
    if config.leaf_hidden_layers is not None:
        return config.leaf_hidden_layers
    return (config.leaf_hidden, config.leaf_hidden)


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
        if config.leaf_hidden < 1:
            raise ValueError("leaf_hidden must be positive")
        if config.leaf_hidden_layers is not None and (
            not config.leaf_hidden_layers
            or any(size < 1 for size in config.leaf_hidden_layers)
        ):
            raise ValueError("leaf_hidden_layers must list positive hidden sizes")
        if config.distilled_leaf_policy and not config.distilled_leaf_evaluator:
            raise ValueError("the distilled policy shares the leaf evaluator's trunk")
        if config.distilled_leaf_policy and not config.joint_policy_heads:
            raise ValueError("the distilled policy distills both joint policy heads")
        if config.token_layout not in {"scalar-v1", "semantic-entity-v1"}:
            raise ValueError("token_layout must be scalar-v1 or semantic-entity-v1")
        if (
            config.token_layout == "semantic-entity-v1"
            and config.feature_count != _SEMANTIC_FEATURE_COUNT
        ):
            raise ValueError("semantic entity tokens require the 492-field v4 schema")
        if config.token_layout == "semantic-entity-v1" and config.token_group_size != 1:
            raise ValueError("semantic entity tokens do not use scalar token grouping")
        self.config = config
        if config.token_layout == "scalar-v1":
            self.low_byte = nn.Embedding(256, config.d_model)
            self.high_byte = nn.Embedding(256, config.d_model)
            self.position = nn.Embedding(config.feature_count + 1, config.d_model)
        else:
            self.entity_position = nn.Embedding(
                _SEMANTIC_TOKEN_COUNT + 1, config.d_model
            )
            self.mon_projection = nn.Linear(22, config.d_model)
            self.active_projection = nn.Linear(48, config.d_model)
            self.move_projection = nn.Linear(6, config.d_model)
            self.switch_projection = nn.Linear(2, config.d_model)
            self.selection_projection = nn.Linear(8, config.d_model)
            self.global_projection = nn.Linear(56, config.d_model)
            self.species_embedding = nn.Embedding(256, config.d_model)
            self.move_embedding = nn.Embedding(256, config.d_model)
            self.register_buffer(
                "_semantic_global_indexes",
                torch.tensor([132, 313, *range(438, 492)], dtype=torch.long),
                persistent=False,
            )
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
        if config.joint_policy_heads:
            self.opponent_policy = nn.Linear(config.d_model, config.action_count)
        self.value = nn.Sequential(
            nn.Linear(config.d_model, config.d_model),
            nn.GELU(),
            nn.Linear(config.d_model, 1),
            nn.Tanh(),
        )
        if config.distilled_leaf_evaluator:
            leaf_layers: list[nn.Module] = []
            leaf_width = config.feature_count
            for hidden in leaf_layer_sizes(config):
                leaf_layers.append(nn.Linear(leaf_width, hidden))
                leaf_layers.append(nn.GELU())
                leaf_width = hidden
            # Trunk and heads are separate so the distilled policy can hang off
            # the representation the distilled value already paid for.
            self.leaf_trunk = nn.Sequential(*leaf_layers)
            self.leaf_value = nn.Sequential(nn.Linear(leaf_width, 1), nn.Tanh())
            if config.distilled_leaf_policy:
                self.leaf_policy = nn.Linear(leaf_width, 2 * config.action_count)
        masks = torch.arange(1 << config.action_count, dtype=torch.long).unsqueeze(1)
        actions = torch.arange(config.action_count, dtype=torch.long).unsqueeze(0)
        self.register_buffer(
            "_legal_mask_lookup",
            masks.bitwise_and(1 << actions).ne(0),
            persistent=False,
        )
        if config.token_layout == "scalar-v1":
            pooled_tokens = (
                config.feature_count + config.token_group_size - 1
            ) // config.token_group_size
            counts = torch.full(
                (pooled_tokens, 1),
                float(config.token_group_size),
                dtype=torch.float32,
            )
            remainder = config.feature_count % config.token_group_size
            if remainder:
                counts[-1].fill_(float(remainder))
            self.register_buffer("_token_pool_counts", counts, persistent=False)
        self._pinned_feature_buffers: dict[int, Tensor] = {}
        self._pinned_mask_buffers: dict[int, Tensor] = {}
        self._inference_engine = "eager"
        self._compiled_forwards: dict[int, Any] = {}
        self._compiled_joint_forwards: dict[int, Any] = {}
        self._compiled_leaf_forwards: dict[int, Any] = {}
        self._compiled_leaf_joint_forwards: dict[int, Any] = {}
        self._inference_stream: torch.cuda.Stream | None = None
        nn.init.normal_(self.cls, std=0.02)
        self._initialize_policy(self.policy)
        if config.joint_policy_heads:
            self._initialize_policy(self.opponent_policy)
        nn.init.zeros_(self.value[-2].weight)
        nn.init.zeros_(self.value[-2].bias)
        if config.distilled_leaf_evaluator:
            nn.init.zeros_(self.leaf_value[0].weight)
            nn.init.zeros_(self.leaf_value[0].bias)
            if config.distilled_leaf_policy:
                self._initialize_policy(self.leaf_policy, sides=2)

    def _initialize_policy(self, head: nn.Linear, sides: int = 1) -> None:
        nn.init.zeros_(head.weight)
        nn.init.zeros_(head.bias)
        if self.config.action_count == 13:
            with torch.no_grad():
                for side in range(sides):
                    bias = head.bias[side * 13 : (side + 1) * 13]
                    bias[4:10].fill_(-2.0)
                    bias[10].fill_(-2.0)
                    bias[12].fill_(-4.0)

    def _scalar_tokens(self, values: Tensor) -> tuple[Tensor, Tensor]:
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
        return cls, tokens

    def _semantic_tokens(self, values: Tensor) -> tuple[Tensor, Tensor]:
        batch = values.shape[0]
        normalized = torch.log1p(values.float()) / 11.090354888959125
        party_values = torch.stack(
            [
                normalized[:, base : base + 22]
                for side in (0, 181)
                for base in range(side, side + 132, 22)
            ],
            dim=1,
        )
        active_values = torch.stack(
            (normalized[:, 133:181], normalized[:, 314:362]), dim=1
        )
        move_values = normalized[:, 362:410].reshape(batch, 8, 6)
        switch_values = normalized[:, 410:422].reshape(batch, 6, 2)
        selection_values = normalized[:, 422:438].reshape(batch, 2, 8)
        global_values = normalized.index_select(1, self._semantic_global_indexes)

        party_species = torch.stack(
            [values[:, side + slot * 22] for side in (0, 181) for slot in range(6)],
            dim=1,
        ).clamp(0, 255)
        party_moves = torch.stack(
            [
                values[:, side + slot * 22 + 7 : side + slot * 22 + 11]
                for side in (0, 181)
                for slot in range(6)
            ],
            dim=1,
        ).clamp(0, 255)
        active_species = values[:, (133, 314)].clamp(0, 255)
        active_moves = torch.stack(
            (values[:, 140:144], values[:, 321:325]), dim=1
        ).clamp(0, 255)
        descriptor_moves = active_moves.reshape(batch, 8)

        party_tokens = (
            self.mon_projection(party_values)
            + self.species_embedding(party_species)
            + self.move_embedding(party_moves).mean(dim=2)
        )
        active_tokens = (
            self.active_projection(active_values)
            + self.species_embedding(active_species)
            + self.move_embedding(active_moves).mean(dim=2)
        )
        tokens = torch.cat(
            (
                party_tokens,
                active_tokens,
                self.move_projection(move_values)
                + self.move_embedding(descriptor_moves),
                self.switch_projection(switch_values),
                self.selection_projection(selection_values),
                self.global_projection(global_values).unsqueeze(1),
            ),
            dim=1,
        )
        tokens = tokens + self.entity_position.weight[1:].unsqueeze(0)
        cls = self.cls.expand(batch, -1, -1) + self.entity_position.weight[
            :1
        ].unsqueeze(0)
        return cls, tokens

    def _encode_impl(self, features: Tensor) -> Tensor:
        values = features.long().clamp(0, 65535)
        if self.config.token_layout == "semantic-entity-v1":
            cls, tokens = self._semantic_tokens(values)
        else:
            cls, tokens = self._scalar_tokens(values)
        encoded = self.encoder(torch.cat((cls, tokens), dim=1))
        return self.final_norm(encoded[:, 0])

    def _forward_impl(self, features: Tensor) -> tuple[Tensor, Tensor]:
        pooled = self._encode_impl(features)
        return self.policy(pooled), self.value(pooled).squeeze(-1)

    def _forward_joint_impl(self, features: Tensor) -> tuple[Tensor, Tensor, Tensor]:
        if not self.config.joint_policy_heads:
            raise RuntimeError("joint evaluation requires joint policy heads")
        pooled = self._encode_impl(features)
        return (
            self.policy(pooled),
            self.opponent_policy(pooled),
            self.value(pooled).squeeze(-1),
        )

    def forward(self, features: Tensor) -> tuple[Tensor, Tensor]:
        with self._precision_context(features):
            logits, values = self._forward_impl(features)
        # Keep policy normalization, losses, reductions, and search values in FP32.
        return logits.float(), values.float()

    def _leaf_trunk_impl(self, features: Tensor) -> Tensor:
        if not self.config.distilled_leaf_evaluator:
            raise RuntimeError("distilled leaf evaluation is disabled")
        normalized = torch.log1p(features.float().clamp(0, 65535)) / 11.090354888959125
        return self.leaf_trunk(normalized)

    def _leaf_forward_impl(self, features: Tensor) -> Tensor:
        return self.leaf_value(self._leaf_trunk_impl(features)).squeeze(-1)

    def _leaf_joint_forward_impl(
        self, features: Tensor
    ) -> tuple[Tensor, Tensor, Tensor]:
        if not self.config.distilled_leaf_policy:
            raise RuntimeError("the distilled policy head is disabled")
        pooled = self._leaf_trunk_impl(features)
        logits = self.leaf_policy(pooled)
        split = self.config.action_count
        return (
            logits[:, :split],
            logits[:, split:],
            self.leaf_value(pooled).squeeze(-1),
        )

    def _precision_context(self, features: Tensor) -> torch.autocast:
        """Use the same checked arithmetic for training and every evaluator.

        FP32 explicitly disables any surrounding autocast. BF16 keeps model
        parameters in FP32 and callers promote outputs before losses/reductions.
        """
        if features.ndim != 2 or features.shape[1] != self.config.feature_count:
            raise ValueError(f"expected [batch,{self.config.feature_count}] features")
        device_type = features.device.type
        enabled = self.config.precision == "bf16"
        if enabled:
            if device_type == "cuda" and not torch.cuda.is_bf16_supported():
                raise RuntimeError("bf16 precision requires a bf16-capable CUDA device")
            if device_type not in {"cpu", "cuda"}:
                raise RuntimeError(f"bf16 precision is unsupported on {device_type}")
        return torch.autocast(
            device_type=device_type, dtype=torch.bfloat16, enabled=enabled
        )

    def leaf_forward(self, features: Tensor) -> Tensor:
        with self._precision_context(features):
            values = self._leaf_forward_impl(features)
        return values.float()

    def leaf_joint_forward(self, features: Tensor) -> tuple[Tensor, Tensor, Tensor]:
        with self._precision_context(features):
            own, opponent, values = self._leaf_joint_forward_impl(features)
        return own.float(), opponent.float(), values.float()

    def forward_joint(self, features: Tensor) -> tuple[Tensor, Tensor, Tensor]:
        with self._precision_context(features):
            own, opponent, values = self._forward_joint_impl(features)
        return own.float(), opponent.float(), values.float()

    @property
    def sequence_length(self) -> int:
        if self.config.token_layout == "semantic-entity-v1":
            return _SEMANTIC_TOKEN_COUNT + 1
        return (
            self.config.feature_count + self.config.token_group_size - 1
        ) // self.config.token_group_size + 1

    @property
    def inference_engine(self) -> str:
        return self._inference_engine

    @property
    def supports_deferred_evaluation(self) -> bool:
        device = next(self.parameters()).device
        # Inductor's static CUDA graphs did not overlap on the production GPU:
        # two batch-96 launches regressed 1.8%. Keep that path serialized while
        # eager kernels and CPU heuristic work retain measured overlap.
        return device.type == "cuda" and self._inference_engine == "eager"

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
            configure_triton_runtime()
            # The ten intentional static batch shapes exceed Dynamo's default
            # eight-entry per-frame recompilation limit in production search.
            torch._dynamo.config.recompile_limit = max(
                torch._dynamo.config.recompile_limit,
                _COMPILED_RECOMPILE_LIMIT,
            )
        if selected != self._inference_engine:
            self._compiled_forwards.clear()
            self._compiled_joint_forwards.clear()
            self._compiled_leaf_forwards.clear()
            self._compiled_leaf_joint_forwards.clear()
            self._inference_engine = selected

    @staticmethod
    def _inference_bucket(batch: int) -> int:
        for bucket in _INFERENCE_BUCKETS:
            if batch <= bucket:
                return bucket
        return batch

    def _padded_inference(self, features: Tensor) -> tuple[Tensor, int, int]:
        batch = features.shape[0]
        bucket = self._inference_bucket(batch)
        if bucket == batch:
            return features, batch, bucket
        padded = torch.zeros(
            (bucket, features.shape[1]),
            dtype=features.dtype,
            device=features.device,
        )
        padded[:batch].copy_(features)
        return padded, batch, bucket

    def _compiled_forward(self, features: Tensor) -> tuple[Tensor, Tensor]:
        padded, batch, bucket = self._padded_inference(features)
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

    def _compiled_joint_forward(
        self, features: Tensor
    ) -> tuple[Tensor, Tensor, Tensor]:
        padded, batch, bucket = self._padded_inference(features)
        compiled = self._compiled_joint_forwards.get(bucket)
        if compiled is None:
            compiled = torch.compile(
                self._forward_joint_impl,
                mode="reduce-overhead",
                fullgraph=True,
                dynamic=False,
            )
            self._compiled_joint_forwards[bucket] = compiled
        own, opponent, values = compiled(padded)
        return own[:batch], opponent[:batch], values[:batch]

    def _compiled_leaf_forward(self, features: Tensor) -> Tensor:
        padded, batch, bucket = self._padded_inference(features)
        compiled = self._compiled_leaf_forwards.get(bucket)
        if compiled is None:
            compiled = torch.compile(
                self._leaf_forward_impl,
                mode="reduce-overhead",
                fullgraph=True,
                dynamic=False,
            )
            self._compiled_leaf_forwards[bucket] = compiled
        return compiled(padded)[:batch]

    def _compiled_leaf_joint_forward(
        self, features: Tensor
    ) -> tuple[Tensor, Tensor, Tensor]:
        padded, batch, bucket = self._padded_inference(features)
        compiled = self._compiled_leaf_joint_forwards.get(bucket)
        if compiled is None:
            compiled = torch.compile(
                self._leaf_joint_forward_impl,
                mode="reduce-overhead",
                fullgraph=True,
                dynamic=False,
            )
            self._compiled_leaf_joint_forwards[bucket] = compiled
        own, opponent, values = compiled(padded)
        return own[:batch], opponent[:batch], values[:batch]

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

    def _masked_policy(self, logits: Tensor, mask_indexes: Tensor) -> Tensor:
        # Empty masks are rejected host-side in _checked_masks (mask 0 is the
        # only all-illegal lookup row); a device-side check here would force a
        # CUDA sync in the middle of an asynchronous launch.
        legal = self._legal_mask_lookup.index_select(0, mask_indexes)
        logits = logits.masked_fill(~legal, torch.finfo(logits.dtype).min)
        return torch.softmax(logits, dim=-1)

    def _evaluation_outputs(self, tensor: Tensor, mask_indexes: Tensor) -> Tensor:
        if self._inference_engine == "compiled":
            with self._precision_context(tensor):
                logits, values = self._compiled_forward(tensor)
            logits, values = logits.float(), values.float()
        else:
            logits, values = self(tensor)
        probabilities = self._masked_policy(logits, mask_indexes)
        return torch.cat((probabilities, values.unsqueeze(1)), dim=1)

    def _leaf_evaluation_outputs(self, tensor: Tensor) -> Tensor:
        if self._inference_engine == "compiled":
            with self._precision_context(tensor):
                values = self._compiled_leaf_forward(tensor)
            return values.float()
        return self.leaf_forward(tensor)

    def _joint_evaluation_outputs(
        self, tensor: Tensor, own_masks: Tensor, opponent_masks: Tensor
    ) -> Tensor:
        if self._inference_engine == "compiled":
            with self._precision_context(tensor):
                own, opponent, values = self._compiled_joint_forward(tensor)
            own, opponent, values = own.float(), opponent.float(), values.float()
        else:
            own, opponent, values = self.forward_joint(tensor)
        return self._joint_rows(own, opponent, values, own_masks, opponent_masks)

    def _leaf_joint_evaluation_outputs(
        self, tensor: Tensor, own_masks: Tensor, opponent_masks: Tensor
    ) -> Tensor:
        if self._inference_engine == "compiled":
            with self._precision_context(tensor):
                own, opponent, values = self._compiled_leaf_joint_forward(tensor)
            own, opponent, values = own.float(), opponent.float(), values.float()
        else:
            own, opponent, values = self.leaf_joint_forward(tensor)
        return self._joint_rows(own, opponent, values, own_masks, opponent_masks)

    def _joint_rows(
        self,
        own: Tensor,
        opponent: Tensor,
        values: Tensor,
        own_masks: Tensor,
        opponent_masks: Tensor,
    ) -> Tensor:
        return torch.cat(
            (
                self._masked_policy(own, own_masks),
                self._masked_policy(opponent, opponent_masks),
                values.unsqueeze(1),
            ),
            dim=1,
        )

    @staticmethod
    def _checked_masks(masks: Sequence[int]) -> np.ndarray:
        mask_array = np.asarray(masks, dtype=np.uint16)
        if (mask_array == 0).any():
            raise ValueError("network evaluation received an empty legal mask")
        return mask_array

    @staticmethod
    def _arrays(
        features: Sequence[Sequence[int]], masks: Sequence[int]
    ) -> tuple[np.ndarray, np.ndarray]:
        feature_array = np.stack(features)
        if feature_array.ndim != 2:
            raise ValueError("network evaluation requires a rectangular feature batch")
        mask_array = BattleTransformer._checked_masks(masks)
        if len(feature_array) != len(mask_array):
            raise ValueError("network evaluation feature and mask batches differ")
        return feature_array, mask_array

    @torch.inference_mode()
    def begin_evaluate(
        self, features: Sequence[Sequence[int]], masks: Sequence[int]
    ) -> EvaluationTicket:
        """Launch inference without synchronizing independent CUDA work.

        CUDA inputs and outputs use ticket-owned pinned buffers. This prevents a
        later same-shaped launch from overwriting an in-flight transfer while
        allowing the pooled search scheduler to launch every model before it
        waits for any result.
        """
        device = next(self.parameters()).device
        feature_array, mask_array = self._arrays(features, masks)
        if device.type != "cuda":
            tensor = self._staged_tensor(
                feature_array, self._pinned_feature_buffers, device
            ).long()
            mask_indexes = self._staged_tensor(
                mask_array, self._pinned_mask_buffers, device
            ).long()
            values = self._evaluation_outputs(tensor, mask_indexes).cpu().numpy()
            return _ImmediateEvaluation(
                (values[:, :-1].tolist(), values[:, -1].tolist())
            )

        feature_source = torch.from_numpy(feature_array)
        mask_source = torch.from_numpy(mask_array)
        pinned_features = torch.empty(
            feature_source.shape, dtype=feature_source.dtype, pin_memory=True
        )
        pinned_masks = torch.empty(
            mask_source.shape, dtype=mask_source.dtype, pin_memory=True
        )
        pinned_features.copy_(feature_source)
        pinned_masks.copy_(mask_source)
        if self._inference_stream is None:
            self._inference_stream = torch.cuda.Stream(device=device)
        stream = self._inference_stream
        stream.wait_stream(torch.cuda.current_stream(device))
        with torch.cuda.stream(stream):
            tensor = pinned_features.to(device, non_blocking=True).long()
            mask_indexes = pinned_masks.to(device, non_blocking=True).long()
            outputs = self._evaluation_outputs(tensor, mask_indexes)
            host_output = torch.empty(
                outputs.shape,
                dtype=outputs.dtype,
                device="cpu",
                pin_memory=True,
            )
            host_output.copy_(outputs, non_blocking=True)
            ready = torch.cuda.Event()
            ready.record(stream)
        return _CudaEvaluation(
            host_output,
            ready,
            (pinned_features, pinned_masks, tensor, mask_indexes, outputs),
        )

    def evaluate(
        self, features: Sequence[Sequence[int]], masks: Sequence[int]
    ) -> tuple[list[list[float]], list[float]]:
        return self.begin_evaluate(features, masks).result()

    @torch.inference_mode()
    def _begin_joint(
        self,
        features: Sequence[Sequence[int]],
        own_masks: Sequence[int],
        opponent_masks: Sequence[int],
        outputs_of: Callable[[Tensor, Tensor, Tensor], Tensor],
    ) -> JointEvaluationTicket:
        """Launch one masked own/opponent/value batch through `outputs_of`.

        The encoder head and the distilled head differ only in which module
        turns features into logits; the staging, streams, and pinned buffers
        that keep the launch asynchronous are the same either way.
        """
        device = next(self.parameters()).device
        feature_array, own_mask_array = self._arrays(features, own_masks)
        opponent_mask_array = self._checked_masks(opponent_masks)
        if len(feature_array) != len(opponent_mask_array):
            raise ValueError("joint evaluation feature and mask batches differ")
        if device.type != "cuda":
            tensor = self._staged_tensor(
                feature_array, self._pinned_feature_buffers, device
            ).long()
            own_indexes = torch.from_numpy(own_mask_array).to(device).long()
            opponent_indexes = torch.from_numpy(opponent_mask_array).to(device).long()
            output = outputs_of(tensor, own_indexes, opponent_indexes).cpu().numpy()
            split = self.config.action_count
            return _ImmediateJointEvaluation(
                (
                    output[:, :split].tolist(),
                    output[:, split : 2 * split].tolist(),
                    output[:, -1].tolist(),
                )
            )

        feature_source = torch.from_numpy(feature_array)
        own_mask_source = torch.from_numpy(own_mask_array)
        opponent_mask_source = torch.from_numpy(opponent_mask_array)
        pinned_features = torch.empty(
            feature_source.shape, dtype=feature_source.dtype, pin_memory=True
        )
        pinned_own_masks = torch.empty(
            own_mask_source.shape, dtype=own_mask_source.dtype, pin_memory=True
        )
        pinned_opponent_masks = torch.empty(
            opponent_mask_source.shape,
            dtype=opponent_mask_source.dtype,
            pin_memory=True,
        )
        pinned_features.copy_(feature_source)
        pinned_own_masks.copy_(own_mask_source)
        pinned_opponent_masks.copy_(opponent_mask_source)
        if self._inference_stream is None:
            self._inference_stream = torch.cuda.Stream(device=device)
        stream = self._inference_stream
        stream.wait_stream(torch.cuda.current_stream(device))
        with torch.cuda.stream(stream):
            tensor = pinned_features.to(device, non_blocking=True).long()
            own_indexes = pinned_own_masks.to(device, non_blocking=True).long()
            opponent_indexes = pinned_opponent_masks.to(
                device, non_blocking=True
            ).long()
            outputs = outputs_of(tensor, own_indexes, opponent_indexes)
            host_output = torch.empty(
                outputs.shape, dtype=outputs.dtype, device="cpu", pin_memory=True
            )
            host_output.copy_(outputs, non_blocking=True)
            ready = torch.cuda.Event()
            ready.record(stream)
        return _CudaJointEvaluation(
            host_output,
            ready,
            self.config.action_count,
            (
                pinned_features,
                pinned_own_masks,
                pinned_opponent_masks,
                tensor,
                own_indexes,
                opponent_indexes,
                outputs,
            ),
        )

    def begin_evaluate_joint(
        self,
        features: Sequence[Sequence[int]],
        own_masks: Sequence[int],
        opponent_masks: Sequence[int],
    ) -> JointEvaluationTicket:
        if not self.config.joint_policy_heads:
            raise RuntimeError("joint evaluation requires joint policy heads")
        return self._begin_joint(
            features, own_masks, opponent_masks, self._joint_evaluation_outputs
        )

    def evaluate_joint(
        self,
        features: Sequence[Sequence[int]],
        own_masks: Sequence[int],
        opponent_masks: Sequence[int],
    ) -> tuple[list[list[float]], list[list[float]], list[float]]:
        return self.begin_evaluate_joint(features, own_masks, opponent_masks).result()

    def begin_evaluate_leaf_joint(
        self,
        features: Sequence[Sequence[int]],
        own_masks: Sequence[int],
        opponent_masks: Sequence[int],
    ) -> JointEvaluationTicket:
        """Priors and a value from the distilled trunk, skipping the encoder."""
        if not self.config.distilled_leaf_policy:
            raise RuntimeError("the distilled policy head is disabled")
        return self._begin_joint(
            features, own_masks, opponent_masks, self._leaf_joint_evaluation_outputs
        )

    def evaluate_leaf_joint(
        self,
        features: Sequence[Sequence[int]],
        own_masks: Sequence[int],
        opponent_masks: Sequence[int],
    ) -> tuple[list[list[float]], list[list[float]], list[float]]:
        return self.begin_evaluate_leaf_joint(
            features, own_masks, opponent_masks
        ).result()

    @torch.inference_mode()
    def begin_evaluate_leaf(
        self, features: Sequence[Sequence[int]]
    ) -> ValueEvaluationTicket:
        if not self.config.distilled_leaf_evaluator:
            raise RuntimeError("distilled leaf evaluation is disabled")
        feature_array = np.stack(features)
        if feature_array.ndim != 2:
            raise ValueError("leaf evaluation requires a rectangular feature batch")
        device = next(self.parameters()).device
        if device.type != "cuda":
            tensor = self._staged_tensor(
                feature_array, self._pinned_feature_buffers, device
            ).long()
            values = self._leaf_evaluation_outputs(tensor).cpu().tolist()
            return _ImmediateValueEvaluation(values)

        feature_source = torch.from_numpy(feature_array)
        pinned_features = torch.empty(
            feature_source.shape, dtype=feature_source.dtype, pin_memory=True
        )
        pinned_features.copy_(feature_source)
        if self._inference_stream is None:
            self._inference_stream = torch.cuda.Stream(device=device)
        stream = self._inference_stream
        stream.wait_stream(torch.cuda.current_stream(device))
        with torch.cuda.stream(stream):
            tensor = pinned_features.to(device, non_blocking=True).long()
            outputs = self._leaf_evaluation_outputs(tensor)
            host_output = torch.empty(
                outputs.shape, dtype=outputs.dtype, device="cpu", pin_memory=True
            )
            host_output.copy_(outputs, non_blocking=True)
            ready = torch.cuda.Event()
            ready.record(stream)
        return _CudaValueEvaluation(
            host_output,
            ready,
            (pinned_features, tensor, outputs),
        )

    def evaluate_leaf(self, features: Sequence[Sequence[int]]) -> list[float]:
        return self.begin_evaluate_leaf(features).result()

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
    additional_state: dict[str, object] | None = None,
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
    if additional_state is not None:
        overlap = payload.keys() & additional_state.keys()
        if overlap:
            raise ValueError(f"additional checkpoint state replaces {sorted(overlap)}")
        payload.update(additional_state)
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


def load_network(
    path: Path, device: torch.device, *, state: str = "deployed"
) -> BattleTransformer:
    if state not in {"deployed", "learner"}:
        raise ValueError("checkpoint state must be deployed or learner")
    payload = load_checkpoint(path, device)
    raw_config = dict(payload["config"])
    # Checkpoints written before precision became explicit executed in strict FP32.
    raw_config.setdefault("precision", "fp32")
    network = BattleTransformer(TransformerConfig(**raw_config)).to(device)
    key = "model" if state == "deployed" else "learner_model"
    if key not in payload:
        raise ValueError(f"checkpoint does not contain requested {state} state")
    network.load_state_dict(payload[key])
    network.eval()
    return network


def warm_start_network(
    path: Path, target_config: TransformerConfig, device: torch.device
) -> BattleTransformer:
    """Copy a compatible checkpoint, extending only the positional table if needed.

    The distilled leaf evaluator may change shape between lineages: when the
    resolved leaf layouts differ, the target keeps its fresh leaf head (whose
    final layer is zero-initialized) and re-distills instead of copying.
    """
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
    # The leaf evaluator is compared by resolved layout below, so equivalent
    # spellings (leaf_hidden=64 versus leaf_hidden_layers=(64, 64)) still copy.
    for comparable in (comparable_source, comparable_target):
        comparable.pop("leaf_hidden")
        comparable.pop("leaf_hidden_layers")
    if comparable_source != comparable_target:
        raise ValueError("warm-start checkpoint architecture is incompatible")
    if source_features > target_features:
        raise ValueError("warm-start cannot shrink the source observation schema")
    copy_leaf = leaf_layer_sizes(source_config) == leaf_layer_sizes(target_config)

    target = BattleTransformer(target_config).to(device)
    source_state = source.state_dict()
    target_state = target.state_dict()
    with torch.no_grad():
        for name, source_value in source_state.items():
            if not copy_leaf and name.startswith(
                ("leaf_trunk.", "leaf_value.", "leaf_policy.")
            ):
                continue
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
