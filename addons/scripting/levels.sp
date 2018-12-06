#pragma semicolon 1
#pragma newdecls required

#include sourcemod
#include <sdktools>

char g_sDBBuffer[3096];

Handle ClientTimer[MAXPLAYERS+1];
Handle g_hDB = INVALID_HANDLE;
Handle gF_OnInsertNewPlayer;

public Plugin myinfo =
{
	name = "Jailbreak Levels",
	author = "BLACK_STAR",
	description = "",
	version = "0.1",
	url = ""
};

public void OnPluginStart()
{
	SQL_TConnect(OnDBConnect, "jblevels");
}

public void OnDBConnect(Handle owner, Handle hndl, char [] error, any data)
{
	if(hndl == INVALID_HANDLE)
	{
		LogError("Database failure: %s", error);
		
		SetFailState("Couldn't connect to database");
	}
	else
	{
		g_hDB = hndl;
		
		SQL_GetDriverIdent(SQL_ReadDriver(g_hDB), g_sDBBuffer, sizeof(g_sDBBuffer));

		Format(g_sDBBuffer, sizeof(g_sDBBuffer), "CREATE TABLE IF NOT EXISTS jblevels (steam_id varchar(32) PRIMARY KEY NOT NULL, time_played INTEGER, level INTEGER)");
		
		SQL_TQuery(g_hDB, OnDBConnectCallback, g_sDBBuffer);
		//LogToFileEx(g_sCmdLogPath, "Query %s", g_sDBBuffer);
		//PruneDatabase();
	}
}

public void OnDBConnectCallback(Handle owner, Handle hndl, char [] error, any data)
{
	if(hndl == INVALID_HANDLE)
	{
		LogError("Query failure: %s", error);
	}
	else
	{
		for(int client = 1; client <= MaxClients; client++)
		{
			if(IsClientInGame(client))
			{
				OnClientPostAdminCheck(client);
			}
		}
	}
}

public void OnClientPutInServer(int client) 
{ 
    if (IsValidClient(client)) 
    { 
        if(!GetClientAuthId(client, AuthId_Engine, g_sUserSteamId[client], sizeof(g_sUserSteamId), true)) //always check for valid return 
            return; 

        FormatEx (g_Query, sizeof (g_Query), "SELECT time_played FROM jblevels WHERE steam_id = '%s' LIMIT 1;", g_sUserSteamId [ client ]); 
        SQL_TQuery (g_DB, LoadPlayerData, g_Query, client); 
    } 

    ClientTimer[client] = (CreateTimer(60.0, TimerAdd, client, TIMER_REPEAT)); 
} 

bool IsValidClient(int client) 
{ 
    if (!(1 <= client <= MaxClients) || !IsClientInGame (client) || IsFakeClient(client)) 
        return false; 

    return true; 
}  