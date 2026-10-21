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
        // F10: windowListWithClipboard 死代码删除后,这里统一走 .windowListWithOther。
        #expect(throws: CLIError.windowListWithOther) {
            _ = try CLIParser.parse(["--window-list", "--clipboard"])
        }
    }

    @Test("Tilde in --output/--save-screenshot/--dir expands to $HOME")
    func tildeExpansionInPaths() throws {
        let opts = try CLIParser.parse(["photo.png", "--output", "~/out.json"])
        let home = NSHomeDirectory()
        #expect(opts.outputPath?.path == "\(home)/out.json")
    }

    @Test("--keyword in batch mode is allowed (per-item matches)")
    func keywordInBatchAllowed() throws {
        let opts = try CLIParser.parse(["a.png", "b.png", "-k", "term"])
        #expect(opts.keyword == "term")
        #expect(opts.imageURLs.count == 2)
    }

    @Test("--keyword with single file still works (regression check)")
    func keywordInSingleFileStillWorks() throws {
        let opts = try CLIParser.parse(["photo.png", "-k", "term"])
        #expect(opts.keyword == "term")
    }

    @Test("--dir with no supported images throws")
    func dirWithNoImagesThrows() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("mac_ocr_cli_noimg_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        try Data([0]).write(to: tmp.appendingPathComponent("a.txt"))
        try Data([0]).write(to: tmp.appendingPathComponent("b.md"))
        #expect(throws: CLIError.self) {
            _ = try CLIParser.parse(["--dir", tmp.path])
        }
    }

    @Test("--from-clipboard with --keyword and --output throws .conflictingKeywordWithOutput")
    func pasteboardKeywordWithOutputThrows() {
        #expect(throws: CLIError.conflictingKeywordWithOutput) {
            _ = try CLIParser.parse(["--from-clipboard", "-k", "x", "-o", "/tmp/r.json"])
        }
    }

    @Test("--cjk after --lang with exact default value still throws")
    func cjkAfterExactDefaultLangThrows() {
        // F6: 之前会静默切换到 cjkLanguages,现在 userSetLang 标志让它拒绝。
        #expect(throws: CLIError.conflictingLanguageAndCJK) {
            _ = try CLIParser.parse(["x.png", "--lang", "zh-Hans,zh-Hant,en-US", "--cjk"])
        }
    }

    @Test("--region rejects NaN, Infinity, -Infinity")
    func regionRejectsNaNAndInfinity() {
        #expect(throws: CLIError.self) {
            _ = try CLIParser.parse(["--region", "NaN", "0", "100", "100"])
        }
        #expect(throws: CLIError.self) {
            _ = try CLIParser.parse(["--region", "0", "0", "Infinity", "100"])
        }
        #expect(throws: CLIError.self) {
            _ = try CLIParser.parse(["--region", "0", "0", "100", "-Infinity"])
        }
    }

    @Test("--window-list with --keyword throws")
    func windowListWithKeywordThrows() {
        #expect(throws: CLIError.self) {
            _ = try CLIParser.parse(["--window-list", "-k", "term"])
        }
    }

    @Test("--clipboard with --keyword throws")
    func clipboardWithKeywordThrows() {
        #expect(throws: CLIError.self) {
            _ = try CLIParser.parse(["--clipboard", "-k", "term"])
        }
    }

    @Test("Duplicate value-taking flag throws")
    func duplicateValueFlagThrows() {
        #expect(throws: CLIError.self) {
            _ = try CLIParser.parse(["photo.png", "-l", "en-US", "-l", "fr-FR"])
        }
        #expect(throws: CLIError.self) {
            _ = try CLIParser.parse(["photo.png", "-o", "/tmp/a.json", "-o", "/tmp/b.json"])
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
        // 用专属临时目录并放一张图片,避免依赖 /tmp 里恰好有可识别的图片
        // (CI runner 上的 /tmp 可能为空,会导致 .invalidArguments 抛错)
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("mac_ocr_cli_quiet_combo_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        try Data([0]).write(to: tmp.appendingPathComponent("a.png"))
        let outputPath = tmp.appendingPathComponent("r.json").path

        let opts = try CLIParser.parse(["--quiet", "--dir", tmp.path, "--json", "-o", outputPath])
        #expect(opts.quiet == true)
        #expect(opts.outputMode == .json)
    }

    // MARK: - --compress-input / --compress-output

    /// 共享 helper:创建一个真实存在的临时目录,用于 --compress-output 之类的目录类 flag。
    private func makeTempDir(prefix: String) throws -> URL {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("mac_ocr_cli_\(prefix)_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        // 测试结束时清理,defer 由 caller 加。
        return tmp
    }

    @Test("--compress-input high enables preprocessing with high quality")
    func compressInputHighEnables() throws {
        let opts = try CLIParser.parse(["photo.png", "--compress-input", "high"])
        #expect(opts.compressionInput != nil)
        #expect(opts.compressionInput?.format == .jpeg)
        #expect(opts.compressionInput?.quality == 0.85)
        #expect(opts.compressionOutput == nil)
    }

    @Test("--compress-input 0.75 enables with numeric quality")
    func compressInputNumericEnables() throws {
        let opts = try CLIParser.parse(["photo.png", "--compress-input", "0.75"])
        #expect(opts.compressionInput?.quality == 0.75)
    }

    @Test("--compress-input without value throws")
    func compressInputMissingValueThrows() {
        #expect(throws: CLIError.self) {
            _ = try CLIParser.parse(["photo.png", "--compress-input"])
        }
        #expect(throws: CLIError.self) {
            // `--compress-input --quiet` 会试图把 `--quiet` 当作 quality 值,
            // 守卫会拦下来(否则会默默吞掉 --quiet)。
            _ = try CLIParser.parse(["photo.png", "--compress-input", "--quiet"])
        }
    }

    @Test("--compress-input foo throws .invalidCompressionQuality")
    func compressInputInvalidQualityThrows() {
        #expect(throws: CLIError.self) {
            _ = try CLIParser.parse(["photo.png", "--compress-input", "foo"])
        }
        #expect(throws: CLIError.self) {
            _ = try CLIParser.parse(["photo.png", "--compress-input", "2.0"])
        }
    }

    @Test("--compress-input-format webp selects WebP, default quality is high")
    func compressInputFormatWebp() throws {
        let opts = try CLIParser.parse(["photo.png", "--compress-input", "medium", "--compress-input-format", "webp"])
        #expect(opts.compressionInput?.format == .webp)
        #expect(opts.compressionInput?.quality == 0.70)
    }

    @Test("Default input format is jpeg when --compress-input-format absent")
    func defaultInputFormatIsJpeg() throws {
        let opts = try CLIParser.parse(["photo.png", "--compress-input", "high"])
        #expect(opts.compressionInput?.format == .jpeg)
    }

    @Test("--compress-output sets directory and default quality is high")
    func compressOutputSetsDirectory() throws {
        let tmp = try makeTempDir(prefix: "compress_out")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let opts = try CLIParser.parse([
            "photo.png", "--compress-output", tmp.path
        ])
        #expect(opts.compressionOutput != nil)
        #expect(opts.compressionOutput?.format == .jpeg)
        #expect(opts.compressionOutput?.quality == 0.85)
        #expect(opts.compressionOutputDirectory?.path == tmp.path)
    }

    @Test("--compress-output-format heic overrides output format only")
    func compressOutputFormatHeic() throws {
        let tmp = try makeTempDir(prefix: "compress_out_heic")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let opts = try CLIParser.parse([
            "photo.png", "--compress-output", tmp.path,
            "--compress-output-format", "heic"
        ])
        #expect(opts.compressionOutput?.format == .heic)
    }

    @Test("--compress-output without value throws")
    func compressOutputMissingValueThrows() {
        #expect(throws: CLIError.self) {
            _ = try CLIParser.parse(["photo.png", "--compress-output"])
        }
    }

    @Test("--compress-output with missing directory throws .compressionOutputRequiresDirectory")
    func compressOutputMissingDirThrows() {
        let bogus = "/no/such/dir/\(UUID().uuidString)"
        #expect(throws: CLIError.self) {
            _ = try CLIParser.parse(["photo.png", "--compress-output", bogus])
        }
    }

    @Test("--compress-quality overrides default quality for output mode")
    func compressQualityOverridesOutput() throws {
        let tmp = try makeTempDir(prefix: "compress_quality")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let opts = try CLIParser.parse([
            "photo.png", "--compress-output", tmp.path,
            "--compress-quality", "0.3"
        ])
        #expect(opts.compressionOutput?.quality == 0.3)
    }

    @Test("--compress-output with --from-clipboard throws .compressionOutputInPasteboardMode")
    func compressOutputWithPasteboardThrows() {
        #expect(throws: CLIError.self) {
            let tmp = FileManager.default.temporaryDirectory
                .appendingPathComponent("mac_ocr_cli_compress_paste_\(UUID().uuidString)")
            _ = try CLIParser.parse([
                "--from-clipboard", "--compress-output", tmp.path
            ])
        }
    }

    @Test("--compress-input with --window-list throws .compressionRequiresOCR")
    func compressInputWithWindowListThrows() {
        #expect(throws: CLIError.self) {
            _ = try CLIParser.parse(["--window-list", "--compress-input", "high"])
        }
    }

    @Test("--compress-input with --clipboard throws .compressionRequiresOCR")
    func compressInputWithClipboardThrows() {
        #expect(throws: CLIError.self) {
            _ = try CLIParser.parse(["--clipboard", "--compress-input", "high"])
        }
    }

    @Test("Duplicate --compress-input throws invalidArguments")
    func duplicateCompressInputThrows() {
        #expect(throws: CLIError.self) {
            _ = try CLIParser.parse(["photo.png", "--compress-input", "high", "--compress-input", "low"])
        }
    }

    @Test("--compress-input-format bogus throws .invalidCompressionFormat")
    func compressFormatBogusThrows() {
        #expect(throws: CLIError.self) {
            _ = try CLIParser.parse(["photo.png", "--compress-input", "high", "--compress-input-format", "gif"])
        }
    }

    @Test("--compress-input + --compress-output share quality when --compress-quality omitted")
    func compressInputAndOutputBothEnabled() throws {
        let tmp = try makeTempDir(prefix: "compress_both")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let opts = try CLIParser.parse([
            "photo.png",
            "--compress-input", "low",
            "--compress-output", tmp.path
        ])
        // input 用 low,output 走默认 high(因为没传 --compress-quality)
        #expect(opts.compressionInput?.quality == 0.50)
        #expect(opts.compressionOutput?.quality == 0.85)
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

    // MARK: - 1.2.0 新增 flag

    @Test("--max-dimension sets value, rejects non-positive and non-numeric")
    func maxDimensionFlag() throws {
        let opts = try CLIParser.parse(["x.png", "--max-dimension", "2048"])
        #expect(opts.maxDimension == 2048)
        #expect(throws: CLIError.self) { _ = try CLIParser.parse(["x.png", "--max-dimension", "0"]) }
        #expect(throws: CLIError.self) { _ = try CLIParser.parse(["x.png", "--max-dimension", "abc"]) }
        #expect(throws: CLIError.self) { _ = try CLIParser.parse(["x.png", "--max-dimension"]) }
    }

    @Test("--concurrency sets value, rejects < 1")
    func concurrencyFlag() throws {
        let opts = try CLIParser.parse(["x.png", "--concurrency", "8"])
        #expect(opts.concurrency == 8)
        #expect(throws: CLIError.self) { _ = try CLIParser.parse(["x.png", "--concurrency", "0"]) }
    }

    @Test("--min-confidence sets value, rejects out of range")
    func minConfidenceFlag() throws {
        let opts = try CLIParser.parse(["x.png", "--min-confidence", "0.5"])
        #expect(opts.minConfidence == 0.5)
        #expect(throws: CLIError.self) { _ = try CLIParser.parse(["x.png", "--min-confidence", "1.5"]) }
        #expect(throws: CLIError.self) { _ = try CLIParser.parse(["x.png", "--min-confidence", "-0.1"]) }
    }

    @Test("--plain sets plain output mode; conflicts with --json")
    func plainFlag() throws {
        let opts = try CLIParser.parse(["x.png", "--plain"])
        #expect(opts.outputMode == .plain)
        #expect(throws: CLIError.conflictingOutputModes) {
            _ = try CLIParser.parse(["x.png", "--plain", "--json"])
        }
    }

    @Test("--jsonl sets jsonl + json mode; rejects non-batch modes")
    func jsonlFlag() throws {
        let opts = try CLIParser.parse(["a.png", "b.png", "--jsonl"])
        #expect(opts.jsonl == true)
        #expect(opts.outputMode == .json)
        #expect(throws: CLIError.self) { _ = try CLIParser.parse(["a.png", "--jsonl", "--text"]) }
        #expect(throws: CLIError.self) { _ = try CLIParser.parse(["--screen", "--jsonl"]) }
        #expect(throws: CLIError.self) { _ = try CLIParser.parse(["--from-clipboard", "--jsonl"]) }
        #expect(throws: CLIError.self) { _ = try CLIParser.parse(["--window-list", "--jsonl"]) }
    }

    @Test("--word-boxes sets flag")
    func wordBoxesFlag() throws {
        let opts = try CLIParser.parse(["x.png", "--word-boxes"])
        #expect(opts.wordBoxes == true)
    }

    @Test("--to-clipboard sets flag; rejected with list/clipboard-capture modes")
    func toClipboardFlag() throws {
        let opts = try CLIParser.parse(["x.png", "--to-clipboard"])
        #expect(opts.toClipboard == true)
        #expect(throws: CLIError.self) { _ = try CLIParser.parse(["--window-list", "--to-clipboard"]) }
        #expect(throws: CLIError.self) { _ = try CLIParser.parse(["--display-list", "--to-clipboard"]) }
        #expect(throws: CLIError.self) { _ = try CLIParser.parse(["--clipboard", "--to-clipboard"]) }
    }

    @Test("--barcode sets barcode mode over file inputs")
    func barcodeFlag() throws {
        let opts = try CLIParser.parse(["a.png", "b.png", "--barcode"])
        #expect(opts.barcodeMode == true)
        #expect(opts.imageURLs.count == 2)
    }

    @Test("--barcode rejects non-file modes, keyword and compression")
    func barcodeConflicts() {
        #expect(throws: CLIError.self) { _ = try CLIParser.parse(["--screen", "--barcode"]) }
        #expect(throws: CLIError.self) { _ = try CLIParser.parse(["--from-clipboard", "--barcode"]) }
        #expect(throws: CLIError.self) { _ = try CLIParser.parse(["--stdin-image", "--barcode"]) }
        #expect(throws: CLIError.self) { _ = try CLIParser.parse(["--window-list", "--barcode"]) }
        #expect(throws: CLIError.self) { _ = try CLIParser.parse(["a.png", "--barcode", "-k", "x"]) }
        #expect(throws: CLIError.self) { _ = try CLIParser.parse(["a.png", "--barcode", "--compress-input", "high"]) }
    }

    @Test("--stdin-image sets stdin image mode, conflicts with other inputs")
    func stdinImageFlag() throws {
        let opts = try CLIParser.parse(["--stdin-image"])
        #expect(opts.stdinImage == true)
        #expect(opts.imageURLs.isEmpty)
        #expect(throws: CLIError.self) { _ = try CLIParser.parse(["--stdin-image", "a.png"]) }
        #expect(throws: CLIError.self) { _ = try CLIParser.parse(["--stdin-image", "--screen"]) }
        #expect(throws: CLIError.self) { _ = try CLIParser.parse(["--stdin-image", "--from-clipboard"]) }
    }

    @Test("--display sets index on screen/region/clipboard; rejected elsewhere")
    func displayFlag() throws {
        let screen = try CLIParser.parse(["--screen", "--display", "1"])
        #expect(screen.screenCapture?.displayIndex == 1)
        let region = try CLIParser.parse(["--region", "0", "0", "100", "100", "--display", "2"])
        #expect(region.screenCapture?.displayIndex == 2)
        let clipboard = try CLIParser.parse(["--clipboard", "--display", "1"])
        #expect(clipboard.clipboardCapture?.displayIndex == 1)
        #expect(throws: CLIError.self) { _ = try CLIParser.parse(["a.png", "--display", "1"]) }
        #expect(throws: CLIError.self) { _ = try CLIParser.parse(["--window", "Safari", "--display", "1"]) }
        #expect(throws: CLIError.self) { _ = try CLIParser.parse(["--screen", "--display", "-1"]) }
    }

    @Test("--display-list / --lang-list set list modes and are mutually exclusive")
    func listModeFlags() throws {
        let d = try CLIParser.parse(["--display-list"])
        #expect(d.displayList == true)
        let l = try CLIParser.parse(["--lang-list"])
        #expect(l.langList == true)
        #expect(throws: CLIError.self) { _ = try CLIParser.parse(["--display-list", "--lang-list"]) }
        #expect(throws: CLIError.self) { _ = try CLIParser.parse(["--window-list", "--display-list"]) }
        #expect(throws: CLIError.self) { _ = try CLIParser.parse(["--display-list", "a.png"]) }
        #expect(throws: CLIError.self) { _ = try CLIParser.parse(["--lang-list", "--screen"]) }
    }

    @Test("Duplicate --window-list / --clipboard / --from-clipboard throw")
    func duplicateModeFlagsThrow() {
        #expect(throws: CLIError.self) { _ = try CLIParser.parse(["--window-list", "--window-list"]) }
        #expect(throws: CLIError.self) { _ = try CLIParser.parse(["--clipboard", "--clipboard"]) }
        #expect(throws: CLIError.self) { _ = try CLIParser.parse(["--from-clipboard", "--from-clipboard"]) }
    }

    @Test("Explicit -l values are validated against supported languages")
    func unsupportedLanguageThrows() throws {
        // 系统给不出支持列表时校验会被跳过,测试也随之跳过。
        let supported = VisionOCRRecognizer.supportedLanguages(level: .accurate)
        guard !supported.isEmpty else { return }
        #expect(throws: CLIError.unsupportedLanguages(["xx-XX"])) {
            _ = try CLIParser.parse(["x.png", "-l", "xx-XX"])
        }
        // 默认预设语言必须能过校验(防误杀回归)
        for lang in CLIParser.defaultLanguages {
            #expect(throws: Never.self) { _ = try CLIParser.parse(["x.png", "-l", lang]) }
        }
    }

    @Test("Mixed short/long forms of the same flag are rejected as duplicates")
    func mixedFlagFormsRejected() {
        // 长短写归一到同一个语义 key,混用也算重复,不会 last-wins 吞掉第一个值。
        #expect(throws: CLIError.self) {
            _ = try CLIParser.parse(["x.png", "-o", "/tmp/a.json", "--output", "/tmp/b.json"])
        }
        #expect(throws: CLIError.self) {
            _ = try CLIParser.parse(["x.png", "-l", "en-US", "--lang", "zh-Hans"])
        }
        #expect(throws: CLIError.self) {
            _ = try CLIParser.parse(["x.png", "-k", "a", "--keyword", "b"])
        }
        #expect(throws: CLIError.self) {
            _ = try CLIParser.parse(["x.png", "-q", "--quiet"])
        }
    }

    @Test("Capture mode keeps the compression options")
    func captureModeKeepsCompressionOptions() throws {
        // 截图模式之前会把压缩参数整个丢掉(静默无效),现在必须透传。
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("mac_ocr_cli_capture_compress_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let opts = try CLIParser.parse([
            "--screen",
            "--compress-input", "low",
            "--compress-output", tmp.path
        ])
        #expect(opts.compressionInput?.quality == 0.5)
        #expect(opts.compressionOutput != nil)
        #expect(opts.compressionOutputDirectory?.path == tmp.path)
    }
}
