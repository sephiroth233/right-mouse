import Foundation
import RightMouseCore

private struct SettingsCheckFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Runs against isolated temporary fixtures; never reads or changes user configuration.
func runSettingsChecks() throws -> Int {
    var count = 0
    func verify(_ condition: @autoclosure () throws -> Bool, _ label: String) throws {
        guard try condition() else { throw SettingsCheckFailure(message: label) }
        count += 1
    }
    func rejects(_ label: String, _ action: () throws -> Void) throws {
        do { try action() } catch { count += 1; return }
        throw SettingsCheckFailure(message: label)
    }
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("rightmouse-settings-check-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = ConfigurationStore(directory: root.appendingPathComponent("config"))
    var configuration = try store.load()
    try verify(configuration.templates.count == 6, "Expected six built-in templates")
    configuration.compactMenu = true
    configuration = try store.save(configuration)
    try verify(configuration.revision == 1 && configuration.compactMenu, "Configuration revision/change not saved")
    try verify(try store.load() == configuration, "Configuration round-trip differs")
    try verify(try store.save(AppConfiguration()).revision == 2, "Revision did not advance beyond stored value")
    let mode = try FileManager.default.attributesOfItem(atPath: store.fileURL.path)[.posixPermissions] as? NSNumber
    try verify(mode?.intValue == 0o600, "Configuration file permissions are not private")
    let future = Data(#"{"schemaVersion":999,"newField":true}"#.utf8)
    try future.write(to: store.fileURL)
    try rejects("Future configuration was accepted") { _ = try store.load() }
    try rejects("Future configuration was overwritten") { _ = try store.save(AppConfiguration()) }
    try verify(try Data(contentsOf: store.fileURL) == future, "Future data changed")
    try Data("broken".utf8).write(to: store.fileURL)
    let beforeRead = try FileManager.default.contentsOfDirectory(atPath: store.directory.path).count
    _ = try store.load(readOnly: true)
    try verify(try FileManager.default.contentsOfDirectory(atPath: store.directory.path).count == beforeRead, "Read-only configuration load wrote a backup")
    _ = try store.load()
    let backups = try FileManager.default.contentsOfDirectory(at: store.directory, includingPropertiesForKeys: nil).filter { $0.lastPathComponent.contains("corrupt") }
    try verify(backups.count == 1 && store.lastWarning != nil, "Corrupt configuration was not backed up")
    try verify(try Data(contentsOf: backups[0]) == Data("broken".utf8), "Corruption backup changed source bytes")
    var oversized = AppConfiguration()
    oversized.favorites = (0...100).map { .init(name: "目录\($0)", path: "/tmp/\($0)") }
    try rejects("Accepted 101 favorites") { try oversized.validate() }
    var traversal = AppConfiguration(); traversal.templates[0].resourceName = "../escape"
    try rejects("Accepted template resource path traversal") { try traversal.validate() }
    var duplicate = AppConfiguration(); duplicate.actions.append(duplicate.actions[0])
    try rejects("Accepted duplicate menu action ID") { try duplicate.validate() }

    let output = root.appendingPathComponent("output")
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    let templates = TemplateStore(directory: root.appendingPathComponent("templates"))
    for template in FileTemplate.builtIns {
        let file = try templates.create(template: template, in: output)
        try verify(file.lastPathComponent == template.filename, "Wrong built-in filename")
        let mode = (try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber)?.intValue ?? 0
        try verify(mode & 0o111 == 0, "New template file has executable permission")
        if template.id == "json" { _ = try JSONSerialization.jsonObject(with: Data(contentsOf: file)); count += 1 }
    }
    let existing = output.appendingPathComponent("未命名.txt")
    try Data("keep me".utf8).write(to: existing)
    let numbered = try templates.create(template: FileTemplate.builtIns[0], in: output)
    try verify(numbered.lastPathComponent == "未命名 2.txt", "No-clobber numbering failed")
    try verify(try String(contentsOf: existing) == "keep me", "Creation overwrote existing contents")
    for name in ["", ".", "..", "../escape", "a/b", "a\0b"] {
        try rejects("Accepted invalid filename") { _ = try templates.create(template: FileTemplate.builtIns[0], in: output, filename: name) }
    }
    let binary = root.appendingPathComponent("sample.dat")
    let bytes = Data([0, 255, 44, 0, 1])
    try bytes.write(to: binary)
    let imported = try templates.importTemplate(from: binary)
    try FileManager.default.removeItem(at: binary)
    let copied = try templates.create(template: imported, in: output)
    try verify(try Data(contentsOf: copied) == bytes, "Binary template changed or still depends on source")
    var binaryVariables = imported; binaryVariables.usesVariables = true
    try rejects("Invalid UTF-8 accepted for variables") { try templates.validateVariables(for: binaryVariables) }
    let source = root.appendingPathComponent("sample.txt")
    try Data("{{filename}}|{{date}}|{{unknown}}".utf8).write(to: source)
    let text = try templates.importTemplate(from: source, variables: true)
    _ = try templates.create(template: text, in: output)
    let second = try templates.create(template: text, in: output)
    let value = try String(contentsOf: second)
    try verify(value.hasPrefix("sample 2.txt|") && value.hasSuffix("|{{unknown}}"), "Variables ignored final numbered filename or interpreted unknown token")
    let tokenFilename = try templates.create(template: text, in: output, filename: "{{date}}.txt")
    try verify(try String(contentsOf: tokenFilename).hasPrefix("{{date}}.txt|"), "Inserted filename was interpreted as a template")
    let link = root.appendingPathComponent("link")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: source)
    try rejects("Accepted symlink template") { _ = try templates.importTemplate(from: link) }
    try rejects("Accepted directory template") { _ = try templates.importTemplate(from: root) }
    let lock = NSLock()
    var outputs: [URL] = []
    var failures: [Error] = []
    DispatchQueue.concurrentPerform(iterations: 12) { _ in
        do {
            let file = try templates.create(template: FileTemplate.builtIns[2], in: output)
            lock.lock(); outputs.append(file); lock.unlock()
        } catch { lock.lock(); failures.append(error); lock.unlock() }
    }
    try verify(failures.isEmpty && Set(outputs).count == 12, "Concurrent creators failed or used the same filename")
    for file in outputs { try verify(try String(contentsOf: file) == "{}\n", "Concurrent creation produced incomplete bytes") }
    return count
}
