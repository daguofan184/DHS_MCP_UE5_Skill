# ue-mcp-probe.ps1 — 对 Unreal 内置 MCP 服务端做协议层往返验证
# 只读：仅做 initialize / notifications/initialized / tools/list，可选一次 tools/call。
#
# 用法:
#   pwsh -NoProfile -File ue-mcp-probe.ps1 -Url "http://127.0.0.1:8000/mcp"
#   pwsh -NoProfile -File ue-mcp-probe.ps1 -Url "http://127.0.0.1:8000/mcp" `
#        -ToolsetName "editor_toolset.toolsets.scene.SceneTools" -ToolName "get_current_level"
#   pwsh -NoProfile -File ue-mcp-probe.ps1 -Url ... -ToolsetName "" -ToolName "list_toolsets"
#
# 退出码: 0 = 全通; 1 = 有步骤失败

[CmdletBinding()]
param(
    [string]$Url = 'http://127.0.0.1:8000/mcp',
    [string]$ToolsetName = '',
    [string]$ToolName = '',
    [string]$ArgumentsJson = '{}',
    [string]$ProtocolVersion = '2025-06-18',
    [int]$TimeoutSec = 30,
    [switch]$Raw
)

$ErrorActionPreference = 'Stop'
$failed = $false

function Step($m) { Write-Host ("[>] " + $m) -ForegroundColor Cyan }
function Good($m) { Write-Host ("[OK] " + $m) -ForegroundColor Green }
function Fail($m) { Write-Host ("[FAIL] " + $m) -ForegroundColor Red }
function Note($m) { Write-Host ("     " + $m) -ForegroundColor DarkGray }

# ---- HTTP POST 封装：同时吃 application/json 与 text/event-stream 响应 ----
function Invoke-McpPost {
    param(
        [string]$Uri,
        [string]$Json,
        [hashtable]$ExtraHeaders
    )
    $headers = @{ 'Accept' = 'application/json, text/event-stream' }
    if ($ExtraHeaders) { foreach ($k in $ExtraHeaders.Keys) { $headers[$k] = [string]$ExtraHeaders[$k] } }

    # UTF-8 字节体（避免 PS5.1 字符串体按 ASCII 编码破坏中文参数）；受限环境退化为字符串体
    $bodyValue = $Json
    try { $bodyValue = [System.Text.Encoding]::UTF8.GetBytes($Json) } catch { $bodyValue = $Json }

    $params = @{
        Uri         = $Uri
        Method      = 'Post'
        ContentType = 'application/json; charset=utf-8'
        Headers     = $headers
        Body        = $bodyValue
        TimeoutSec  = $TimeoutSec
    }
    if ($PSVersionTable.PSVersion.Major -lt 6) { $params['UseBasicParsing'] = $true }

    try {
        return Invoke-WebRequest @params
    } catch {
        $resp = $null
        if ($_.Exception.PSObject.Properties['Response']) { $resp = $_.Exception.Response }
        $code = ''
        if ($resp -and $resp.PSObject.Properties['StatusCode']) { $code = [string]$resp.StatusCode }
        $body = ''
        if ($resp -and $resp.PSObject.Properties['Content']) {
            try { $body = $resp.Content } catch { $body = '' }
        }
        $detail = "HTTP 错误 " + $code + " " + $_.Exception.Message
        if ($body) { $detail = $detail + " | body: " + $body }
        throw $detail
    }
}

function Get-JsonFromResponse {
    param($Response)
    $text = [string]$Response.Content
    if ([string]::IsNullOrWhiteSpace($text)) { return $null }
    $t = $text.Trim()
    if ($t -match '^(event|data|id|retry):') {
        $dataLines = @($t -split "\r?\n" | Where-Object { $_ -match '^data:' })
        if ($dataLines.Count -eq 0) { return $null }
        $t = ($dataLines[-1] -replace '^data:\s*', '').Trim()
    }
    return ($t | ConvertFrom-Json)
}

function Get-HeaderValue {
    param($Response, [string]$Name)
    $h = $Response.Headers
    if (-not $h) { return $null }
    $v = $h[$Name]
    if ($null -eq $v) {
        foreach ($k in $h.Keys) { if ($k -ieq $Name) { $v = $h[$k]; break } }
    }
    if ($v -is [array]) { return [string]$v[0] }
    return [string]$v
}

# ---------------------------------------------------------------- 0. 前置
Write-Host ""
Write-Host "=== Unreal MCP 协议探针 ===" -ForegroundColor Cyan
Note ("URL: " + $Url)

$probePort = ''
if ($Url -match ':(\d+)/') { $probePort = $Matches[1] }
$portHit = $null
if ($probePort) {
    # 某些环境 Get-NetTCPConnection 查不到监听项，用 netstat 兜底
    $portHit = @(netstat -ano 2>$null | Where-Object { $_ -match (':' + $probePort + '\s') -and $_ -match 'LISTENING' }) | Select-Object -First 1
}
if ($portHit) {
    $ownerPid = [int]((@($portHit -replace '\s+', ' '))[0].Trim() -split ' ')[-1]
    $ownerName = (Get-Process -Id $ownerPid -ErrorAction SilentlyContinue).ProcessName
    Good ("端口 " + $probePort + " 在监听 (PID " + $ownerPid + " " + $ownerName + ")")
} else {
    Note ("端口 " + $probePort + " 未在监听清单里（可能服务未启动或 URL 非本机），继续尝试 HTTP")
}

# ---------------------------------------------------------------- 1. initialize
Step "initialize"
$initBody = '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"' + $ProtocolVersion +
            '","capabilities":{},"clientInfo":{"name":"ue-mcp-probe","version":"1.0.0"}}}'
try {
    $init = Invoke-McpPost -Uri $Url -Json $initBody
} catch {
    Fail ("initialize 失败: " + $_.Exception.Message)
    Note "常见原因：编辑器没开 / 插件没启用 / 服务端没启动 / 端口不对"
    Note "先跑 ue-mcp-doctor.ps1 定位"
    exit 1
}
$initJson = Get-JsonFromResponse $init
$sessionId = Get-HeaderValue -Response $init -Name 'Mcp-Session-Id'
$negotiated = if ($initJson -and $initJson.result) { $initJson.result.protocolVersion } else { '' }

if ($sessionId) { Good ("会话 Mcp-Session-Id = " + $sessionId) } else { Note "响应未带 Mcp-Session-Id（某些实现不需要）" }
if ($negotiated) {
    Good ("协议协商结果 = " + $negotiated)
    if ($negotiated -ne $ProtocolVersion) { Note ("客户端请求 " + $ProtocolVersion + "，服务端回落到 " + $negotiated) }
} else {
    Fail "initialize 响应里没有 result.protocolVersion"
    Note (($init.Content -split "\r?\n" | Select-Object -First 8) -join ' ')
    $failed = $true
}
if ($Raw -and $initJson) { Note ("initialize 原文: " + ($initJson | ConvertTo-Json -Depth 6 -Compress)) }

# ---------------------------------------------------------------- 2. notifications/initialized
Step "notifications/initialized"
$hdrs = @{}
if ($sessionId) { $hdrs['Mcp-Session-Id'] = $sessionId }
if ($negotiated) { $hdrs['Mcp-Protocol-Version'] = $negotiated }
try {
    $null = Invoke-McpPost -Uri $Url -Json '{"jsonrpc":"2.0","method":"notifications/initialized"}' -ExtraHeaders $hdrs
    Good "已发送（204/200 均可）"
} catch {
    Fail ("notifications/initialized 失败: " + $_.Exception.Message)
    $failed = $true
}

# ---------------------------------------------------------------- 3. tools/list
Step "tools/list"
$toolNames = @()
try {
    $list = Invoke-McpPost -Uri $Url -Json '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}' -ExtraHeaders $hdrs
    $listJson = Get-JsonFromResponse $list
    if ($listJson -and $listJson.result -and $listJson.result.tools) {
        $toolNames = @($listJson.result.tools | ForEach-Object { $_.name })
        Good ("共 " + $toolNames.Count + " 个工具: " + ($toolNames -join ', '))
        if ($toolNames.Count -eq 3 -and $toolNames -contains 'call_tool') {
            Note "只有 3 个元工具 = UE 侧 bEnableToolSearch=True 的预期行为（其余工具集靠它们按需发现）"
        }
    } else {
        Fail "tools/list 响应结构异常"
        Note (($list.Content -split "\r?\n" | Select-Object -First 8) -join ' ')
        $failed = $true
    }
} catch {
    Fail ("tools/list 失败: " + $_.Exception.Message)
    Note "若提示未初始化，说明 notifications/initialized 没成功送达"
    $failed = $true
}

# ---------------------------------------------------------------- 4. 可选 tools/call
if ($ToolName) {
    Step ("tools/call -> " + $ToolName)
    $argsObj = $null
    try { $argsObj = $ArgumentsJson | ConvertFrom-Json } catch {
        Fail ("-ArgumentsJson 不是合法 JSON: " + $ArgumentsJson)
        $failed = $true
    }
    if ($argsObj) {
        $callParams = [ordered]@{ name = $ToolName; arguments = $argsObj }
        # 走元工具 call_tool：toolset 工具需要 toolset_name/tool_name
        if ($toolNames -contains 'call_tool' -and $ToolName -ne 'call_tool' -and
            $ToolName -notin @('list_toolsets', 'describe_toolset')) {
            $inner = [ordered]@{ tool_name = $ToolName; arguments = $argsObj }
            if ($ToolsetName) { $inner['toolset_name'] = $ToolsetName }
            $callParams = [ordered]@{ name = 'call_tool'; arguments = $inner }
        }
        if (-not $ToolsetName -and $ToolName -notmatch '\.') { Note "未提供 -ToolsetName：按顶层工具处理" }

        $callBody = [ordered]@{ jsonrpc = '2.0'; id = 3; method = 'tools/call'; params = $callParams } | ConvertTo-Json -Depth 12 -Compress
        try {
            $call = Invoke-McpPost -Uri $Url -Json $callBody -ExtraHeaders $hdrs
            $callJson = Get-JsonFromResponse $call
            if ($callJson.result -and $callJson.result.isError) {
                Fail "工具返回 isError=true"
                Note (($callJson.result.content | ForEach-Object { $_.text }) -join ' ')
                $failed = $true
            } elseif ($callJson.result) {
                Good "调用成功"
                foreach ($c in @($callJson.result.content)) {
                    if ($c.type -eq 'text') { Write-Host ("     " + $c.text) -ForegroundColor DarkGray }
                    else { Note ("[" + $c.type + "] 块") }
                }
                if ($callJson.result.structuredContent) {
                    Note ("structuredContent: " + ($callJson.result.structuredContent | ConvertTo-Json -Depth 8 -Compress))
                }
            } else {
                Fail "tools/call 响应异常"
                Note (($call.Content -split "\r?\n" | Select-Object -First 8) -join ' ')
                $failed = $true
            }
        } catch {
            Fail ("tools/call 失败: " + $_.Exception.Message)
            $failed = $true
        }
    }
}

# ---------------------------------------------------------------- 结论
Write-Host ""
if ($failed) {
    Write-Host "结论: 未全通 —— 按上面的 [FAIL] 行处理；连接层问题先跑 ue-mcp-doctor.ps1" -ForegroundColor Yellow
    Write-Host ""
    exit 1
}
Write-Host "结论: 全通 ✅ 服务端可用。下一步在 MCP 客户端（DSH: cordis.patch.yml）注册:" -ForegroundColor Green
Write-Host "  transport: streamable-http / url: $Url / serverName: unreal / failOnStartupError: false" -ForegroundColor Green
Write-Host ""
exit 0
