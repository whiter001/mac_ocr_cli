import Foundation
import Testing
import Vision
@testable import MacOCRCore

@Suite("CLIParser")
struct CLIParserTests {
    @Test("Empty arguments throws .missingImagePath")
    func emptyArgumentsThrowsMissingImagePath() {
        #expect(throws: CLIError.missingImagePath) {
            _ = try CLIParser.parse([])
        }
    }

    @Test("--help and -h throw .helpRequested")
    func helpThrowsHelpRequested() {
        #expect(throws: CLIError.helpRequested) { _ = try CLIParser.parse(["--help"]) }
        #expect(throws: CLIError.helpRequested) { _ = try CLIParser.parse(["-h"]) }
    }

    @Test("--version throws .versionRequested")
    func versionThrowsVersionRequested() {
        #expect(throws: CLIError.versionRequested) { _ = try CLIParser.parse(["--version"]) }
    }

    @Test("Minimal invocation uses defaults")
    func defaultsForMinimalInvocation() throws {
        let opts = try CLIParser.parse(["photo.png"])
        #expect(opts.imageURLs.map(\.lastPathComponent) == ["photo.png"])
        #expect(opts.languages == ["zh-Hans", "zh-Hant", "en-US"])
        #expect(opts.level == .accurate)
        #expect(opts.languageCorrection == true)
        #expect(opts.outputMode == .text)
        #expect(opts.outputPath == nil)
        #expect(opts.keyword == nil)
    }

    @Test("--cjk expands to CJK preset")
    func cjkPresetExpands() throws {
        let opts = try CLIParser.parse(["x.png", "--cjk"])
        #expect(opts.languages == ["zh-Hans", "zh-Hant", "zh-HK", "en-US"])
    }

    @Test("--cjk combined with --lang throws")
    func cjkAndLangConflict() {
        #expect(throws: CLIError.conflictingLanguageAndCJK) {
            _ = try CLIParser.parse(["x.png", "--cjk", "-l", "en-US"])
        }
        #expect(throws: CLIError.conflictingLanguageAndCJK) {
            _ = try CLIParser.parse(["x.png", "-l", "en-US", "--cjk"])
        }
    }

    @Test("Long-form flags propagate")
    func longFormFlags() throws {
        let opts = try CLIParser.parse([
            "menu.png",
            "--lang", "en-US,fr-FR",
            "--level", "fast",
            "--no-correction",
            "--json"
        ])
        #expect(opts.languages == ["en-US", "fr-FR"])
        #expect(opts.level == .fast)
        #expect(opts.languageCorrection == false)
        #expect(opts.outputMode == .json)
    }

    @Test("Short-form flags propagate; -o forces JSON")
    func shortFormFlags() throws {
        let opts = try CLIParser.parse([
            "a.png", "-l", "en-US", "-o", "/tmp/r.json"
        ])
        #expect(opts.languages == ["en-US"])
        #expect(opts.keyword == nil)
        #expect(opts.outputPath == URL(fileURLWithPath: "/tmp/r.json"))
        #expect(opts.outputMode == .json)
    }

    @Test("Language list trims whitespace and drops empties")
    func languageListTrimsWhitespaceAndDropsEmpties() throws {
        let opts = try CLIParser.parse(["x.png", "-l", " en-US , , zh-Hans "])
        #expect(opts.languages == ["en-US", "zh-Hans"])
    }

    @Test("Invalid level throws .invalidLevel")
    func invalidLevelThrows() {
        #expect(throws: CLIError.self) {
            _ = try CLIParser.parse(["x.png", "--level", "turbo"])
        }
    }

    @Test("--json and --text together throw .conflictingOutputModes")
    func conflictingJsonAndTextThrows() {
        #expect(throws: CLIError.conflictingOutputModes) {
            _ = try CLIParser.parse(["x.png", "--json", "--text"])
        }
    }

    @Test("Unknown flag throws .invalidArguments")
    func unknownFlagThrows() {
        #expect(throws: CLIError.self) {
            _ = try CLIParser.parse(["x.png", "--bogus"])
        }
    }

    @Test("Multiple positional args are accepted (batch mode)")
    func multiplePositionalArgsAreAccepted() throws {
        let opts = try CLIParser.parse(["a.png", "b.png", "c.png"])
        #expect(opts.imageURLs.map(\.lastPathComponent) == ["a.png", "b.png", "c.png"])
    }

    @Test("Duplicate positional args throw .duplicateInput")
    func duplicatePositionalArgsThrow() {
        #expect(throws: CLIError.self) {
            _ = try CLIParser.parse(["a.png", "a.png"])
        }
    }

    @Test("--dir recurses and filters by extension")
    func dirScansRecursively() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("mac_ocr_cli_parser_\(UUID().uuidString)")
        let subdir = tmp.appendingPathComponent("nested")
        try FileManager.default.createDirectory(at: subdir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        try Data([0]).write(to: tmp.appendingPathComponent("a.png"))
        try Data([0]).write(to: tmp.appendingPathComponent("b.txt"))         // not an image
        try Data([0]).write(to: subdir.appendingPathComponent("c.JPG"))      // uppercase extension
        try Data([0]).write(to: subdir.appendingPathComponent("d.heic"))

        let opts = try CLIParser.parse(["--dir", tmp.path])
        let names = opts.imageURLs.map { $0.lastPathComponent }.sorted()
        #expect(names == ["a.png", "c.JPG", "d.heic"])
    }

    @Test("--dir on missing path throws .directoryNotFound")
    func dirMissingThrows() {
        #expect(throws: CLIError.self) {
            _ = try CLIParser.parse(["--dir", "/no/such/path/anywhere"])
        }
    }

    @Test("Positional args and --dir are merged, positional first")
    func positionalAndDirAreMerged() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("mac_ocr_cli_merge_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        try Data([0]).write(to: tmp.appendingPathComponent("z.png"))

        let opts = try CLIParser.parse(["first.png", "--dir", tmp.path])
        #expect(opts.imageURLs.map(\.lastPathComponent) == ["first.png", "z.png"])
    }

    // MARK: - stdin

    @Test("- reads path list from stdin (one per line)")
    func stdinReadsPathList() throws {
        let opts = try CLIParser.parse(
            ["-"],
            stdinReader: { "/a.png\n/b.png\n/c.png\n" }
        )
        #expect(opts.imageURLs.map(\.lastPathComponent) == ["a.png", "b.png", "c.png"])
    }

    @Test("- skips blank lines and #-prefixed comments from stdin")
    func stdinSkipsBlanksAndComments() throws {
        let opts = try CLIParser.parse(
            ["-"],
            stdinReader: { "# header comment\n\n/a.png\n   \n# another\n/b.png\n" }
        )
        #expect(opts.imageURLs.map(\.lastPathComponent) == ["a.png", "b.png"])
    }

    @Test("- can be combined with positional args (positional first)")
    func stdinCombinedWithPositional() throws {
        let opts = try CLIParser.parse(
            ["first.png", "-"],
            stdinReader: { "/from-stdin.png\n" }
        )
        #expect(opts.imageURLs.map(\.lastPathComponent) == ["first.png", "from-stdin.png"])
    }

    @Test("- with no reader throws .stdinRequestedButNoReader")
    func stdinWithoutReaderThrows() {
        #expect(throws: CLIError.stdinRequestedButNoReader) {
            _ = try CLIParser.parse(["-"])
        }
    }

    @Test("- with empty stdin throws .stdinEmpty")
    func stdinEmptyThrows() {
        #expect(throws: CLIError.stdinEmpty) {
            _ = try CLIParser.parse(["-"], stdinReader: { "" })
        }
        // 只有空行和注释也算空
        #expect(throws: CLIError.stdinEmpty) {
            _ = try CLIParser.parse(["-"], stdinReader: { "# only comments\n\n  \n" })
        }
    }

    @Test("parseStdinPaths handles CRLF and mixed whitespace")
    func parseStdinPathsCRLF() {
        let paths = CLIParser.parseStdinPaths("  /a.png  \r\n/b.png\r\n")
        #expect(paths == ["/a.png", "/b.png"])
    }

    // MARK: - 截图模式

    @Test("--screen sets main display capture, no imageURLs")
    func screenCaptureMode() throws {
        let opts = try CLIParser.parse(["--screen"])
        #expect(opts.screenCapture != nil)
        #expect(opts.imageURLs.isEmpty)
        #expect(opts.windowList == false)
    }

    @Test("--window with query sets windowQuery capture source")
    func windowCaptureMode() throws {
        let opts = try CLIParser.parse(["--window", "Safari"])
        #expect(opts.screenCapture != nil)
    }

    @Test("--window-id with valid id sets windowID capture")
    func windowIdCaptureMode() throws {
        let opts = try CLIParser.parse(["--window-id", "12345"])
        #expect(opts.screenCapture != nil)
    }

    @Test("--window-id rejects 0 and non-numeric")
    func windowIdValidation() {
        #expect(throws: CLIError.self) { _ = try CLIParser.parse(["--window-id", "0"]) }
        #expect(throws: CLIError.self) { _ = try CLIParser.parse(["--window-id", "abc"]) }
    }

    @Test("--region parses 4 numbers into a CGRect capture")
    func regionCaptureMode() throws {
        let opts = try CLIParser.parse(["--region", "100", "200", "800", "600"])
        #expect(opts.screenCapture != nil)
    }

    @Test("--region rejects non-positive width/height or missing args")
    func regionValidation() {
        #expect(throws: CLIError.self) { _ = try CLIParser.parse(["--region", "0", "0", "0", "100"]) }
        #expect(throws: CLIError.self) { _ = try CLIParser.parse(["--region", "0", "0"]) }
        #expect(throws: CLIError.self) { _ = try CLIParser.parse(["--region", "a", "b", "c", "d"]) }
    }

    @Test("--save-screenshot must be paired with a capture mode")
    func saveScreenshotRequiresCapture() {
        #expect(throws: CLIError.saveScreenshotWithoutCapture) {
            _ = try CLIParser.parse(["--save-screenshot", "/tmp/x.png", "photo.png"])
        }
    }

    @Test("Multiple capture sources throw .conflictingCaptureModes")
    func conflictingCaptureModes() {
        #expect(throws: CLIError.conflictingCaptureModes) {
            _ = try CLIParser.parse(["--screen", "--window", "Safari"])
        }
        #expect(throws: CLIError.conflictingCaptureModes) {
            _ = try CLIParser.parse(["--region", "0", "0", "100", "100", "--screen"])
        }
    }

    @Test("Capture + positional image path throws .captureWithImageInput")
    func captureWithImageInput() {
        #expect(throws: CLIError.captureWithImageInput) {
            _ = try CLIParser.parse(["--screen", "photo.png"])
        }
    }

    @Test("Capture + --dir throws .captureWithImageInput")
    func captureWithDir() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("mac_ocr_cli_capture_dir_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        #expect(throws: CLIError.captureWithImageInput) {
            _ = try CLIParser.parse(["--screen", "--dir", tmp.path])
        }
    }

    @Test("Capture + stdin `-` throws .captureWithImageInput")
    func captureWithStdin() {
        #expect(throws: CLIError.captureWithImageInput) {
            _ = try CLIParser.parse(["--screen", "-"], stdinReader: { "/a.png\n" })
        }
    }

    @Test("Capture + --keyword throws .invalidArguments")
    func captureWithKeyword() {
        do {
            _ = try CLIParser.parse(["--screen", "--keyword", "term"])
            Issue.record("expected error")
        } catch let error as CLIError {
            if case .invalidArguments = error { return }
            Issue.record("expected .invalidArguments, got \(error)")
        } catch {
            Issue.record("expected CLIError, got \(error)")
        }
    }

    @Test("--window-list sets windowList and clears everything else")
    func windowListMode() throws {
        let opts = try CLIParser.parse(["--window-list"])
        #expect(opts.windowList == true)
        #expect(opts.imageURLs.isEmpty)
        #expect(opts.screenCapture == nil)
    }

    @Test("--window-list + capture throws .windowListWithOther")
    func windowListWithCapture() {
        #expect(throws: CLIError.windowListWithOther) {
            _ = try CLIParser.parse(["--window-list", "--screen"])
        }
    }

    @Test("--window-list + positional throws .windowListWithOther")
    func windowListWithPositional() {
        #expect(throws: CLIError.windowListWithOther) {
            _ = try CLIParser.parse(["--window-list", "photo.png"])
        }
    }

    // MARK: - 剪贴板

    @Test("--clipboard defaults to main display")
    func clipboardDefaultsToMainDisplay() throws {
        let opts = try CLIParser.parse(["--clipboard"])
        #expect(opts.clipboardCapture != nil)
        #expect(opts.pasteboardSource == false)
    }

    @Test("--clipboard + --region captures the region into the pasteboard")
    func clipboardWithRegion() throws {
        let opts = try CLIParser.parse(["--clipboard", "--region", "0", "0", "400", "300"])
        #expect(opts.clipboardCapture != nil)
    }

    @Test("--clipboard + positional image throws .clipboardWithImageInput")
    func clipboardWithImageInput() {
        #expect(throws: CLIError.clipboardWithImageInput) {
            _ = try CLIParser.parse(["--clipboard", "photo.png"])
        }
    }

    @Test("--clipboard + --from-clipboard throws .clipboardAndPasteboard")
    func clipboardAndPasteboard() {
        #expect(throws: CLIError.clipboardAndPasteboard) {
            _ = try CLIParser.parse(["--clipboard", "--from-clipboard"])
        }
    }

    @Test("--from-clipboard alone sets pasteboardSource")
    func fromClipboardAlone() throws {
        let opts = try CLIParser.parse(["--from-clipboard"])
        #expect(opts.pasteboardSource == true)
        #expect(opts.imageURLs.isEmpty)
    }

    @Test("--from-clipboard + positional throws .pasteboardWithImageInput")
    func pasteboardWithImageInput() {
        #expect(throws: CLIError.pasteboardWithImageInput) {
            _ = try CLIParser.parse(["--from-clipboard", "photo.png"])
        }
    }

    @Test("--from-clipboard + --screen throws .pasteboardRequiresClipboard")
    func pasteboardWithScreen() {
        #expect(throws: CLIError.pasteboardRequiresClipboard) {
            _ = try CLIParser.parse(["--from-clipboard", "--screen"])
        }
    }

    @Test("--from-clipboard + --keyword still works")
    func pasteboardWithKeyword() throws {
        let opts = try CLIParser.parse(["--from-clipboard", "-k", "term"])
        #expect(opts.pasteboardSource == true)
        #expect(opts.keyword == "term")
    }

    @Test("--window-list + --clipboard throws")
    func windowListWithClipboard() {
        #expect(throws: CLIError.self) {
            _ = try CLIParser.parse(["--window-list", "--clipboard"])
        }
    }

    // MARK: - --quiet

    @Test("--quiet and -q set quiet=true")
    func quietFlag() throws {
        let opts1 = try CLIParser.parse(["--quiet", "photo.png"])
        #expect(opts1.quiet == true)
        let opts2 = try CLIParser.parse(["-q", "photo.png"])
        #expect(opts2.quiet == true)
    }

    @Test("Default is quiet=false")
    func quietDefault() throws {
        let opts = try CLIParser.parse(["photo.png"])
        #expect(opts.quiet == false)
    }

    @Test("--quiet can be combined with batch / --dir / --json / --output")
    func quietCombinations() throws {
        let opts = try CLIParser.parse(["--quiet", "--dir", "/tmp", "--json", "-o", "/tmp/r.json"])
        #expect(opts.quiet == true)
        #expect(opts.outputMode == .json)
    }

    @Test("--lang without a value throws")
    func missingLangValueThrows() {
        #expect(throws: CLIError.self) {
            _ = try CLIParser.parse(["x.png", "--lang"])
        }
    }

    @Test("All-empty --lang value throws")
    func emptyLangListThrows() {
        #expect(throws: CLIError.self) {
            _ = try CLIParser.parse(["x.png", "-l", "  ,  "])
        }
    }

    @Test("--keyword with -o throws .conflictingKeywordWithOutput")
    func keywordWithOutputThrows() {
        #expect(throws: CLIError.conflictingKeywordWithOutput) {
            _ = try CLIParser.parse(["x.png", "-k", "term", "-o", "/tmp/r.json"])
        }
    }
}
