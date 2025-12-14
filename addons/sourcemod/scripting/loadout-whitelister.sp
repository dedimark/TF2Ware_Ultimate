#undef REQUIRE_EXTENSIONS
#include <sdktools>
#include <dhooks>

#define SLOT_MELEE 2
#define SLOT_WEARABLES 7
#define SLOT_TAUNT1 11
#define SLOT_TAUNT8 18

ConVar mp_tournament;
ConVar mp_tournament_whitelist;
ConVar loadoutwhitelister_enable;
ConVar loadoutwhitelister_cosmetics;
ConVar loadoutwhitelister_taunts;

bool loadoutwhitelister_init = false;
public bool script_allow_loadout = false;

DynamicHook g_DHook_CTFPlayerInitClass;
DynamicDetour g_DDetour_CTFPlayerGetLoadoutItem;
DynamicHook g_DDetour_CBaseEntityFVisible;

char g_SavedTournamentWhitelist[256];

void SetTournamentValue(bool toggle)
{
	mp_tournament.Flags &= ~(FCVAR_REPLICATED|FCVAR_NOTIFY);
	mp_tournament.SetInt(toggle ? 1 : 0, false, false);
	mp_tournament.Flags |= (FCVAR_REPLICATED|FCVAR_NOTIFY);
}

public void LoadoutWhitelister_Start(GameData gamedata)
{
	if (!LibraryExists("dhooks"))
	{
		LogMessage("Cannot start loadout whitelister as DHooks extension is not loaded");
		return;
	}
	
	g_DHook_CTFPlayerInitClass = DynamicHook.FromConf(gamedata, "CTFPlayer::InitClass");
	if (!g_DHook_CTFPlayerInitClass)
	{
		LogError("Failed to setup hook for CTFPlayer::InitClass");		
		return;
	}
	
	g_DDetour_CTFPlayerGetLoadoutItem = DynamicDetour.FromConf(gamedata, "CTFPlayer::GetLoadoutItem");
	if (!g_DDetour_CTFPlayerGetLoadoutItem)
	{
		LogError("Failed to setup detour for CTFPlayer::GetLoadoutItem");		
		return;
	}
	
	g_DDetour_CBaseEntityFVisible = DynamicHook.FromConf(gamedata, "CBaseEntity::FVisible");
	if (!g_DDetour_CBaseEntityFVisible)
		LogError("Failed to setup detour for CBaseEntity::FVisible");
	
	loadoutwhitelister_init = true;
	
	g_DDetour_CTFPlayerGetLoadoutItem.Enable(Hook_Pre, DHookPre_CTFPlayerGetLoadoutItem);
	
	mp_tournament = FindConVar("mp_tournament");
	mp_tournament_whitelist = FindConVar("mp_tournament_whitelist");
	mp_tournament_whitelist.GetString(g_SavedTournamentWhitelist, sizeof(g_SavedTournamentWhitelist));
	mp_tournament_whitelist.SetString("cfg/tf2ware_ultimate/item_whitelist.cfg"); // TODO: don't hardcode this here?
	loadoutwhitelister_enable = CreateConVar("loadoutwhitelister_enable", "1", "");
	loadoutwhitelister_cosmetics = CreateConVar("loadoutwhitelister_cosmetics", MaxClients > 64 ? "0" : "1", "Allow cosmetics. Whitelist will still be used");
	loadoutwhitelister_taunts = CreateConVar("loadoutwhitelister_taunts", "4", "Allow up to N amount of taunts (0 for none)");
	
	AddCommandListener(ListenerTournamentRestart, "mp_tournament_restart");
	
	for (int client = 1; client <= MaxClients; client++)
	{
		if (IsClientInGame(client))
			LoadoutWhitelister_InitClient(client);
	}
}

public void LoadoutWhitelister_End(bool map_unload)
{
	if (!loadoutwhitelister_init)
		return;
	loadoutwhitelister_init = false;
	
	mp_tournament_whitelist.SetString(g_SavedTournamentWhitelist);
	
	if (g_DDetour_CTFPlayerGetLoadoutItem)
		g_DDetour_CTFPlayerGetLoadoutItem.Disable(Hook_Pre, DHookPre_CTFPlayerGetLoadoutItem);
	
	if (map_unload)
		RemoveCommandListener(ListenerTournamentRestart, "mp_tournament_restart");	
}

public void LoadoutWhitelister_InitClient(int client)
{
	if (!loadoutwhitelister_init)
		return;
	
	if (g_DHook_CTFPlayerInitClass)
	{
		g_DHook_CTFPlayerInitClass.HookEntity(Hook_Pre, client, DHookPre_CTFPlayerInitClass);
		g_DHook_CTFPlayerInitClass.HookEntity(Hook_Post, client, DHookPost_CTFPlayerInitClass);
	}
}

static bool g_ReloadingWhitelist = false;
static bool g_InRestart = false;
static int g_PrevWPF = 0;

Action ListenerTournamentRestart(int client, const char[] command, int argc)
{
	if (g_ReloadingWhitelist)
	{
		if (g_InRestart)
		{
			GameRules_SetProp("m_bInWaitingForPlayers", g_PrevWPF);
			GameRules_SetProp("m_bAwaitingReadyRestart", 0);
			SetTournamentValue(false);
			
			g_InRestart = false;
			g_ReloadingWhitelist = false;
			return Plugin_Handled;
		}
		
		g_InRestart = true;
		
		SetTournamentValue(true);
		g_PrevWPF = GameRules_GetProp("m_bInWaitingForPlayers"); 
		GameRules_SetProp("m_bInWaitingForPlayers", 1);
	}
	
	return Plugin_Continue;
}

public void LoadoutWhitelister_ReloadWhitelist()
{
	PrintToServer("Reloading item whitelist...");
	
	int gamerules = FindEntityByClassname(-1, "tf_gamerules");
	if (gamerules == -1)
	{
		PrintToServer("No gamerules to reload whitelist with!");
		return;
	}
	
	g_ReloadingWhitelist = true;
	ServerCommand("mp_tournament_restart");
	ServerCommand("mp_tournament_restart"); // hacky but this isn't synchronous
}
static bool g_InitClass = false;
static int g_SavedTournamentValue = 0;

static MRESReturn DHookPre_CTFPlayerInitClass(int client)
{
	g_InitClass = true;
	
	if (loadoutwhitelister_enable.BoolValue)
	{
		g_SavedTournamentValue = mp_tournament.IntValue;
		SetTournamentValue(true);
	}
	
	return MRES_Ignored;
}

static MRESReturn DHookPre_CTFPlayerGetLoadoutItem(int client, DHookReturn ret, DHookParam param)
{
	if (g_InitClass && loadoutwhitelister_enable.BoolValue && !script_allow_loadout)
	{
		int slot = param.Get(2);
		// remove weapons (except melee)
		// keep up to N taunts (defined by convar)
		// keep wearables (whitelist will kill those), unless >64 players
		if (slot == SLOT_MELEE)
		{
		}
		else if (loadoutwhitelister_cosmetics.IntValue 
				&& (slot >= SLOT_WEARABLES && slot < (SLOT_TAUNT1 + loadoutwhitelister_taunts.IntValue)))
		{
		}
		else if (slot >= SLOT_TAUNT1 && slot < (SLOT_TAUNT1 + loadoutwhitelister_taunts.IntValue))
		{
		}
		else
		{
			// makes inventory return a null item
			param.Set(2, -1);
		}
			
		// don't print failures
		param.Set(3, false);
		return MRES_ChangedHandled;
	}
	
	return MRES_Ignored;
}

static MRESReturn DHookPost_CTFPlayerInitClass(int client)
{
	g_InitClass = false;
	
	if (loadoutwhitelister_enable.BoolValue)
		SetTournamentValue(g_SavedTournamentValue != 0);
	
	return MRES_Ignored;
}

// TODO temporary hack to figure out why weapons are rarely not being given to players
// I suspect the cause is a FVisible trace check in CTFPlayer::BumpWeapon
// Going to see if this fixes it
static MRESReturn DHookPre_CBaseEntityFVisible(int entity, DHookReturn ret)
{
	ret.Value = true;
	return MRES_Supercede;
}

public void OnEntityCreated(int entity, const char[] classname)
{
	if (g_DDetour_CBaseEntityFVisible && strncmp(classname, "tf_weapon", 9) == 0)
		g_DDetour_CBaseEntityFVisible.HookEntity(Hook_Pre, entity, DHookPre_CBaseEntityFVisible);
}
