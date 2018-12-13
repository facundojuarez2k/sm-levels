/***********************************************************************************
	Requires 
		Chat-Processor: https://forums.alliedmods.net/showthread.php?t=286913
		Multicolors: https://forums.alliedmods.net/showthread.php?t=247770
	To do:
		>Optimize database sync queries
		>Admin menu
************************************************************************************/

#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>
#include <cstrike>
#include <multicolors>
#include <chat-processor>

#define PLUGIN_VERSION "0.1.2"
#define PLUGIN_CHAT_PREFIX "{darkred}[JBLevels]"
#define PLUGIN_CHAT_PREFIX_2 "[JBLevels]"
#define XP_INCREMENT_VALUE 1

ConVar g_hDBTableName;
ConVar g_hDBUpdateInterval;
ConVar g_hXPUpdateInterval;
ConVar g_hMinLevelToJoinCT;

char g_sLogPath[256];
char g_sDBTableName[512];
float g_fDBUpdateInterval;
float  g_fXPUpdateInterval;
int g_iMinLevelToJoinCT;

Handle g_hClientTimer[MAXPLAYERS+1];
Handle g_hDatabase = INVALID_HANDLE;
Handle g_hAutoUpdateDatabaseTimer;

/* Player stats struct */
enum PlayerStats 
{
	xp,
	level,
	timePlayed,
	lastDBLoadTime,
	lastDBSaveTime
}; 

int g_iPlayerStats[MAXPLAYERS+1][PlayerStats];

public Plugin myinfo =
{
	name = "Jailbreak Levels [BETA]",
	author = "BLACK_STAR",
	description = "Leveling system for jailbreak servers",
	version = PLUGIN_VERSION,
	url = ""
};

public void OnPluginStart()
{
	g_hDBTableName = CreateConVar("jbl_db_table_name", "jblevels", "Name of the database table in the databases.cfg file", FCVAR_PROTECTED);
	g_hDBUpdateInterval = CreateConVar("jbl_db_update_interval", "300.0", "Time in seconds between each database update", FCVAR_PROTECTED, true, 120.0, true, 900.0);
	g_hXPUpdateInterval = CreateConVar("jbl_xp_update_interval", "60.0", "Time in seconds between each player experience increment", FCVAR_PROTECTED, true, 10.0, true, 120.0);
	g_hMinLevelToJoinCT = CreateConVar("jbl_ct_level", "5", "Lowest level required to join the CT team", _, true, 1.0);
	
	RegConsoleCmd("sm_mystats", Panel_JBMyStats);
	RegAdminCmd("sm_playerstats", Command_PlayerStats, ADMFLAG_BAN, "Shows stats for a given player");
	
	AddCommandListener(Command_CheckJoin, "jointeam");
	//HookEvent("player_team", Event_PlayerTeam);
	
	AutoExecConfig(true, "jblevels");
	BuildPath(Path_SM, g_sLogPath, sizeof(g_sLogPath), "logs/jblevels.log");
	LoadTranslations("common.phrases");
} 

public void OnConfigsExecuted()
{
	GetConVarString(g_hDBTableName, g_sDBTableName, sizeof(g_sDBTableName));
	g_fDBUpdateInterval = GetConVarFloat(g_hDBUpdateInterval);
	g_fXPUpdateInterval = GetConVarFloat(g_hXPUpdateInterval);
	g_iMinLevelToJoinCT = GetConVarInt(g_hMinLevelToJoinCT);
	
	Initialize();
	
	SQL_TConnect(OnDBConnect, g_sDBTableName);
}

public void OnMapEnd()
{
	SaveAllPlayerStats(true);
}

public void OnPluginEnd()
{
	SaveAllPlayerStats(true);
}

public Action CP_OnChatMessage(int& author, ArrayList recipients, char[] flagstring, char[] name, char[] message, bool& processcolors, bool& removecolors)
{
    Format(name, MAXLENGTH_NAME, "{gold}[%i]{teamcolor}%s", GetPlayerLevel(author), name);
    return Plugin_Changed;
}

public Action Command_CheckJoin(int client, const char[] command, int args)
{
	if(!g_hDatabase || !IsValidClient(client))
		return Plugin_Continue;
	
	//Admins don't have restrictions
	if(CheckCommandAccess(client, "", ADMFLAG_KICK))
		return Plugin_Continue;

	char sJoinTeamString[5];
	GetCmdArg(1, sJoinTeamString, sizeof(sJoinTeamString));
	int iTargetTeam = StringToInt(sJoinTeamString);

	int iPlayerLevel = GetPlayerLevel(client);

	if((iTargetTeam == CS_TEAM_CT) && (iPlayerLevel < g_iMinLevelToJoinCT))
	{
		CPrintToChat(client, "%s Debes alcanzar el nivel %i antes de ser CT", PLUGIN_CHAT_PREFIX, g_iMinLevelToJoinCT);		
		return Plugin_Stop;
	}

	return Plugin_Continue;
}

public Action Command_PlayerStats(int client, int args) 
{ 
	if (args < 1) 
    { 
		CPrintToChat(client, "%s {green}Uso: !playerstats <target>", PLUGIN_CHAT_PREFIX); 
		return Plugin_Handled; 
    }
	
	char szTarget[64]; 
	GetCmdArg(1, szTarget, sizeof(szTarget));
	int target = FindTarget(client, szTarget, true);
	
	if(!IsValidClient(target))
	{
		CPrintToChat(client, "%s {green}Jugador no encontrado", PLUGIN_CHAT_PREFIX);
		return Plugin_Handled;
	}
	
	return Panel_JBTargetStats(client, target); 
}

/*public Action Event_PlayerTeam(Event event, const char[] name, bool dontBroadcast)
{
	int client = GetClientOfUserId(GetEventInt(event, "userid"));
	if(IsValidClient(client))
	{
		if(CheckCommandAccess(client, "", ADMFLAG_KICK))
			return Plugin_Continue;
		
		if(g_iPlayerStats[client][level] < g_iMinLevelToJoinCT)
		{
			PrintToChat(client, "Debes alcanzar el nivel %i antes de ser CT", g_iMinLevelToJoinCT);
			return Plugin_Handled;
		}
	}
	else
	{
		return Plugin_Handled;
	}
	return Plugin_Continue;
}*/

public void OnDBConnect(Handle owner, Handle hndl, char [] error, any data)
{
	if(hndl == INVALID_HANDLE)
	{
		LogToFileEx(g_sLogPath, "[Database failure]: %s", error);
		SetFailState("Couldn't connect to database");
	}
	else
	{
		g_hDatabase = hndl;
		
		char sQuery[256];
		//SQL_GetDriverIdent(SQL_ReadDriver(g_hDatabase), sQuery, sizeof(sQuery));
		Format(sQuery, sizeof(sQuery), "CREATE TABLE IF NOT EXISTS %s (steam_id varchar(32) PRIMARY KEY NOT NULL, level INTEGER, xp INTEGER, time_played INTEGER, last_update INTEGER);", g_sDBTableName);
		SQL_TQuery(g_hDatabase, DB_CreateTable, sQuery);
		//LogToFileEx(g_sLogPath, "Query %s", sQuery);
	}
}

public void OnClientConnected(int client)
{
	if(!IsFakeClient(client))
		InitPlayer(client);
}

public void OnClientPostAdminCheck(int client)
{
	if(IsValidClient(client))
	{
		LoadPlayerStats(client);
		StartXPTimer(client);
	}
}

public void OnClientDisconnect(int client)
{
	if(g_hClientTimer[client] != INVALID_HANDLE)
	{
		CloseHandle(g_hClientTimer[client]);
		g_hClientTimer[client] = INVALID_HANDLE;
	}
	
	SavePlayerStats(client, null, true);
	ClearPlayerCache(client);
}

public Action AutoUpdateDatabase(Handle timer)
{
	if(!g_hDatabase || GetPlayerCount()==0)
	{
		if(g_hAutoUpdateDatabaseTimer != INVALID_HANDLE)
		{
			CloseHandle(g_hAutoUpdateDatabaseTimer);
			g_hAutoUpdateDatabaseTimer = INVALID_HANDLE;
		}
		return Plugin_Stop;	
	}
	
	SaveAllPlayerStats();
	
	return Plugin_Continue;
}

public Action AddExperienceOnTimePlayed(Handle timer, any userId)
{
	int client = GetClientOfUserId(userId);
	
	//Client has disconnected but the timer is still running
	if(!IsValidClient(client))
	{
		KillClientTimerIfExists(client);
		return Plugin_Stop;	
	}
	
	IncrementPlayerXP(client, XP_INCREMENT_VALUE);
	IncrementPlayerTimePlayed(client, RoundToFloor(g_fXPUpdateInterval));
	
	if(ShouldLevelUp(client)) 
		levelUp(client);
	
	return Plugin_Continue;
}

//Initializes the cache array
void Initialize()
{
	for(int i=1; i<=MaxClients; i++)
	{
		if(IsValidClient(i))
		{
			InitPlayer(i);
			StartXPTimer(i);
		}
		else{
			InitPlayerEmpty(i);
		}
	}
}

void InitPlayer(int client)
{
	SetPlayerLevel(client, 1);
	SetPlayerXP(client, 0);
	SetPlayerTimePlayed(client, 0);
	SetPlayerLastDBLoadTime(client, -1);
	SetPlayerLastDBSaveTime(client, -1);
}

void InitPlayerEmpty(int client)
{
	SetPlayerLevel(client, -1);
	SetPlayerXP(client, -1);
	SetPlayerTimePlayed(client, -1);
	SetPlayerLastDBLoadTime(client, -1);
	SetPlayerLastDBSaveTime(client, -1);
}

void ClearPlayerCache(int client)
{
	SetPlayerLevel(client, -1);
	SetPlayerXP(client, -1);
	SetPlayerTimePlayed(client, -1);
	SetPlayerLastDBLoadTime(client, -1);
	SetPlayerLastDBSaveTime(client, -1);
}

void LoadPlayerStats(int client, Transaction hTransaction=null)
{
	if(!g_hDatabase)
		return;

	if(!IsValidClient(client))
		return;
	
	int iSteamId = GetSteamAccountID(client);
	if(!iSteamId)
		return;
	
	char sQuery[256];
	Format(sQuery, sizeof(sQuery), "SELECT steam_id, level, xp, time_played FROM %s WHERE steam_id = %d LIMIT 1;", g_sDBTableName, iSteamId);
	
	if(hTransaction != null)
		hTransaction.AddQuery(sQuery);
	else
		SQL_TQuery(g_hDatabase, DB_GetPlayerStats, sQuery, GetClientUserId(client));
}

void LoadConnectedPlayersStats()
{
	if(!g_hDatabase)
		return;
	
	Transaction hTransaction = new Transaction();
	
	for(int i=1;i<=MaxClients;i++)
	{
		if(IsValidClient(i) && IsClientAuthorized(i))
		{
			if(GetPlayerLastDBLoadTime(i) > 0)
				continue;
			LoadPlayerStats(i, hTransaction);
		}
	}
	
	SQL_ExecuteTransaction(g_hDatabase, hTransaction, SQLTxn_LoadPlayersStats, SQLTxn_LogError);
}

bool InsertNewPlayer(int client)
{
	if(!g_hDatabase)
		return false;

	if(!IsValidClient(client))
		return false;
	
	int iSteamId = GetSteamAccountID(client);
	if(!iSteamId)
		return false;
	
	char sQuery[256];
	
	int lastUpdate = GetTime();
	Format(sQuery, sizeof(sQuery), "INSERT INTO %s (steam_id, level, xp, time_played, last_update) VALUES (%d, %i, %i, %i, %i);", g_sDBTableName, iSteamId, GetPlayerLevel(client), GetPlayerXP(client), GetPlayerTimePlayed(client), lastUpdate);
	
	SQL_TQuery(g_hDatabase, DB_InsertNewPlayer, sQuery, GetClientUserId(client));
	
	return true;
}

bool SavePlayerStats(int client, Transaction hTransaction=null, bool manual=false)
{
	if(!g_hDatabase)
		return false;
		
	if(!IsValidClient(client))
		return false;

	if(GetPlayerLastDBLoadTime(client) < 0)
		return false;
	
	if(!manual && ((GetTime() - GetPlayerLastDBSaveTime(client)) < g_fDBUpdateInterval))
		return false;	
	
	int iSteamId = GetSteamAccountID(client);
	if(!iSteamId)
		return false;
	
	char sQuery[256];
	
	SetPlayerLastDBSaveTime(client, GetTime());
	Format(sQuery, sizeof(sQuery), "UPDATE %s SET level = %i, xp = %i, time_played = %i, last_update = %i WHERE steam_id = %d;", g_sDBTableName, GetPlayerLevel(client), GetPlayerXP(client), GetPlayerTimePlayed(client), GetPlayerLastDBSaveTime(client), iSteamId);
	
	if(hTransaction != null)
		hTransaction.AddQuery(sQuery);
	else
		SQL_TQuery(g_hDatabase, DB_SavePlayerStats, sQuery, GetClientUserId(client));
	
	return true;
}

bool SaveAllPlayerStats(bool manual=false)
{
	if(g_hDatabase == null)
		return false;
	
	Transaction hTransaction = new Transaction();
	
	for(int i=1;i<=MaxClients;i++)
	{
		if(IsValidClient(i) && IsClientAuthorized(i))
			SavePlayerStats(i, hTransaction, manual);
	}
	
	SQL_ExecuteTransaction(g_hDatabase, hTransaction, SQLTxn_LogSaveSuccecss, SQLTxn_LogError);
	
	return true;
}

/* SQL Callbacks */

public void DB_CreateTable(Handle owner, Handle hndl, char [] error, any data)
{
	if(hndl == INVALID_HANDLE)
	{
		LogToFileEx(g_sLogPath, "[Query failure] Error while creating table: %s", error);
	}
	else
	{
		if(g_hAutoUpdateDatabaseTimer == INVALID_HANDLE)
			g_hAutoUpdateDatabaseTimer = CreateTimer(g_fDBUpdateInterval, AutoUpdateDatabase, _, TIMER_REPEAT);
		LoadConnectedPlayersStats();
	}
}

public void DB_SavePlayerStats(Handle owner, Handle hndl, char [] error, any userid)
{
	if(hndl == INVALID_HANDLE)
	{
		int client = GetClientOfUserId(userid);
		if(IsValidClient(client))
			SetPlayerLastDBSaveTime(client, -1);
		
		LogToFileEx(g_sLogPath, "[Query failure] Error updating stats for client (SteamID: %d). Message: %s", GetSteamAccountID(client), error);
	}
}

public void DB_GetPlayerStats(Handle owner, Handle hndl, char [] error, any userid)
{
	int client = GetClientOfUserId(userid);	
	if(!client)
		return;
	
	if(hndl == INVALID_HANDLE)
	{
		LogToFileEx(g_sLogPath, "[Query failure] Error retrieving stats for client (SteamID: %d). Message: %s", GetSteamAccountID(client), error);
		return;
	}
	if(!SQL_GetRowCount(hndl) || !SQL_FetchRow(hndl)) 
	{
		InsertNewPlayer(client);
		LogToFileEx(g_sLogPath, "Client (SteamID: %d) not found in database, inserting new entry", GetSteamAccountID(client));
		return;
	}
	
	SetPlayerLevel(client, SQL_FetchInt(hndl, 1));
	SetPlayerXP(client, SQL_FetchInt(hndl, 2));
	SetPlayerTimePlayed(client, SQL_FetchInt(hndl, 3));
	SetPlayerLastDBLoadTime(client, GetTime());
}

public void DB_InsertNewPlayer(Handle owner, Handle hndl, char [] error, any userid)
{
	int client = GetClientOfUserId(userid);
	if(!client)
		return;
	
	if(hndl == INVALID_HANDLE)
	{
		LogToFileEx(g_sLogPath, "[Query failure] Error inserting new client (SteamID: %d) into database. Message: %s", GetSteamAccountID(client), error);
		return;
	}
	
	SetPlayerLastDBLoadTime(client, GetTime());
	SetPlayerLastDBSaveTime(client, GetTime());
	
	LogToFileEx(g_sLogPath, "New client with steamid %i inserted into database", GetSteamAccountID(client));
}

public void SQLTxn_LoadPlayersStats(Database db, any data, int numQueries, DBResultSet[] results, any[] queryData)
{
	for(int i=0; i<numQueries; i++)
	{
		if(!results[i].FetchRow())
			continue;
		
		int client = GetClientOfSteamId(results[i].FetchInt(0));
		if(!client) 
			continue;
		
		SetPlayerLevel(client, results[i].FetchInt(1));
		SetPlayerXP(client, results[i].FetchInt(2));
		SetPlayerTimePlayed(client, results[i].FetchInt(3));
		SetPlayerLastDBLoadTime(client, GetTime());
	}
}

public void SQLTxn_LogSaveSuccecss(Database db, any data, int numQueries, DBResultSet[] results, any[] queryData)
{
	PrintToServer("Stats for all players have been saved into the database");
}

public void SQLTxn_LogError(Database db, any data, int numQueries, const char[] error, int failIndex, any[] queryData)
{
	LogToFileEx(g_sLogPath, "[Query failure] Error executing query %d of %d queries: %s", failIndex, numQueries, error);
}

void StartXPTimer(int client)
{
	if(IsValidClient(client))
	{
		KillClientTimerIfExists(client);
		g_hClientTimer[client] = CreateTimer(g_fXPUpdateInterval, AddExperienceOnTimePlayed, GetClientUserId(client), TIMER_REPEAT);
	}
}

/* Leveling functions */
bool ShouldLevelUp(int client)
{
	return (GetPlayerXP(client) >= nextLevelXP(GetPlayerLevel(client)));
}

//Returns the amount of XP required to reach the next level
int nextLevelXP(int lvl)
{
	int formula = ((100+(lvl*lvl))/2);
	return formula;
}

//Increases a player level and resets his experience
void levelUp(int client)
{
	IncrementPlayerLevel(client, 1);
	ResetPlayerXP(client);
	PrintToChat(client, "%s Has subido de nivel!, tu nuevo nivel es: %i", PLUGIN_CHAT_PREFIX, GetPlayerLevel(client));
}

/* Panels */
public int PanelHandler1(Menu menu, MenuAction action, int param1, int param2)
{
	if (action == MenuAction_End)
	{
		CloseHandle(menu);
	}
}

public Action Panel_JBMyStats(int client, int args)
{
	char sXP[128];
	Format(sXP, sizeof(sXP), "XP: %i", GetPlayerXP(client));
	
	char sLevel[128];
	Format(sLevel, sizeof(sLevel), "Nivel: %i", GetPlayerLevel(client));
	
	char sFormattedTime[8];
	FormatTimeCustom(sFormattedTime, sizeof(sFormattedTime), GetPlayerTimePlayed(client));
	char sTimePlayed[64];
	Format(sTimePlayed, sizeof(sTimePlayed), "Tiempo de juego total (H:M): %s", sFormattedTime);	
	
	char sNeededXP[128];
	Format(sNeededXP, sizeof(sNeededXP), "XP para sig. nivel: %i", nextLevelXP(GetPlayerLevel(client)));	
	
	Panel panel = new Panel();
	panel.SetTitle("Tus estadisticas:");
	panel.DrawText(sXP);
	panel.DrawText(sLevel);
	panel.DrawText(sTimePlayed);
	panel.DrawText(sNeededXP);
	panel.DrawItem("Salir");
 
	panel.Send(client, PanelHandler1, 20);
 
	delete panel;
 
	return Plugin_Handled;
}

public Action Panel_JBTargetStats(int client, int target)
{
	char sXP[128];
	Format(sXP, sizeof(sXP), "XP: %i", GetPlayerXP(target));
	
	char sLevel[128];
	Format(sLevel, sizeof(sLevel), "Nivel: %i", GetPlayerLevel(target));
	
	char sFormattedTime[8];
	FormatTimeCustom(sFormattedTime, sizeof(sFormattedTime), GetPlayerTimePlayed(target));
	char sTimePlayed[64];
	Format(sTimePlayed, sizeof(sTimePlayed), "Tiempo de juego total (H:M): %s", sFormattedTime);	
	
	char sNeededXP[128];
	Format(sNeededXP, sizeof(sNeededXP), "XP para sig. nivel: %i", nextLevelXP(GetPlayerLevel(target)));	
	
	char sTargetName[MAXLENGTH_NAME];
	GetClientName(target, sTargetName, sizeof(sTargetName));
	char sTitle[128];
	Format(sTitle, sizeof(sTitle), "Estadisticas de %s", sTargetName);
	
	Panel panel = new Panel();
	panel.SetTitle(sTitle);
	panel.DrawText(sXP);
	panel.DrawText(sLevel);
	panel.DrawText(sTimePlayed);
	panel.DrawText(sNeededXP);
	panel.DrawItem("Salir");
 
	panel.Send(client, PanelHandler1, 20);
 
	delete panel;
 
	return Plugin_Handled;
}

/* Helper functions */

void KillClientTimerIfExists(int client)
{
	if(g_hClientTimer[client] != INVALID_HANDLE)
	{
		CloseHandle(g_hClientTimer[client]);
		g_hClientTimer[client] = INVALID_HANDLE;	
	}
}

int GetClientOfSteamId(int steamId)
{
	for(int i=1; i<=MaxClients; i++)
	{
		if(IsValidClient(i) && steamId == GetSteamAccountID(i))
			return i;
	}
	return -1;
} 

bool IsValidClient(int client) 
{ 
    if (!(1 <= client <= MaxClients) || !IsClientInGame (client) || IsFakeClient(client)) 
        return false; 

    return true; 
}  

int GetPlayerCount()
{
	int players;
	for(int i=1; i<=MaxClients; i++)
	{
		if(IsClientAuthorized(i) && !IsFakeClient(i))
			players++;
	}
	return players;
}

void FormatTimeCustom(char[] buffer, int bufferSize, int iTime)
{
	if(iTime<0)
		return;
	
	int iHrs = iTime / 3600;
	int iMin = iTime % 3600 / 60;
	
	char sHrs[4];
	char sMin[4];
	
	if(iHrs<10)
		Format(sHrs, sizeof(sHrs), "0%i", iHrs);
	else
		Format(sHrs, sizeof(sHrs), "%i", iHrs);
	
	if(iMin<10)
		Format(sMin, sizeof(sMin), "0%i", iMin);
	else
		Format(sMin, sizeof(sMin), "%i", iMin);
	
	Format(buffer, bufferSize, "%s:%s", sHrs, sMin);
}

//Setters & Getters for players array

int GetPlayerXP(int client)
{
	if(!client)
		return -1;
	return g_iPlayerStats[client][xp];
}

int GetPlayerLevel(int client)
{
	if(!client)
		return -1;
	return g_iPlayerStats[client][level];
}

int GetPlayerTimePlayed(int client)
{
	if(!client)
		return -1;
	return g_iPlayerStats[client][timePlayed];
}

int GetPlayerLastDBLoadTime(int client)
{
	if(!client)
		return -1;
	return g_iPlayerStats[client][lastDBLoadTime];
}

int GetPlayerLastDBSaveTime(int client)
{
	if(!client)
		return -1;
	return g_iPlayerStats[client][lastDBSaveTime];
}

bool SetPlayerXP(int client, int newXP)
{
	if(!client)
		return false;
	g_iPlayerStats[client][xp] = newXP;
	return true;
}

bool SetPlayerLevel(int client, int lvl)
{
	if(!client)
		return false;
	g_iPlayerStats[client][level] = lvl;
	return true;
}

bool SetPlayerTimePlayed(int client, int time)
{
	if(!client)
		return false;
	g_iPlayerStats[client][timePlayed] = time;
	return true;
}

bool SetPlayerLastDBLoadTime(int client, int time)
{
	if(!client)
		return false;
	g_iPlayerStats[client][lastDBLoadTime] = time;
	return true;
}

bool SetPlayerLastDBSaveTime(int client, int time)
{
	if(!client)
		return false;
	g_iPlayerStats[client][lastDBSaveTime] = time;
	return true;
}

bool IncrementPlayerLevel(int client, int levels)
{
	if(!client)
		return false;
	g_iPlayerStats[client][level] += levels;
	return true;
}

bool IncrementPlayerXP(int client, int XPToAdd)
{
	if(!client)
		return false;
	g_iPlayerStats[client][xp] += XPToAdd;
	return true;
}

bool IncrementPlayerTimePlayed(int client, int timeToAdd)
{
	if(!client)
		return false;
	g_iPlayerStats[client][timePlayed] += timeToAdd;
	return true;
}

bool ResetPlayerXP(int client)
{
	if(!client)
		return false;
	g_iPlayerStats[client][xp] = 0;
	return true;
}