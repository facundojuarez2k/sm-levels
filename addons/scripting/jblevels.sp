#pragma semicolon 1
#pragma newdecls required

#include sourcemod
#include <sdktools>
#include <cstrike>
#include <chat-processor>

#define PLUGIN_VERSION "0.1.1"

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
	g_hMinLevelToJoinCT = CreateConVar("jbl_ct_level", "3", "Lowest level required to join the CT team", _, true, 1.0);
	
	RegConsoleCmd("sm_jbstats", Panel_JBStats);
	
	AddCommandListener(Command_CheckJoin, "jointeam");
	//HookEvent("player_team", Event_PlayerTeam);
	
	AutoExecConfig(true, "jblevels");
	BuildPath(Path_SM, g_sLogPath, sizeof(g_sLogPath), "logs/jblevels.log");
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

public Action CP_OnChatMessage(int& author, ArrayList recipients, char[] flagstring, char[] name, char[] message, bool& processcolors, bool& removecolors)
{
    Format(name, MAXLENGTH_NAME, "{gold}[%i]{teamcolor}%s", g_iPlayerStats[author][level], name);
    return Plugin_Changed;
}

public Action Command_CheckJoin(int client, const char[] command, int args)
{
	if(!g_hDatabase || !IsValidClient(client))
	{
		return Plugin_Continue;
	}

	char sJoinTeamString[5];
	GetCmdArg(1, sJoinTeamString, sizeof(sJoinTeamString));
	int iTargetTeam = StringToInt(sJoinTeamString);

	int iPlayerLevel = g_iPlayerStats[client][level];

	if((iTargetTeam == CS_TEAM_CT) && (iPlayerLevel < g_iMinLevelToJoinCT))
	{
		PrintToChat(client, "Debes alcanzar el nivel %i antes de ser CT", g_iMinLevelToJoinCT);
		return Plugin_Stop;
	}

	return Plugin_Continue;
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
			g_iPlayerStats[i][level] = -1;
			g_iPlayerStats[i][xp] = -1;
			g_iPlayerStats[i][timePlayed] = -1;
			g_iPlayerStats[i][lastDBSaveTime] = -1;
			g_iPlayerStats[i][lastDBLoadTime] = -1;
		}
	}
}

public void OnDBConnect(Handle owner, Handle hndl, char [] error, any data)
{
	if(hndl == INVALID_HANDLE)
	{
		LogToFileEx(g_sLogPath, "Database failure: %s", error);
		SetFailState("Couldn't connect to database");
	}
	else
	{
		g_hDatabase = hndl;
		
		char sQuery[256];
		//SQL_GetDriverIdent(SQL_ReadDriver(g_hDatabase), sQuery, sizeof(sQuery));
		Format(sQuery, sizeof(sQuery), "CREATE TABLE IF NOT EXISTS %s (steam_id varchar(32) PRIMARY KEY NOT NULL, level INTEGER, xp INTEGER, time_played INTEGER, last_update INTEGER);", g_sDBTableName);
		SQL_TQuery(g_hDatabase, DB_OnDBConnectCallback, sQuery);
		LogToFileEx(g_sLogPath, "Query %s", sQuery);
	}
}

public void DB_OnDBConnectCallback(Handle owner, Handle hndl, char [] error, any data)
{
	if(hndl == INVALID_HANDLE)
	{
		LogToFileEx(g_sLogPath, "Query failure: %s", error);
	}
	else
	{
		if(g_hAutoUpdateDatabaseTimer == INVALID_HANDLE)
			g_hAutoUpdateDatabaseTimer = CreateTimer(g_fDBUpdateInterval, AutoUpdateDatabase, _, TIMER_REPEAT);
		LoadConnectedPlayersStats();
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
	ClearClientStatsCache(client);
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
	
	if(!IsValidClient(client))
		return Plugin_Stop;
	
	g_iPlayerStats[client][xp] = g_iPlayerStats[client][xp] + 1;
	g_iPlayerStats[client][timePlayed] += RoundToFloor(g_fXPUpdateInterval);
	
	if(ShouldLevelUp(client)) 
		levelUp(client);
	
	return Plugin_Continue;
}

bool ShouldLevelUp(int client)
{
	return (g_iPlayerStats[client][xp] >= nextLevelXP(g_iPlayerStats[client][level]));
}

int nextLevelXP(int lvl)
{
	int formula = ((100+(lvl*lvl))/2);
	return formula;
}

void levelUp(int client)
{
	g_iPlayerStats[client][level] += 1;
	g_iPlayerStats[client][xp] = 0;
	PrintToChat(client, "Has subido de nivel!, tu nuevo nivel es: %i", g_iPlayerStats[client][level]);
}

void InitPlayer(int client)
{
	g_iPlayerStats[client][level] = 1;
	g_iPlayerStats[client][xp] = 0;
	g_iPlayerStats[client][timePlayed] = 0;
	g_iPlayerStats[client][lastDBSaveTime] = -1;
	g_iPlayerStats[client][lastDBLoadTime] = -1;
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
			if(g_iPlayerStats[i][lastDBLoadTime] > 0)
				continue;
			LoadPlayerStats(i, hTransaction);
		}
	}
	
	SQL_ExecuteTransaction(g_hDatabase, hTransaction, SQLTxn_LoadPlayersStats, SQLTxn_LogError);
}

void InsertNewPlayer(int client)
{
	if(!g_hDatabase)
		return;

	if(!IsValidClient(client))
		return;
	
	int iSteamId = GetSteamAccountID(client);
	if(!iSteamId)
		return;
	
	char sQuery[256];
	
	int lastUpdate = GetTime();
	Format(sQuery, sizeof(sQuery), "INSERT INTO %s (steam_id, level, xp, time_played, last_update) VALUES (%d, %i, %i, %i, %i);", g_sDBTableName, iSteamId, g_iPlayerStats[client][level], g_iPlayerStats[client][xp], g_iPlayerStats[client][timePlayed], lastUpdate);
	
	SQL_TQuery(g_hDatabase, DB_InsertNewPlayer, sQuery, GetClientUserId(client));
}

void ClearClientStatsCache(int client)
{
	g_iPlayerStats[client][level] = -1;
	g_iPlayerStats[client][xp] = -1;
	g_iPlayerStats[client][timePlayed] = -1;
	g_iPlayerStats[client][lastDBLoadTime] = -1;
	g_iPlayerStats[client][lastDBSaveTime] = -1;
}

bool SavePlayerStats(int client, Transaction hTransaction=null, bool manual=false)
{
	if(!g_hDatabase)
		return false;
		
	if(!IsValidClient(client))
		return false;

	if(g_iPlayerStats[client][lastDBLoadTime] < 0)
		return false;
	
	if(!manual && ((GetTime() - g_iPlayerStats[client][lastDBSaveTime]) < g_fDBUpdateInterval))
		return false;	
	
	int iSteamId = GetSteamAccountID(client);
	if(!iSteamId)
		return false;
	
	char sQuery[256];
	
	g_iPlayerStats[client][lastDBSaveTime] = GetTime();
	Format(sQuery, sizeof(sQuery), "UPDATE %s SET level = %i, xp = %i, time_played = %i, last_update = %i WHERE steam_id = %d;", g_sDBTableName, g_iPlayerStats[client][level], g_iPlayerStats[client][xp], g_iPlayerStats[client][timePlayed], g_iPlayerStats[client][lastDBSaveTime], iSteamId);
	
	if(hTransaction != null)
		hTransaction.AddQuery(sQuery);
	else
		SQL_TQuery(g_hDatabase, DB_SavePlayerStats, sQuery, GetClientUserId(client));
	
	return true;
}

void SaveAllPlayerStats(bool manual=false)
{
	if(g_hDatabase == null)
		return;
	
	Transaction hTransaction = new Transaction();
	
	for(int i=1;i<=MaxClients;i++)
	{
		if(IsValidClient(i) && IsClientAuthorized(i))
			SavePlayerStats(i, hTransaction, manual);
	}
	
	SQL_ExecuteTransaction(g_hDatabase, hTransaction, SQLTxn_LogSaveSuccecss, SQLTxn_LogError);
}

/* SQL Callbacks */

public void DB_SavePlayerStats(Handle owner, Handle hndl, char [] error, any userid)
{
	if(hndl == INVALID_HANDLE)
	{
		int client = GetClientOfUserId(userid);
		if(IsValidClient(client))
			g_iPlayerStats[client][lastDBSaveTime] = -1;
		
		LogToFileEx(g_sLogPath, "Query failure on save player stats: %s", error);
		return;
	}
}

public void DB_GetPlayerStats(Handle owner, Handle hndl, char [] error, any userid)
{
	int client = GetClientOfUserId(userid);	
	if(!client)
		return;
	
	if(hndl == INVALID_HANDLE)
	{
		LogToFileEx(g_sLogPath, "Query failure on get player stats: %s", error);
		return;
	}
	if(!SQL_GetRowCount(hndl) || !SQL_FetchRow(hndl)) 
	{
		InsertNewPlayer(client);
		return;
	}
	
	g_iPlayerStats[client][level] = SQL_FetchInt(hndl, 1);
	g_iPlayerStats[client][xp] = SQL_FetchInt(hndl, 2);
	g_iPlayerStats[client][timePlayed] = SQL_FetchInt(hndl, 3);
	g_iPlayerStats[client][lastDBLoadTime] = GetTime();
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
		
		g_iPlayerStats[client][level] = results[i].FetchInt(1);
		g_iPlayerStats[client][xp] = results[i].FetchInt(2);
		g_iPlayerStats[client][timePlayed] = results[i].FetchInt(3);
		g_iPlayerStats[client][lastDBLoadTime] = GetTime();
	}
}

public void DB_InsertNewPlayer(Handle owner, Handle hndl, char [] error, any userid)
{
	int client = GetClientOfUserId(userid);
	if(!client)
		return;
	
	if(hndl == INVALID_HANDLE)
	{
		LogToFileEx(g_sLogPath, "Query failure on insert new player: %s", error);
		return;
	}
	
	g_iPlayerStats[client][lastDBLoadTime] = GetTime();
	g_iPlayerStats[client][lastDBSaveTime] = GetTime();
	
	LogToFileEx(g_sLogPath, "New player with steamid %i inserted into database", GetSteamAccountID(client));
}

public void SQLTxn_LogSaveSuccecss(Database db, any data, int numQueries, DBResultSet[] results, any[] queryData)
{
	LogToFileEx(g_sLogPath, "Stats for all players updated in database");
}

public void SQLTxn_LogError(Database db, any data, int numQueries, const char[] error, int failIndex, any[] queryData)
{
	LogToFileEx(g_sLogPath, "Error executing query %d of %d queries: %s", failIndex, numQueries, error);
}

void StartXPTimer(int client)
{
	if(IsValidClient(client))
	{
		if(g_hClientTimer[client] != INVALID_HANDLE)
		{
			CloseHandle(g_hClientTimer[client]);
			g_hClientTimer[client] = INVALID_HANDLE;	
		}
		g_hClientTimer[client] = CreateTimer(g_fXPUpdateInterval, AddExperienceOnTimePlayed, GetClientUserId(client), TIMER_REPEAT);
	}
}

/* Menu stuff */
public int PanelHandler1(Menu menu, MenuAction action, int param1, int param2)
{
	if (action == MenuAction_End)
	{
		CloseHandle(menu);
	}
}
 
public Action Panel_JBStats(int client, int args)
{
	char sXP[128];
	Format(sXP, sizeof(sXP), "XP: %i", g_iPlayerStats[client][xp]);
	
	char sLevel[128];
	Format(sLevel, sizeof(sLevel), "Nivel: %i", g_iPlayerStats[client][level]);
	
	char sTimePlayed[128];
	Format(sTimePlayed, sizeof(sTimePlayed), "Tiempo jugado (seg): %i", g_iPlayerStats[client][timePlayed]);	
	
	char sNeededXP[128];
	Format(sNeededXP, sizeof(sNeededXP), "XP para sig. nivel: %i", nextLevelXP(g_iPlayerStats[client][level]));	
	
	Panel panel = new Panel();
	panel.SetTitle("Estadisticas:");
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

int GetClientOfSteamId(int steamId)
{
	for(int i=1; i<=MaxClients; i++)
	{
		if(steamId == GetSteamAccountID(i))
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