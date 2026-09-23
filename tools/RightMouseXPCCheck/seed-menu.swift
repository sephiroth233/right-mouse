import Foundation
import RightMouseCore

// Isolated UI acceptance configuration; never edits the user's real settings.
guard CommandLine.arguments.count == 2 else { exit(64) }
let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let paths = SharedPaths(root: root.appendingPathComponent("state"), privateRoot: root.appendingPathComponent("state/Host"), isDevelopmentFallback: true)
try paths.prepare()
let source = root.appendingPathComponent("source"), target = root.appendingPathComponent("target")
for directory in [source, target] { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
for name in ["source.txt", "move.txt", "cut.txt"] {
    try Data("RightMouse Finder acceptance: \(name)\n".utf8).write(to: source.appendingPathComponent(name))
}
let templateURL = root.appendingPathComponent("Finder Preview.txt")
try Data("Created from the configured custom template.\n".utf8).write(to: templateURL)
let template = try TemplateStore(directory: paths.templatesDirectory).importTemplate(from: templateURL, name: "验收模板")
let favorite = SavedLocation(name: "验收目标", path: target.path,
    bookmarkData: try target.bookmarkData(options: .withoutImplicitSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil), securityScoped: false)
let app = AppIntegration(id: "acceptance-textedit", name: "验收 TextEdit", bundleID: "com.apple.TextEdit", applicationPath: "/System/Applications/TextEdit.app")
var configuration = AppConfiguration()
configuration.templates.append(template); configuration.favorites.append(favorite); configuration.integrations.append(app)
configuration.revealCreatedFile = false; configuration.compactMenu = true
configuration.topLevelEntryIDs = ["template." + template.id, "integration." + app.id, "stageMove", "pasteMove", "copyTo", "moveTo", "favorite." + favorite.id.uuidString]
_ = try ConfigurationStore(directory: paths.configurationDirectory).save(configuration)
print(root.path)
