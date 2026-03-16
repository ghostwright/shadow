import XCTest
@testable import Shadow

final class InputSynthesizerTests: XCTestCase {

    // MARK: - Event Tagging

    /// The shadow event tag is the expected hex value.
    func testShadowEventTag() {
        XCTAssertEqual(InputSynthesizer.shadowEventTag, 0x5348_4457)
        // "SHDW" in ASCII: S=0x53, H=0x48, D=0x44, W=0x57
    }

    /// InputMonitor's tag matches InputSynthesizer's tag.
    func testTagMatchesInputMonitor() {
        XCTAssertEqual(
            InputSynthesizer.shadowEventTag,
            InputMonitor.shadowSynthesizedEventTag,
            "InputSynthesizer and InputMonitor must use the same event tag"
        )
    }

    // MARK: - Key Code Mapping

    /// All letter keys map to valid key codes.
    func testLetterKeyCodes() {
        let letters = "abcdefghijklmnopqrstuvwxyz"
        for char in letters {
            let code = InputSynthesizer.keyCodeForName(String(char))
            XCTAssertNotNil(code, "Missing key code for '\(char)'")
        }
    }

    /// All digit keys map to valid key codes.
    func testDigitKeyCodes() {
        for digit in 0...9 {
            let code = InputSynthesizer.keyCodeForName(String(digit))
            XCTAssertNotNil(code, "Missing key code for '\(digit)'")
        }
    }

    /// Special keys have expected key codes.
    func testSpecialKeyCodes() {
        XCTAssertEqual(InputSynthesizer.keyCodeForName("return"), 36)
        XCTAssertEqual(InputSynthesizer.keyCodeForName("enter"), 36)
        XCTAssertEqual(InputSynthesizer.keyCodeForName("tab"), 48)
        XCTAssertEqual(InputSynthesizer.keyCodeForName("space"), 49)
        XCTAssertEqual(InputSynthesizer.keyCodeForName("delete"), 51)
        XCTAssertEqual(InputSynthesizer.keyCodeForName("escape"), 53)
    }

    /// Arrow keys have expected key codes.
    func testArrowKeyCodes() {
        XCTAssertEqual(InputSynthesizer.keyCodeForName("up"), 126)
        XCTAssertEqual(InputSynthesizer.keyCodeForName("down"), 125)
        XCTAssertEqual(InputSynthesizer.keyCodeForName("left"), 123)
        XCTAssertEqual(InputSynthesizer.keyCodeForName("right"), 124)
    }

    /// Function keys F1-F12 have valid codes.
    func testFunctionKeyCodes() {
        let functionKeys = ["f1", "f2", "f3", "f4", "f5", "f6",
                            "f7", "f8", "f9", "f10", "f11", "f12"]
        for key in functionKeys {
            let code = InputSynthesizer.keyCodeForName(key)
            XCTAssertNotNil(code, "Missing key code for '\(key)'")
        }
    }

    /// Unknown key names return nil.
    func testUnknownKeyCode() {
        XCTAssertNil(InputSynthesizer.keyCodeForName("nonexistent"))
        XCTAssertNil(InputSynthesizer.keyCodeForName(""))
        XCTAssertNil(InputSynthesizer.keyCodeForName("cmd"))  // modifier, not a key
    }

    /// Punctuation keys have codes.
    func testPunctuationKeyCodes() {
        let punctuation = ["-", "=", "[", "]", "\\", ";", "'", ",", ".", "/", "`"]
        for key in punctuation {
            let code = InputSynthesizer.keyCodeForName(key)
            XCTAssertNotNil(code, "Missing key code for '\(key)'")
        }
    }

    // MARK: - Key Code Coverage

    /// No duplicate key codes (each key name maps to a unique code).
    func testNoAmbiguousKeyCodes() {
        // "return" and "enter" are intentionally the same (36)
        // All other keys should have unique codes
        let testKeys = "abcdefghijklmnopqrstuvwxyz".map { String($0) }
            + (0...9).map { String($0) }
            + ["tab", "space", "delete", "escape", "up", "down", "left", "right"]

        var seen: [CGKeyCode: String] = [:]
        for key in testKeys {
            guard let code = InputSynthesizer.keyCodeForName(key) else { continue }
            if let existing = seen[code] {
                XCTFail("Key '\(key)' has same code \(code) as '\(existing)'")
            }
            seen[code] = key
        }
    }
}
