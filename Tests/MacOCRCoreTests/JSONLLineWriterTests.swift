import Darwin
import Foundation
import Testing
@testable import mac_ocr_cli

@Suite("JSONLLineWriter")
struct JSONLLineWriterTests {
    // MARK: - 工具

    private static func makeTempDirectory() -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mac_ocr_cli-jsonl-tests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private static func removeTempDirectory(_ directory: URL) {
        try? FileManager.default.removeItem(at: directory)
    }

    private static func readBytes(_ url: URL) -> Data {
        (try? Data(contentsOf: url)) ?? Data()
    }

    /// 目录里残留的 JSONL 临时文件(写完/失败后都应该为空)。
    private static func leftoverTemporaryFiles(in directory: URL) -> [String] {
        let contents = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return contents.filter { $0.hasPrefix(".mac_ocr_cli-jsonl-") }
    }

    /// 文件的 POSIX 权限位(不含文件类型位)。
    private static func posixMode(of url: URL) -> UInt16? {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return nil }
        return info.st_mode & 0o7777
    }

    /// 当前进程的 umask(读出后立刻恢复)。
    private static func currentUmask() -> mode_t {
        let mask = umask(0o077)
        _ = umask(mask)
        return mask
    }

    // MARK: - 用例

    @Test("Reusing a longer existing output file leaves no stale trailing bytes")
    func reusingLongerExistingFileLeavesNoStaleBytes() throws {
        let directory = Self.makeTempDirectory()
        defer { Self.removeTempDirectory(directory) }
        let output = directory.appendingPathComponent("out.jsonl")

        // 旧文件比新内容长很多。
        let oldContent = String(repeating: "x", count: 512) + "\n"
        try oldContent.write(to: output, atomically: true, encoding: .utf8)

        let writer = try MacOCRCLI.JSONLLineWriter(path: output, quiet: true)
        try writer.write("{\"n\":1}")
        try writer.close()

        let data = Self.readBytes(output)
        #expect(String(decoding: data, as: UTF8.self) == "{\"n\":1}\n")
        #expect(data.count == "{\"n\":1}\n".utf8.count)
        #expect(data.count < oldContent.utf8.count)
    }

    @Test("Content is available at the destination after a successful close")
    func contentAvailableAfterClose() throws {
        let directory = Self.makeTempDirectory()
        defer { Self.removeTempDirectory(directory) }
        let output = directory.appendingPathComponent("out.jsonl")

        let writer = try MacOCRCLI.JSONLLineWriter(path: output, quiet: true)
        try writer.write("{\"a\":1}")
        try writer.write("{\"b\":2}")
        try writer.close()

        let text = String(decoding: Self.readBytes(output), as: UTF8.self)
        #expect(text == "{\"a\":1}\n{\"b\":2}\n")
    }

    @Test("The old destination is untouched until close commits the new content")
    func destinationUntouchedUntilClose() throws {
        let directory = Self.makeTempDirectory()
        defer { Self.removeTempDirectory(directory) }
        let output = directory.appendingPathComponent("out.jsonl")

        try "old\n".write(to: output, atomically: true, encoding: .utf8)

        let writer = try MacOCRCLI.JSONLLineWriter(path: output, quiet: true)
        try writer.write("new")

        // 写入期间目标文件保持原样,新内容只在临时文件里。
        #expect(String(decoding: Self.readBytes(output), as: UTF8.self) == "old\n")
        #expect(Self.leftoverTemporaryFiles(in: directory).count == 1)

        try writer.close()

        #expect(String(decoding: Self.readBytes(output), as: UTF8.self) == "new\n")
        #expect(Self.leftoverTemporaryFiles(in: directory).isEmpty)
    }

    @Test("A failed commit throws and cleans up the temporary file")
    func failedCommitThrowsAndCleansUp() throws {
        let directory = Self.makeTempDirectory()
        defer { Self.removeTempDirectory(directory) }
        // 目标是已存在的目录:rename(2) 必然失败。
        let output = directory.appendingPathComponent("out.jsonl")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

        let writer = try MacOCRCLI.JSONLLineWriter(path: output, quiet: true)
        try writer.write("{\"a\":1}")

        #expect(throws: MacOCRCLI.JSONLLineWriter.WriteError.self) {
            try writer.close()
        }
        #expect(Self.leftoverTemporaryFiles(in: directory).isEmpty)
        // 目标是目录:提交失败后目录本身不受影响(仍是目录、仍是空的)。
        var isDirectory: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: output.path, isDirectory: &isDirectory))
        #expect(isDirectory.boolValue)
        #expect((try? FileManager.default.contentsOfDirectory(atPath: output.path))?.isEmpty == true)
    }

    @Test("A failed commit leaves a pre-existing destination file unchanged")
    func failedCommitLeavesExistingDestinationFileUnchanged() throws {
        let directory = Self.makeTempDirectory()
        defer { Self.removeTempDirectory(directory) }
        let output = directory.appendingPathComponent("out.jsonl")
        try "old\n".write(to: output, atomically: true, encoding: .utf8)
        try #require(chmod(output.path, 0o640) == 0)

        // 确定性地让 rename(2) 失败:目标打上 uchg(不可变)标志后不可被替换,
        // rename 返回 EPERM。目标内容与权限都不受影响。
        try #require(chflags(output.path, UInt32(UF_IMMUTABLE)) == 0)
        defer { _ = chflags(output.path, 0) }  // 解除标志,方便清理

        let writer = try MacOCRCLI.JSONLLineWriter(path: output, quiet: true)
        try writer.write("new")

        #expect(throws: MacOCRCLI.JSONLLineWriter.WriteError.self) {
            try writer.close()
        }
        // 旧目标文件原封不动:内容、权限都没变。
        #expect(String(decoding: Self.readBytes(output), as: UTF8.self) == "old\n")
        #expect(Self.posixMode(of: output) == 0o640)
        // 临时文件被清理,没有残留。
        #expect(Self.leftoverTemporaryFiles(in: directory).isEmpty)
    }

    @Test("A failed write cleans up the temporary file and keeps the destination intact")
    func failedWriteCleansUpTemporaryFile() throws {
        let directory = Self.makeTempDirectory()
        defer { Self.removeTempDirectory(directory) }
        let output = directory.appendingPathComponent("out.jsonl")
        try "old\n".write(to: output, atomically: true, encoding: .utf8)

        let writer = try MacOCRCLI.JSONLLineWriter(path: output, quiet: true)
        // 让底层句柄失效:之后的写入必然失败(不依赖任何平台特性)。
        try writer.invalidateHandleForTesting()

        #expect(throws: MacOCRCLI.JSONLLineWriter.WriteError.self) {
            try writer.write("new")
        }
        // 目标文件保持原样,临时文件被清理。
        #expect(String(decoding: Self.readBytes(output), as: UTF8.self) == "old\n")
        #expect(Self.leftoverTemporaryFiles(in: directory).isEmpty)

        // 失败之后再写仍然报错,不会静默丢数据。
        #expect(throws: MacOCRCLI.JSONLLineWriter.WriteError.self) {
            try writer.write("again")
        }
        // 失败后 close 是安全的(句柄已随失败清理)。
        try writer.close()
        #expect(String(decoding: Self.readBytes(output), as: UTF8.self) == "old\n")
    }

    @Test("Existing destination permissions survive the atomic replace")
    func existingDestinationPermissionsArePreserved() throws {
        let directory = Self.makeTempDirectory()
        defer { Self.removeTempDirectory(directory) }
        let output = directory.appendingPathComponent("out.jsonl")
        try "old\n".write(to: output, atomically: true, encoding: .utf8)
        try #require(chmod(output.path, 0o640) == 0)
        #expect(Self.posixMode(of: output) == 0o640)

        let writer = try MacOCRCLI.JSONLLineWriter(path: output, quiet: true)
        try writer.write("new")
        try writer.close()

        // 原子替换不改变目标原有的权限位。
        #expect(Self.posixMode(of: output) == 0o640)
        #expect(String(decoding: Self.readBytes(output), as: UTF8.self) == "new\n")
    }

    @Test("A read-only destination can still be replaced and keeps its mode")
    func readOnlyDestinationIsReplaced() throws {
        let directory = Self.makeTempDirectory()
        defer { Self.removeTempDirectory(directory) }
        let output = directory.appendingPathComponent("out.jsonl")
        try "old\n".write(to: output, atomically: true, encoding: .utf8)
        try #require(chmod(output.path, 0o400) == 0)

        let writer = try MacOCRCLI.JSONLLineWriter(path: output, quiet: true)
        try writer.write("new")
        try writer.close()

        #expect(String(decoding: Self.readBytes(output), as: UTF8.self) == "new\n")
        #expect(Self.posixMode(of: output) == 0o400)
    }

    @Test("A new destination keeps the default creation permissions")
    func newDestinationKeepsDefaultPermissions() throws {
        let directory = Self.makeTempDirectory()
        defer { Self.removeTempDirectory(directory) }
        let output = directory.appendingPathComponent("out.jsonl")

        let writer = try MacOCRCLI.JSONLLineWriter(path: output, quiet: true)
        try writer.write("new")
        try writer.close()

        // 新建文件沿用常规的默认创建权限(0666 & ~umask),不因内部用 0600 建临时文件而变窄。
        #expect(Self.posixMode(of: output) == UInt16(0o666 & ~Self.currentUmask()))
        #expect(String(decoding: Self.readBytes(output), as: UTF8.self) == "new\n")
    }

    @Test("The temporary file inherits the destination permissions while writing")
    func temporaryFileInheritsDestinationMode() throws {
        let directory = Self.makeTempDirectory()
        defer { Self.removeTempDirectory(directory) }
        let output = directory.appendingPathComponent("out.jsonl")
        try "old\n".write(to: output, atomically: true, encoding: .utf8)
        try #require(chmod(output.path, 0o640) == 0)

        let writer = try MacOCRCLI.JSONLLineWriter(path: output, quiet: true)
        try writer.write("new")

        // 临时文件在建好时(fchmod 作用在 fd 上)就已经是目标的权限位。
        let temporaries = Self.leftoverTemporaryFiles(in: directory)
        #expect(temporaries.count == 1)
        #expect(Self.posixMode(of: directory.appendingPathComponent(temporaries[0])) == 0o640)

        try writer.close()
        #expect(Self.posixMode(of: output) == 0o640)
        #expect(String(decoding: Self.readBytes(output), as: UTF8.self) == "new\n")
    }

    @Test("An existing symlink at the destination is rejected and left untouched")
    func existingSymlinkIsRejected() throws {
        let directory = Self.makeTempDirectory()
        defer { Self.removeTempDirectory(directory) }
        let target = directory.appendingPathComponent("target.jsonl")
        try "target\n".write(to: target, atomically: true, encoding: .utf8)
        let link = directory.appendingPathComponent("out.jsonl")
        try #require(symlink(target.path, link.path) == 0)

        // 目标是符号链接:构造时直接拒绝,而不是替换链接本身。
        do {
            _ = try MacOCRCLI.JSONLLineWriter(path: link, quiet: true)
            Issue.record("expected a symlink rejection")
        } catch let error as MacOCRCLI.JSONLLineWriter.WriteError {
            if case .destinationIsSymbolicLink = error {
                // 预期中的拒绝。
            } else {
                Issue.record("unexpected error: \(error)")
            }
        }

        // 链接本身仍然是链接,链接指向的目标内容没变,也没有留下临时文件。
        var info = stat()
        #expect(lstat(link.path, &info) == 0)
        #expect((info.st_mode & S_IFMT) == S_IFLNK)
        #expect(String(decoding: Self.readBytes(target), as: UTF8.self) == "target\n")
        #expect(Self.leftoverTemporaryFiles(in: directory).isEmpty)
    }

    @Test("Stdout mode closes without touching the filesystem")
    func stdoutModeCloseIsNoop() throws {
        let writer = try MacOCRCLI.JSONLLineWriter(path: nil, quiet: true)
        try writer.close()
        // 重复 close 也不应抛错。
        try writer.close()
        // --quiet 时 stdout 不写内容,自然也不会出错。
        try writer.write("{\"a\":1}")
    }

    @Test("The temporary file is created relative to the directory descriptor")
    func temporaryFileIsCreatedRelativeToDirectoryDescriptor() throws {
        let directory = Self.makeTempDirectory()
        defer { Self.removeTempDirectory(directory) }
        let directoryFD = directory.path.withCString {
            open($0, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        }
        try #require(directoryFD >= 0)
        defer { _ = unistd.close(directoryFD) }

        // 新名字:openat 在目录 fd 下建出一个普通文件,权限是 0600。
        let freshName = "fresh-\(UUID().uuidString).tmp"
        let created = MacOCRCLI.JSONLLineWriter.createTemporaryFile(
            directoryDescriptor: directoryFD,
            name: freshName
        )
        #expect(created.fd >= 0)
        guard created.fd >= 0 else { return }
        defer { _ = unistd.close(created.fd) }
        let createdURL = directory.appendingPathComponent(freshName)
        var createdInfo = stat()
        #expect(lstat(createdURL.path, &createdInfo) == 0)
        #expect((createdInfo.st_mode & S_IFMT) == S_IFREG)
        #expect(Self.posixMode(of: createdURL) == UInt16(0o600 & ~Self.currentUmask()))

        // 已存在的名字:openat 的 O_EXCL|O_NOFOLLOW 必须失败,
        // 既不覆盖同名文件,也不跟随同名符号链接。
        let target = directory.appendingPathComponent("target.txt")
        try "keep\n".write(to: target, atomically: true, encoding: .utf8)
        let linkName = "link"
        try #require(symlink(target.path, directory.appendingPathComponent(linkName).path) == 0)

        let failed = MacOCRCLI.JSONLLineWriter.createTemporaryFile(
            directoryDescriptor: directoryFD,
            name: linkName
        )
        #expect(failed.fd < 0)
        #expect(failed.errorCode == EEXIST)
        // 链接还是链接,链接指向的目标内容也没变。
        var linkInfo = stat()
        #expect(lstat(directory.appendingPathComponent(linkName).path, &linkInfo) == 0)
        #expect((linkInfo.st_mode & S_IFMT) == S_IFLNK)
        #expect(String(decoding: Self.readBytes(target), as: UTF8.self) == "keep\n")
    }

    @Test("A destination turned into a symlink before close is rejected")
    func destinationTurnedIntoSymlinkBeforeCloseIsRejected() throws {
        let directory = Self.makeTempDirectory()
        defer { Self.removeTempDirectory(directory) }
        let output = directory.appendingPathComponent("out.jsonl")
        let target = directory.appendingPathComponent("target.jsonl")
        try "target\n".write(to: target, atomically: true, encoding: .utf8)

        let writer = try MacOCRCLI.JSONLLineWriter(path: output, quiet: true)
        try writer.write("new")

        // 目标在写入期间被换成符号链接:提交前复核时必须拒绝,
        // 不能跟着链接写,也不能替换链接本身。
        // (写入期间目标文件还不存在,只存在临时文件。)
        try #require(symlink(target.path, output.path) == 0)

        do {
            try writer.close()
            Issue.record("expected a symlink rejection at commit time")
        } catch let error as MacOCRCLI.JSONLLineWriter.WriteError {
            if case .destinationIsSymbolicLink = error {
                // 预期中的拒绝。
            } else {
                Issue.record("unexpected error: \(error)")
            }
        }

        // 链接与链接目标都原样保留,临时文件被清理。
        var info = stat()
        #expect(lstat(output.path, &info) == 0)
        #expect((info.st_mode & S_IFMT) == S_IFLNK)
        #expect(String(decoding: Self.readBytes(target), as: UTF8.self) == "target\n")
        #expect(Self.leftoverTemporaryFiles(in: directory).isEmpty)
    }
}
