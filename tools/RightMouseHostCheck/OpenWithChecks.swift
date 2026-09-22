import Foundation
import RightMouseCore

private struct OpenWithCheckFailure: Error, CustomStringConvertible { let description: String }

@MainActor
func runOpenWithChecks() throws -> Int {
    var count = 0
    func check(_ condition: @autoclosure () throws -> Bool, _ name: String) throws {
        guard try condition() else { throw OpenWithCheckFailure(description: name) }
        count += 1; print("PASS open-with: \(name)")
    }
    func rejects(_ name: String, _ action: () throws -> Void) throws {
        do { try action() } catch { count += 1; print("PASS open-with: \(name)"); return }
        throw OpenWithCheckFailure(description: "unexpected acceptance: \(name)")
    }

    let a = URL(fileURLWithPath: "/fixture/a/file.swift")
    let b = URL(fileURLWithPath: "/fixture/a/test.swift")
    let c = URL(fileURLWithPath: "/fixture/b/readme.md")
    let directory = URL(fileURLWithPath: "/fixture/project", isDirectory: true)
    try check(try OpenWithPlanning.plan(items: [.init(url: a, isDirectory: false)], adapterType: "vscode") == .launch([a]), "VS Code opens one file directly")
    try check(try OpenWithPlanning.plan(items: [.init(url: directory, isDirectory: true)], adapterType: "vscode") == .launch([directory]), "VS Code opens one directory as a project")
    try check(try OpenWithPlanning.plan(items: [.init(url: a, isDirectory: false), .init(url: b, isDirectory: false)], adapterType: "vscode") == .launch([a,b]), "VS Code preserves same-parent file semantics")
    try check(try OpenWithPlanning.plan(items: [.init(url: a, isDirectory: false), .init(url: c, isDirectory: false)], adapterType: "vscode") == .chooseProjectDirectory, "VS Code cross-directory files require one project")
    try check(try OpenWithPlanning.plan(items: [.init(url: directory, isDirectory: true), .init(url: a, isDirectory: false)], adapterType: "vscode") == .chooseProjectDirectory, "VS Code multi-selection containing a directory requires one project")
    try check(try OpenWithPlanning.plan(items: [.init(url: a, isDirectory: false), .init(url: c, isDirectory: false)], adapterType: "urls") == .launch([a,c]), "custom applications retain standard URL delivery")
    try check(try OpenWithPlanning.plan(items: [.init(url: a, isDirectory: false)], adapterType: "terminal") == .launch([a.deletingLastPathComponent().standardizedFileURL]), "Terminal derives the working directory from a selected file")
    try check(try OpenWithPlanning.plan(items: [.init(url: directory, isDirectory: true)], adapterType: "terminal") == .launch([directory.standardizedFileURL]), "Terminal preserves a selected working directory")
    try rejects("empty selection is rejected") { _ = try OpenWithPlanning.plan(items: [], adapterType: "vscode") }
    try rejects("non-file URL selection is rejected") {
        _ = try OpenWithPlanning.plan(items: [.init(url: URL(string: "https://example.invalid/file")!, isDirectory: false)], adapterType: "urls")
    }
    try OpenWithPlanning.validateAdapter(.init(id: "vscode", name: "Code", bundleID: "com.microsoft.VSCode", adapterType: "vscode"), applicationBundleID: "com.microsoft.VSCode")
    try check(true, "VS Code adapter accepts the matching installed bundle")
    try rejects("VS Code adapter rejects a mismatched bundle") {
        try OpenWithPlanning.validateAdapter(.init(id: "vscode", name: "Fake", bundleID: "example.fake", adapterType: "vscode"), applicationBundleID: "example.fake")
    }
    try rejects("Terminal adapter rejects a non-Terminal bundle") {
        try OpenWithPlanning.validateAdapter(.init(id: "terminal", name: "Other", bundleID: "example.terminal", adapterType: "terminal"), applicationBundleID: "example.terminal")
    }
    try OpenWithPlanning.validateAdapter(.init(id: "custom", name: "Custom", bundleID: "example.custom", adapterType: "urls"), applicationBundleID: "example.custom")
    try check(true, "custom URL adapter accepts only its configured bundle")
    try rejects("custom URL adapter rejects installed bundle mismatch") {
        try OpenWithPlanning.validateAdapter(.init(id: "custom", name: "Custom", bundleID: "example.custom", adapterType: "urls"), applicationBundleID: "example.other")
    }
    return count
}
