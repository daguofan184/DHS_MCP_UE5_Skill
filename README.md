# dsh-unreal-mcp-connect

把 **Unreal Engine 5.8+** 引擎自带的实验性 MCP 服务端（`ModelContextProtocol` 插件，FriendlyName「Unreal MCP」）
接通到 DSH / 任意 MCP 客户端的可复用流程 —— 含体检脚本、协议探针，和一套已验证的排障路径。

> 已实测：UE 5.8.4（`++UE5+Release-5.8-CL-58902052`）+ DSH web profile，
> `initialize` / `notifications/initialized` / `tools/list` / `tools/call` 全链路通过。

## 这是什么

UE 5.8 起引擎自带一个标准 MCP 服务端（streamable HTTP，默认 `http://127.0.0.1:8000/mcp`）。
本仓库是一个 **DSH skill**，让 agent 遇到「给 UE 工程接 MCP」这类任务时，按既定路径走，而不是每次重新摸索。

包含：

| 文件 | 作用 |
|---|---|
| `skills/unreal-mcp-connect/SKILL.md` | 运行手册：体检 → 分诊 → 启动服务端 → 注册客户端 → 端到端验证 |
| `skills/unreal-mcp-connect/scripts/ue-mcp-doctor.ps1` | 只读体检：工程/插件/引擎/进程/端口/ini/日志，结尾给「下一步做什么」 |
| `skills/unreal-mcp-connect/scripts/ue-mcp-probe.ps1` | 协议探针：三步握手 + 可选 `tools/call`，退出码 0/1 便于脚本化 |

## 安装

把 skill 目录放进 DSH 的用户技能根目录：

```powershell
# 方式一：直接复制
Copy-Item -Recurse .\skills\unreal-mcp-connect "$env:USERPROFILE\.dsh\skills\"

# 方式二：符号链接（方便更新）
New-Item -ItemType SymbolicLink -Path "$env:USERPROFILE\.dsh\skills\unreal-mcp-connect" `
  -Target (Resolve-Path .\skills\unreal-mcp-connect)
```

DSH 会扫描 `<DSH_HOME>/skills/<name>/SKILL.md`，目录出现后即可被识别（无需重启）。

## 快速自检

```powershell
# 体检（只读）
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\skills\unreal-mcp-connect\scripts\ue-mcp-doctor.ps1 -Port 8000

# 协议往返
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\skills\unreal-mcp-connect\scripts\ue-mcp-probe.ps1 -Url "http://127.0.0.1:8000/mcp"
```

## 客户端接入（DSH 示例）

在 `$DSH_HOME/profiles/<profile>/cordis.patch.yml` 追加：

```yaml
- insert:
    - id: mcp-client-unreal
      name: '@deepseek-ai/dsh-mcp-client'
      config:
        transport: streamable-http
        serverName: unreal
        url: 'http://127.0.0.1:8000/mcp'
        headers: {}
        toolCallTimeoutMs: 120000
        failOnStartupError: false
```

模型侧得到 `mcp__unreal__list_toolsets` / `describe_toolset` / `call_tool` 三个元工具，
再用它们按需发现 19 个工具集（Scene / Actor / Blueprint / Material / Niagara …）。

## 两个坑（写脚本前必看）

1. **`.ps1` 必须存为 UTF-8 with BOM** —— Windows PowerShell 5.1 对无 BOM 的 UTF-8 按 GBK 解析，
   中文注释直接变乱码并报 `Unexpected token`。
2. **`Get-NetTCPConnection` 在某些受限环境返回空**（比如沙箱里），
   脚本因此以 `netstat -ano` 为主、cmdlet 兜底。自己写检查时别只信 cmdlet。

更多细节（启动方式、端口冲突、Origin 白名单、UE 日志时间戳是 UTC 等）见
[`skills/unreal-mcp-connect/SKILL.md`](skills/unreal-mcp-connect/SKILL.md)。

## 要求

- Unreal Engine **5.8+**（`ModelContextProtocol` 插件自 5.8 起内置）
- Windows + Windows PowerShell 5.1 或 PowerShell 7
- 工程侧：编辑器开启「Unreal MCP」插件（实验性），`bAutoStartServer` 建议置 `True`
