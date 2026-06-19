import Darwin
import Foundation
import MacOCRCore

@main
struct MacOCRCLI {
    static func main() async {
        do {
            let options = try CLIParser.parse(Array(CommandLine.arguments.dropFirst()))

            let recognizer = VisionOCRRecognizer(
                recognitionLanguages: options.languages,
                recognitionLevel: options.level,
                usesLanguageCorrection: options.languageCorrection
            )

            let lines = try await recognizer.recognizeText(in: options.imageURL)
            let report = OCRReport(imagePath: options.imageURL.path, lines: lines)

            try writeOutput(report: report, options: options)
        } catch let error as CLIError where error == .helpRequested {
            print(CLIPrinter.usage)
            exit(0)
        } catch let error as CLIError where error == .versionRequested {
            print(CLIPrinter.version)
            exit(0)
        } catch {
            fputs("错误: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }

    private static func writeOutput(report: OCRReport, options: CLIOptions) throws {
        let text = CLIOutputRenderer.renderText(report: report, options: options)
        let json = try CLIOutputRenderer.renderJSON(report: report)

        let payload: String
        switch options.outputMode {
        case .text: payload = text
        case .json: payload = json
        }

        if let outputPath = options.outputPath {
            try FileManager.default.createDirectory(
                at: outputPath.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try payload.write(to: outputPath, atomically: true, encoding: .utf8)
        }

        print(payload)
    }
}
