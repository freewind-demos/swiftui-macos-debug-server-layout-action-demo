# swiftui-macos-debug-server-layout-action-demo

这个 Demo 演示 `SwiftUI macOS` 程序如何内嵌一个本地 debug server，把关键组件数、每个组件的位置尺寸、可操作动作暴露给外部 AI。

重点不是“自动扒出全部 SwiftUI 内部视图”，而是“用少量显式埋点换来稳定可读、可控的 UI 快照”。

## 快速开始

### 环境要求

- macOS
- Xcode.app

### 运行

```bash
cd /Users/peng.li/workspace/freewind-demos/swiftui-macos-debug-server-layout-action-demo
./swift-compile-build.fish
./build/Debug/swiftui_macos_debug_server_layout_action_demo
```

打开窗口后，可在另一个终端访问：

```bash
curl http://127.0.0.1:7878/snapshot | jq
```

触发动作：

```bash
curl -X POST http://127.0.0.1:7878/action \
  -H 'Content-Type: application/json' \
  -d '{"type":"node","id":"increment_button","action":"press"}' | jq
```

也可以调用语义动作：

```bash
curl -X POST http://127.0.0.1:7878/action \
  -H 'Content-Type: application/json' \
  -d '{"type":"intent","name":"toggle_detail"}' | jq
```

## 注意事项

- 这个 Demo 只暴露“显式标记过的节点”，不是 SwiftUI 私有完整视图树。
- `frame` 来自嵌入的 `NSViewRepresentable` 桥接视图，因此坐标是面向窗口内容区域的。
- 这个 server 只适合 `DEBUG` / 本机开发，不适合直接带到生产。

## 教程

### 关键概念

做这类能力时，`server` 本身不会凭空知道 SwiftUI 里有什么组件。真正做事的是 app 内的这三层：

1. `DebugNodeModifier`
   把 `debug id / role / label / actions` 挂到关键 view 上。
2. `DebugFrameReporter`
   通过透明 `NSView` 读取实际布局 frame，再写回注册中心。
3. `DebugRegistry`
   汇总节点与动作；`HTTP server` 只负责把它读出来、调进去。

### demo 原理

这个 Demo 只在真实代码里新增两类侵入点：

1. 给关键组件加 `.debugNode(id:role:label:actions:)`
2. 在 `DemoAppShell.installActions()` 注册少量语义动作或节点动作

其他逻辑仍保持原本的单向流：

`view -> store`

`server -> registry -> store`

也就是：

- view 直接点击按钮，照常改状态
- server 想“点按钮”，走 `registry` 注册好的动作，再进 `store`
- server 想知道组件数/位置，读 `registry` 已收集好的节点快照

### 关键代码解读

先看最重要的业务侵入点：

```swift
Button("Increment") {
    store.incrementCounter(source: "ui button")
}
.debugNode(id: "increment_button", role: "button", label: "Increment button", actions: ["press"])
```

这基本就是你真实业务代码需要多写的量。

再看对外动作注册：

```swift
registry.registerNodeAction(id: "increment_button", action: "press") { [store] in
    store.incrementCounter(source: "server node action")
    return ActionResponse(ok: true, message: "Pressed increment button")
}
```

这表示“外部 AI 请求按下某个节点”时，最终仍然调用你定义好的业务入口。

最后看 frame 收集：

```swift
let frame = view.convert(view.bounds, to: nil)
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
```

这就是“组件数、组件位置、组件大小”真正来源。

## 侵入评估

若你的真实 app 已经有清晰的 `store / handler / app-shell` 主干，这套做法侵入通常不大：

1. 每个关键组件增加 1 行 `.debugNode(...)`
2. 每个允许外部驱动的动作增加 1 段注册逻辑
3. 顶层 app-shell 新增 1 个 debug server 装配

若你追求“所有组件自动发现”，侵入会迅速变大，而且结果反而更噪。

更实用的策略是：

1. 只标关键可交互节点
2. 只暴露必要布局信息
3. 只开放少量合法动作

这样 AI 才真的好用，也更省 token。
