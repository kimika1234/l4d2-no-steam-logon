/*
 * [L4D2] Block No Steam Logon - All Codes (engine memory patch)
 *
 * 完全阻止 "No Steam logon" 踢出（EAuthSessionResponse codes 1/6/7/8）。
 * 支持 Linux (engine_srv.so) 与 Windows (engine.dll) 双平台。
 * 一个 .smx 通吃两端（运行时用 GameConfGetOffset(gd,"OS") 判断平台）。
 *
 * ==== 原理 ====
 * CSteam3Server::OnValidateAuthTicketResponseHelper 中，auth code 1/6/7/8
 * 分支各有一条守卫：先 cmp m_bShuttingDown,1 ; je 跳过踢出(Disconnect)。
 * 本插件把该 je 改为 jmp，使 codes 1/6/7/8 无条件走「不踢」路径。
 *
 *   Linux  (engine_srv.so): code 1/6/7/8 共用同一 je (0x20114f: 74 1F)。
 *                           m_bShuttingDown @ [edi+0x98]
 *   Windows(engine.dll)   : code 1/6/7/8 各有独立守卫（3 处 je）。
 *                           m_bShuttingDown @ [ebx+0x84]
 *                           code1 近跳(0F 84)/ code6,7-8 短跳(74)
 *
 * ==== 可选 ====
 * code 5 ("Client timed out") 默认放行；打开 l4d2_block_no_steam_logon_all_block_code5
 * 可拦截。Linux: 改写 code5 分支指令为 jmp；Windows: 改写 switch 跳转表 code5 项
 * 指向「不踢」路径。两平台均已支持。
 *
 * 详见 gamedata/l4d2_block_no_steam_logon_all.txt
 */
#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sourcescramble>

#define GAMEDATA_FILE "l4d2_block_no_steam_logon_all"
#define PLUGIN_VERSION "1.2.0"
#define MAX_PATCHES 8

enum
{
	OS_WINDOWS = 0,
	OS_LINUX
};

MemoryPatch g_hPatches[MAX_PATCHES];
int         g_iPatchCount;
bool        g_bCode5Available;
int         g_iCode5Index = -1;
int         g_iOS = -1;

// codes 1/6/7/8 守卫 patch 名称
static const char g_szNoSteamWin[][] = {
	"OnValidateAuthTicketResponseHelper::SkipNoSteamLogonKick_Code1",
	"OnValidateAuthTicketResponseHelper::SkipNoSteamLogonKick_Code6",
	"OnValidateAuthTicketResponseHelper::SkipNoSteamLogonKick_Code78"
};
static const char g_szNoSteamLinux[][] = {
	"OnValidateAuthTicketResponseHelper::SkipNoSteamLogonKick_Code1"
};
#define PATCH_CODE5 "OnValidateAuthTicketResponseHelper::SkipClientTimedOut"

ConVar g_hCvar_Enable;
ConVar g_hCvar_BlockCode5;
bool g_bEnabled;
bool g_bBlockCode5;

public Plugin myinfo =
{
	name        = "[L4D2] Block No Steam Logon (All Codes)",
	author      = "Hermes Agent",
	description = "Engine memory patch: fully blocks 'No Steam logon' kicks (codes 1/6/7/8) + optional code 5. Linux & Windows.",
	version     = PLUGIN_VERSION,
	url         = ""
};

public void OnPluginStart()
{
	CreateConVar("l4d2_block_no_steam_logon_all_version", PLUGIN_VERSION, "Plugin version.", FCVAR_NONE | FCVAR_DONTRECORD);

	g_hCvar_Enable = CreateConVar("l4d2_block_no_steam_logon_all_enable", "1",
		"[0=off/1=on] Block 'No Steam logon' kicks (auth codes 1/6/7/8).", FCVAR_NONE, true, 0.0, true, 1.0);
	g_hCvar_Enable.AddChangeHook(OnEnableChange);

	g_hCvar_BlockCode5 = CreateConVar("l4d2_block_no_steam_logon_all_block_code5", "0",
		"[0=off/1=on] Also block code 5 kick ('Client timed out', VAC check timeout).", FCVAR_NONE, true, 0.0, true, 1.0);
	g_hCvar_BlockCode5.AddChangeHook(OnEnableChange);

	AutoExecConfig(true, "l4d2_block_no_steam_logon_all");

	InitPatches();
	ApplyPatchState();
}

void OnEnableChange(ConVar convar, const char[] oldValue, const char[] newValue)
{
	ApplyPatchState();
}

void InitPatches()
{
	GameData gd = new GameData(GAMEDATA_FILE);
	if (!gd)
		SetFailState("Missing or invalid gamedata: %s.txt", GAMEDATA_FILE);

	// 运行时平台检测（gamedata 里 "OS" { "windows" "0" "linux" "1" }）
	g_iOS = GameConfGetOffset(gd, "OS");
	if (g_iOS < 0)
	{
		delete gd;
		SetFailState("gamedata missing 'OS' offset");
	}

	g_iPatchCount = 0;
	g_bCode5Available = false;

	// codes 1/6/7/8 的守卫 patch
	// Linux: 1 条共用；Windows: 3 条
	if (g_iOS == OS_LINUX)
	{
		for (int i = 0; i < sizeof(g_szNoSteamLinux); i++)
		{
			MemoryPatch p = MemoryPatch.CreateFromConf(gd, g_szNoSteamLinux[i]);
			if (p == null)
			{
				delete gd;
				SetFailState("Failed to create patch: %s", g_szNoSteamLinux[i]);
			}
			g_hPatches[g_iPatchCount++] = p;
		}
	}
	else // windows
	{
		for (int i = 0; i < sizeof(g_szNoSteamWin); i++)
		{
			MemoryPatch p = MemoryPatch.CreateFromConf(gd, g_szNoSteamWin[i]);
			if (p == null)
			{
				delete gd;
				SetFailState("Failed to create patch: %s", g_szNoSteamWin[i]);
			}
			g_hPatches[g_iPatchCount++] = p;
		}
	}

	if (g_iPatchCount == 0)
	{
		delete gd;
		SetFailState("No 'No Steam logon' patch created");
	}

	// code5（Linux + Windows 均有 patch 点）
	{
		MemoryPatch p5 = MemoryPatch.CreateFromConf(gd, PATCH_CODE5);
		if (p5 != null)
		{
			g_iCode5Index = g_iPatchCount;
			g_hPatches[g_iPatchCount++] = p5;
			g_bCode5Available = true;
		}
	}

	delete gd;

	LogMessage("[BlockNoSteamLogonAll] platform=%s, loaded %d patch handle(s), code5=%s",
		(g_iOS == OS_LINUX) ? "linux" : "windows", g_iPatchCount, g_bCode5Available ? "yes" : "no");
}

void ApplyPatchState()
{
	bool want = g_hCvar_Enable.BoolValue;
	bool wantCode5 = g_hCvar_BlockCode5.BoolValue && g_bCode5Available;

	// codes 1/6/7/8 守卫（不含 code5）
	int noSteamEnd = g_bCode5Available ? g_iCode5Index : g_iPatchCount;

	if (want)
	{
		if (!g_bEnabled)
		{
			for (int i = 0; i < noSteamEnd; i++)
			{
				if (!g_hPatches[i].Validate())
					SetFailState("Patch verify failed (engine mismatch?): #%d", i);
				if (!g_hPatches[i].Enable())
					SetFailState("Patch enable failed: #%d", i);
			}
			g_bEnabled = true;
			LogMessage("[BlockNoSteamLogonAll] Enabled %d patch(es): codes 1/6/7/8 will NOT kick", noSteamEnd);
			PrintToServer("[BlockNoSteamLogonAll] 'No Steam logon' block ENABLED (%s, %d patch)",
				(g_iOS == OS_LINUX) ? "linux" : "windows", noSteamEnd);
		}
	}
	else if (g_bEnabled)
	{
		for (int i = 0; i < noSteamEnd; i++)
			g_hPatches[i].Disable();
		g_bEnabled = false;
		LogMessage("[BlockNoSteamLogonAll] Disabled");
	}

	// code5（可选）
	if (wantCode5)
	{
		if (!g_bBlockCode5)
		{
			if (!g_hPatches[g_iCode5Index].Validate())
				SetFailState("code5 patch verify failed");
			if (!g_hPatches[g_iCode5Index].Enable())
				SetFailState("code5 patch enable failed");
			g_bBlockCode5 = true;
			LogMessage("[BlockNoSteamLogonAll] Code5 patch enabled (Client timed out will NOT kick)");
		}
	}
	else if (g_bBlockCode5)
	{
		g_hPatches[g_iCode5Index].Disable();
		g_bBlockCode5 = false;
		LogMessage("[BlockNoSteamLogonAll] Code5 patch disabled");
	}
}
