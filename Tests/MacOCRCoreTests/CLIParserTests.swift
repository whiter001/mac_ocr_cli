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
