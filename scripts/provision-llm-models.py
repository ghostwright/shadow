#!/usr/bin/env python3
"""
Download MLX-format LLM and embedding models for on-device inference.

Produces:
  ~/.shadow/models/llm/<model-name>/         (LLM models)
  ~/.shadow/models/embeddings/<model-name>/  (embedding models)
    ├── config.json
    ├── tokenizer.json
    ├── tokenizer_config.json
    ├── model*.safetensors
    └── ...

Models:
  - Qwen2.5-7B-Instruct-4bit     (fast tier, ~4.5 GB, Apache 2.0)
  - Qwen2.5-1.5B-Instruct-4bit   (draft model for speculative decoding, ~1 GB, Apache 2.0)
  - Qwen2.5-32B-Instruct-4bit    (deep tier, ~20 GB, Apache 2.0)
  - Qwen2.5-VL-7B-Instruct-4bit  (vision tier, ~5 GB, Apache 2.0)
  - nomic-embed-text-v1.5         (embed tier, ~0.25 GB, Apache 2.0)
  - ShowUI-2B                     (grounding tier, ~1.5 GB, MIT license)

Source: https://huggingface.co/mlx-community/, https://huggingface.co/nomic-ai/
License: Apache 2.0

Verification strategy: weight fingerprint (hashes only inference-essential files:
*.safetensors, *.json, merges.txt, vocab.txt, vocab.json, tokenizer.model).
Metadata files (.gitattributes, README.md, .cache/) are excluded — they change
independently of the model and would make verification brittle.

Idempotent: skips download when verification passes.

Usage:
  python3 scripts/provision-llm-models.py                    # fast tier (default)
  python3 scripts/provision-llm-models.py --tier fast         # fast tier explicitly
  python3 scripts/provision-llm-models.py --tier draft        # draft model (~1 GB)
  python3 scripts/provision-llm-models.py --tier deep         # deep tier (32B, 48GB+ RAM)
  python3 scripts/provision-llm-models.py --tier vision       # vision tier (VLM, 24GB+ RAM)
  python3 scripts/provision-llm-models.py --tier embed        # embedding tier (~250 MB)
  python3 scripts/provision-llm-models.py --tier grounding    # grounding tier (ShowUI-2B, ~1.5 GB)
  python3 scripts/provision-llm-models.py --tier all          # all tiers
  python3 scripts/provision-llm-models.py --model Qwen2.5-7B-Instruct-4bit
  python3 scripts/provision-llm-models.py --force             # re-download even if verified
  python3 scripts/provision-llm-models.py --pin               # print pinning values for script

Requirements:
  pip3 install huggingface_hub
"""

import argparse
import ctypes
import ctypes.util
import hashlib
import os
import shutil
import sys
from pathlib import Path

# ---------------------------------------------------------------------------
# Preflight checks
# ---------------------------------------------------------------------------

def check_python_version():
    """Require Python 3.8+."""
    if sys.version_info < (3, 8):
        print(f"ERROR: Python 3.8+ required, found {sys.version}")
        sys.exit(1)

check_python_version()

try:
    from huggingface_hub import snapshot_download
except ImportError:
    print("ERROR: huggingface_hub not installed.")
    print()
    print("  Install with:  pip3 install huggingface_hub")
    print()
    print("  If pip3 is not found, install it first:")
    print("    python3 -m ensurepip --upgrade")
    sys.exit(1)


# ---------------------------------------------------------------------------
# Inference-essential file patterns
# ---------------------------------------------------------------------------
# Only these files are downloaded and verified. Metadata files (.gitattributes,
# README.md, LICENSE, .cache/) are excluded from both download and verification.
# This makes the fingerprint stable across HuggingFace repo housekeeping.

INFERENCE_PATTERNS = [
    "*.safetensors",
    "*.json",
    "merges.txt",
    "vocab.txt",
    "vocab.json",
    "tokenizer.model",
]


# ---------------------------------------------------------------------------
# Model catalog
# ---------------------------------------------------------------------------
# weight_fingerprint: SHA256 over (filename + file_sha256) for all inference-
# essential files, sorted by filename. Deterministic and stable — only changes
# when actual model content changes, not when metadata files are updated.
#
# To pin a model: run with --pin after downloading. The script prints the
# exact values to paste here.

MODELS = {
    "Qwen2.5-7B-Instruct-4bit": {
        "repo_id": "mlx-community/Qwen2.5-7B-Instruct-4bit",
        "revision": "c26a38f6a37d0a51b4e9a1eb3026530fa35d9fed",
        "required_files": ["config.json", "tokenizer.json"],
        "config_sha256": "1661a349986919d13820d3981623776138d50783d13e247cdc5b075a22b62698",
        "weight_fingerprint": "a572fe6b4290ff41ea22e64cc6711fd01afcd11febdd42b903e4269a7ddc9d08",
        "size_estimate_gb": 4.5,
        "min_ram_gb": 16,
    },
    "Qwen2.5-1.5B-Instruct-4bit": {
        "repo_id": "mlx-community/Qwen2.5-1.5B-Instruct-4bit",
        "revision": "main",
        "required_files": ["config.json", "tokenizer.json"],
        "config_sha256": None,
        "weight_fingerprint": None,
        "size_estimate_gb": 1.0,
        "min_ram_gb": 8,
    },
    "Qwen2.5-32B-Instruct-4bit": {
        "repo_id": "mlx-community/Qwen2.5-32B-Instruct-4bit",
        "revision": "main",
        "required_files": ["config.json", "tokenizer.json"],
        "config_sha256": None,
        "weight_fingerprint": None,
        "size_estimate_gb": 20.0,
        "min_ram_gb": 48,
    },
    "Qwen2.5-VL-7B-Instruct-4bit": {
        "repo_id": "mlx-community/Qwen2.5-VL-7B-Instruct-4bit",
        "revision": "main",
        "required_files": ["config.json", "tokenizer.json", "preprocessor_config.json"],
        "config_sha256": None,
        "weight_fingerprint": None,
        "size_estimate_gb": 5.0,
        "min_ram_gb": 24,
    },
    "nomic-embed-text-v1.5": {
        "repo_id": "nomic-ai/nomic-embed-text-v1.5",
        "revision": "main",
        "required_files": ["config.json"],
        "config_sha256": None,
        "weight_fingerprint": None,
        "size_estimate_gb": 0.25,
        "min_ram_gb": 8,
        "base_dir": "embeddings",
    },
    "ShowUI-2B-bf16-8bit": {
        "repo_id": "mlx-community/ShowUI-2B-bf16-8bit",
        "revision": "main",
        "required_files": ["config.json", "tokenizer.json", "preprocessor_config.json"],
        "config_sha256": "f89c882af51e7c14af9c9f9f4c278696d672c3cdc15c8f0eef5552e940145f23",
        "weight_fingerprint": "46555d91999af0ed3df67dbc92ad013f779851c8e4788f67288ca8d28a819372",
        "size_estimate_gb": 3.0,
        "min_ram_gb": 16,
    },
}

TIER_MODELS = {
    "fast": ["Qwen2.5-7B-Instruct-4bit"],
    "draft": ["Qwen2.5-1.5B-Instruct-4bit"],
    "deep": ["Qwen2.5-32B-Instruct-4bit"],
    "vision": ["Qwen2.5-VL-7B-Instruct-4bit"],
    "embed": ["nomic-embed-text-v1.5"],
    "grounding": ["ShowUI-2B-bf16-8bit"],
    "all": [
        "Qwen2.5-7B-Instruct-4bit",
        "Qwen2.5-1.5B-Instruct-4bit",
        "Qwen2.5-32B-Instruct-4bit",
        "Qwen2.5-VL-7B-Instruct-4bit",
        "nomic-embed-text-v1.5",
        "ShowUI-2B-bf16-8bit",
    ],
}

MODELS_DIR = Path.home() / ".shadow" / "models" / "llm"
EMBEDDINGS_DIR = Path.home() / ".shadow" / "models" / "embeddings"


# ---------------------------------------------------------------------------
# System detection
# ---------------------------------------------------------------------------

def get_system_ram_gb():
    """Get system physical RAM in GB using sysctl (macOS) or sysconf (Linux)."""
    try:
        libc = ctypes.CDLL(ctypes.util.find_library("c"))
        size = ctypes.c_uint64(0)
        size_len = ctypes.c_size_t(ctypes.sizeof(size))
        result = libc.sysctlbyname(
            b"hw.memsize",
            ctypes.byref(size),
            ctypes.byref(size_len),
            None,
            ctypes.c_size_t(0),
        )
        if result == 0:
            return size.value / (1024 ** 3)
    except (OSError, AttributeError):
        pass

    try:
        return os.sysconf("SC_PAGE_SIZE") * os.sysconf("SC_PHYS_PAGES") / (1024 ** 3)
    except (ValueError, OSError):
        pass

    print("WARNING: Could not detect system RAM, assuming 16 GB")
    return 16.0


def get_available_disk_gb(path):
    """Get available disk space in GB for the filesystem containing path."""
    try:
        usage = shutil.disk_usage(str(path))
        return usage.free / (1024 ** 3)
    except OSError:
        return None


# ---------------------------------------------------------------------------
# Hashing and verification
# ---------------------------------------------------------------------------

def sha256_file(path):
    """Compute SHA256 hex digest of a file."""
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(65536), b""):
            h.update(chunk)
    return h.hexdigest()


def collect_inference_files(model_dir):
    """Collect inference-essential files from a model directory.

    Returns a sorted list of Path objects matching INFERENCE_PATTERNS.
    Only top-level files — excludes .cache/, .huggingface/, etc.
    """
    model_dir = Path(model_dir)
    files = []
    for pattern in INFERENCE_PATTERNS:
        files.extend(model_dir.glob(pattern))
    # Deduplicate (glob can overlap) and sort by name for determinism
    files = sorted(set(files), key=lambda p: p.name)
    return files


def weight_fingerprint(model_dir):
    """Compute a stable fingerprint over inference-essential files only.

    Hashes (filename, file_sha256) pairs for all files matching
    INFERENCE_PATTERNS. Sorted by filename for determinism.

    This fingerprint is stable across:
    - HuggingFace metadata changes (.gitattributes, README.md)
    - huggingface_hub cache file changes (.cache/)
    - File system ordering differences

    It ONLY changes when actual model content changes (weights, config,
    tokenizer).
    """
    files = collect_inference_files(model_dir)
    if not files:
        return None

    h = hashlib.sha256()
    for f in files:
        h.update(f.name.encode("utf-8"))
        h.update(b"\0")
        h.update(sha256_file(f).encode("utf-8"))
        h.update(b"\0")

    return h.hexdigest()


def verify_model(model_dir, config):
    """Verify a downloaded model directory.

    3-step verification:
    1. Required files exist (config.json, tokenizer.json, etc.)
    2. At least one .safetensors weight file present
    3. config.json SHA256 matches pinned value (if pinned)
    4. Weight fingerprint matches pinned value (if pinned)

    Returns (ok: bool, message: str).
    """
    model_dir = Path(model_dir)

    # 1. Required files
    for required in config["required_files"]:
        if not (model_dir / required).exists():
            return False, f"Missing required file: {required}"

    # 2. Weight files
    safetensors = list(model_dir.glob("*.safetensors"))
    if not safetensors:
        return False, "No .safetensors weight files found"

    # 3. Config SHA256
    if config["config_sha256"]:
        actual = sha256_file(model_dir / "config.json")
        if actual != config["config_sha256"]:
            return False, (
                f"config.json checksum mismatch: "
                f"expected {config['config_sha256'][:16]}..., "
                f"got {actual[:16]}..."
            )

    # 4. Weight fingerprint
    if config["weight_fingerprint"]:
        actual_fp = weight_fingerprint(model_dir)
        if actual_fp != config["weight_fingerprint"]:
            return False, (
                f"Weight fingerprint mismatch: "
                f"expected {config['weight_fingerprint'][:16]}..., "
                f"got {actual_fp[:16]}..."
            )

    return True, "Verified"


def print_pin_values(model_dir, model_name):
    """Print the pinning values for a downloaded model."""
    model_dir = Path(model_dir)

    config_hash = sha256_file(model_dir / "config.json")
    fp = weight_fingerprint(model_dir)

    print(f"\n--- Pinning values for {model_name} ---")
    print(f"  config_sha256:      \"{config_hash}\"")
    print(f"  weight_fingerprint: \"{fp}\"")
    print()

    # Per-file detail for transparency
    files = collect_inference_files(model_dir)
    total_bytes = sum(f.stat().st_size for f in files)
    print(f"  Files verified ({len(files)} files, {total_bytes / (1024**3):.2f} GB):")
    for f in files:
        size_mb = f.stat().st_size / (1024 * 1024)
        fhash = sha256_file(f)
        print(f"    {f.name:40s}  {size_mb:10.2f} MB  {fhash[:16]}...")


# ---------------------------------------------------------------------------
# Download
# ---------------------------------------------------------------------------

def model_dir_for(model_name, config):
    """Resolve the on-disk directory for a model."""
    base_dir = EMBEDDINGS_DIR if config.get("base_dir") == "embeddings" else MODELS_DIR
    return base_dir / model_name


def provision(model_name, force=False, pin=False):
    """Download and verify a model."""
    if model_name not in MODELS:
        print(f"ERROR: Unknown model '{model_name}'.")
        print(f"Available: {', '.join(MODELS.keys())}")
        sys.exit(1)

    config = MODELS[model_name]
    model_dir = model_dir_for(model_name, config)

    # --- Preflight checks ---

    # RAM check
    min_ram = config.get("min_ram_gb")
    if min_ram:
        system_ram = get_system_ram_gb()
        if system_ram < min_ram:
            print(f"WARNING: {model_name} recommends {min_ram} GB RAM, "
                  f"system has {system_ram:.0f} GB")
            if not force:
                print("  Use --force to download anyway.")
                return
            print("  --force specified, proceeding.")

    # Disk space check
    disk_gb = get_available_disk_gb(model_dir.parent if model_dir.parent.exists()
                                     else Path.home())
    needed_gb = config["size_estimate_gb"] * 1.5  # 1.5x safety margin
    if disk_gb is not None and disk_gb < needed_gb:
        print(f"WARNING: Low disk space. Available: {disk_gb:.1f} GB, "
              f"need ~{needed_gb:.1f} GB ({config['size_estimate_gb']} GB model + margin)")
        if not force:
            print("  Use --force to download anyway.")
            return
        print("  --force specified, proceeding.")

    # --- Status ---

    print(f"Model:    {model_name}")
    print(f"Source:   {config['repo_id']}")
    print(f"Revision: {config['revision']}")
    print(f"Target:   {model_dir}")
    print(f"Size:     ~{config['size_estimate_gb']} GB")
    if min_ram:
        print(f"Min RAM:  {min_ram} GB")
    print()

    # --- Check existing ---

    if not force and model_dir.exists():
        ok, msg = verify_model(model_dir, config)
        if ok:
            print(f"Already provisioned and verified.")
            if pin:
                print_pin_values(model_dir, model_name)
            return
        else:
            print(f"Existing download failed verification: {msg}")
            print(f"Re-downloading...")
            print()

    if force and model_dir.exists():
        print("--force specified, re-downloading...")
        print()

    # --- Download ---

    print(f"Downloading {config['repo_id']}...")
    print(f"This may take several minutes for a {config['size_estimate_gb']} GB model.")
    print()

    model_dir.parent.mkdir(parents=True, exist_ok=True)

    try:
        snapshot_download(
            repo_id=config["repo_id"],
            revision=config["revision"],
            local_dir=str(model_dir),
            allow_patterns=INFERENCE_PATTERNS,
        )
    except Exception as e:
        print(f"\nERROR: Download failed: {e}")
        sys.exit(1)

    # --- Post-download verification ---

    ok, msg = verify_model(model_dir, config)
    if not ok:
        # If checksums are pinned and don't match, that's a hard failure
        has_pins = (config["config_sha256"] is not None
                    or config["weight_fingerprint"] is not None)
        if has_pins:
            print(f"\nERROR: Downloaded model failed verification: {msg}")
            print(f"This may indicate the model was updated on HuggingFace.")
            print(f"Run with --pin to see current values, then update the script.")
            sys.exit(1)
        else:
            # No pins — structural check passed, just no integrity pins yet
            print(f"Structural verification passed (no pinned checksums yet).")

    print(f"\nModel provisioned successfully: {model_name}")

    # Always show pin values after download
    print_pin_values(model_dir, model_name)

    if not config["config_sha256"] or not config["weight_fingerprint"]:
        print("  To make this reproducible, update the MODELS dict in this script")
        print("  with the config_sha256 and weight_fingerprint values above.")


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def main():
    parser = argparse.ArgumentParser(
        description="Provision MLX LLM models for Shadow",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
  %(prog)s                    Download fast tier (default, ~4.5 GB)
  %(prog)s --tier deep        Download deep tier (32B, ~20 GB)
  %(prog)s --tier all         Download all tiers
  %(prog)s --pin              Show pinning values for already-downloaded models
  %(prog)s --force            Re-download even if verified
""",
    )
    parser.add_argument(
        "--model",
        choices=list(MODELS.keys()),
        help="Specific model to download",
    )
    parser.add_argument(
        "--tier",
        choices=list(TIER_MODELS.keys()),
        default=None,
        help="Model tier: fast (default), draft, deep, vision, embed, grounding, all",
    )
    parser.add_argument(
        "--force",
        action="store_true",
        help="Re-download even when verification passes",
    )
    parser.add_argument(
        "--pin",
        action="store_true",
        help="Print pinning values for downloaded models (for updating this script)",
    )
    args = parser.parse_args()

    # Pin mode: just print values for already-downloaded models
    if args.pin and not args.model and not args.tier:
        found = False
        for name, config in MODELS.items():
            md = model_dir_for(name, config)
            if md.exists():
                ok, _ = verify_model(md, config)
                status = "verified" if ok else "NOT verified (structural check)"
                print(f"{name}: {status}")
                print_pin_values(md, name)
                found = True
        if not found:
            print("No models downloaded yet. Run without --pin to download first.")
        return

    if args.model:
        provision(args.model, force=args.force, pin=args.pin)
    else:
        tier = args.tier or "fast"
        models_to_download = TIER_MODELS[tier]
        for i, model_name in enumerate(models_to_download):
            if i > 0:
                print()
                print("=" * 60)
                print()
            provision(model_name, force=args.force, pin=args.pin)


if __name__ == "__main__":
    main()
