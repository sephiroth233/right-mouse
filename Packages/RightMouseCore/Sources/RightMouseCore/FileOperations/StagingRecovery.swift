import Foundation
import Darwin
import CryptoKit

private enum StagingRecoveryError: LocalizedError {
    case unsafe(String)
    var errorDescription: String? { if case let .unsafe(message) = self { return message }; return nil }
}

extension FileTransferEngine {
    public func inspectStagingRecovery(operationID: UUID? = nil) -> StagingRecoveryInspection {
        var items: [StagingRecoveryItem] = []
        var issues: [TransferRecoveryIssue] = []
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: journalDirectory.path) else {
            return .init(items: [], issues: [])
        }
        for name in names where name.hasSuffix(".json") {
            let journalURL = journalDirectory.appendingPathComponent(name)
            do {
                let record = try validatedRecoveryRecord(at: journalURL)
                if let operationID, record.operationID != operationID { continue }
                guard record.stagingURL != nil || record.stagingCleanupState == .requested else { continue }
                items.append(try inspect(record, journalURL: journalURL))
            } catch {
                issues.append(.init(url: journalURL, message: error.localizedDescription))
            }
        }
        return .init(items: items, issues: issues)
    }

    public func cleanupStaging(_ token: StagingCleanupToken) throws -> StagingCleanupResult {
        guard !running else { throw CommandFailure(.ioFailed, "另一个文件操作正在进行，请稍后重试。", retryable: true) }
        running = true; defer { running = false }
        let expectedJournal = journalDirectory.appendingPathComponent(token.itemID.uuidString + ".json").standardizedFileURL
        guard token.journalURL.standardizedFileURL == expectedJournal else { throw CommandFailure(.recoveryRequired, "暂存清理令牌与操作记录不匹配。") }
        let currentJournalData: Data
        do { currentJournalData = try PrivateFileIO.read(expectedJournal, maximumBytes: RequestValidator.maximumBytes) }
        catch { throw CommandFailure(.recoveryRequired, "暂存操作记录无法读取，已保留现场。") }
        guard Self.stagingJournalDigest(currentJournalData) == token.journalDigest else {
            throw CommandFailure(.recoveryRequired, "暂存操作记录在检查后已经变化，请重新检查。")
        }
        var record: TransferJournalRecord
        do { record = try validatedRecoveryRecord(at: expectedJournal) }
        catch { throw CommandFailure(.recoveryRequired, "暂存操作记录无法验证，已保留现场。") }
        guard record.operationID == token.operationID, record.itemID == token.itemID,
              record.result == nil, ["staging", "verified"].contains(record.phase),
              record.stagingIdentity == token.stagingIdentity,
              record.stagingParentIdentity == token.parentIdentity,
              let sourceIdentity = record.sourceIdentity,
              (try? TransferFileSystem.identity(record.source)) == sourceIdentity,
              !TransferFileSystem.exists(record.destination) else {
            throw CommandFailure(.recoveryRequired, "暂存状态、来源或目标已经变化，不能自动清理。")
        }
        let original = record.stagingURL ?? token.stagingURL
        let parent = original.deletingLastPathComponent()
        let cleanup = parent.appendingPathComponent(".rightmouse-cleanup-\(record.itemID.uuidString)", isDirectory: true)
        guard record.destination.deletingLastPathComponent() == parent,
              token.stagingURL == original || token.stagingURL == cleanup else {
            throw CommandFailure(.recoveryRequired, "暂存位置与检查令牌不一致。")
        }
        do {
            try StagingRecoveryFileSystem.validateParent(parent, identity: token.parentIdentity)
            let currentURL: URL
            if record.stagingCleanupState == .requested, !StagingRecoveryFileSystem.existsNoFollow(original), StagingRecoveryFileSystem.existsNoFollow(cleanup) {
                currentURL = cleanup
            } else {
                guard original.lastPathComponent == ".rightmouse-\(record.itemID.uuidString)", original.deletingLastPathComponent() == parent,
                      StagingRecoveryFileSystem.sameObject(try StagingRecoveryFileSystem.identityNoFollow(original), token.stagingIdentity) else { throw StagingRecoveryError.unsafe("暂存目录身份已变化") }
                record.stagingCleanupURL = cleanup; record.stagingCleanupState = .requested
                try save(record) // Durable intent precedes the first destructive namespace change.
                try StagingRecoveryFileSystem.renameExclusive(original, cleanup, parent: parent)
                currentURL = cleanup
            }
            guard StagingRecoveryFileSystem.sameObject(try StagingRecoveryFileSystem.identityNoFollow(currentURL), token.stagingIdentity) else { throw StagingRecoveryError.unsafe("清理目录身份已变化") }
            let bytes = try StagingRecoveryFileSystem.occupiedBytes(currentURL, expectedDevice: token.stagingIdentity.device)
            try StagingRecoveryFileSystem.removeTree(currentURL, expected: token.stagingIdentity)
            record.stagingURL = nil; record.stagingCleanupURL = cleanup; record.stagingCleanupState = .completed
            do { try save(record) }
            catch { throw CommandFailure(.recoveryRequired, "暂存目录已清理，但结果记录失败；请核对操作记录。") }
            return .init(operationID: record.operationID, itemID: record.itemID, removedBytes: bytes)
        } catch let failure as CommandFailure { throw failure }
        catch {
            record.stagingCleanupURL = cleanup; record.stagingCleanupState = .needsReview
            try? save(record)
            throw CommandFailure(.recoveryRequired, "暂存目录未能安全清理，已保留现场：\(error.localizedDescription)")
        }
    }

    private func inspect(_ record: TransferJournalRecord, journalURL: URL) throws -> StagingRecoveryItem {
        let shownURL = record.stagingCleanupState == .requested && record.stagingCleanupURL.map(StagingRecoveryFileSystem.existsNoFollow) == true
            ? record.stagingCleanupURL : record.stagingURL
        guard let url = shownURL else {
            return .init(operationID: record.operationID, itemID: record.itemID, stagingURL: nil, occupiedBytes: 0,
                         disposition: .retainedForReview("清理已请求，但暂存目录与完成记录不一致。"))
        }
        let bytes = (try? StagingRecoveryFileSystem.occupiedBytes(url, expectedDevice: nil)) ?? 0
        guard let stagingIdentity = record.stagingIdentity, let parentIdentity = record.stagingParentIdentity else {
            return .init(operationID: record.operationID, itemID: record.itemID, stagingURL: url, occupiedBytes: bytes,
                         disposition: .legacyEvidenceOnly("旧记录没有暂存目录归属身份，只能查看，不能删除。"))
        }
        guard record.result == nil, ["staging", "verified"].contains(record.phase), record.stagingCleanupState != .needsReview,
              let sourceIdentity = record.sourceIdentity, (try? TransferFileSystem.identity(record.source)) == sourceIdentity,
              !TransferFileSystem.exists(record.destination) else {
            return .init(operationID: record.operationID, itemID: record.itemID, stagingURL: url, occupiedBytes: bytes,
                         disposition: .retainedForReview("操作可能已提交，或来源、目标已变化。"))
        }
        let parent = (record.stagingURL ?? url).deletingLastPathComponent()
        let originalName = ".rightmouse-\(record.itemID.uuidString)"
        let cleanupName = ".rightmouse-cleanup-\(record.itemID.uuidString)"
        guard record.destination.deletingLastPathComponent() == parent else {
            return .init(operationID: record.operationID, itemID: record.itemID, stagingURL: url, occupiedBytes: bytes,
                         disposition: .retainedForReview("暂存目录不是记录目标的直接子目录。"))
        }
        guard [originalName, cleanupName].contains(url.lastPathComponent) else {
            return .init(operationID: record.operationID, itemID: record.itemID, stagingURL: url, occupiedBytes: bytes,
                         disposition: .retainedForReview("暂存目录名称与项目标识不匹配。"))
        }
        let currentIdentity: TransferFileIdentity
        do { currentIdentity = try StagingRecoveryFileSystem.identityNoFollow(url) }
        catch {
            return .init(operationID: record.operationID, itemID: record.itemID, stagingURL: url, occupiedBytes: bytes,
                         disposition: .retainedForReview("暂存目录不是可验证的当前用户私有目录。"))
        }
        guard StagingRecoveryFileSystem.sameObject(currentIdentity, stagingIdentity) else {
            return .init(operationID: record.operationID, itemID: record.itemID, stagingURL: url, occupiedBytes: bytes,
                         disposition: .retainedForReview("暂存目录所有者或身份不匹配。"))
        }
        do { try StagingRecoveryFileSystem.validateParent(parent, identity: parentIdentity) }
        catch {
            return .init(operationID: record.operationID, itemID: record.itemID, stagingURL: url, occupiedBytes: bytes,
                         disposition: .retainedForReview("暂存父目录身份不匹配：\(error.localizedDescription)"))
        }
        let journalData = try PrivateFileIO.read(journalURL, maximumBytes: RequestValidator.maximumBytes)
        let token = StagingCleanupToken(operationID: record.operationID, itemID: record.itemID, journalURL: journalURL,
                                        stagingURL: url, stagingIdentity: stagingIdentity, parentIdentity: parentIdentity,
                                        journalDigest: Self.stagingJournalDigest(journalData))
        return .init(operationID: record.operationID, itemID: record.itemID, stagingURL: url, occupiedBytes: bytes, disposition: .cleanupAllowed(token))
    }

    private static func stagingJournalDigest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

private enum StagingRecoveryFileSystem {
    static func sameObject(_ lhs: TransferFileIdentity, _ rhs: TransferFileIdentity) -> Bool {
        lhs.device == rhs.device && lhs.inode == rhs.inode && lhs.kind == rhs.kind
    }
    static func existsNoFollow(_ url: URL) -> Bool { var value = stat(); return lstat(url.path, &value) == 0 }
    static func identityNoFollow(_ url: URL) throws -> TransferFileIdentity {
        let identity = try TransferFileSystem.identity(url)
        var value = stat()
        guard lstat(url.path, &value) == 0, value.st_uid == getuid(), value.st_mode & S_IFMT == S_IFDIR,
              value.st_mode & 0o077 == 0 else { throw StagingRecoveryError.unsafe("目录不是当前用户的私有真实目录") }
        return identity
    }
    static func validateParent(_ url: URL, identity: TransferFileIdentity) throws {
        let descriptor = try openDirectoryNoFollow(url)
        defer { close(descriptor) }
        var value = stat()
        guard fstat(descriptor, &value) == 0, UInt64(value.st_dev) == identity.device, UInt64(value.st_ino) == identity.inode,
              UInt32(value.st_mode & S_IFMT) == identity.kind else { throw StagingRecoveryError.unsafe("目标父目录身份已变化") }
    }
    static func openDirectoryNoFollow(_ url: URL) throws -> Int32 {
        guard url.isFileURL, url.path.hasPrefix("/"), !url.path.contains("\0") else { throw StagingRecoveryError.unsafe("不是本地绝对路径") }
        var current = ""
        for part in url.path.split(separator: "/") {
            current += "/" + part
            var info = stat()
            guard lstat(current, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else {
                throw StagingRecoveryError.unsafe("目录路径含符号链接祖先：\(current)")
            }
        }
        let descriptor = open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard descriptor >= 0 else { throw TransferEngineError.system(errno) }
        return descriptor
    }
    static func renameExclusive(_ source: URL, _ destination: URL, parent: URL) throws {
        let parentFD = try openDirectoryNoFollow(parent); defer { close(parentFD) }
        guard renameatx_np(parentFD, source.lastPathComponent, parentFD, destination.lastPathComponent, UInt32(RENAME_EXCL)) == 0 else {
            throw TransferEngineError.system(errno)
        }
        guard fsync(parentFD) == 0 else { throw TransferEngineError.system(errno) }
    }
    static func occupiedBytes(_ url: URL, expectedDevice: UInt64?) throws -> Int64 {
        return try occupiedBytesAtPath(url, expectedDevice: expectedDevice)
    }
    static func removeTree(_ url: URL, expected: TransferFileIdentity) throws {
        let parent = url.deletingLastPathComponent()
        let parentFD = try openDirectoryNoFollow(parent); defer { close(parentFD) }
        let descriptor = openat(parentFD, url.lastPathComponent, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard descriptor >= 0 else { throw TransferEngineError.system(errno) }
        defer { close(descriptor) }
        var root = stat()
        guard fstat(descriptor, &root) == 0, UInt64(root.st_dev) == expected.device, UInt64(root.st_ino) == expected.inode,
              UInt32(root.st_mode & S_IFMT) == expected.kind, root.st_uid == getuid(), root.st_mode & 0o077 == 0 else {
            throw StagingRecoveryError.unsafe("待清理目录身份已变化")
        }
        _ = try walk(descriptor, expectedDevice: expected.device, remove: true)
        guard unlinkat(parentFD, url.lastPathComponent, AT_REMOVEDIR) == 0, fsync(parentFD) == 0 else { throw TransferEngineError.system(errno) }
    }
    private static func walk(_ descriptor: Int32, expectedDevice: UInt64?, remove: Bool) throws -> Int64 {
        var root = stat(); guard fstat(descriptor, &root) == 0 else { throw TransferEngineError.system(errno) }
        if let expectedDevice, UInt64(root.st_dev) != expectedDevice { throw StagingRecoveryError.unsafe("暂存内容跨越了文件系统") }
        guard let stream = fdopendir(dup(descriptor)) else { throw TransferEngineError.system(errno) }
        defer { closedir(stream) }
        var bytes = Int64(root.st_blocks) * 512
        var names: [String] = []
        while let entry = readdir(stream) {
            let name = withUnsafePointer(to: &entry.pointee.d_name) { $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(cString: $0) } }
            if name != "." && name != ".." { names.append(name) }
        }
        for name in names {
            var info = stat()
            // Descendants preserve source metadata and may legitimately carry a
            // different uid. Ownership is established by the private root inode.
            guard fstatat(descriptor, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { throw StagingRecoveryError.unsafe("暂存成员无法验证") }
            if let expectedDevice, UInt64(info.st_dev) != expectedDevice { throw StagingRecoveryError.unsafe("暂存成员跨越了文件系统") }
            bytes += Int64(info.st_blocks) * 512
            if info.st_mode & S_IFMT == S_IFDIR {
                let child = openat(descriptor, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
                guard child >= 0 else { throw TransferEngineError.system(errno) }
                do { bytes += try walk(child, expectedDevice: expectedDevice, remove: remove); close(child) }
                catch { close(child); throw error }
                if remove { guard unlinkat(descriptor, name, AT_REMOVEDIR) == 0 else { throw TransferEngineError.system(errno) } }
            } else if remove {
                guard unlinkat(descriptor, name, 0) == 0 else { throw TransferEngineError.system(errno) }
            }
        }
        if remove { guard fsync(descriptor) == 0 else { throw TransferEngineError.system(errno) } }
        return bytes
    }
    private static func occupiedBytesAtPath(_ url: URL, expectedDevice: UInt64?) throws -> Int64 {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { throw TransferEngineError.system(errno) }
        if let expectedDevice, UInt64(info.st_dev) != expectedDevice { throw StagingRecoveryError.unsafe("暂存内容跨越了文件系统") }
        var bytes = Int64(info.st_blocks) * 512
        if info.st_mode & S_IFMT == S_IFDIR {
            for child in try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil) {
                bytes += try occupiedBytesAtPath(child, expectedDevice: expectedDevice)
            }
        }
        return bytes
    }
}
