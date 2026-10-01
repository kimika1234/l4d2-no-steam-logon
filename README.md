# [L4D2] Block No Steam Logon (All Codes)

完全阻止 L4D2 服务器上恼人的 **"No Steam logon"** 踢出 —— 让玩家不再被莫名其妙的 Steam 认证失败踢下线。

> 这是一个 **引擎内存补丁（Memory Patch）** 插件：直接改写 `engine_srv.so` 里 Steam 认证回调函数的判断分支，从**根**上阻止踢出，而不是靠条件苛刻的 Hook 拦截。

---

## 它解决什么问题？

L4D2 服务器（Linux srcds 容器）经常会出现玩家被服务端以 `No Steam logon` 理由踢出的情况，日志表现为：

```
Connecting player ... 
Kicked: "No Steam logon"
```

根因是 Steam 认证票据校验回调 `CSteam3Server::OnValidateAuthTicketResponseHelper` 收到了非 OK 的 `EAuthSessionResponse` 返回码，服务端据此把玩家断开。触发原因包括：

| Auth code | 枚举名 | 含义 |
|-----------|--------|------|
| 1 | `UserNotConnectedToSteam` | 用户（暂时）未连接到 Steam |
| 6 | `AuthTicketCanceled` | 认证票据被取消 |
| 7 | `AuthTicketInvalidAlreadyUsed` | 票据已被使用过 |
| 8 | `AuthTicketInvalid` | 票据无效 |
| 5 | `VACCheckTimedOut` | VAC 检查超时（"Client timed out"） |
| 3 | `VACBanned` | **VAC 封禁（本插件不做拦截，必须踢）** |

绝大多数 `No Steam logon` 踢出属于 **1/6/7/8**，多为玩家网络/Steam 客户端瞬时抖动，并非真的作弊或断线。本插件将这几类返回码放行，玩家留在服务器里。

---

## 逆向依据（Linux `engine_srv.so`）

目标库：`engine_srv.so`
- MD5：`0ee571682d63f798ac07d4bc238beb4f`（45 / 103 全农场同款）

函数：`CSteam3Server::OnValidateAuthTicketResponseHelper`
- Linux 符号：`_ZN13CSteam3Server34OnValidateAuthTicketResponseHelperEP11CBaseClient20EAuthSessionResponse`
- 地址：`0x2010e0`

反汇编关键片段：

```asm
0x201148: cmp dword ptr [edi + 0x98], 1   ; m_bShuttingDown 检查
0x20114f: je  0x201170                    ; == 1 则跳过踢出
0x201153: mov [ebp+0xc], 0x2b5566         ; "No Steam logon"
          ... jmp [vtable+0x3c]           ; CBaseClient::Disconnect
```

`switch (EAuthSessionResponse)` 跳转表 `0x2b5a80`：
- `case 1,6,7,8` → `0x201148`（踢出文案 `"No Steam logon"`）
- `case 5` → `0x2011d0`（踢出文案 `"Client timed out"`）
- `case 3` → VAC banned（保留原逻辑，必须踢）

### 补丁内容

**Patch 1 — SkipNoSteamLogonKick**（默认启用）
- 位置：偏移 `0x6F`（即 `0x20114f`）
- 原始：`74 1F`（`je +0x1F`）
- 修改：`EB 1F`（`jmp +0x1F`）
- 效果：codes **1/6/7/8** 全部走 `m_bShuttingDown == 1` 的"不踢"路径

**Patch 2 — SkipClientTimedOut**（默认关闭，需 `block_code5` 开启）
- 位置：偏移 `0xF0`（即 `0x2011d0`）
- 原始：`8B 03 89 5D 08`（`mov eax,[ebx]; mov [ebp+8],ebx`）
- 修改：`E9 9B FF FF FF`（`jmp 0x201170`，rel -0x65）
- 效果：code **5**（VAC 检查超时「Client timed out」）不踢

> ⚠️ `0x201148` 是 `m_bShuttingDown` 检查。该路径也是服务器**正在关闭**时的正常跳过逻辑 —— 补丁把它变成「永远跳过」。这是本方案的根本原理。

---

## 安装

把 `pkg/` 下的内容合并进服务器游戏根目录（`left4dead2/` 所在目录）：

```
pkg/
├── addons/sourcemod/plugins/l4d2_block_no_steam_logon_all.smx
└── addons/sourcemod/gamedata/l4d2_block_no_steam_logon_all.txt
```

即最终路径：

```
<server>/left4dead2/addons/sourcemod/plugins/l4d2_block_no_steam_logon_all.smx
<server>/left4dead2/addons/sourcemod/gamedata/l4d2_block_no_steam_logon_all.txt
```

重启服务器（或 `sm plugins load l4d2_block_no_steam_logon_all`）。

### 依赖

- SourceMod **1.12+**（`sourcescramble` 扩展；1.11 编译器会报 custom destructors 错误）
- Linux 服务端（本补丁仅含 linux 签名/偏移）

---

## 配置（ConVar）

插件首次加载后自动生成 `cfg/sourcemod/l4d2_block_no_steam_logon_all.cfg`：

| ConVar | 默认 | 说明 |
|--------|------|------|
| `l4d2_block_no_steam_logon_all_enable` | `1` | 阻止 codes 1/6/7/8 踢出 |
| `l4d2_block_no_steam_logon_all_block_code5` | `0` | 额外阻止 code 5「Client timed out」踢出 |
| `l4d2_block_no_steam_logon_all_version` | — | 版本号（只读） |

---

## ⚠️ 重要：`unload_all` + `load_lock` 陷阱

本农场部分配置（`sm_warmode_on.cfg` 战备模式、难度系统 cfg、confogl 竞技预设、投票预设等）包含：

```
sm plugins unload_all
sm plugins load_lock
```

这会把**不在白名单里的插件静默卸载并锁死**。部署本插件后，若这些 cfg 存在，需要在每个 `load_lock` 之前插入：

```
sm plugins load l4d2_block_no_steam_logon_all.smx
```

**验证是否真的在跑，以 RCON `sm plugins info l4d2_block_no_steam_logon_all.smx` 为准**，不要只看日志里的 `Patch enabled`（日志有记录 ≠ 插件当前加载）。

---

## 构建

```bash
# 需要 SourceMod 1.12 编译器 spcomp（64 位）
spcomp64 src/l4d2_block_no_steam_logon_all.sp -i <sm_include_dir> -o dist/l4d2_block_no_steam_logon_all.smx
```

本仓库 `dist/` 内已附带编译产物（SM 1.12.0.7220 编译）。

---

## License

MIT
