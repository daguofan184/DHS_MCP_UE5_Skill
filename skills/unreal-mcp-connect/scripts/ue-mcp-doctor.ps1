# ue-mcp-doctor.ps1 — 只读体检：Unreal 工程能否用内置 "Unreal MCP"（ModelContextProtocol）
# 用法:
#   pwsh -NoProfile -File ue-mcp-doctor.ps1 -ProjectPath "E:\Proj\Proj.uproject" -Port 8000
# 不带 -ProjectPath 时从当前目录向上找 *.uproject。本脚本不做任何写操作。

[CmdletBinding()]
param(
    [string]$ProjectPath = '',
    [int]$Port = 8000,
    [int]$LogTailLines = 12
)

$ErrorActionPreference = 'SilentlyContinue'
$results = @()

function Ok($m)   { Write-Host ("  [OK]   " + $m) -ForegroundColor Green }
function Warn($m) { Write-Host ("  [WARN] " + $m) -ForegroundColor Yellow }
function Bad($m)  { Write-Host ("  [FAIL] " + $m) -ForegroundColor Red }
function Info($m) { Write-Host ("  [info] " + $m) -ForegroundColor DarkGray }
function Add-Result($level, $text) { $script:results += [pscustomobject]@{ Level = $level; Text = $text } }

Write-Host ""
Write-Host "=== Unreal MCP 体检 ===" -ForegroundColor Cyan

# ---------------------------------------------------------------- 1. 定位工程
if ([string]::IsNullOrWhiteSpace($ProjectPath)) {
    $dir = (Get-Location).Path
    $found = $null
    for ($i = 0; $i -lt 6 -and $dir; $i++) {
        $hit = Get-ChildItem -Path $dir -Filter *.uproject -File -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($hit) { $found = $hit.FullName; break }
        $parent = Split-Path -Parent $dir
        if ($parent -eq $dir) { break }
        $dir = $parent
    }
    $ProjectPath = $found
}

if (-not $ProjectPath -or -not (Test-Path $ProjectPath)) {
    Bad "找不到 .uproject，请用 -ProjectPath 指定"
    Add-Result 'FAIL' 'project'
    Write-Host ""
    Write-Host "下一步: 重新运行时加 -ProjectPath <工程>.uproject" -ForegroundColor Yellow
    exit 1
}
$ProjectPath = (Resolve-Path $ProjectPath).Path
$projectDir  = Split-Path -Parent $ProjectPath
Ok ("工程: " + $ProjectPath)

$proj = Get-Content $ProjectPath -Raw | ConvertFrom-Json
$engineAssoc = $proj.EngineAssociation
Info ("EngineAssociation: " + $engineAssoc)

# ---------------------------------------------------------------- 2. 插件是否启用
$mcpPlugin = $null
foreach ($p in @($proj.Plugins)) {
    if ($p -and $p.Name -eq 'ModelContextProtocol') { $mcpPlugin = $p; break }
}
if ($mcpPlugin -and ($mcpPlugin.Enabled -ne $false)) {
    Ok "插件 ModelContextProtocol 已在 .uproject 中启用"
} else {
    Bad "插件 ModelContextProtocol 未在 .uproject 的 Plugins 中启用"
    Add-Result 'FAIL' 'plugin'
}

# ---------------------------------------------------------------- 3. 引擎与插件文件
$engineRoot = $null
$regRoot = "HKLM:\SOFTWARE\EpicGames\Unreal Engine\$engineAssoc"
$regHit = (Get-ItemProperty -Path $regRoot -Name InstalledDirectory -ErrorAction SilentlyContinue).InstalledDirectory
if ($regHit -and (Test-Path $regHit)) {
    $engineRoot = $regHit
} else {
    $guess = Join-Path $env:ProgramFiles ("Epic Games\UE_" + $engineAssoc)
    if (Test-Path $guess) { $engineRoot = $guess }
}

if ($engineRoot) {
    Ok ("引擎: " + $engineRoot)
    $uplugin = Join-Path $engineRoot 'Engine\Plugins\Experimental\ModelContextProtocol\ModelContextProtocol.uplugin'
    if (Test-Path $uplugin) {
        $ver = '?'
        $verFile = Join-Path $engineRoot 'Engine\Build\Build.version'
        if (Test-Path $verFile) {
            $bj = Get-Content $verFile -Raw | ConvertFrom-Json
            $ver = "$($bj.MajorVersion).$($bj.MinorVersion).$($bj.PatchVersion)"
        }
        Ok ("内置插件存在，引擎版本 " + $ver)
        if ($uplugin -and -not ($engineRoot -match '5\.([89]|1[0-9])')) {
            Warn "ModelContextProtocol 插件自 UE 5.8 起内置；更早版本需要自己装 MCP 插件"
        }
    } else {
        Bad "引擎里找不到 ModelContextProtocol.uplugin（UE 5.8 之前无此插件）"
        Add-Result 'FAIL' 'engine-plugin'
    }
} else {
    Warn "未定位到引擎安装目录（注册表与默认路径都没命中），跳过插件文件检查"
}

# ---------------------------------------------------------------- 4. 编辑器进程
$procs = @(Get-Process -Name UnrealEditor, UnrealEditor-Cmd -ErrorAction SilentlyContinue)
$editorPid = $null
$editorStart = $null
$projName = [System.IO.Path]::GetFileNameWithoutExtension($ProjectPath)

if ($procs.Count -eq 0) {
    Bad "没有运行中的 UnrealEditor 进程 —— MCP 服务端寄生在编辑器里，编辑器必须开着"
    Add-Result 'FAIL' 'editor'
} else {
    $pick = $procs | Where-Object { $_.MainWindowTitle -and $_.MainWindowTitle -like ("*" + $projName + "*") } | Select-Object -First 1
    if (-not $pick) { $pick = $procs | Sort-Object StartTime -Descending | Select-Object -First 1 }
    $editorPid = $pick.Id
    $editorStart = $pick.StartTime
    Ok ("编辑器进程 PID " + $editorPid + "，启动于 " + $editorStart.ToString('HH:mm:ss'))
    if ($procs.Count -gt 1) { Info ("共 " + $procs.Count + " 个 UnrealEditor 进程，取最新一个") }
}

# ---------------------------------------------------------------- 5. 端口监听
# 注意：某些受限环境里 Get-NetTCPConnection 查不到监听项，故以 netstat 为主、cmdlet 兜底
$portOwner = $null
$portAddr = $null
$nl = @(netstat -ano 2>$null | Where-Object { $_ -match (':' + $Port + '\s') -and $_ -match 'LISTENING' })
if ($nl.Count -gt 0) {
    $parts = @(($nl[0] -replace '\s+', ' ').Trim() -split ' ')
    $portAddr = $parts[1]
    $portOwner = [int]$parts[$parts.Count - 1]
} else {
    $conn = Get-NetTCPConnection -State Listen -LocalPort $Port -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($conn) { $portAddr = [string]$conn.LocalAddress; $portOwner = $conn.OwningProcess }
}

if ($portOwner) {
    $ownerName = (Get-Process -Id $portOwner -ErrorAction SilentlyContinue).ProcessName
    if ($editorPid -and $portOwner -eq $editorPid) {
        Ok ("端口 " + $Port + " 已监听: " + $portAddr + " (PID " + $portOwner + ")")
    } else {
        Bad ("端口 " + $Port + " 被 PID " + $portOwner + " (" + $ownerName + ") 占用，不是当前编辑器")
        Info "换端口: 设置里改 ServerPortNumber，或启动参数 -ModelContextProtocolPort=8123"
        Add-Result 'FAIL' 'port'
    }
} else {
    Bad ("端口 " + $Port + " 没有监听 —— MCP 服务端未启动")
    Add-Result 'FAIL' 'listening'
}

# ---------------------------------------------------------------- 6. 设置文件与 ini 时序
$ini = Join-Path $projectDir 'Saved\Config\WindowsEditor\EditorPerProjectUserSettings.ini'
if (Test-Path $ini) {
    $iniTime = (Get-Item $ini).LastWriteTime
    $keys = @{}
    $inSection = $false
    foreach ($line in Get-Content $ini) {
        $t = $line.Trim()
        # 节头形如 [/Script/ModelContextProtocolEngine.ModelContextProtocolSettings]，按后缀匹配
        if ($t -match '^\[(.+)\]$') { $inSection = ($Matches[1] -match 'ModelContextProtocolSettings$'); continue }
        if ($inSection -and $t -match '^([^=]+)=(.*)$') { $keys[$Matches[1].Trim()] = $Matches[2].Trim() }
    }
    if ($keys.Count -gt 0) {
        Info ("ini 节 [ModelContextProtocolSettings]: " + (($keys.GetEnumerator() | ForEach-Object { $_.Key + '=' + $_.Value }) -join '  '))
        $autoStart = ($keys['bAutoStartServer'] -eq 'True')
        if (-not $autoStart) {
            Warn "bAutoStartServer=False: 每次启动都要手动 ModelContextProtocol.StartServer"
        } else {
            Ok "bAutoStartServer=True（重启编辑器后应自动监听）"
        }
        if ($keys['ServerPortNumber'] -and [int]$keys['ServerPortNumber'] -ne $Port) {
            Warn ("配置端口是 " + $keys['ServerPortNumber'] + "，但本次体检按 " + $Port + " 检查")
        }
        if ($editorStart -and $iniTime -gt $editorStart.AddSeconds(5)) {
            if ($portOwner) {
                Info ("ini 写入时间 " + $iniTime.ToString('HH:mm:ss') + " 晚于编辑器启动 " + $editorStart.ToString('HH:mm:ss') +
                      "（UE 运行期也会回写 ini，端口已在监听，无需关注）")
            } else {
                Warn ("ini 写入时间 " + $iniTime.ToString('HH:mm:ss') + " 晚于编辑器启动 " + $editorStart.ToString('HH:mm:ss') +
                      " —— 自动启动只在 PostEngineInit 读一次，本次启动不会生效，需重启编辑器或手动 StartServer")
            }
        }
    } else {
        Warn "ini 中没有 [ModelContextProtocolSettings] 节（说明还没在工程设置里改过，走默认值：8000 / /mcp / 不自动启动）"
    }
} else {
    Warn "找不到 " + $ini
}

# ---------------------------------------------------------------- 7. 日志证据
$logDir = Join-Path $projectDir 'Saved\Logs'
$newest = Get-ChildItem -Path $logDir -Filter *.log -File -ErrorAction SilentlyContinue |
          Where-Object { $_.Name -notlike '*backup*' } | Sort-Object LastWriteTime -Descending | Select-Object -First 1
if ($newest) {
    # 全文搜索关键事件，"最近 N 行"只用于展示
    $allMcp = @(Select-String -Path $newest.FullName -Pattern 'LogModelContextProtocol' -ErrorAction SilentlyContinue)
    $started = @($allMcp | Where-Object { $_.Line -match 'Starting MCP server on port' })
    $lines = @($allMcp | Select-Object -Last $LogTailLines | ForEach-Object { $_.Line })
    if ($allMcp.Count -eq 0) {
        Bad ("日志里没有任何 LogModelContextProtocol 记录 —— 插件可能没加载（检查 .uproject 的 Plugins）")
        Add-Result 'FAIL' 'plugin-loaded'
    } else {
        if ($started.Count -gt 0) {
            Ok ("日志中有 " + $started.Count + " 次 'Starting MCP server on port' 记录（最近一次: " + $started[-1].Line + "）")
        } else {
            Bad "插件已加载但全文没有 'Starting MCP server on port' —— 服务端从未启动"
            Add-Result 'FAIL' 'never-started'
        }
        $sessions = @($allMcp | Where-Object { $_.Line -match "Client requested protocol version" })
        if ($sessions.Count -gt 0) {
            Info ("已发生过 " + $sessions.Count + " 次客户端握手: " + (($sessions | ForEach-Object { ($_.Line -split "'")[1] }) -join ', ') + "（2025-11-25 通常是 DSH 客户端）")
        }
        Write-Host "  --- 最近日志（注意：日志时间戳为 UTC） ---" -ForegroundColor DarkGray
        foreach ($l in $lines) { Write-Host ("    " + $l) -ForegroundColor DarkGray }
    }
} else {
    Warn ("找不到日志文件: " + $logDir)
}

# ---------------------------------------------------------------- 8. 结论
Write-Host ""
Write-Host "=== 结论 ===" -ForegroundColor Cyan

$failKinds = @($results | Where-Object { $_.Level -eq 'FAIL' } | ForEach-Object { $_.Text })
if ($failKinds.Count -eq 0) {
    Write-Host "  全绿。下一步做协议层验证（本机示例，pwsh 不存在时用 powershell.exe）:" -ForegroundColor Green
    Write-Host ('    powershell.exe -NoProfile -ExecutionPolicy Bypass -File "<本技能目录>\scripts\ue-mcp-probe.ps1" -Url "http://127.0.0.1:' + $Port + '/mcp"') -ForegroundColor Green
} else {
    if ($failKinds -contains 'plugin' -or $failKinds -contains 'engine-plugin') {
        Write-Host "  1) 启用插件：编辑器 编辑->插件 搜 'MCP' 勾选 'Unreal MCP'（实验性提示选'是'），重启编辑器。" -ForegroundColor Yellow
    }
    if ($failKinds -contains 'editor') {
        Write-Host "  2) 打开该工程的编辑器（MCP 服务端运行在编辑器进程内）：" -ForegroundColor Yellow
        Write-Host ('     "' + $ProjectPath + '"') -ForegroundColor Yellow
    }
    if ($failKinds -contains 'never-started' -or $failKinds -contains 'listening') {
        Write-Host "  3) 启动服务端（编辑器里）：控制台输入 ModelContextProtocol.StartServer" -ForegroundColor Yellow
        Write-Host "     或重启编辑器（需 bAutoStartServer=True），或命令行加 -ModelContextProtocolStartServer" -ForegroundColor Yellow
    }
    if ($failKinds -contains 'port') {
        Write-Host "  4) 端口冲突：换端口（设置 ServerPortNumber 或 -ModelContextProtocolPort=N）后同步改 MCP 客户端的 url" -ForegroundColor Yellow
    }
    Write-Host ("     补一句：日志里出现 'Starting MCP server' 之后，socket 通常还要 1~2 秒才 LISTENING。") -ForegroundColor DarkGray
}
Write-Host ""
