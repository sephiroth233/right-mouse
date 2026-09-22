import Foundation
import Darwin

enum TransferFailureMapping {
    enum Context { case general, source, destination }

    static func failure(for error: Error, context: Context = .general) -> CommandFailure {
        if let failure = error as? CommandFailure { return failure }
        if let engine = error as? TransferEngineError { return failure(for: engine, context: context) }
        if let posix = error as? POSIXError { return failure(forErrno: posix.code.rawValue, fallback: posix.localizedDescription, context: context) }

        let cocoa = error as NSError
        if cocoa.domain == NSPOSIXErrorDomain {
            return failure(forErrno: Int32(cocoa.code), fallback: cocoa.localizedDescription, context: context)
        }
        if cocoa.domain == NSCocoaErrorDomain {
            switch CocoaError.Code(rawValue: cocoa.code) {
            case .fileNoSuchFile, .fileReadNoSuchFile:
                return .init(.sourceMissing, "来源不存在或已被移除。")
            case .fileReadNoPermission, .fileWriteNoPermission:
                return .init(.accessDenied, "没有读写所选项目的权限，请重新授权后再试。", retryable: true)
            case .fileWriteOutOfSpace:
                return .init(.noSpace, "目标磁盘空间不足，请释放空间后重试。", retryable: true)
            case .fileWriteVolumeReadOnly:
                return .init(.accessDenied, "目标卷为只读，无法完成文件操作。")
            default: break
            }
        }
        return .init(.ioFailed, "文件操作失败：\(error.localizedDescription)")
    }

    static func failure(for error: TransferEngineError, context: Context = .general) -> CommandFailure {
        switch error {
        case .invalidTarget, .descendantTarget:
            return .init(.invalidDestination, error.localizedDescription)
        case .invalidSource:
            return .init(.sourceMissing, error.localizedDescription)
        case .sourceChanged:
            return .init(.sourceChanged, error.localizedDescription)
        case .verificationFailed:
            // Before commit this means the staged copy could not be trusted; it
            // is not the two-visible-copies state represented by SOURCE_RETAINED.
            return .init(.ioFailed, error.localizedDescription)
        case .cancelled:
            return .init(.cancelled, error.localizedDescription)
        case .occupied:
            return .init(.destinationConflict, error.localizedDescription, retryable: true)
        case .unsafeUndo:
            return .init(.sourceChanged, error.localizedDescription)
        case .unsupportedFile:
            return .init(.metadataUnsupported, error.localizedDescription)
        case .journalVersion:
            return .init(.recoveryRequired, error.localizedDescription)
        case .system(let code):
            return failure(forErrno: code, fallback: error.localizedDescription, context: context)
        }
    }

    private static func failure(forErrno code: Int32, fallback: String, context: Context) -> CommandFailure {
        switch code {
        case ENOENT:
            if case .destination = context { return .init(.invalidDestination, "目标目录不存在或在操作期间被移除。", retryable: true) }
            return .init(.sourceMissing, "来源不存在或在操作期间被移除。")
        case EACCES, EPERM:
            return .init(.accessDenied, "没有读写所选项目的权限，请重新授权后再试。", retryable: true)
        case ENOSPC, EDQUOT:
            return .init(.noSpace, "目标磁盘空间不足，请释放空间后重试。", retryable: true)
        case ENODEV, ENXIO, ESTALE:
            return .init(.volumeUnavailable, "文件所在卷已断开或暂时不可用，请重新连接后重试。", retryable: true)
        case EEXIST, ENOTEMPTY:
            return .init(.destinationConflict, "目标已存在同名项目，未覆盖任何内容。", retryable: true)
        default:
            return .init(.ioFailed, "文件操作失败：\(fallback)")
        }
    }

    static func conservativeFailure(for error: Error, status: TransferItemStatus, committed: Bool) -> CommandFailure {
        if status == .sourceRetained {
            return .init(.sourceRetained, "目标已提交，来源仍保留；\(error.localizedDescription) 请核对两份内容。")
        }
        if status == .needsReview || committed {
            return .init(.recoveryRequired, "目标可能已提交；\(error.localizedDescription) 请核对操作记录、来源和目标。")
        }
        return failure(for: error)
    }
}
