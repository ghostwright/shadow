#!/usr/bin/env python3
"""
Download pre-exported MobileCLIP-S2 CoreML models from apple/coreml-mobileclip.

Produces:
  Shadow/Shadow/Resources/Models/MobileCLIPImageEncoder.mlpackage/
  Shadow/Shadow/Resources/Models/MobileCLIPTextEncoder.mlpackage/
  Shadow/Shadow/Resources/Models/clip_tokenizer.json

Source: https://huggingface.co/apple/coreml-mobileclip
Model: MobileCLIP-S2 (512-dim embeddings, 256x256 input, context length 77)

Pinned to a specific HuggingFace revision with SHA256 checksums on weight files.
Idempotent: verifies existing assets against checksums before skipping.

Usage:
  python3 scripts/provision-clip-models.py

Requirements:
  pip3 install huggingface_hub open_clip_torch
"""

import hashlib
import json
import os
import shutil
import sys

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
PROJECT_ROOT = os.path.dirname(SCRIPT_DIR)
OUTPUT_DIR = os.path.join(PROJECT_ROOT, "Shadow", "Shadow", "Resources", "Models")

# ---- Pinned source ----
REPO_ID = "apple/coreml-mobileclip"
PINNED_REVISION = "3e0a7bfb9fe83da8a3efaa3fd8f7df24214bb947"

# HuggingFace paths within the repo
IMAGE_PKG_SRC = "mobileclip_s2_image.mlpackage"
TEXT_PKG_SRC = "mobileclip_s2_text.mlpackage"

# Local output names
IMAGE_OUT = "MobileCLIPImageEncoder.mlpackage"
TEXT_OUT = "MobileCLIPTextEncoder.mlpackage"
TOKENIZER_OUT = "clip_tokenizer.json"

CONTEXT_LENGTH = 77

# ---- SHA256 checksums (pinned) ----
# These are verified against the actual weight.bin files inside each mlpackage.
CHECKSUMS = {
    "image_weight": "6cbc7fb06b6072c1cae9c4496d67e0e6217adbf726dfeb82e44d4efe87c34c00",
    "image_model": "2aeb3359f6cde65e9f9248ec2a742e9939bd4bbf48c2f55fcd255b4504d96a1b",
    "text_weight": "8e8d5454f104b6cbb58d98bf11e038ff1f1943599efea111260a832f094cd0ce",
    "text_model": "b8651b6d030bae419a9548b41c8fae11f96b59cfa21b6e532a4c4434522b4b80",
    "tokenizer": "2c232cae4986581f1dc52e709f6ec2a8a58a4d8610065771aff0b9babbc62a25",
}


def sha256_file(path):
    """Compute SHA256 of a file."""
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(8192), b""):
            h.update(chunk)
    return h.hexdigest()


def verify_mlpackage(output_path, weight_checksum, model_checksum):
    """Verify an mlpackage directory exists and matches expected checksums.
    Returns True if valid, False otherwise."""
    if not os.path.isdir(output_path):
        return False

    weight_path = os.path.join(
        output_path, "Data", "com.apple.CoreML", "weights", "weight.bin"
    )
    model_path = os.path.join(
        output_path, "Data", "com.apple.CoreML", "model.mlmodel"
    )
    manifest_path = os.path.join(output_path, "Manifest.json")

    if not all(os.path.exists(p) for p in [weight_path, model_path, manifest_path]):
        return False

    actual_weight = sha256_file(weight_path)
    if actual_weight != weight_checksum:
        print(f"  CHECKSUM MISMATCH (weight): expected {weight_checksum[:16]}..., got {actual_weight[:16]}...")
        return False

    actual_model = sha256_file(model_path)
    if actual_model != model_checksum:
        print(f"  CHECKSUM MISMATCH (model): expected {model_checksum[:16]}..., got {actual_model[:16]}...")
        return False

    return True


def download_mlpackage(repo_id, revision, pkg_name, output_path):
    """Download an mlpackage directory from HuggingFace at a pinned revision."""
    from huggingface_hub import snapshot_download

    print(f"  Downloading {pkg_name} @ {revision[:12]}...")

    local_dir = snapshot_download(
        repo_id=repo_id,
        revision=revision,
        allow_patterns=[f"{pkg_name}/**"],
        local_dir=os.path.join(OUTPUT_DIR, "_hf_cache"),
    )

    src = os.path.join(local_dir, pkg_name)
    if os.path.exists(output_path):
        shutil.rmtree(output_path)
    shutil.copytree(src, output_path)

    weight_path = os.path.join(
        output_path, "Data", "com.apple.CoreML", "weights", "weight.bin"
    )
    if os.path.exists(weight_path):
        size_mb = os.path.getsize(weight_path) / 1024 / 1024
        checksum = sha256_file(weight_path)
        print(f"  Saved: {output_path} ({size_mb:.1f} MB, sha256: {checksum[:16]}...)")


def export_tokenizer(output_path):
    """Export the CLIP tokenizer vocab and merges to a JSON file.
    Uses open_clip's built-in SimpleTokenizer which is model-aligned."""
    import open_clip

    print("  Exporting tokenizer from open_clip (model-aligned)...")

    # Load the model to ensure tokenizer matches MobileCLIP-S2
    _ = open_clip.get_tokenizer("MobileCLIP-S2")

    # Access the global SimpleTokenizer instance
    st = open_clip.tokenizer._tokenizer

    bpe_ranks = st.bpe_ranks
    merges = []
    for (a, b), rank in sorted(bpe_ranks.items(), key=lambda x: x[1]):
        merges.append(f"{a} {b}")

    encoder = st.encoder
    byte_encoder = st.byte_encoder

    tokenizer_data = {
        "model_id": "mobileclip-s2",
        "source_revision": PINNED_REVISION,
        "vocab_size": len(encoder),
        "context_length": CONTEXT_LENGTH,
        "sot_token": 49406,
        "eot_token": 49407,
        "encoder": encoder,
        "byte_encoder": {str(k): v for k, v in byte_encoder.items()},
        "merges": merges,
    }

    with open(output_path, "w") as f:
        json.dump(tokenizer_data, f)

    size_kb = os.path.getsize(output_path) / 1024
    print(f"  Tokenizer exported: {output_path} ({size_kb:.0f} KB)")


def main():
    print(f"Provisioning MobileCLIP-S2 CoreML models for Shadow...")
    print(f"  Source: {REPO_ID} @ {PINNED_REVISION[:12]}")
    os.makedirs(OUTPUT_DIR, exist_ok=True)

    image_path = os.path.join(OUTPUT_DIR, IMAGE_OUT)
    text_path = os.path.join(OUTPUT_DIR, TEXT_OUT)
    tokenizer_path = os.path.join(OUTPUT_DIR, TOKENIZER_OUT)

    # Verify existing assets against checksums
    image_ok = verify_mlpackage(
        image_path, CHECKSUMS["image_weight"], CHECKSUMS["image_model"]
    )
    text_ok = verify_mlpackage(
        text_path, CHECKSUMS["text_weight"], CHECKSUMS["text_model"]
    )
    tokenizer_ok = (
        os.path.exists(tokenizer_path)
        and sha256_file(tokenizer_path) == CHECKSUMS["tokenizer"]
    )

    if image_ok and text_ok and tokenizer_ok:
        print("All assets verified (checksums match). Skipping download.")
        return

    # Download missing or mismatched assets
    if not image_ok:
        download_mlpackage(REPO_ID, PINNED_REVISION, IMAGE_PKG_SRC, image_path)
        if not verify_mlpackage(image_path, CHECKSUMS["image_weight"], CHECKSUMS["image_model"]):
            print("FATAL: Image encoder checksum mismatch after download.", file=sys.stderr)
            sys.exit(1)
    else:
        print(f"  Image encoder verified: {image_path}")

    if not text_ok:
        download_mlpackage(REPO_ID, PINNED_REVISION, TEXT_PKG_SRC, text_path)
        if not verify_mlpackage(text_path, CHECKSUMS["text_weight"], CHECKSUMS["text_model"]):
            print("FATAL: Text encoder checksum mismatch after download.", file=sys.stderr)
            sys.exit(1)
    else:
        print(f"  Text encoder verified: {text_path}")

    if not tokenizer_ok:
        export_tokenizer(tokenizer_path)
        actual = sha256_file(tokenizer_path)
        if actual != CHECKSUMS["tokenizer"]:
            print(
                f"FATAL: Tokenizer checksum mismatch after export.\n"
                f"  Expected: {CHECKSUMS['tokenizer']}\n"
                f"  Got:      {actual}\n"
                f"  Remediation: If open_clip was upgraded, run:\n"
                f"    python3 scripts/test-tokenizer-parity.py\n"
                f"  If parity passes, update CHECKSUMS['tokenizer'] in this script.",
                file=sys.stderr,
            )
            sys.exit(1)
    else:
        print(f"  Tokenizer verified: {tokenizer_path}")

    # Cleanup HF cache
    cache_dir = os.path.join(OUTPUT_DIR, "_hf_cache")
    if os.path.exists(cache_dir):
        shutil.rmtree(cache_dir)
        print("  Cleaned up download cache.")

    print("\nProvisioning complete. Assets:")
    print(f"  {IMAGE_OUT} (image encoder)")
    print(f"  {TEXT_OUT} (text encoder)")
    print(f"  {TOKENIZER_OUT} (BPE tokenizer)")
    print(f"\nNext: cd Shadow && xcodegen generate")


if __name__ == "__main__":
    main()
