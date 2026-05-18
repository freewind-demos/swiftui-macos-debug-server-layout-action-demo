import SwiftUI
import AppKit
import Foundation
import Network

// 定义可被调试面读取的节点快照。
struct DebugNodeSnapshot: Codable, Identifiable, Sendable {
    // 稳定节点 id，供外部查询与操作。
    let id: String
    // 组件语义角色，如 button、text、panel。
    let role: String
    // 可读标签，帮助 AI 理解用途。
    let label: String
    // 节点左上角 x。
    let x: Double
    // 节点左上角 y。
    let y: Double
    // 节点宽度。
    let width: Double
    // 节点高度。
    let height: Double
    // 当前是否可见。
    let isVisible: Bool
    // 当前允许的动作。
    let actions: [String]
}

// 汇总给 server 的整体快照。
struct DebugSnapshot: Codable, Sendable {
    // demo 当前时间戳。
    let timestamp: String
    // 业务状态摘要。
    let appState: AppStateSnapshot
    // 调试节点总数。
    let nodeCount: Int
    // 所有已注册节点。
    let nodes: [DebugNodeSnapshot]
    // 可调用语义动作名。
    let actionNames: [String]
}

// 对外暴露的业务状态摘要。
struct AppStateSnapshot: Codable, Sendable {
    // 计数器值。
    let counter: Int
    // 当前选中的卡片 id。
    let selectedCardID: String?
    // 最近一次事件文案。
    let latestEvent: String
    // 是否显示详情面板。
    let isDetailVisible: Bool
}

// 动作请求体。
struct ActionRequest: Codable {
    // 动作类型，当前支持 intent / node。
    let type: String
    // 语义动作名。
    let name: String?
    // 目标节点 id。
    let id: String?
    // 节点动作名。
    let action: String?
}

// 动作执行结果。
struct ActionResponse: Codable, Sendable {
    // 是否执行成功。
    let ok: Bool
    // 结果说明。
    let message: String
}

// 对外统一收口的共享业务状态。
@Observable
@MainActor
final class DemoStore {
    // 可被按钮与 server 共同操作的计数。
    var counter: Int = 0
    // 当前选中的卡片。
    var selectedCardID: String? = "alpha"
    // 最近一次事件，用来验证 server action 生效。
    var latestEvent: String = "App launched"
    // 控制详情面板显隐。
    var isDetailVisible: Bool = true

    // 自增计数，并记录来源。
    func incrementCounter(source: String) {
        counter += 1
        latestEvent = "Increment from \(source)"
    }

    // 切换详情面板。
    func toggleDetail(source: String) {
        isDetailVisible.toggle()
        latestEvent = "Toggle detail from \(source)"
    }

    // 选中某卡片。
    func selectCard(id: String, source: String) {
        selectedCardID = id
        latestEvent = "Select \(id) from \(source)"
    }

    // 生成对外快照。
    func snapshot() -> AppStateSnapshot {
        AppStateSnapshot(
            counter: counter,
            selectedCardID: selectedCardID,
            latestEvent: latestEvent,
            isDetailVisible: isDetailVisible
        )
    }
}

// 节点注册中心，负责收集布局与动作。
@Observable
@MainActor
final class DebugRegistry {
    // 所有节点快照，key 为稳定 id。
    private(set) var nodes: [String: DebugNodeSnapshot] = [:]
    // 所有语义动作。
    private var intents: [String: @MainActor () -> ActionResponse] = [:]
    // 所有节点动作，key 由 nodeId + actionName 组成。
    private var nodeActions: [String: @MainActor () -> ActionResponse] = [:]

    // 新增或覆盖节点快照。
    func upsert(_ node: DebugNodeSnapshot) {
        nodes[node.id] = node
    }

    // 移除已消失节点。
    func remove(id: String) {
        nodes.removeValue(forKey: id)
        nodeActions.keys
            .filter { $0.hasPrefix("\(id)::") }
            .forEach { nodeActions.removeValue(forKey: $0) }
    }

    // 注册语义动作。
    func registerIntent(name: String, perform: @escaping @MainActor () -> ActionResponse) {
        intents[name] = perform
    }

    // 注册节点动作。
    func registerNodeAction(id: String, action: String, perform: @escaping @MainActor () -> ActionResponse) {
        nodeActions["\(id)::\(action)"] = perform
    }

    // 组装完整快照。
    func snapshot(appState: AppStateSnapshot) -> DebugSnapshot {
        DebugSnapshot(
            timestamp: ISO8601DateFormatter().string(from: Date()),
            appState: appState,
            nodeCount: nodes.count,
            nodes: nodes.values.sorted { $0.id < $1.id },
            actionNames: intents.keys.sorted()
        )
    }

    // 执行动作请求。
    func perform(request: ActionRequest) -> ActionResponse {
        if request.type == "intent", let name = request.name, let action = intents[name] {
            return action()
        }
        if request.type == "node", let id = request.id, let actionName = request.action, let action = nodeActions["\(id)::\(actionName)"] {
            return action()
        }
        return ActionResponse(ok: false, message: "Unknown action request")
    }
}

// 自定义追踪视图，负责在布局变化与销毁时回调。
final class DebugTrackingView: NSView {
    // 布局或挂窗时触发。
    var onUpdate: ((NSView) -> Void)?
    // 视图销毁前触发。
    var onRemove: (() -> Void)?

    // 初始构造。
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        postsFrameChangedNotifications = true
        postsBoundsChangedNotifications = true
    }

    // storyboard 不使用。
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // 被挂到窗口时同步一次。
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        onUpdate?(self)
    }

    // 布局变化时同步一次。
    override func layout() {
        super.layout()
        onUpdate?(self)
    }

    // 被移出父级时清理节点。
    override func removeFromSuperview() {
        onRemove?()
        super.removeFromSuperview()
    }
}

// 用于把 NSView 的 frame 回传到 SwiftUI。
struct DebugFrameReporter: NSViewRepresentable {
    // 节点 id。
    let id: String
    // 组件角色。
    let role: String
    // 组件标签。
    let label: String
    // 允许的动作。
    let actions: [String]
    // 调试中心。
    let registry: DebugRegistry

    // 创建桥接视图。
    func makeNSView(context: Context) -> DebugTrackingView {
        let view = DebugTrackingView()
        view.onUpdate = { trackedView in
            updateSnapshot(from: trackedView)
        }
        view.onRemove = {
            registry.remove(id: id)
        }
        DispatchQueue.main.async {
            updateSnapshot(from: view)
        }
        return view
    }

    // 更新桥接视图时同步最新尺寸。
    func updateNSView(_ nsView: DebugTrackingView, context: Context) {
        nsView.onUpdate = { trackedView in
            updateSnapshot(from: trackedView)
        }
        nsView.onRemove = {
            registry.remove(id: id)
        }
        DispatchQueue.main.async {
            updateSnapshot(from: nsView)
        }
    }

    // SwiftUI 拆掉节点时强制清理 registry。
    static func dismantleNSView(_ nsView: DebugTrackingView, coordinator: ()) {
        nsView.onRemove?()
    }

    // 读取窗口坐标并写入 registry。
    private func updateSnapshot(from view: NSView) {
        guard let window = view.window else {
            return
        }
        let frame = view.convert(view.bounds, to: nil)
        let windowHeight = window.contentLayoutRect.height
        let topLeftY = windowHeight - frame.maxY
        registry.upsert(
            DebugNodeSnapshot(
                id: id,
                role: role,
                label: label,
                x: frame.minX,
                y: topLeftY,
                width: frame.width,
                height: frame.height,
                isVisible: !view.isHidden && view.alphaValue > 0.001,
                actions: actions
            )
        )
    }
}

// 把调试埋点收口成一个 modifier，减少真实业务代码侵入。
struct DebugNodeModifier: ViewModifier {
    // 节点 id。
    let id: String
    // 组件语义。
    let role: String
    // 对外标签。
    let label: String
    // 支持的动作。
    let actions: [String]
    // registry 来自环境。
    @Environment(DebugRegistry.self) private var registry

    // 在目标 view 背后挂一个透明 NSView 采样 frame。
    func body(content: Content) -> some View {
        content
            .background(
                DebugFrameReporter(
                    id: id,
                    role: role,
                    label: label,
                    actions: actions,
                    registry: registry
                )
            )
    }
}

// 给业务 view 提供统一埋点入口。
extension View {
    // 挂载 debug 节点描述。
    func debugNode(id: String, role: String, label: String, actions: [String] = []) -> some View {
        modifier(
            DebugNodeModifier(
                id: id,
                role: role,
                label: label,
                actions: actions
            )
        )
    }
}

// 真正承载 HTTP server 的 actor。
final class DebugHTTPServer: @unchecked Sendable {
    // 监听端口。
    private let port: UInt16
    // 拿业务状态快照。
    private let getSnapshot: @Sendable () async -> DebugSnapshot
    // 执行动作请求。
    private let performAction: @Sendable (ActionRequest) async -> ActionResponse
    // Network listener。
    private var listener: NWListener?

    // 初始化依赖。
    init(
        port: UInt16,
        getSnapshot: @escaping @Sendable () async -> DebugSnapshot,
        performAction: @escaping @Sendable (ActionRequest) async -> ActionResponse
    ) {
        self.port = port
        self.getSnapshot = getSnapshot
        self.performAction = performAction
    }

    // 启动本地监听。
    func start() throws {
        let parameters = NWParameters.tcp
        let listener = try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: port)!)
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else {
                return
            }
            Task {
                await self.handle(connection: connection)
            }
        }
        listener.start(queue: .global(qos: .userInitiated))
        self.listener = listener
    }

    // 停止监听。
    func stop() {
        listener?.cancel()
        listener = nil
    }

    // 处理单个连接。
    private func handle(connection: NWConnection) async {
        connection.start(queue: .global(qos: .userInitiated))
        do {
            let requestData = try await receiveAll(from: connection)
            let requestText = String(decoding: requestData, as: UTF8.self)
            let responseData = try await route(requestText: requestText)
            try await send(responseData, to: connection)
        } catch {
            let body = #"{"ok":false,"message":"\#(error.localizedDescription)"}"#
            let response = httpResponse(status: "500 Internal Server Error", body: body)
            try? await send(response, to: connection)
        }
        connection.cancel()
    }

    // 读取整个请求。
    private func receiveAll(from connection: NWConnection) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, isComplete, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                guard let data else {
                    continuation.resume(returning: Data())
                    return
                }
                if isComplete {
                    continuation.resume(returning: data)
                    return
                }
                continuation.resume(returning: data)
            }
        }
    }

    // 路由 HTTP 请求。
    private func route(requestText: String) async throws -> Data {
        let parts = requestText.components(separatedBy: "\r\n\r\n")
        let headerText = parts.first ?? ""
        let bodyText = parts.count > 1 ? parts[1] : ""
        let firstLine = headerText.components(separatedBy: "\r\n").first ?? ""
        let requestLine = firstLine.split(separator: " ")
        guard requestLine.count >= 2 else {
            return httpResponse(status: "400 Bad Request", body: #"{"ok":false,"message":"Bad request"}"#)
        }
        let method = String(requestLine[0])
        let path = String(requestLine[1])

        if method == "GET", path == "/snapshot" {
            let snapshot = await getSnapshot()
            let body = try jsonString(snapshot)
            return httpResponse(status: "200 OK", body: body)
        }

        if method == "POST", path == "/action" {
            let request = try JSONDecoder().decode(ActionRequest.self, from: Data(bodyText.utf8))
            let result = await performAction(request)
            let body = try jsonString(result)
            return httpResponse(status: result.ok ? "200 OK" : "400 Bad Request", body: body)
        }

        return httpResponse(status: "404 Not Found", body: #"{"ok":false,"message":"Not found"}"#)
    }

    // 发送响应。
    private func send(_ data: Data, to connection: NWConnection) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: ())
                }
            })
        }
    }

    // 编码 JSON 字符串。
    private func jsonString<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(value)
        return String(decoding: data, as: UTF8.self)
    }

    // 组装 HTTP 文本响应。
    private func httpResponse(status: String, body: String) -> Data {
        let payload = body.data(using: .utf8) ?? Data()
        let header = [
            "HTTP/1.1 \(status)",
            "Content-Type: application/json; charset=utf-8",
            "Content-Length: \(payload.count)",
            "Connection: close",
            "",
            "",
        ].joined(separator: "\r\n")
        return Data(header.utf8) + payload
    }
}

// app-shell，负责把 store、registry、server 装配起来。
@Observable
@MainActor
final class DemoAppShell {
    // 共享业务状态。
    let store = DemoStore()
    // 共享调试注册中心。
    let registry = DebugRegistry()
    // 内嵌 server。
    private var server: DebugHTTPServer?
    // 当前监听端口。
    let port: UInt16 = 7878

    // 启动全部依赖。
    func start() {
        installActions()
        server = DebugHTTPServer(
            port: port,
            getSnapshot: { [weak self] in
                await MainActor.run {
                    guard let self else {
                        return DebugSnapshot(
                            timestamp: ISO8601DateFormatter().string(from: Date()),
                            appState: AppStateSnapshot(
                                counter: 0,
                                selectedCardID: nil,
                                latestEvent: "Shell deallocated",
                                isDetailVisible: false
                            ),
                            nodeCount: 0,
                            nodes: [],
                            actionNames: []
                        )
                    }
                    return self.registry.snapshot(appState: self.store.snapshot())
                }
            },
            performAction: { [weak self] request in
                await MainActor.run {
                    guard let self else {
                        return ActionResponse(ok: false, message: "Shell deallocated")
                    }
                    return self.registry.perform(request: request)
                }
            }
        )
        do {
            try server?.start()
            store.latestEvent = "Debug server listening at http://127.0.0.1:\(port)"
        } catch {
            store.latestEvent = "Debug server failed: \(error.localizedDescription)"
        }
    }

    // 注册对外动作，保持真实状态修改仍经 store。
    private func installActions() {
        registry.registerIntent(name: "increment_counter") { [store] in
            store.incrementCounter(source: "server intent")
            return ActionResponse(ok: true, message: "Counter incremented")
        }
        registry.registerIntent(name: "toggle_detail") { [store] in
            store.toggleDetail(source: "server intent")
            return ActionResponse(ok: true, message: "Detail toggled")
        }
        registry.registerIntent(name: "select_beta") { [store] in
            store.selectCard(id: "beta", source: "server intent")
            return ActionResponse(ok: true, message: "Card beta selected")
        }
        registry.registerNodeAction(id: "increment_button", action: "press") { [store] in
            store.incrementCounter(source: "server node action")
            return ActionResponse(ok: true, message: "Pressed increment button")
        }
        registry.registerNodeAction(id: "detail_toggle", action: "press") { [store] in
            store.toggleDetail(source: "server node action")
            return ActionResponse(ok: true, message: "Pressed detail toggle")
        }
        registry.registerNodeAction(id: "card_beta", action: "press") { [store] in
            store.selectCard(id: "beta", source: "server node action")
            return ActionResponse(ok: true, message: "Pressed beta card")
        }
    }
}

// 顶层内容视图。
struct ContentView: View {
    // app-shell 来自环境。
    @Environment(DemoAppShell.self) private var shell

    // demo 主界面。
    var body: some View {
        @Bindable var store = shell.store

        HStack(spacing: 20) {
            VStack(alignment: .leading, spacing: 16) {
                Text("SwiftUI Debug Server Demo")
                    .font(.title2.bold())
                    .debugNode(id: "title_text", role: "text", label: "Demo title")

                Text("Node count and frame come from explicit debugNode markers.")
                    .foregroundStyle(.secondary)
                    .debugNode(id: "subtitle_text", role: "text", label: "Demo subtitle")

                HStack(spacing: 12) {
                    Button("Increment") {
                        store.incrementCounter(source: "ui button")
                    }
                    .debugNode(id: "increment_button", role: "button", label: "Increment button", actions: ["press"])

                    Button(store.isDetailVisible ? "Hide Detail" : "Show Detail") {
                        store.toggleDetail(source: "ui button")
                    }
                    .debugNode(id: "detail_toggle", role: "button", label: "Detail toggle button", actions: ["press"])
                }
                .debugNode(id: "button_row", role: "row", label: "Action button row")

                Text("Counter: \(store.counter)")
                    .font(.system(.title3, design: .monospaced))
                    .debugNode(id: "counter_text", role: "text", label: "Counter text")

                VStack(alignment: .leading, spacing: 10) {
                    Text("Cards")
                        .font(.headline)
                    HStack(spacing: 12) {
                        cardView(id: "alpha", title: "Alpha", color: .blue)
                            .debugNode(id: "card_alpha", role: "button", label: "Alpha card", actions: ["press"])
                            .onTapGesture {
                                store.selectCard(id: "alpha", source: "ui tap")
                            }
                        cardView(id: "beta", title: "Beta", color: .green)
                            .debugNode(id: "card_beta", role: "button", label: "Beta card", actions: ["press"])
                            .onTapGesture {
                                store.selectCard(id: "beta", source: "ui tap")
                            }
                    }
                    .debugNode(id: "card_row", role: "row", label: "Card row")
                }
                .debugNode(id: "card_section", role: "section", label: "Card section")

                Spacer(minLength: 0)

                Text("Latest event: \(store.latestEvent)")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .debugNode(id: "event_text", role: "text", label: "Latest event text")
            }
            .frame(maxWidth: 420, alignment: .topLeading)
            .debugNode(id: "left_panel", role: "panel", label: "Main control panel")

            if store.isDetailVisible {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Detail Panel")
                        .font(.headline)
                    Text("Selected: \(store.selectedCardID ?? "none")")
                    Text("Server: http://127.0.0.1:\(shell.port)")
                        .font(.system(.body, design: .monospaced))
                    Text("Try GET /snapshot and POST /action.")
                        .foregroundStyle(.secondary)
                }
                .padding(16)
                .frame(width: 260, alignment: .topLeading)
                .background(
                    RoundedRectangle(cornerRadius: 16)
                        .fill(Color(nsColor: .windowBackgroundColor))
                        .shadow(radius: 6, y: 2)
                )
                .debugNode(id: "detail_panel", role: "panel", label: "Detail panel")
            }
        }
        .padding(24)
        .frame(minWidth: 760, minHeight: 420, alignment: .topLeading)
        .debugNode(id: "root_container", role: "window", label: "Root container")
    }

    // 单张卡片视图。
    @ViewBuilder
    private func cardView(id: String, title: String, color: Color) -> some View {
        let isSelected = shell.store.selectedCardID == id

        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)
            Text(isSelected ? "Selected" : "Idle")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(width: 140, height: 96, alignment: .topLeading)
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(color.opacity(isSelected ? 0.35 : 0.18))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(isSelected ? color : .clear, lineWidth: 2)
        )
    }
}

// 顶层 App 定义。
@main
struct SwiftUIMacOSDebugServerLayoutActionDemoApp: App {
    // 顶层持有 app-shell。
    @State private var shell = DemoAppShell()

    // 创建窗口并注入环境。
    var body: some Scene {
        WindowGroup("SwiftUI Debug Server Demo") {
            ContentView()
                .environment(shell)
                .environment(shell.registry)
                .onAppear {
                    shell.start()
                }
        }
        .windowResizability(.contentSize)
    }
}
