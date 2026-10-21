import Foundation

/// 压缩副本(`--compress-output`)输出名的规划器。
///
/// `--compress-output <dir>` 指向一个**扁平**目录,而输入可能来自任意多层目录:
/// `a/photo.png` 和 `b/photo.png` 沿用同一个 stem 就会写进同一个 `photo.jpg`,
/// 后写的直接覆盖先写的——批量模式下多个 worker 还会并发写同一路径。
///
/// 规划器在并发开始前一次性把每个输入的目标名算好,规则:
/// - 不冲突 → 沿用原 stem(`photo.jpg`)
/// - 冲突   → 用「相对公共根目录的路径」区分(`a__photo.jpg` / `b__photo.jpg`)
/// - 仍冲突 → 追加序号(`photo-2.jpg`)
///
/// 多页 PDF 的 displayPath 带 `#page=N` 后缀,页码后缀会保留在输出名里
/// (`doc-p2.jpg`),不会互相覆盖。
public struct CompressedOutputPlanner: Sendable {

    /// displayPath → 输出文件名 stem(不含扩展名)
    public private(set) var stems: [String: String]

    public init(displayPaths: [String]) {
        stems = Self.plan(displayPaths: displayPaths)
    }

    /// 规划出的目标 URL。displayPath 不在规划范围内时返回 nil。
    public func url(for displayPath: String, in dir: URL, format: ImageFormat) -> URL? {
        guard let stem = stems[displayPath] else { return nil }
        return dir
            .appendingPathComponent(stem)
            .appendingPathExtension(ImageCompressor.fileExtension(for: format))
    }

    // MARK: - 内部实现

    /// 一个输入的解析结果:去掉 `#page=N` 后的路径 + 页码后缀 + 基础 stem。
    private struct Parsed {
        let displayPath: String
        let pathPart: String
        let pageSuffix: String
        let stem: String
    }

    private static func parse(_ displayPath: String) -> Parsed {
        let parts = displayPath.components(separatedBy: "#page=")
        let pathPart = parts.first ?? displayPath
        let pageSuffix = parts.count > 1 ? "-p" + (parts.last ?? "") : ""
        let fileName = (pathPart as NSString).lastPathComponent
        let stem = (fileName as NSString).deletingPathExtension + pageSuffix
        return Parsed(
            displayPath: displayPath,
            pathPart: pathPart,
            pageSuffix: pageSuffix,
            stem: stem
        )
    }

    private static func plan(displayPaths: [String]) -> [String: String] {
        let parsed = displayPaths.map(parse)

        // 1. 按基础名分组:只有出现多次的组才需要消歧。
        var counts: [String: Int] = [:]
        for item in parsed {
            counts[item.stem, default: 0] += 1
        }

        // 2. 公共根目录:冲突组改用相对路径命名时需要它。
        let root = commonRoot(of: parsed.map(\.pathPart))

        // 3. 分配唯一名字。
        var used: Set<String> = []
        var result: [String: String] = [:]
        for item in parsed {
            var candidate = item.stem
            if (counts[item.stem] ?? 0) > 1 {
                candidate = flattenedStem(for: item, root: root)
            }
            // 极端情况(同目录同 stem 不同扩展名)再追加序号。
            var unique = candidate
            var suffix = 2
            while used.contains(unique) {
                unique = "\(candidate)-\(suffix)"
                suffix += 1
            }
            used.insert(unique)
            result[item.displayPath] = unique
        }
        return result
    }

    /// 一组路径的最长公共目录前缀(按路径分段比较)。
    private static func commonRoot(of paths: [String]) -> [String] {
        guard let first = paths.first else { return [] }
        var common = first.split(separator: "/").map(String.init)
        for path in paths.dropFirst() {
            let parts = path.split(separator: "/").map(String.init)
            var index = 0
            while index < min(common.count, parts.count), common[index] == parts[index] {
                index += 1
            }
            common = Array(common.prefix(index))
        }
        return common
    }

    /// 相对公共根目录的路径 → 扁平化 stem(目录分隔符换成 `__`)。
    private static func flattenedStem(for item: Parsed, root: [String]) -> String {
        let parts = item.pathPart.split(separator: "/").map(String.init)
        let tail = parts.count > root.count ? Array(parts[root.count...]) : parts
        let fileName = tail.last ?? "image"
        let stem = (fileName as NSString).deletingPathExtension
        let dirs = tail.dropLast().joined(separator: "__")
        let base = dirs.isEmpty ? stem : "\(dirs)__\(stem)"
        return base + item.pageSuffix
    }
}
