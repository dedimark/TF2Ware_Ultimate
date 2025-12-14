// Purpose of this plugin:
// - set sv_cheats 1 for the duration of the map
// - allow vscript to control host_timescale
// - block cheat commands and impulses on the server-side, as sv_cheats is required for host_timescale modification
// - use tournament whitelist system to block weapons/body cosmetics/taunts to prevent spawn lagspikes

#define LOADOUT_WHITELISTER 1

#include <sourcemod>
#include <sdktools>
#include <morecolors>

#define PLUGIN_NAME "TF2Ware Ultimate"
// if changing this, change it in VScript's config.nut too
#define PLUGIN_VERSION "1.3.0 save-scores"

// unused event repurposed for vscript <-> sourcemod communication
#define PROXY_EVENT "tf_map_time_remaining"

Database g_Database;
bool g_FirstSpawn[MAXPLAYERS + 1];

public Plugin myinfo =
{
	name        = PLUGIN_NAME,
	author      = "ficool2",
	description = "Dedicated functionality for TF2Ware Ultimate",
	version     = PLUGIN_VERSION,
	url         = "https://github.com/ficool2/TF2Ware_Ultimate"
};

#if LOADOUT_WHITELISTER
#include "loadout-whitelister.sp"
#endif

bool g_Enabled = false;

ArrayList g_CheatCommands;
ArrayList g_CheatCommandsArgs;
int g_CheatImpulses[] = { 76, 81, 82, 83, 101, 102, 103, 106, 107, 108, 195, 196, 197, 200, 202, 203 };

int g_TextProxy = INVALID_ENT_REFERENCE;

float g_ScriptPerfValue = 1.5;
float g_AntiFloodValue = 0.0;

ConVar host_timescale;
ConVar vscript_perf_warning_spew_ms;
ConVar datacachesize;
ConVar sv_cheats;
ConVar sm_flood_time;

//ConVar ware_version;
ConVar ware_cheats;
ConVar ware_log_cheats;

bool ShouldEnable()
{
	// TODO check how this behaves with workshop maps
	char map_name[PLATFORM_MAX_PATH];
	GetCurrentMap(map_name, sizeof(map_name));
	return StrContains(map_name, "tf2ware_ultimate", false) != -1;
}

Action ListenerCheatCommand(int client, const char[] command, int argc)
{
	if (!ware_cheats.BoolValue && client > 0)	
	{
		if (ware_log_cheats.BoolValue)
		{
			char name[MAX_NAME_LENGTH];
			GetClientName(client, name, sizeof(name));
			PrintToServer("Client '%s' attempted to execute cheat command '%s'", name, command);
		}
		return Plugin_Handled;
	}
	return Plugin_Continue;
}

Action ListenerCheatCommandArgs(int client, const char[] command, int argc)
{
	if (!ware_cheats.BoolValue && argc >= 1)
	{
		if (ware_log_cheats.BoolValue)
		{
			char name[MAX_NAME_LENGTH];
			GetClientName(client, name, sizeof(name));
			PrintToServer("Client '%s' attempted to execute cheat command '%s'", name, command);	
		}		
		return Plugin_Handled;
	}
	return Plugin_Continue;
}

public Action ListenerVScript(Event event, const char[] name, bool dontBroadcast)
{
	char id[32];
	event.GetString("id", id, sizeof(id), "");
	if (StrEqual(id, "tf2ware_ultimate"))
	{
		char routine[64];
		event.GetString("routine", routine, sizeof(routine), "");
		
		if (StrEqual(routine, "timescale"))
		{
			host_timescale.SetFloat(event.GetFloat("value", 1.0), true, false);
		}
		else if (StrEqual(routine, "loadout_on"))
		{
#if LOADOUT_WHITELISTER
			script_allow_loadout = true;
#endif
		}
		else if (StrEqual(routine, "loadout_off"))
		{
#if LOADOUT_WHITELISTER
			script_allow_loadout = false;
#endif
		}
		else if (StrEqual(routine, "flood_off"))
		{
			if (sm_flood_time != INVALID_HANDLE)
			{
				g_AntiFloodValue = sm_flood_time.FloatValue;
				sm_flood_time.SetFloat(-1.0);
			}	
		}	
		else if (StrEqual(routine, "flood_on"))
		{
			if (sm_flood_time != INVALID_HANDLE)
			{
				sm_flood_time.SetFloat(g_AntiFloodValue);
			}
		} else if (StrEqual(routine, "game_over")) {
			char scores[512];
			event.GetString("players_score", scores, sizeof(scores), "");
			
			for(int i = 0; i < sizeof(scores) && scores[i] != '\0'; i++) {
				int client = i + 1;
				int score = scores[i];
				StoreScore(client, score);
			}
		} else if (StrEqual(routine, "updatescore")) {
			char player[16];
			event.GetString("player", player, sizeof(player), "");

			int target = StringToInt(player);
			int score = event.GetInt("score", 0);

			StoreScore(target, score);
		} else {
			//LogMessage("Unknown VScript routine '%s'", routine);
		}
		
		return Plugin_Handled;
	}
	
	return Plugin_Continue;
}

public Action OnClientSayCommand(int client, const char[] command, const char[] sArgs)
{	
	int proxy = EntRefToEntIndex(g_TextProxy);
	if (proxy == INVALID_ENT_REFERENCE)
	{
		proxy = FindEntityByClassname(-1, "ware_textproxy");
		if (proxy != -1)
			g_TextProxy = EntIndexToEntRef(proxy);
	}
	
	if (IsValidEntity(proxy))
	{
		// ask vscript whether to hide the message
		SetEntPropEnt(proxy, Prop_Data, "m_hDamageFilter", client);
		SetEntPropString(proxy, Prop_Send, "m_szText", sArgs);
		SetVariantString("Ware_OnPlayerSayProxy");
		AcceptEntityInput(proxy, "CallScriptFunction", client, client);
		int show = GetEntProp(proxy, Prop_Data, "m_iHammerID");
		if (show == 1)
			return Plugin_Handled;
	}
	
	return Plugin_Continue;
}

public void OnCheatsChanged(ConVar convar, const char[] oldValue, const char[] newValue)
{
	// cheats must be enabled for host_timescale to function
	sv_cheats.SetInt(1, true, false);
}

public Action HookVoiceCommand(UserMsg msg_id, BfRead bf, const int[] players, int playersNum, bool reliable, bool init)
{
	return Plugin_Handled;
}

void Enable()
{
	if (g_Enabled || !ShouldEnable())
		return;
	g_Enabled = true;
	
	PrintToServer("Enabling...");
	
#if LOADOUT_WHITELISTER
	GameData gamedata = LoadGameConfigFile("tf2-ware-ultimate");
	if (gamedata)	
	{
		LoadoutWhitelister_Start(gamedata);
	}
	else
	{
		LogError("Failed to retrieve 'tf2-ware-ultimate' gamedata, loadout caching will be unavailable");	
	}
	delete gamedata;
#endif

	host_timescale = FindConVar("host_timescale");
	vscript_perf_warning_spew_ms = FindConVar("vscript_perf_warning_spew_ms");
	sv_cheats = FindConVar("sv_cheats");
	sm_flood_time = FindConVar("sm_flood_time");
	
	host_timescale.SetFloat(1.0, true, false);
	sv_cheats.SetInt(1, true, false);
	
	// bump this because loading minigames from disk frequently takes a few ms and clogs the log
	if (vscript_perf_warning_spew_ms.FloatValue < 10.0)
	{
		g_ScriptPerfValue = vscript_perf_warning_spew_ms.FloatValue;
		vscript_perf_warning_spew_ms.SetFloat(10.0, false, false);
	}
	
	HookConVarChange(sv_cheats, OnCheatsChanged);
	
	CreateConVar("ware_version", PLUGIN_VERSION, "TF2Ware Ultimate plugin version");
	ware_cheats = CreateConVar("ware_cheats", "0", "Enable sv_cheats commands");
	ware_log_cheats = CreateConVar("ware_log_cheats", "1", "Log cheat command attempts");
	
	// unused event repurposed for vscript <-> sourcemod communication
	HookEvent(PROXY_EVENT, ListenerVScript, EventHookMode_Pre);
	
	HookUserMessage(GetUserMessageId("VoiceSubtitle"), HookVoiceCommand, true);

	char name[64];
	char description[128];
	bool is_command;
	int flags;
	
	Handle hConCommandIter = FindFirstConCommand(name, sizeof(name), is_command, flags, description, sizeof(description));
	do 
	{
		if (is_command && (flags & FCVAR_CHEAT))
		{	
			AddCommandListener(ListenerCheatCommand, name);
			g_CheatCommands.PushString(name);
		}
	} 
	while ( FindNextConCommand(hConCommandIter, name, sizeof(name), is_command, flags, description, sizeof(description)));
	
	// special cases
	g_CheatCommands.PushString("give");	
	g_CheatCommands.PushString("te");
	g_CheatCommands.PushString("addcond");	
	g_CheatCommands.PushString("removecond");	
	g_CheatCommands.PushString("mp_playgesture");	
	g_CheatCommands.PushString("mp_playanimation");	
	for (int i = 0; i < g_CheatCommands.Length; i++)	
	{		
		g_CheatCommands.GetString(i, name, sizeof(name));
		AddCommandListener(ListenerCheatCommand, name);
	}
	
	g_CheatCommandsArgs.PushString("kill");	
	g_CheatCommandsArgs.PushString("explode");	
	g_CheatCommandsArgs.PushString("fov");		
	for (int i = 0; i < g_CheatCommandsArgs.Length; i++)	
	{		
		g_CheatCommandsArgs.GetString(i, name, sizeof(name));
		AddCommandListener(ListenerCheatCommandArgs, name);
	}

	RegConsoleCmd("sm_rank", Command_Rank, "Display your current rank in TF2Ware Ultimate.");
	RegConsoleCmd("sm_top", Command_Top, "Displays the top players of TF2Ware Ultimate in a menu.");
}

void Disable(bool map_unload)
{
	if (!g_Enabled)
		return;
	g_Enabled = false;
	
	PrintToServer("Disabling...");
	
#if LOADOUT_WHITELISTER
	LoadoutWhitelister_End(map_unload);
#endif

	host_timescale.SetFloat(1.0, true, false);
	sv_cheats.SetInt(0, true, false);
	vscript_perf_warning_spew_ms.SetFloat(g_ScriptPerfValue, false, false);
	
	UnhookConVarChange(sv_cheats, OnCheatsChanged);
	
	UnhookEvent(PROXY_EVENT, ListenerVScript, EventHookMode_Pre);
	
	UnhookUserMessage(GetUserMessageId("VoiceSubtitle"), HookVoiceCommand, true);
	
	// OnPluginEnd will clear these automatically
	if (map_unload)
	{
		char name[64];
		for (int i = 0; i < g_CheatCommands.Length; i++)
		{
			g_CheatCommands.GetString(i, name, sizeof(name));	
			RemoveCommandListener(ListenerCheatCommand, name);	
		}
		
		for (int i = 0; i < g_CheatCommandsArgs.Length; i++)
		{
			g_CheatCommandsArgs.GetString(i, name, sizeof(name));
			RemoveCommandListener(ListenerCheatCommandArgs, name);	
		}		
	}
	
	g_CheatCommands.Clear();
	g_CheatCommandsArgs.Clear();

}

public void OnClientPutInServer(int client)
{
	if (!g_Enabled)
		return;
		
#if LOADOUT_WHITELISTER
	LoadoutWhitelister_InitClient(client);
#endif
}

public void OnClientPostAdminCheck(int client)
{
	if (!g_Enabled)
		return;
	
	// allow admins to use dev commands
	if (CheckCommandAccess(client, "ware_admincheck", ADMFLAG_ROOT))
		SetEntProp(client, Prop_Data, "m_autoKickDisabled", 1);
}

public Action OnPlayerRunCmd(int client, int& buttons, int& impulse, float vel[3], float angles[3], int& weapon, int& subtype, int& cmdnum, int& tickcount, int& seed, int mouse[2])
{
	if (g_Enabled)
	{
		if (impulse > 0 && !ware_cheats.BoolValue)
		{
			for (int i = 0; i < sizeof(g_CheatImpulses); i++)
			{
				if (impulse == g_CheatImpulses[i])
				{
					if (ware_log_cheats.BoolValue)
					{
						char name[MAX_NAME_LENGTH];
						GetClientName(client, name, sizeof(name));
						PrintToServer("Client '%s' attempted to execute cheat impulse '%d'", name, impulse);		
					}					
					impulse = 0;					
					break;
				}
			}
		}
	}
	
	return Plugin_Continue;
}

public void OnPluginStart()
{
	Database.Connect(OnSQLConnect, "default");
	HookEvent("player_spawn", Event_OnPlayerSpawn);

	// tf2ware exhausts more than 256mb of model data
	// this has been the culprit of random server crashes on map load
	datacachesize = FindConVar("datacachesize");
	if (datacachesize.IntValue < 512)
		datacachesize.IntValue = 512;
	
	g_CheatCommands = new ArrayList(ByteCountToCells(64));
	g_CheatCommandsArgs = new ArrayList(ByteCountToCells(64));
	Enable();
}

public void OnPluginEnd()
{
	Disable(false);
}

public void OnMapStart()
{
	Enable();
	
#if LOADOUT_WHITELISTER
	LoadoutWhitelister_ReloadWhitelist();
#endif
}

public void OnMapEnd()
{
	Disable(true);
}

public void OnClientConnected(int client) {
	g_FirstSpawn[client] = true;
}

public void Event_OnPlayerSpawn(Event event, const char[] name, bool dontBroadcast) {
	int client = GetClientOfUserId(event.GetInt("userid"));

	if (client == 0 || !IsClientInGame(client) || IsFakeClient(client) || g_Database == null) {
		return;
	}

	if (!g_Enabled) {
		return;
	}

	if (!g_FirstSpawn[client]) {
		return;
	}

	g_FirstSpawn[client] = false;

	char query[256];
	g_Database.Format(query, sizeof(query), "SELECT score FROM ware_scores WHERE accountid = %d;", GetSteamAccountID(client));
	g_Database.Query(OnGetScore, query, GetClientUserId(client));
}

public void OnSQLConnect(Database db, const char[] error, int data) {
	if (db == null) {
		LogError("Failed to connect to SQL database: %s", error);
		return;
	}

	g_Database = db;
	PrintToServer("Connected to SQL database successfully.");

	g_Database.Query(OnCreateTable, "CREATE TABLE IF NOT EXISTS `ware_scores` (`id` INT AUTO_INCREMENT PRIMARY KEY, `accountid` INT NOT NULL UNIQUE, `name` VARCHAR(64) NOT NULL, `score` INT NOT NULL);");
}

public void OnCreateTable(Database db, DBResultSet results, const char[] error, any data) {
	if (results == null) {
		LogError("Failed to create table: %s", error);
	}
}

public void OnGetScore(Database db, DBResultSet results, const char[] error, int userid) {
	if (results == null) {
		LogError("Failed to get score: %s", error);
		return;
	}

	int client = GetClientOfUserId(userid);

	if (client == 0) {
		return;
	}

	while (results.FetchRow()) {
		Event event = CreateEvent("tf_map_time_remaining");
		event.SetBool("tf2ware_ultimate", true);
		event.SetString("routine", "score");
		event.SetInt("client", client);
		event.SetInt("score", results.FetchInt(0));
		event.Fire();
	}
}

public void StoreScore(int client, int score) {
	if (client < 1 || client > MaxClients || !IsClientInGame(client) || IsFakeClient(client) || g_Database == null) {
		return;
	}

	if (g_Database == null) {
		return;
	}

	char name[MAX_NAME_LENGTH];
	GetClientName(client, name, sizeof(name));

	int size = 2 * strlen(name) + 1;
	char[] escapedName = new char[size];
	g_Database.Escape(name, escapedName, size);

	char query[256];
	g_Database.Format(query, sizeof(query), "INSERT INTO `ware_scores` (`accountid`, `name`, `score`) VALUES (%d, '%s', %d) ON DUPLICATE KEY UPDATE name = '%s', `score` = `score` + %d;", GetSteamAccountID(client), escapedName, score, escapedName, score);
	g_Database.Query(OnStoreScore, query);
}

public void OnStoreScore(Database db, DBResultSet results, const char[] error, any data) {
	if (results == null) {
		LogError("Failed to store score: %s", error);
	}
}

public Action Command_Rank(int client, int args) {
	if (!g_Enabled || client == 0) {
		return Plugin_Handled;
	}

	char query[256];
	g_Database.Format(query, sizeof(query), "SELECT score, (SELECT COUNT(*) FROM ware_scores WHERE score > ws.score) + 1 AS rank, (SELECT COUNT(*) FROM ware_scores) AS total FROM ware_scores ws WHERE accountid = %d;", GetSteamAccountID(client));
	g_Database.Query(OnGetRank, query, GetClientUserId(client));

	return Plugin_Handled;
}

public void OnGetRank(Database db, DBResultSet results, const char[] error, any data) {
	if (results == null) {
		ThrowError("Failed to get a players rank: %s", error);
	}

	if (!results.FetchRow()) {
		return;
	}

    int client = GetClientOfUserId(data);
    int score = results.FetchInt(0);
    int rank = results.FetchInt(1);
    int total = results.FetchInt(2);

	if (client == 0 || !IsClientInGame(client)) {
		return;
	}

	CPrintToChatAll("[TF2Ware] {orange}%N is ranked {blue}%d {default}(out of {blue}%i {default}players) with {blue}%i {default}points!", client, rank, total, score);
}

public Action Command_Top(int client, int args) {
	if (!g_Enabled || client == 0) {
		return Plugin_Handled;
	}

	char amount[16];
	GetCmdArg(1, amount, sizeof(amount));
	int limit = StringToInt(amount);

	if (limit < 1) {
		limit = 25;
	} else if (limit > 100) {
		limit = 100;
	}

	char query[256];
	g_Database.Format(query, sizeof(query), "SELECT name, score FROM ware_scores ORDER BY score DESC LIMIT %i;", limit);
	g_Database.Query(OnGetTop, query, GetClientUserId(client));

	return Plugin_Handled;
}

public void OnGetTop(Database db, DBResultSet results, const char[] error, any data) {
	if (results == null) {
		ThrowError("Failed to get top players: %s", error);
	}

	int client = GetClientOfUserId(data);

	if (client == 0 || !IsClientInGame(client)) {
		return;
	}

	Menu menu = new Menu(MenuHandler_Top);
	menu.SetTitle("Top TF2Ware Ultimate Players");

	char display[256]; int count; char name[MAX_NAME_LENGTH];
	while (results.FetchRow()) {
		count++;
		results.FetchString(0, name, sizeof(name));
		FormatEx(display, sizeof(display), "#%i%s - %s - %i points", count, GetNumberExtension(count), name, results.FetchInt(1));
		menu.AddItem("", display, ITEMDRAW_DISABLED);
	}

	if (menu.ItemCount == 0) {
		menu.AddItem("", " :: Empty", ITEMDRAW_DISABLED);
	}

	menu.Display(client, MENU_TIME_FOREVER);
}

char[] GetNumberExtension(int number) {
	switch (number % 10) {
		case 1: return "st";
		case 2: return "nd";
		case 3: return "rd";
		default: return "th";
	}
}

public int MenuHandler_Top(Menu menu, MenuAction action, int param1, int param2) {
	if (action == MenuAction_End) {
		delete menu;
	}

	return 0;
}