import AppKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class ManageWindowController {
    private let model: GroupManagementModel
    private var window: NSWindow?

    init(onChanged: @escaping ([AppGroup]) -> Void, onDelete: @escaping (UUID) -> Void, onPermissions: @escaping () -> Void,
         onOpen: @escaping (UUID) -> Void = { _ in }, nativeHost: Bool = false) {
        model = GroupManagementModel(onChanged: onChanged, onDelete: onDelete, onPermissions: onPermissions,
                                     onOpen: onOpen, nativeHost: nativeHost)
    }

    func show(groups: [AppGroup], status: String, selectedID: UUID? = nil) {
        refresh(groups: groups, status: status)
        if let selectedID, groups.contains(where: { $0.id == selectedID }) { model.selectedID = selectedID }
        if window == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 780, height: 570),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            window.title = "Dock 分组"
            window.isReleasedWhenClosed = false
            window.minSize = NSSize(width: 690, height: 480)
            window.contentView = NSHostingView(rootView: GroupManagementView(model: model))
            window.center()
            self.window = window
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    /// 后台状态变化只更新已有视图，不打开窗口或抢占焦点。
    func refresh(groups: [AppGroup], status: String) {
        model.groups = groups
        model.status = status
        if model.selectedID == nil || !groups.contains(where: { $0.id == model.selectedID }) { model.selectedID = groups.first?.id }
    }

    func updateStatus(_ text: String) { model.status = text }
}

@MainActor
private final class GroupManagementModel: ObservableObject {
    @Published var groups: [AppGroup] = []
    @Published var selectedID: UUID?
    @Published var status = "正在启动应用栏…"
    let onChanged: ([AppGroup]) -> Void
    let onDelete: (UUID) -> Void
    let onPermissions: () -> Void
    let onOpen: (UUID) -> Void
    let nativeHost: Bool

    init(onChanged: @escaping ([AppGroup]) -> Void, onDelete: @escaping (UUID) -> Void, onPermissions: @escaping () -> Void,
         onOpen: @escaping (UUID) -> Void, nativeHost: Bool) {
        self.onChanged = onChanged
        self.onDelete = onDelete
        self.onPermissions = onPermissions
        self.onOpen = onOpen
        self.nativeHost = nativeHost
    }

    var selectedGroup: AppGroup? { groups.first { $0.id == selectedID } }

    func update(_ update: (inout AppGroup) -> Void) {
        guard let index = groups.firstIndex(where: { $0.id == selectedID }) else { return }
        update(&groups[index])
        onChanged(groups)
    }

    func add(_ urls: [URL]) {
        update { group in
            for url in urls {
                if let app = AppReference(url: url), !group.apps.contains(where: { $0.path == app.path }) { group.apps.append(app) }
            }
        }
    }

    func selectApps() {
        let picker = NSOpenPanel()
        picker.title = "添加应用"
        picker.prompt = "添加到分组"
        picker.directoryURL = URL(fileURLWithPath: "/Applications")
        picker.allowedContentTypes = [.applicationBundle]
        picker.canChooseDirectories = false
        picker.canChooseFiles = true
        picker.allowsMultipleSelection = true
        if picker.runModal() == .OK { add(picker.urls) }
    }

    func removeGroup() {
        guard let group = selectedGroup else { return }
        let alert = NSAlert()
        alert.messageText = "解散“\(group.name)”？"
        alert.informativeText = "应用栏中的分组将解散，组内应用不会被卸载。"
        alert.addButton(withTitle: "取消")
        alert.addButton(withTitle: "解散分组")
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        groups.removeAll { $0.id == group.id }
        selectedID = groups.first?.id
        onDelete(group.id)
    }
}

@MainActor
private struct GroupManagementView: View {
    @ObservedObject var model: GroupManagementModel

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "square.grid.2x2.fill").font(.system(size: 28)).foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 5) {
                    Text("把应用收进文件夹").font(.title2.bold())
                    Text("在 Dock 将一个 App 拖到另一个中央，出现建组提示后松开。").font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
            }.padding(22)
            Divider()
            HSplitView {
                VStack(alignment: .leading, spacing: 12) {
                    Text("我的分组").font(.headline).padding(.horizontal, 12).padding(.top, 15)
                    List(selection: $model.selectedID) {
                        ForEach(model.groups) { group in
                            HStack {
                                Image(systemName: "folder.fill").foregroundStyle(.tint)
                                Text(group.name).lineLimit(1)
                                Spacer()
                                Text("\(group.apps.count)").foregroundStyle(.secondary)
                            }.tag(group.id)
                        }
                    }.listStyle(.sidebar)
                    Button("解散所选分组…") { model.removeGroup() }
                        .disabled(model.selectedGroup == nil).padding(.horizontal, 12).padding(.bottom, 12)
                }.frame(minWidth: 190, idealWidth: 210, maxWidth: 270)
                if let group = model.selectedGroup {
                    GroupManagementDetails(model: model, group: group).id(group.id)
                } else {
                    VStack(spacing: 12) {
                        Image(systemName: "arrow.down.app").font(.system(size: 40)).foregroundStyle(.secondary)
                        Text("从应用栏拖叠开始创建分组").font(.headline)
                        Text("创建后可以在这里改名、添加应用和调整顺序。")
                            .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    }.frame(maxWidth: .infinity, maxHeight: .infinity).padding(28)
                }
            }
            Divider()
            HStack(spacing: 12) {
                Image(systemName: "dock.rectangle").foregroundStyle(.secondary)
                Text(model.status).font(.caption).textSelection(.enabled)
                Spacer()
                Button(model.nativeHost ? "恢复原始固定应用并退出" : "恢复系统 Dock") { model.onPermissions() }
            }.padding(14)
        }
    }
}

@MainActor
private struct GroupManagementDetails: View {
    @ObservedObject var model: GroupManagementModel
    let group: AppGroup
    @State private var draftName: String
    @State private var dropTarget = false

    init(model: GroupManagementModel, group: AppGroup) {
        self.model = model
        self.group = group
        _draftName = State(initialValue: group.name)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                TextField("分组名称", text: $draftName).textFieldStyle(.roundedBorder).onSubmit { saveName() }
                Button("保存名称") { saveName() }
            }
            HStack {
                Text("应用顺序").font(.headline)
                Spacer()
                Button("展开分组") { model.onOpen(group.id) }
                    .keyboardShortcut("o", modifiers: .command)
                Button("添加应用…") { model.selectApps() }
            }
            List {
                ForEach(Array(group.apps.enumerated()), id: \.element.path) { index, app in
                    HStack(spacing: 10) {
                        Image(nsImage: ShelfAppActions.icon(app)).resizable().frame(width: 30, height: 30)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(app.name)
                            if !FileManager.default.fileExists(atPath: app.path) {
                                Text("原应用已移动或不存在").font(.caption).foregroundStyle(.orange)
                            }
                        }
                        Spacer()
                        Button { move(index, by: -1) } label: { Image(systemName: "chevron.up") }.disabled(index == 0).help("向前移动")
                        Button { move(index, by: 1) } label: { Image(systemName: "chevron.down") }.disabled(index == group.apps.count - 1).help("向后移动")
                        Button { model.update { $0.apps.removeAll { $0.path == app.path } } } label: { Image(systemName: "minus.circle") }.help("从分组移除，不卸载应用")
                    }.padding(.vertical, 4)
                }
            }
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(dropTarget ? Color.accentColor : Color.clear, lineWidth: 2))
            .onDrop(of: [UTType.fileURL.identifier], isTargeted: $dropTarget) { providers in
                acceptApplicationURLs(providers) { urls in model.add(urls) }
            }
            Text("可将 Finder 中的 .app 拖进列表。关闭分组面板后，应用仍会继续运行。")
                .font(.caption).foregroundStyle(.secondary)
        }.padding(22).frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
    }

    private func saveName() {
        let name = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { draftName = group.name; return }
        model.update { $0.name = name }
    }

    private func move(_ index: Int, by offset: Int) {
        model.update { group in
            let destination = index + offset
            if group.apps.indices.contains(index), group.apps.indices.contains(destination) { group.apps.swapAt(index, destination) }
        }
    }
}
