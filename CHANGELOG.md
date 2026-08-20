# Changelog

本插件版本号跟随监视器本体（[dsh-task-watcher](https://github.com/YeqingTang/dsh-task-watcher)）；
仅浏览器半端或 host 半端的改动独立前进（patch）。

## [0.5.4] - 2026-08-20

### Fixed
- 设置页「任务监视器」Tab 排版加固：开关/刷新按钮 `all: unset` 防宿主全局按钮样式入侵；元信息改为定义网格（dl grid），超长路径不再错位折行；移除 720px 定宽；提示语加圆点；新增 `:focus-visible` 焦点环。

## [0.5.3] - 2026-08-20

### Added
- 浏览器半端：**设置 → 插件 → 任务监视器** Tab——状态点（运行/停止/操作中脉冲）、启停开关、pid/版本/数据目录元信息、10s 轮询、中英双语。
- 停止意图记忆（`stopped.flag`）：托盘右键退出或插件开关停止后，DSH 重启不再被 boot 便利逻辑自动拉回；崩溃/被强杀仍允许自动恢复；重新 start 清除标记。
- 非Windows 宿主守卫：start/stop 路由在非 win32 下返回明确错误而非不可名状的 spawn 失败。
- 发布到 npm（`@yeqingtang/dsh-task-watcher-plugin`）并提交 awesome-dsh-plugin 市场 PR。

### Changed
- GUIDANCE 系统提示词与实现对齐（CREATE_NO_WINDOW 直起，弃用 conhost --headless 描述）。

## [0.5.2] - 2026-08-20

首个市场壳版本（与监视器 v0.5.2 对齐）。

### Added
- Host 半端：部署器（assets 增量覆盖，`config.json` 只在缺失时写入）、拉起（`CREATE_NO_WINDOW` 直起，无 detached 旗标）、`/api/dsh-task-watcher/status|start|stop` 三条 loopback-only 路由、boot 自动拉起便利逻辑。
- 监视器配套：单实例互斥（`DshTaskWatcher_SingleInstance` mutex；`-SelfTest`/`-Demo` 豁免）。
