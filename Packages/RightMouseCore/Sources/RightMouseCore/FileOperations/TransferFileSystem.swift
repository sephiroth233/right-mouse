import Foundation
import CryptoKit
import Darwin

struct TransferSnapshot: Equatable {
    let identity: TransferFileIdentity
    let digest: String
    let metadata: String
}

enum TransferFileSystem {
    static func fingerprint(_ manifest: [String: TransferSnapshot]) throws -> String {
        var hash = SHA256()
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        for key in manifest.keys.sorted() {
            let entry = manifest[key]!
            hash.update(data: Data(key.utf8)); hash.update(data: Data([0]))
            hash.update(data: try encoder.encode(entry.identity))
            hash.update(data: Data(entry.digest.utf8)); hash.update(data: Data(entry.metadata.utf8))
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
    static func identity(_ url: URL) throws -> TransferFileIdentity {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { throw TransferEngineError.system(errno) }
        return TransferFileIdentity(device: UInt64(info.st_dev), inode: UInt64(info.st_ino), kind: UInt32(info.st_mode & S_IFMT), size: info.st_size, modifiedSeconds: Int64(info.st_mtimespec.tv_sec), modifiedNanoseconds: Int64(info.st_mtimespec.tv_nsec), changedSeconds: Int64(info.st_ctimespec.tv_sec), changedNanoseconds: Int64(info.st_ctimespec.tv_nsec))
    }

    static func exists(_ url: URL) -> Bool { (try? identity(url)) != nil }
    static func check(_ cancellation: TransferCancellation) throws {
        if cancellation.isCancelled || Task.isCancelled { throw TransferEngineError.cancelled }
    }
    static func renameExclusive(_ from: URL, _ to: URL) throws {
        guard renamex_np(from.path, to.path, UInt32(RENAME_EXCL)) == 0 else {
            if errno == EEXIST || errno == ENOTEMPTY { throw TransferEngineError.occupied }
            throw TransferEngineError.system(errno)
        }
    }

    static func manifest(_ root: URL, cancellation: TransferCancellation) throws -> [String: TransferSnapshot] {
        var entries: [String: TransferSnapshot] = [:]
        func visit(_ url: URL, relative: String) throws {
            try check(cancellation)
            let before = try identity(url)
            guard [UInt32(S_IFREG), UInt32(S_IFDIR), UInt32(S_IFLNK)].contains(before.kind) else { throw TransferEngineError.unsupportedFile }
            let digest: String
            if before.kind == S_IFREG {
                let fd = open(url.path, O_RDONLY | O_NOFOLLOW)
                guard fd >= 0 else { throw TransferEngineError.system(errno) }
                defer { close(fd) }
                var hash = SHA256()
                var buffer = [UInt8](repeating: 0, count: 1024 * 1024)
                while true {
                    try check(cancellation)
                    let count = read(fd, &buffer, buffer.count)
                    if count < 0 { throw TransferEngineError.system(errno) }
                    if count == 0 { break }
                    hash.update(data: Data(buffer.prefix(count)))
                }
                digest = hash.finalize().map { String(format: "%02x", $0) }.joined()
            } else if before.kind == S_IFLNK {
                digest = try FileManager.default.destinationOfSymbolicLink(atPath: url.path)
            } else {
                digest = "directory"
                let children = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil).sorted { $0.lastPathComponent < $1.lastPathComponent }
                for child in children { try visit(child, relative: relative.isEmpty ? child.lastPathComponent : relative + "/" + child.lastPathComponent) }
            }
            let metadata = try metadataDigest(url)
            guard before == (try identity(url)) else { throw TransferEngineError.sourceChanged }
            entries[relative] = TransferSnapshot(identity: before, digest: digest, metadata: metadata)
        }
        try visit(root, relative: "")
        return entries
    }

    static func equivalent(_ lhs: [String: TransferSnapshot], _ rhs: [String: TransferSnapshot]) -> Bool {
        guard lhs.keys.sorted() == rhs.keys.sorted() else { return false }
        return lhs.allSatisfy { key, value in
            guard let other = rhs[key] else { return false }
            return value.identity.kind == other.identity.kind && value.digest == other.digest && value.metadata == other.metadata
                && (value.identity.kind != S_IFREG || value.identity.size == other.identity.size)
        }
    }

    /// A rename can change ctime without changing the object selected by the user.
    /// Compare inode identity, content, relevant metadata, size and mtime, while deliberately
    /// ignoring only ctime. This is stricter than `equivalent`, which is intended for copies.
    static func sameObjectsAfterRename(_ before: [String: TransferSnapshot], _ after: [String: TransferSnapshot]) -> Bool {
        guard before.keys.sorted() == after.keys.sorted() else { return false }
        return before.allSatisfy { key, value in
            guard let other = after[key] else { return false }
            let a = value.identity, b = other.identity
            return a.device == b.device && a.inode == b.inode && a.kind == b.kind && a.size == b.size
                && a.modifiedSeconds == b.modifiedSeconds && a.modifiedNanoseconds == b.modifiedNanoseconds
                && value.digest == other.digest && value.metadata == other.metadata
        }
    }

    static func metadataDigest(_ url: URL) throws -> String {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { throw TransferEngineError.system(errno) }
        var hash = SHA256()
        // Change/creation times are filesystem bookkeeping. Preserve permissions, modification time,
        // Finder flags, ACL and all readable extended attributes including resource forks.
        hash.update(data: Data("\(info.st_mode & 0o7777):\(info.st_flags):\(info.st_mtimespec.tv_sec):\(info.st_mtimespec.tv_nsec)".utf8))
        let length = listxattr(url.path, nil, 0, XATTR_NOFOLLOW)
        guard length >= 0 else { throw TransferEngineError.system(errno) }
        var names = [CChar](repeating: 0, count: max(length, 1))
        if length > 0 {
            guard listxattr(url.path, &names, length, XATTR_NOFOLLOW) == length else { throw TransferEngineError.sourceChanged }
            let keys = Data(names.prefix(length).map { UInt8(bitPattern: $0) }).split(separator: 0).map { String(decoding: $0, as: UTF8.self) }.sorted()
            for key in keys {
                let count = getxattr(url.path, key, nil, 0, 0, XATTR_NOFOLLOW)
                guard count >= 0 else { throw TransferEngineError.system(errno) }
                var bytes = [UInt8](repeating: 0, count: max(count, 1))
                guard getxattr(url.path, key, &bytes, count, 0, XATTR_NOFOLLOW) == count else { throw TransferEngineError.sourceChanged }
                hash.update(data: Data(key.utf8)); hash.update(data: Data([0])); hash.update(data: Data(bytes.prefix(count)))
            }
        }
        if info.st_mode & S_IFMT != S_IFLNK, let acl = acl_get_file(url.path, ACL_TYPE_EXTENDED) {
            defer { acl_free(UnsafeMutableRawPointer(acl)) }
            var size = 0
            if let text = acl_to_text(acl, &size) {
                defer { acl_free(text) }
                hash.update(data: Data(bytes: text, count: size))
            }
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func copyTree(_ source: URL, _ destination: URL, cancellation: TransferCancellation, bytes: (Int64) -> Void) throws {
        try check(cancellation)
        let kind = try identity(source).kind
        if kind == S_IFREG {
            let input = open(source.path, O_RDONLY | O_NOFOLLOW)
            guard input >= 0 else { throw TransferEngineError.system(errno) }
            defer { close(input) }
            let output = open(destination.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
            guard output >= 0 else { throw TransferEngineError.system(errno) }
            defer { close(output) }
            var buffer = [UInt8](repeating: 0, count: 1024 * 1024)
            while true {
                try check(cancellation)
                let count = read(input, &buffer, buffer.count)
                if count < 0 { throw TransferEngineError.system(errno) }
                if count == 0 { break }
                try buffer.withUnsafeBytes { raw in
                    var offset = 0
                    while offset < count {
                        let written = write(output, raw.baseAddress!.advanced(by: offset), count - offset)
                        guard written > 0 else { throw TransferEngineError.system(errno) }
                        offset += written
                    }
                }
                bytes(Int64(count))
            }
            guard fcopyfile(input, output, nil, copyfile_flags_t(COPYFILE_METADATA)) == 0 else { throw TransferEngineError.system(errno) }
            guard fsync(output) == 0 else { throw TransferEngineError.system(errno) }
        } else if kind == S_IFLNK {
            guard copyfile(source.path, destination.path, nil, copyfile_flags_t(COPYFILE_ALL | COPYFILE_NOFOLLOW | COPYFILE_EXCL)) == 0 else { throw TransferEngineError.system(errno) }
        } else if kind == S_IFDIR {
            guard mkdir(destination.path, 0o700) == 0 else { throw TransferEngineError.system(errno) }
            for child in try FileManager.default.contentsOfDirectory(at: source, includingPropertiesForKeys: nil) {
                try copyTree(child, destination.appendingPathComponent(child.lastPathComponent), cancellation: cancellation, bytes: bytes)
            }
            guard copyfile(source.path, destination.path, nil, copyfile_flags_t(COPYFILE_METADATA | COPYFILE_NOFOLLOW)) == 0 else { throw TransferEngineError.system(errno) }
        } else { throw TransferEngineError.unsupportedFile }
    }

    /// Every source and its committed counterpart is rechecked immediately before removal.
    /// Never recursively remove a source path. Non-cooperating writers cannot be globally locked.
    static func removeVerified(_ source: URL, target: URL, expected: [String: TransferSnapshot], cancellation: TransferCancellation) throws {
        guard try manifest(source, cancellation: cancellation) == expected else { throw TransferEngineError.sourceChanged }
        let targetSnapshot = try manifest(target, cancellation: cancellation)
        guard equivalent(expected, targetSnapshot) else { throw TransferEngineError.verificationFailed }
        let sorted = expected.keys.sorted { $0.split(separator: "/").count > $1.split(separator: "/").count }
        var unlinkedIdentities = Set<String>()
        for key in sorted {
            try check(cancellation)
            let url = key.isEmpty ? source : source.appendingPathComponent(key)
            let snapshot = expected[key]!
            let current = try identity(url)
            if current.kind == S_IFDIR {
                // Removing children changes directory timestamps; identity must still match.
                guard current.device == snapshot.identity.device && current.inode == snapshot.identity.inode && current.kind == snapshot.identity.kind else { throw TransferEngineError.sourceChanged }
                guard rmdir(url.path) == 0 else { throw TransferEngineError.system(errno) }
            } else {
                let currentManifest = try manifest(url, cancellation: cancellation)
                let identityKey = "\(snapshot.identity.device):\(snapshot.identity.inode)"
                // Removing one name of a hard-linked file changes ctime for its remaining
                // names. Permit only that cleanup-induced ctime delta for an inode already
                // unlinked by this loop; all content, metadata, size, mtime and inode fields
                // remain checked.
                let sourceMatches = unlinkedIdentities.contains(identityKey)
                    ? sameObjectsAfterRename(["": snapshot], currentManifest)
                    : currentManifest[""] == snapshot
                guard sourceMatches else { throw TransferEngineError.sourceChanged }
                let targetURL = key.isEmpty ? target : target.appendingPathComponent(key)
                guard try manifest(targetURL, cancellation: cancellation)[""] == targetSnapshot[key] else { throw TransferEngineError.verificationFailed }
                guard unlink(url.path) == 0 else { throw TransferEngineError.system(errno) }
                unlinkedIdentities.insert(identityKey)
            }
        }
    }

    static func coordinateMutation(source: URL, destination: URL, action: () throws -> Void) throws {
        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordinationError: NSError?
        var operationError: Error?
        var called = false
        coordinator.coordinate(writingItemAt: source, options: .forMoving, writingItemAt: destination, options: [], error: &coordinationError) { _, _ in
            called = true
            do { try action() } catch { operationError = error }
        }
        if let operationError { throw operationError }
        if let coordinationError { throw coordinationError }
        guard called else { throw TransferEngineError.sourceChanged }
    }
}
