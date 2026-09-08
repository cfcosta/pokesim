"""Discover existing CUDA tools for Triton without overriding user settings."""

from __future__ import annotations

import os
from pathlib import Path

_NIX_DRIVER_DIRECTORY = Path("/run/opengl-driver/lib")


def configure_triton_runtime() -> None:
    """Support NixOS, where Triton's default /sbin/ldconfig does not exist.

    This configures paths only to tools already installed on the machine. It
    does not install drivers or replace explicitly configured paths.
    """
    if _NIX_DRIVER_DIRECTORY.is_dir():
        os.environ.setdefault("TRITON_LIBCUDA_PATH", str(_NIX_DRIVER_DIRECTORY))
    cuda_home = os.environ.get("CUDA_HOME")
    if cuda_home:
        for tool, variable in (
            ("ptxas", "TRITON_PTXAS_PATH"),
            ("cuobjdump", "TRITON_CUOBJDUMP_PATH"),
            ("nvdisasm", "TRITON_NVDISASM_PATH"),
        ):
            executable = Path(cuda_home) / "bin" / tool
            if executable.is_file():
                os.environ.setdefault(variable, str(executable))
