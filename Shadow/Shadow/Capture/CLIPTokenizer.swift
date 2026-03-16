import Foundation
import os.log

private let logger = Logger(subsystem: "com.shadow.app", category: "CLIPTokenizer")

/// BPE tokenizer for CLIP text encoding, loaded from clip_tokenizer.json.
///
/// Implements the same byte-pair encoding algorithm as OpenAI's SimpleTokenizer:
/// 1. Lowercase + strip whitespace (ftfy normalization skipped — search queries are ASCII-clean)
/// 2. Regex pre-tokenization into word tokens (matches open_clip's pattern)
/// 3. Byte-encode each word using the byte encoder mapping
/// 4. Apply BPE merges iteratively to produce subword tokens
/// 5. Map token strings to integer IDs via the encoder vocabulary
/// 6. Wrap with SOT/EOT tokens and pad to contextLength
///
/// Parity verified against open_clip's SimpleTokenizer on a fixed prompt set.
///
/// Thread-safe: all state is immutable after init.
final class CLIPTokenizer: Sendable {
    let contextLength: Int
    let sotToken: Int32
    let eotToken: Int32
    let modelId: String

    private let encoder: [String: Int32]
    private let byteEncoder: [UInt8: Character]
    private let bpeRanks: [String: Int]

    /// Regex pattern matching open_clip's SimpleTokenizer:
    /// Captures: contractions ('s, 't, etc.), letter sequences, digit sequences, punctuation clusters.
    /// This is the same as OpenAI CLIP's tokenizer pattern.
    private static let wordPattern: NSRegularExpression = {
        // Matches open_clip's pattern: 's|'t|'re|'ve|'m|'ll|'d|[a-zA-Z]+|[0-9]|[^\sa-zA-Z0-9]+
        // We omit <start_of_text>|<end_of_text> since those are special tokens handled separately.
        let pattern = #"'s|'t|'re|'ve|'m|'ll|'d|[a-zA-Z]+|[0-9]|[^\sa-zA-Z0-9]+"#
        return try! NSRegularExpression(pattern: pattern)
    }()

    /// Load tokenizer from a JSON file exported by provision-clip-models.py.
    init?(url: URL) {
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            logger.error("Failed to load tokenizer from \(url.path)")
            return nil
        }

        guard let modelId = json["model_id"] as? String,
              let contextLength = json["context_length"] as? Int,
              let sotToken = json["sot_token"] as? Int,
              let eotToken = json["eot_token"] as? Int,
              let encoderDict = json["encoder"] as? [String: Int],
              let byteEncoderDict = json["byte_encoder"] as? [String: String],
              let mergesArray = json["merges"] as? [String]
        else {
            logger.error("Tokenizer JSON missing required fields")
            return nil
        }

        self.modelId = modelId
        self.contextLength = contextLength
        self.sotToken = Int32(sotToken)
        self.eotToken = Int32(eotToken)

        var enc: [String: Int32] = [:]
        enc.reserveCapacity(encoderDict.count)
        for (k, v) in encoderDict {
            enc[k] = Int32(v)
        }
        self.encoder = enc

        var be: [UInt8: Character] = [:]
        for (k, v) in byteEncoderDict {
            if let byteVal = UInt8(k), let char = v.first {
                be[byteVal] = char
            }
        }
        self.byteEncoder = be

        var ranks: [String: Int] = [:]
        ranks.reserveCapacity(mergesArray.count)
        for (i, merge) in mergesArray.enumerated() {
            ranks[merge] = i
        }
        self.bpeRanks = ranks

        logger.info("Tokenizer loaded: \(modelId), vocab=\(enc.count), merges=\(ranks.count)")
    }

    /// Tokenize a text string into a padded Int32 array of length contextLength.
    /// Returns [SOT, token1, token2, ..., EOT, 0, 0, ...] padded to contextLength.
    func tokenize(_ text: String) -> [Int32] {
        let cleaned = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)

        // Pre-tokenize using regex (matches open_clip's word splitting)
        let words = regexSplit(cleaned)

        var tokens: [Int32] = [sotToken]

        for word in words {
            // Byte-encode the word
            let byteEncoded = byteEncode(word)
            guard !byteEncoded.isEmpty else { continue }

            // Apply BPE
            let bpeTokens = bpe(byteEncoded)

            // Look up token IDs
            for token in bpeTokens {
                if let id = encoder[token] {
                    tokens.append(id)
                }
            }

            // Respect context length (leave room for EOT)
            if tokens.count >= contextLength - 1 {
                break
            }
        }

        // Truncate if needed
        if tokens.count > contextLength - 1 {
            tokens = Array(tokens.prefix(contextLength - 1))
        }

        tokens.append(eotToken)

        // Pad to contextLength
        while tokens.count < contextLength {
            tokens.append(0)
        }

        return tokens
    }

    // MARK: - Pre-tokenization

    /// Split text into words using the CLIP regex pattern.
    private func regexSplit(_ text: String) -> [String] {
        let nsRange = NSRange(text.startIndex..., in: text)
        let matches = Self.wordPattern.matches(in: text, range: nsRange)
        return matches.compactMap { match in
            Range(match.range, in: text).map { String(text[$0]) }
        }
    }

    // MARK: - BPE Implementation

    /// Encode a word's bytes using the byte encoder mapping.
    private func byteEncode(_ word: String) -> String {
        let utf8 = Array(word.utf8)
        return String(utf8.compactMap { byteEncoder[$0] })
    }

    /// Apply byte-pair encoding to a word, returning subword tokens.
    private func bpe(_ token: String) -> [String] {
        if token.isEmpty { return [] }

        var word = Array(token).map { String($0) }

        if word.count <= 1 {
            return [word[0] + "</w>"]
        }

        // Append </w> to last character (word boundary marker)
        word[word.count - 1] = word[word.count - 1] + "</w>"

        while word.count > 1 {
            // Find the pair with lowest BPE rank
            var bestRank = Int.max
            var bestIndex = -1

            for i in 0..<(word.count - 1) {
                let pair = "\(word[i]) \(word[i + 1])"
                if let rank = bpeRanks[pair], rank < bestRank {
                    bestRank = rank
                    bestIndex = i
                }
            }

            guard bestIndex >= 0 else { break }

            // Merge at the best position and all subsequent occurrences of the same pair
            let first = word[bestIndex]
            let second = word[bestIndex + 1]
            let merged = first + second

            var newWord: [String] = []
            var i = 0
            while i < word.count {
                if i < word.count - 1 && word[i] == first && word[i + 1] == second {
                    newWord.append(merged)
                    i += 2
                } else {
                    newWord.append(word[i])
                    i += 1
                }
            }
            word = newWord
        }

        return word
    }
}
