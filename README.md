# [L4D2] Block No Steam Logon (All Codes)

完全阻止 L4D2 服务器上恼人的 **"No Steam logon"** 踢出 —— 让玩家不再被莫名其妙的 Steam 认证失败踢下线。

> 这是一个 **引擎内存补丁（Memory Patch）** 插件：直接改写 `engine_srv.so`（Linux）/ `engine.dll`（Windows）里 Steam 认证回调函数的判断分支，从**根**上阻止踢出，而不是靠条件苛刻的 Hook 拦截。
>
> **双平台支持**：同一个 `.smx` 通吃 Linux 与 Windows 服务端（运行时自动识别平台）。

---

## 它解决什么问题？

L4D2 服务器（Linux srcds 容器）经常会出现玩家被服务端以 `No Steam logon` 理由踢出的情况，日志表现为：

```
Connecting player ... 
Kicked: "No Steam logon"
```

根因是 Steam 认证票据校验回调 `CSteam3Server::OnValidateAuthTicketResponseHelper` 收到了非 OK 的 `EAuthSessionResponse` 返回码，服务端据此把玩家断开。

### 完整的 9 种 `EAuthSessionResponse`（code 0-8）

| Auth code | 枚举名 | 含义 | 原始行为 | 本插件 |
|-----------|--------|------|---------|--------|
| 0 | `OK` | 认证通过 | 继续 | 不干预 |
| 1 | `UserNotConnectedToSteam` | 用户（暂时）未连接到 Steam | 踢「No Steam logon」 | ✅ **拦截** |
| 2 | `NoLicenseOrExpired` | 未拥有此游戏 / 授权过期 | 踢「This Steam account does not own this game」 | 不拦截（DRM 层已挡） |
| 3 | `VACBanned` | **VAC 封禁** | 踢「VAC banned from secure server」 | ⛔ **绝不拦截**（真封禁必须生效） |
| 4 | `LoggedInElseWhere` | 账号在别处登录 | 踢「being used in another game」 | 不拦截 |
| 5 | `VACCheckTimedOut` | VAC 检查超时 | 踢「Client timed out」 | ⚙️ 可选（`block_code5`，默认关） |
| 6 | `AuthTicketCanceled` | 认证票据被取消 | 踢「No Steam logon」 | ✅ **拦截** |
| 7 | `AuthTicketInvalidAlreadyUsed` | 票据已被使用过 | 踢「No Steam logon」 | ✅ **拦截** |
| 8 | `AuthTicketInvalid` | 票据无效 | 踢「No Steam logon」 | ✅ **拦截** |

> 上表 9 种 code 与 `switch (EAuthSessionResponse)` 跳转表 `0x2b5a80` 的 9 个表项**一一对应**（见下方逆向依据）。

绝大多数 `No Steam logon` 踢出属于 **1/6/7/8**，多为玩家网络/Steam 客户端瞬时抖动，并非真的作弊或断线。本插件将这几类返回码放行，玩家留在服务器里。

> ⚠️ **codes 2 / 3 / 4 保持原样不拦**：2=没买游戏（DRM 层已挡）、3=VAC 封禁（必须踢）、4=异地登录（账号安全提示，应保留）。

---

## 逆向依据（Linux `engine_srv.so`）

目标库：`engine_srv.so`
- MD5：`0ee571682d63f798ac07d4bc238beb4f`（L4D2 官方 Linux 服务端）

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

`switch (EAuthSessionResponse)` 跳转表 `0x2b5a80`（**9 项，code 0-8 全覆盖**）：

| code | 跳转目标 | 踢出文案 | 备注 |
|------|---------|---------|------|
| 0 | `0x2011f0` | `"Client dropped by server"` | OK 路径（正常流程） |
| 1 | `0x201148` | `"No Steam logon"` | 有 `m_bShuttingDown` 保护 |
| 2 | `0x201180` | `"This Steam account does not own this game..."` | |
| 3 | `0x2011a0` | `"VAC banned from secure server"` | 有保护 |
| 4 | `0x2011b8` | `"This Steam account is being used in another game..."` | 有保护 |
| 5 | `0x2011d0` | `"Client timed out"` | |
| 6 | `0x201148` | `"No Steam logon"` | 有保护 |
| 7 | `0x201148` | `"No Steam logon"` | 有保护 |
| 8 | `0x201148` | `"No Steam logon"` | 有保护 |

> 「有保护」= 该分支先 `cmp dword ptr [edi+0x98], 1; je skip`（`[edi+0x98]` = `CSteam3Server::m_bShuttingDown`，服务器关闭时跳过踢人）。**Patch 1 正是把 code 1/6/7/8 这条 `je` 改成 `jmp`，让其无条件走「不踢」路径。**

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

## 逆向依据（Windows `engine.dll`）

> 由 Ghidra 12.1.4 反编译 + capstone 交叉验证。

目标库：`engine.dll`（x86 / PE32，ImageBase `0x10000000`）
- 来自 **L4D2 Dedicated Server**（`Left 4 Dead 2 Dedicated Server/bin/engine.dll`）
- MD5：`A16CD381409BAB749909D5000C2302D8`
- 函数：`CSteam3Server::OnValidateAuthTicketResponseHelper` @ RVA `0x12d750`（无符号，靠 signature 定位）

Ghidra 反编译结构（与 Linux 完全同构）：

```c
switch (code) {                       // code = EAuthSessionResponse
case 1:  if (*(int*)(this+0x84) != 1) { Disconnect("No Steam logon\n"); return; } break;
case 2:  Disconnect("...does not own this game..."); return;
case 3:  if (*(int*)(this+0x84) != 1) { Disconnect("VAC banned from secure server"); return; } break;
case 4:  if (*(int*)(this+0x84) != 1) { Disconnect("...being used in another location"); return; } break;
case 5:  Disconnect("Client timed out"); return;
case 6:  if (*(int*)(this+0x84) != 1) { Disconnect("No Steam logon\n"); return; } break;
case 7:
case 8:  if (*(int*)(this+0x84) != 1) { Disconnect("No Steam logon\n"); return; } break;
default: Disconnect("Client dropped by server");
}
```

其中 `this+0x84` = `m_bShuttingDown`（Linux 版是 `+0x98`，Windows 版偏移不同）。

`switch` 跳转表 @ RVA `0x12d898`（8 项，code 1..8）：

| code | 跳转目标 | 守卫 | 踢出文案 |
|------|---------|------|---------|
| 1 | `0x12d7ab` | `cmp [ebx+0x84],1; je 0x12d891` | `"No Steam logon"` |
| 2 | `0x12d7f3` | 无 | `"...does not own this game..."` |
| 3 | `0x12d80a` | `cmp [ebx+0x84],1; je skip` | `"VAC banned from secure server"` |
| 4 | `0x12d7cf` | `cmp [ebx+0x84],1; je skip` | `"...another location"` |
| 5 | `0x12d86a` | 无 | `"Client timed out"` |
| 6 | `0x12d82a` | `cmp [ebx+0x84],1; je 0x12d891` | `"No Steam logon"` |
| 7 | `0x12d84a` | `cmp [ebx+0x84],1; je 0x12d891` | `"No Steam logon"` |
| 8 | `0x12d84a` | （与 7 共用） | `"No Steam logon"` |

> **与 Linux 的关键差异**：Linux 版 code 1/6/7/8 **共用同一条 `je`（`0x20114f`）**；Windows 版它们**各有独立守卫（3 处 `je`）**，所以 Windows 需要 3 个 patch。

### 补丁内容（Windows）

三处守卫 `je` 全部改为 `jmp`（都跳向 `0x12d891` = 不踢/`ret 8`）：

| Patch | 相对 signature 偏移 | RVA | 原始 | 修改 |
|-------|------|-----|------|------|
| Code1 | `0x62`  | `0x12d7b2` | `0F 84 D9 00 00 00`（je 近跳，6B） | `E9 DA 00 00 00 90`（jmp + NOP，6B） |
| Code6 | `0xE1`  | `0x12d831` | `74 5E`（je 短跳，2B） | `EB 5E`（jmp，2B） |
| Code7/8 | `0x101` | `0x12d851` | `74 3E`（je 短跳，2B） | `EB 3E`（jmp，2B） |

> Code1 是 6 字节近跳，改成 5 字节 `jmp rel32` + 1 字节 `NOP(0x90)` 保持字节等长，不破坏后续指令对齐。
>
> **Signature（唯一匹配）**：
> ```
> 55 8B EC 53 56 8B 75 08 8B 46 04 8B 50 44 57 8B 7D 0C 83 C6 04 8B D9 57 8B CE FF D2 50
> 68 ?? ?? ?? ?? FF 15 ?? ?? ?? ?? 8B 06 8B 50 44 83 C4 0C 57 8B CE FF D2 50 68 ?? ?? ?? ??
> 68 ?? ?? ?? ?? E8 ?? ?? ?? ?? 8D 47 FF 83 C4 10 83 F8 07 0F 87 ?? ?? ?? ?? FF 24 85 ?? ?? ?? ??
> ```
>
**Patch — SkipClientTimedOut（code 5，默认关闭）**

- **Linux**：`offset 0xF0`，`8B 03 89 5D 08` → `E9 9B FF FF FF`（改写分支为 jmp 0x201170）
- **Windows**：改 **switch 跳转表 code5 项**（`table[4]` @ `entry+0x158`）
  - 位置：RVA `0x12d8a8`（跳转表 @ `0x12d898` + 4×4）
  - `verify = 6A D8 12 10`（= `0x1012d86a`，原「踢出」分支）
  - `patch  = 91 D8 12 10`（= `0x1012d891`，「不踢」收尾 `pop...ret 8`）
  - 效果：code 5 直接跳转表指向不踢路径 —— 比改指令更干净，4 字节搞定

> Windows 版 code 5 分支**没有守卫**（直接调 `Disconnect`），所以不走「改 je 为 jmp」的套路，
> 而是直接改跳转表项让它指向函数收尾。两平台 code5 均已支持。

### 真机验证

在 Windows 服务端（srcds.exe + MetaMod + SourceMod 1.12 + sourcescramble）实测启动日志：

```
[l4d2_block_no_steam_logon_all.smx] [BlockNoSteamLogonAll] platform=windows, loaded 3 patch handle(s), code5=no
[l4d2_block_no_steam_logon_all.smx] [BlockNoSteamLogonAll] Enabled 3 patch(es): codes 1/6/7/8 will NOT kick
[BlockNoSteamLogonAll] 'No Steam logon' block ENABLED (windows, 3 patch)
```

3 个 patch 的 `Validate()`（verify 字节比对）与 `Enable()` 均成功 —— 引擎侧确认 signature/offset 完全正确。

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
- **Linux** 或 **Windows** 服务端均可（同一个 `.smx` 通吃，运行时自动识别平台）
  - Linux → 打在 `engine_srv.so`
  - Windows → 打在 `engine.dll`

> 同一个 `.smx` 同时支持两端 —— 平台检测靠 gamedata 里的 `Offsets/OS`（`GameConfGetOffset`），
> 无需分别编译，也不需要单独的 Windows 版插件。

---

## 配置（ConVar）

插件首次加载后自动生成 `cfg/sourcemod/l4d2_block_no_steam_logon_all.cfg`：

| ConVar | 默认 | 说明 |
|--------|------|------|
| `l4d2_block_no_steam_logon_all_enable` | `1` | 阻止 codes 1/6/7/8 踢出 |
| `l4d2_block_no_steam_logon_all_block_code5` | `0` | 额外阻止 code 5「Client timed out」踢出 |
| `l4d2_block_no_steam_logon_all_version` | — | 版本号（只读） |

---

## 构建

**Windows（一键，含打包）**：

```powershell
# 需要 SM 1.12 的 spcomp64.exe + include 目录（含 sourcescramble.inc）
powershell -ExecutionPolicy Bypass -File build.ps1
# 或指定路径：
# powershell -File build.ps1 -SPCOMP <spcomp64.exe> -INCLUDE <include目录>
```

产出 `dist/l4d2_block_no_steam_logon_all.smx` + `dist/SHA256SUMS.txt`，并同步刷新 `pkg/`。

**手动（任意平台）**：

```bash
# 需要 SourceMod 1.12 编译器 spcomp（64 位）
spcomp64 src/l4d2_block_no_steam_logon_all.sp -i <sm_include_dir> -o dist/l4d2_block_no_steam_logon_all.smx
```

本仓库 `dist/` 内已附带编译产物（SM 1.12.0.7220 编译）。

---

## License

MIT
