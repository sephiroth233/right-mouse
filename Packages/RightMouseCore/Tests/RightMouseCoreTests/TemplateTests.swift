import Foundation
import XCTest
@testable import RightMouseCore

final class TemplateTests: XCTestCase {
    private var root: URL!
    private var store: TemplateStore!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        store = TemplateStore(directory: root.appendingPathComponent("templates"))
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }
    func testBuiltInsAreValidAndNeverExecutable() throws {
        for template in FileTemplate.builtIns {
            let file = try store.create(template: template, in: root)
            XCTAssertEqual(file.lastPathComponent, template.filename)
            let mode = (try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber)?.intValue ?? 0
            XCTAssertEqual(mode & 0o111, 0)
            if template.id == "json" { XCTAssertNoThrow(try JSONSerialization.jsonObject(with: Data(contentsOf: file))) }
        }
    }
    func testNoClobberNamesAndInvalidNames() throws {
        let template = FileTemplate.builtIns[0]
        let first = try store.create(template: template, in: root)
        try Data("keep me".utf8).write(to: first)
        let second = try store.create(template: template, in: root)
        XCTAssertEqual(second.lastPathComponent, "未命名 2.txt")
        XCTAssertEqual(try String(contentsOf: first), "keep me")
        for name in ["", ".", "..", "../escape", "a/b", "a\0b"] { XCTAssertThrowsError(try store.create(template: template, in: root, filename: name)) }
    }
    func testBinaryCopyAndVariableFinalFilename() throws {
        let binary = root.appendingPathComponent("sample.dat")
        let bytes = Data([0, 255, 44, 0, 1])
        try bytes.write(to: binary)
        let imported = try store.importTemplate(from: binary)
        let copy = try store.create(template: imported, in: root)
        XCTAssertEqual(try Data(contentsOf: copy), bytes)
        XCTAssertThrowsError(try store.importTemplate(from: binary, variables: true))
        let source = root.appendingPathComponent("sample.txt")
        try Data("{{filename}}|{{date}}|{{unknown}}".utf8).write(to: source)
        let text = try store.importTemplate(from: source, variables: true)
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let output = try store.create(template: text, in: root, date: date)
        let value = try String(contentsOf: output)
        XCTAssertTrue(value.hasPrefix("sample 2.txt|"))
        XCTAssertTrue(value.hasSuffix("|{{unknown}}"))
        let unusual = try store.create(template: text, in: root, filename: "{{date}}.txt", date: date)
        XCTAssertTrue(try String(contentsOf: unusual).hasPrefix("{{date}}.txt|"))
    }
    func testRejectSymlinkAndDirectoryImport() throws {
        let source = root.appendingPathComponent("source")
        try Data().write(to: source)
        let link = root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: source)
        XCTAssertThrowsError(try store.importTemplate(from: link))
        XCTAssertThrowsError(try store.importTemplate(from: root))
    }
    func testConcurrentCreatorsGetDistinctNames() throws {
        let lock = NSLock()
        var results: [URL] = []
        var errors: [Error] = []
        DispatchQueue.concurrentPerform(iterations: 12) { _ in
            do { let value = try store.create(template: FileTemplate.builtIns[2], in: root); lock.lock(); results.append(value); lock.unlock() }
            catch { lock.lock(); errors.append(error); lock.unlock() }
        }
        XCTAssertTrue(errors.isEmpty)
        XCTAssertEqual(Set(results).count, 12)
        for value in results { XCTAssertEqual(try String(contentsOf: value), "{}\n") }
    }
}
