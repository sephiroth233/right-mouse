import Foundation
import RightMouseCore

private struct MenuCheckFailure: Error, CustomStringConvertible {
    let description: String
}

/// Framework-independent checks, runnable with Apple's Command Line Tools.
func runMenuChecks() throws -> Int {
    func check(_ value: @autoclosure () -> Bool, _ message: String) throws {
        if !value() { throw MenuCheckFailure(description: message) }
    }
    func flatten(_ entries: [MenuEntry]) -> [MenuEntry] { entries.flatMap { [$0] + flatten($0.children) } }
    let configuration = AppConfiguration()
    let background = ActionContext(entryPoint: .container, container: FileReference(url: URL(fileURLWithPath: "/tmp/menu-fixture", isDirectory: true), kindHint: .directory), selection: [])
    let backgroundMenu = flatten(MenuPolicy.entries(configuration: configuration, context: background))
    try check(!backgroundMenu.contains { $0.action == .stageMove }, "Background must not offer cut")
    try check(backgroundMenu.first { $0.id == "copy.name" }?.enabled == false, "Background must disable copying file names")
    try check(backgroundMenu.first { $0.id == "copy.path" }?.enabled == true, "Background supports directory paths")
    try check(!backgroundMenu.contains { $0.id == "copyTo" }, "Background must not offer file transfer")

    let toolbar = ActionContext(entryPoint: .toolbar, container: nil, selection: [])
    let toolbarMenu = flatten(MenuPolicy.entries(configuration: configuration, context: toolbar))
    try check(toolbarMenu.first { $0.id == "template.md" }?.action == .createFile(templateID: "md", destination: nil, name: nil), "Unknown target must request a host picker")
    try check(toolbarMenu.first { $0.id == "copy.path" }?.enabled == false, "No target means no path to copy")

    let now = Date(), token = UUID()
    let pending = PendingMoveSnapshot(token: token, count: 2, expiresAt: now.addingTimeInterval(60))
    let pendingMenu = flatten(MenuPolicy.entries(configuration: configuration, context: background, pendingMove: pending, now: now))
    try check(pendingMenu.first { $0.id == "pasteMove" }?.action == .pasteMove(pendingToken: token, destination: background.container, conflictPolicy: .ask), "Paste must preserve the exact active token and destination")
    let expiredMenu = flatten(MenuPolicy.entries(configuration: configuration, context: background, pendingMove: pending, now: now.addingTimeInterval(61)))
    try check(!expiredMenu.contains { $0.id == "pasteMove" }, "Expired cut must be absent")

    var custom = configuration
    custom.actions = [
        ConfiguredAction(id: "a", commandType: "copyText", title: "路径", order: 2, groupID: "文件"),
        ConfiguredAction(id: "b", commandType: "createFile", title: "新建", order: 1),
        ConfiguredAction(id: "c", commandType: "openWith", title: "关闭", enabled: false)
    ]
    custom.compactMenu = true
    let customMenu = MenuPolicy.entries(configuration: custom, context: background)
    try check(customMenu.count == 1, "Compact mode must wrap the configured actions")
    try check(customMenu[0].children.map(\.id) == ["b", "group.文件"], "Menu order and grouping must match settings")
    try check(customMenu[0].children[1].children.map(\.id) == ["a"], "Disabled actions must not be shown")

    let many = ActionContext(entryPoint: .items, container: background.container, selection: (0..<1025).map { FileReference(url: URL(fileURLWithPath: "/tmp/\($0)")) })
    let manyMenu = flatten(MenuPolicy.entries(configuration: configuration, context: many))
    try check(manyMenu.filter { $0.action != nil }.allSatisfy { !$0.enabled }, "Over-limit selections must not submit truncated or invalid requests")
    let mixed = ActionContext(entryPoint: .items, container: background.container, selection: [
        FileReference(url: URL(fileURLWithPath: "/tmp/one/a.txt")),
        FileReference(url: URL(fileURLWithPath: "/tmp/two/b.txt"))
    ])
    let mixedMenu = flatten(MenuPolicy.entries(configuration: configuration, context: mixed, pendingMove: pending, now: now))
    try check(mixedMenu.first { $0.id == "template.md" }?.action == .createFile(templateID: "md", destination: nil, name: nil), "Mixed parent folders require an explicit target for creation")
    try check(mixedMenu.first { $0.id == "pasteMove" }?.action == .pasteMove(pendingToken: token, destination: nil, conflictPolicy: .ask), "Mixed parent folders require an explicit paste target")
    return 6 + (try runMenuPromotionChecks())
}
