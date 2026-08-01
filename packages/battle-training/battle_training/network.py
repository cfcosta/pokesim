"""Side-canonical transformer policy/value network."""

from __future__ import annotations

import copy
import os
import tempfile
from collections.abc import Sequence
from dataclasses import asdict, dataclass
from pathlib import Path
from typing import Any, Protocol

import numpy as np
import torch
from torch import Tensor, nn

from . import FEATURE_COUNT

_INFERENCE_BUCKETS = (2, 4, 8, 16, 32, 64, 96, 128, 192, 256)
_COMPILED_RECOMPILE_LIMIT = 32
_SEMANTIC_FEATURE_COUNT = 492
_SEMANTIC_TOKEN_COUNT = 31


class EvaluationTicket(Protocol):
    """One launched inference whose host result may be collected later."""

    def result(self) -> tuple[list[list[float]], list[float]]: ...


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
        self._inference_stream: torch.cuda.Stream | None = None
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

    def _forward_impl(self, features: Tensor) -> tuple[Tensor, Tensor]:
        values = features.long().clamp(0, 65535)
        if self.config.token_layout == "semantic-entity-v1":
            cls, tokens = self._semantic_tokens(values)
        else:
            cls, tokens = self._scalar_tokens(values)
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
            driver = Path("/run/opengl-driver/lib")
            if "TRITON_LIBCUDA_PATH" not in os.environ and driver.is_dir():
                os.environ["TRITON_LIBCUDA_PATH"] = str(driver)
            cuda_home = Path(os.environ.get("CUDA_HOME", ""))
            for tool, variable in (
                ("ptxas", "TRITON_PTXAS_PATH"),
                ("cuobjdump", "TRITON_CUOBJDUMP_PATH"),
                ("nvdisasm", "TRITON_NVDISASM_PATH"),
            ):
                executable = cuda_home / "bin" / tool
                if variable not in os.environ and executable.is_file():
                    os.environ[variable] = str(executable)
            # The ten intentional static batch shapes exceed Dynamo's default
            # eight-entry per-frame recompilation limit in production search.
            torch._dynamo.config.recompile_limit = max(
                torch._dynamo.config.recompile_limit,
                _COMPILED_RECOMPILE_LIMIT,
            )
        if selected != self._inference_engine:
            self._compiled_forwards.clear()
            self._inference_engine = selected

    @staticmethod
    def _inference_bucket(batch: int) -> int:
        for bucket in _INFERENCE_BUCKETS:
            if batch <= bucket:
                return bucket
        return batch

    def _compiled_forward(self, features: Tensor) -> tuple[Tensor, Tensor]:
        batch = features.shape[0]
        bucket = self._inference_bucket(batch)
        if bucket != batch:
            padded = torch.zeros(
                (bucket, features.shape[1]),
                dtype=features.dtype,
                device=features.device,
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

    def _evaluation_outputs(self, tensor: Tensor, mask_indexes: Tensor) -> Tensor:
        if self._inference_engine == "compiled":
            device_type = tensor.device.type
            with torch.autocast(device_type=device_type, dtype=torch.bfloat16):
                logits, values = self._compiled_forward(tensor)
            logits, values = logits.float(), values.float()
        else:
            logits, values = self(tensor)
        legal = self._legal_mask_lookup.index_select(0, mask_indexes)
        if (~legal.any(dim=1)).any():
            raise ValueError("network evaluation received an empty legal mask")
        logits = logits.masked_fill(~legal, torch.finfo(logits.dtype).min)
        probabilities = torch.softmax(logits, dim=-1)
        return torch.cat((probabilities, values.unsqueeze(1)), dim=1)

    @staticmethod
    def _arrays(
        features: Sequence[Sequence[int]], masks: Sequence[int]
    ) -> tuple[np.ndarray, np.ndarray]:
        feature_array = np.stack(features)
        if feature_array.ndim != 2:
            raise ValueError("network evaluation requires a rectangular feature batch")
        mask_array = np.asarray(masks, dtype=np.uint16)
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
    """Copy a compatible checkpoint, extending only the positional table if needed."""
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
    if source_features > target_features:
        raise ValueError("warm-start cannot shrink the source observation schema")

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
