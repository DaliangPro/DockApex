# Dock 五项修复夹具

构建：`bash Tools/DockBugFixture/build.sh`。使用 CUA 打开 `build/DockBugFixture.app` 后，可点击控制窗按钮铺满主显示器或内屏的系统可用区域、最小化和恢复标准测试窗。系统黄色按钮与 `⌘M` 同样经过窗口代理记录。

输出位于 `Data/Diagnostics/五项修复-fixture/events.json`。每条事件包含单调时钟、两个自有窗口状态、显示器 UUID、内屏标志、frame 和 visibleFrame；顶层还包含屏幕录制权限的只读预检结果。夹具只操作本应用窗口，不改变 Dock 偏好。

`windowDidMiniaturize.durationMs` 取 `windowWillMiniaturize` 到完成回调的间隔。夹具按钮触发恢复时，`windowDidDeminiaturize.durationMs` 取本应用恢复请求到完成回调的间隔；从其他入口恢复没有系统开始回调，因此记为 `null`，不能把窗口保持最小化的时间当成动画时间。日志按 50 毫秒合并落盘，退出前同步完成最后一次保存。

每次启动建立独立 session，覆盖当前 `events.json`；对比不同系统参数时可保持夹具运行，或先保存日志副本再重启。
