# dsh-task-watcher-plugin

DSH 任务监视器插件（薄壳）——把 [DshTaskWatcher](https://github.com/YeqingTang/dsh-task-watcher)
（独立 Windows 托盘监视程序）打进插件包：安装即部署到 `%LOCALAPPDATA%\DshTaskWatcher`
并拉起托盘，无需再从 GitHub 下载安装包。

## 形态

- **Host + Web 双半端**：host 负责部署/拉起/管理路由；浏览器半端在
  **设置 → 插件 → 任务监视器** 提供状态显示与启停开关（10s 轮询、中英双语）
- **脱离宿主进程**：`CREATE_NO_WINDOW` 直起 powershell（无终端窗口）、无 job 绑定——DSH 重启不影响托盘常驻
- **独立生命周期**：桌面快捷方式启动、托盘右键退出照常可用；插件停用/卸载不杀运行中的监视器
- **停止意图记忆**：托盘退出或开关停止后写 `stopped.flag`，DSH 重启不会自动拉回（崩溃/强杀仍允许自动恢复）
- **单实例互斥**：监视器内置 mutex，与手动安装并存也不会双托盘
- **零依赖零构建**：`lib/` 纯手写 ESM，assets 为运行时载荷

## 管理 API（仅 loopback POST）

| 路由 | 作用 |
|---|---|
| `/api/dsh-task-watcher/status` | 运行状态 / pid / 已部署版本 |
| `/api/dsh-task-watcher/start` | 部署（增量覆盖，`config.json` 只在缺失时写入）+ 拉起托盘 |
| `/api/dsh-task-watcher/stop` | 停止托盘（只匹配 `-File <路径>DshTaskWatcher.ps1` 启动形态，绝不误伤提及该文件名的其他进程） |

宿主启动时：已有部署但未运行 → 自动拉起；全新安装不擅自部署（首次显式 start 才落盘）。

## 安装

![preview](assets/screenshots/preview.png)

方式一（推荐，npm 源）：

```sh
dsh plugin --profile web add @yeqingtang/dsh-task-watcher-plugin
```

方式二（GitHub 源）：

```sh
dsh plugin --profile web add github:YeqingTang/dsh-task-watcher-plugin
```

重启 web 服务后生效。

## 已知坑（实现记录）

- **node spawn 旗标互斥**：`detached:true`（DETACHED_PROCESS）与 `windowsHide:true`
  （CREATE_NO_WINDOW）组合会让 CreateProcess 静默失败（异步 `error` 事件无输出、pid 照常分配，
  极难排查）。Windows 下普通 spawn 的子进程本就能活得比父进程久，直接去掉 detached 即可。
- **stop 误杀面**：进程匹配必须锚定 `-File\s+\S*DshTaskWatcher[.]ps1` 启动形态；宽松匹配
  （仅文件名）会杀掉任何命令行里提到该文件的进程（编辑器、Get-Content、测试壳）。

## 升级监视器

插件包 assets 随 git/npm 更新；`start` 前会增量覆盖部署（`config.json` 用户文件只在缺失时写入）。
