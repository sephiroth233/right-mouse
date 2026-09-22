import Foundation
import Darwin

/// Retain this lease for the host lifetime. It fences an older host while its
/// private data is moved out of the shared container. File formats do not change.
public final class PrivateStorageMigration {
    private let paths: SharedPaths
    private var legacyLedger: CommandLedger?
    public private(set) var migratedFiles = 0
    public init(paths: SharedPaths) throws {
        self.paths = paths
        guard paths.root.standardizedFileURL != paths.privateRoot.standardizedFileURL else { return }
        let root = try MigrationDirectory(paths.root)
        let oldCommands = paths.root.appendingPathComponent("Operations/Commands")
        if let operations = try root.child("Operations", create: false),
           try operations.child("Commands", create: false) != nil {
            legacyLedger = try CommandLedger(directory: oldCommands)
        }
    }
    public func run() throws {
        guard paths.root.standardizedFileURL != paths.privateRoot.standardizedFileURL else { return }
        let source = try MigrationDirectory(paths.root)
        let destination = try MigrationDirectory(paths.privateRoot)
        for category in ["Configuration", "Templates", "Operations", "Diagnostics", "Backups"] {
            guard let old = try source.child(category, create: false) else { continue }
            guard source.device == destination.device else {
                throw CommandFailure(.volumeUnavailable, "旧数据与宿主私有目录不在同一卷，已保留原件。请将应用数据迁移到同一卷后重试。")
            }
            guard let new = try destination.child(category, create: true) else { throw Self.failure }
            try moveContents(old, new, relative: category, depth: 0)
            // The legacy Commands/host.lock remains held; an empty directory may remain.
            _ = unlinkat(source.fd, category, AT_REMOVEDIR)
        }
        guard fsync(source.fd) == 0, fsync(destination.fd) == 0 else { throw Self.failure }
    }
    private func moveContents(_ source: MigrationDirectory, _ target: MigrationDirectory, relative: String, depth: Int) throws {
        guard depth < 32 else { throw Self.failure }
        for name in try source.names() {
            if relative == "Operations/Commands", name == "host.lock" { continue }
            let before = try source.identity(name)
            guard before.st_uid == getuid(), before.st_mode & 0o022 == 0 else { throw Self.failure }
            if before.st_mode & S_IFMT == S_IFDIR {
                guard let from = try source.child(name, create: false), let to = try target.child(name, create: true) else { throw Self.failure }
                try moveContents(from, to, relative: relative + "/" + name, depth: depth + 1)
                guard unlinkat(source.fd, name, AT_REMOVEDIR) == 0 || errno == ENOTEMPTY else { throw Self.failure }
            } else {
                guard before.st_mode & S_IFMT == S_IFREG, before.st_nlink == 1 else { throw Self.failure }
                let fd = openat(source.fd, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
                guard fd >= 0 else { throw Self.failure }
                defer { close(fd) }
                var opened = stat()
                guard fstat(fd, &opened) == 0, Self.sameObject(before, opened), fchmod(fd, 0o600) == 0 else { throw Self.failure }
                // Atomic, no-overwrite relocation retains the original inode and bytes.
                guard renameatx_np(source.fd, name, target.fd, name, UInt32(RENAME_EXCL)) == 0 else {
                    throw CommandFailure(.recoveryRequired, "私有数据迁移遇到已有记录或无法移动的文件，已保留两侧数据；请核对后重试。")
                }
                let after = try target.identity(name)
                guard Self.sameObject(opened, after), fsync(fd) == 0,
                      fsync(source.fd) == 0, fsync(target.fd) == 0 else { throw Self.failure }
                migratedFiles += 1
            }
        }
    }
    private static func sameObject(_ lhs: stat, _ rhs: stat) -> Bool {
        lhs.st_dev == rhs.st_dev && lhs.st_ino == rhs.st_ino && lhs.st_mode & S_IFMT == rhs.st_mode & S_IFMT && lhs.st_size == rhs.st_size
    }
    private static var failure: CommandFailure { .init(.recoveryRequired, "无法安全迁移旧应用数据，已保留现场；不会覆盖或丢弃原始记录。") }
}

private final class MigrationDirectory {
    let fd: Int32
    let device: dev_t
    init(_ url: URL) throws {
        var info = stat()
        guard url.isFileURL, lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
              let physical = realpath(url.path, nil) else { throw Self.failure }
        defer { free(physical) }
        var current = open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard current >= 0 else { throw Self.failure }
        do {
            for part in String(cString: physical).split(separator: "/") {
                let next = openat(current, String(part), O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
                guard next >= 0 else { throw Self.failure }
                close(current); current = next
            }
            guard fstat(current, &info) == 0, info.st_uid == getuid(), info.st_mode & 0o077 == 0 else { throw Self.failure }
            fd = current; device = info.st_dev
        } catch { close(current); throw error }
    }
    private init(fd: Int32) throws {
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFDIR, info.st_uid == getuid(), info.st_mode & 0o077 == 0 else { close(fd); throw Self.failure }
        self.fd = fd; device = info.st_dev
    }
    deinit { close(fd) }
    func child(_ name: String, create: Bool) throws -> MigrationDirectory? {
        if create { guard mkdirat(fd, name, 0o700) == 0 || errno == EEXIST else { throw Self.failure } }
        let child = openat(fd, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        if child < 0 && errno == ENOENT && !create { return nil }
        guard child >= 0 else { throw Self.failure }
        let value = try MigrationDirectory(fd: child)
        guard value.device == device else { throw Self.failure }
        return value
    }
    func identity(_ name: String) throws -> stat {
        var info = stat()
        guard fstatat(fd, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { throw Self.failure }
        return info
    }
    func names() throws -> [String] {
        let duplicate = dup(fd)
        guard duplicate >= 0 else { throw Self.failure }
        guard let stream = fdopendir(duplicate) else { close(duplicate); throw Self.failure }
        defer { closedir(stream) }
        var names: [String] = []
        while let entry = readdir(stream) {
            let name = withUnsafePointer(to: &entry.pointee.d_name) { pointer in pointer.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(cString: $0) } }
            if name != ".", name != ".." { names.append(name) }
        }
        return names.sorted()
    }
    private static var failure: CommandFailure { .init(.recoveryRequired, "旧数据目录不可信，无法自动迁移。") }
}
