import Foundation
import Darwin
import RightMouseCore

private struct VolumeCheckFailure: Error, CustomStringConvertible { let description: String }

@main
struct RightMouseVolumeCheck {
    static func main() async {
        do {
            guard CommandLine.arguments.count == 3 else { throw VolumeCheckFailure(description: "usage: RightMouseVolumeCheck HOST_FIXTURE IMAGE_MOUNT") }
            let count = try await run(hostRoot: URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true),
                                      imageRoot: URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true))
            print("PASS volume total: \(count)")
        } catch { fputs("FAIL volume: \(error)\n", stderr); exit(1) }
    }

    static func run(hostRoot: URL, imageRoot: URL) async throws -> Int {
        let fm = FileManager.default
        var count = 0
        func check(_ value: @autoclosure () throws -> Bool, _ title: String) throws {
            guard try value() else { throw VolumeCheckFailure(description: title) }
            count += 1; print("PASS volume: \(title)")
        }
        func device(_ url: URL) throws -> UInt64 {
            var value = stat(); guard lstat(url.path, &value) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            return UInt64(value.st_dev)
        }
        func write(_ name: String, bytes: Int = 4096) throws -> URL {
            let url = hostRoot.appendingPathComponent(name); try Data(repeating: 0x5a, count: bytes).write(to: url); return url
        }
        try check(try device(hostRoot) != device(imageRoot), "host fixture and image target have different st_dev")

        let copyTarget = imageRoot.appendingPathComponent("copy-target", isDirectory: true)
        try fm.createDirectory(at: copyTarget, withIntermediateDirectories: false)
        let copySource = try write("metadata-source.bin")
        try fm.setAttributes([.posixPermissions: 0o640, .modificationDate: Date(timeIntervalSince1970: 1_700_000_000)], ofItemAtPath: copySource.path)
        let xattrValue = Array("rightmouse-volume-metadata".utf8)
        let setResult = xattrValue.withUnsafeBytes { setxattr(copySource.path, "com.rightmouse.volume-check", $0.baseAddress, $0.count, 0, 0) }
        try check(setResult == 0, "fixture stores a real extended attribute")
        let copyEngine = FileTransferEngine(journalDirectory: hostRoot.appendingPathComponent("copy-journal"))
        let copied = await copyEngine.transfer(sources: [copySource], to: copyTarget, mode: .copy)
        let copyDestination = copyTarget.appendingPathComponent(copySource.lastPathComponent)
        try check(copied.completedCount == 1 && fm.fileExists(atPath: copySource.path) && fm.fileExists(atPath: copyDestination.path), "real cross-device copy commits target and retains source")
        try check(try Data(contentsOf: copyDestination) == Data(contentsOf: copySource), "real cross-device copy preserves bytes")
        let sourceAttributes = try fm.attributesOfItem(atPath: copySource.path), destinationAttributes = try fm.attributesOfItem(atPath: copyDestination.path)
        try check((sourceAttributes[.posixPermissions] as? NSNumber) == (destinationAttributes[.posixPermissions] as? NSNumber), "real cross-device copy preserves POSIX mode")
        let xattrLength = getxattr(copyDestination.path, "com.rightmouse.volume-check", nil, 0, 0, 0)
        var copiedXattr = [UInt8](repeating: 0, count: max(0, xattrLength))
        let copiedXattrLength = copiedXattr.withUnsafeMutableBytes {
            getxattr(copyDestination.path, "com.rightmouse.volume-check", $0.baseAddress, $0.count, 0, 0)
        }
        try check(copiedXattrLength == xattrValue.count && copiedXattr == xattrValue, "real cross-device copy preserves extended attribute")

        let moveTarget = imageRoot.appendingPathComponent("move-target", isDirectory: true)
        try fm.createDirectory(at: moveTarget, withIntermediateDirectories: false)
        let moveSource = try write("move-source.bin", bytes: 1024 * 1024)
        let moveEngine = FileTransferEngine(journalDirectory: hostRoot.appendingPathComponent("move-journal"))
        let moved = await moveEngine.transfer(sources: [moveSource], to: moveTarget, mode: .move)
        let moveDestination = moveTarget.appendingPathComponent(moveSource.lastPathComponent)
        try check(moved.completedCount == 1 && !fm.fileExists(atPath: moveSource.path) && fm.fileExists(atPath: moveDestination.path), "real cross-device move removes source only after target commit")
        try check(moved.items[0].undoToken == nil, "real cross-device move does not advertise same-volume undo")

        let cancelTarget = imageRoot.appendingPathComponent("cancel-target", isDirectory: true)
        try fm.createDirectory(at: cancelTarget, withIntermediateDirectories: false)
        let cancelSource = try write("cancel-source.bin", bytes: 24 * 1024 * 1024)
        let cancellation = TransferCancellation()
        let cancelEngine = FileTransferEngine(journalDirectory: hostRoot.appendingPathComponent("cancel-journal"))
        let cancelled = await cancelEngine.transfer(sources: [cancelSource], to: cancelTarget, mode: .move, cancellation: cancellation,
                                                    onProgress: { progress in
            if progress.phase == "copying" && progress.bytesProcessed >= 1024 * 1024 { cancellation.cancel() }
        })
        try check(cancelled.items[0].status == .cancelled, "real cross-device streaming cancellation is reported")
        try check(fm.fileExists(atPath: cancelSource.path), "real cross-device cancellation retains source")
        try check(!fm.fileExists(atPath: cancelTarget.appendingPathComponent(cancelSource.lastPathComponent).path), "real cross-device cancellation exposes no final target")
        try check(try fm.contentsOfDirectory(atPath: cancelTarget.path).isEmpty, "real cross-device cancellation removes private staging")

        let fullTarget = imageRoot.appendingPathComponent("full-target", isDirectory: true)
        try fm.createDirectory(at: fullTarget, withIntermediateDirectories: false)
        let filler = imageRoot.appendingPathComponent("capacity-filler.bin")
        let fillerFD = open(filler.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard fillerFD >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        var reachedCapacity = false
        var randomBlock = [UInt8](repeating: 0, count: 1024 * 1024)
        defer { close(fillerFD) }
        for _ in 0..<256 {
            randomBlock.withUnsafeMutableBytes { arc4random_buf($0.baseAddress, $0.count) }
            let amount = randomBlock.withUnsafeBytes { Darwin.write(fillerFD, $0.baseAddress, $0.count) }
            if amount == randomBlock.count { continue }
            if amount < 0 && (errno == ENOSPC || errno == EDQUOT) { reachedCapacity = true; break }
            if amount >= 0 && amount < randomBlock.count { reachedCapacity = true; break }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        try check(reachedCapacity, "isolated image reaches its real capacity limit")
        let fullSource = try write("no-space-source.bin", bytes: 2 * 1024 * 1024)
        let fullEngine = FileTransferEngine(journalDirectory: hostRoot.appendingPathComponent("full-journal"))
        let noSpace = await fullEngine.transfer(sources: [fullSource], to: fullTarget, mode: .move)
        try check(noSpace.items[0].failure?.code == .noSpace && fm.fileExists(atPath: fullSource.path), "real ENOSPC is structured and retains move source")
        try check(!fm.fileExists(atPath: fullTarget.appendingPathComponent(fullSource.lastPathComponent).path), "real ENOSPC exposes no final target")
        return count
    }
}
