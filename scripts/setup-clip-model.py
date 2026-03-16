#!/usr/bin/env python3
"""
Download MobileCLIP-S2 and convert to CoreML for Shadow's vector search lane.

Produces:
  Shadow/Shadow/Resources/Models/MobileCLIPImageEncoder.mlpackage
  Shadow/Shadow/Resources/Models/MobileCLIPTextEncoder.mlpackage
  Shadow/Shadow/Resources/Models/clip_tokenizer.json

Usage:
  python3 scripts/setup-clip-model.py

Requirements:
  pip3 install coremltools torch open_clip_torch
"""

import json
import os
import sys

import coremltools as ct
import numpy as np
import open_clip
import torch

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
PROJECT_ROOT = os.path.dirname(SCRIPT_DIR)
OUTPUT_DIR = os.path.join(PROJECT_ROOT, "Shadow", "Shadow", "Resources", "Models")

# MobileCLIP-S2 via open_clip (MobileCLIP-S0 does not exist in open_clip v3.2+)
MODEL_NAME = "MobileCLIP-S2"
PRETRAINED = "datacompdr"
IMAGE_SIZE = 256
EMBED_DIM = 512
CONTEXT_LENGTH = 77


def export_tokenizer(tokenizer, output_path):
    """Export the CLIP tokenizer vocab and merges to a JSON file."""
    from open_clip.tokenizer import SimpleTokenizer

    if not isinstance(tokenizer, SimpleTokenizer):
        print(f"  Tokenizer type: {type(tokenizer).__name__}")

    # Get the SimpleTokenizer instance
    st = open_clip.tokenizer._tokenizer

    # Export byte encoder/decoder
    byte_encoder = st.byte_encoder

    # Export BPE ranks (merges)
    bpe_ranks = st.bpe_ranks
    merges = []
    for (a, b), rank in sorted(bpe_ranks.items(), key=lambda x: x[1]):
        merges.append(f"{a} {b}")

    # Export encoder (token -> id)
    encoder = st.encoder

    tokenizer_data = {
        "model_id": "mobileclip-s2",
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


def export_image_encoder(model, output_path):
    """Export the CLIP image encoder to CoreML."""
    print("  Tracing image encoder...")
    model.eval()

    visual = model.visual
    visual.eval()

    dummy_image = torch.randn(1, 3, IMAGE_SIZE, IMAGE_SIZE)

    class ImageEncoderWrapper(torch.nn.Module):
        def __init__(self, visual_model):
            super().__init__()
            self.visual = visual_model

        def forward(self, image):
            features = self.visual(image)
            # L2 normalize
            features = features / features.norm(dim=-1, keepdim=True)
            return features

    wrapper = ImageEncoderWrapper(visual)
    wrapper.eval()

    with torch.no_grad():
        traced = torch.jit.trace(wrapper, dummy_image)

    print("  Converting to CoreML...")
    mlmodel = ct.convert(
        traced,
        inputs=[
            ct.ImageType(
                name="image",
                shape=(1, 3, IMAGE_SIZE, IMAGE_SIZE),
                scale=1.0 / 255.0,
                color_layout="RGB",
                bias=[-0.485 / 0.229, -0.456 / 0.224, -0.406 / 0.225],
            )
        ],
        outputs=[ct.TensorType(name="embedding", dtype=np.float32)],
        minimum_deployment_target=ct.target.macOS14,
        compute_precision=ct.precision.FLOAT32,
    )

    mlmodel.author = "Shadow"
    mlmodel.short_description = "MobileCLIP-S2 image encoder (512-dim, L2-normalized)"
    mlmodel.save(output_path)
    print(f"  Image encoder saved: {output_path}")


def export_text_encoder(model, output_path):
    """Export the CLIP text encoder to CoreML."""
    print("  Tracing text encoder...")
    model.eval()

    # MobileCLIP-S2 uses CustomTextCLIP: text encoder is at model.text, not model directly
    text_model = model.text if hasattr(model, "text") else model

    class TextEncoderWrapper(torch.nn.Module):
        def __init__(self, text_module):
            super().__init__()
            self.token_embedding = text_module.token_embedding
            self.positional_embedding = text_module.positional_embedding
            self.transformer = text_module.transformer
            self.ln_final = text_module.ln_final
            self.text_projection = text_module.text_projection
            self.attn_mask = text_module.attn_mask

        def forward(self, text_tokens):
            x = self.token_embedding(text_tokens)
            x = x + self.positional_embedding
            x = x.permute(1, 0, 2)  # NLD -> LND
            x = self.transformer(x, attn_mask=self.attn_mask)
            x = x.permute(1, 0, 2)  # LND -> NLD
            x = self.ln_final(x)
            # Take features from EOT token (argmax of token IDs = EOT position)
            x = x[torch.arange(x.shape[0]), text_tokens.argmax(dim=-1)]
            if self.text_projection is not None:
                x = x @ self.text_projection
            # L2 normalize
            x = x / x.norm(dim=-1, keepdim=True)
            return x

    wrapper = TextEncoderWrapper(text_model)
    wrapper.eval()

    dummy_tokens = torch.zeros(1, CONTEXT_LENGTH, dtype=torch.long)
    dummy_tokens[0, 0] = 49406  # SOT
    dummy_tokens[0, 1] = 49407  # EOT

    # Disable native MHA fastpath — coremltools can't convert _native_multi_head_attention.
    # Monkey-patch nn.MultiheadAttention to force the SDPA path (decomposed ops) instead.
    _orig_mha_forward = torch.nn.MultiheadAttention.forward

    def _patched_mha_forward(self, query, key, value, key_padding_mask=None,
                             need_weights=True, attn_mask=None,
                             average_attn_weights=True, is_causal=False):
        # Force need_weights=True to skip native fast path
        return _orig_mha_forward(
            self, query, key, value,
            key_padding_mask=key_padding_mask,
            need_weights=True,
            attn_mask=attn_mask,
            average_attn_weights=average_attn_weights,
            is_causal=is_causal,
        )

    torch.nn.MultiheadAttention.forward = _patched_mha_forward

    try:
        with torch.no_grad():
            traced = torch.jit.trace(wrapper, dummy_tokens)
    finally:
        torch.nn.MultiheadAttention.forward = _orig_mha_forward

    print("  Converting to CoreML...")
    mlmodel = ct.convert(
        traced,
        inputs=[
            ct.TensorType(
                name="input_ids", shape=(1, CONTEXT_LENGTH), dtype=np.int32
            )
        ],
        outputs=[ct.TensorType(name="embedding", dtype=np.float32)],
        minimum_deployment_target=ct.target.macOS14,
        compute_precision=ct.precision.FLOAT32,
    )

    mlmodel.author = "Shadow"
    mlmodel.short_description = "MobileCLIP-S2 text encoder (512-dim, L2-normalized)"
    mlmodel.save(output_path)
    print(f"  Text encoder saved: {output_path}")


def main():
    print(f"Setting up MobileCLIP-S2 for Shadow...")
    os.makedirs(OUTPUT_DIR, exist_ok=True)

    # Load model
    print(f"Loading {MODEL_NAME} ({PRETRAINED})...")
    model, _, preprocess = open_clip.create_model_and_transforms(
        MODEL_NAME, pretrained=PRETRAINED
    )
    tokenizer = open_clip.get_tokenizer(MODEL_NAME)

    # Export tokenizer
    print("Exporting tokenizer...")
    tokenizer_path = os.path.join(OUTPUT_DIR, "clip_tokenizer.json")
    export_tokenizer(tokenizer, tokenizer_path)

    # Export image encoder
    print("Exporting image encoder...")
    image_encoder_path = os.path.join(OUTPUT_DIR, "MobileCLIPImageEncoder.mlpackage")
    export_image_encoder(model, image_encoder_path)

    # Export text encoder
    print("Exporting text encoder...")
    text_encoder_path = os.path.join(OUTPUT_DIR, "MobileCLIPTextEncoder.mlpackage")
    export_text_encoder(model, text_encoder_path)

    print("\nDone! Models saved to:")
    print(f"  {OUTPUT_DIR}/")
    print(f"  - MobileCLIPImageEncoder.mlpackage")
    print(f"  - MobileCLIPTextEncoder.mlpackage")
    print(f"  - clip_tokenizer.json")
    print(
        "\nNext: run `cd Shadow && xcodegen generate` to include models in the build."
    )


if __name__ == "__main__":
    main()
