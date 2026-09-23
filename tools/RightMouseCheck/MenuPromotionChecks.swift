import Foundation
import RightMouseCore

func runMenuPromotionChecks() throws -> Int {
    var count = 0
    func check(_ value: Bool, _ message: String) throws {
        guard value else { throw ConfigurationError.invalid(message) }
        count += 1
    }
    func flatten(_ entries: [MenuEntry]) -> [MenuEntry] { entries.flatMap { [$0] + flatten($0.children) } }
    let folder = FileReference(url: URL(fileURLWithPath: "/tmp/menu", isDirectory: true), kindHint: .directory)
    let context = ActionContext(entryPoint: .items, container: folder, selection: [FileReference(url: folder.url.appendingPathComponent("a.txt"))])
    var config = AppConfiguration()
    config.compactMenu = true
    config.topLevelEntryIDs = ["copy.path", "template.txt", "integration.vscode"]
    let menu = MenuPolicy.entries(configuration: config, context: context)
    try check(menu.map(\.id) == config.topLevelEntryIDs + ["rightmouse"], "Leaves must be promoted in selection order")
    try check(menu[0].title == "复制完整路径" && menu[2].title == "使用 Visual Studio Code 打开", "Promoted leaves must be meaningful without their parent title")
    try check(flatten(menu).filter { config.topLevelEntryIDs.contains($0.id) }.count == 3, "Promoted commands must not be duplicated")
    try check(menu[1].action == .createFile(templateID: "txt", destination: folder, name: nil), "Promotion must preserve action and destination")
    config.topLevelEntryIDs = ["createFile", "template.txt"]
    config.actions[0].groupID = "常用"
    let both = MenuPolicy.entries(configuration: config, context: context)
    try check(both.prefix(2).map(\.id) == config.topLevelEntryIDs, "Parent and descendant can both be top-level")
    try check(!both[0].children.contains { $0.id == "template.txt" }, "Promoted descendant must be removed from promoted parent")
    try check(!flatten(both).contains { $0.id == "group.常用" }, "Empty groups must be removed")
    config.actions[0].enabled = false
    try check(!flatten(MenuPolicy.entries(configuration: config, context: context)).contains { $0.id == "template.txt" }, "Promotion must not re-enable disabled actions")
    config = AppConfiguration(); config.compactMenu = true
    config.actions = [ConfiguredAction(id: "createFile", commandType: "createFile", title: "新建文件")]
    config.topLevelEntryIDs = config.templates.map { "template." + $0.id }
    let all = MenuPolicy.entries(configuration: config, context: context)
    try check(all.count == config.templates.count && !all.contains { $0.id == "rightmouse" }, "All promoted leaves must not leave empty menus")
    config = AppConfiguration(); config.topLevelEntryIDs = ["copy.name", "copy.path", "stageMove", "nonexistent"]
    let background = ActionContext(entryPoint: .container, container: folder, selection: [])
    let blank = MenuPolicy.entries(configuration: config, context: background)
    try check(blank.first { $0.id == "copy.name" }?.enabled == false, "Promoted names must remain disabled on background")
    try check(!blank.contains { ["stageMove", "nonexistent"].contains($0.id) }, "Unavailable and obsolete IDs must not create commands")
    let many = ActionContext(entryPoint: .items, container: folder, selection: (0..<1025).map { FileReference(url: folder.url.appendingPathComponent("\($0)")) })
    try check(flatten(MenuPolicy.entries(configuration: config, context: many)).allSatisfy { !$0.enabled }, "Promotion must preserve selection count guard")
    var legacy = try JSONSerialization.jsonObject(with: JSONEncoder().encode(config)) as! [String: Any]
    legacy.removeValue(forKey: "topLevelEntryIDs")
    let old = try JSONDecoder().decode(AppConfiguration.self, from: JSONSerialization.data(withJSONObject: legacy))
    try check(old.topLevelEntryIDs.isEmpty && old.actions == config.actions, "Old configurations must retain settings")
    var oldSnapshot = try JSONSerialization.jsonObject(with: JSONEncoder().encode(MenuConfigurationSnapshot(configuration: config))) as! [String: Any]
    oldSnapshot.removeValue(forKey: "topLevelEntryIDs")
    let decoded = try JSONDecoder().decode(MenuConfigurationSnapshot.self, from: JSONSerialization.data(withJSONObject: oldSnapshot))
    try decoded.validate()
    try check(decoded.topLevelEntryIDs == nil, "Old menu snapshots must remain readable")
    config.topLevelEntryIDs = ["copy.path", "integration.vscode", "custom-private-template"]
    let layout = LocalMenuLayout(configuration: config)
    let wire = try layout.encoded()
    let restored = try LocalMenuLayout.decode(wire)
    try check(restored.topLevelEntryIDs == ["copy.path", "integration.vscode"], "Local layout must filter non-built-in IDs")
    try check(restored.configuration.favorites.isEmpty && restored.configuration.watchedLocations.isEmpty, "Local layout must not contain private paths")
    try check(MenuPolicy.entries(configuration: restored.configuration, context: context).prefix(2).map(\.id) == restored.topLevelEntryIDs, "Local projection and menu policy must agree")
    for invalid in [
        "{\"version\":2,\"compactMenu\":true,\"topLevelEntryIDs\":[]}",
        "{\"version\":1,\"compactMenu\":true,\"topLevelEntryIDs\":[\"evil\"]}",
        "{\"version\":1,\"compactMenu\":true,\"topLevelEntryIDs\":[\"copy.path\",\"copy.path\"]}",
        "{\"version\":1,\"compactMenu\":true,\"topLevelEntryIDs\":[],\"path\":\"/tmp/private\"}",
        String(repeating: "x", count: LocalMenuLayout.maximumBytes + 1)
    ] {
        var rejected = false
        do { _ = try LocalMenuLayout.decode(invalid) } catch { rejected = true }
        try check(rejected, "Invalid local layout payload must be rejected")
    }
    var bad = config; bad.topLevelEntryIDs = ["copy.path", "copy.path"]
    var rejected = false
    do { try bad.validate() } catch { rejected = true }
    try check(rejected, "Duplicate promotion IDs must fail persistence validation")
    return count
}
