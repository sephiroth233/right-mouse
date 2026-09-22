import Foundation
import XCTest
@testable import RightMouseCore

final class SettingsTests: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws { root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString); try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true) }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }
    func testRoundTripAndMonotonicRevision() throws {
        let store = ConfigurationStore(directory: root)
        var configuration = try store.load(); configuration.compactMenu = true
        configuration = try store.save(configuration)
        XCTAssertEqual(configuration.revision, 1)
        XCTAssertEqual(try store.load(), configuration)
        XCTAssertEqual(try store.save(AppConfiguration()).revision, 2)
        let attributes = try FileManager.default.attributesOfItem(atPath: store.fileURL.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }
    func testCorruptionBackupAndReadOnlyReader() throws {
        let store = ConfigurationStore(directory: root)
        try Data("broken".utf8).write(to: store.fileURL)
        _ = try store.load(readOnly: true)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path).count, 1)
        _ = try store.load()
        XCTAssertNotNil(store.lastWarning)
        let backups = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).filter { $0.lastPathComponent.contains("corrupt") }
        XCTAssertEqual(backups.count, 1)
        XCTAssertEqual(try Data(contentsOf: backups[0]), Data("broken".utf8))
    }
    func testFutureVersionNeverOverwritten() throws {
        let store = ConfigurationStore(directory: root)
        let future = Data(#"{"schemaVersion":999,"newField":true}"#.utf8)
        try future.write(to: store.fileURL)
        XCTAssertThrowsError(try store.load())
        XCTAssertThrowsError(try store.save(AppConfiguration()))
        XCTAssertEqual(try Data(contentsOf: store.fileURL), future)
    }
    func testLimitsAndInvalidResources() throws {
        var config = AppConfiguration()
        config.favorites = (0...100).map { .init(name: "目录\($0)", path: "/tmp/\($0)") }
        XCTAssertThrowsError(try config.validate())
        config = AppConfiguration(); config.templates[0].resourceName = "../escape"
        XCTAssertThrowsError(try config.validate())
        config = AppConfiguration(); config.actions.append(config.actions[0])
        XCTAssertThrowsError(try config.validate())
    }
}
