import Foundation
import RightMouseCore

private struct BenchmarkResult: Codable {
    let scenario: String
    let measurementScope: String
    let sampleCount: Int
    let configuredActions: Int
    let templates: Int
    let favorites: Int
    let integrations: Int
    let recentDestinations: Int
    let recentFavoriteDuplicates: Int
    let recentEntriesPerTransferMenu: Int
    let snapshotSchemaVersion: Int
    let selectedItems: Int
    let distinctSelectionParents: Int
    let compactMenu: Bool
    let groups: Int
    let topLevelEntries: Int
    let totalTreeEntries: Int
    let executableEntries: Int
    let disabledEntries: Int
    let firstSampleMilliseconds: Double
    let minimumMilliseconds: Double
    let medianMilliseconds: Double
    let p95Milliseconds: Double
    let maximumMilliseconds: Double
    let warmSampleCount: Int
    let warmP95Milliseconds: Double
    let nearestRankDefinition: String
    let rawMilliseconds: [Double]
    let allSamplesRetained: Bool
    let ruleP95Below50Milliseconds: Bool
    let thermalStateBefore: Int
    let thermalStateAfter: Int
    let checksum: Int
}

private struct Fixture {
    let snapshot: MenuConfigurationSnapshot
    let context: ActionContext
    let pending: PendingMoveSnapshot
    let now: Date
    let distinctParents: Int
}

private enum BenchmarkFailure: Error {
    case invalidScenario, outputChanged, emptyOutput
}

@main private struct MenuPolicyBenchmark {
    static func main() throws {
        let scenario = CommandLine.arguments.dropFirst().first ?? "100-actions-one-selection"
        let fixture = try makeFixture(scenario)
        // Validation and all fixture setup happen before the first timed policy call.
        try fixture.snapshot.validate()
        let before = ProcessInfo.processInfo.thermalState.rawValue
        var samples: [Double] = []
        var expected: Counts?
        var checksum = 0
        for _ in 0..<100 {
            let start = DispatchTime.now().uptimeNanoseconds
            let entries = build(fixture)
            let finish = DispatchTime.now().uptimeNanoseconds
            samples.append(Double(finish - start) / 1_000_000)
            // Consume and validate every returned tree outside the timed interval;
            // do not measure merely calling an optimizer-eliminated pure function.
            let observed = counts(entries)
            guard observed.total > 0 && observed.executable > 0 else { throw BenchmarkFailure.emptyOutput }
            let transferMenuCount = fixture.snapshot.actions.filter { ["copyTo", "moveTo"].contains($0.commandType) }.count
            guard observed.recentMenus == transferMenuCount, observed.recentLeaves == transferMenuCount * 7 else { throw BenchmarkFailure.outputChanged }
            if let expected, expected != observed { throw BenchmarkFailure.outputChanged }
            else { expected = observed }
            checksum &+= observed.total + observed.executable + observed.titleLength
        }
        let output = expected!
        let p95 = nearestRank(samples, probability: 0.95)
        let result = BenchmarkResult(
            scenario: scenario,
            measurementScope: "MenuPolicy.entries(snapshot:) only; excludes AppConfiguration projection, JSON decoding, Finder callback, NSMenu construction, configuration IO, IPC, and GUI latency",
            sampleCount: samples.count,
            configuredActions: fixture.snapshot.actions.count,
            templates: fixture.snapshot.templates.count,
            favorites: fixture.snapshot.favorites.count,
            integrations: fixture.snapshot.integrations.count,
            recentDestinations: fixture.snapshot.recentDestinations.count,
            recentFavoriteDuplicates: 3,
            recentEntriesPerTransferMenu: 7,
            snapshotSchemaVersion: fixture.snapshot.schemaVersion,
            selectedItems: fixture.context.selection.count,
            distinctSelectionParents: fixture.distinctParents,
            compactMenu: fixture.snapshot.compactMenu,
            groups: Set(fixture.snapshot.actions.compactMap(\.groupID)).count,
            topLevelEntries: output.top,
            totalTreeEntries: output.total,
            executableEntries: output.executable,
            disabledEntries: output.disabled,
            firstSampleMilliseconds: samples[0],
            minimumMilliseconds: samples.min()!,
            medianMilliseconds: nearestRank(samples, probability: 0.5),
            p95Milliseconds: p95,
            maximumMilliseconds: samples.max()!,
            warmSampleCount: samples.count - 1,
            warmP95Milliseconds: nearestRank(Array(samples.dropFirst()), probability: 0.95),
            nearestRankDefinition: "Sort ascending; percentile p is sample at one-based rank ceil(p * n). All-sample P95 uses rank 95 of 100; warm P95 uses rank 95 of 99.",
            rawMilliseconds: samples,
            allSamplesRetained: true,
            ruleP95Below50Milliseconds: p95 < 50,
            thermalStateBefore: before,
            thermalStateAfter: ProcessInfo.processInfo.thermalState.rawValue,
            checksum: checksum)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        print(String(decoding: try encoder.encode(result), as: UTF8.self))
    }

    @inline(never) private static func build(_ fixture: Fixture) -> [MenuEntry] {
        MenuPolicy.entries(snapshot: fixture.snapshot, context: fixture.context, pendingMove: fixture.pending, now: fixture.now)
    }

    private static func makeFixture(_ scenario: String) throws -> Fixture {
        let actionCount: Int, selectedCount: Int, parentCount: Int, compact: Bool
        switch scenario {
        case "100-actions-one-selection": (actionCount, selectedCount, parentCount, compact) = (100, 1, 1, false)
        case "100-actions-1024-selection": (actionCount, selectedCount, parentCount, compact) = (100, 1024, 32, true)
        case "8-actions-one-selection": (actionCount, selectedCount, parentCount, compact) = (8, 1, 1, false)
        default: throw BenchmarkFailure.invalidScenario
        }
        var configuration = AppConfiguration()
        let defaults = configuration.actions
        // The stored model allows 100 actions with unique IDs. The current UI
        // starts with eight categories; this fixture repeats those allowed types.
        configuration.actions = (0..<actionCount).map { index in
            let base = defaults[index % defaults.count]
            return ConfiguredAction(id: "benchmark.action.\(index)", commandType: base.commandType,
                                    title: "\(base.title) \(index + 1)", order: actionCount - index,
                                    groupID: actionCount == 100 ? "分组 \(index % 20)" : nil)
        }
        configuration.templates = (0..<100).map { index in
            FileTemplate(id: "benchmark.template.\(index)", name: "Markdown 模板 \(index + 1)", resourceName: "md",
                         filename: "模板 \(index + 1).md", isBuiltIn: true)
        }
        configuration.favorites = (0..<100).map { index in
            SavedLocation(id: stableUUID(index + 1), name: "常用目录 \(index + 1)", path: "/RightMouseBenchmark/favorites/\(index)", order: 100 - index)
        }
        configuration.integrations = (0..<100).map { index in
            AppIntegration(id: "benchmark.integration.\(index)", name: "应用 \(index + 1)", bundleID: "test.benchmark.application\(index)", adapterType: index == 0 ? "terminal" : "urls")
        }
        configuration.compactMenu = compact
        let selection = (0..<selectedCount).map { index in
            FileReference(refID: stableUUID(index + 1000), url: URL(fileURLWithPath: "/RightMouseBenchmark/selection/parent-\(index % parentCount)/文件 \(index).md"), kindHint: .file)
        }
        let context = ActionContext(invocationID: stableUUID(5000), entryPoint: .items,
                                    container: FileReference(refID: stableUUID(5001), url: URL(fileURLWithPath: "/RightMouseBenchmark/selection", isDirectory: true), kindHint: .directory), selection: selection)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        // Match Finder's already decoded, authority-free snapshot input. Recent
        // entries need display metadata only, not manufactured security bookmarks.
        // Three of ten targets overlap favorites, exercising real deduplication.
        let encoded = try JSONEncoder().encode(MenuConfigurationSnapshot(configuration: configuration))
        var object = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
        object["recentDestinations"] = (0..<10).map { index in
            ["id": stableUUID(7000 + index).uuidString,
             "name": "最近目录 \(index + 1)",
             "path": index < 3 ? "/RightMouseBenchmark/favorites/\(index)" : "/RightMouseBenchmark/recent/\(index)",
             "order": index] as [String: Any]
        }
        let snapshot = try JSONDecoder().decode(MenuConfigurationSnapshot.self, from: JSONSerialization.data(withJSONObject: object))
        try snapshot.validate()
        return Fixture(snapshot: snapshot, context: context,
                       pending: PendingMoveSnapshot(token: stableUUID(6000), count: 16, expiresAt: now.addingTimeInterval(120)),
                       now: now, distinctParents: parentCount)
    }

    private static func stableUUID(_ value: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-4000-8000-%012llx", Int64(value)))!
    }
    private struct Counts: Equatable {
        var top = 0, total = 0, executable = 0, disabled = 0, titleLength = 0, recentMenus = 0, recentLeaves = 0
    }
    private static func counts(_ entries: [MenuEntry]) -> Counts {
        var value = Counts(); value.top = entries.count
        func walk(_ entries: [MenuEntry]) {
            for entry in entries {
                value.total += 1; value.titleLength += entry.title.utf8.count
                if entry.action != nil { value.executable += 1 }
                if entry.id == "copy.recent" || entry.id == "move.recent" { value.recentMenus += 1 }
                if entry.id.hasPrefix("copy.recent.") || entry.id.hasPrefix("move.recent.") { value.recentLeaves += 1 }
                if !entry.enabled { value.disabled += 1 }
                walk(entry.children)
            }
        }
        walk(entries)
        return value
    }
    private static func nearestRank(_ values: [Double], probability: Double) -> Double {
        values.sorted()[max(0, Int(ceil(probability * Double(values.count))) - 1)]
    }
}
