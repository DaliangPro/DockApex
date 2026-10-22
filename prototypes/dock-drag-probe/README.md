# 系统 Dock 拖叠交互探针

本探针用于验证：**从系统 Dock 内拖动一个 App 图标，覆盖另一个 App 图标时，目标应用能否收到可用于创建分组的事件。** 它不是 Dock 分组产品。

## 构建与边界

运行 `bash build.sh` 编译两份独立应用。它们使用同一份 AppKit 源码和不同的 Bundle ID：

| 身份 | 应用 | Bundle ID |
| --- | --- | --- |
| 蓝色 A，拖拽源 | `build/DockProbeSource.app` | `io.daliang.dockdragprobe.source` |
| 橙色 B，拖拽目标 | `build/DockProbeTarget.app` | `io.daliang.dockdragprobe.target` |

构建脚本不启动应用、不固定图标、不修改 Dock 设置、不安装依赖，也不申请辅助功能或录屏权限。编译缓存和产物都在 `build/` 内；构建产物使用本地 ad hoc 临时签名，不使用开发者证书或系统密钥。运行探针需要由主代理另行进行 UI 测试。

两份应用都声明 `com.apple.application-bundle` 文档类型，角色 `Viewer`、顺位 `Alternate`；没有调用修改默认打开方式的接口。运行应用时 macOS 可能按正常应用发现机制识别该声明，不能把“未主动改默认项”解释成系统没有任何注册行为。

## 观察范围

探针记录三类入口：

- AppKit 应用代理的 `openFiles`、`openURLs`。
- 窗口内容视图的 `draggingEntered`、`draggingExited`、`prepareForDragOperation`、`performDragOperation`，用于对照验证记录器。
- 自定义 Dock Tile 视图的同类拖放回调；这里只安装观察器，**没有假定系统会向该视图转发 Dock 拖放**。

每个窗口展示身份、总事件数、接收事件数、日志位置和退出按钮。文件事件只记录最后一级文件名、UTType 和入口；不打开文件、不读取文件内容、不执行命令。日志仅写入本目录的 `logs/source-events.jsonl` 和 `logs/target-events.jsonl`。

## 必须分开的测试

1. **记录器对照**：把 Finder 中 `DockProbeSource.app` 拖到 B 的窗口空白处，检查 `window.performDragOperation` 是否增加。
2. **Finder 到 Dock 对照**：把 Finder 中 `DockProbeSource.app` 拖到系统 Dock 中 B 的图标上。检查 `application.openFiles` 或 `application.openURLs`；该测试成功也不代表 Dock 内部拖叠成功。
3. **目标交互**：两份探针处于运行状态且都出现在原生 Dock 时，把 Dock 中蓝色 A 图标拖到橙色 B 图标中央，悬停再释放。观察系统是接收、重排、退回还是其他表现，检查 B 的新增日志。可另测按住 Option 等修饰键，必须注明条件。

不要将 Finder 到 Dock 的成功，或窗口接收文件的成功，作为系统 Dock 内部拖叠成组的结论。目标测试若没有事件，也只说明所测系统版本与条件下未观察到该入口，不能单凭一次测试证明所有技术路线都不可能。

## 当前验证状态

已通过 Swift 6 语言模式、完整并发检查的编译，两份 plist 静态校验和两份应用的本地代码签名校验。两份 App 随后已由主代理启动。实际在 Dock 中把 A 拖向 B 后，图标只被重排；日志中两者文件或拖放接收计数均为 0。本轮常规回调路线未通过。Finder 到 Dock 的对照投放尚未测试，不能据此作全技术路线不可行的结论。测试结束后已退出探针。
