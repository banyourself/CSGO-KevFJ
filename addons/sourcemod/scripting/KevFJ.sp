#include <sourcemod>
#include <sdktools>
#include <sdkhooks>
#include <cstrike>
#include <adminmenu>

#pragma newdecls required
#pragma semicolon 1

#define PLUGIN_VERSION "1.4"

// Change the tag here and nowhere else.
char g_sPrefix[] = " \x04[FJ]\x01 ";

// hnsmix exposes these. Optional, so KevFJ still loads on a server without it.
native int kev_isMixActive();
// Redraws the Discord status embed. Its refresh is event-driven and FJ is not one of its
// events, so the sidebar color would sit stale until the 90s safety-net pass.
native void kev_refreshMixStatus();

ConVar g_cvTime
	 , g_cvNoclip
	 , g_cvTeleport
	 , g_cvSpectate
	 , g_cvNoCollide
	 , g_cvGodmode;

bool g_bFJ
   , g_bNoclip[MAXPLAYERS+1]
   , g_bSaved[MAXPLAYERS+1]
   , g_bGod[MAXPLAYERS+1];

float g_fPos[MAXPLAYERS+1][3]
	, g_fAng[MAXPLAYERS+1][3];

TopMenu g_hTopMenu = null;

// Ours specifically, so cancelling never kills an unrelated vote.
bool g_bFJVoteActive = false;
bool g_bFJVoteWantsOn = false;  // which way the running vote would flip it

public Plugin myinfo = {
	name = "KevFJ",
	author = "hiiamu + Kevin + zwolof",
	description = "id/iamarealplayer",
	version = PLUGIN_VERSION,
	url = ""
};

public APLRes AskPluginLoad2(Handle myself, bool late, char[] error, int err_max) {
	// gstrafe reads this to drop enemy collision from its trace filter while FJ runs.
	CreateNative("kev_isFJActive", Native_isFJActive);

	MarkNativeAsOptional("kev_isMixActive");
	MarkNativeAsOptional("kev_refreshMixStatus");
	return APLRes_Success;
}

public int Native_isFJActive(Handle plugin, int numParams) {
	return g_bFJ ? 1 : 0;
}

public void OnPluginStart() {
	RegConsoleCmd("sm_fj", Command_FJ, "Open the FJ menu");
	RegConsoleCmd("sm_funjump", Command_FJ, "Open the FJ menu (alias)");
	RegConsoleCmd("sm_fjmenu", Command_FJ, "Open the FJ menu (alias)");
	RegConsoleCmd("sm_funjumpmenu", Command_FJ, "Open the FJ menu (alias)");
	RegConsoleCmd("sm_menufj", Command_FJ, "Open the FJ menu (alias)");

	RegAdminCmd("sm_cancelfj", Command_CancelFJ, ADMFLAG_GENERIC, "Disable FJ, or cancel a running FJ vote");
	RegAdminCmd("sm_fjoff", Command_CancelFJ, ADMFLAG_GENERIC, "Disable FJ, or cancel a running FJ vote (alias)");
	RegAdminCmd("sm_disablefj", Command_CancelFJ, ADMFLAG_GENERIC, "Disable FJ, or cancel a running FJ vote (alias)");
	RegConsoleCmd("sm_votefj", Command_VoteFJ, "Start a vote to enable FJ mode");
	RegConsoleCmd("sm_fjvote", Command_VoteFJ, "Start a vote to enable FJ mode (alias)");
	RegConsoleCmd("sm_funjumpvote", Command_VoteFJ, "Start a vote to enable FJ mode (alias)");
	RegConsoleCmd("sm_votefunjump", Command_VoteFJ, "Start a vote to enable FJ mode (alias)");
	RegAdminCmd("sm_forcefj", Command_ForceFJ, ADMFLAG_GENERIC, "sm_forcefj [on|off] - force FJ mode");

	// Round length, not session length: FJ runs until voted or forced off. 60 is CS:GO's mp_roundtime ceiling.
	g_cvTime = CreateConVar("kevfj_time", "60.0", "FJ round length in minutes. FJ itself runs until it is voted or forced off.", FCVAR_NOTIFY, true, 1.0, true, 60.0);
	g_cvNoclip = CreateConVar("kevfj_noclip", "1", "Allow players to toggle noclip.", FCVAR_NOTIFY, true, 0.0, true, 1.0);
	g_cvTeleport = CreateConVar("kevfj_teleport", "1", "Allow save location and teleport.", FCVAR_NOTIFY, true, 0.0, true, 1.0);
	g_cvSpectate = CreateConVar("kevfj_spectate", "1", "Allow the spectate toggle.", FCVAR_NOTIFY, true, 0.0, true, 1.0);
	g_cvNoCollide = CreateConVar("kevfj_nocollide", "1", "Players pass through each other during FJ, both teams.", FCVAR_NOTIFY, true, 0.0, true, 1.0);
	g_cvGodmode = CreateConVar("kevfj_godmode", "1", "Allow players to toggle godmode. Off means everyone takes damage.", FCVAR_NOTIFY, true, 0.0, true, 1.0);

	AutoExecConfig(true, "KevFJ");

	HookEvent("player_spawn", Event_PlayerSpawn, EventHookMode_Post);
	HookEvent("player_death", Event_PlayerDeath, EventHookMode_Post);
	HookEvent("player_team", Event_PlayerTeam, EventHookMode_Post);
	HookEvent("round_start", Event_RoundStart, EventHookMode_Post);

	// No NO_MAPCHANGE: this is created once and must survive map changes.
	CreateTimer(1.0, Timer_FJMixWatch, _, TIMER_REPEAT);
}

public void OnAllPluginsLoaded() {
	if(LibraryExists("adminmenu")) {
		TopMenu topmenu = GetAdminTopMenu();
		if(topmenu != null)
			OnAdminMenuReady(topmenu);
	}
}

public void OnMapStart() {
	// Never carries over. A fresh map starts in normal play.
	g_bFJ = false;

	for(int i = 1; i <= MaxClients; i++) {
		g_bNoclip[i] = false;
		g_bSaved[i] = false;
		g_bGod[i] = true;
	}
}

public void OnMapEnd() {
}

public void OnPluginEnd() {
	if(g_bFJ)
		SetFJ(false, "plugin unload");
}

public void OnClientPutInServer(int client) {
	g_bNoclip[client] = false;
	g_bSaved[client] = false;
	g_bGod[client] = true;
}

public void Event_PlayerSpawn(Event event, const char[] name, bool dontBroadcast) {
	int client = GetClientOfUserId(event.GetInt("userid"));
	if(!IsValidClient(client))
		return;

	// Collision group and movetype both reset on spawn, so reapply.
	g_bNoclip[client] = false;
	if(g_bFJ)
		ApplyFJState(client, true);
}

public void Event_PlayerDeath(Event event, const char[] name, bool dontBroadcast) {
	if(!g_bFJ)
		return;

	int client = GetClientOfUserId(event.GetInt("userid"));
	if(!IsValidClient(client))
		return;

	// Respawning inside the death event does not stick, so wait a beat.
	CreateTimer(0.1, Timer_Respawn, GetClientUserId(client), TIMER_FLAG_NO_MAPCHANGE);
}

// An FJ round runs up to an hour and CS:GO only spawns a joiner at round start, so anyone
// connecting or leaving spectate mid-round sat dead until the round turned over. Same path
// as a death. Fires on connect and disconnect too; Timer_Respawn's checks filter those.
public void Event_PlayerTeam(Event event, const char[] name, bool dontBroadcast) {
	if(!g_bFJ || event.GetBool("disconnect"))
		return;

	int client = GetClientOfUserId(event.GetInt("userid"));
	if(!IsValidClient(client))
		return;

	CreateTimer(0.1, Timer_Respawn, GetClientUserId(client), TIMER_FLAG_NO_MAPCHANGE);
}

public Action Timer_Respawn(Handle timer, int iUserId) {
	int client = GetClientOfUserId(iUserId);

	// A player who moved to spectate between dying and this firing stays there.
	if(g_bFJ && IsValidClient(client) && !IsPlayerAlive(client) && GetClientTeam(client) > CS_TEAM_SPECTATOR)
		CS_RespawnPlayer(client);

	return Plugin_Stop;
}

// ---------------------------------------------------------------- mode state

bool MixActive() {
	return (GetFeatureStatus(FeatureType_Native, "kev_isMixActive") == FeatureStatus_Available && kev_isMixActive() != 0);
}

// A mix owns the round flow and FJ holds the clock open for an hour, so the two cannot share
// a server. Checked on a timer because a mix can start at any moment, not just on a round
// boundary. Turning FJ off restarts the round, handing mp_roundtime back to hnsmix.
public Action Timer_FJMixWatch(Handle timer) {
	if(g_bFJ && MixActive())
		SetFJ(false, "a mix is starting");

	// A running vote is equally pointless once a mix owns the server.
	if(g_bFJVoteActive && MixActive() && IsVoteInProgress()) {
		g_bFJVoteActive = false;
		CancelVote();
		PrintToChatAll("%sFJ vote cancelled: a mix is starting.", g_sPrefix);
	}

	return Plugin_Continue;
}

void SetFJ(bool enable, const char[] reason) {
	if(g_bFJ == enable)
		return;

	g_bFJ = enable;

	// Both directions restart the round. On, so the full FJ clock starts now instead of
	// inheriting the current round; off, so hnsmix and hnsova rebuild on their own terms,
	// both re-applying their round length from round_start.
	ServerCommand("mp_restartgame 1");

	if(enable) {
		ApplyFJRoundTime();
		PrintToChatAll("%sFunjump is \x04on\x01 (%s). Rounds run \x04%d\x01 minutes and FJ carries across them until it is voted off. Type \x04!fj\x01 for the menu.", g_sPrefix, reason, RoundToNearest(g_cvTime.FloatValue));
	}
	else {
		PrintToChatAll("%sFunjump is \x0Foff\x01 (%s).", g_sPrefix, reason);
	}

	// The embed sidebar goes red for FJ, so tell it the moment the state flips, not on the 90s net.
	if(GetFeatureStatus(FeatureType_Native, "kev_refreshMixStatus") == FeatureStatus_Available)
		kev_refreshMixStatus();

	for(int i = 1; i <= MaxClients; i++) {
		if(!IsValidClient(i))
			continue;

		// Fresh session starts everyone protected. Not per respawn, or godmode off would last until the next death.
		if(enable)
			g_bGod[i] = true;

		ApplyFJState(i, enable);
	}
}

// Everything that has to be set on a player when FJ turns on or off.
void ApplyFJState(int client, bool enable) {
	if(!enable) {
		g_bNoclip[client] = false;
		if(IsPlayerAlive(client) && GetEntityMoveType(client) == MOVETYPE_NOCLIP)
			SetEntityMoveType(client, MOVETYPE_WALK);
	}

	if(!IsPlayerAlive(client))
		return;

	// 2 is COLLISION_GROUP_DEBRIS_TRIGGER: passes through every player while still colliding with the world. 5 is default.
	if(g_cvNoCollide.BoolValue)
		SetEntProp(client, Prop_Send, "m_CollisionGroup", enable ? 2 : 5);

	SetEntProp(client, Prop_Data, "m_takedamage", (enable && g_cvGodmode.BoolValue && g_bGod[client]) ? 0 : 2, 1);
}

// mp_roundtime only applies from the NEXT round, so the current round is pinned on the game
// rules entity too - the HUD clock shows (m_fRoundStartTime + m_iRoundTime - now).
// Re-applied every round on purpose: hnsmix re-asserts its own and hnsova pins ten minutes
// for OVA, so FJ has to claim the clock back each time.
void ApplyFJRoundTime() {
	ConVar cvar = FindConVar("mp_roundtime");
	if(cvar != null)
		cvar.SetFloat(g_cvTime.FloatValue);

	cvar = FindConVar("mp_roundtime_defuse");
	if(cvar != null)
		cvar.SetFloat(g_cvTime.FloatValue);

	cvar = FindConVar("mp_roundtime_hostage");
	if(cvar != null)
		cvar.SetFloat(g_cvTime.FloatValue);

	GameRules_SetProp("m_iRoundTime", RoundToNearest(g_cvTime.FloatValue * 60.0));
}

// Post, deliberately: hnsmix hooks round_start as Pre and always runs first. Writing from
// Post means FJ writes last and its round length survives.
public void Event_RoundStart(Event event, const char[] name, bool dontBroadcast) {
	if(g_bFJ)
		ApplyFJRoundTime();
}

// ------------------------------------------------------------------ commands

public Action Command_FJ(int client, int args) {
	if(client == 0) {
		ReplyToCommand(client, "[FJ] This command must be used in-game.");
		return Plugin_Handled;
	}

	// The menu opens for everyone now: with FJ off it carries the vote entry, which is what a player wants.
	OpenFJMenu(client);
	return Plugin_Handled;
}

public Action Command_VoteFJ(int client, int args) {
	if(client == 0) {
		ReplyToCommand(client, "[FJ] This command must be used in-game.");
		return Plugin_Handled;
	}
	if(IsVoteInProgress()) {
		PrintToChat(client, "%sA vote is already running.", g_sPrefix);
		return Plugin_Handled;
	}

	// The vote always proposes the opposite of what is running, so one command toggles FJ.
	g_bFJVoteWantsOn = !g_bFJ;

	// Only switching it ON needs the mix gate; stopping is always allowed.
	if(g_bFJVoteWantsOn && !CanEnableFJ(client))
		return Plugin_Handled;

	// Vote actions are not in the default action mask, so ask for them.
	Menu menu = new Menu(VoteHandler, MenuAction_End|MenuAction_VoteEnd|MenuAction_VoteCancel);
	menu.SetTitle(g_bFJVoteWantsOn ? "Enable Funjump mode?" : "Disable Funjump mode?");
	menu.AddItem("y", "Yes");
	menu.AddItem("n", "No");
	menu.ExitButton = false;
	menu.DisplayVoteToAll(20);
	g_bFJVoteActive = true;

	PrintToChatAll("%s\x04%N\x01 started a vote to \x04%s\x01 Funjump mode.", g_sPrefix, client, g_bFJVoteWantsOn ? "enable" : "disable");
	return Plugin_Handled;
}

public Action Command_ForceFJ(int client, int args) {
	char sArg[8];
	if(args >= 1)
		GetCmdArg(1, sArg, sizeof(sArg));

	bool bWant = (args >= 1) ? (StrEqual(sArg, "on", false) || StrEqual(sArg, "start", false)) : !g_bFJ;

	if(bWant && !CanEnableFJ(client))
		return Plugin_Handled;

	if(bWant == g_bFJ) {
		ReplyToCommand(client, "%sFunjump is already %s.", g_sPrefix, g_bFJ ? "on" : "off");
		return Plugin_Handled;
	}

	SetFJ(bWant, "admin");
	return Plugin_Handled;
}

// Single gate for turning FJ on. Replying here keeps the mix check out of all three callers.
bool CanEnableFJ(int client) {
	if(g_bFJ) {
		ReplyToCommand(client, "%sFunjump is already on.", g_sPrefix);
		return false;
	}
	if(MixActive()) {
		ReplyToCommand(client, "%sA mix is running. Funjump cannot be started now.", g_sPrefix);
		return false;
	}
	return true;
}

bool IsFJAdmin(int client) {
	return CheckCommandAccess(client, "sm_forcefj", ADMFLAG_GENERIC, false);
}

// ---------------------------------------------------------------------- vote

public int VoteHandler(Menu menu, MenuAction action, int param1, int param2) {
	switch(action) {
		case MenuAction_End: delete menu;

		case MenuAction_VoteCancel: {
			g_bFJVoteActive = false;
			if(param1 == VoteCancel_NoVotes)
				PrintToChatAll("%sNobody voted, Funjump stays off.", g_sPrefix);
		}

		case MenuAction_VoteEnd: {
			g_bFJVoteActive = false;

			int iVotes, iTotal;
			GetMenuVoteInfo(param2, iVotes, iTotal);

			// param1 is the winning item; when No wins, flip the count so iVotes is always the yes tally.
			if(param1 == 1)
				iVotes = iTotal - iVotes;

			// Strict majority of everyone in game, not of everyone who answered, so ignoring the menu counts as no.
			int iPlayers = CountVoters();
			int iNeeded = (iPlayers / 2) + 1;

			// Enabling still has to clear the mix gate when the vote lands, not just when it started.
			if(iVotes >= iNeeded && (!g_bFJVoteWantsOn || CanEnableFJ(0))) {
				char sReason[32];
				FormatEx(sReason, sizeof(sReason), "vote passed %d/%d", iVotes, iPlayers);
				SetFJ(g_bFJVoteWantsOn, sReason);
			}
			else {
				PrintToChatAll("%sVote failed: \x04%d\x01 of %d voted yes, \x04%d\x01 needed.", g_sPrefix, iVotes, iPlayers, iNeeded);
			}
		}
	}
	return 0;
}

// ---------------------------------------------------------------------- menu

void OpenFJMenu(int client) {
	// With FJ off there is nothing here for an admin except Admin Options, so go straight there
	// instead of making them click through a single-item menu.
	if(!g_bFJ && IsFJAdmin(client)) {
		OpenFJAdminMenu(client);
		return;
	}

	Menu menu = new Menu(FJMenuHandler);
	menu.SetTitle("[FJ] Menu Selection");

	if(g_bFJ) {
		char sItem[64];

		menu.AddItem("save", "Save Location", g_cvTeleport.BoolValue ? ITEMDRAW_DEFAULT : ITEMDRAW_DISABLED);
		menu.AddItem("tp", "Teleport to Location", (g_cvTeleport.BoolValue && g_bSaved[client]) ? ITEMDRAW_DEFAULT : ITEMDRAW_DISABLED);

		FormatEx(sItem, sizeof(sItem), "NoClip: %s", g_bNoclip[client] ? "On" : "Off");
		menu.AddItem("nc", sItem, g_cvNoclip.BoolValue ? ITEMDRAW_DEFAULT : ITEMDRAW_DISABLED);

		FormatEx(sItem, sizeof(sItem), "GodMode: %s", g_bGod[client] ? "On" : "Off");
		menu.AddItem("god", sItem, g_cvGodmode.BoolValue ? ITEMDRAW_DEFAULT : ITEMDRAW_DISABLED);

		bool bSpec = (GetClientTeam(client) == CS_TEAM_SPECTATOR);
		menu.AddItem("spec", bSpec ? "Return to play" : "Spectate", g_cvSpectate.BoolValue ? ITEMDRAW_DEFAULT : ITEMDRAW_DISABLED);

		menu.AddItem("respawn", "Self-Respawn");
	}

	// Admins get one entry that opens everything; players get the vote directly. Both land on
	// exactly 7 items, the most a menu page holds - an eighth pushes Exit to page two.
	if(IsFJAdmin(client))
		menu.AddItem("admin", "Admin Options");
	else
		menu.AddItem("vote", g_bFJ ? "Vote to Disable FJ" : "Vote to Enable FJ",
			g_bFJVoteActive ? ITEMDRAW_DISABLED : ITEMDRAW_DEFAULT);

	menu.ExitButton = true;
	menu.Display(client, MENU_TIME_FOREVER);
}

void OpenFJAdminMenu(int client) {
	Menu menu = new Menu(FJAdminMenuHandler);
	menu.SetTitle("[FJ] Admin Options");

	menu.AddItem("toggle", g_bFJ ? "Disable FJ" : "Enable FJ");

	// Above the vote entry: with one running this is what an admin reaches for.
	if(g_bFJVoteActive)
		menu.AddItem("cancelvote", "Cancel FJ Vote");

	menu.AddItem("vote", g_bFJ ? "Start Vote to Disable FJ" : "Start Vote to Enable FJ",
		g_bFJVoteActive ? ITEMDRAW_DISABLED : ITEMDRAW_DEFAULT);

	if(g_bFJ) {
		menu.AddItem("respawnothers", "Respawn Others");
		menu.AddItem("noclipothers", "NoClip for Others");
		menu.AddItem("godothers", "GodMode for Others");
	}

	// With FJ off this IS the top-level menu, so there is nothing behind it.
	menu.ExitBackButton = g_bFJ;
	menu.Display(client, MENU_TIME_FOREVER);
}

public int FJAdminMenuHandler(Menu menu, MenuAction action, int client, int item) {
	if(action == MenuAction_End) {
		delete menu;
		return 0;
	}
	if(action == MenuAction_Cancel) {
		if(item == MenuCancel_ExitBack && IsClientInGame(client))
			OpenFJMenu(client);
		return 0;
	}
	if(action != MenuAction_Select || !IsClientInGame(client) || !IsFJAdmin(client))
		return 0;

	char sInfo[16];
	menu.GetItem(item, sInfo, sizeof(sInfo));

	if(StrEqual(sInfo, "toggle")) {
		if(g_bFJ)
			SetFJ(false, "admin");
		else if(CanEnableFJ(client))
			SetFJ(true, "admin");
	}
	else if(StrEqual(sInfo, "cancelvote")) {
		CancelFJVote(client);
	}
	else if(StrEqual(sInfo, "vote")) {
		FakeClientCommand(client, "sm_votefj");
		return 0; // the vote panel replaces the menu
	}
	else if(StrEqual(sInfo, "respawnothers")) {
		OpenTargetMenu(client, "respawn");
		return 0;
	}
	else if(StrEqual(sInfo, "noclipothers")) {
		OpenTargetMenu(client, "noclip");
		return 0;
	}
	else if(StrEqual(sInfo, "godothers")) {
		OpenTargetMenu(client, "god");
		return 0;
	}

	OpenFJAdminMenu(client);
	return 0;
}

public int FJMenuHandler(Menu menu, MenuAction action, int client, int item) {
	if(action == MenuAction_End) {
		delete menu;
		return 0;
	}
	if(action != MenuAction_Select || !IsValidClient(client))
		return 0;

	char sInfo[16];
	menu.GetItem(item, sInfo, sizeof(sInfo));

	if(StrEqual(sInfo, "vote")) {
		FakeClientCommand(client, "sm_votefj");
		return 0;
	}

	if(StrEqual(sInfo, "admin")) {
		if(IsFJAdmin(client))
			OpenFJAdminMenu(client);
		return 0;
	}

	// Everything below needs FJ still running and the player alive.
	if(!g_bFJ) {
		PrintToChat(client, "%sFunjump is no longer on.", g_sPrefix);
		return 0;
	}

	if(StrEqual(sInfo, "save"))
		SaveLocation(client);
	else if(StrEqual(sInfo, "tp"))
		Teleport(client);
	else if(StrEqual(sInfo, "nc"))
		ToggleNoclip(client);
	else if(StrEqual(sInfo, "spec"))
		ToggleSpectate(client);
	else if(StrEqual(sInfo, "god"))
		ToggleGodmode(client);
	else if(StrEqual(sInfo, "respawn"))
		RespawnAtSpawn(client, client);

	OpenFJMenu(client);
	return 0;
}

// ------------------------------------------------------------------- actions

void SaveLocation(int client) {
	if(!IsPlayerAlive(client)) {
		PrintToChat(client, "%sYou must be alive to save a location.", g_sPrefix);
		return;
	}

	GetClientAbsOrigin(client, g_fPos[client]);
	GetClientEyeAngles(client, g_fAng[client]);
	g_bSaved[client] = true;
	PrintToChat(client, "%sLocation saved.", g_sPrefix);
}

void Teleport(int client) {
	if(!IsPlayerAlive(client)) {
		PrintToChat(client, "%sYou must be alive to teleport.", g_sPrefix);
		return;
	}
	if(!g_bSaved[client]) {
		PrintToChat(client, "%sNo saved location.", g_sPrefix);
		return;
	}
	if(!IsValidPlayerPos(client, g_fPos[client])) {
		PrintToChat(client, "%sSomething is in the way, cannot teleport there.", g_sPrefix);
		return;
	}

	float fZero[3] = {0.0, 0.0, 0.0};
	TeleportEntity(client, g_fPos[client], g_fAng[client], fZero);
	PrintToChat(client, "%sTeleported.", g_sPrefix);
}

void ToggleNoclip(int client) {
	if(!IsPlayerAlive(client)) {
		PrintToChat(client, "%sYou must be alive to use noclip.", g_sPrefix);
		return;
	}

	g_bNoclip[client] = !g_bNoclip[client];
	SetEntityMoveType(client, g_bNoclip[client] ? MOVETYPE_NOCLIP : MOVETYPE_WALK);
	PrintToChat(client, "%sNoclip is now \x04%s\x01.", g_sPrefix, g_bNoclip[client] ? "on" : "off");
}

// Back to a team spawn. Works on a living player, which is the point in FJ: the way out of a noclip trap.
void RespawnAtSpawn(int iAdmin, int iTarget) {
	if(!IsClientInGame(iTarget) || GetClientTeam(iTarget) <= CS_TEAM_SPECTATOR) {
		PrintToChat(iAdmin, "%sThat player is not on a team.", g_sPrefix);
		return;
	}

	CS_RespawnPlayer(iTarget);

	if(iAdmin == iTarget) {
		PrintToChat(iTarget, "%sRespawned at your team spawn.", g_sPrefix);
		return;
	}

	PrintToChat(iTarget, "%sAn admin respawned you.", g_sPrefix);
	PrintToChat(iAdmin, "%sRespawned \x04%N\x01.", g_sPrefix, iTarget);
}

// One target picker for every admin action. sAction rides in the info string so the handler
// needs no state, which stops a menu left open across a round change applying the wrong thing.
void OpenTargetMenu(int client, const char[] sAction) {
	Menu menu = new Menu(RespawnMenuHandler);

	if(StrEqual(sAction, "noclip"))
		menu.SetTitle("[FJ] NoClip for Others");
	else if(StrEqual(sAction, "god"))
		menu.SetTitle("[FJ] GodMode for Others");
	else
		menu.SetTitle("[FJ] Respawn Others");

	char sInfo[32], sName[MAX_NAME_LENGTH], sLabel[96];
	FormatEx(sInfo, sizeof(sInfo), "%s:all", sAction);
	menu.AddItem(sInfo, "Everyone");

	for(int i = 1; i <= MaxClients; i++) {
		if(!IsClientInGame(i) || IsFakeClient(i) || GetClientTeam(i) <= CS_TEAM_SPECTATOR)
			continue;

		// Userid, not client index: the menu can outlive a disconnect.
		FormatEx(sInfo, sizeof(sInfo), "%s:%d", sAction, GetClientUserId(i));
		GetClientName(i, sName, sizeof(sName));

		// Toggles show the target's current state; respawn has none to show.
		if(StrEqual(sAction, "noclip"))
			FormatEx(sLabel, sizeof(sLabel), "%s (%s)", sName, g_bNoclip[i] ? "On" : "Off");
		else if(StrEqual(sAction, "god"))
			FormatEx(sLabel, sizeof(sLabel), "%s (%s)", sName, g_bGod[i] ? "On" : "Off");
		else
			strcopy(sLabel, sizeof(sLabel), sName);

		menu.AddItem(sInfo, sLabel);
	}

	menu.ExitBackButton = true;
	menu.Display(client, MENU_TIME_FOREVER);
}

// Applies one admin action to one target, and reports to both sides.
void ApplyTargetAction(int iAdmin, int iTarget, const char[] sAction, bool bQuiet = false) {
	if(!IsClientInGame(iTarget) || GetClientTeam(iTarget) <= CS_TEAM_SPECTATOR)
		return;

	if(StrEqual(sAction, "noclip")) {
		if(!IsPlayerAlive(iTarget))
			return;
		g_bNoclip[iTarget] = !g_bNoclip[iTarget];
		SetEntityMoveType(iTarget, g_bNoclip[iTarget] ? MOVETYPE_NOCLIP : MOVETYPE_WALK);
		PrintToChat(iTarget, "%sAn admin set your noclip \x04%s\x01.", g_sPrefix, g_bNoclip[iTarget] ? "on" : "off");
		if(!bQuiet)
			PrintToChat(iAdmin, "%sNoclip \x04%s\x01 for \x04%N\x01.", g_sPrefix, g_bNoclip[iTarget] ? "on" : "off", iTarget);
		return;
	}

	if(StrEqual(sAction, "god")) {
		g_bGod[iTarget] = !g_bGod[iTarget];
		if(IsPlayerAlive(iTarget))
			SetEntProp(iTarget, Prop_Data, "m_takedamage", g_bGod[iTarget] ? 0 : 2, 1);
		PrintToChat(iTarget, "%sAn admin set your godmode \x04%s\x01.", g_sPrefix, g_bGod[iTarget] ? "on" : "off");
		if(!bQuiet)
			PrintToChat(iAdmin, "%sGodmode \x04%s\x01 for \x04%N\x01.", g_sPrefix, g_bGod[iTarget] ? "on" : "off", iTarget);
		return;
	}

	RespawnAtSpawn(iAdmin, iTarget);
}

public int RespawnMenuHandler(Menu menu, MenuAction action, int client, int item) {
	if(action == MenuAction_End) {
		delete menu;
		return 0;
	}
	if(action == MenuAction_Cancel) {
		// Back goes to the admin menu, which is where this was opened from.
		if(item == MenuCancel_ExitBack && IsClientInGame(client))
			OpenFJAdminMenu(client);
		return 0;
	}
	if(action != MenuAction_Select || !IsClientInGame(client) || !IsFJAdmin(client))
		return 0;

	char sInfo[32], sParts[2][24];
	menu.GetItem(item, sInfo, sizeof(sInfo));
	if(ExplodeString(sInfo, ":", sParts, sizeof(sParts), sizeof(sParts[])) != 2)
		return 0;

	if(StrEqual(sParts[1], "all")) {
		int iCount = 0;
		for(int i = 1; i <= MaxClients; i++) {
			if(IsClientInGame(i) && !IsFakeClient(i) && GetClientTeam(i) > CS_TEAM_SPECTATOR) {
				ApplyTargetAction(client, i, sParts[0], true);
				iCount++;
			}
		}
		PrintToChat(client, "%sApplied to \x04%d\x01 player(s).", g_sPrefix, iCount);
	}
	else {
		int iTarget = GetClientOfUserId(StringToInt(sParts[1]));
		if(iTarget > 0 && IsClientInGame(iTarget))
			ApplyTargetAction(client, iTarget, sParts[0]);
		else
			PrintToChat(client, "%sThat player has left.", g_sPrefix);
	}

	OpenTargetMenu(client, sParts[0]);
	return 0;
}

// Cancels our own vote only. CancelVote() would kill an unrelated one, so the flag gates it.
void CancelFJVote(int client) {
	if(!g_bFJVoteActive || !IsVoteInProgress()) {
		ReplyToCommand(client, "%sThere is no FJ vote running.", g_sPrefix);
		return;
	}

	g_bFJVoteActive = false;
	CancelVote();
	PrintToChatAll("%sThe FJ vote was cancelled by an admin.", g_sPrefix);
}

// One command for "make FJ stop": ends a running vote, or turns FJ off.
public Action Command_CancelFJ(int client, int args) {
	if(g_bFJVoteActive && IsVoteInProgress()) {
		CancelFJVote(client);
		return Plugin_Handled;
	}

	if(!g_bFJ) {
		ReplyToCommand(client, "%sFunjump is already off and no vote is running.", g_sPrefix);
		return Plugin_Handled;
	}

	SetFJ(false, "admin");
	return Plugin_Handled;
}

void ToggleGodmode(int client) {
	g_bGod[client] = !g_bGod[client];

	if(IsPlayerAlive(client))
		SetEntProp(client, Prop_Data, "m_takedamage", g_bGod[client] ? 0 : 2, 1);

	PrintToChat(client, "%sGodmode is now \x04%s\x01.", g_sPrefix, g_bGod[client] ? "on" : "off");
}

void ToggleSpectate(int client) {
	if(GetClientTeam(client) != CS_TEAM_SPECTATOR) {
		SaveLocation(client);
		ChangeClientTeam(client, CS_TEAM_SPECTATOR);
		PrintToChat(client, "%sMoved to spectate.", g_sPrefix);
		return;
	}

	ChangeClientTeam(client, CS_TEAM_T);
	CS_RespawnPlayer(client);
	if(g_bSaved[client])
		Teleport(client);
	PrintToChat(client, "%sBack in play.", g_sPrefix);
}

// -------------------------------------------------------------- admin menu

public void OnAdminMenuReady(Handle aTopMenu) {
	TopMenu topmenu = TopMenu.FromHandle(aTopMenu);
	if(topmenu == g_hTopMenu)
		return;

	g_hTopMenu = topmenu;

	TopMenuObject oCat = g_hTopMenu.FindCategory("KevFJ");
	if(oCat == INVALID_TOPMENUOBJECT)
		oCat = g_hTopMenu.AddCategory("KevFJ", AdminCatHandler, "sm_forcefj", ADMFLAG_GENERIC);

	if(oCat == INVALID_TOPMENUOBJECT)
		return;

	g_hTopMenu.AddItem("kevfj_on", AdminItemHandler, oCat, "sm_forcefj", ADMFLAG_GENERIC);
	g_hTopMenu.AddItem("kevfj_off", AdminItemHandler, oCat, "sm_forcefj", ADMFLAG_GENERIC);
	g_hTopMenu.AddItem("kevfj_vote", AdminItemHandler, oCat, "sm_votefj", ADMFLAG_GENERIC);
}

public void AdminCatHandler(TopMenu topmenu, TopMenuAction action, TopMenuObject object_id, int param, char[] buffer, int maxlength) {
	if(action == TopMenuAction_DisplayTitle || action == TopMenuAction_DisplayOption)
		Format(buffer, maxlength, "Funjump");
}

public void AdminItemHandler(TopMenu topmenu, TopMenuAction action, TopMenuObject object_id, int param, char[] buffer, int maxlength) {
	char sName[32];
	topmenu.GetObjName(object_id, sName, sizeof(sName));

	if(action == TopMenuAction_DisplayOption) {
		if(StrEqual(sName, "kevfj_on"))
			Format(buffer, maxlength, "Force FJ On");
		else if(StrEqual(sName, "kevfj_off"))
			Format(buffer, maxlength, "Force FJ Off");
		else
			Format(buffer, maxlength, "Start FJ Vote");
	}
	else if(action == TopMenuAction_SelectOption) {
		if(StrEqual(sName, "kevfj_on")) {
			if(CanEnableFJ(param))
				SetFJ(true, "admin");
		}
		else if(StrEqual(sName, "kevfj_off")) {
			SetFJ(false, "admin");
		}
		else {
			FakeClientCommand(param, "sm_votefj");
		}

		topmenu.Display(param, TopMenuPosition_LastCategory);
	}
}

// -------------------------------------------------------------------- utils

bool IsValidPlayerPos(int client, float fPos[3]) {
	static const float fMins[3] = {-16.0, -16.0, 0.0};
	static const float fMaxs[3] = {16.0, 16.0, 72.0};

	TR_TraceHullFilter(fPos, fPos, fMins, fMaxs, MASK_SOLID, TraceFilter_IgnoreSelf, client);
	return !TR_DidHit(null);
}

public bool TraceFilter_IgnoreSelf(int entity, int mask, any data) {
	// Every player passes through during FJ, so only the world blocks a teleport. gstrafe filter minus the teammate test.
	if(entity == data)
		return false;

	if(0 < entity <= MaxClients)
		return false;

	return true;
}

// Everyone the vote menu was shown to. Never zero, or an empty server would need a yes from nobody.
int CountVoters() {
	int iCount = 0;

	for(int i = 1; i <= MaxClients; i++) {
		if(IsValidClient(i))
			iCount++;
	}

	return (iCount < 1) ? 1 : iCount;
}

bool IsValidClient(int client) {
	return (0 < client <= MaxClients && IsClientInGame(client) && !IsFakeClient(client));
}
