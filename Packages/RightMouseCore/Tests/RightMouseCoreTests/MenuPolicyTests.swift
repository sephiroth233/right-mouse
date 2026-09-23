import XCTest
@testable import RightMouseCore

final class MenuPolicyTests: XCTestCase {
    private func flatten(_ entries: [MenuEntry]) -> [MenuEntry] { entries.flatMap { [$0] + flatten($0.children) } }
    private var background: ActionContext {
        ActionContext(entryPoint: .container, container: FileReference(url: URL(fileURLWithPath: "/tmp/menu-fixture", isDirectory: true), kindHint: .directory), selection: [])
    }
    func testBackgroundDoesNotOfferCutAndNameFormats() {
        let entries = flatten(MenuPolicy.entries(configuration: AppConfiguration(), context: background))
        XCTAssertFalse(entries.contains { $0.action == .stageMove })
        XCTAssertFalse(entries.first { $0.id == "copy.name" }!.enabled)
        XCTAssertTrue(entries.first { $0.id == "copy.path" }!.enabled)
        XCTAssertFalse(entries.contains { $0.id == "copyTo" })
    }
    func testMissingContextUsesHostDirectoryChoice() {
        let context = ActionContext(entryPoint: .toolbar, container: nil, selection: [])
        let entries = flatten(MenuPolicy.entries(configuration: AppConfiguration(), context: context))
        XCTAssertEqual(entries.first { $0.id == "template.md" }?.action, .createFile(templateID: "md", destination: nil, name: nil))
        XCTAssertFalse(entries.first { $0.id == "copy.path" }!.enabled)
    }
    func testExpiredMoveIsAbsentAndValidMovePreservesToken() {
        let now = Date(), token = UUID()
        let context = background
        let pending = PendingMoveSnapshot(token: token, count: 2, expiresAt: now.addingTimeInterval(60))
        let valid = flatten(MenuPolicy.entries(configuration: AppConfiguration(), context: context, pendingMove: pending, now: now))
        XCTAssertEqual(valid.first { $0.id == "pasteMove" }?.action, .pasteMove(pendingToken: token, destination: context.container, conflictPolicy: .ask))
        let expired = flatten(MenuPolicy.entries(configuration: AppConfiguration(), context: context, pendingMove: pending, now: now.addingTimeInterval(61)))
        XCTAssertFalse(expired.contains { $0.id == "pasteMove" })
    }
    func testConfiguredOrderGroupingAndCompactMode() {
        var config = AppConfiguration()
        config.actions = [
            ConfiguredAction(id: "a", commandType: "copyText", title: "路径", order: 2, groupID: "文件"),
            ConfiguredAction(id: "b", commandType: "createFile", title: "新建", order: 1),
            ConfiguredAction(id: "c", commandType: "openWith", title: "关闭", enabled: false)
        ]
        config.compactMenu = true
        let entries = MenuPolicy.entries(configuration: config, context: background)
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].children.map(\.id), ["b", "group.文件"])
        XCTAssertEqual(entries[0].children[1].children.map(\.id), ["a"])
    }
    func testMixedParentSelectionRequiresExplicitDestination() {
        let context = ActionContext(entryPoint: .items, container: background.container, selection: [
            FileReference(url: URL(fileURLWithPath: "/tmp/one/a.txt")),
            FileReference(url: URL(fileURLWithPath: "/tmp/two/b.txt"))
        ])
        let entries = flatten(MenuPolicy.entries(configuration: AppConfiguration(), context: context))
        XCTAssertEqual(entries.first { $0.id == "template.md" }?.action, .createFile(templateID: "md", destination: nil, name: nil))
    }
    func testOverLimitSelectionNeverSilentlyTruncatesCommands() {
        let context = ActionContext(entryPoint: .items, container: background.container, selection: (0..<1025).map { FileReference(url: URL(fileURLWithPath: "/tmp/\($0)")) })
        let entries = flatten(MenuPolicy.entries(configuration: AppConfiguration(), context: context))
        XCTAssertFalse(entries.first { $0.id == "stageMove" }!.enabled)
        XCTAssertFalse(entries.first { $0.id == "copyTo" }!.enabled)
        XCTAssertFalse(entries.first { $0.id == "copy.path" }!.enabled)
    }
}
