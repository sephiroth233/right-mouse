import Foundation
import RightMouseCore
let args = CommandLine.arguments
guard args.count >= 4 else { exit(64) }
let target = URL(fileURLWithPath: args[1], isDirectory: true)
let reference = FileReference(url: target, kindHint: .directory)
let mode = args[2]
let context: ActionContext
let action: CommandAction
if mode == "open" {
    context = ActionContext(entryPoint: .items, container: reference, selection: [FileReference(url: target.appendingPathComponent(args[3]), kindHint: .file)])
    action = .openWith(integrationID: "vscode", mode: .files)
} else {
    context = ActionContext(entryPoint: .container, container: reference, selection: [])
    action = .createFile(templateID: "txt", destination: reference, name: args[3])
}
let request = CommandRequest(context: context, action: action, now: mode == "expired" ? Date().addingTimeInterval(-300) : Date())
print(String(decoding: try WireCodec.encoder().encode(request), as: UTF8.self))
