import SwiftUI
import RightMouseCore

struct RecentDestinationsView: View {
    @ObservedObject var model: AppModel
    var onSelect: () -> Void
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text("\(model.configuration.recentDestinations.count) / 10 个目录").foregroundStyle(.secondary)
                    Spacer()
                    Button("检查可用性") { model.refreshRecentDestinations() }
                    Button("清空记录") { model.clearRecentDestinations() }
                        .disabled(model.configuration.recentDestinations.isEmpty || model.isReadOnly)
                }
                Text("选择或成功使用目标后自动更新顺序。这里只保存目录记录；移除或清空不会删除文件，也不会清除收藏。").font(.caption).foregroundStyle(.secondary)
                if model.configuration.recentDestinations.isEmpty {
                    ContentUnavailableView("还没有最近目标", systemImage: "folder.badge.clock", description: Text("在文件操作台选择一个目标目录，或从 Finder 执行复制到、移动到后，会显示在这里。"))
                        .frame(maxWidth: .infinity).padding(.vertical, 28)
                }
                ForEach(model.configuration.recentDestinations) { item in
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(alignment: .top) {
                            Image(systemName: "folder.fill").font(.title2).foregroundStyle(.blue)
                            VStack(alignment: .leading, spacing: 5) {
                                Text(item.name).font(.headline)
                                Text(item.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled).lineLimit(2).truncationMode(.middle)
                                Text("上次使用：\(item.lastUsedAt.formatted(date: .abbreviated, time: .shortened))").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                        if let problem = model.recentDestinationIssues[item.id] {
                            Label(problem, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
                        }
                        HStack {
                            Button("设为目标") { if model.selectRecentDestination(item.id) { onSelect() } }
                                .buttonStyle(.borderedProminent).disabled(model.recentDestinationIssues[item.id] != nil)
                                .accessibilityLabel("将 \(item.name) 设为目标")
                            Button("重新选择…") { model.repairRecentDestination(item.id) }.disabled(model.isReadOnly)
                                .accessibilityLabel("重新选择最近目标 \(item.name)")
                            Spacer()
                            Button("移除记录") { model.removeRecentDestination(item.id) }.disabled(model.isReadOnly)
                                .accessibilityLabel("移除最近目标 \(item.name)")
                        }
                    }.padding(16).background(.quaternary.opacity(0.22), in: RoundedRectangle(cornerRadius: 12))
                        .accessibilityElement(children: .contain)
                }
            }.padding(.horizontal, 24).padding(.bottom, 24)
        }.onAppear { model.refreshRecentDestinations() }
    }
}
