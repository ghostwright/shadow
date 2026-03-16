#!/usr/bin/env python3
"""
Download pre-exported WhisperKit CoreML models from argmaxinc/whisperkit-coreml.

Produces:
  ~/.shadow/models/whisper/<model-variant>/
    ├── config.json
    ├── generation_config.json
    ├── AudioEncoder.mlmodelc/
    ├── TextDecoder.mlmodelc/
    ├── MelSpectrogram.mlmodelc/
    └── *.mlcomputeplan.json

Source: https://huggingface.co/argmaxinc/whisperkit-coreml
Profiles:
  fast     -> openai_whisper-small.en   (~200 MB)
  balanced -> openai_whisper-medium.en  (~1.5 GB, default)
  accurate -> openai_whisper-large-v3   (~3.1 GB)

Pinned to a specific HuggingFace revision. Verification covers:
  1. config.json SHA256 (pinned in source — ties model to known variant/revision)
  2. Payload structural validity (AudioEncoder/TextDecoder/MelSpectrogram are
     non-empty directories)
  3. Full directory fingerprint (sorted recursive file list + SHA256 accumulation;
     pinned after first verified download)

Idempotent: skips download only when ALL verification checks pass.
Post-download: hard-fails on any verification mismatch.

Usage:
  python3 scripts/provision-whisper-models.py                    # balanced (default)
  python3 scripts/provision-whisper-models.py --profile fast     # small.en
  python3 scripts/provision-whisper-models.py --profile accurate # large-v3

Requirements:
  pip3 install huggingface_hub
"""

import argparse
import hashlib
import os
import shutil
import sys

# ---- Model profiles ----
PROFILES = {
    "fast": "openai_whisper-small.en",
    "balanced": "openai_whisper-medium.en",
    "accurate": "openai_whisper-large-v3",
}

# ---- Pinned source ----
REPO_ID = "argmaxinc/whisperkit-coreml"
PINNED_REVISION = "1f92e0a7895c30ff3448ec31a65eb4acffcfd7de"  # 2026-01-27

# Output directory (not in git)
OUTPUT_BASE = os.path.expanduser("~/.shadow/models/whisper")

# ---- SHA256 checksums on config.json per model ----
# Pinned against PINNED_REVISION above. Hard-fail on mismatch.
CONFIG_CHECKSUMS = {
    "openai_whisper-small.en": "5cbba95e3fda213c33957ddcd76070270e0ae55f926909f332790a1824810219",
    "openai_whisper-medium.en": "5fa4b2586d5b59e76c83773754a893ec131cc15ff0cd08f0a216db4fbb06a313",
    "openai_whisper-large-v3": "798b69c08cf93b2b03d94bea6eb3eb25fd4712259712d8a62ed2483fdf818a9e",
}

# ---- Full directory fingerprints per model ----
# Computed by dir_fingerprint() over the entire model directory (all files,
# sorted by relative path, SHA256 accumulated). Covers actual model weights,
# not just metadata. Pin after first verified download.
MODEL_FINGERPRINTS = {
    "openai_whisper-small.en": "000e488ddff3413a3011ea6d087875d7d3a217608a32152243e1d14f60a0f95e",
    "openai_whisper-medium.en": "3bdacf4be35c6458c2dcf7fd28abdba80dde01a47b5e9c4714cb9bafee5c18e7",
    "openai_whisper-large-v3": "0ce9f6d2b76baaef383c8105c106f07f560f7b04385b899afe2e578d2ff0309a",
}

# Required files/directories that must exist in a valid model folder
REQUIRED_ENTRIES = [
    "config.json",
    "generation_config.json",
    "AudioEncoder.mlmodelc",
    "TextDecoder.mlmodelc",
    "MelSpectrogram.mlmodelc",
]

# Core model payload directories — must be non-empty directories
PAYLOAD_DIRS = [
    "AudioEncoder.mlmodelc",
    "TextDecoder.mlmodelc",
    "MelSpectrogram.mlmodelc",
]


def sha256_file(path):
    """Compute SHA256 of a file."""
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(8192), b""):
            h.update(chunk)
    return h.hexdigest()


def dir_fingerprint(model_dir):
    """Compute a stable fingerprint over all files in a model directory.

    Walks recursively, collects (relative_path, sha256) for every file,
    sorts by relative path, then feeds each pair into an accumulating SHA256.
    Deterministic regardless of filesystem walk order.
    """
    file_entries = []
    for dirpath, dirnames, filenames in os.walk(model_dir):
        dirnames.sort()
        for filename in sorted(filenames):
            filepath = os.path.join(dirpath, filename)
            relpath = os.path.relpath(filepath, model_dir)
            file_hash = sha256_file(filepath)
            file_entries.append((relpath, file_hash))

    file_entries.sort(key=lambda x: x[0])

    h = hashlib.sha256()
    for relpath, file_hash in file_entries:
        h.update(relpath.encode("utf-8"))
        h.update(b"\0")
        h.update(file_hash.encode("utf-8"))
        h.update(b"\0")

    return h.hexdigest()


def verify_model(model_dir, model_variant):
    """Verify a model directory is complete with valid payload.

    Checks (in order):
      1. All required entries exist.
      2. Payload directories are actual non-empty directories.
      3. config.json SHA256 matches pinned value.
      4. Directory fingerprint matches pinned value (if pinned).

    Returns True only if ALL checks pass.
    """
    if not os.path.isdir(model_dir):
        return False

    # 1. Required entries exist
    for entry in REQUIRED_ENTRIES:
        path = os.path.join(model_dir, entry)
        if not os.path.exists(path):
            print(f"  Missing: {entry}")
            return False

    # 2. Payload directories are non-empty directories (not stubs/files)
    for payload_dir in PAYLOAD_DIRS:
        dir_path = os.path.join(model_dir, payload_dir)
        if not os.path.isdir(dir_path):
            print(f"  Not a directory: {payload_dir}")
            return False
        if not os.listdir(dir_path):
            print(f"  Empty payload directory: {payload_dir}")
            return False

    # 3. config.json checksum (pinned in source)
    expected_config = CONFIG_CHECKSUMS.get(model_variant)
    if expected_config is not None:
        config_path = os.path.join(model_dir, "config.json")
        actual = sha256_file(config_path)
        if actual != expected_config:
            print(f"  CONFIG CHECKSUM MISMATCH: expected {expected_config[:16]}..., got {actual[:16]}...")
            return False

    # 4. Directory fingerprint (covers full payload)
    expected_fp = MODEL_FINGERPRINTS.get(model_variant)
    if expected_fp is not None:
        actual_fp = dir_fingerprint(model_dir)
        if actual_fp != expected_fp:
            print(f"  FINGERPRINT MISMATCH: expected {expected_fp[:16]}..., got {actual_fp[:16]}...")
            return False

    return True


def download_model(model_variant, output_dir):
    """Download a model variant from HuggingFace."""
    from huggingface_hub import snapshot_download

    print(f"  Downloading {model_variant} from {REPO_ID}...")

    local_dir = snapshot_download(
        repo_id=REPO_ID,
        revision=PINNED_REVISION,
        allow_patterns=[f"{model_variant}/**"],
        local_dir=os.path.join(OUTPUT_BASE, "_hf_cache"),
    )

    src = os.path.join(local_dir, model_variant)
    if not os.path.isdir(src):
        print(f"FATAL: Downloaded content missing {model_variant} directory.", file=sys.stderr)
        sys.exit(1)

    if os.path.exists(output_dir):
        shutil.rmtree(output_dir)
    shutil.copytree(src, output_dir)

    # Report config.json checksum
    config_path = os.path.join(output_dir, "config.json")
    if os.path.exists(config_path):
        checksum = sha256_file(config_path)
        print(f"  config.json SHA256: {checksum}")

    # Compute and report directory fingerprint for pinning
    fp = dir_fingerprint(output_dir)
    print(f"  Directory fingerprint: {fp}")

    # Report total size
    total_size = sum(
        os.path.getsize(os.path.join(dp, f))
        for dp, dn, filenames in os.walk(output_dir)
        for f in filenames
    )
    size_mb = total_size / 1024 / 1024
    print(f"  Saved: {output_dir} ({size_mb:.0f} MB)")


def main():
    parser = argparse.ArgumentParser(
        description="Download WhisperKit CoreML models for Shadow."
    )
    parser.add_argument(
        "--profile",
        choices=PROFILES.keys(),
        default="balanced",
        help="Model profile: fast (small.en), balanced (medium.en, default), accurate (large-v3)",
    )
    args = parser.parse_args()

    model_variant = PROFILES[args.profile]
    output_dir = os.path.join(OUTPUT_BASE, model_variant)

    print(f"Provisioning WhisperKit model for Shadow...")
    print(f"  Profile:  {args.profile}")
    print(f"  Model:    {model_variant}")
    print(f"  Source:   {REPO_ID}")
    print(f"  Output:   {output_dir}")

    os.makedirs(OUTPUT_BASE, exist_ok=True)

    # Verify existing model
    if verify_model(output_dir, model_variant):
        print(f"\nModel verified (all files present, checksum OK). Skipping download.")
        return

    # Download
    download_model(model_variant, output_dir)

    # Post-download verification (hard failure on any mismatch)
    if not verify_model(output_dir, model_variant):
        print(f"FATAL: Post-download verification failed for {model_variant}.", file=sys.stderr)
        print(f"  This may indicate a corrupted download or upstream revision change.", file=sys.stderr)
        print(f"  If the upstream repo has updated, re-pin PINNED_REVISION and CONFIG_CHECKSUMS.", file=sys.stderr)
        sys.exit(1)

    # Cleanup HF cache
    cache_dir = os.path.join(OUTPUT_BASE, "_hf_cache")
    if os.path.exists(cache_dir):
        shutil.rmtree(cache_dir)
        print("  Cleaned up download cache.")

    print(f"\nProvisioning complete.")
    print(f"  Model: {model_variant}")
    print(f"  Path:  {output_dir}")
    print(f"\nThe Shadow app will automatically detect this model on next launch.")



if __name__ == "__main__":
    main()
