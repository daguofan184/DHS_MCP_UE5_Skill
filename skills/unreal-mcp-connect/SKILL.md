---
name: unreal-mcp-connect
description: >
  把 Unreal Engine 5.8+ 内置的 "Unreal MCP"（Experimental 插件 ModelContextProtocol，
  streamable-http 于 http://127.0.0.1:<port>/mcp）接通到 DSH 等 MCP 客户端的可复用流程。
  覆盖：体检诊断 -> 启动服务端 -> 在 cordis.patch.yml 注册 MCP 客户端 -> initialize /
  tools/list / tools/call 端到端验证。适用于「新 Unreal 项目要接 MCP / 让 AI 控制编辑器」的场景。
whenToUse: >
  用户说「给这个 UE 项目接通 MCP」「mcp__unreal__ 工具不见了/连不上」「UE MCP 服务没起来」
  或新建的 UE 5.8+ 工程要接 AI 控制时使用。
metadata:
  version: 1.0.0
  verified: UE 5.8 (++UE5+Release-5.8-CL-58902052) + DSH web profile，2026-10-30 实测通过
---

# Unreal Engine MCP 接通技能（unreal-mcp-connect）

UE 5.8 起引擎自带实验性插件 **`ModelContextProtocol`（FriendlyName「Unreal MCP」）**，它就是一个标准
MCP 服务端：streamable HTTP，默认 `http://127.0.0.1:8000/mcp`。DSH 侧用
`@deepseek-ai/dsh-mcp-client`（`transport: streamable-http`）即可接入，模型看到的是
`mcp__unreal__list_toolsets` / `mcp__unreal__describe_toolset` / `mcp__unreal__call_tool`。

## 何时使用

- 新 Unreal 工程要接 MCP / 让 agent 操作编辑器。
- 已经接通过，但 `mcp__unreal__*` 工具消失、调用报 unreachable。
- 想换端口、换机器、或排查"插件开了但 8000 没监听"。

## 第 0 步：一条命令体检（先跑这个）

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "<本技能目录>\scripts\ue-mcp-doctor.ps1" -ProjectPath "<工程>\Xxx.uproject" -Port 8000
```

不带 `-ProjectPath` 时脚本按当前目录向上找 `*.uproject`。输出每项 `[OK]/[WARN]/[FAIL]`，
末尾给出「下一步做什么」。它只读不写，可放心反复跑。

> 本机可能没有 `pwsh`（只有 Windows PowerShell 5.1），统一用 `powershell.exe -NoProfile -ExecutionPolicy Bypass -File` 调用。

## 第 1 步：按体检结论分三类处理

| 现象 | 根因 | 修复 |
|---|---|---|
| `.uproject` 里没有 `ModelContextProtocol`，或 `Enabled: false` | 插件未启用 | 编辑器 `编辑 → 插件` 搜 "MCP" 勾选「Unreal MCP」（提示实验性，选「是」），或直接在 `.uproject` 的 `Plugins` 数组加 `{"Name": "ModelContextProtocol", "Enabled": true}`，然后重启编辑器 |
| 插件已启用、编辑器在跑，但 **端口没监听** | **最常见**：`bAutoStartServer` 是在编辑器启动之后才写进 ini 的，而自动启动只在 `PostEngineInit` 读一次 | 见第 2 步（控制台起服务，或重启编辑器） |
| 端口被别的进程占（`OwningProcess` 不是 UnrealEditor） | 端口冲突 | 换端口：设置里改 `ServerPortNumber`，或启动参数 `-ModelContextProtocolPort=8123`；或杀掉占用者 |

体检里还要看两条容易误判的点：

- **ini 的 LastWriteTime 晚于编辑器进程 StartTime** → 就是上面第二种情况，重启才生效。
- **日志时间戳是 UTC**：`Saved/Logs/*.log` 里 `[2026.10.30-13.25.09]` 对应本机 21:25，别看错。

## 第 2 步：启动服务端（三种方式，任选）

1. **不重启（最快）**：编辑器里按 `` ` `` 打开控制台（或用 Terminal 插件）输入
   `ModelContextProtocol.StartServer`（可带端口，如 `ModelContextProtocol.StartServer 8123`）。
2. **重启编辑器**：前提是 ini/设置里 `bAutoStartServer=True`，重启后自动监听。
3. **命令行强制**：`UnrealEditor.exe "<工程>.uproject" -ModelContextProtocolStartServer -ModelContextProtocolPort=8000`。

配套控制台命令：`ModelContextProtocol.StopServer`、`ModelContextProtocol.RefreshTools`。

成功判据（两处都要有）：

```
Saved/Logs/*.log:  LogModelContextProtocol: Starting MCP server on port 8000
netstat -ano | findstr :8000   ->  TCP 127.0.0.1:8000 ... LISTENING <UnrealEditor PID>
```

> 注意：日志出现 `Starting MCP server` 后，socket 通常还要 1~2 秒才 LISTENING，别立刻断言失败。

## 第 3 步：协议层验证（不依赖 DSH）

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "<本技能目录>\scripts\ue-mcp-probe.ps1" -Url "http://127.0.0.1:8000/mcp"
```

脚本做完整三步握手并打印结果：`initialize` -> `notifications/initialized` -> `tools/list`（列出工具名）。
还可以直接调一个工具做真实往返：

```powershell
# 只读示例：取当前关卡路径
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "<本技能目录>\scripts\ue-mcp-probe.ps1" `
  -ToolsetName "editor_toolset.toolsets.scene.SceneTools" `
  -ToolName "get_current_level"
```

期望输出形如 `[OK] 调用成功` + `{"returnValue":"/Temp/Untitled_1"}`，退出码 0。通了再进第 4 步。
其它可选参数：`-ArgumentsJson '{"a":1}'`（工具入参）、`-ProtocolVersion 2025-06-18`（协商起始版本）、`-Raw`（打印原始响应）。

## 第 4 步：在 DSH 里注册 MCP 客户端

编辑 **profile 的 patch 文件**（不是 `cordis.yml`）：
`$DSH_HOME/profiles/<profile>/cordis.patch.yml`，默认 `C:\Users\<你>\.dsh\profiles\web\cordis.patch.yml`。
在文件末尾追加（`insert` 形式，与其它 MCP 条目并列）：

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

要点：

- **`serverName: unreal`** 决定工具前缀 `mcp__unreal__*`；同一进程内不能重复。
- **`failOnStartupError: false` 必须有**：编辑器没开时 UE 服务不可达，设 true 会让该插件激活失败；
  设 false 则 DSH 正常启动、工具只是暂时缺席。
- 该文件在**工作区外**，DSH 沙箱下 `write`/`edit` 会被拒；按规则做一次 `sandbox_permissions:
  danger-full-access` 提权重试（带 justification），不要绕道。
- **改完通常不用重启 DSH**：host 监听 patch 文件，HMR 会热加载并连接。

**HMR 是否生效的硬证据**（比看工具列表可靠）：查 UE 日志有没有出现**第二个会话**且协议版本不同——

```
LogModelContextProtocol: Client requested protocol version '2025-11-25', negotiated '2025-11-25'
LogModelContextProtocol: Initializing new session: <hex>
LogModelContextProtocol: Listing tools (3)
```

`2025-06-18` 是你自己 curl/probe 的，`2025-11-25` 基本就是 DSH 客户端。

## 第 5 步：以模型视角验证

`mcp__unreal__list_toolsets`（无参）-> 拿到工具集列表 -> `mcp__unreal__describe_toolset`
（传 `toolset_name`）-> `mcp__unreal__call_tool`（传 `toolset_name` / `tool_name` / `arguments`）。
首次建议用只读工具试水，例如 `editor_toolset.toolsets.scene.SceneTools.get_current_level`。

## 关键事实速查

| 项 | 值 |
|---|---|
| 插件路径 | `<引擎>/Engine/Plugins/Experimental/ModelContextProtocol/` |
| 模块 | ModelContextProtocol / MCPEngine / MCPEditor（+3 个 Tests） |
| 传输 | streamable HTTP：`POST`/`GET`(SSE)/`DELETE` 同一路径 |
| 默认地址 | `http://127.0.0.1:8000/mcp` |
| 设置项（ini 节） | `[/Script/ModelContextProtocolEngine.ModelContextProtocolSettings]` |
| 设置键 | `ServerPortNumber`(8000) / `ServerUrlPath`(/mcp) / `bAutoStartServer`(false) / `bEnableToolSearch`(true) |
| 设置文件 | `<工程>/Saved/Config/WindowsEditor/EditorPerProjectUserSettings.ini` |
| 相关启动参数 | `-ModelContextProtocolStartServer`、`-ModelContextProtocolPort=N` |
| 协议头 | 请求协商 `protocolVersion`；后续请求带 `Mcp-Session-Id`，可选 `Mcp-Protocol-Version` |
| 日志类别 | `LogModelContextProtocol` |

## 常见坑

1. **只暴露 3 个工具不是 bug**：`bEnableToolSearch=True` 时刻意只注册 `list_toolsets` /
   `describe_toolset` / `call_tool` 三个元工具（省 token），其余 19 个工具集靠它们按需发现。
   想让工具平铺出现在工具列表里，把 `bEnableToolSearch` 关掉（token 成本高）。
2. **只监听 127.0.0.1，无鉴权**：不要改成 0.0.0.0 或做端口转发暴露到网络。
3. **Origin 白名单**：请求若带 `Origin` 头，只有 `localhost` / `127.0.0.1` / `[::1]` 被接受，
   其它一律 HTTP 403。从浏览器或远程客户端接时要注意。
4. **curl 内联 body 容易踩坑**：PowerShell 里把 JSON 内联给 `curl.exe -d` 常被转义坏成
   `-32700 Invalid JSON body!`。用 `--data-binary "@file.json"` 或直接用 probe 脚本。
5. **`initialize` 必须紧跟 `notifications/initialized`**，否则后续 `tools/list` 会以未初始化被拒。
6. **写操作是真改工程**：SceneTools / ActorTools 的 `save_actor`、`remove_from_scene`、
   `delete_folder`、`load_level` 等直接落盘，调用前逐次与用户确认。
7. **编辑器关了就没有服务**：HMR + `failOnStartupError: false` 下工具会消失但不影响 DSH；
   编辑器重启后会自动重连（无需再动 DSH 配置）。

## 新项目接通 checklist

- [ ] `.uproject` 的 `EngineAssociation` 是 5.8+，且 `Plugins` 含 `ModelContextProtocol`（Enabled）
- [ ] 跑 `ue-mcp-doctor.ps1`，三项全绿：插件已启用 / 编辑器在跑 / 端口 LISTENING
- [ ] 跑 `ue-mcp-probe.ps1`，`initialize` + `tools/list` 成功
- [ ] `cordis.patch.yml` 里加了 `mcp-client-unreal`，`serverName` 未被占用
- [ ] UE 日志出现 `2025-11-25` 的新会话（HMR 已接管）
- [ ] `mcp__unreal__call_tool` 跑通一个只读工具（如 `get_current_level`）

## 本技能的文件与维护须知

```
unreal-mcp-connect/
├── SKILL.md                  # 本文（运行手册 + 速查表）
└── scripts/
    ├── ue-mcp-doctor.ps1     # 只读体检：工程/插件/引擎/进程/端口/ini/日志
    └── ue-mcp-probe.ps1      # 协议探针：initialize -> initialized -> tools/list（可选 tools/call）
```

两个坑（改脚本前务必看）：

1. **`.ps1` 必须存为 UTF-8 with BOM**。Windows PowerShell 5.1 对无 BOM 的 UTF-8 会按 GBK 解析，
   中文注释/字符串直接变成乱码并报 `Unexpected token`。若用工具重写过脚本（例如某些编辑器默认存
   UTF-8 无 BOM），用下面这段补 BOM：

   ```powershell
   $enc = New-Object System.Text.UTF8Encoding($true)
   $p = "<脚本路径>.ps1"
   [System.IO.File]::WriteAllText($p, [System.IO.File]::ReadAllText($p, [System.Text.Encoding]::UTF8), $enc)
   ```

2. **`Get-NetTCPConnection` 在某些环境（如受限沙箱）返回空**，看不到真实监听项。两个脚本因此都以
   `netstat -ano` 为主、`Get-NetTCPConnection` 兜底；自己写检查时别只信 cmdlet。

已验证：UE 5.8.4（`++UE5+Release-5.8-CL-58902052`）+ Windows PowerShell 5.1，
doctor 全绿、probe 握手与 `tools/call` 均实测通过。
