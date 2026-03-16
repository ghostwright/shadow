#!/usr/bin/env python3
"""
Test CLIPTokenizer parity against open_clip reference token IDs.

Replicates the exact tokenization pipeline from CLIPTokenizer.swift:
  1. Lowercase + strip whitespace
  2. Regex pre-tokenize (open_clip SimpleTokenizer pattern)
  3. Byte-encode each word via byte_encoder mapping
  4. BPE merge using ranked merge pairs
  5. Encoder lookup for integer IDs
  6. Wrap with SOT/EOT, pad to context_length (77)

Usage:
  python3 scripts/test-tokenizer-parity.py
"""

import json
import re
import sys
import os

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
PROJECT_ROOT = os.path.dirname(SCRIPT_DIR)
TOKENIZER_PATH = os.path.join(
    PROJECT_ROOT,
    "Shadow", "Shadow", "Resources", "Models", "clip_tokenizer.json",
)

# open_clip SimpleTokenizer regex pattern (same as CLIPTokenizer.swift)
WORD_PATTERN = re.compile(
    r"'s|'t|'re|'ve|'m|'ll|'d|[a-zA-Z]+|[0-9]|[^\sa-zA-Z0-9]+"
)

# Reference tokenizations from open_clip SimpleTokenizer on MobileCLIP-S2.
# Each entry: (prompt, expected_non_pad_tokens)
# The full array is 77 elements: these tokens + zero-padding.
REFERENCE = [
    # --- Basic phrases ---
    ("a photo of a cat", [49406, 320, 1125, 539, 320, 2368, 49407]),
    ("person working at a computer", [49406, 2533, 1699, 536, 320, 11639, 652, 49407]),
    ("sunset over mountains", [49406, 3424, 962, 5873, 49407]),
    ("code editor with syntax highlighting", [49406, 3217, 7661, 593, 3758, 3879, 17344, 49407]),
    ("meeting in a conference room", [49406, 2071, 530, 320, 2230, 1530, 49407]),
    # --- Edge cases ---
    ("", [49406, 49407]),
    ("a", [49406, 320, 49407]),
    ("x", [49406, 343, 49407]),
    # --- Contractions ---
    ("it's a beautiful day", [49406, 585, 568, 320, 1215, 575, 49407]),
    ("I can't believe it's not butter", [49406, 328, 753, 713, 2649, 585, 568, 783, 6952, 49407]),
    ("they're working on it", [49406, 889, 982, 1699, 525, 585, 49407]),
    # --- Punctuation ---
    ("hello, world! how are you?", [49406, 3306, 267, 1002, 256, 829, 631, 592, 286, 49407]),
    ("email: user@example.com", [49406, 4462, 281, 7031, 287, 6228, 269, 2464, 49407]),
    ("!!!", [49406, 995, 49407]),
    # --- Numbers ---
    ("the year 2024 was interesting", [49406, 518, 935, 273, 271, 273, 275, 739, 3628, 49407]),
    ("3.14 is pi", [49406, 274, 269, 272, 275, 533, 5357, 49407]),
    # --- Mixed spacing and case ---
    ("  HELLO   World  ", [49406, 3306, 1002, 49407]),
    ("MacBook Pro 16-inch", [49406, 20617, 2630, 272, 277, 268, 6523, 49407]),
]

CONTEXT_LENGTH = 77


def load_tokenizer(path: str):
    """Load tokenizer data from clip_tokenizer.json."""
    with open(path, "r") as f:
        data = json.load(f)

    encoder = {k: int(v) for k, v in data["encoder"].items()}
    byte_encoder = {int(k): v for k, v in data["byte_encoder"].items()}

    # Build BPE rank dict: merge string -> rank (index)
    bpe_ranks = {}
    for i, merge in enumerate(data["merges"]):
        bpe_ranks[merge] = i

    sot_token = int(data["sot_token"])
    eot_token = int(data["eot_token"])
    context_length = int(data["context_length"])

    return encoder, byte_encoder, bpe_ranks, sot_token, eot_token, context_length


def byte_encode(word: str, byte_encoder: dict) -> str:
    """Encode a word's UTF-8 bytes using the byte encoder mapping.

    Mirrors CLIPTokenizer.swift's byteEncode().
    """
    utf8_bytes = word.encode("utf-8")
    return "".join(byte_encoder.get(b, "") for b in utf8_bytes)


def bpe(token: str, bpe_ranks: dict) -> list:
    """Apply byte-pair encoding to a byte-encoded word.

    Mirrors CLIPTokenizer.swift's bpe() exactly:
    - Split token into individual characters
    - Append </w> to the last character
    - Iteratively merge the lowest-ranked pair across all positions
    - Return the final subword list

    Returns a list of subword strings.
    """
    if not token:
        return []

    word = list(token)

    if len(word) <= 1:
        return [word[0] + "</w>"]

    # Append </w> to last character (word boundary marker)
    word[-1] = word[-1] + "</w>"

    while len(word) > 1:
        # Find the pair with lowest BPE rank
        best_rank = float("inf")
        best_index = -1

        for i in range(len(word) - 1):
            pair = f"{word[i]} {word[i + 1]}"
            rank = bpe_ranks.get(pair)
            if rank is not None and rank < best_rank:
                best_rank = rank
                best_index = i

        if best_index < 0:
            break

        # Merge at the best position and all subsequent occurrences
        first = word[best_index]
        second = word[best_index + 1]
        merged = first + second

        new_word = []
        i = 0
        while i < len(word):
            if i < len(word) - 1 and word[i] == first and word[i + 1] == second:
                new_word.append(merged)
                i += 2
            else:
                new_word.append(word[i])
                i += 1
        word = new_word

    return word


def tokenize(text: str, encoder, byte_encoder, bpe_ranks, sot_token, eot_token, context_length):
    """Tokenize a text string, mirroring CLIPTokenizer.swift's tokenize().

    Returns a list of int32 token IDs, padded to context_length.
    """
    cleaned = text.lower().strip()

    # Pre-tokenize using regex
    words = WORD_PATTERN.findall(cleaned)

    tokens = [sot_token]

    for word in words:
        # Byte-encode the word
        byte_encoded = byte_encode(word, byte_encoder)
        if not byte_encoded:
            continue

        # Apply BPE
        bpe_tokens = bpe(byte_encoded, bpe_ranks)

        # Look up token IDs
        for tok in bpe_tokens:
            token_id = encoder.get(tok)
            if token_id is not None:
                tokens.append(token_id)

        # Respect context length (leave room for EOT)
        if len(tokens) >= context_length - 1:
            break

    # Truncate if needed
    if len(tokens) > context_length - 1:
        tokens = tokens[: context_length - 1]

    tokens.append(eot_token)

    # Pad to context_length
    while len(tokens) < context_length:
        tokens.append(0)

    return tokens


def main():
    # --- Load tokenizer ---
    if not os.path.exists(TOKENIZER_PATH):
        print(f"FAIL: Tokenizer file not found at {TOKENIZER_PATH}")
        sys.exit(1)

    print(f"Loading tokenizer from {TOKENIZER_PATH}")
    encoder, byte_encoder, bpe_ranks, sot_token, eot_token, context_length = load_tokenizer(
        TOKENIZER_PATH
    )
    print(
        f"  model vocab={len(encoder)}, merges={len(bpe_ranks)}, "
        f"context_length={context_length}, SOT={sot_token}, EOT={eot_token}"
    )
    print()

    assert context_length == CONTEXT_LENGTH, (
        f"Expected context_length={CONTEXT_LENGTH}, got {context_length}"
    )

    # --- Run parity tests against reference token IDs ---
    print("=" * 70)
    print("Parity test: our tokenizer vs. open_clip reference token IDs")
    print("=" * 70)

    all_passed = True

    for prompt, expected_prefix in REFERENCE:
        display = repr(prompt) if prompt else '""'

        result = tokenize(prompt, encoder, byte_encoder, bpe_ranks, sot_token, eot_token, context_length)
        assert len(result) == CONTEXT_LENGTH, f"Length mismatch: {len(result)} != {CONTEXT_LENGTH}"

        # Build expected full array (prefix + zero padding)
        expected_full = expected_prefix + [0] * (CONTEXT_LENGTH - len(expected_prefix))

        if result == expected_full:
            print(f"  PASS  {display}")
            # Show the non-pad tokens for clarity
            non_pad = [t for t in result if t != 0 or t == result[-1]]
            actual_prefix = result[: len(expected_prefix)]
            print(f"        tokens: {actual_prefix}")
        else:
            print(f"  FAIL  {display}")
            # Find first mismatch
            actual_prefix = result[: len(expected_prefix)]
            print(f"        expected: {expected_prefix}")
            print(f"        got:      {actual_prefix}")
            # Show full diff for non-zero tokens
            actual_nonzero = [t for t in result if t != 0]
            expected_nonzero = [t for t in expected_full if t != 0]
            if actual_nonzero != expected_nonzero:
                print(f"        expected (non-zero): {expected_nonzero}")
                print(f"        got      (non-zero): {actual_nonzero}")
            all_passed = False

    print()

    # --- Optional: compare against open_clip if installed ---
    print("=" * 70)
    print("Optional: cross-check against open_clip (if installed)")
    print("=" * 70)

    try:
        import open_clip

        oc_tokenizer = open_clip.get_tokenizer("MobileCLIP-S2")
        print("  open_clip tokenizer loaded (MobileCLIP-S2 SimpleTokenizer)")

        for prompt, expected_prefix in REFERENCE:
            display = repr(prompt) if prompt else '""'
            oc_tokens = oc_tokenizer(prompt).squeeze().tolist()
            our_tokens = tokenize(
                prompt, encoder, byte_encoder, bpe_ranks, sot_token, eot_token, context_length
            )

            if oc_tokens == our_tokens:
                print(f"  MATCH  {display}")
            else:
                print(f"  DIFF   {display}")
                oc_nonzero = [t for t in oc_tokens if t != 0]
                our_nonzero = [t for t in our_tokens if t != 0]
                print(f"         open_clip: {oc_nonzero}")
                print(f"         ours:      {our_nonzero}")
                all_passed = False

    except ImportError:
        print("  open_clip not installed, skipping cross-check.")
        print("  Install with: pip install open_clip_torch")

    # --- Summary ---
    print()
    print("=" * 70)
    if all_passed:
        print("RESULT: ALL TESTS PASSED")
    else:
        print("RESULT: SOME TESTS FAILED")
    print("=" * 70)

    sys.exit(0 if all_passed else 1)


if __name__ == "__main__":
    main()
