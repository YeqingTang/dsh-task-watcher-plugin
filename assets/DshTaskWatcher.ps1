#requires -version 5.1
<#
================================================================================
 DSH 任务监视器 (DshTaskWatcher)  v0.5.2
--------------------------------------------------------------------------------
 常驻 Windows 托盘，监视 DSH（http://127.0.0.1:3080）的对话任务状态：

   · 托盘图标四态：红=需处理 / 橙=运行中 / 绿=空闲 / 灰=DSH 未连接
   · Windows 通知：任务完成（含统计与提示音）/ 子任务完成 / 需要批准或回答
   · 系统原生悬浮摘要「运行中 N · 待处理 M」
   · 单击托盘图标 → 监控窗（始终置顶、可拖动、可固定、点击外部隐藏）
   · 状态窗口（运行中任务列表 + 最近完成记录）+ 双击查看单任务详情
   · 点击通知气泡 → 打开 DSH 控制台

 零第三方依赖：Windows PowerShell 5.1 + WinForms / System.Drawing（Win11 自带）。

 用法：
   powershell -NoProfile -ExecutionPolicy Bypass -File DshTaskWatcher.ps1
   powershell ... -SelfTest        # 状态机自测（不弹通知，输出断言结果）
   powershell ... -NoWelcome       # 启动时不弹欢迎通知
   powershell ... -Demo            # 演示模式：假数据驱动真实界面（截图用）
   powershell ... -ConfigPath x.json   # 指定配置文件

 数据目录：%LOCALAPPDATA%\DshTaskWatcher\（logs\watcher.log、status.json、icons\）
 配置：与脚本同目录 config.json（缺失时自动生成默认配置）
================================================================================
#>
[CmdletBinding()]
param(
    [switch]$SelfTest,
    [switch]$NoWelcome,
    [switch]$Demo,
    [string]$ConfigPath = ''
)

$ErrorActionPreference = 'Stop'

# 隐藏自身控制台窗口（替代快捷方式参数 -WindowStyle Hidden：
# 该参数组合容易被安全软件（如火绒快捷方式保护）误判为可疑启动器而删除快捷方式，
# 改为脚本启动后自隐藏，快捷方式参数保持朴素）
try {
    Add-Type -Namespace Win32 -Name NativeMethods -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("kernel32.dll")] public static extern System.IntPtr GetConsoleWindow();
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern bool ShowWindow(System.IntPtr hWnd, int nCmdShow);
'@
    $script:ConsoleHwnd = [Win32.NativeMethods]::GetConsoleWindow()
    if ($script:ConsoleHwnd -ne [IntPtr]::Zero) {
        [void][Win32.NativeMethods]::ShowWindow($script:ConsoleHwnd, 0) # 0 = SW_HIDE
    }
} catch { }

# 依赖程序集（Windows 11 自带，无需安装）
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Net.Http

# 监控窗类型（单击托盘图标弹出；无焦点、不占任务栏；空白区可拖动）+ 点击外部隐藏过滤器
# 注意：Add-Type -TypeDefinition 的 C# 源码内避免中文（PS 5.1 编译兼容性问题）
try {
    Add-Type -ReferencedAssemblies 'System.Windows.Forms.dll','System.Drawing.dll' -WarningAction SilentlyContinue -TypeDefinition @'
using System;
using System.Drawing;
using System.Windows.Forms;
using System.Runtime.InteropServices;
namespace DshTaskWatcher {
    public class MonitorForm : Form {
        protected override bool ShowWithoutActivation { get { return true; } }
        protected override CreateParams CreateParams {
            get {
                CreateParams p = base.CreateParams;
                p.ExStyle |= 0x00000080;  // WS_EX_TOOLWINDOW
                p.ExStyle |= 0x08000000;  // WS_EX_NOACTIVATE
                return p;
            }
        }
    }
    // 全局鼠标按下钩子（WH_MOUSE_LL）：点击监控窗外部时隐藏（固定模式禁用）。
    // 用低级钩子而非 IMessageFilter——IMessageFilter 只能拦截本进程消息，
    // 点击其他程序/桌面的消息不会经过本进程，外部隐藏形同虚设。
    public class GlobalClickFilter : IDisposable {
        public Form Target = null;
        public bool Enabled = true;
        private delegate IntPtr LowLevelMouseProc(int nCode, IntPtr wParam, IntPtr lParam);
        private LowLevelMouseProc _proc;
        private IntPtr _hook = IntPtr.Zero;
        [StructLayout(LayoutKind.Sequential)]
        private struct POINT { public int X; public int Y; }
        [DllImport("user32.dll", SetLastError = true)]
        private static extern IntPtr SetWindowsHookEx(int idHook, LowLevelMouseProc lpfn, IntPtr hMod, uint dwThreadId);
        [DllImport("user32.dll", SetLastError = true)]
        private static extern bool UnhookWindowsHookEx(IntPtr hhk);
        [DllImport("user32.dll")]
        private static extern IntPtr CallNextHookEx(IntPtr hhk, int nCode, IntPtr wParam, IntPtr lParam);
        [DllImport("kernel32.dll", CharSet = CharSet.Auto)]
        private static extern IntPtr GetModuleHandle(string lpModuleName);
        [DllImport("user32.dll")]
        private static extern bool GetCursorPos(out POINT lpPoint);

        public void Start() {
            if (_hook != IntPtr.Zero) return;
            _proc = HookCallback;
            _hook = SetWindowsHookEx(14 /* WH_MOUSE_LL */, _proc, GetModuleHandle(null), 0);
        }
        private IntPtr HookCallback(int nCode, IntPtr wParam, IntPtr lParam) {
            if (nCode >= 0 && Enabled && Target != null && !Target.IsDisposed) {
                int msg = (int)wParam;
                if (msg == 0x0201 || msg == 0x0204 || msg == 0x0207) {  // 左/右/中键按下
                    POINT pt;
                    if (GetCursorPos(out pt)) {
                        if (!Target.Bounds.Contains(pt.X, pt.Y)) {
                            // 不要在钩子回调内直接操作 UI（会造成消息重入、多次循环后拖垮消息循环）：
                            // 用 BeginInvoke 排队到 UI 线程再 Hide
                            Form t = Target;
                            t.BeginInvoke(new Action(() => { if (t != null && !t.IsDisposed) { t.Hide(); } }));
                        }
                    }
                }
            }
            return CallNextHookEx(IntPtr.Zero, nCode, wParam, lParam);
        }
        public void Dispose() {
            if (_hook != IntPtr.Zero) { UnhookWindowsHookEx(_hook); _hook = IntPtr.Zero; }
        }
    }
}
'@
    $script:MonitorFormType = [DshTaskWatcher.MonitorForm]
    # 低级鼠标钩子不常驻：仅监控窗「可见且未固定」期间安装（Show/Hide/固定 时装/卸）。
    # 常驻 WH_MOUSE_LL 的回调跑在 UI 线程——UI 被网络阻塞时会拖累全系统鼠标输入，
    # 产生「整机卡鼠标」的死机感；限定作用域后空闲零钩子开销。
    $script:ClickFilter = [DshTaskWatcher.GlobalClickFilter]::new()
} catch {
    $script:MonitorFormType = $null
    $script:ClickFilter = $null
}

# ── 常量与全局状态 ────────────────────────────────────────────────────────────
$script:Version = '0.5.2'

# 单实例互斥：市场插件安装与手动安装并存时防止双托盘/双轮询
# （-SelfTest / -Demo 是同进程内多场景演练，不参与互斥）
if (-not $SelfTest -and -not $Demo) {
    $script:SingleMutex = New-Object System.Threading.Mutex($false, 'DshTaskWatcher_SingleInstance')
    if (-not $script:SingleMutex.WaitOne(0)) {
        try { $script:SingleMutex.ReleaseMutex() } catch { }
        exit 0
    }
}

$script:AppId = 'DshTaskWatcher'
$script:DataDir = Join-Path $env:LOCALAPPDATA $script:AppId
$script:LogDir = Join-Path $script:DataDir 'logs'
$script:LogFile = Join-Path $script:LogDir 'watcher.log'
$script:StatusFile = Join-Path $script:DataDir 'status.json'
$script:IconDir = Join-Path $script:DataDir 'icons'
$script:ConfigFile = if ($ConfigPath) { $ConfigPath } else { Join-Path $PSScriptRoot 'config.json' }

$script:Cfg = @{}
$script:Http = $null
$script:Tray = $null
$script:Timer = $null
$script:CurrentIcon = ''
$script:MenuPauseItem = $null
$script:KnownSessions = @{}
$script:BusySessions = @()
$script:LastFinished = $null
$script:RecentFinishes = New-Object System.Collections.ArrayList
$script:Polling = $false
$script:Paused = $false
$script:LastPollOk = $false
$script:WasConnected = $false
$script:StatusForm = $null
$script:StatusList = $null
$script:StatusFinList = $null
$script:StatusLblRunning = $null
$script:StatusVisible = $false
# 监控窗（单击托盘图标弹出）：MonitorFormType/ClickFilter 由上方 Add-Type 块赋值，这里不能重置
$script:MonitorForm = $null
$script:MonitorTable = $null
$script:MonitorScroll = $null
$script:MonitorRows = @()
$script:MonitorFixed = $false
$script:MonitorTitle = $null
$script:MonitorPinBtn = $null
$script:PinImgGray = $null    # 图钉图标：未固定（空心，Bootstrap Icons MIT）
$script:PinImgBlue = $null    # 图钉图标：已固定（实心，Bootstrap Icons MIT）
# 「需要用户介入」（审批/提问）事件流状态：后台 runspace 写队列，UI 线程读取解析
$script:AttentionSessions = @{}                                  # sessionId → @{kind; approvalId; questionRpcId; text; at}
$script:KnownApprovals = @{}                                     # approvalId → sessionId（重放去重）
$script:KnownQuestions = @{}                                     # questionRpcId → sessionId（重放去重）
$script:AttQueue = [System.Collections.Concurrent.ConcurrentQueue[object]]::new()
$script:SseState = @{ stop = $false }                            # 后台 runspace 停止标志（共享对象）
$script:SseQueue = [System.Collections.Concurrent.ConcurrentQueue[object]]::new()  # 原始帧队列（跨 runspace 共享）
$script:SsePs = $null
# 轮询抓取后台化（性能修复）：全部网络 I/O 与多 MB 文本解析移出 UI 线程——
# UI 定时器只消费紧凑快照，网络阻塞不再冻结界面/托盘菜单/鼠标钩子
$script:FetchState = @{ stop = $false; pollMs = 3000; idleMs = 10000; wantDetail = $false; kick = 0 }
$script:FetchQueue = [System.Collections.Concurrent.ConcurrentQueue[object]]::new()
$script:FetchPs = $null
$script:FetchExtras = @{}          # sid -> @{ user; real; forTurn; retry; turnStart; finish; finishKind; finishMsg }
$script:LastSnap = $null
$script:StatusFp = ''              # status.json 节流：状态指纹不变不落盘
$script:StatusLastWrite = [DateTime]::MinValue
$script:LastTrim = [DateTime]::MinValue   # 周期性内存回收（GC + 归还工作集）
$script:TestMode = $false
$script:TestToasts = New-Object System.Collections.ArrayList

# ── 日志 ──────────────────────────────────────────────────────────────────────
function Write-Log {
    param([string]$Message)
    try {
        if (-not (Test-Path $script:LogDir)) { New-Item -ItemType Directory -Force -Path $script:LogDir | Out-Null }
        $line = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff') + ' ' + $Message
        Add-Content -Path $script:LogFile -Value $line -Encoding UTF8
        try {
            $fi = Get-Item $script:LogFile
            if ($fi.Length -gt 200KB) {
                Get-Content $script:LogFile -Tail 1000 | Set-Content -Path $script:LogFile -Encoding UTF8
            }
        } catch { }
    } catch { }
}

# ── 配置 ──────────────────────────────────────────────────────────────────────
$script:DefaultConfig = @{
    baseUrl            = 'http://127.0.0.1:3080'
    openUrl            = 'http://127.0.0.1:3080'
    pollSeconds        = 3
    toastOnStart       = $false     # 任务开始不推送系统通知（只在完成/待处理时推送）
    toastOnFinish      = $true
    playSoundOnFinish  = $true
    toastForSubagents  = $true
    statusWindowOnTop  = $true
    notifyOnUserAction = $true      # 会话需要用户介入（审批/提问）时弹系统通知
    attentionSound     = $true      # 介入通知播放提示音
}

function Read-Config {
    $cfg = @{}
    foreach ($k in $script:DefaultConfig.Keys) { $cfg[$k] = $script:DefaultConfig[$k] }
    if (Test-Path $script:ConfigFile) {
        try {
            $loaded = Get-Content -Raw -Encoding UTF8 $script:ConfigFile | ConvertFrom-Json
            foreach ($p in $loaded.PSObject.Properties) {
                if ($cfg.ContainsKey($p.Name)) { $cfg[$p.Name] = $p.Value }
            }
        } catch {
            Write-Log ('配置解析失败，使用默认值: ' + $_.Exception.Message)
        }
    } else {
        try {
            $dir = Split-Path $script:ConfigFile -Parent
            if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
            $script:DefaultConfig | ConvertTo-Json | Set-Content -Path $script:ConfigFile -Encoding UTF8
            Write-Log ('已生成默认配置: ' + $script:ConfigFile)
        } catch { }
    }
    $script:Cfg = $cfg
}

# ── HTTP（显式 UTF-8，规避 PS5.1 Invoke-WebRequest 中文乱码）──────────────────
function Invoke-DshRpc {
    param([string]$Method, [hashtable]$Payload = @{})
    $req = @{ type = 'client-request'; rpcId = [guid]::NewGuid().ToString(); method = $Method; payload = $Payload }
    $json = $req | ConvertTo-Json -Depth 10 -Compress
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
    $content = [System.Net.Http.ByteArrayContent]::new($bytes)
    $content.Headers.ContentType = [System.Net.Http.Headers.MediaTypeHeaderValue]::new('application/json')
    $url = $script:Cfg.baseUrl.TrimEnd('/') + '/api/' + $Method
    $resp = $script:Http.PostAsync($url, $content).GetAwaiter().GetResult()
    if (-not $resp.IsSuccessStatusCode) { throw ('HTTP ' + [int]$resp.StatusCode) }
    $respBytes = $resp.Content.ReadAsByteArrayAsync().GetAwaiter().GetResult()
    $text = [System.Text.Encoding]::UTF8.GetString($respBytes)
    $obj = $text | ConvertFrom-Json
    if ($null -eq $obj -or $obj.type -ne 'server-response') { throw '非预期响应类型' }
    if (-not $obj.result.ok) { throw ('RPC 错误: ' + $obj.result.error.code) }
    return $obj.result.value
}

# 发送 RPC 并返回原始响应文本（不做 JSON 解析）。
# 背景：session.history 在长回合进行中时，最后一「条消息」包含本回合全部流式 chunk，
# 载荷可达数 MB；在 UI 线程上用 ConvertFrom-Json 全量解析既卡顿又可能超限失败。
function Invoke-DshRpcRaw {
    param([string]$Method, [hashtable]$Payload = @{})
    $req = @{ type = 'client-request'; rpcId = [guid]::NewGuid().ToString(); method = $Method; payload = $Payload }
    $json = $req | ConvertTo-Json -Depth 10 -Compress
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
    $content = [System.Net.Http.ByteArrayContent]::new($bytes)
    $content.Headers.ContentType = [System.Net.Http.Headers.MediaTypeHeaderValue]::new('application/json')
    $url = $script:Cfg.baseUrl.TrimEnd('/') + '/api/' + $Method
    $resp = $script:Http.PostAsync($url, $content).GetAwaiter().GetResult()
    if (-not $resp.IsSuccessStatusCode) { throw ('HTTP ' + [int]$resp.StatusCode) }
    $respBytes = $resp.Content.ReadAsByteArrayAsync().GetAwaiter().GetResult()
    return [System.Text.Encoding]::UTF8.GetString($respBytes)
}

# 从 session.history 原始响应文本中提取最后一条「真实用户」消息开头（正则定位，不做全量解析）。
# 实测形状：…"event":{"type":"user/message","seq":N,"time":…,"data":{"content":[{"type":"text","text":"…"}],
#           "source":{"kind":"user","rpcId":…}…（紧凑序列化，键序稳定；文本内引号均被转义，不会伪造 marker）
# 注意：agent 每轮工具往返都会追加一条 assistant/message，分页按「消息」计数——
# maxMessages 太小会让本轮用户消息滑出窗口（mm=4 几轮工具后就取不到）；调用方应传 ≥40，
# 超长回合还需深窗兜底（mm=400）。
# 提取策略：从最后一个 marker 用 LastIndexOf 向前走（marker 数≈回合数，远少于事件数，
# 深窗大载荷也快），优先 source.kind=user 的真实用户消息；返回 @{ text; real }——
# real=$true 表示拿到 kind=user 真实消息；real=$false 表示只有合成兜底
# （goal 自动续跑的 <goal_round> 消息、压缩摘要等宿主生成 user 形消息，无 kind=user）。
function Get-LastUserEx {
    param([string]$Raw, [int]$MaxLen = 60)
    if (-not $Raw) { return @{ text = ''; real = $false } }
    $best = ''
    $scanFrom = $Raw.Length
    while ($scanFrom -gt 0) {
        $pos = $Raw.LastIndexOf('"type":"user/message"', $scanFrom - 1)
        if ($pos -lt 0) { break }
        $look = $Raw.Substring($pos, [Math]::Min(8000, $Raw.Length - $pos))
        $m = [regex]::Match($look, '"text"\s*:\s*"((?:[^"\\]|\\.)*)"')
        $txt = ''
        if ($m.Success) {
            $txt = [regex]::Unescape($m.Groups[1].Value)
            $txt = ($txt -replace '\s+', ' ').Trim()
        }
        if ($txt -and $look.Contains('"kind":"user"')) {
            if ($txt.Length -gt $MaxLen) { $txt = $txt.Substring(0, $MaxLen) + '…' }
            return @{ text = $txt; real = $true }
        }
        if (-not $best -and $txt) { $best = $txt }
        $scanFrom = $pos
    }
    if ($best.Length -gt $MaxLen) { $best = $best.Substring(0, $MaxLen) + '…' }
    return @{ text = $best; real = $false }
}

function Get-LastUserFromRaw {
    param([string]$Raw, [int]$MaxLen = 60)
    return (Get-LastUserEx -Raw $Raw -MaxLen $MaxLen).text
}

# 从 session.history 原始文本提取最后一条 turn/end 的结局（官方事件词汇表，dsh-agent-loop）：
#   completed（正常完成）/ error{message,code}（LLM 或内部错误）/ aborted（用户中止或释放）
#   / max-tokens（达到输出上限）/ blocked（进入前被拒）/ interrupted（崩溃恢复合成——宿主中断）
# 序列化形状：…"type":"turn/end","seq":N,…,"data":{"turn":N,"reason":{"kind":"…",…}}…
# reason 对象用「字符串感知的括号配平」截取——错误消息里可能含 { } 字符，后续事件的
# "message" 键（如 tool/result）不得误吞。
function Get-LastTurnEndFromRaw {
    param([string]$Raw)
    if (-not $Raw) { return $null }
    $pos = $Raw.LastIndexOf('"type":"turn/end"')
    if ($pos -lt 0) { return $null }
    $rp = $Raw.IndexOf('"reason":', $pos)
    if ($rp -lt 0) { return $null }
    $start = $rp + 9
    if ($start -ge $Raw.Length -or $Raw[$start] -ne '{') { return $null }
    # 括号配平（跳过字符串字面量内部的花括号）
    $depth = 0; $end = -1; $inStr = $false; $esc = $false
    $max = [Math]::Min($Raw.Length, $start + 4000)
    for ($i = $start; $i -lt $max; $i++) {
        $ch = $Raw[$i]
        if ($esc) { $esc = $false; continue }
        if ($inStr) {
            if ($ch -eq '\') { $esc = $true } elseif ($ch -eq '"') { $inStr = $false }
            continue
        }
        if ($ch -eq '"') { $inStr = $true }
        elseif ($ch -eq '{') { $depth++ }
        elseif ($ch -eq '}') { $depth--; if ($depth -eq 0) { $end = $i; break } }
    }
    if ($end -lt 0) { return $null }
    $reason = $Raw.Substring($start, $end - $start)
    $km = [regex]::Match($reason, '"kind"\s*:\s*"([a-z-]+)"')
    if (-not $km.Success) { return $null }
    $kind = $km.Groups[1].Value
    $msg = ''
    if ($kind -eq 'error') {
        $em = [regex]::Match($reason, '"message"\s*:\s*"((?:[^"\\]|\\.)*)"')
        if ($em.Success) {
            $msg = [regex]::Unescape($em.Groups[1].Value)
            $msg = ($msg -replace '\s+', ' ').Trim()
            if ($msg.Length -gt 80) { $msg = $msg.Substring(0, 80) + '…' }
        }
    }
    return @{ kind = $kind; message = $msg }
}

# turn/end 结局 → 展示映射（监控窗状态列 + 通知标题/图标 + 颜色）
function Get-TurnOutcomeInfo {
    param([string]$Kind)
    switch ($Kind) {
        'completed'   { return @{ label = '已完成'; color = '#9aa0a6'; toast = '任务完成';   tkind = 'Info'    } }
        'error'       { return @{ label = '已失败'; color = '#ff6b6b'; toast = '任务失败';   tkind = 'Error'   } }
        'interrupted' { return @{ label = '已中断'; color = '#ff6b6b'; toast = '会话中断';   tkind = 'Error'   } }
        'aborted'     { return @{ label = '已中止'; color = '#f0b429'; toast = '任务已中止'; tkind = 'Warning' } }
        'max-tokens'  { return @{ label = '达上限'; color = '#f0b429'; toast = '达到输出上限'; tkind = 'Warning' } }
        'blocked'     { return @{ label = '被阻断'; color = '#f0b429'; toast = '任务被阻断'; tkind = 'Warning' } }
        default       { return @{ label = '已完成'; color = '#9aa0a6'; toast = '任务完成';   tkind = 'Info'    } }
    }
}

# 从 session.history 原始文本提取窗口内最后一个 turn/start 的回合号。
# 回合数口径（dsh-session-stats 源码考证）：投影 sessionStats.turns 在 step/end 计数
# （回合的**首个 step 完成后**即含该回合）——回合刚开始、首个 step 未完成时不计入。
# 官方 Web GUI 的「Turn N」直接用事件序号（turn/start 即有号）。两者统一口径：
#   显示 = max(投影 turns, 窗口内最后 turn/start 号)
# 首个 step 未完成时 turn/start 号 = 投影+1（取它）；已完成后两者相等（不重复计）。
# 窗口截断（超长回合 >40 消息）时 turn/start 不可见，但那类回合早有 step/end，投影已含。
function Get-LastTurnStartFromRaw {
    param([string]$Raw)
    if (-not $Raw) { return -1 }
    $pos = $Raw.LastIndexOf('"type":"turn/start"')
    if ($pos -lt 0) { return -1 }
    $m = [regex]::Match($Raw.Substring($pos, [Math]::Min(200, $Raw.Length - $pos)), '"turn"\s*:\s*(\d+)')
    if ($m.Success) { return [int]$m.Groups[1].Value }
    return -1
}

# 运行中行的显示回合数：max(投影 liveTurns, liveTurnStart)
function Get-DisplayTurns {
    param($Rec)
    $t = [int]$Rec.liveTurns
    if ($null -ne $Rec.liveTurnStart -and ($Rec.liveTurnStart -is [int]) -and ([int]$Rec.liveTurnStart) -gt $t) {
        $t = [int]$Rec.liveTurnStart
    }
    return $t
}

# ── 图标生成（PNG-in-ICO；设计：状态色大圆 + 白色脉冲折线——扁平现代，状态醒目）───
function New-StatusBitmap {
    param([string]$ColorName)
    $colors = @{
        gray  = '#9aa0a6'
        green = '#2ecc71'
        amber = '#f39c12'
        red   = '#e74c3c'
    }
    $bmp = New-Object System.Drawing.Bitmap(32, 32)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $g.Clear([System.Drawing.Color]::Transparent)
    # 状态色实心大圆（图标 94% 面积是状态色，醒目）
    $g.FillEllipse([System.Drawing.SolidBrush]::new([System.Drawing.ColorTranslator]::FromHtml($colors[$ColorName])), 1, 1, 30, 30)
    # 白色脉冲折线（心跳/实时监控意象）
    $pen = [System.Drawing.Pen]::new([System.Drawing.Color]::White, 2.6)
    $pen.StartCap = [System.Drawing.Drawing2D.LineCap]::Round
    $pen.EndCap = [System.Drawing.Drawing2D.LineCap]::Round
    $pen.LineJoin = [System.Drawing.Drawing2D.LineJoin]::Round
    $pts = @(
        [System.Drawing.PointF]::new(8, 17),
        [System.Drawing.PointF]::new(12.5, 12.5),
        [System.Drawing.PointF]::new(16, 19.5),
        [System.Drawing.PointF]::new(19.5, 12),
        [System.Drawing.PointF]::new(24, 17)
    )
    $g.DrawLines($pen, $pts)
    $g.Dispose(); $pen.Dispose()
    return $bmp
}

function Write-PngIcon {
    param([string]$Path, [System.Drawing.Bitmap]$Bitmap)
    $ms = New-Object System.IO.MemoryStream
    $Bitmap.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
    $png = $ms.ToArray()
    $ms.Dispose()
    # ICO 头：ICONDIR(6) + ICONDIRENTRY(16) + PNG 数据（Vista+ 支持 PNG 图标）
    $header = New-Object byte[] 22
    $header[2] = 1; $header[3] = 0        # type = icon
    $header[4] = 1; $header[5] = 0        # count = 1
    $header[6] = 32; $header[7] = 32      # width/height = 32
    $header[10] = 1; $header[11] = 0      # planes
    $header[12] = 32; $header[13] = 0     # bpp
    [BitConverter]::GetBytes([uint32]$png.Length).CopyTo($header, 14)
    [BitConverter]::GetBytes([uint32]22).CopyTo($header, 18)
    $fs = [System.IO.File]::Open($Path, [System.IO.FileMode]::Create)
    try {
        $fs.Write($header, 0, $header.Length)
        $fs.Write($png, 0, $png.Length)
    } finally { $fs.Close() }
}

function Ensure-Icons {
    if (-not (Test-Path $script:IconDir)) { New-Item -ItemType Directory -Force -Path $script:IconDir | Out-Null }
    foreach ($name in @('gray', 'green', 'amber', 'red')) {
        $path = Join-Path $script:IconDir ($name + '.ico')
        if (-not (Test-Path $path)) {
            try {
                $bmp = New-StatusBitmap $name
                Write-PngIcon $path $bmp
                $bmp.Dispose()
                Write-Log ('生成托盘图标: ' + $path)
            } catch {
                Write-Log ('图标生成失败: ' + $_.Exception.Message)
            }
        }
    }
}

# ── 工具 ──────────────────────────────────────────────────────────────────────
function Get-SessionTitle {
    param($Item)
    try {
        if ($null -ne $Item.projections -and $null -ne $Item.projections.values -and $null -ne $Item.projections.values.title) {
            $t = [string]$Item.projections.values.title
            if ($t -and $t.Trim().Length -gt 0) { return $t.Trim() }
        }
    } catch { }
    return '未命名会话'
}

function Format-Duration {
    param([TimeSpan]$D)
    if ($D.TotalSeconds -lt 60) { return ([int]$D.TotalSeconds).ToString() + '秒' }
    if ($D.TotalHours -lt 1) { return ([int]$D.TotalMinutes).ToString() + '分' + $D.Seconds.ToString() + '秒' }
    return ([int]$D.TotalHours).ToString() + '小时' + $D.Minutes.ToString() + '分'
}

# 冒号分隔时长（监控窗「时长」列专用）：45秒→0:45，9分12秒→9:12，1小时5分30秒→1:05:30
# 纯 ASCII 定宽，窄列内不折行（「9分12秒」含全角字符宽度大且易换行）
function Format-DurationClock {
    param([TimeSpan]$D)
    if ($D.TotalHours -ge 1) {
        return ([int][Math]::Floor($D.TotalHours)).ToString() + ':' + $D.Minutes.ToString('00') + ':' + $D.Seconds.ToString('00')
    }
    return ([int][Math]::Floor($D.TotalMinutes)).ToString() + ':' + $D.Seconds.ToString('00')
}

function Format-Tokens {
    param([long]$N)
    if ($N -ge 1000000) { return ('{0:N1}m' -f ($N / 1e6)) }
    if ($N -ge 1000) { return ('{0:N1}k' -f ($N / 1e3)) }
    return $N.ToString()
}

# ── 状态机 ────────────────────────────────────────────────────────────────────
function Process-Sessions {
    param([object[]]$Items)
    $seen = @{}
    $busy = @()
    $now = [DateTime]::Now
    # 第一遍：统计本次轮询仍处于运行中的会话（完成通知里报「剩余任务数」用）
    $runningIds = @($Items | Where-Object { [bool]$_.running } | ForEach-Object { [string]$_.sessionId })

    foreach ($it in $Items) {
        $sid = [string]$it.sessionId
        if (-not $sid) { continue }
        $seen[$sid] = $true
        $isSub = ($it.origin -eq 'subagent')
        $title = Get-SessionTitle $it
        $running = [bool]$it.running
        $turns = 0; $steps = 0; $tokens = 0
        $tokPerSec = 0.0; $ctxTokens = 0; $ctxWindow = 0
        $llmMs = 0; $toolMs = 0; $inTokens = 0; $cacheRead = 0
        $planActive = $false; $goal = ''; $todoCount = 0; $updatedAt = $null
        try {
            if ($null -ne $it.projections -and $null -ne $it.projections.values) {
                $v = $it.projections.values
                if ($null -ne $v.sessionStats) {
                    $s = $v.sessionStats
                    if ($null -ne $s.turns) { $turns = [int]$s.turns }
                    if ($null -ne $s.steps) { $steps = [int]$s.steps }
                    if ($null -ne $s.decodeTokens) { $tokens = [long]$s.decodeTokens }
                    if ($null -ne $s.llmMs) { $llmMs = [long]$s.llmMs }
                    if ($null -ne $s.toolMs) { $toolMs = [long]$s.toolMs }
                }
                # tps = decodeTokens / decodeMs（DSH 官方 stats 口径，宿主从未提供 liveTokenUsage）
                if ($null -ne $s.decodeMs -and [long]$s.decodeMs -gt 0) {
                    $tokPerSec = [Math]::Round($tokens / ([long]$s.decodeMs / 1000.0), 1)
                }
                if ($null -ne $v.tokenUsage) {
                    if ($null -ne $v.tokenUsage.uncachedInputTokens) { $inTokens = [long]$v.tokenUsage.uncachedInputTokens }
                    if ($null -ne $v.tokenUsage.cacheReadTokens) { $cacheRead = [long]$v.tokenUsage.cacheReadTokens }
                }
                if ($null -ne $v.contextPressure) {
                    if ($null -ne $v.contextPressure.pressureTokens) { $ctxTokens = [long]$v.contextPressure.pressureTokens }
                    if ($null -ne $v.contextPressure.contextWindow) { $ctxWindow = [long]$v.contextPressure.contextWindow }
                }
                if ($null -ne $v.plan) { $planActive = [bool]$v.plan.active }
                if ($null -ne $v.goal -and $null -ne $v.goal.objective) { $goal = [string]$v.goal.objective }
                if ($null -ne $v.todos -and $null -ne $v.todos.items) { $todoCount = @($v.todos.items).Count }
            }
        } catch { }
        if ($null -ne $it.updatedAt) { $updatedAt = $it.updatedAt }   # epoch 毫秒

        if (-not $script:KnownSessions.ContainsKey($sid)) {
            $script:KnownSessions[$sid] = @{
                sid = $sid; title = $title; isSub = $isSub; lastRunning = $false
                runningSince = $null; startTurns = 0; startSteps = 0; startTokens = 0
                liveTurns = 0; liveSteps = 0; liveTokens = 0; cwd = ''
                liveTurnStart = -1
                tokPerSec = 0.0; ctxTokens = 0; ctxWindow = 0
                llmMs = 0; toolMs = 0; inTokens = 0; cacheRead = 0
                planActive = $false; goal = ''; todoCount = 0; updatedAt = $null
                lastUser = ''; lastUserAt = $null; llmRetry = 0; userTurn = -1
                anchorReal = $false; seenBefore = $false
            }
        }
        $rec = $script:KnownSessions[$sid]
        $rec.title = $title
        $rec.isSub = $isSub
        $rec.liveTurns = $turns; $rec.liveSteps = $steps; $rec.liveTokens = $tokens
        $rec.tokPerSec = $tokPerSec; $rec.ctxTokens = $ctxTokens; $rec.ctxWindow = $ctxWindow
        $rec.llmMs = $llmMs; $rec.toolMs = $toolMs; $rec.inTokens = $inTokens; $rec.cacheRead = $cacheRead
        $rec.planActive = $planActive; $rec.goal = $goal; $rec.todoCount = $todoCount
        $rec.updatedAt = $updatedAt
        $rec.cwd = if ($null -ne $it.cwd) { [string]$it.cwd } else { '' }

        if ($running) {
            if (-not $rec.lastRunning) {
                $rec.runningSince = $now
                if ($rec.seenBefore) {
                    # 真实「开始」转变（此前空闲→现在运行）：增量基线 = 当前值，
                    # 完成通知报本段增量；同时弹开始通知
                    $rec.startTurns = $turns; $rec.startSteps = $steps; $rec.startTokens = $tokens
                    if ($script:Cfg.toastOnStart -and (-not $isSub -or $script:Cfg.toastForSubagents)) {
                        Show-Balloon -Title '任务开始' -Text $title -Kind 'Info'
                        Write-Log ('任务开始: ' + $title)
                    }
                } else {
                    # 首见运行中（监视器启动时任务已在跑）：时长起点=本拍（后台 userAt
                    # 到位后渲染层升级为真实起点）；输出基线归零——liveTokens 本就是
                    # 会话总量，完成通知/面板即真实累计值（含监视器启动前已跑的部分），
                    # 不再从监视器启动那刻重新计数
                    $rec.startTurns = 0; $rec.startSteps = 0; $rec.startTokens = 0
                }
            }
            $busy += $rec
        } else {
            if ($rec.lastRunning) {
                # 真实「完成」转变
                $dur = [TimeSpan]::Zero
                if ($null -ne $rec.runningSince) { $dur = $now - $rec.runningSince }
                $dTurns = $turns - $rec.startTurns
                $dSteps = $steps - $rec.startSteps
                $dTokens = $tokens - $rec.startTokens
                $rec.runningSince = $null
                # 完成时刻数据由后台抓取线程提取（完成转变检测时 mm=40 + 深窗兜底）：
                # 结局 kind/message（completed/error/aborted/max-tokens/blocked/interrupted）
                # 与最终用户消息均为后台解析好的小字段——多 MB 原文不跨线程、不滞留 UI 侧
                $outcomeKind = 'completed'; $outcomeMsg = ''
                $fx = $script:FetchExtras[$sid]
                if ($null -ne $fx -and $fx.finish) {
                    if ($fx.finishKind) {
                        $outcomeKind = [string]$fx.finishKind
                        $outcomeMsg = [string]$fx.finishMsg
                    }
                    if ($fx.user) { $rec.lastUser = [string]$fx.user; $rec.lastUserAt = $now }
                    $fx.finish = $false
                }
                $oi = Get-TurnOutcomeInfo $outcomeKind
                $summary = (Format-Duration $dur) + ' · 回合 ' + $dTurns.ToString() + ' · 步骤 ' + $dSteps.ToString() + ' · 输出 ' + (Format-Tokens $dTokens) + ' tokens'
                # 结构化字段（监控窗各列直接取值，避免把 summary 整串塞进「用户消息」列）
                # 口径：steps/turns/tokens = 会话累计总量（与运行行一致，完成前后不跳变）；
                # toast summary 保持增量（本次运行口径）。sid：轮询时跟随会话重命名刷新标题
                $finish = @{
                    title = $title; summary = $summary; at = $now; isSub = $isSub; sid = $sid
                    user = [string]$rec.lastUser
                    outcomeKind = $outcomeKind; outcomeMsg = $outcomeMsg
                    steps = $steps.ToString(); turns = $turns.ToString(); tps = ''
                    dur = (Format-DurationClock $dur); tokens = (Format-Tokens $tokens)
                }
                $script:LastFinished = $finish
                [void]$script:RecentFinishes.Add($finish)
                while ($script:RecentFinishes.Count -gt 10) { $script:RecentFinishes.RemoveAt(0) }
                Write-Log ('任务结束(' + $outcomeKind + '): ' + $title + ' [' + $summary + ']')
                if ($script:Cfg.toastOnFinish -and (-not $isSub -or $script:Cfg.toastForSubagents)) {
                    $tt = if ($isSub) { $oi.toast + '（子任务）' } else { $oi.toast }
                    $toastText = $title + "`n" + $summary
                    if ($outcomeMsg) { $toastText += "`n" + $outcomeMsg }
                    # 多任务场景：提示还剩几个任务在跑
                    $remaining = @($runningIds | Where-Object { $_ -ne $sid }).Count
                    if ($remaining -gt 0) {
                        $toastText += "`n（剩余 " + $remaining.ToString() + ' 个任务运行中）'
                    }
                    Show-Balloon -Title $tt -Text $toastText -Kind $oi.tkind
                    if ($script:Cfg.playSoundOnFinish -and -not $script:TestMode) {
                        switch ($oi.tkind) {
                            'Error'   { [System.Media.SystemSounds]::Hand.Play() }
                            'Warning' { [System.Media.SystemSounds]::Exclamation.Play() }
                            default   { [System.Media.SystemSounds]::Asterisk.Play() }
                        }
                    }
                }
            }
        }
        $rec.lastRunning = $running
        $rec.seenBefore = $true
    }
    # 完成记录跟随会话重命名：session.rename 追加 session/title(kind=user) 事件并钉住投影，
    # KnownSessions.title 每轮轮询刷新——已完成行的标题快照随之更新（用户重命名优先展示）
    foreach ($f in $script:RecentFinishes) {
        if ($f.sid -and $script:KnownSessions.ContainsKey([string]$f.sid)) {
            $curTitle = [string]$script:KnownSessions[[string]$f.sid].title
            if ($curTitle -and $curTitle -ne [string]$f.title) { $f.title = $curTitle }
        }
    }
    # 清理已消失的会话（被删除）
    $stale = @($script:KnownSessions.Keys | Where-Object { -not $seen.ContainsKey($_) })
    foreach ($k in $stale) { $script:KnownSessions.Remove($k) }
    $script:BusySessions = $busy
}

function Update-Status {
    if ($script:Paused) { return }
    if ($null -ne $script:FetchPs) {
        # ── 后台抓取模式（常态）：UI 线程零网络 I/O，只消费快照 ──
        $snap = $null
        $s = $null
        while ($script:FetchQueue.TryDequeue([ref]$s)) { $snap = $s }
        if ($null -eq $snap) { $snap = $script:LastSnap }
        if ($null -ne $snap -and $snap.ok) {
            $script:LastSnap = $snap
            $script:LastPollOk = $true
            if (-not $script:WasConnected) {
                $script:WasConnected = $true
                Write-Log ('已连接 DSH: ' + $script:Cfg.baseUrl)
            }
            # 合并后台提取结果（用户消息/重试/回合号/完成结局）
            foreach ($sid in @($snap.extras.Keys)) { $script:FetchExtras[$sid] = $snap.extras[$sid] }
            try {
                Process-Sessions -Items @($snap.items)
            } catch {
                $script:LastPollOk = $false
                if ($script:WasConnected) { $script:WasConnected = $false; Write-Log ('DSH 连接断开: ' + $_.Exception.Message) }
            }
            if ($snap.deep) { Invoke-MemoryTrim }
        } elseif ($null -ne $snap -and -not $snap.ok) {
            $script:LastPollOk = $false
            if ($script:WasConnected) {
                $script:WasConnected = $false
                Write-Log 'DSH 连接断开: 后台抓取失败'
            }
        }
        # 自适应刷新节奏：监控窗可见 1s（秒级时长/数据），忙 pollSeconds，空闲拉长
        $want = if ($null -ne $script:MonitorForm -and $script:MonitorForm.Visible) { 1000 }
                elseif (@($script:BusySessions).Count -gt 0) { [Math]::Max(1, [int]$script:Cfg.pollSeconds) * 1000 }
                else { 5000 }
        if ($script:Timer.Interval -ne $want) { $script:Timer.Interval = $want }
    } elseif (-not $script:DemoMode -and -not $script:TestMode) {
        # ── 降级路径（后台 runspace 启动失败）：原同步轮询 ──
        if (-not $script:Polling) {
            $script:Polling = $true
            try {
                $value = Invoke-DshRpc 'session.list' @{}
                $items = @($value.items)
                $script:LastPollOk = $true
                if (-not $script:WasConnected) {
                    $script:WasConnected = $true
                    Write-Log ('已连接 DSH: ' + $script:Cfg.baseUrl)
                }
                Process-Sessions -Items $items
            } catch {
                $script:LastPollOk = $false
                if ($script:WasConnected) {
                    $script:WasConnected = $false
                    Write-Log ('DSH 连接断开: ' + $_.Exception.Message)
                }
            } finally {
                $script:Polling = $false
            }
        }
    }
    Drain-SseQueue
    Process-AttentionQueue
    Update-TrayState
    # 周期性内存回收：无论是否深抓，每 5 分钟 GC+归还工作集，防大载荷碎片累积推高常驻内存
    if ((([DateTime]::Now) - $script:LastTrim).TotalSeconds -ge 300) {
        $script:LastTrim = [DateTime]::Now
        Invoke-MemoryTrim
    }
    # status.json 节流：状态指纹变化或 30 秒心跳才落盘（原先每拍全量序列化+写盘）
    $fp = "$($script:LastPollOk)|$(@($script:BusySessions | ForEach-Object { $_.sid + ':' + $_.liveSteps + ':' + $_.liveTurns + ':' + $_.liveTokens }) -join ',')|$($script:AttentionSessions.Count)|$($script:RecentFinishes.Count)"
    if ($fp -ne $script:StatusFp -or (([DateTime]::Now) - $script:StatusLastWrite).TotalSeconds -ge 30) {
        $script:StatusFp = $fp
        $script:StatusLastWrite = [DateTime]::Now
        Update-StatusFile
    }
    Update-StatusWindow
    # 监控窗可见即持续重渲染（未固定面板同样要刷新：时长/步骤/回合实时走）；
    # 渲染只读缓存零网络 I/O，1 秒拍代价可忽略
    if ($null -ne $script:MonitorForm -and $script:MonitorForm.Visible) {
        try { Render-MonitorContent } catch { }
    }
}

# ── 托盘 ──────────────────────────────────────────────────────────────────────
function Set-TrayIcon {
    param([string]$Name)
    if ($Name -eq $script:CurrentIcon -or $null -eq $script:Tray) { return }
    $path = Join-Path $script:IconDir ($Name + '.ico')
    if (Test-Path $path) {
        try {
            $newIcon = New-Object System.Drawing.Icon($path)
            $old = $script:Tray.Icon
            $script:Tray.Icon = $newIcon
            if ($null -ne $old) { $old.Dispose() }
            $script:CurrentIcon = $Name
        } catch {
            Write-Log ('切换图标失败: ' + $_.Exception.Message)
        }
    }
}

# 精简托盘悬浮摘要（系统原生 tooltip，63 字符限制）：运行中 N · 待处理 M
function Format-TraySummary {
    $att = $script:AttentionSessions.Count
    $busyN = @($script:BusySessions).Count
    if ($att -gt 0) {
        $t = '⚠ 待处理 ' + $att.ToString() + ' · 运行中 ' + $busyN.ToString()
    } elseif ($busyN -gt 0) {
        $t = '运行中 ' + $busyN.ToString()
    } else {
        $t = 'DSH 空闲'
    }
    if ($t.Length -gt 63) { $t = $t.Substring(0, 60) + '…' }
    return $t
}

# ── 悬浮详情窗（悬停托盘图标时显示所有运行中会话 + 本轮对话开头）─────────────
# 从消息 content 块中提取文本开头（截断）
function Get-TextPreview {
    param($Msg, [int]$MaxLen = 60)
    if ($null -eq $Msg -or $null -eq $Msg.content) { return '' }
    $sb = ''
    foreach ($b in @($Msg.content)) {
        if ($null -ne $b -and $b.type -eq 'text' -and $null -ne $b.text) {
            $sb += [string]$b.text
            if ($sb.Length -ge $MaxLen) { break }
        }
    }
    $sb = ($sb -replace '\s+', ' ').Trim()
    if ($sb.Length -gt $MaxLen) { $sb = $sb.Substring(0, $MaxLen) + '…' }
    return $sb
}

# 从 session.history 的 events 中提取「本轮对话」展示信息：
#   user = 最后一条用户消息开头（超长回合时尾部窗口可能没有 → 空）
#   live = 进行中内容：优先已成型正文，其次实时文本增量，其次状态提示
function Get-MessagePreview {
    param([object]$HistoryValue)
    $user = ''; $asstText = ''; $deltaText = ''
    $hasReasoning = $false; $hasToolDelta = $false
    $events = @($HistoryValue.events)
    for ($i = $events.Count - 1; $i -ge 0; $i--) {
        $ev = $events[$i].event
        if ($null -eq $ev) { continue }
        $t = [string]$ev.type
        if ($t -eq 'user/message' -and -not $user) {
            $user = Get-TextPreview $ev.data
        } elseif ($t -eq 'assistant/message' -and -not $asstText) {
            $asstText = Get-TextPreview $ev.data.message
        } elseif ($t -eq 'assistant/chunk' -and $null -ne $ev.data -and $null -ne $ev.data.chunk) {
            $c = $ev.data.chunk
            $ct = [string]$c.type
            if ($ct -eq 'text-delta' -and $null -ne $c.text) {
                if ($deltaText.Length -lt 120) { $deltaText = [string]$c.text + $deltaText }
            } elseif ($ct -eq 'reasoning-delta') { $hasReasoning = $true }
            elseif ($ct -eq 'tool-call-delta') { $hasToolDelta = $true }
        }
    }
    if ($asstText) { $live = $asstText }
    elseif ($deltaText) { $live = $deltaText }
    elseif ($hasToolDelta) { $live = '（正在调用工具…）' }
    elseif ($hasReasoning) { $live = '（正在思考…）' }
    else { $live = '（正在生成/等待响应…）' }
    return @{ user = $user; live = $live }
}


# ── 监控窗（单击托盘图标弹出完整信息；点击外部隐藏；可固定置顶；可拖动）─────────
# 表格行数据：@{ status; statusColor; title; user; steps; turns; tps; dur; tokens } 或合并行 @{ merged=$true; text; statusColor }
function Build-MonitorRows {
    $rows = New-Object System.Collections.ArrayList
    $busy = @($script:BusySessions)
    if ($busy.Count -eq 0) {
        # 空闲：列出最近完成记录（表格同构，排版一致）
        $fins = @($script:RecentFinishes)
        if ($fins.Count -gt 0) {
            $n = [Math]::Min(6, $fins.Count)
            for ($i = $n - 1; $i -ge 0; $i--) {
                $fin = $fins[$i]
                # 结局映射：已完成(灰) / 已失败·已中断(红) / 已中止·达上限·被阻断(橙)
                $foi = Get-TurnOutcomeInfo ([string]$fin.outcomeKind)
                # 失败/中断行：用户消息列优先展示错误消息（诊断价值高于原请求）
                $finUser = if ($fin.outcomeMsg) { [string]$fin.outcomeMsg } else { [string]$fin.user }
                [void]$rows.Add(@{
                    status = $foi.label; statusColor = $foi.color
                    title = $(if ($fin.isSub) { '[子] ' + [string]$fin.title } else { [string]$fin.title })
                    user = $finUser
                    steps = [string]$fin.steps; turns = [string]$fin.turns; tps = [string]$fin.tps
                    dur = [string]$fin.dur; tokens = [string]$fin.tokens
                })
            }
            return $rows
        }
        [void]$rows.Add(@{ merged = $true; statusColor = '#9aa0a6'; text = 'DSH 空闲 — 无正在运行的任务' })
        return $rows
    }
    $msgCount = [Math]::Min(8, $busy.Count)
    for ($k = 0; $k -lt $busy.Count; $k++) {
        $r = $busy[$k]
        $att = $null
        if ($script:AttentionSessions.ContainsKey($r.sid)) { $att = $script:AttentionSessions[$r.sid] }
        if ($null -ne $att) {
            $st = if ($att.kind -eq 'approval') { '待批准' } else { '待回答' }
            $color = '#ff6b6b'
        } elseif ($r.llmRetry -gt 0) { $st = '重试中'; $color = '#f39f12' }
        elseif ($r.isSub) { $st = '子任务'; $color = '#f0b429' }
        else { $st = '运行中'; $color = '#2ecc71' }
        $dur = ''
        if ($null -ne $r.runningSince) { $dur = Format-DurationClock (([DateTime]::Now) - $r.runningSince) }
        # 用户消息/重试信号/回合号：全部来自后台抓取缓存 FetchExtras——渲染路径零网络 I/O
        # （原先渲染循环里同步抓 mm=40/400，多 MB 载荷直接冻结 UI）。合并规则：real 用户消息
        # 按 forTurn 去重（同回合只取一次）；合成兜底（goal_round/压缩摘要）只填空；
        # retry/turnStart 每拍刷新（重试信号实时性）。
        if (-not $script:DemoMode -and $k -lt $msgCount) {
            $fx = $script:FetchExtras[$r.sid]
            if ($null -ne $fx) {
                # 真实起点锚定（一次性）：后台抓到最后用户消息的事件时间（epoch ms）→
                # runningSince 回拨到该消息时刻——监视器中途启动也显示任务真实已跑时长。
                # 时钟偏差防御：晚于 now 取 now；早于 24h 视为脏数据不锚
                if (-not $r.anchorReal -and $fx.userAt) {
                    $anchored = [DateTimeOffset]::FromUnixTimeMilliseconds([long]$fx.userAt).LocalDateTime
                    $nowD = [DateTime]::Now
                    if ($anchored -gt $nowD) { $anchored = $nowD }
                    if ($nowD - $anchored -lt [TimeSpan]::FromHours(24)) {
                        $r.runningSince = $anchored
                        $r.anchorReal = $true
                    }
                }
                if ($null -ne $fx.retry) { $r.llmRetry = [int]$fx.retry }
                if ($fx.turnStart -is [int] -and ([int]$fx.turnStart) -gt 0) { $r.liveTurnStart = [int]$fx.turnStart }
                if ($fx.user -and $fx.real -and ([int]$fx.forTurn -ne [int]$r.userTurn)) {
                    $r.lastUser = [string]$fx.user
                    $r.userTurn = [int]$fx.forTurn
                } elseif ($fx.user -and -not $fx.real -and -not $r.lastUser) {
                    $r.lastUser = [string]$fx.user
                    $r.userTurn = [int]$fx.forTurn
                }
            }
        }
        $user = if ($r.lastUser) { [string]$r.lastUser } elseif ($script:DemoMode -and $r.userPreview) { [string]$r.userPreview } else { '（本回合持续中）' }
        [void]$rows.Add(@{
            status = $st; statusColor = $color
            title = $(if ($r.isSub) { '[子] ' + [string]$r.title } else { [string]$r.title })
            user = $user
            steps = [string]$r.liveSteps
            # 显示回合 = max(投影 liveTurns, liveTurnStart)：回合刚开始（首个 step 未完成）
            # 投影未含 → 用 turn/start 号；已有 step/end → 两者相等不重复计
            turns = (Get-DisplayTurns $r).ToString()
            tps = $([int][Math]::Round($r.tokPerSec)).ToString()
            dur = $dur
            tokens = (Format-Tokens $r.liveTokens)
        })
    }
    return $rows
}

# 渲染监控窗表格（自绘：表头 + 数据行，交替底色 + 状态圆点）
function Render-MonitorContent {
    if ($null -eq $script:MonitorTable) { return }
    $script:MonitorRows = @(Build-MonitorRows)
    $tp = $script:MonitorTable
    # 高度仅在行数变化时调整——每次赋值都会触发布局级联与滚动容器背景重绘（闪烁来源之一）
    $newH = 28 + ($script:MonitorRows.Count * 44) + 6
    if ($tp.Height -ne $newH) {
        if ($null -ne $script:MonitorScroll) { $script:MonitorScroll.SuspendLayout() }
        $tp.SuspendLayout()
        $tp.Height = $newH
        $tp.ResumeLayout($false)
        if ($null -ne $script:MonitorScroll) { $script:MonitorScroll.ResumeLayout($false) }
    }
    $tp.Invalidate()
}

# 单击托盘图标切换监控窗
# 注意：监控窗显示时单击图标会先被「点击外部隐藏」过滤器 Hide（图标在窗外），
# 此时引用还在但 Visible=false——必须用 Visible 判断：隐藏中→重新显示，可见→关闭
function Toggle-MonitorWindow {
    if ($null -ne $script:MonitorForm) {
        if ($script:MonitorForm.Visible) {
            Write-Log 'toggle: 窗口可见 → 关闭'
            Hide-MonitorWindow
        } else {
            Write-Log 'toggle: 窗口被过滤器隐藏 → 重新显示'
            $script:MonitorForm.Show()
            try { Render-MonitorContent } catch { }
        }
    } else {
        Write-Log 'toggle: 窗口不存在 → 新建显示'
        Show-MonitorWindow
    }
}

# 加载随包 PNG 图标（FromStream 避免文件锁，便于覆盖更新）
function Load-PinImage {
    param([string]$FileName)
    $path = Join-Path $PSScriptRoot $FileName
    if (Test-Path $path) {
        try {
            $bytes = [System.IO.File]::ReadAllBytes($path)
            $ms = [System.IO.MemoryStream]::new($bytes)
            return [System.Drawing.Image]::FromStream($ms)
        } catch { }
    }
    return $null
}

# 开启控件双缓冲（DoubleBuffered 是 Protected 属性，反射设置）：
# 自绘表格每帧多个 FillRectangle 直画屏幕会闪，双缓冲后整帧经内存位图一次提交
function Enable-DoubleBuffer {
    param($Control)
    try {
        $pi = [System.Windows.Forms.Control].GetProperty('DoubleBuffered', ([System.Reflection.BindingFlags]'Instance,NonPublic'))
        $pi.SetValue($Control, $true, $null)
    } catch { }
}

function Show-MonitorWindow {
    if ($null -eq $script:MonitorFormType) { return }
    # 已有实例：被外部隐藏（Visible=false）时重新显示；可见则保持；已释放则重建
    if ($null -ne $script:MonitorForm) {
        if ($script:MonitorForm.IsDisposed) {
            Write-Log 'monitor: 旧实例已释放 → 重建'
            $script:MonitorForm = $null
            $script:MonitorTable = $null
            $script:MonitorScroll = $null
        } elseif (-not $script:MonitorForm.Visible) {
            try {
                Write-Log 'monitor: 重新显示（此前被外部点击隐藏）'
                $script:MonitorForm.Show()
                Start-Sleep -Milliseconds 50
                Write-Log ('monitor: Show 后 Visible=' + $script:MonitorForm.Visible + ' Location=' + $script:MonitorForm.Location.ToString())
                # 复用路径同样要接线（创建路径的钩子/wantDetail 不经过这里）：
                # 重挂点击外部隐藏钩子（Hide 时已卸载）+ 重开明细抓取 + kick 立即全量抓一轮
                if ($null -ne $script:ClickFilter) {
                    $script:ClickFilter.Target = $script:MonitorForm
                    $script:ClickFilter.Enabled = -not $script:MonitorFixed
                    if ($script:ClickFilter.Enabled) { $script:ClickFilter.Start() }
                }
                $script:FetchState.wantDetail = $true
                $script:FetchState.kick++
                try { Render-MonitorContent } catch { }
            } catch {
                Write-Log ('monitor: 重新显示失败: ' + $_.Exception.Message)
            }
        }
        if ($null -ne $script:MonitorForm) { return }
    }
    try {
        $width = 716
        $form = $script:MonitorFormType::new()
        $form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::None
        $form.ShowInTaskbar = $false
        # 始终置顶：展开必在最前可见（否则会被浏览器等窗口盖住，表现为"点不开"）；
        # 「固定」只控制点击外部是否隐藏，不再切换置顶
        $form.TopMost = $true
        $form.StartPosition = [System.Windows.Forms.FormStartPosition]::Manual

        # 标题栏（拖动把手）
        $title = New-Object System.Windows.Forms.Panel
        $title.BackColor = [System.Drawing.ColorTranslator]::FromHtml('#14141c')
        $title.Dock = [System.Windows.Forms.DockStyle]::Top
        $title.Height = 34
        $lbl = New-Object System.Windows.Forms.Label
        $lbl.Text = 'DSH 任务监控'
        $lbl.ForeColor = [System.Drawing.ColorTranslator]::FromHtml('#e8e8ee')
        $lbl.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 9.5, [System.Drawing.FontStyle]::Bold)
        $lbl.BackColor = [System.Drawing.Color]::Transparent
        $lbl.Location = New-Object System.Drawing.Point(14, 8)
        $lbl.AutoSize = $true
        $title.Controls.Add($lbl)

        # 固定按钮（Bootstrap Icons pin 图钉：未固定=灰空心 pin，已固定=蓝实心 pin-fill）
        if ($null -eq $script:PinImgGray) { $script:PinImgGray = Load-PinImage 'pin-gray.png' }
        if ($null -eq $script:PinImgBlue) { $script:PinImgBlue = Load-PinImage 'pin-blue.png' }
        $pin = New-Object System.Windows.Forms.Button
        $pin.Text = ''
        $pin.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
        $pin.FlatAppearance.BorderSize = 0
        $pin.BackColor = [System.Drawing.ColorTranslator]::FromHtml('#14141c')
        if ($null -ne $script:PinImgGray) {
            $pin.Image = $script:PinImgGray
            $pin.ImageAlign = [System.Drawing.ContentAlignment]::MiddleCenter
            $pin.Size = New-Object System.Drawing.Size(28, 26)
        } else {
            $pin.Text = '📌'
            $pin.Size = New-Object System.Drawing.Size(34, 28)
        }
        $pin.Location = New-Object System.Drawing.Point(($width - 170), 4)
        $pin.FlatAppearance.MouseOverBackColor = [System.Drawing.ColorTranslator]::FromHtml('#23232e')

        # 关闭按钮
        $close = New-Object System.Windows.Forms.Button
        $close.Text = '✕'
        $close.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
        $close.FlatAppearance.BorderSize = 0
        $close.BackColor = [System.Drawing.ColorTranslator]::FromHtml('#14141c')
        $close.ForeColor = [System.Drawing.ColorTranslator]::FromHtml('#c8c8d0')
        $close.Font = New-Object System.Drawing.Font('Segoe UI', 10)
        $close.Size = New-Object System.Drawing.Size(32, 26)
        $close.Location = New-Object System.Drawing.Point(($width - 46), 4)
        $close.FlatAppearance.MouseOverBackColor = [System.Drawing.ColorTranslator]::FromHtml('#8a3a3a')
        $title.Controls.Add($pin)
        $title.Controls.Add($close)

        # 内容区：滚动容器 + 自绘表格
        $scroll = New-Object System.Windows.Forms.Panel
        $scroll.Dock = [System.Windows.Forms.DockStyle]::Fill
        $scroll.AutoScroll = $true
        $scroll.BackColor = [System.Drawing.ColorTranslator]::FromHtml('#17171f')
        $table = New-Object System.Windows.Forms.Panel
        $table.BackColor = [System.Drawing.ColorTranslator]::FromHtml('#17171f')
        $table.Width = 694
        $table.Location = New-Object System.Drawing.Point(0, 0)
        Enable-DoubleBuffer $scroll
        Enable-DoubleBuffer $table
        $table.Add_Paint({
            param($s, $e)
            try {
                $g = $e.Graphics
                $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
                $g.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::ClearTypeGridFit
                $rows = @($script:MonitorRows)
                # 列布局（总宽 694，任务列收紧至 160）：状态 | 任务 | 用户消息 | 步骤 | 回合 | tps | 时长 | 输出
                $cols = @(
                    @{ name = '状态'; x = 8; w = 88; align = 'L' },
                    @{ name = '任务'; x = 98; w = 160; align = 'L' },
                    @{ name = '用户消息'; x = 258; w = 172; align = 'L' },
                    @{ name = '步骤'; x = 430; w = 40; align = 'R' },
                    @{ name = '回合'; x = 470; w = 40; align = 'R' },
                    @{ name = 'tps'; x = 510; w = 44; align = 'R' },
                    @{ name = '时长'; x = 554; w = 58; align = 'R' },
                    @{ name = '输出'; x = 612; w = 50; align = 'R' }
                )
                $headFont = New-Object System.Drawing.Font('Microsoft YaHei UI', 9, [System.Drawing.FontStyle]::Bold)
                $bodyFont = New-Object System.Drawing.Font('Microsoft YaHei UI', 9)
                $headBg = [System.Drawing.SolidBrush]::new([System.Drawing.ColorTranslator]::FromHtml('#1b1b24'))
                $headFg = [System.Drawing.SolidBrush]::new([System.Drawing.ColorTranslator]::FromHtml('#9aa0a6'))
                $fg = [System.Drawing.SolidBrush]::new([System.Drawing.ColorTranslator]::FromHtml('#e6e6ec'))
                $dimFg = [System.Drawing.SolidBrush]::new([System.Drawing.ColorTranslator]::FromHtml('#a8acb6'))
                $linePen = [System.Drawing.Pen]::new([System.Drawing.ColorTranslator]::FromHtml('#262630'))
                # 双行文本格式（自动换行 + 两行上限 + 省略号；垂直居中——单行时不贴顶）
                $wrap = New-Object System.Drawing.StringFormat
                $wrap.Trimming = [System.Drawing.StringTrimming]::EllipsisCharacter
                $wrap.FormatFlags = [System.Drawing.StringFormatFlags]::LineLimit
                $wrap.LineAlignment = [System.Drawing.StringAlignment]::Center
                # 数值/状态格式（右对齐或居中，垂直居中）
                $numFmt = New-Object System.Drawing.StringFormat
                $numFmt.Alignment = [System.Drawing.StringAlignment]::Far
                $numFmt.LineAlignment = [System.Drawing.StringAlignment]::Center
                $midFmt = New-Object System.Drawing.StringFormat
                $midFmt.LineAlignment = [System.Drawing.StringAlignment]::Center
                $headH = 28
                $rowH = 44
                # 表头
                $g.FillRectangle($headBg, 0, 0, $table.Width, $headH)
                foreach ($c in $cols) {
                    if ($c.align -eq 'R') {
                        $g.DrawString($c.name, $headFont, $headFg, ([System.Drawing.RectangleF]::new($c.x, 0, ($c.w - 6), $headH)), $numFmt)
                    } else {
                        $g.DrawString($c.name, $headFont, $headFg, ([System.Drawing.RectangleF]::new($c.x, 0, $c.w, $headH)), $midFmt)
                    }
                }
                # 数据行（双行文字）
                for ($i = 0; $i -lt $rows.Count; $i++) {
                    $r = $rows[$i]
                    $y = $headH + $i * $rowH
                    $bg = if (($i % 2) -eq 0) { '#17171f' } else { '#1a1a23' }
                    $g.FillRectangle([System.Drawing.SolidBrush]::new([System.Drawing.ColorTranslator]::FromHtml($bg)), 0, $y, $table.Width, $rowH)
                    $g.DrawLine($linePen, 0, $y, $table.Width, $y)
                    if ($r.merged) {
                        # 合并行：圆点 + 双行文字
                        $dot = [System.Drawing.SolidBrush]::new([System.Drawing.ColorTranslator]::FromHtml([string]$r.statusColor))
                        $g.FillEllipse($dot, 10, ($y + 18), 8, 8)
                        $g.DrawString([string]$r.text, $bodyFont, $fg, ([System.Drawing.RectangleF]::new(28, $y + 3, 656, 38)), $wrap)
                        $dot.Dispose()
                        continue
                    }
                    # 状态圆点（垂直居中）+ 文字
                    $dot = [System.Drawing.SolidBrush]::new([System.Drawing.ColorTranslator]::FromHtml([string]$r.statusColor))
                    $g.FillEllipse($dot, 10, ($y + 18), 8, 8)
                    $g.DrawString([string]$r.status, $bodyFont, $fg, ([System.Drawing.RectangleF]::new(24, $y, 62, $rowH)), $midFmt)
                    $dot.Dispose()
                    # 双行文字列（任务 / 用户消息：自动换行，两行放不下省略号）
                    $g.DrawString([string]$r.title, $bodyFont, $fg, ([System.Drawing.RectangleF]::new(98, $y + 3, 158, 38)), $wrap)
                    $g.DrawString([string]$r.user, $bodyFont, $dimFg, ([System.Drawing.RectangleF]::new(258, $y + 3, 170, 38)), $wrap)
                    # 数值列（右对齐垂直居中）
                    $g.DrawString([string]$r.steps, $bodyFont, $fg, ([System.Drawing.RectangleF]::new(430, $y, 40, $rowH)), $numFmt)
                    $g.DrawString([string]$r.turns, $bodyFont, $fg, ([System.Drawing.RectangleF]::new(470, $y, 40, $rowH)), $numFmt)
                    $g.DrawString([string]$r.tps, $bodyFont, $fg, ([System.Drawing.RectangleF]::new(510, $y, 44, $rowH)), $numFmt)
                    $g.DrawString([string]$r.dur, $bodyFont, $dimFg, ([System.Drawing.RectangleF]::new(554, $y, 58, $rowH)), $numFmt)
                    $g.DrawString([string]$r.tokens, $bodyFont, $dimFg, ([System.Drawing.RectangleF]::new(612, $y, 50, $rowH)), $numFmt)
                }
                $headBg.Dispose(); $headFg.Dispose(); $fg.Dispose(); $dimFg.Dispose(); $linePen.Dispose()
                $headFont.Dispose(); $bodyFont.Dispose()
                $wrap.Dispose(); $numFmt.Dispose(); $midFmt.Dispose()
            } catch { }
        })
        $scroll.Controls.Add($table)
        $form.Controls.Add($scroll)
        $form.Controls.Add($title)
        $script:MonitorForm = $form
        $script:MonitorTable = $table
        $script:MonitorScroll = $scroll
        $script:MonitorPinBtn = $pin
        $script:MonitorFixed = $false

        # 固定：点击外部不隐藏；再点解除（图钉图标切换；TopMost 恒定 true）
        $pin.Add_Click({
            $script:MonitorFixed = -not $script:MonitorFixed
            if ($script:MonitorFixed) {
                if ($null -ne $script:ClickFilter) { $script:ClickFilter.Enabled = $false; $script:ClickFilter.Dispose() }
                if ($null -ne $script:PinImgBlue) { $script:MonitorPinBtn.Image = $script:PinImgBlue }
            } else {
                if ($null -ne $script:ClickFilter) { $script:ClickFilter.Enabled = $true; if ($null -ne $script:MonitorForm -and $script:MonitorForm.Visible) { $script:ClickFilter.Start() } }
                if ($null -ne $script:PinImgGray) { $script:MonitorPinBtn.Image = $script:PinImgGray }
            }
            Write-Log ('监控窗固定: ' + $script:MonitorFixed)
        })
        $close.Add_Click({ Hide-MonitorWindow })

        # 拖动（标题栏 + 表格区，左键按住拖动）
        $title.Add_MouseDown({ param($s, $e) if ($e.Button -eq 'Left') { $script:MonitorDrag = @{ dx = $e.X; dy = $e.Y } } })
        $title.Add_MouseMove({ param($s, $e) if ($null -ne $script:MonitorDrag -and $null -ne $script:MonitorForm) { $script:MonitorForm.Location = New-Object System.Drawing.Point(($script:MonitorForm.Left + $e.X - $script:MonitorDrag.dx), ($script:MonitorForm.Top + $e.Y - $script:MonitorDrag.dy)) } })
        $title.Add_MouseUp({ $script:MonitorDrag = $null })
        $table.Add_MouseDown({ param($s, $e) if ($e.Button -eq 'Left') { $script:MonitorDrag = @{ dx = $e.X; dy = $e.Y } } })
        $table.Add_MouseMove({ param($s, $e) if ($null -ne $script:MonitorDrag -and $null -ne $script:MonitorForm) { $script:MonitorForm.Location = New-Object System.Drawing.Point(($script:MonitorForm.Left + $e.X - $script:MonitorDrag.dx), ($script:MonitorForm.Top + $e.Y - $script:MonitorDrag.dy)) } })
        $table.Add_MouseUp({ $script:MonitorDrag = $null })

        # 点击外部隐藏（未固定时由 ClickOutsideFilter 处理）
        if ($null -ne $script:ClickFilter) {
            $script:ClickFilter.Target = $form
            $script:ClickFilter.Enabled = -not $script:MonitorFixed
            if ($script:ClickFilter.Enabled) { $script:ClickFilter.Start() }
        }
        # 监控窗可见 → 打开明细抓取（mm=40 用户消息/重试/回合号），kick 重置节流立即全量抓一轮
        $script:FetchState.wantDetail = $true
        $script:FetchState.kick++

        # 内容 + 圆角 + 定位
        Render-MonitorContent
        $radius = 10
        $path = New-Object System.Drawing.Drawing2D.GraphicsPath
        $d = $radius * 2
        $h = 320
        $path.AddArc(0, 0, $d, $d, 180, 90)
        $path.AddArc(($width - $d), 0, $d, $d, 270, 90)
        $path.AddArc(($width - $d), ($h - $d), $d, $d, 0, 90)
        $path.AddArc(0, ($h - $d), $d, $d, 90, 90)
        $path.CloseFigure()
        $form.Region = [System.Drawing.Region]::new($path)
        $form.ClientSize = New-Object System.Drawing.Size($width, $h)
        $wa = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
        $x = $wa.Right - $width - 16
        $y = $wa.Bottom - $h - 12
        if ($x -lt $wa.Left) { $x = $wa.Left + 4 }
        if ($y -lt $wa.Top) { $y = $wa.Top + 4 }
        $form.Location = New-Object System.Drawing.Point($x, $y)
        $form.Show()
        Write-Log '监控窗已显示'
    } catch {
        Write-Log ('监控窗显示失败: ' + $_.Exception.Message)
    }
}

function Hide-MonitorWindow {
    try {
        # 窗口隐藏 = 卸载低级钩子（不留常驻回调）+ 关闭明细抓取（托盘挂机零明细流量）
        if ($null -ne $script:ClickFilter) { $script:ClickFilter.Target = $null; $script:ClickFilter.Dispose() }
        $script:FetchState.wantDetail = $false
        if ($null -ne $script:MonitorForm) {
            $f = $script:MonitorForm
            $script:MonitorForm = $null
            $script:MonitorTable = $null
            $script:MonitorScroll = $null
            $f.Hide()
            $f.Dispose()
        }
        Write-Log '监控窗已关闭'
    } catch { }
}


# ── 「需要用户介入」事件流（WebSocket mux：approval/question 帧）────────────────
# 后台线程直连 ws://…/api/events.mux，解析 server-request 信封，
# requested 帧 → 入队待通知 + 记录状态；resolved 帧 → 清除状态。
# mux 重连时会重放未应答的 requested 帧（与宿主重放语义一致），Known* 表负责去重。
function Handle-AttentionFrame {
    param($Envelope)
    $frame = $Envelope.payload
    if ($null -eq $frame) { return }
    $type = [string]$frame.type
    if ($type -eq 'approval/requested') {
        $sid = [string]$frame.sessionId
        $aid = [string]$frame.approvalId
        if (-not $aid -or $script:KnownApprovals.ContainsKey($aid)) { return }   # 重放去重
        $script:KnownApprovals[$aid] = $sid
        $tool = [string]$frame.toolName
        $reason = if ($null -ne $frame.reason) { [string]$frame.reason } else { '' }
        $text = '请求批准工具调用: ' + $tool
        if ($reason) { $text += "`n原因: " + $reason }
        $script:AttentionSessions[$sid] = @{ kind = 'approval'; approvalId = $aid; questionRpcId = ''; text = $text; at = [DateTime]::Now }
        $script:AttQueue.Enqueue(@{ kind = 'approval'; sessionId = $sid; text = $text })
    } elseif ($type -eq 'approval/resolved') {
        $aid = [string]$frame.approvalId
        if ($script:KnownApprovals.ContainsKey($aid)) {
            $sid = $script:KnownApprovals[$aid]
            if ($script:AttentionSessions.ContainsKey($sid) -and $script:AttentionSessions[$sid].kind -eq 'approval') {
                $script:AttentionSessions.Remove($sid)
            }
        }
    } elseif ($type -eq 'question/requested') {
        $sid = [string]$frame.sessionId
        $rpcId = [string]$Envelope.rpcId
        if (-not $rpcId -or $script:KnownQuestions.ContainsKey($rpcId)) { return }  # 重放去重
        $script:KnownQuestions[$rpcId] = $sid
        $qs = @($frame.questions)
        $first = if ($qs.Count -gt 0 -and $null -ne $qs[0].question) { [string]$qs[0].question } else { '' }
        $text = '向你提问（' + $qs.Count.ToString() + ' 个问题）'
        if ($first) { $text += "`n" + $first }
        $script:AttentionSessions[$sid] = @{ kind = 'question'; approvalId = ''; questionRpcId = $rpcId; text = $text; at = [DateTime]::Now }
        $script:AttQueue.Enqueue(@{ kind = 'question'; sessionId = $sid; text = $text })
    } elseif ($type -eq 'question/resolved') {
        $rpcId = [string]$frame.questionRpcId
        if ($script:KnownQuestions.ContainsKey($rpcId)) {
            $sid = $script:KnownQuestions[$rpcId]
            if ($script:AttentionSessions.ContainsKey($sid) -and $script:AttentionSessions[$sid].kind -eq 'question') {
                $script:AttentionSessions.Remove($sid)
            }
        }
    }
}

# 后台 runspace 的 WS 监听代码（独立 runspace 执行，避免跨线程访问主 runspace）：
# 直连 ws://…/api/events.mux，把每个原始帧文本入队共享队列；主 runspace 轮询时解析。
# mux 重连时会重放未应答的 requested 帧（与宿主重放语义一致），Known* 表负责去重。
$script:SseCode = @'
param($State, $Queue, $LogFile, $BaseUrl)
function SseLog {
    param([string]$m)
    try { [System.IO.File]::AppendAllText($LogFile, (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + ' [sse] ' + $m + [Environment]::NewLine, [System.Text.Encoding]::UTF8) } catch {}
}
while (-not $State.stop) {
    $ws = $null
    try {
        $url = ($BaseUrl -replace '^http', 'ws').TrimEnd('/') + '/api/events.mux'
        $ws = [System.Net.WebSockets.ClientWebSocket]::new()
        $ws.ConnectAsync([uri]$url, [System.Threading.CancellationToken]::None).GetAwaiter().GetResult()
        SseLog 'connected'
        while (-not $State.stop -and $ws.State -eq [System.Net.WebSockets.WebSocketState]::Open) {
            $buffer = New-Object byte[] 131072
            $seg = [System.ArraySegment[byte]]::new($buffer)
            $result = $ws.ReceiveAsync($seg, [System.Threading.CancellationToken]::None).GetAwaiter().GetResult()
            if ($result.Count -eq 0) { break }
            $text = [System.Text.Encoding]::UTF8.GetString($buffer, 0, $result.Count)
            $Queue.Enqueue($text)
        }
    } catch {
        SseLog ('disconnected: ' + $_.Exception.Message)
    } finally {
        try { if ($null -ne $ws) { $ws.Dispose() } } catch {}
    }
    if ($State.stop) { break }
    Start-Sleep -Seconds 3
}
SseLog 'stopped'
'@

function Start-SseListener {
    if ($null -ne $script:SsePs) { return }
    $script:SseState.stop = $false
    # 清空遗留帧
    $dummy = $null
    while ($script:SseQueue.TryDequeue([ref]$dummy)) { }
    $script:SsePs = [System.Management.Automation.PowerShell]::Create()
    [void]$script:SsePs.AddScript($script:SseCode).AddArgument($script:SseState).AddArgument($script:SseQueue).AddArgument($script:LogFile).AddArgument([string]$script:Cfg.baseUrl)
    $script:SsePs.BeginInvoke() | Out-Null
    Write-Log '事件流监听已启动（审批/提问）'
}

function Stop-SseListener {
    # 只设停止标志；不调 Stop()/Dispose()（会阻塞在 WS 接收上），后台 runspace 随进程退出
    $script:SseState.stop = $true
}

# ── 后台轮询抓取 runspace（性能修复核心）────────────────────────────────────
# UI 线程原先同步做 session.list 解析 + 运行会话 mm=40/400 抓取（单次 2.9~15.6MB），
# DSH 忙碌/掉线时每个 tick 冻结 UI 最多 8 秒（HTTP 超时），叠加低级鼠标钩子 = 「整机卡死」观感。
# 此 runspace 仿 SSE 监听模式：独立 PowerShell 实例循环抓取，产出紧凑快照入队，UI 只消费。
# 快照：@{ ok; items(后台已解析的会话数组); extras(sid->提取结果); deep(是否做过深窗抓取) }
$script:FetchCode = @'
param($State, $Queue, $BaseUrl, $TimeoutSec)
Add-Type -AssemblyName System.Net.Http
function RpcRaw {
    param([string]$Method, [hashtable]$Payload = @{})
    $req = @{ type = 'client-request'; rpcId = [guid]::NewGuid().ToString(); method = $Method; payload = $Payload }
    $json = $req | ConvertTo-Json -Depth 10 -Compress
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
    $content = [System.Net.Http.ByteArrayContent]::new($bytes)
    $content.Headers.ContentType = [System.Net.Http.Headers.MediaTypeHeaderValue]::new('application/json')
    $url = $BaseUrl.TrimEnd('/') + '/api/' + $Method
    $resp = $http.PostAsync($url, $content).GetAwaiter().GetResult()
    if (-not $resp.IsSuccessStatusCode) { throw ('HTTP ' + [int]$resp.StatusCode) }
    $respBytes = $resp.Content.ReadAsByteArrayAsync().GetAwaiter().GetResult()
    return [System.Text.Encoding]::UTF8.GetString($respBytes)
}
# Get-LastUserEx / Get-LastTurnEndFromRaw 的本线程拷贝（runspace 无法调用主会话函数）。
# at = 该消息事件的 time 字段（epoch 毫秒）——首见运行中会话用它锚定真实任务起点
function GetLUser {
    param([string]$Raw, [int]$MaxLen = 60)
    if (-not $Raw) { return @{ text = ''; real = $false; at = [long]0 } }
    $best = ''
    $bestAt = [long]0
    $scanFrom = $Raw.Length
    while ($scanFrom -gt 0) {
        $pos = $Raw.LastIndexOf('"type":"user/message"', $scanFrom - 1)
        if ($pos -lt 0) { break }
        $look = $Raw.Substring($pos, [Math]::Min(8000, $Raw.Length - $pos))
        $m = [regex]::Match($look, '"text"\s*:\s*"((?:[^"\\]|\\.)*)"')
        $txt = ''
        if ($m.Success) {
            $txt = [regex]::Unescape($m.Groups[1].Value)
            $txt = ($txt -replace '\s+', ' ').Trim()
        }
        # 事件信封：{"type":"user/message","seq":N,"time":T,"data":{...}} —— time 在 data 之前
        $evtAt = [long]0
        $tm = [regex]::Match($look.Substring(0, [Math]::Min(250, $look.Length)), '"time":(\d{13,14})')
        if ($tm.Success) { $evtAt = [long]$tm.Groups[1].Value }
        if ($txt -and $look.Contains('"kind":"user"')) {
            if ($txt.Length -gt $MaxLen) { $txt = $txt.Substring(0, $MaxLen) + '...' }
            if ($evtAt -eq 0) { $evtAt = $bestAt }
            return @{ text = $txt; real = $true; at = $evtAt }
        }
        if (-not $best -and $txt) { $best = $txt; $bestAt = $evtAt }
        $scanFrom = $pos
    }
    if ($best.Length -gt $MaxLen) { $best = $best.Substring(0, $MaxLen) + '...' }
    return @{ text = $best; real = $false; at = $bestAt }
}
function GetLastEnd {
    # 与主线程 Get-LastTurnEndFromRaw 相同口径：最后一个 turn/end 的 kind/message
    param([string]$Raw)
    if (-not $Raw) { return $null }
    $pos = $Raw.LastIndexOf('"type":"turn/end"')
    if ($pos -lt 0) { return $null }
    $look = $Raw.Substring($pos, [Math]::Min(4000, $Raw.Length - $pos))
    $k = [regex]::Match($look, '"kind"\s*:\s*"((?:[^"\\]|\\.)*)"')
    $msg = ''
    $mm = [regex]::Match($look, '"message"\s*:\s*"((?:[^"\\]|\\.)*)"')
    if ($mm.Success) { $msg = [regex]::Unescape($mm.Groups[1].Value) }
    if ($k.Success) { return @{ kind = $k.Groups[1].Value; message = $msg } }
    return $null
}
$http = New-Object System.Net.Http.HttpClient
$http.Timeout = [TimeSpan]::FromSeconds($TimeoutSec)
$lastTurns = @{}       # sid -> @{ at=上次抓取时刻; proj=上次投影回合 }（节流+回合门控）
$lastRunning = @{}     # sid -> 上次快照 running（完成转变检测）
$running = @()
$kick = 0              # UI 踢脚计数（监控窗打开时 +1 → 立即重置节流全量抓一轮）
while (-not $State.stop) {
    # 自适应间隔：有任务运行 pollMs，空闲 idleMs（250ms 切片睡眠，可快速响应停止）
    $interval = if ($running.Count -gt 0) { $State.pollMs } else { $State.idleMs }
    $slept = 0
    while (-not $State.stop -and $slept -lt $interval) { Start-Sleep -Milliseconds 250; $slept += 250 }
    if ($State.stop) { break }
    # 快照只装小对象：解析后的 items + 逐会话提取结果；不带任何多 MB 原文跨线程
    $snap = @{ ok = $false; items = $null; extras = @{}; deep = $false }
    try {
        $listRaw = RpcRaw 'session.list' @{}
        $snap.ok = $true
        # 唯一一次 JSON 解析（后台线程）；UI 线程直接消费 items，不再重复解析
        $obj = $listRaw | ConvertFrom-Json
        $listRaw = $null
        $items = @($obj.result.value.items)
        $obj = $null
        $snap.items = $items
        $running = @($items | Where-Object { $_.running })
        # 明细抓取按需：仅监控窗可见（wantDetail）时才抓 mm=40 明细（重试/回合号/用户消息，
        # 载荷 1~3MB/条）。托盘挂机零明细流量——与旧架构口径一致（旧版只在渲染监控窗时抓）。
        # 监控窗打开时 UI 将 kick+1：此处重置节流表，本轮全量立即抓取，窗口即时有数据
        if ($State.kick -ne $kick) { $kick = $State.kick; $lastTurns = @{} }
        if ($State.wantDetail) {
            $i = 0
            foreach ($it in $running) {
                if ($i -ge 8) { break }
                $i++
                $sid = [string]$it.sessionId
                $proj = [int]$it.projections.values.sessionStats.turns
                $st = $lastTurns[$sid]
                $turnChanged = ($null -eq $st) -or ($st.proj -ne $proj)
                $throttleOk = ($null -eq $st) -or (((Get-Date) - $st.at).TotalSeconds -ge 10)
                if (-not $turnChanged -and -not $throttleOk) { continue }
                try {
                    $raw = RpcRaw 'session.history' @{ sessionId = $sid; maxMessages = 40 }
                    $ex = @{}
                    $ex.retry = ([regex]::Matches($raw, '"type":"llm/retry"')).Count
                    $tsPos = $raw.LastIndexOf('"type":"turn/start"')
                    if ($tsPos -ge 0) {
                        $m2 = [regex]::Match($raw.Substring($tsPos, [Math]::Min(200, $raw.Length - $tsPos)), '"turn"\s*:\s*(\d+)')
                        if ($m2.Success) { $ex.turnStart = [int]$m2.Groups[1].Value }
                    }
                    if ($turnChanged) {
                        $ux = GetLUser $raw
                        if (-not $ux.real) {
                            $deepRaw = RpcRaw 'session.history' @{ sessionId = $sid; maxMessages = 400 }
                            $ux2 = GetLUser $deepRaw
                            if ($ux2.real) { $ux = $ux2 }
                            elseif (-not $ux.text -and $ux2.text) { $ux = $ux2 }
                            $deepRaw = $null
                            $snap.deep = $true
                        }
                        $ex.user = $ux.text; $ex.real = $ux.real; $ex.forTurn = $proj
                        if ($ux.at) { $ex.userAt = $ux.at }
                    }
                    $snap.extras[$sid] = $ex
                    $lastTurns[$sid] = @{ at = Get-Date; proj = $proj }
                } catch {}
                $raw = $null
            }
        }
        # 完成转变（running->false）：结局+最终用户消息在后台提取完成再入队（不回传原文）
        foreach ($it in $items) {
            $sid = [string]$it.sessionId
            $wasRun = $lastRunning[$sid]
            if ($wasRun -eq $true -and -not $it.running) {
                try {
                    $fraw = RpcRaw 'session.history' @{ sessionId = $sid; maxMessages = 40 }
                    $fx = $snap.extras[$sid]
                    if ($null -eq $fx) { $fx = @{}; $snap.extras[$sid] = $fx }
                    $te = GetLastEnd $fraw
                    if ($null -ne $te) { $fx.finishKind = [string]$te.kind; $fx.finishMsg = [string]$te.message }
                    else { $fx.finishKind = 'completed'; $fx.finishMsg = '' }
                    $ux = GetLUser $fraw
                    if (-not $ux.real) {
                        $fdeep = RpcRaw 'session.history' @{ sessionId = $sid; maxMessages = 400 }
                        $ux2 = GetLUser $fdeep
                        if ($ux2.real) { $ux = $ux2 }
                        elseif (-not $ux.text -and $ux2.text) { $ux = $ux2 }
                        $fdeep = $null
                        $snap.deep = $true
                    }
                    $fx.finish = $true
                    if ($ux.at) { $fx.userAt = $ux.at }
                    $fx.user = $ux.text; $fx.real = $ux.real
                    $fraw = $null
                } catch {}
            }
            $lastRunning[$sid] = [bool]$it.running
        }
        if ($snap.deep) { [System.GC]::Collect() }
    } catch {}
    $Queue.Enqueue($snap)
    $snap = $null
}
try { $http.Dispose() } catch {}
'@

function Start-Fetcher {
    if ($null -ne $script:FetchPs -or $script:DemoMode -or $script:TestMode) { return }
    $script:FetchState.stop = $false
    $script:FetchState.pollMs = [Math]::Max(1, [int]$script:Cfg.pollSeconds) * 1000
    $script:FetchState.idleMs = [Math]::Max($script:FetchState.pollMs, 10000)
    $script:FetchState.wantDetail = ($null -ne $script:MonitorForm -and $script:MonitorForm.Visible)
    $script:FetchState.kick++
    # 清空遗留快照
    $dummy = $null
    while ($script:FetchQueue.TryDequeue([ref]$dummy)) { }
    $script:FetchPs = [System.Management.Automation.PowerShell]::Create()
    [void]$script:FetchPs.AddScript($script:FetchCode).AddArgument($script:FetchState).AddArgument($script:FetchQueue).AddArgument([string]$script:Cfg.baseUrl).AddArgument(8)
    $script:FetchPs.BeginInvoke() | Out-Null
    Write-Log '后台抓取已启动（UI 线程零网络 I/O）'
}

function Stop-Fetcher {
    $script:FetchState.stop = $true
}

# 深窗抓取后回收内存：GC + 归还工作集（250MB 工作集主因是多 MB 原文串滞留 LOH）
function Invoke-MemoryTrim {
    try {
        [System.GC]::Collect()
        [System.GC]::WaitForPendingFinalizers()
        if ($null -ne $script:ProcHandle) { [void][DshTaskWatcher.Mem]::EmptyWorkingSet($script:ProcHandle) }
    } catch { }
}

# 主线程消费事件流队列：解析帧 → 更新待介入状态/入通知队列
function Drain-SseQueue {
    while ($true) {
        $text = $null
        if (-not $script:SseQueue.TryDequeue([ref]$text)) { break }
        try {
            $obj = $text | ConvertFrom-Json
            if ($null -ne $obj -and $null -ne $obj.payload) { Handle-AttentionFrame $obj }
        } catch { }
    }
}

# UI 线程消费待介入队列：弹系统通知 + 提示音
function Process-AttentionQueue {
    while ($true) {
        $entry = $null
        if (-not $script:AttQueue.TryDequeue([ref]$entry)) { break }
        if ($script:Cfg.notifyOnUserAction) {
            $title = if ($entry.kind -eq 'approval') { '需要你的批准' } else { '有提问待回答' }
            $sid = [string]$entry.sessionId
            $sessTitle = if ($script:KnownSessions.ContainsKey($sid)) { [string]$script:KnownSessions[$sid].title } else { $sid }
            $text = '会话「' + $sessTitle + '」' + [string]$entry.text
            Show-Balloon -Title $title -Text $text -Kind 'Warning'
            if ($script:Cfg.attentionSound) {
                [System.Media.SystemSounds]::Exclamation.Play()
            }
            Write-Log ('待介入: ' + $title + ' | ' + ($text -replace "`n", ' / '))
        }
    }
}

# 图标状态判定（优先级：灰=未连接/暂停 > 红=需介入 > 橙=运行中 > 绿=空闲）
function Get-TrayIconName {
    if ($script:Paused -or -not $script:LastPollOk) { return 'gray' }
    if ($script:AttentionSessions.Count -gt 0) { return 'red' }
    if (@($script:BusySessions).Count -gt 0) { return 'amber' }
    return 'green'
}

function Update-TrayState {
    # 图标颜色 + 系统原生悬浮摘要（精简：运行中 N · 待处理 M）
    if ($null -eq $script:Tray) { return }
    Set-TrayIcon (Get-TrayIconName)
    try {
        if ($script:Paused) { $script:Tray.Text = '已暂停' }
        elseif (-not $script:LastPollOk) { $script:Tray.Text = 'DSH 未连接' }
        else { $script:Tray.Text = Format-TraySummary }
    } catch { }
}

function Show-Balloon {
    param([string]$Title, [string]$Text, [string]$Kind = 'Info')
    if ($script:TestMode) {
        [void]$script:TestToasts.Add(@{ title = $Title; text = $Text; kind = $Kind })
        return
    }
    if ($null -eq $script:Tray) { return }
    try {
        $script:Tray.BalloonTipIcon = [System.Windows.Forms.ToolTipIcon]::$Kind
        $script:Tray.BalloonTipTitle = $Title
        $script:Tray.BalloonTipText = $Text
        $script:Tray.ShowBalloonTip(8000)
    } catch { }
}

function Open-Dsh {
    try { Start-Process $script:Cfg.openUrl } catch { }
}

function Toggle-Pause {
    $script:Paused = -not $script:Paused
    if ($script:Paused) {
        $script:MenuPauseItem.Text = '继续监控'
        Write-Log '监控已暂停'
    } else {
        $script:MenuPauseItem.Text = '暂停监控'
        Write-Log '监控已恢复'
        Update-Status
    }
}

function Reload-Config {
    Read-Config
    if ($null -ne $script:Timer) {
        $script:Timer.Interval = [Math]::Max(1, [int]$script:Cfg.pollSeconds) * 1000
    }
    if ($null -ne $script:StatusForm) { $script:StatusForm.TopMost = [bool]$script:Cfg.statusWindowOnTop }
    Write-Log '配置已重新加载'
    if (-not $script:TestMode) {
        Show-Balloon '配置已重载' ('轮询间隔 ' + $script:Cfg.pollSeconds + ' 秒') 'Info'
    }
    Update-Status
}

function New-Tray {
    $tray = New-Object System.Windows.Forms.NotifyIcon
    $tray.Visible = $true
    $tray.Text = 'DSH 任务监视器'   # 系统原生悬浮（更新为精简摘要）
    $script:Tray = $tray

    $menu = New-Object System.Windows.Forms.ContextMenuStrip
    $miOpen   = $menu.Items.Add('打开 DSH 控制台')
    $miMon    = $menu.Items.Add('监控窗')
    $miWin    = $menu.Items.Add('状态窗口')
    $miPause  = $menu.Items.Add('暂停监控')
    $miReload = $menu.Items.Add('重新加载配置')
    $miCfg    = $menu.Items.Add('编辑配置')
    $miLogs   = $menu.Items.Add('打开日志目录')
    [void]$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
    $miExit   = $menu.Items.Add('退出')
    $tray.ContextMenuStrip = $menu

    $miOpen.Add_Click({ Open-Dsh })
    $miMon.Add_Click({ Toggle-MonitorWindow })
    $miWin.Add_Click({ Toggle-StatusWindow })
    $miPause.Add_Click({ Toggle-Pause })
    $miReload.Add_Click({ Reload-Config })
    $miCfg.Add_Click({ Start-Process notepad.exe -ArgumentList ('"' + $script:ConfigFile + '"') })
    $miLogs.Add_Click({ if (Test-Path $script:LogDir) { Start-Process $script:LogDir } })
    $miExit.Add_Click({ Exit-App })
    $tray.Add_BalloonTipClicked({ Open-Dsh })
    # 左键单击：始终展示监控窗（已显示则保持）——关闭走「点击外部」或 ✕ 按钮。
    # 用 MouseDown/MouseUp 判定单击（比 Click 可靠：NotifyIcon 的 Click 在多次
    # Show/Hide 循环后可能停止投递；MouseUp 每次释放都触发，且不受双击合并影响）
    $tray.Add_MouseDown({ param($s, $e) if ($e.Button -eq 'Left') { $script:TrayDownAt = [DateTime]::Now } })
    $tray.Add_MouseUp({
        param($s, $e)
        if ($e.Button -eq 'Left') {
            $dur = ([DateTime]::Now - $script:TrayDownAt).TotalMilliseconds
            if ($dur -lt 600) {
                Write-Log ('tray: 单击(按下-释放 ' + [int]$dur + 'ms) @' + (Get-Date -Format 'HH:mm:ss.fff') + ' form=' + $(if ($null -ne $script:MonitorForm) { if ($script:MonitorForm.Visible) { 'visible' } else { 'hidden' } } else { 'null' }))
                Show-MonitorWindow
            }
        }
    })
    $script:MenuPauseItem = $miPause
}

# ── 状态窗口 ──────────────────────────────────────────────────────────────────
function Toggle-StatusWindow {
    if ($script:StatusVisible) { Hide-StatusWindow } else { Show-StatusWindow }
}

function New-ColumnHeader {
    param([string]$Text, [int]$Width)
    $col = New-Object System.Windows.Forms.ColumnHeader
    $col.Text = $Text
    $col.Width = $Width
    return $col
}

function Show-StatusWindow {
    # 防御：窗口被关闭（X）后 Form 已释放，检查并清空引用以便重建
    if ($null -ne $script:StatusForm -and $script:StatusForm.IsDisposed) {
        $script:StatusForm = $null
        $script:StatusList = $null
        $script:StatusFinList = $null
        $script:StatusLblRunning = $null
    }
    if ($null -eq $script:StatusForm) {
        $form = New-Object System.Windows.Forms.Form
        $form.Text = 'DSH 任务状态'
        $form.Width = 900; $form.Height = 480
        $form.MinimumSize = New-Object System.Drawing.Size(640, 260)
        $form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::SizableToolWindow
        $form.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterScreen
        $form.TopMost = [bool]$script:Cfg.statusWindowOnTop
        $form.Add_FormClosed({
            $script:StatusVisible = $false
            # 窗口被右上角 X 关闭时 Form 已被 Dispose，引用全部清空，下次打开重建
            $script:StatusForm = $null
            $script:StatusList = $null
            $script:StatusFinList = $null
            $script:StatusLblRunning = $null
        })

        $lblRunning = New-Object System.Windows.Forms.Label
        $lblRunning.Text = '运行中 (0)'
        $lblRunning.Dock = [System.Windows.Forms.DockStyle]::Top
        $lblRunning.Height = 22
        $lblRunning.Font = New-Object System.Drawing.Font($lblRunning.Font.FontFamily, 9, [System.Drawing.FontStyle]::Bold)

        $list = New-Object System.Windows.Forms.ListView
        $list.Dock = [System.Windows.Forms.DockStyle]::Fill
        $list.View = [System.Windows.Forms.View]::Details
        $list.FullRowSelect = $true
        $list.GridLines = $true
        $list.MultiSelect = $false
        [void]$list.Columns.Add((New-ColumnHeader '任务' 240))
        [void]$list.Columns.Add((New-ColumnHeader '类型' 60))
        [void]$list.Columns.Add((New-ColumnHeader '回合' 45))
        [void]$list.Columns.Add((New-ColumnHeader '步骤' 45))
        [void]$list.Columns.Add((New-ColumnHeader '输出' 70))
        [void]$list.Columns.Add((New-ColumnHeader '速度' 65))
        [void]$list.Columns.Add((New-ColumnHeader '上下文' 70))
        [void]$list.Columns.Add((New-ColumnHeader '时长' 80))
        [void]$list.Columns.Add((New-ColumnHeader '目录' 150))
        $list.Add_DoubleClick({
            if ($null -ne $script:StatusList -and $script:StatusList.SelectedItems.Count -gt 0) {
                $item = $script:StatusList.SelectedItems[0]
                if ($null -ne $item.Tag) { Show-SessionDetail -SessionId ([string]$item.Tag) }
            }
        })

        $lblFin = New-Object System.Windows.Forms.Label
        $lblFin.Text = '最近完成'
        $lblFin.Dock = [System.Windows.Forms.DockStyle]::Bottom
        $lblFin.Height = 22
        $lblFin.Font = New-Object System.Drawing.Font($lblFin.Font.FontFamily, 9, [System.Drawing.FontStyle]::Bold)

        $finList = New-Object System.Windows.Forms.ListView
        $finList.Dock = [System.Windows.Forms.DockStyle]::Bottom
        $finList.Height = 110
        $finList.View = [System.Windows.Forms.View]::Details
        $finList.FullRowSelect = $true
        $finList.GridLines = $true
        $finList.MultiSelect = $false
        [void]$finList.Columns.Add((New-ColumnHeader '任务' 220))
        [void]$finList.Columns.Add((New-ColumnHeader '统计' 300))
        [void]$finList.Columns.Add((New-ColumnHeader '完成时间' 110))

        $form.Controls.Add($list)          # Fill 占中间
        $form.Controls.Add($lblRunning)    # Top
        $form.Controls.Add($finList)       # Bottom
        $form.Controls.Add($lblFin)        # Bottom（先加的 Bottom 在上方）
        $script:StatusForm = $form
        $script:StatusList = $list
        $script:StatusFinList = $finList
        $script:StatusLblRunning = $lblRunning
    }
    $script:StatusVisible = $true
    Update-StatusWindow
    $script:StatusForm.Show()
    $script:StatusForm.Activate()
}

function Hide-StatusWindow {
    $script:StatusVisible = $false
    if ($null -ne $script:StatusForm) { $script:StatusForm.Hide() }
}

function Format-CtxPercent {
    param([long]$Tokens, [long]$Window)
    if ($Window -gt 0) { return ([int][Math]::Round($Tokens * 100.0 / $Window)).ToString() + '%' }
    return '-'
}

function Update-StatusWindow {
    if (-not $script:StatusVisible -or $null -eq $script:StatusList) { return }
    try {
        $list = $script:StatusList
        $list.BeginUpdate()
        $list.Items.Clear()
        $busy = @($script:BusySessions)
        # 排序：主任务在前，其次按开始时间（先开始的在上）
        $sorted = @($busy | Sort-Object @{ e = { $_.isSub } }, @{ e = { if ($null -ne $_.runningSince) { $_.runningSince } else { [DateTime]::MaxValue } } })
        if (-not $script:LastPollOk) {
            [void]$list.Items.Add([System.Windows.Forms.ListViewItem]::new([string[]]@('DSH 服务不可达', '', '', '', '', '', '', '', '')))
        } elseif ($busy.Count -eq 0) {
            $txt = if ($null -ne $script:LastFinished) { '空闲 · 最近完成: ' + $script:LastFinished.title } else { '空闲 — 无正在运行的任务' }
            [void]$list.Items.Add([System.Windows.Forms.ListViewItem]::new([string[]]@($txt, '', '', '', '', '', '', '', '')))
        } else {
            foreach ($r in $sorted) {
                $dur = ''
                if ($null -ne $r.runningSince) { $dur = Format-Duration (([DateTime]::Now) - $r.runningSince) }
                $att = $null
                if ($script:AttentionSessions.ContainsKey($r.sid)) { $att = $script:AttentionSessions[$r.sid] }
                $st = if ($null -ne $att) {
                    if ($att.kind -eq 'approval') { '⚠ 审批中' } else { '⚠ 提问中' }
                } elseif ($r.llmRetry -gt 0) { '⟳ 重试中' }
                elseif ($r.isSub) { '子任务' } else { '主任务' }
                $spd = if ($r.tokPerSec -gt 0) { [int][Math]::Round($r.tokPerSec) } else { 0 }
                $titleTxt = if ($null -ne $att) { '⚠ ' + [string]$r.title } else { [string]$r.title }
                $item = [System.Windows.Forms.ListViewItem]::new([string[]]@(
                    $titleTxt, $st, (Get-DisplayTurns $r).ToString(), [string]$r.liveSteps,
                    (Format-Tokens $r.liveTokens), $spd.ToString() + ' t/s',
                    (Format-CtxPercent $r.ctxTokens $r.ctxWindow),
                    $dur, [string]$r.cwd))
                $item.Tag = $r.sid
                [void]$list.Items.Add($item)
            }
        }
        $list.EndUpdate()
        if ($null -ne $script:StatusLblRunning) {
            $script:StatusLblRunning.Text = if ($busy.Count -gt 0) { '运行中 (' + $busy.Count + ')' } else { '运行中 (0)' }
        }
        # 最近完成列表
        if ($null -ne $script:StatusFinList) {
            $finList = $script:StatusFinList
            $finList.BeginUpdate()
            $finList.Items.Clear()
            foreach ($f in @($script:RecentFinishes)) {
                $tag = if ($f.isSub) { '（子任务）' } else { '' }
                # 非正常结局：任务名前加结局标注（已失败/已中断/已中止/达上限/被阻断）
                $otag = ''
                $fkind = [string]$f.outcomeKind
                if ($fkind -and $fkind -ne 'completed') { $otag = '[' + (Get-TurnOutcomeInfo $fkind).label + '] ' }
                [void]$finList.Items.Add([System.Windows.Forms.ListViewItem]::new([string[]]@(
                    $otag + [string]$f.title + $tag, [string]$f.summary,
                    $f.at.ToString('HH:mm:ss'))))
            }
            $finList.EndUpdate()
        }
    } catch { }
}

# ── 单任务详情窗口（双击运行中行弹出，展示细粒度统计）─────────────────────────
function Show-SessionDetail {
    param([string]$SessionId)
    if (-not $script:KnownSessions.ContainsKey($SessionId)) { return }
    $rec = $script:KnownSessions[$SessionId]
    $form = New-Object System.Windows.Forms.Form
    $form.Text = '任务详情'
    $form.Width = 600; $form.Height = 430
    $form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedDialog
    $form.MaximizeBox = $false
    $form.MinimizeBox = $false
    $form.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterParent

    $table = New-Object System.Windows.Forms.TableLayoutPanel
    $table.Dock = [System.Windows.Forms.DockStyle]::Fill
    $table.ColumnCount = 2
    $table.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 28))) | Out-Null
    $table.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 72))) | Out-Null
    $table.AutoScroll = $true
    $table.Padding = New-Object System.Windows.Forms.Padding(12, 8, 12, 8)
    $rowIdx = 0

    function Add-DetailRow {
        param([string]$Label, [string]$Value)
        $lbl = New-Object System.Windows.Forms.Label
        $lbl.Text = $Label
        $lbl.AutoSize = $true
        $lbl.Font = New-Object System.Drawing.Font($lbl.Font.FontFamily, 9, [System.Drawing.FontStyle]::Bold)
        $val = New-Object System.Windows.Forms.Label
        $val.Text = $Value
        $val.AutoSize = $true
        $val.MaximumSize = New-Object System.Drawing.Size(360, 0)
        $table.RowCount++
        $table.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::AutoSize)))
        $table.Controls.Add($lbl, 0, $rowIdx)
        $table.Controls.Add($val, 1, $rowIdx)
        $rowIdx++
    }

    $dur = ''
    if ($null -ne $rec.runningSince) { $dur = Format-Duration (([DateTime]::Now) - $rec.runningSince) }
    $started = if ($null -ne $rec.runningSince) { $rec.runningSince.ToString('HH:mm:ss') } else { '-' }
    $lastAct = if ($null -ne $rec.updatedAt) {
        try { ([DateTimeOffset]::FromUnixTimeMilliseconds([long]$rec.updatedAt)).LocalDateTime.ToString('HH:mm:ss') } catch { '-' }
    } else { '-' }
    $ctxPct = Format-CtxPercent $rec.ctxTokens $rec.ctxWindow

    Add-DetailRow '标题' ([string]$rec.title)
    Add-DetailRow '会话 ID' ([string]$rec.sid)
    Add-DetailRow '类型' $(if ($rec.isSub) { '子任务' } else { '主任务' })
    Add-DetailRow '状态' $(if ($rec.lastRunning) { '运行中' } else { '空闲' })
    $att = $null
    if ($script:AttentionSessions.ContainsKey($SessionId)) { $att = $script:AttentionSessions[$SessionId] }
    if ($null -ne $att) {
        Add-DetailRow '待处理' $(if ($att.kind -eq 'approval') { '⚠ 等待批准' } else { '⚠ 等待回答' })
        Add-DetailRow '待处理内容' ($att.text -replace "`n", ' / ')
    }
    Add-DetailRow '工作目录' ([string]$rec.cwd)
    Add-DetailRow '开始时间' $started
    Add-DetailRow '已运行' $dur
    Add-DetailRow '最后活动' $lastAct
    Add-DetailRow '────────── 进度 ──────────' ''
    Add-DetailRow '回合' ((Get-DisplayTurns $rec).ToString())
    Add-DetailRow '步骤' ([string]$rec.liveSteps)
    Add-DetailRow '输出 tokens' (Format-Tokens $rec.liveTokens)
    Add-DetailRow '生成速度' $(([int][Math]::Round($rec.tokPerSec)).ToString() + ' t/s')
    Add-DetailRow 'LLM 耗时' $(([int]($rec.llmMs / 1000)).ToString() + ' 秒')
    Add-DetailRow '工具耗时' $(([int]($rec.toolMs / 1000)).ToString() + ' 秒')
    Add-DetailRow '────────── 上下文 ──────────' ''
    Add-DetailRow '压力 tokens' ([string]$rec.ctxTokens)
    Add-DetailRow '窗口大小' ([string]$rec.ctxWindow)
    Add-DetailRow '占用率' $ctxPct
    Add-DetailRow '未缓存输入' (Format-Tokens $rec.inTokens)
    Add-DetailRow '缓存读取' (Format-Tokens $rec.cacheRead)
    Add-DetailRow '────────── 其他 ──────────' ''
    Add-DetailRow '规划模式' $(if ($rec.planActive) { '是' } else { '否' })
    Add-DetailRow '目标 (goal)' $(if ($rec.goal) { [string]$rec.goal } else { '无' })
    Add-DetailRow '待办 (todos)' ([string]$rec.todoCount)

    $form.Controls.Add($table)
    $form.ShowDialog() | Out-Null
}

# ── status.json（每次轮询落盘，调试/二次开发用）────────────────────────────────
function Update-StatusFile {
    try {
        $busyList = @($script:BusySessions | ForEach-Object {
            @{
                sessionId    = $_.sid
                title        = $_.title
                kind         = if ($_.isSub) { 'sub' } else { 'main' }
                turns        = $_.liveTurns
                steps        = $_.liveSteps
                tokens       = $_.liveTokens
                tokPerSec    = [Math]::Round($_.tokPerSec, 1)
                ctxTokens    = $_.ctxTokens
                ctxWindow    = $_.ctxWindow
                ctxPercent   = (Format-CtxPercent $_.ctxTokens $_.ctxWindow)
                llmSec       = [Math]::Round($_.llmMs / 1000.0, 1)
                toolSec      = [Math]::Round($_.toolMs / 1000.0, 1)
                planActive   = $_.planActive
                goal         = $_.goal
                todoCount    = $_.todoCount
                cwd          = $_.cwd
                llmRetry     = $_.llmRetry
                updatedAt    = $_.updatedAt
                runningSince = if ($null -ne $_.runningSince) { $_.runningSince.ToString('o') } else { $null }
            }
        })
        $finishList = @($script:RecentFinishes | ForEach-Object {
            @{
                title = $_.title; summary = $_.summary; at = $_.at.ToString('o'); isSub = $_.isSub
                sid = [string]$_.sid
                user = [string]$_.user; steps = [string]$_.steps; turns = [string]$_.turns
                tps = [string]$_.tps; dur = [string]$_.dur; tokens = [string]$_.tokens
                outcomeKind = [string]$_.outcomeKind; outcomeMsg = [string]$_.outcomeMsg
            }
        })
        $attList = @($script:AttentionSessions.Keys | ForEach-Object {
            $a = $script:AttentionSessions[$_]
            @{ sessionId = $_; kind = $a.kind; text = $a.text; at = $a.at.ToString('o') }
        })
        $payload = @{
            updatedAt      = (Get-Date).ToString('o')
            connected      = [bool]$script:LastPollOk
            paused         = [bool]$script:Paused
            busyCount      = @($script:BusySessions).Count
            busy           = $busyList
            attentionCount = $script:AttentionSessions.Count
            attention      = $attList
            recentFinishes = $finishList
        } | ConvertTo-Json -Depth 6
        Set-Content -Path $script:StatusFile -Value $payload -Encoding UTF8
    } catch { }
}

# ── 单实例 ────────────────────────────────────────────────────────────────────
function Acquire-SingleInstance {
    try {
        $script:Mutex = New-Object System.Threading.Mutex($false, 'DshTaskWatcher.SingleInstance')
        if (-not $script:Mutex.WaitOne(0)) {
            Write-Host 'DSH 任务监视器已在运行。'
            return $false
        }
    } catch {
        Write-Host ('单实例锁失败: ' + $_.Exception.Message)
        return $false
    }
    return $true
}

function Exit-App {
    Write-Log '正在退出…'
    Stop-SseListener
    Stop-Fetcher
    try { if ($null -ne $script:Timer) { $script:Timer.Stop() } } catch { }
    try { if ($null -ne $script:ClickFilter) { $script:ClickFilter.Dispose() } } catch { }
    try {
        if ($null -ne $script:Tray) {
            $script:Tray.Visible = $false
            $script:Tray.Dispose()
        }
    } catch { }
    try { if ($null -ne $script:PinImgGray) { $script:PinImgGray.Dispose() } } catch { }
    try { if ($null -ne $script:PinImgBlue) { $script:PinImgBlue.Dispose() } } catch { }
    try { if ($null -ne $script:Http) { $script:Http.Dispose() } } catch { }
    try { if ($null -ne $script:Mutex) { $script:Mutex.ReleaseMutex() } } catch { }
    try { [System.Windows.Forms.Application]::Exit() } catch { }
    # 兜底强退：后台线程（抓取/WS 监听）随进程一并终止——右键「退出」必达，
    # 杜绝「点了退出没反应、像卡死」
    [System.Environment]::Exit(0)
}

# ── 主入口 ────────────────────────────────────────────────────────────────────
function Main {
    Read-Config
    foreach ($d in @($script:DataDir, $script:LogDir, $script:IconDir)) {
        if (-not (Test-Path $d)) { New-Item -ItemType Directory -Force -Path $d | Out-Null }
    }
    # 内存回收 P/Invoke + 进程句柄（深窗抓取后 EmptyWorkingSet 归还工作集）。
    # 必须 try/catch：$ErrorActionPreference=Stop 下任何启动期编译失败都会无声杀死整个应用
    if (-not ('DshTaskWatcher.Mem' -as [type])) {
        try {
            Add-Type -TypeDefinition 'using System; using System.Runtime.InteropServices; namespace DshTaskWatcher { public class Mem { [DllImport("psapi.dll")] public static extern bool EmptyWorkingSet(IntPtr hProcess); } }'
        } catch { }
    }
    try { $script:ProcHandle = [System.Diagnostics.Process]::GetCurrentProcess().Handle } catch { $script:ProcHandle = $null }
    $script:Http = New-Object System.Net.Http.HttpClient
    $script:Http.Timeout = [TimeSpan]::FromSeconds(8)
    Ensure-Icons
    New-Tray
    Set-TrayIcon 'gray'
    if ($Demo) {
        Start-Demo
        [System.Windows.Forms.Application]::Run()
        return
    }
    $script:Timer = New-Object System.Windows.Forms.Timer
    $script:Timer.Interval = [Math]::Max(1, [int]$script:Cfg.pollSeconds) * 1000
    $script:Timer.Add_Tick({ Update-Status })
    $script:Timer.Start()
    # 审批/提问事件流监听（后台 WS 线程）
    Start-SseListener
    Start-Fetcher
    Update-Status
    if (-not $NoWelcome -and $script:LastPollOk) {
        Show-Balloon 'DSH 任务监视器已启动' ('正在监控 DSH 任务状态（轮询 ' + $script:Cfg.pollSeconds + ' 秒）') 'Info'
    }
    Write-Log ('启动完成 v' + $script:Version + ' | 监控窗类型: ' + $(if ($null -ne $script:MonitorFormType) { 'OK' } else { 'null' }))
    [System.Windows.Forms.Application]::Run()
}

# ── 演示模式（-Demo：假数据驱动真实界面，供截图/展示；不连接 DSH）──────────────
function Start-Demo {
    $script:DemoMode = $true
    $script:LastPollOk = $true
    $script:KnownSessions = @{}
    $script:BusySessions = @()
    $script:AttentionSessions = @{}
    $script:LastFinished = $null
    $script:RecentFinishes = New-Object System.Collections.ArrayList
    $now = Get-Date

    # 运行中主任务（含速度/上下文等细粒度字段，驱动监控窗/状态窗口/详情窗）
    $a = @{
        sid = 'demo-a'; title = '示例任务：整理产品需求文档'; isSub = $false; lastRunning = $true
        runningSince = $now.AddMinutes(-21); startTurns = 0; startSteps = 0; startTokens = 0
        liveTurns = 2; liveSteps = 162; liveTokens = 146000; cwd = '.\work'
        liveTurnStart = 3
        tokPerSec = 147.0; ctxTokens = 52000; ctxWindow = 1000000
        llmMs = 480000; toolMs = 410000; inTokens = 31000; cacheRead = 21000
        planActive = $false; goal = ''; todoCount = 0; updatedAt = $null; seenBefore = $true
        userPreview = '把会议纪要和需求清单整理成最终版本文档，输出为 Markdown 格式'
    }
    # 等待批准的会话（红色：审批中）
    $b = @{
        sid = 'demo-b'; title = '示例任务：检查后端配置'; isSub = $true; lastRunning = $true
        runningSince = $now.AddMinutes(-3); startTurns = 0; startSteps = 0; startTokens = 0
        liveTurns = 0; liveSteps = 33; liveTokens = 12000; cwd = '.\work'
        liveTurnStart = 1
        tokPerSec = 21.0; ctxTokens = 8000; ctxWindow = 1000000
        llmMs = 45000; toolMs = 30000; inTokens = 6000; cacheRead = 3000
        planActive = $false; goal = ''; todoCount = 0; updatedAt = $null; seenBefore = $true
        userPreview = '检查一下配置文件是否正确，并确认端口监听状态'
    }
    # 运行中子任务（黄色）
    $c = @{
        sid = 'demo-c'; title = '示例任务：编写发布说明'; isSub = $true; lastRunning = $true
        runningSince = $now.AddMinutes(-1); startTurns = 0; startSteps = 0; startTokens = 0
        liveTurns = 1; liveSteps = 12; liveTokens = 4000; cwd = '.\work'
        liveTurnStart = 2
        tokPerSec = 45.0; ctxTokens = 3000; ctxWindow = 1000000
        llmMs = 20000; toolMs = 15000; inTokens = 2500; cacheRead = 1500
        planActive = $false; goal = ''; todoCount = 0; updatedAt = $null; seenBefore = $true
        userPreview = '根据变更记录生成一段简洁的发布说明'
        llmRetry = 2
    }
    $script:BusySessions = @($a, $b, $c)
    foreach ($s in $script:BusySessions) { $script:KnownSessions[$s.sid] = $s }
    $script:AttentionSessions['demo-b'] = @{
        kind = 'approval'; approvalId = 'demo-approval-1'; questionRpcId = ''
        text = '请求批准工具调用: 执行远程命令'; at = $now
    }
    # 最近完成记录（状态窗口下方列表/监控窗空闲态；含结构化字段驱动监控窗各列）
    [void]$script:RecentFinishes.Add(@{
        title = '示例任务：修复登录超时问题'; summary = '9分12秒 · 回合 2 · 步骤 58 · 输出 67k tokens'
        at = $now.AddMinutes(-9); isSub = $false
        user = '修复登录接口在令牌过期后 30 秒超时的问题，并补充回归测试'
        steps = '58'; turns = '5'; tps = ''; dur = '9:12'; tokens = '67k'
    })
    [void]$script:RecentFinishes.Add(@{
        title = '示例任务：生成周报初稿'; summary = '6分3秒 · 回合 2 · 步骤 41 · 输出 28k tokens'
        at = $now.AddMinutes(-14); isSub = $false
        user = '根据本周的提交记录和任务看板，生成一份周报初稿'
        steps = '41'; turns = '3'; tps = ''; dur = '6:03'; tokens = '28k'
        outcomeKind = 'completed'; outcomeMsg = ''
    })
    # 失败示例（LLM 错误）：状态列红色「已失败」，用户消息列显示错误消息
    [void]$script:RecentFinishes.Add(@{
        title = '示例任务：数据迁移脚本'; summary = '2分48秒 · 回合 1 · 步骤 9 · 输出 5.1k tokens'
        at = $now.AddMinutes(-21); isSub = $false
        user = '把旧数据库的用户表迁移到新库，保留注册时间字段'
        steps = '9'; turns = '2'; tps = ''; dur = '2:48'; tokens = '5.1k'
        outcomeKind = 'error'; outcomeMsg = 'Provider rate limit exceeded: 429 (retry exhausted)'
    })
    $script:LastFinished = $script:RecentFinishes[0]

    # 真实状态逻辑：有待批准 → 托盘红色
    Update-TrayState
    # 固定模式：点击外部不隐藏（演示窗口稳定，便于截图）
    $script:MonitorFixed = $true
    # 固定演示位置（便于截屏脚本裁剪；互不重叠：监控窗左、状态窗中、菜单在监控窗下方）
    Show-MonitorWindow
    Start-Sleep -Milliseconds 300
    if ($null -ne $script:MonitorForm) {
        $script:MonitorForm.Location = New-Object System.Drawing.Point(60, 60)
        Write-Log ('demo: monitor location=' + $script:MonitorForm.Location.ToString())
    }
    Show-StatusWindow
    if ($null -ne $script:StatusForm) { $script:StatusForm.Location = New-Object System.Drawing.Point(900, 60) }
    try { Render-MonitorContent } catch { }
    try { Update-StatusWindow } catch { }
    # 演示用右键菜单（固定位置弹出）
    try {
        $script:Tray.ContextMenuStrip.Show((New-Object System.Drawing.Point(60, 400)))
        Write-Log 'demo: 菜单已弹出'
    } catch {
        Write-Log ('demo: 菜单弹出失败: ' + $_.Exception.Message)
    }
    # 3 秒后弹真实完成通知（供通知截图）
    $demoTimer = New-Object System.Windows.Forms.Timer
    $demoTimer.Interval = 3000
    $demoTimer.Add_Tick({
        param($s2, $e2)
        $s2.Stop()
        Show-Balloon -Title '任务完成' -Text ("示例任务：整理产品需求文档`n21分 · 回合 3 · 步骤 162 · 输出 143k tokens`n（剩余 1 个任务运行中）") -Kind 'Info'
    })
    $demoTimer.Start()
    Write-Log '演示模式已启动（假数据驱动真实界面，仅供截图/展示）'
}

# ── 自测（合成数据驱动状态机，不弹通知）────────────────────────────────────────
function New-FakeSession {
    param([string]$Id, [bool]$Running, [string]$Title, [int]$Turns, [int]$Steps, [long]$Tokens,
          [string]$Origin = '', [string]$Cwd = '', [double]$TokPerSec = 0,
          [long]$CtxTokens = 0, [long]$CtxWindow = 0)
    [pscustomobject]@{
        sessionId  = $Id
        running    = $Running
        origin     = $Origin
        cwd        = $Cwd
        updatedAt  = 1786856220380
        projections = [pscustomobject]@{
            values = [pscustomobject]@{
                title = $Title
                sessionStats = [pscustomobject]@{ turns = $Turns; steps = $Steps; decodeTokens = $Tokens; llmMs = 5000; toolMs = 2000; decodeMs = $(if ($TokPerSec -gt 0) { [long](($Tokens / $TokPerSec) * 1000) } else { 0 }) }
                contextPressure = [pscustomobject]@{ pressureTokens = $CtxTokens; projectedTokens = 0; contextWindow = $CtxWindow }
                plan = [pscustomobject]@{ active = $false; pending = $false }
                goal = $null
                todos = $null
            }
        }
    }
}

function Invoke-SelfTest {
    $script:TestMode = $true
    $script:TestToasts = New-Object System.Collections.ArrayList
    $script:Cfg = @{
        toastOnStart = $true; toastOnFinish = $true; playSoundOnFinish = $true
        toastForSubagents = $true; statusWindowOnTop = $true
    }
    $script:KnownSessions = @{}
    $script:BusySessions = @()
    $script:LastFinished = $null
    $script:RecentFinishes = New-Object System.Collections.ArrayList
    $script:LastPollOk = $true
    $failures = New-Object System.Collections.ArrayList

    function Assert-True {
        param([bool]$Cond, [string]$Msg)
        if (-not $Cond) { [void]$failures.Add($Msg) }
    }

    # 场景0：默认通知策略——任务开始不推送，完成/待处理才推送
    Assert-True ($script:DefaultConfig.toastOnStart -eq $false) '场景0: 默认 toastOnStart 应为 false'
    Assert-True ($script:DefaultConfig.toastOnFinish -eq $true) '场景0: 默认 toastOnFinish 应为 true'
    Assert-True ($script:DefaultConfig.notifyOnUserAction -eq $true) '场景0: 默认 notifyOnUserAction 应为 true'

    # 场景1：启动时 A 空闲 / B 已在运行（首次见到） / C 空闲（子任务）
    Process-Sessions -Items @(
        (New-FakeSession 'A' $false '任务A' 1 5 100 '' '.\work'),
        (New-FakeSession 'B' $true  '任务B' 2 8 300 '' '.\work'),
        (New-FakeSession 'C' $false '子任务C' 0 0 0 'subagent' '.\work')
    )
    Assert-True ($script:TestToasts.Count -eq 0) '场景1: 启动时不应弹任何通知'
    Assert-True (@($script:BusySessions).Count -eq 1) '场景1: 应有 1 个运行中会话（B）'

    # 场景2 使用的带速/上下文数据
    Process-Sessions -Items @(
        (New-FakeSession 'A' $true '任务A' 2 8 300 '' '.\work' 15.0 30000 1000000),
        (New-FakeSession 'B' $true '任务B' 3 12 800 '' '.\work' 12.5 40000 1000000),
        (New-FakeSession 'C' $true '子任务C' 1 3 50 'subagent' '.\work' 8.0 5000 1000000)
    )
    Assert-True ($script:TestToasts.Count -eq 2) '场景2: 应弹 2 个开始通知'
    Assert-True (@($script:TestToasts | Where-Object { $_.title -eq '任务开始' }).Count -eq 2) '场景2: 开始通知标题应为「任务开始」'
    Assert-True ($script:KnownSessions['A'].liveSteps -eq 8 -and $script:KnownSessions['A'].liveTurns -eq 2) '场景2: 细粒度字段 liveSteps/liveTurns 采集'
    Assert-True ($script:KnownSessions['B'].tokPerSec -eq 12.5) '场景2: tokPerSec 采集（12.5）'
    Assert-True ($script:KnownSessions['B'].ctxTokens -eq 40000 -and $script:KnownSessions['B'].ctxWindow -eq 1000000) '场景2: 上下文压力/窗口采集'

    # 场景3：A / B / C 全部完成 → 3 个完成通知（C 带子任务前缀）
    Process-Sessions -Items @(
        (New-FakeSession 'A' $false '任务A' 3 12 600 '' '.\work'),
        (New-FakeSession 'B' $false '任务B' 4 15 2300 '' '.\work'),
        (New-FakeSession 'C' $false '子任务C' 2 6 120 'subagent' '.\work')
    )
    Assert-True ($script:TestToasts.Count -eq 5) '场景3: 共应 5 个通知'
    Assert-True (@($script:BusySessions).Count -eq 0) '场景3: 应无运行中会话'
    Assert-True ($script:RecentFinishes.Count -eq 3) '场景3: 应有 3 条最近完成记录'
    $fRec = $script:RecentFinishes[0]
    Assert-True ($fRec.turns -eq '3' -and $fRec.steps -eq '12' -and $fRec.tokens -eq '600' -and $fRec.dur.Length -gt 0) '场景3: 完成记录累计总量口径（回合3 步骤12 输出600）'
    Assert-True ($fRec.dur -match '^\d+:\d{2}(:\d{2})?$') '场景3: 完成记录时长为冒号格式（m:ss / h:mm:ss）'
    Assert-True ($fRec.outcomeKind -eq 'completed') '场景3: 完成记录默认结局 completed（自测跳过抓取）'
    Assert-True ($script:KnownSessions['A'].llmRetry -eq 0) '场景3: 会话记录初始化 llmRetry=0'
    $finishA = @($script:TestToasts | Where-Object { $_.title -eq '任务完成' -and $_.text -like '任务A*' })[0]
    Assert-True ($null -ne $finishA) '场景3: 应有任务A完成通知'
    Assert-True ($finishA.text -like '*回合 1*' -and $finishA.text -like '*步骤 4*' -and $finishA.text -like '*输出 300 tokens*') '场景3: 任务A增量统计（回合1 步骤4 输出300）'
    $finishB = @($script:TestToasts | Where-Object { $_.title -eq '任务完成' -and $_.text -like '任务B*' })[0]
    Assert-True ($null -ne $finishB) '场景3: 应有任务B完成通知'
    Assert-True ($finishB.text -like '*2.3k tokens*') '场景3: 任务B 会话总量口径 2.3k'
    $finishC = @($script:TestToasts | Where-Object { $_.title -eq '任务完成（子任务）' -and $_.text -like '子任务C*' })[0]
    Assert-True ($null -ne $finishC) '场景3: 子任务C完成通知应带子任务前缀'

    # 场景4：全部空闲（无新通知）；新会话 D 出现后消失（清理不崩）
    Process-Sessions -Items @(
        (New-FakeSession 'A' $false '任务A' 3 12 600 '' '.\work'),
        (New-FakeSession 'D' $false '新会话D' 0 0 0 '' '.\other')
    )
    Assert-True ($script:TestToasts.Count -eq 5) '场景4: 空闲轮询不应再弹通知'
    Process-Sessions -Items @((New-FakeSession 'A' $false '任务A' 3 12 600 '' '.\work'))
    Assert-True (-not $script:KnownSessions.ContainsKey('D')) '场景4: 消失的会话应被清理'

    # 场景5：多任务并发——E 完成时 F 仍在运行 → 完成通知带「剩余任务数」
    Process-Sessions -Items @(
        (New-FakeSession 'E' $true '任务E' 1 2 100 '' '.\work'),
        (New-FakeSession 'F' $true '任务F' 1 1 50 '' '.\work')
    )
    Assert-True ($script:TestToasts.Count -eq 5) '场景5: 首次见到的运行中会话不应弹开始通知'
    Process-Sessions -Items @(
        (New-FakeSession 'E' $false '任务E' 2 5 200 '' '.\work'),
        (New-FakeSession 'F' $true '任务F' 2 3 120 '' '.\work')
    )
    $finishE = @($script:TestToasts | Where-Object { $_.title -eq '任务完成' -and $_.text -like '任务E*' })[0]
    Assert-True ($null -ne $finishE) '场景5: 应有任务E完成通知'
    Assert-True ($finishE.text -like '*剩余 1 个任务运行中*') '场景5: 完成通知应提示剩余 1 个任务运行中'
    Assert-True ($finishE.text -like '*200 tokens*') '场景5: E 完成输出=会话总量 200（基线归零）'
    Assert-True (@($script:BusySessions).Count -eq 1) '场景5: 应剩 1 个运行中会话（F）'
    Assert-True ($script:KnownSessions['F'].lastRunning -eq $true) '场景5: F 应保持运行状态'

    # 场景5b：会话重命名 → 完成记录标题跟随（用户重命名优先展示）
    Process-Sessions -Items @(
        (New-FakeSession 'E' $false '任务E（已重命名）' 2 5 200 '' '.\work'),
        (New-FakeSession 'F' $true '任务F' 2 3 120 '' '.\work')
    )
    $finE = @($script:RecentFinishes | Where-Object { $_.sid -eq 'E' })[0]
    Assert-True ($null -ne $finE -and $finE.title -eq '任务E（已重命名）') '场景5b: 完成记录标题跟随会话重命名'

    # 场景6：托盘精简悬浮摘要（Format-TraySummary：运行中 N · 待处理 M）
    $script:AttentionSessions = @{}
    $script:BusySessions = @(@{ title = '任务X'; isSub = $false }, @{ title = '任务Y'; isSub = $true })
    $tip1 = Format-TraySummary
    Assert-True ($tip1 -eq '运行中 2') '场景6: 仅运行中 → 运行中 2'
    $script:AttentionSessions = @{ 'SX' = @{ kind = 'approval'; text = 'x' } }
    $tip2 = Format-TraySummary
    Assert-True ($tip2 -like '⚠ 待处理 1 · 运行中 2') '场景6: 有待处理优先显示'
    $script:AttentionSessions = @{}
    $script:BusySessions = @()
    $tip3 = Format-TraySummary
    Assert-True ($tip3 -eq 'DSH 空闲') '场景6: 空闲 → DSH 空闲'
    $script:BusySessions = @(@{ title = '任务X'; isSub = $false })
    $script:AttentionSessions = @{ 'SX' = @{ kind = 'question'; text = 'q' } }
    $tip4 = Format-TraySummary
    Assert-True ($tip4 -eq '⚠ 待处理 1 · 运行中 1') '场景6: 待处理与运行中组合'

    # 场景7：本轮对话内容提取（Get-MessagePreview / Get-TextPreview）
    $fakeHistory = [pscustomobject]@{
        events = @(
            [pscustomobject]@{ event = [pscustomobject]@{ type = 'user/message'; data = [pscustomobject]@{ content = @([pscustomobject]@{ type = 'text'; text = '请帮我检查一下配置文件的内容是否正常，如果发现问题请直接修复' }) } } },
            [pscustomobject]@{ event = [pscustomobject]@{ type = 'assistant/message'; data = [pscustomobject]@{ message = [pscustomobject]@{ content = @([pscustomobject]@{ type = 'text'; text = '好的，我先读取配置文件……' }) } } } }
        )
    }
    $pv = Get-MessagePreview $fakeHistory
    Assert-True ($pv.user -like '请帮我检查*') '场景7: 提取最后用户消息开头'
    Assert-True ($pv.live -like '好的，我先读取*') '场景7: 提取进行中（助手正文）开头'
    # 场景8：只有工具调用增量 → 提示「正在调用工具…」；只有思考增量 → 「正在思考…」
    $fakeChunks = [pscustomobject]@{
        events = @(
            [pscustomobject]@{ event = [pscustomobject]@{ type = 'assistant/chunk'; data = [pscustomobject]@{ chunk = [pscustomobject]@{ type = 'tool-call-delta'; name = 'pwsh'; argumentsDelta = '{}' } } } },
            [pscustomobject]@{ event = [pscustomobject]@{ type = 'assistant/chunk'; data = [pscustomobject]@{ chunk = [pscustomobject]@{ type = 'reasoning-delta'; text = '让我想想…' } } } }
        )
    }
    $pv2 = Get-MessagePreview $fakeChunks
    Assert-True ($pv2.live -eq '（正在调用工具…）') '场景8: 工具增量时提示正在调用工具'
    $fakeReason = [pscustomobject]@{
        events = @(
            [pscustomobject]@{ event = [pscustomobject]@{ type = 'assistant/chunk'; data = [pscustomobject]@{ chunk = [pscustomobject]@{ type = 'reasoning-delta'; text = '让我想想…' } } } }
        )
    }
    $pv3 = Get-MessagePreview $fakeReason
    Assert-True ($pv3.live -eq '（正在思考…）') '场景8: 思考增量时提示正在思考'
    $longText = '这是一段非常长的文本，' * 10
    $tp = Get-TextPreview ([pscustomobject]@{ content = @([pscustomobject]@{ type = 'text'; text = $longText }) }) 40
    Assert-True ($tp.Length -le 41) '场景7: 文本截断生效'

    # 场景7b：从原始 history JSON 提取最后用户消息（Get-LastUserFromRaw，不做全量解析）
    $fakeRaw = '{"result":{"ok":true,"value":{"events":[{"event":{"type":"assistant/chunk","seq":3,"data":{"chunk":{"type":"text-delta","text":"好的"}}}},{"event":{"type":"user/message","seq":4,"data":{"content":[{"type":"text","text":"请帮我检查配置文件"}]}}},{"event":{"type":"assistant/chunk","seq":5,"data":{"chunk":{"type":"text-delta","text":"收到"}}}}]}}}'
    $ru = Get-LastUserFromRaw $fakeRaw
    Assert-True ($ru -eq '请帮我检查配置文件') '场景7b: 原始 JSON 提取最后用户消息'
    $escRaw = '"type":"user/message","seq":9,"data":{"content":[{"type":"text","text":"第一行\n第二行 \"引号\" 结尾"}]}}'
    $ru2 = Get-LastUserFromRaw $escRaw
    Assert-True ($ru2 -eq '第一行 第二行 "引号" 结尾') '场景7b: 转义字符还原（换行/引号）'
    Assert-True ((Get-LastUserFromRaw '{"value":{"events":[]}}') -eq '') '场景7b: 无用户消息返回空'
    Assert-True ((Get-LastUserFromRaw '') -eq '') '场景7b: 空文本返回空'
    $longRaw = '"type":"user/message","data":{"content":[{"type":"text","text":"' + ('字' * 80) + '"}]}}'
    $ru3 = Get-LastUserFromRaw $longRaw
    Assert-True ($ru3.Length -eq 61 -and $ru3.EndsWith('…')) '场景7b: 超长截断 60+省略号'
    # 优先 source.kind=user 的真实用户消息（跳过宿主生成的 user 形消息，如压缩替换件）
    $twoRaw = '{"type":"user/message","seq":5,"data":{"content":[{"type":"text","text":"宿主生成的消息"}]}},{"event":{"type":"user/message","seq":6,"data":{"content":[{"type":"text","text":"真正的用户消息"}],"source":{"kind":"user","rpcId":"x"}}}}'
    $ru4 = Get-LastUserFromRaw $twoRaw
    Assert-True ($ru4 -eq '真正的用户消息') '场景7b: 优先取 source.kind=user 的真实用户消息'
    $longKindRaw = '"type":"user/message","data":{"content":[{"type":"text","text":"' + ('长' * 600) + '"}],"source":{"kind":"user","rpcId":"y"}}'
    $ru5 = Get-LastUserFromRaw $longKindRaw
    Assert-True ($ru5.Length -eq 61 -and $ru5.StartsWith('长')) '场景7b: 超长真实用户消息截断（提取窗口容纳长文本）'
    # real 标志：区分 kind=user 真实消息与合成兜底（goal_round 续跑/压缩摘要）
    $exReal = Get-LastUserEx $longKindRaw
    Assert-True ($exReal.real -eq $true) '场景7b: kind=user 消息 real=true'
    $goalRoundRaw = '"type":"user/message","data":{"content":[{"type":"text","text":"<goal_round> Objective: 继续完成任务"}]}}'
    $exSyn = Get-LastUserEx $goalRoundRaw
    Assert-True ($exSyn.real -eq $false -and $exSyn.text -eq '<goal_round> Objective: 继续完成任务') '场景7b: 无 kind=user 的合成消息 real=false（文本兜底保留）'

    # 场景7c：冒号时长格式（Format-DurationClock，监控窗「时长」列专用）
    Assert-True ((Format-DurationClock ([TimeSpan]::FromSeconds(45))) -eq '0:45') '场景7c: 45秒 → 0:45'
    Assert-True ((Format-DurationClock ([TimeSpan]::FromMinutes(9).Add([TimeSpan]::FromSeconds(12)))) -eq '9:12') '场景7c: 9分12秒 → 9:12'
    Assert-True ((Format-DurationClock ([TimeSpan]::FromMinutes(21).Add([TimeSpan]::FromSeconds(35)))) -eq '21:35') '场景7c: 21分35秒 → 21:35'
    $h1 = [TimeSpan]::FromHours(1).Add([TimeSpan]::FromMinutes(5)).Add([TimeSpan]::FromSeconds(30))
    Assert-True ((Format-DurationClock $h1) -eq '1:05:30') '场景7c: 1小时5分30秒 → 1:05:30'
    Assert-True ((Format-DurationClock ([TimeSpan]::FromHours(10))) -eq '10:00:00') '场景7c: 10小时 → 10:00:00'

    # 场景7d：turn/end 结局提取（Get-LastTurnEndFromRaw + Get-TurnOutcomeInfo）
    $teCompleted = Get-LastTurnEndFromRaw '{"value":{"events":[{"event":{"type":"turn/end","seq":9,"time":1,"data":{"turn":3,"reason":{"kind":"completed"}}}}]}}'
    Assert-True ($null -ne $teCompleted -and $teCompleted.kind -eq 'completed') '场景7d: completed 结局提取'
    $teErr = Get-LastTurnEndFromRaw '"type":"turn/end","data":{"turn":5,"reason":{"kind":"error","error":{"message":"Provider timeout after 60000ms","code":"TIMEOUT"}}}},{"event":{"type":"tool/result","data":{"turn":6,"message":{"content":"noise"}}}}'
    Assert-True ($null -ne $teErr -and $teErr.kind -eq 'error' -and $teErr.message -eq 'Provider timeout after 60000ms') '场景7d: error 结局 + 错误消息（不误吞后续事件 message）'
    # 错误消息内含花括号（JSON 片段）——括号配平必须跳过字符串内部
    $teBrace = Get-LastTurnEndFromRaw '"type":"turn/end","data":{"reason":{"kind":"error","error":{"message":"bad payload {\"a\":1} in body","code":"BAD"}}}'
    Assert-True ($null -ne $teBrace -and $teBrace.message -eq 'bad payload {"a":1} in body') '场景7d: 错误消息含花括号仍正确配平'
    $teAb = Get-LastTurnEndFromRaw '"type":"turn/end","data":{"turn":2,"reason":{"kind":"aborted","reason":"user cancel"}}'
    Assert-True ($null -ne $teAb -and $teAb.kind -eq 'aborted') '场景7d: aborted 结局提取'
    Assert-True ($null -eq (Get-LastTurnEndFromRaw '{"value":{"events":[]}}')) '场景7d: 无 turn/end 返回 null'
    Assert-True ($null -eq (Get-LastTurnEndFromRaw '')) '场景7d: 空文本返回 null'
    $oiErr = Get-TurnOutcomeInfo 'error'
    Assert-True ($oiErr.label -eq '已失败' -and $oiErr.toast -eq '任务失败' -and $oiErr.tkind -eq 'Error') '场景7d: error 结局映射（红/失败/Error）'
    $oiDef = Get-TurnOutcomeInfo 'something-new'
    Assert-True ($oiDef.label -eq '已完成' -and $oiDef.tkind -eq 'Info') '场景7d: 未知结局回落已完成'
    Assert-True ((Get-TurnOutcomeInfo 'interrupted').toast -eq '会话中断') '场景7d: interrupted 映射会话中断'

    # 场景7e：运行中回合数口径（max(投影, 最后 turn/start 号)）
    $tsRaw = '{"events":[{"event":{"type":"turn/start","seq":10,"time":1,"data":{"turn":7}}},{"event":{"type":"step/start","seq":11,"time":1,"data":{"turn":7,"step":1}}}]}'
    Assert-True ((Get-LastTurnStartFromRaw $tsRaw) -eq 7) '场景7e: 提取最后 turn/start 回合号'
    Assert-True ((Get-LastTurnStartFromRaw '{"value":{"events":[]}}') -eq -1) '场景7e: 无 turn/start 返回 -1（窗口截断回落投影）'
    # 回合刚开始（投影 6 未含当前 7）→ 显示 7
    Assert-True ((Get-DisplayTurns @{ liveTurns = 6; liveTurnStart = 7 }) -eq 7) '场景7e: 回合刚开始显示 turn/start 号'
    # 首个 step 已完成（投影 7 已含）→ 显示 7 不重复计
    Assert-True ((Get-DisplayTurns @{ liveTurns = 7; liveTurnStart = 7 }) -eq 7) '场景7e: step 已完成投影已含不重复计'
    # 窗口截断（liveTurnStart 不可见）→ 回落投影
    Assert-True ((Get-DisplayTurns @{ liveTurns = 9; liveTurnStart = -1 }) -eq 9) '场景7e: 窗口截断回落投影值'
    Assert-True ((Get-DisplayTurns @{ liveTurns = 4 }) -eq 4) '场景7e: 无 liveTurnStart 字段回落投影值'

    # 场景9：待介入事件流处理（Handle-AttentionFrame）
    $script:AttentionSessions = @{}
    $script:KnownApprovals = @{}
    $script:KnownQuestions = @{}
    $script:AttQueue = [System.Collections.Concurrent.ConcurrentQueue[object]]::new()
    # approval/requested
    Handle-AttentionFrame ([pscustomobject]@{
        type = 'server-request'; rpcId = 'rpc-1'
        payload = [pscustomobject]@{ type = 'approval/requested'; sessionId = 'S1'; approvalId = 'A1'; toolName = 'pwsh'; reason = '需要执行命令' }
    })
    Assert-True ($script:AttentionSessions.ContainsKey('S1')) '场景9: approval/requested 记录待处理'
    Assert-True ($script:AttentionSessions['S1'].kind -eq 'approval') '场景9: 待处理类型为 approval'
    Assert-True ($script:AttQueue.Count -eq 1) '场景9: 入队 1 条通知'
    # 同 approvalId 重放 → 不重复通知
    Handle-AttentionFrame ([pscustomobject]@{
        type = 'server-request'; rpcId = 'rpc-1'
        payload = [pscustomobject]@{ type = 'approval/requested'; sessionId = 'S1'; approvalId = 'A1'; toolName = 'pwsh' }
    })
    Assert-True ($script:AttQueue.Count -eq 1) '场景9: 重放帧去重（不重复入队）'
    # approval/resolved → 清除
    Handle-AttentionFrame ([pscustomobject]@{
        type = 'server-request'; rpcId = 'rpc-2'
        payload = [pscustomobject]@{ type = 'approval/resolved'; sessionId = 'S1'; approvalId = 'A1'; outcome = 'allowed-once' }
    })
    Assert-True (-not $script:AttentionSessions.ContainsKey('S1')) '场景9: approval/resolved 清除待处理'
    # question/requested（rpcId 在信封）
    Handle-AttentionFrame ([pscustomobject]@{
        type = 'server-request'; rpcId = 'q-rpc-1'
        payload = [pscustomobject]@{ type = 'question/requested'; sessionId = 'S2'; questions = @([pscustomobject]@{ id = 'q1'; question = '是否允许我继续执行？'; options = @('是', '否') }) }
    })
    Assert-True ($script:AttentionSessions.ContainsKey('S2') -and $script:AttentionSessions['S2'].kind -eq 'question') '场景9: question/requested 记录待处理'
    Assert-True ($script:AttentionSessions['S2'].text -like '*是否允许我继续执行？*') '场景9: 提问内容写入待处理文本'
    Assert-True ($script:AttQueue.Count -eq 2) '场景9: 提问入队 1 条'
    # 同 questionRpcId 重放 → 去重
    Handle-AttentionFrame ([pscustomobject]@{
        type = 'server-request'; rpcId = 'q-rpc-1'
        payload = [pscustomobject]@{ type = 'question/requested'; sessionId = 'S2'; questions = @([pscustomobject]@{ id = 'q1'; question = '是否允许我继续执行？' }) }
    })
    Assert-True ($script:AttQueue.Count -eq 2) '场景9: 提问重放去重'
    # question/resolved → 清除
    Handle-AttentionFrame ([pscustomobject]@{
        type = 'server-request'; rpcId = 'rpc-3'
        payload = [pscustomobject]@{ type = 'question/resolved'; sessionId = 'S2'; questionRpcId = 'q-rpc-1'; outcome = 'answered' }
    })
    Assert-True (-not $script:AttentionSessions.ContainsKey('S2')) '场景9: question/resolved 清除待处理'

    # 场景10：图标状态优先级（Get-TrayIconName）
    $script:LastPollOk = $false
    Assert-True ((Get-TrayIconName) -eq 'gray') '场景10: 未连接 → 灰'
    $script:LastPollOk = $true
    $script:Paused = $true
    Assert-True ((Get-TrayIconName) -eq 'gray') '场景10: 暂停 → 灰'
    $script:Paused = $false
    $script:AttentionSessions = @{ 'SX' = @{ kind = 'approval'; text = 'x' } }
    $script:BusySessions = @(@{ title = 'B'; isSub = $false })
    Assert-True ((Get-TrayIconName) -eq 'red') '场景10: 有待处理 → 红（优先于运行中）'
    $script:AttentionSessions = @{}
    Assert-True ((Get-TrayIconName) -eq 'amber') '场景10: 仅运行中 → 橙'
    $script:BusySessions = @()
    Assert-True ((Get-TrayIconName) -eq 'green') '场景10: 空闲 → 绿'

    # 输出
    Write-Host '── DshTaskWatcher SelfTest ──'
    foreach ($t in $script:TestToasts) {
        Write-Host ('  TOAST: ' + $t.title + ' | ' + ($t.text -replace "`n", ' / '))
    }
    if ($failures.Count -eq 0) {
        Write-Host 'PASS: 全部断言通过'
        return 0
    }
    Write-Host ('FAIL: ' + $failures.Count + ' 项未通过:')
    foreach ($f in $failures) { Write-Host ('  - ' + $f) }
    return 1
}

# ── 分发 ──────────────────────────────────────────────────────────────────────
if ($SelfTest) {
    exit (Invoke-SelfTest)
}
if (-not $Demo -and -not (Acquire-SingleInstance)) { exit 0 }
Main