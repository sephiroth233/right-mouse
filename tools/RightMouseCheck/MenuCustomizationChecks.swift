import Foundation
import RightMouseCore

func runMenuCustomizationChecks() throws -> Int {
    struct Failure: Error { let message: String }
    var count = 0
    func check(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try value() else { throw Failure(message: message) }; count += 1
        print("PASS menu-editor: \(message)")
    }
    func flatten(_ entries: [MenuEntry]) -> [MenuEntry] { entries.flatMap { [$0] + flatten($0.children) } }
    var config = AppConfiguration(); config.compactMenu = true
    MenuCustomization.set(.hidden, for: ["template.txt", "copy.path", "integration.vscode"], in: &config)
    let hidden = flatten(MenuPolicy.entries(configuration: config, context: MenuCustomization.context))
    try check(!hidden.contains { ["template.txt", "copy.path", "integration.vscode"].contains($0.id) }, "hidden leaves removed from real menu")
    try check(hidden.contains { $0.id == "template.md" }, "unmodified sibling remains visible")
    MenuCustomization.set(.topLevel, for: ["template.txt"], in: &config)
    try check(MenuCustomization.placement("template.txt", in: config) == .topLevel && !config.hiddenEntryIDs.contains("template.txt"), "placement values mutually exclusive")
    try check(MenuPolicy.entries(configuration: config, context: MenuCustomization.context).first?.id == "template.txt", "promoted template appears at root")
    MenuCustomization.set(.submenu, for: ["template.txt"], in: &config)
    try check(!config.topLevelEntryIDs.contains("template.txt") && MenuCustomization.placement("template.txt", in: config) == .submenu, "submenu removes promotion")
    let decoded = try JSONDecoder().decode(AppConfiguration.self, from: JSONEncoder().encode(config))
    try check(decoded == config, "hidden preferences persist losslessly")
    var old = try JSONSerialization.jsonObject(with: JSONEncoder().encode(config)) as! [String: Any]
    old.removeValue(forKey: "hiddenEntryIDs")
    let legacy = try JSONDecoder().decode(AppConfiguration.self, from: JSONSerialization.data(withJSONObject: old))
    try check(legacy.hiddenEntryIDs.isEmpty, "old configuration loads without hidden field")
    config.actions[0].enabled = false
    MenuCustomization.set(.topLevel, for: ["template.json"], in: &config)
    try check(MenuCustomization.placement("template.json", in: config) == .topLevel && MenuCustomization.placement("template.md", in: config) == .hidden, "restoring one disabled group child keeps siblings hidden")
    MenuCustomization.set(.submenu, for: ["template.txt", "template.md", "template.json"], in: &config)
    try check(["template.txt", "template.md", "template.json"].allSatisfy { MenuCustomization.placement($0, in: config) == .submenu }, "batch restores only requested entries")
    var flat = AppConfiguration()
    MenuCustomization.set(.hidden, for: ["template.txt"], in: &flat)
    try check(MenuPolicy.entries(configuration: flat, context: MenuCustomization.context).contains { $0.id == "copyTo" }, "editing legacy flat layout preserves other root actions")
    let snapshot = MenuConfigurationSnapshot(configuration: config)
    try check(flatten(MenuPolicy.entries(snapshot: snapshot, context: MenuCustomization.context)).map(\.id) == flatten(MenuPolicy.entries(configuration: config, context: MenuCustomization.context)).map(\.id), "Finder snapshot and editor use identical visibility")
    var local = AppConfiguration(); local.hiddenEntryIDs = ["template.txt"]
    let layout = try LocalMenuLayout.decode(LocalMenuLayout(configuration: local).encoded())
    try check(layout.configuration.hiddenEntryIDs == ["template.txt"], "legacy local display channel preserves hiding")
    var rejected = false
    let request = CommandRequest(context: MenuCustomization.context, action: .copyText(format: .path))
    do { try AuthenticatedFinderRequest.validate(request, configuration: config, pending: nil) } catch { rejected = true }
    try check(rejected, "host rejects stale requests for hidden commands")
    var invalid = config; invalid.hiddenEntryIDs = ["template.txt", "template.txt"]
    rejected = false; do { try invalid.validate() } catch { rejected = true }
    try check(rejected, "duplicate hidden IDs rejected")
    return count
}
