import Foundation
import Darwin

public struct FileTemplate: Codable, Identifiable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var resourceName: String
    public var filename: String
    public var usesVariables: Bool
    public var isBuiltIn: Bool
    public init(id: String, name: String, resourceName: String, filename: String, usesVariables: Bool = false, isBuiltIn: Bool = false) {
        self.id = id; self.name = name; self.resourceName = resourceName; self.filename = filename; self.usesVariables = usesVariables; self.isBuiltIn = isBuiltIn
    }
    public static let builtIns: [FileTemplate] = [
        .init(id: "txt", name: "文本文档", resourceName: "txt", filename: "未命名.txt", isBuiltIn: true),
        .init(id: "md", name: "Markdown", resourceName: "md", filename: "未命名.md", isBuiltIn: true),
        .init(id: "json", name: "JSON", resourceName: "json", filename: "未命名.json", isBuiltIn: true),
        .init(id: "yaml", name: "YAML", resourceName: "yaml", filename: "未命名.yaml", isBuiltIn: true),
        .init(id: "html", name: "HTML", resourceName: "html", filename: "未命名.html", isBuiltIn: true),
        .init(id: "sh", name: "Shell 脚本", resourceName: "sh", filename: "未命名.sh", isBuiltIn: true)
    ]
    public func validate() throws {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !id.isEmpty else { throw TemplateError.invalidName }
        try TemplateStore.validateFilename(filename)
        try TemplateStore.validateFilename(resourceName)
        if isBuiltIn && !Self.builtIns.contains(where: { $0.resourceName == resourceName }) { throw TemplateError.invalidTemplate }
    }
}

public enum TemplateError: LocalizedError {
    case invalidName, invalidTemplate, notText, notDirectory, tooManyConflicts
    public var errorDescription: String? {
        switch self {
        case .invalidName: return "请输入有效的单个文件名，不能包含斜杠、空字符或 . / ..。"
        case .invalidTemplate: return "模板必须为普通文件；不支持符号链接、文件夹和应用包。"
        case .notText: return "变量仅支持不超过 16 MiB 的 UTF-8 文本模板。"
        case .notDirectory: return "请选择一个可写的目标文件夹。"
        case .tooManyConflicts: return "同名文件过多，请换一个文件名。"
        }
    }
}

public final class TemplateStore {
    public let directory: URL
    public init(directory: URL) { self.directory = directory }
    public static func validateFilename(_ name: String) throws {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains("\0") else { throw TemplateError.invalidName }
    }
    public func importTemplate(from url: URL, name: String? = nil, variables: Bool = false) throws -> FileTemplate {
        let scoped = url.startAccessingSecurityScopedResource(); defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .isPackageKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true, values.isPackage != true else { throw TemplateError.invalidTemplate }
        let identifier = UUID().uuidString
        let template = FileTemplate(id: identifier, name: name ?? url.deletingPathExtension().lastPathComponent, resourceName: identifier, filename: url.lastPathComponent, usesVariables: variables)
        try template.validate()
        try PrivateFileIO.ensureDirectory(directory)
        let target = directory.appendingPathComponent(identifier)
        do {
            try FileManager.default.copyItem(at: url, to: target)
            let copied = try target.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard copied.isRegularFile == true, copied.isSymbolicLink != true else { throw TemplateError.invalidTemplate }
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
            if variables { _ = try text(at: target) }
            return template
        } catch {
            try? FileManager.default.removeItem(at: target)
            throw error
        }
    }
    /// Resource cleanup is called only after configuration no longer references it.
    public func deleteResource(for template: FileTemplate) throws {
        try template.validate()
        guard !template.isBuiltIn else { return }
        let url = directory.appendingPathComponent(template.resourceName)
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }
    public func validateVariables(for template: FileTemplate) throws {
        try template.validate()
        if template.usesVariables && !template.isBuiltIn { _ = try text(at: directory.appendingPathComponent(template.resourceName)) }
    }
    public func create(template: FileTemplate, in destination: URL, filename: String? = nil, date: Date = Date()) throws -> URL {
        try template.validate()
        let original = filename ?? template.filename
        try Self.validateFilename(original)
        let destinationValues = try destination.resourceValues(forKeys: [.isDirectoryKey])
        guard destinationValues.isDirectory == true else { throw TemplateError.notDirectory }
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = "yyyy-MM-dd"
        let dateString = formatter.string(from: date)
        for sequence in 1...10000 {
            let candidate = sequence == 1 ? original : Self.numberedName(original, number: sequence)
            let target = destination.appendingPathComponent(candidate)
            let temporary = destination.appendingPathComponent(".rightmouse-create-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: temporary) }
            if template.isBuiltIn {
                let body = Self.builtInContents[template.resourceName] ?? ""
                let expanded = template.usesVariables ? Self.expand(body, date: dateString, filename: candidate) : body
                try Data(expanded.utf8).write(to: temporary, options: .withoutOverwriting)
            } else {
                let source = directory.appendingPathComponent(template.resourceName)
                let values = try source.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                guard values.isRegularFile == true, values.isSymbolicLink != true else { throw TemplateError.invalidTemplate }
                if template.usesVariables {
                    try Data(Self.expand(try text(at: source), date: dateString, filename: candidate).utf8).write(to: temporary, options: .withoutOverwriting)
                } else { try FileManager.default.copyItem(at: source, to: temporary) }
            }
            try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: temporary.path)
            let fd = open(temporary.path, O_RDONLY | O_NOFOLLOW)
            guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            let syncResult = fsync(fd); let syncError = errno; close(fd)
            guard syncResult == 0 else { throw POSIXError(POSIXErrorCode(rawValue: syncError) ?? .EIO) }
            if renamex_np(temporary.path, target.path, UInt32(RENAME_EXCL)) == 0 { return target }
            let code = errno
            if code != EEXIST { throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO) }
        }
        throw TemplateError.tooManyConflicts
    }
    private func text(at url: URL) throws -> String {
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= 16 * 1024 * 1024, let value = String(data: try Data(contentsOf: url), encoding: .utf8) else { throw TemplateError.notText }
        return value
    }
    private static func expand(_ text: String, date: String, filename: String) -> String {
        // Replace the original tokens once; inserted filenames are never interpreted again.
        let pattern = #"\{\{(date|filename)\}\}"#
        let regex = try! NSRegularExpression(pattern: pattern)
        var result = text
        for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
            guard let range = Range(match.range, in: result), let tokenRange = Range(match.range(at: 1), in: text) else { continue }
            result.replaceSubrange(range, with: text[tokenRange] == "date" ? date : filename)
        }
        return result
    }
    private static func numberedName(_ original: String, number: Int) -> String {
        let ns = original as NSString
        let ext = original.hasPrefix(".") && !original.dropFirst().contains(".") ? "" : ns.pathExtension
        return ext.isEmpty ? "\(original) \(number)" : "\(ns.deletingPathExtension) \(number).\(ext)"
    }
    private static let builtInContents = [
        "txt": "", "md": "", "json": "{}\n", "yaml": "",
        "html": "<!doctype html>\n<html lang=\"zh-CN\">\n<head>\n  <meta charset=\"utf-8\">\n  <meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">\n  <title>未命名</title>\n</head>\n<body>\n</body>\n</html>\n",
        "sh": "#!/bin/sh\n# 在此编写脚本；本文件默认没有执行权限。\n"
    ]
}
