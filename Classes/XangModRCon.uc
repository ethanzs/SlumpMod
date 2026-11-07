/**
 * XangMod remote console. Extends AOCRCon with ChivAdmin's command set plus our own.
 *
 * 0-22 are vanilla, in AOCRCon's MessageType order. 23-28 exist only in the ChivAdmin
 * client (its mutator was never published); implementing them means an unmodified
 * ChivAdmin client works here. 29+ are ours -- unknown opcodes are ignored, so adding
 * them cannot break that client. Full table and payloads: RCON_PROTOCOL.md.
 *
 * Every state-changing command calls XangModAudit: logged, and echoed as
 * RCONX_ADMIN_AUDIT. RCON is password-authenticated but otherwise unrestricted, and
 * opcode 28 is arbitrary execution, so that power should be visible rather than quiet.
 */
class XangModRCon extends AOCRCon;

// ---- ChivAdmin mutator parity ------------------------------------------------
const RCONX_PING_EXTENDED        = 23;
const RCONX_CHANGE_SCORE         = 24;
const RCONX_KILL_PLAYER          = 25;
const RCONX_INEBRIATE            = 26;
const RCONX_CHANGE_GAME_PASSWORD = 27;
const RCONX_CONSOLE_COMMAND      = 28;

// ---- XangMod additions -------------------------------------------------------
const RCONX_PLAYER_LIST_REQUEST  = 29;  // in : (no body)
const RCONX_PLAYER_INFO          = 30;  // out: one per player, see SendPlayerInfo
const RCONX_PLAYER_LIST_END      = 31;  // out: marks the end of a list burst
const RCONX_SET_TEAM             = 32;  // in : QWord uid, int team
const RCONX_FORCE_SPECTATE       = 33;  // in : QWord uid
const RCONX_SET_TEAM_SCORE       = 34;  // in : int team, int score
const RCONX_ADMIN_AUDIT          = 35;  // out: string action, string detail
const RCONX_SERVER_INFO_REQUEST  = 36;  // in : (no body)
const RCONX_SERVER_INFO          = 37;  // out: see SendServerInfo
const RCONX_CONSOLE_RESULT       = 38;  // out: string command, string result
const RCONX_BAN_LIST_REQUEST     = 39;  // in : (no body)
const RCONX_BAN_INFO             = 40;  // out: one per ban, see SendBanInfo
const RCONX_BAN_LIST_END         = 41;  // out: int count
const RCONX_MUTE_PLAYER          = 42;  // in : QWord uid, int mute
const RCONX_SET_PAUSE            = 43;  // in : int paused
const RCONX_END_MATCH            = 44;  // in : int winningTeam, string reason
const RCONX_SET_AUTOBALANCE      = 45;  // in : int enabled
const RCONX_SET_GAME_SPEED       = 46;  // in : int speedPercent (100 = normal)
const RCONX_RESTART_MATCH        = 47;  // in : (no body)
const RCONX_SOBER_PLAYER         = 48;  // in : QWord uid
const RCONX_SET_TOURNAMENT       = 49;  // in : int enabled, int thresholdPercent (0 = leave)
const RCONX_READY_ALL            = 50;  // in : int ready (1 = ready all, 0 = clear all)
const RCONX_SET_FROZEN           = 51;  // in : QWord uid, int frozen
const RCONX_SET_CLASS            = 52;  // in : QWord uid, int classIndex, int immediate
const RCONX_LOADOUT_REQUEST      = 53;  // in : QWord uid
const RCONX_LOADOUT_OPTION       = 54;  // out: QWord uid, int slot, int index, string weapon
const RCONX_LOADOUT_END          = 55;  // out: QWord uid, int prim, int sec, int tert
const RCONX_SET_LOADOUT          = 56;  // in : QWord uid, int prim, int sec, int tert (-1 = leave)
const RCONX_PLAYER_POS_REQUEST   = 57;  // in : (no body)
const RCONX_PLAYER_POS           = 58;  // out: see SendPlayerPositions
const RCONX_PLAYER_POS_END       = 59;  // out: int count
const RCONX_TELEPORT             = 60;  // in : QWord who, QWord toWhom
const RCONX_SLAP                 = 61;  // in : QWord uid, int power
const RCONX_MUTE_LIST_REQUEST    = 62;  // in : (no body)
const RCONX_MUTE_INFO            = 63;  // out: one per muted player, QWord uid, string name, int team
const RCONX_MUTE_LIST_END        = 64;  // out: int count
const RCONX_ROUND_START          = 65;  // out: string map, int roundNumber, int agathaScore, int masonScore, int goalScore
const RCONX_ROUND_END            = 66;  // out: int winningTeam, string map, int roundNumber, int agathaScore, int masonScore, int matchEnding
const RCONX_ROUND_PLAYER_STAT    = 67;  // out: one per player, see SendRoundPlayerStat
const RCONX_ROUND_STAT_END       = 68;  // out: int count
const RCONX_OBJECTIVE_STAGE      = 69;  // out: see SendObjectiveStage

const SLOT_PRIMARY   = 0;
const SLOT_SECONDARY = 1;
const SLOT_TERTIARY  = 2;

const SCOPE_GAME        = 0;
const SCOPE_PLAYER      = 1;
const SCOPE_ALL_PLAYERS = 2;

/**
 * Console verbs RCON refuses to run, matched case-insensitively on the first token.
 * Scope 1 runs on the SERVER-side controller, so "quit" on a player kills the server
 * (confirmed in testing). config(Game) is inherited, so admins can extend this in
 * UDKGame.ini under [XangMod.XangModRCon].
 */
var config array<string> XangModBlockedConsoleCommands;

/** Set while opcode 43 has forced GameInfo.bPauseable on, with the value to put back. */
var bool bXangModPauseForced;
var bool bXangModPauseableWas;

/** Set on a session actor; none on the listener. Distinguishes the two at runtime. */
var XangModRCon ParentLink;

/** Live sessions. Listener only. */
var array<XangModRCon> Sessions;

/** Connection diagnostics for AdminRConStatus. Per session: peer, opened, last data. */
var string XangModRemote;
var float XangModOpenedAt;
var float XangModLastRecvAt;
/** Listener only: port actually bound, and rejected logins this map. */
var int XangModBoundPort;
var int XangModAuthFailures;
var string XangModLastAuthFailure;

/**
 * Persistent text mutes, mirroring AOCAccessControl.BanInfo/Bans. globalconfig so the
 * session subclass shares the listener's section ([XangMod.XangModRCon] in UDKGame.ini) rather than
 * keeping its own copy, and so a mute survives a restart the way a ban does.
 */
struct MuteInfo
{
	var UniqueNetId NetID;
	var string PlayerName;
	var string NetIDAsString;
};

var globalconfig array<MuteInfo> Mutes;

/** Bind retry pacing. A port held by a dying process should not spin the Tick every frame. */
var float XangModNextBindTime;
var int XangModBindFailures;
const BIND_RETRY_INTERVAL = 5.0;

/** Index into the shared mute list, or INDEX_NONE. */
function int XangModFindMute(UniqueNetId NetID)
{
	local int i;

	for (i = 0; i < XangModShared().Mutes.Length; i++)
	{
		if (XangModShared().Mutes[i].NetID == NetID)
			return i;
	}

	return INDEX_NONE;
}

/**
 * Add or drop a persistent mute and write it straight to the ini.
 *
 * SaveConfig is deliberate: AOCAccessControl.UnbanByUID drops the entry from the array and
 * never saves, so the ban is back on the next restart. Not repeating that here.
 */
function XangModRememberMute(UniqueNetId NetID, string PlayerName, bool bMute)
{
	local XangModRCon Listener;
	local MuteInfo MI;
	local int i;

	Listener = XangModShared();
	i = XangModFindMute(NetID);

	if (bMute)
	{
		if (i != INDEX_NONE)
			return;

		MI.NetID         = NetID;
		MI.PlayerName    = PlayerName;
		MI.NetIDAsString = class'OnlineSubsystem'.static.UniqueNetIdToString(NetID);
		Listener.Mutes[Listener.Mutes.Length] = MI;
	}
	else
	{
		if (i == INDEX_NONE)
			return;

		Listener.Mutes.Remove(i, 1);
	}

	Listener.SaveConfig();
}

/**
 * Re-apply a stored mute as the player joins.
 *
 * AOCGame.PostLogin pushes GameEvent_PlayerConnect at the listener, so gating on
 * ParentLink keeps this off the per-session replay SendCurrentGameInfo does for every
 * already-connected player.
 */
function XangModReapplyMute(PlayerReplicationInfo PRI)
{
	local AOCPRI APRI;

	APRI = AOCPRI(PRI);

	if (ParentLink != none || APRI == none || APRI.bIsAdminMuted)
		return;

	if (XangModFindMute(PRI.UniqueId) == INDEX_NONE)
		return;

	APRI.bIsAdminMuted = true;
	APRI.bForceNetUpdate = true;
	XangModAudit("MUTE_REAPPLIED", APRI.PlayerName);
}

/**
 * Bind and listen with the result actually checked.
 *
 * Vanilla AOCRCon does "BindPort(RConPort); if (Listen())" and throws the return away.
 * BindPort returns the port it got, or 0 on failure, so a taken port means Listen() comes up
 * on an OS-assigned one instead: the server logs nothing, reports itself listening, and
 * refuses every client on the configured port. Retries are spaced so a port held by a dying
 * process is recovered without spinning the Tick.
 */
function Tick(float fDeltaTime)
{
	local int Bound;

	// A session must never bind. PostBeginPlay and Closed keep it out of RCON_Initialized,
	// but do not lean on that -- from here vanilla's Tick would grab the listener's own port.
	if (XangModRConSession(self) != none && RConState == RCON_Initialized)
		RConState = RCON_Closing;

	if (RConState == RCON_Connecting && AuthorizationTime + fDeltaTime > AUTHORIZATION_TIMEOUT)
		XangModNoteAuthFailure("no password within 2s");

	if (RConState != RCON_Initialized)
	{
		super.Tick(fDeltaTime);
		return;
	}

	if (WorldInfo.TimeSeconds < XangModNextBindTime)
		return;

	Bound = BindPort(RConPort);
	if (Bound == 0)
	{
		XangModNextBindTime = WorldInfo.TimeSeconds + BIND_RETRY_INTERVAL;
		XangModBindFailures++;
		// First failure, then once a minute. Enough to find in a log, not enough to fill one.
		if (XangModBindFailures == 1 || (XangModBindFailures % 12) == 0)
			LogAlwaysInternal("[XangModRCon] cannot bind port" @ RConPort
				@ "- something else holds it. RCON is NOT accepting connections. Attempt"
				@ XangModBindFailures);
		return;
	}

	if (Bound != RConPort)
		LogAlwaysInternal("[XangModRCon] WARNING: asked for port" @ RConPort @ "but bound" @ Bound
			@ "- clients using the configured port will be refused.");

	if (Listen())
	{
		RConState = RCON_Listening;
		XangModBoundPort = Bound;
		LogAlwaysInternal("[XangModRCon] listening on port" @ Bound);
		return;
	}

	XangModNextBindTime = WorldInfo.TimeSeconds + BIND_RETRY_INTERVAL;
	LogAlwaysInternal("[XangModRCon] bound port" @ Bound @ "but Listen() failed. RCON is NOT accepting connections.");
}

event ReceivedBinary(int Count, byte B[255])
{
	XangModLastRecvAt = WorldInfo.RealTimeSeconds;
	if (RConState == RCON_Connecting && Count != 50)
		XangModNoteAuthFailure("password frame was" @ Count @ "bytes, expected 50");
	super.ReceivedBinary(Count, B);
}

function HandlePassword(AOCRConPacket Packet)
{
	super.HandlePassword(Packet);
	if (RConState == RCON_Connected)
		LogAlwaysInternal("[XangModRCon] authenticated" @ XangModRemote);
	else
		XangModNoteAuthFailure("password rejected");
}

function XangModNoteAuthFailure(string Reason)
{
	local XangModRCon Listener;

	LogAlwaysInternal("[XangModRCon] login failed from" @ XangModRemote $ ":" @ Reason);
	Listener = XangModShared();
	Listener.XangModAuthFailures++;
	Listener.XangModLastAuthFailure = XangModRemote @ "-" @ Reason;
}

/** A game may retain this listener through travel, but never an accepted session. */
function bool XangModCanReuseListener(int RequiredPort)
{
	return !bDeleteMe && XangModRConSession(self) == none && ParentLink == none
		&& RConPort == RequiredPort && AcceptClass == class'XangModRConSession'
		&& (RConState == RCON_Initialized || XangModIsListening());
}

/** A spawned actor is not ready until the native socket is listening on the configured port. */
function bool XangModIsListening()
{
	return !bDeleteMe && XangModRConSession(self) == none && ParentLink == none
		&& RConState == RCON_Listening && LinkState == STATE_Listening
		&& AcceptClass == class'XangModRConSession' && XangModBoundPort == RConPort;
}

function string XangModStateName()
{
	switch (RConState)
	{
		case RCON_Initialized: return "Initialized";
		case RCON_Listening:   return "Listening";
		case RCON_Connecting:  return "Authenticating";
		case RCON_Connected:   return "Connected";
		case RCON_Closing:     return "Closing";
	}
	return "?";
}

/** AdminRConStatus output. Call on the listener. */
function XangModStatusLines(out array<string> Lines)
{
	local AOCRCon Other;
	local int i, Foreign;
	local float Now;

	Now = WorldInfo.RealTimeSeconds;
	Lines.AddItem("RCON listener:" @ XangModStateName() @ "| configured port" @ RConPort @ "| bound" @ XangModBoundPort
		@ "| class default port" @ class'XangModRCon'.default.RConPort @ "| AcceptClass" @ string(AcceptClass));

	foreach WorldInfo.AllActors(class'AOCRCon', Other)
	{
		if (XangModRCon(Other) == none)
			Foreign++;
	}
	if (Foreign > 0)
		Lines.AddItem("WARNING:" @ Foreign @ "non-XangMod AOCRCon actor(s) present.");

	Lines.AddItem("Sessions:" @ Sessions.Length);
	for (i = 0; i < Sessions.Length; i++)
	{
		if (Sessions[i] == none)
			continue;
		Lines.AddItem("  " $ Sessions[i].XangModRemote @ Sessions[i].XangModStateName()
			@ "| open" @ int(Now - Sessions[i].XangModOpenedAt) $ "s"
			@ "| last data" @ (Sessions[i].XangModLastRecvAt > 0 ? int(Now - Sessions[i].XangModLastRecvAt) $ "s ago" : "never"));
	}

	Lines.AddItem("Rejected logins this map:" @ XangModAuthFailures
		$ (XangModLastAuthFailure != "" ? " | last: " $ XangModLastAuthFailure : ""));
}

/** Shared state lives on the listener, so two admins cannot each keep their own copy. */
function XangModRCon XangModShared()
{
	return (ParentLink != none) ? ParentLink : self;
}

/**
 * TcpLink makes the accepting listener the session's owner. Preserve that association
 * when several listeners exist; a global sweep could attach this socket to another port.
 * The game's validated event target is a fallback if ownership is not available yet.
 */
function XangModRCon XangModFindListener()
{
	local XangModRCon Listener;
	local AOCGame Game;

	Listener = XangModRCon(Owner);
	if (Listener != none && Listener.XangModCanReuseListener(Listener.RConPort))
		return Listener;

	Game = AOCGame(WorldInfo.Game);
	if (Game == none)
		return none;
	// Judge the target by its own port: a session's RConPort is the class default, which
	// need not match the port the listener actually bound.
	Listener = XangModRCon(Game.RemoteConsole);
	if (Listener != none && Listener.XangModCanReuseListener(Listener.RConPort))
		return Listener;

	return none;
}

/**
 * AOCRCon leaves AcceptClass unset, so the listening link takes the one connection itself
 * and every later client is dropped at auth. Setting it makes TcpLink spawn a session per
 * connection, each with its own RConState -- many clients, still one port.
 */
event PostBeginPlay()
{
	super.PostBeginPlay();
	AcceptClass = class'XangModRConSession';
	LogAlwaysInternal("[XangModRCon] listener up, AcceptClass=" $ string(AcceptClass));
}

function XangModRegisterSession(XangModRCon Session)
{
	Sessions[Sessions.Length] = Session;
	LogAlwaysInternal("[XangModRCon] session opened (" $ Sessions.Length $ " live)");
}

function XangModUnregisterSession(XangModRCon Session)
{
	local int i;

	i = Sessions.Find(Session);
	if (i == INDEX_NONE)
		return;

	Sessions.Remove(i, 1);
	LogAlwaysInternal("[XangModRCon] session closed (" $ Sessions.Length $ " live)");
}

/**
 * On a session this is that client's socket, so opcode handlers reply only to the client
 * that asked. On the listener it fans out -- that is the path every vanilla GameEvent_*
 * push already takes, so none of them need overriding.
 *
 * AOCRCon.SendPacket DRAINS the packet (Packet.Buffer.Remove after each SendBinary), so
 * the buffer has to be refilled per recipient or only the first session sees anything.
 */
function SendPacket(AOCRConPacket Packet)
{
	local int i;
	local array<byte> Payload;

	if (ParentLink != none)
	{
		super.SendPacket(Packet);
		return;
	}

	Payload = Packet.Buffer;

	for (i = Sessions.Length - 1; i >= 0; i--)
	{
		if (Sessions[i] == none)
		{
			Sessions.Remove(i, 1);
			continue;
		}

		if (Sessions[i].RConState != RCON_Connected)
			continue;

		Packet.Buffer = Payload;
		Sessions[i].SendPacket(Packet);
	}
}


/**
 * One place for "an admin did something". Logs it and puts it on the wire.
 * LogAlwaysInternal rather than the log macro: FINAL_RELEASE builds make LogInternal
 * private and the macro stops compiling.
 */
function XangModAudit(string Action, string Detail)
{
	local AOCRConPacket Packet;

	LogAlwaysInternal("[XangModRCon]" @ Action @ "|" @ Detail);

	Packet = new class'AOCRConPacket';
	Packet.SetMessageType(RCONX_ADMIN_AUDIT);
	Packet.AddString(Action);
	Packet.AddString(Detail);

	// Route via the listener so every connected admin sees it, not just the issuer.
	XangModShared().SendPacket(Packet);
}

/**
 * Bots have no Steam ID, so stamp {A=0, B=PlayerID} like vanilla does at AOCRCon.uc:352 --
 * except that block is inside a notdefined(FINAL_RELEASE) guard, so shipped builds lose it.
 * Real SteamID64s never have a zero high half, so there is no collision.
 */
function EnsureUniqueId(PlayerReplicationInfo PRI)
{
	if (PRI == none)
		return;

	if (PRI.UniqueId.Uid.A == 0 && PRI.UniqueId.Uid.B == 0)
	{
		PRI.UniqueId.Uid.A = 0;
		PRI.UniqueId.Uid.B = PRI.PlayerID;
	}
}

/**
 * GetPlayerControllerFromGUID that also finds bots. Use for anything needing only a Pawn;
 * anything that talks to a client must keep using the PlayerController version.
 */
function Controller GetControllerFromGUID(QWord UniqueId)
{
	local Controller C;

	foreach WorldInfo.AllControllers(class'Controller', C)
	{
		if (C.PlayerReplicationInfo == none)
			continue;

		if (C.PlayerReplicationInfo.UniqueId.Uid == UniqueId)
			return C;
	}

	return none;
}

/** Stamp bots before the connect event goes out, so the client sees them from the start. */
function GameEvent_PlayerConnect(PlayerReplicationInfo PRI)
{
	EnsureUniqueId(PRI);
	XangModReapplyMute(PRI);
	super.GameEvent_PlayerConnect(PRI);
}

/** Name for a uid we may or may not still have a controller for. */
function string DescribePlayer(QWord PlayerId)
{
	local AOCPlayerController PC;

	PC = GetPlayerControllerFromGUID(PlayerId);
	if (PC != none && PC.PlayerReplicationInfo != none)
		return PC.PlayerReplicationInfo.PlayerName;

	return "<unknown uid>";
}

/**
 * Extended opcodes are handled here; everything else falls through to vanilla.
 *
 * Deliberately checks RCON_Connected first. Vanilla's HandleMessage closes the
 * connection on any non-PASSWORD packet while still authenticating, and that behaviour
 * must survive -- an unauthenticated peer must not reach any of this.
 */
function HandleMessage(AOCRConPacket Packet)
{
	// Vanilla opcode 20 is intercepted rather than extended: AOCAccessControl.UnbanByUID
	// removes the entry from the in-memory array and never calls SaveConfig(), so the ban
	// is still in the ini and returns on the next server start. See HandleUnbanFixed.
	if (RConState == RCON_Connected && Packet.MessageType == MessageType.UNBAN_PLAYER)
	{
		HandleUnbanFixed(Packet);
		return;
	}

	// Vanilla opcode 7 is intercepted for the same reason: AOCRCon routes SAY_ALL_BIG to
	// the same HandleSayAll as SAY_ALL, so "big" was only ever a second chat line.
	if (RConState == RCON_Connected && Packet.MessageType == MessageType.SAY_ALL_BIG)
	{
		HandleSayAllBig(Packet);
		return;
	}

	if (RConState == RCON_Connected && Packet.MessageType >= RCONX_PING_EXTENDED)
	{
		switch (Packet.MessageType)
		{
			case RCONX_CHANGE_SCORE:          HandleChangeScore(Packet);        return;
			case RCONX_KILL_PLAYER:           HandleKillPlayer(Packet);         return;
			case RCONX_INEBRIATE:             HandleInebriate(Packet);          return;
			case RCONX_CHANGE_GAME_PASSWORD:  HandleChangeGamePassword(Packet); return;
			case RCONX_CONSOLE_COMMAND:       HandleConsoleCommand(Packet);     return;
			case RCONX_PLAYER_LIST_REQUEST:   HandlePlayerListRequest();        return;
			case RCONX_SET_TEAM:              HandleSetTeam(Packet);            return;
			case RCONX_FORCE_SPECTATE:        HandleForceSpectate(Packet);      return;
			case RCONX_SET_TEAM_SCORE:        HandleSetTeamScore(Packet);       return;
			case RCONX_SERVER_INFO_REQUEST:   SendServerInfo();                 return;
			case RCONX_BAN_LIST_REQUEST:      HandleBanListRequest();           return;
			case RCONX_MUTE_PLAYER:           HandleMutePlayer(Packet);         return;
			case RCONX_MUTE_LIST_REQUEST:     HandleMuteListRequest();          return;
			case RCONX_SET_PAUSE:             HandleSetPause(Packet);           return;
			case RCONX_END_MATCH:             HandleEndMatch(Packet);           return;
			case RCONX_SET_AUTOBALANCE:       HandleSetAutoBalance(Packet);     return;
			case RCONX_SET_GAME_SPEED:        HandleSetGameSpeed(Packet);       return;
			case RCONX_RESTART_MATCH:         HandleRestartMatch();             return;
			case RCONX_SOBER_PLAYER:          HandleSober(Packet);              return;
			case RCONX_SET_TOURNAMENT:        HandleSetTournament(Packet);      return;
			case RCONX_READY_ALL:             HandleReadyAll(Packet);           return;
			case RCONX_SET_FROZEN:            HandleSetFrozen(Packet);          return;
			case RCONX_SET_CLASS:             HandleSetClass(Packet);           return;
			case RCONX_LOADOUT_REQUEST:       HandleLoadoutRequest(Packet);     return;
			case RCONX_SET_LOADOUT:           HandleSetLoadout(Packet);         return;
			case RCONX_PLAYER_POS_REQUEST:    SendPlayerPositions();            return;
			case RCONX_TELEPORT:              HandleTeleport(Packet);           return;
			case RCONX_SLAP:                  HandleSlap(Packet);               return;
			default:
				// Unknown opcode from a client newer than this server. Ignore it
				// rather than dropping the connection.
				LogAlwaysInternal("[XangModRCon] ignoring unknown opcode" @ Packet.MessageType);
				return;
		}
	}

	super.HandleMessage(Packet);
}

/**
 * Vanilla pushes MAP_CHANGED from AOCGame.ProcessServerTravel, before the new level is up,
 * so GetCurrentMap() resolves against the map being left -- and returns "" outright when
 * MapCycleIndex is INDEX_NONE and MapList[-1] yields an empty string. Drop the empty one;
 * XangModGame re-announces once the new map is actually current.
 */
function GameEvent_MapChanged(string mapName, int mapIndex)
{
	if (mapName == "")
		return;

	super.GameEvent_MapChanged(mapName, mapIndex);
}

// XANGMOD: During tournament-mode warmup (pre-round before the round starts / before
// !adminreadyall) players can freely hit and kill teammates. Those warmup kills must not
// reach RCON stat consumers (heir.gg) as real kills/deaths. GameEvent_Kill / GameEvent_Suicide
// are the exact KILL/SUICIDE pushes (AOCPawn.Died) that vanilla opcodes 15/16 emit, so
// suppress them for the same window the pawn-side negates team damage.
function bool IsTournamentWarmup()
{
	local AOCGame G;

	G = AOCGame(WorldInfo.Game);
	if (G == none)
		return false;

	return G.bTournamentMode && G.IsInState('AOCPreRound');
}

function GameEvent_Kill(PlayerReplicationInfo Attacker, PlayerReplicationInfo Victim, AOCWeapon Weapon)
{
	if (IsTournamentWarmup())
		return;

	super.GameEvent_Kill(Attacker, Victim, Weapon);
}

function GameEvent_Suicide(PlayerReplicationInfo Victim)
{
	if (IsTournamentWarmup())
		return;

	super.GameEvent_Suicide(Victim);
}

/* ============================ ChivAdmin parity ============================== */

/** 24: set a player's score. */
function HandleChangeScore(AOCRConPacket Packet)
{
	local QWord PlayerId;
	local int NewScore;
	local AOCPlayerController PC;

	PlayerId = Packet.GetGUID();
	NewScore = Packet.GetInt();

	PC = GetPlayerControllerFromGUID(PlayerId);
	if (PC == none || PC.PlayerReplicationInfo == none)
		return;

	PC.PlayerReplicationInfo.Score = NewScore;
	PC.PlayerReplicationInfo.bNetDirty = true;
	XangModAudit("CHANGE_SCORE", PC.PlayerReplicationInfo.PlayerName @ "->" @ NewScore);
}

/** 25: kill a player where they stand. */
function HandleKillPlayer(AOCRConPacket Packet)
{
	local QWord PlayerId;
	local Controller C;

	PlayerId = Packet.GetGUID();

	C = GetControllerFromGUID(PlayerId);   // Controller-level so bots can be slain.

	if (C == none || C.Pawn == none)
		return;

	XangModAudit("KILL_PLAYER", DescribeController(C));
	C.Pawn.Died(C, class'AOCDmgType_Generic', C.Pawn.Location);
}

/** 26: the drunk screen effect. AOCPlayerController.ClientInebriate drives the HUD. */
function HandleInebriate(AOCRConPacket Packet)
{
	local QWord PlayerId;
	local AOCPlayerController PC;

	PlayerId = Packet.GetGUID();
	PC = GetPlayerControllerFromGUID(PlayerId);
	if (PC == none)
		return;

	XangModAudit("INEBRIATE", PC.PlayerReplicationInfo.PlayerName);

	// ClientInebriate is the whole job. EnableDrunkSoundMode must NOT be called from here:
	// it is a plain function, so on an RCON command it runs on the SERVER's copy of the
	// controller, where it sets a 1s repeating timer that reaches for an audio device the
	// dedicated server does not have. AOCBaseHUD already drives the sound mode on the
	// player's own machine, from its fade in UpdateDrunkEffect.
	//
	// XangMod's ClientInebriate override also adds the drunk post-process chain when the
	// map has none, which is what lifts this off TO2 maps.
	PC.ClientInebriate(true);
}

/**
 * 48: undo 26. ChivAdmin never had this -- its Inebriate command carries only a UID and
 * is one-way, so the effect lasted until the player respawned. Kept as its own opcode
 * rather than adding a flag to 26, so 26 stays wire-compatible with a ChivAdmin client.
 */
function HandleSober(AOCRConPacket Packet)
{
	local QWord PlayerId;
	local AOCPlayerController PC;

	PlayerId = Packet.GetGUID();
	PC = GetPlayerControllerFromGUID(PlayerId);
	if (PC == none)
	{
		XangModAudit("SOBER_FAILED", DescribePlayer(PlayerId) @ "- no player controller with that id");
		return;
	}

	XangModAudit("SOBER", PC.PlayerReplicationInfo.PlayerName);

	// As with 26: client-side only. ToggleDrunkPostEffects(false) turns the sound mode off
	// on the player's machine as part of the same call.
	PC.ClientInebriate(false);
}

/** 27: set (or clear, with an empty string) the server's join password. */
function HandleChangeGamePassword(AOCRConPacket Packet)
{
	local string NewPassword;

	NewPassword = Packet.GetString();

	if (WorldInfo.Game == none || WorldInfo.Game.AccessControl == none)
		return;

	WorldInfo.Game.AccessControl.SetGamePassword(NewPassword);

	// Never log the password itself.
	XangModAudit("CHANGE_GAME_PASSWORD", (NewPassword == "") ? "cleared" : "set");
}

/** True if Command's first token is on XangModBlockedConsoleCommands. */
function bool IsConsoleCommandBlocked(string Command)
{
	local string Verb;
	local int i, SpacePos;

	Verb = Locs(Command);

	while (Left(Verb, 1) == " " || Left(Verb, 1) == Chr(9))
		Verb = Mid(Verb, 1);

	SpacePos = InStr(Verb, " ");
	if (SpacePos != INDEX_NONE)
		Verb = Left(Verb, SpacePos);

	if (Verb == "")
		return false;

	for (i = 0; i < XangModBlockedConsoleCommands.Length; i++)
	{
		if (Locs(XangModBlockedConsoleCommands[i]) == Verb)
			return true;
	}

	return false;
}

/**
 * 28: run a console command. The most powerful thing here, hence the loudest audit.
 *
 * Scope 1 targets the SERVER-SIDE controller for that player, so it runs server
 * functions and admin execs against them. It does not execute on their machine.
 */
function HandleConsoleCommand(AOCRConPacket Packet)
{
	local QWord PlayerId;
	local int Scope;
	local string Command;
	local AOCPlayerController PC;
	local int Count;

	PlayerId = Packet.GetGUID();
	Scope    = Packet.GetInt();
	Command  = Packet.GetString();

	// All three scopes run in the server's process, so one check covers them.
	if (IsConsoleCommandBlocked(Command))
	{
		XangModAudit("CONSOLE_COMMAND(blocked)", Command);
		SendConsoleResult(Command, "Blocked: this command would take the server down."
			@ "Edit XangModBlockedConsoleCommands in UDKGame.ini to change the list.");
		return;
	}

	switch (Scope)
	{
		case SCOPE_GAME:
			XangModAudit("CONSOLE_COMMAND(game)", Command);
			if (WorldInfo.Game != none)
				SendConsoleResult(Command, WorldInfo.Game.ConsoleCommand(Command));
			break;

		case SCOPE_PLAYER:
			PC = GetPlayerControllerFromGUID(PlayerId);
			if (PC == none)
				return;
			XangModAudit("CONSOLE_COMMAND(player)", DescribePlayer(PlayerId) @ ":" @ Command);
			SendConsoleResult(Command, PC.ConsoleCommand(Command));
			break;

		case SCOPE_ALL_PLAYERS:
			foreach WorldInfo.AllControllers(class'AOCPlayerController', PC)
			{
				PC.ConsoleCommand(Command);
				Count++;
			}
			XangModAudit("CONSOLE_COMMAND(all)", Command @ "on" @ Count @ "players");
			break;
	}
}

/* ============================ XangMod additions ============================= */

/**
 * 29 -> a burst of 30s then a 31.
 * ChivAdmin's PING event only carries uid and ping; this is the whole scoreboard.
 * NumKills rather than Kills: AOCPRI comments that Kills is not replicated.
 */
function HandlePlayerListRequest()
{
	local PlayerReplicationInfo PRI;
	local AOCRConPacket Packet;
	local int i;

	if (WorldInfo.GRI == none)
	{
		XangModAudit("PLAYER_LIST_FAILED", "no GameReplicationInfo yet");
		Packet = new class'AOCRConPacket';
		Packet.SetMessageType(RCONX_PLAYER_LIST_END);
		SendPacket(Packet);
		return;
	}

	for (i = 0; i < WorldInfo.GRI.PRIArray.Length; i++)
	{
		PRI = WorldInfo.GRI.PRIArray[i];
		if (PRI == none)
			continue;

		// Bots present before RCON connected never fired the connect event.
		EnsureUniqueId(PRI);

		SendPlayerInfo(PRI);
	}

	Packet = new class'AOCRConPacket';
	Packet.SetMessageType(RCONX_PLAYER_LIST_END);
	Packet.AddInt(WorldInfo.GRI.PRIArray.Length);
	SendPacket(Packet);
}

/** 30: uid, name, team, score, deaths, kills, ping, health, teamDamage, class, spectator */
function SendPlayerInfo(PlayerReplicationInfo PRI)
{
	local AOCRConPacket Packet;
	local AOCPRI APRI;
	local string ClassName;

	APRI = AOCPRI(PRI);

	ClassName = "";
	if (APRI != none && APRI.MyFamilyInfo != none)
		ClassName = string(APRI.MyFamilyInfo.Name);

	Packet = new class'AOCRConPacket';
	Packet.SetMessageType(RCONX_PLAYER_INFO);
	Packet.AddQWord(PRI.UniqueId.Uid);
	Packet.AddString(PRI.PlayerName);
	Packet.AddInt((PRI.Team != none) ? PRI.Team.TeamIndex : -1);
	Packet.AddInt(int(PRI.Score));
	Packet.AddInt(PRI.Deaths);
	Packet.AddInt((APRI != none) ? APRI.NumKills : 0);
	// PRI.Ping is quarter-ms (PlayerController.ServerUpdatePing); opcode 23 sends raw ms.
	// Scale so both agree. Saturates at 1000ms.
	Packet.AddInt(PRI.Ping * 4);
	Packet.AddInt((APRI != none) ? APRI.CurrentHealth : 0);
	Packet.AddInt((APRI != none) ? APRI.TeamDamageDealt : 0);
	Packet.AddString(ClassName);
	Packet.AddInt((APRI != none && APRI.bIsVoluntarySpectator) ? 1 : 0);
	SendPacket(Packet);
}

/** 32: move a player to a team. */
function HandleSetTeam(AOCRConPacket Packet)
{
	local QWord PlayerId;
	local int NewTeam;
	local AOCPlayerController PC;

	PlayerId = Packet.GetGUID();
	NewTeam  = Packet.GetInt();

	PC = GetPlayerControllerFromGUID(PlayerId);
	if (PC == none || WorldInfo.Game == none)
		return;

	XangModForceTeam(PC, NewTeam);
}

/**
 * Move a player between Agatha and Mason.
 *
 * NOT WorldInfo.Game.ChangeTeam: AOCGame.ChangeTeam ignores its team argument and
 * re-resolves from CurrentFamilyInfo.FamilyFaction, so it always returns false. Changing
 * CurrentFamilyInfo first is the only thing that moves anyone -- same approach as
 * AOCGame.PerformDeathBasedAB. AOCGRI.FamilyInfos: 0-4 Agatha, 5-9 Mason.
 */
function XangModForceTeam(AOCPlayerController PC, int NewTeam)
{
	local AOCFamilyInfo NewFamily;
	local AOCGRI GRI;
	local int Index;
	local EAOCFaction Target;

	GRI = AOCGRI(WorldInfo.GRI);
	if (GRI == none || PC.CurrentFamilyInfo == none)
	{
		XangModAudit("SET_TEAM_FAILED", DescribeController(PC) @ "- no GRI or player has not picked a class yet");
		return;
	}

	Target = (NewTeam == 1) ? EFAC_MASON : EFAC_AGATHA;

	if (PC.CurrentFamilyInfo.FamilyFaction == Target)
	{
		XangModAudit("SET_TEAM_NOOP", DescribeController(PC) @ "- already on" @ (Target == EFAC_MASON ? "Mason" : "Agatha"));
		return;
	}

	Index = PC.CurrentFamilyInfo.default.ClassReference;
	if (Target == EFAC_MASON)
		Index += 5;

	if (Index < 0 || Index > 9)
	{
		XangModAudit("SET_TEAM_FAILED", DescribeController(PC) @ "- bad family index" @ Index);
		return;
	}

	NewFamily = GRI.FamilyInfos[Index];
	if (NewFamily == none)
	{
		XangModAudit("SET_TEAM_FAILED", DescribeController(PC) @ "- FamilyInfos[" $ Index $ "] is none");
		return;
	}

	// Order matters and is taken from PerformDeathBasedAB: tell the client to drop any
	// pending team selection and update its HUD, then set the class server-side.
	PC.ClientAutoBalance(NewFamily);

	// bForceSwitch=true (rather than autobalance's false) is what sets bMarkNewTeam and
	// kills the current pawn, so the swap lands immediately instead of on next respawn.
	PC.SetNewClass(NewFamily, false, true);
	AOCPRI(PC.PlayerReplicationInfo).MyFamilyInfo = none;

	// CurrentFamilyInfo now points at the new faction, so ChangeTeam finally resolves
	// to the other team. ServerChangeTeam consumes bMarkNewTeam for the broadcast.
	PC.ServerChangeTeam(NewFamily.FamilyFaction);

	XangModAudit("SET_TEAM", DescribeController(PC) @ "->" @ (Target == EFAC_MASON ? "Mason" : "Agatha") @ "as" @ NewFamily);
}

/** Same idea as DescribePlayer, but when the controller is already resolved. */
// Controller rather than AOCPlayerController so bots (AOCBot) describe too.
function string DescribeController(Controller PC)
{
	if (PC != none && PC.PlayerReplicationInfo != none)
		return PC.PlayerReplicationInfo.PlayerName;

	return "<unknown player>";
}

/**
 * 7: the big broadcast. AOCBaseHUD.Announce is an empty stub, so the objective header
 * banner is the only vanilla path that puts arbitrary text on a player's screen.
 * Chat still gets the line, because the banner clears itself after a few seconds.
 */
function HandleSayAllBig(AOCRConPacket Packet)
{
	local AOCPlayerController PC;
	local AOCGame Game;
	local string Message;
	local int Shown;

	Message = Packet.GetString();
	if (Message == "")
	{
		XangModAudit("SAY_ALL_BIG_FAILED", "empty message");
		return;
	}

	foreach WorldInfo.AllControllers(class'AOCPlayerController', PC)
	{
		PC.ClientShowLocalizedHeaderText(Message);
		Shown++;
	}

	Game = AOCGame(WorldInfo.Game);
	if (Game != none)
		Game.BroadcastMessage(none, Message, EFAC_ALL, true);

	XangModAudit("SAY_ALL_BIG", Message @ "->" @ string(Shown) @ "players");
}

/**
 * 20 (vanilla): unban by UID, but persisted.
 *
 * AOCAccessControl.UnbanByUID never calls SaveConfig (AddBan does), so the ban returns
 * on restart. Removing it here lets us save, and report whether anything was removed.
 */
function HandleUnbanFixed(AOCRConPacket Packet)
{
	local UniqueNetId NetID;
	local AOCAccessControl AC;
	local string Removed;
	local int i, PolicyIndex;

	NetID.Uid = Packet.GetGUID();

	if (WorldInfo.Game == none)
		return;

	AC = AOCAccessControl(WorldInfo.Game.AccessControl);
	if (AC == none)
	{
		XangModAudit("UNBAN_FAILED", "no AOCAccessControl");
		return;
	}

	// Find it first purely so the audit line can name who was unbanned; the removal
	// itself goes through the stock function rather than poking AC.Bans directly.
	for (i = 0; i < AC.Bans.Length; i++)
	{
		if (AC.Bans[i].NetID == NetID)
		{
			Removed = AC.Bans[i].PlayerName @ "(" $ AC.Bans[i].NetIDAsString $ ")";
			break;
		}
	}

	// Not in Bans, but it may still be in the stock uid list that Super.IsIDBanned
	// enforces. UnbanByUID only touches Bans, so without this an entry the ban list now
	// shows as "(uid ban list)" could be unbanned forever and never actually lift.
	if (Removed == "")
	{
		for (i = 0; i < AC.BannedIDs.Length; i++)
		{
			if (!(AC.BannedIDs[i] == NetID))
				continue;

			Removed = "(uid ban list) (" $ class'OnlineSubsystem'.static.UniqueNetIdToString(NetID) $ ")";

			// KickBanPlayer wrote a DENY line alongside this uid, so lifting the ban has to
			// take both or the ini fills with orphans. Resolved before the removal, since the
			// pairing test compares the two array lengths.
			PolicyIndex = XangModPoliciesPairBans(AC) ? XangModNthDenyPolicy(AC, i) : INDEX_NONE;

			AC.BannedIDs.Remove(i, 1);
			if (PolicyIndex != INDEX_NONE)
			{
				Removed @= "and its policy line" @ AC.IPPolicies[PolicyIndex];
				AC.IPPolicies.Remove(PolicyIndex, 1);
			}

			AC.SaveConfig();
			XangModAudit("UNBAN", Removed);
			return;
		}
	}

	if (Removed == "")
	{
		XangModAudit("UNBAN_FAILED", "no ban matching uid" @ NetID.Uid.A @ NetID.Uid.B
			@ "- request the ban list (opcode 39) and unban with a uid from it");
		return;
	}

	AC.UnbanByUID(NetID);

	// The bit vanilla forgets. Without this the array is clean in memory but the ini
	// still lists the ban, so it comes straight back on the next server start.
	AC.SaveConfig();

	XangModAudit("UNBAN", Removed);
}

/** 33: force a player into spectate. Mirrors XangMod's AdminForceSpectate. */
function HandleForceSpectate(AOCRConPacket Packet)
{
	local QWord PlayerId;
	local AOCPlayerController PC;

	PlayerId = Packet.GetGUID();
	PC = GetPlayerControllerFromGUID(PlayerId);
	if (PC == none)
		return;

	XangModAudit("FORCE_SPECTATE", DescribePlayer(PlayerId));
	PC.JoinSpectatorTeam();
}

/**
 * 34: set a team's score.
 *
 * LTS is the odd one: AOCLTS.RoundScores is authoritative, AOCLTSGRI.RoundsWon is drawn,
 * and Teams[].Score is a mirror rewritten from RoundScores at every round boundary
 * (AOCLTS.uc:216-219, :316). Writing the mirror alone is silently discarded. All three here.
 */
function HandleSetTeamScore(AOCRConPacket Packet)
{
	local int TeamIndex, NewScore, Goal;
	local AOCLTS LTS;

	TeamIndex = Packet.GetInt();
	NewScore  = Packet.GetInt();

	if (WorldInfo.GRI == none || TeamIndex < 0 || TeamIndex >= WorldInfo.GRI.Teams.Length)
		return;
	if (WorldInfo.GRI.Teams[TeamIndex] == none)
		return;

	WorldInfo.GRI.Teams[TeamIndex].Score = NewScore;
	WorldInfo.GRI.Teams[TeamIndex].bForceNetUpdate = true;

	LTS = AOCLTS(WorldInfo.Game);
	if (LTS != none && TeamIndex < LTS.RoundScores.Length)
	{
		LTS.RoundScores[TeamIndex] = NewScore;

		if (AOCLTSGRI(LTS.GameReplicationInfo) != none)
		{
			AOCLTSGRI(LTS.GameReplicationInfo).RoundsWon[TeamIndex] = NewScore;
			LTS.GameReplicationInfo.bForceNetUpdate = true;
		}

		// AOCLTS.uc:331 tests RoundScores[winner] == GoalScore AFTER incrementing it, so a
		// team parked ON the goal steps over it and the match never ends. GoalScore - 1 is
		// what makes the next round decisive.
		Goal = LTS.GoalScore;
		if (Goal > 0 && NewScore >= Goal)
		{
			XangModAudit("SET_TEAM_SCORE_WARNING",
				"team" @ TeamIndex @ "is at or past the goal of" @ Goal
				$ " - the end-of-round check is an exact match, so set" @ (Goal - 1)
				@ "if the next round should decide it");
		}
	}

	XangModAudit("SET_TEAM_SCORE", "team" @ TeamIndex @ "->" @ NewScore
		@ (LTS != none ? "(rounds won)" : ""));
}

/** 37: map, player count, and match state. */
function SendServerInfo()
{
	local AOCRConPacket Packet;

	Packet = new class'AOCRConPacket';
	Packet.SetMessageType(RCONX_SERVER_INFO);
	Packet.AddString(WorldInfo.GetMapName(true));
	Packet.AddInt((WorldInfo.Game != none) ? WorldInfo.Game.NumPlayers : 0);
	Packet.AddInt((WorldInfo.Game != none) ? WorldInfo.Game.MaxPlayers : 0);
	Packet.AddInt((WorldInfo.GRI != none && WorldInfo.GRI.bMatchHasBegun) ? 1 : 0);
	Packet.AddInt((WorldInfo.Game != none) ? WorldInfo.Game.NumSpectators : 0);
	SendPacket(Packet);
}

/**
 * 65: a real round has started (never warmup -- these are pushed from
 * XangModGame.StartRound, which the game only calls out of the pre-round).
 * Called from the game mode, so no state change to audit here.
 */
function SendRoundStart(string MapName, int RoundNumber, int AgathaScore, int MasonScore, int GoalScore)
{
	local AOCRConPacket Packet;

	Packet = new class'AOCRConPacket';
	Packet.SetMessageType(RCONX_ROUND_START);
	Packet.AddString(MapName);
	Packet.AddInt(RoundNumber);
	Packet.AddInt(AgathaScore);
	Packet.AddInt(MasonScore);
	Packet.AddInt(GoalScore);
	SendPacket(Packet);
}

/**
 * 66: a real round has ended, with the team that won it. winningTeam is a raw
 * EAOCFaction int (0 = Agatha, 1 = Mason), -1 for a draw/none. matchEnding is 1
 * when this round also ends the match (LTS reaching GoalScore, or TD/TO where one
 * round IS the match), so the client can tell round from map boundaries.
 */
function SendRoundEnd(int WinningTeam, string MapName, int RoundNumber, int AgathaScore, int MasonScore, int MatchEnding)
{
	local AOCRConPacket Packet;

	Packet = new class'AOCRConPacket';
	Packet.SetMessageType(RCONX_ROUND_END);
	Packet.AddInt(WinningTeam);
	Packet.AddString(MapName);
	Packet.AddInt(RoundNumber);
	Packet.AddInt(AgathaScore);
	Packet.AddInt(MasonScore);
	Packet.AddInt(MatchEnding);
	SendPacket(Packet);
}

/**
 * 67: one player's cumulative match stats, sent as part of the ROUND_END burst.
 * uid is the same synthetic {A=0,B=PlayerID} stamp bots get, so a consumer can
 * correlate against PLAYER_CONNECT / PLAYER_INFO.
 */
function SendRoundPlayerStat(QWord Uid, int Team, string PlayerName, int Kills, int Deaths,
	int Assists, int Score, int EnemyDamage, int TeamDamage, int DamageTaken, int Parries,
	int Feints, int MeleeHits, int ProjectileHits, int Blocks, int Dodges)
{
	local AOCRConPacket Packet;

	Packet = new class'AOCRConPacket';
	Packet.SetMessageType(RCONX_ROUND_PLAYER_STAT);
	Packet.AddQWord(Uid);
	Packet.AddInt(Team);
	Packet.AddString(PlayerName);
	Packet.AddInt(Kills);
	Packet.AddInt(Deaths);
	Packet.AddInt(Assists);
	Packet.AddInt(Score);
	Packet.AddInt(EnemyDamage);
	Packet.AddInt(TeamDamage);
	Packet.AddInt(DamageTaken);
	Packet.AddInt(Parries);
	Packet.AddInt(Feints);
	Packet.AddInt(MeleeHits);
	Packet.AddInt(ProjectileHits);
	Packet.AddInt(Blocks);
	Packet.AddInt(Dodges);
	SendPacket(Packet);
}

/** 68: closes a 67 burst. Count is the number of player-stat packets sent. */
function SendRoundStatEnd(int Count)
{
	local AOCRConPacket Packet;

	Packet = new class'AOCRConPacket';
	Packet.SetMessageType(RCONX_ROUND_STAT_END);
	Packet.AddInt(Count);
	SendPacket(Packet);
}

/**
 * 69: one Team Objective stage has ended. stage is 1-based, in the map's Register
 * Objective Sequence order. outcome is 1 completed by the attackers, 2 skipped, 0 still
 * standing when the match ended. attackingTeam is a raw EAOCFaction int (0 = Agatha,
 * 1 = Mason, -1 unknown). completed and skipped are the running counts for this round,
 * this stage included. timeLeft is the round clock in seconds before any bonus time.
 */
function SendObjectiveStage(string MapName, int RoundNumber, int Stage, int TotalStages, int Outcome,
	int AttackingTeam, int Completed, int Skipped, int SecondsLeft)
{
	local AOCRConPacket Packet;

	Packet = new class'AOCRConPacket';
	Packet.SetMessageType(RCONX_OBJECTIVE_STAGE);
	Packet.AddString(MapName);
	Packet.AddInt(RoundNumber);
	Packet.AddInt(Stage);
	Packet.AddInt(TotalStages);
	Packet.AddInt(Outcome);
	Packet.AddInt(AttackingTeam);
	Packet.AddInt(Completed);
	Packet.AddInt(Skipped);
	Packet.AddInt(SecondsLeft);
	SendPacket(Packet);
}

/** 23: the richer per-player ping event, sent at vanilla's own ping cadence. */
function GameEvent_UpdatePing(PlayerReplicationInfo PRI, int NewPing)
{
	local AOCRConPacket Packet;
	local AOCPRI APRI;

	APRI = AOCPRI(PRI);

	// Replaces vanilla opcode 22 rather than sitting alongside it, which is the same swap
	// the ChivAdmin mutator made, and the field order matches theirs so a ChivAdmin client
	// reads it unchanged.
	//
	// This overrides the vanilla hook deliberately: GameEvent_UpdatePing is the ONLY ping
	// entry point the game calls (AOCPlayerController.uc:8446). There is no separate
	// "extended" hook to add, so a new function here would simply never run.
	Packet = new class'AOCRConPacket';
	Packet.SetMessageType(RCONX_PING_EXTENDED);
	Packet.AddQWord(PRI.UniqueId.Uid);
	Packet.AddInt(NewPing);
	Packet.AddInt(int(PRI.Score));

	// AOCPRI.IdleTime is a byte holding quarter-scale seconds
	// (AOCPRI.uc:558 -- Min(Round(elapsed) / 4, 255)), so it is scaled back to seconds
	// here and saturates at 1020s / 17 minutes.
	Packet.AddInt((APRI != none) ? APRI.IdleTime * 4 : 0);
	Packet.AddInt((APRI != none) ? APRI.NumKills : 0);
	Packet.AddInt((APRI != none) ? APRI.TeamDamageDealt : 0);
	Packet.AddInt((APRI != none) ? APRI.MyRank : 0);
	SendPacket(Packet);
}

/* ============================ wave two ====================================== */

/**
 * 38: hand back whatever the command printed. Vanilla discards ConsoleCommand's return,
 * so query commands were invisible. Empty results are still sent, so every request pairs.
 */
function SendConsoleResult(string Command, string Result)
{
	local AOCRConPacket Packet;

	Packet = new class'AOCRConPacket';
	Packet.SetMessageType(RCONX_CONSOLE_RESULT);
	Packet.AddString(Command);
	Packet.AddString(Result);
	SendPacket(Packet);
}

/* --- ban-list helpers: Chivalry keeps its bans in three places, see below --- */

/**
 * "DENY,<addr>" or "DENY;<addr>" -- the address may be empty. ACCEPT lines and anything
 * without a separator are not DENY policies.
 */
function bool XangModIsDenyPolicy(string Policy)
{
	local int Sep;

	Sep = InStr(Policy, ",");
	if (Sep == INDEX_NONE)
		Sep = InStr(Policy, ";");

	return Sep != INDEX_NONE && Left(Policy, Sep) ~= "DENY";
}

/** The address half of a policy line, "" when the line carries none. */
function string XangModPolicyAddress(string Policy)
{
	local int Sep;

	Sep = InStr(Policy, ",");
	if (Sep == INDEX_NONE)
		Sep = InStr(Policy, ";");

	return (Sep == INDEX_NONE) ? "" : Mid(Policy, Sep + 1);
}

/**
 * True when every banned uid has exactly one DENY line, i.e. the two arrays are in lockstep
 * and the Nth DENY line can be trusted to belong to the Nth banned uid.
 *
 * AOCAccessControl.KickBanPlayer appends "DENY," $ IP and then BannedIDs.AddItem in the same
 * call, so Chivalry writes them as a pair, in that order, every time. The address is empty in
 * practice because that function does Left(IP, InStr(IP, ":")) and a Steam socket address
 * carries no ":port" -- InStr returns -1 and Left(IP, -1) is "". Counting rather than assuming
 * keeps a hand-edited ini (an admin's own DENY line, say) from having the wrong entry removed.
 */
function bool XangModPoliciesPairBans(AOCAccessControl AC)
{
	local int i, Denies;

	for (i = 0; i < AC.IPPolicies.Length; i++)
	{
		if (XangModIsDenyPolicy(AC.IPPolicies[i]))
			Denies++;
	}

	return AC.BannedIDs.Length > 0 && Denies == AC.BannedIDs.Length;
}

/** Index into IPPolicies of the Nth DENY line, or INDEX_NONE. */
function int XangModNthDenyPolicy(AOCAccessControl AC, int Ordinal)
{
	local int i, Seen;

	for (i = 0; i < AC.IPPolicies.Length; i++)
	{
		if (!XangModIsDenyPolicy(AC.IPPolicies[i]))
			continue;

		if (Seen == Ordinal)
			return i;

		Seen++;
	}

	return INDEX_NONE;
}

/**
 * 39 -> a burst of 40s then a 41. Vanilla can unban but never shows the list, so you had
 * to know the uid.
 *
 * Three stores, all of them live, all of them reported here:
 *   AOCAccessControl.Bans        name, reason, duration. Written by AddBan/KickBanGlobal --
 *                                the RCON ban, votekick, the ping kick.
 *   Engine.AccessControl.BannedIDs   bare uids, written by the console "admin kickban" and by
 *                                AOCAccessControl.KickBanPlayer. Enforced, because
 *                                AOCAccessControl.IsIDBanned ends with Super.IsIDBanned.
 *   Engine.AccessControl.IPPolicies  DENY lines, enforced through Super.CheckIPPolicy.
 *
 * KickBanPlayer writes a DENY line and a BannedIDs entry together, so in practice the last
 * two pair up one-for-one and are reported as a single row.
 */
function HandleBanListRequest()
{
	local AOCAccessControl AC;
	local AOCRConPacket Packet;
	local QWord ZeroId;
	local UniqueNetId LegacyId;
	local string Policy;
	local bool bAlreadyListed, bPaired;
	local int i, j, PolicyIndex, Count, LegacyUids, LegacyIPs;

	if (WorldInfo.Game == none)
		return;

	AC = AOCAccessControl(WorldInfo.Game.AccessControl);
	if (AC == none)
	{
		// Terminate the burst anyway. Returning without a BAN_LIST_END leaves the client
		// waiting forever, which on screen is indistinguishable from an empty ban list.
		XangModAudit("BAN_LIST_FAILED", "AccessControl is not an AOCAccessControl");
		Packet = new class'AOCRConPacket';
		Packet.SetMessageType(RCONX_BAN_LIST_END);
		Packet.AddInt(0);
		SendPacket(Packet);
		return;
	}

	for (i = 0; i < AC.Bans.Length; i++)
	{
		Packet = new class'AOCRConPacket';
		Packet.SetMessageType(RCONX_BAN_INFO);
		Packet.AddQWord(AC.Bans[i].NetID.Uid);
		Packet.AddString(AC.Bans[i].PlayerName);
		Packet.AddString(AC.Bans[i].Reason);
		Packet.AddInt(AC.Bans[i].DurationSeconds);
		Packet.AddString(AC.Bans[i].NetIDAsString);
		Packet.AddString(AC.Bans[i].IPPolicy);
		SendPacket(Packet);
		Count++;
	}

	// There is a SECOND live ban store. AOCAccessControl.IsIDBanned ends with
	// "return bBanned || Super.IsIDBanned(NetID)", so Engine.AccessControl.BannedIDs is
	// still enforced -- it just carries no name, reason or duration. AddBan/KickBanGlobal
	// (the RCON ban, votekick, ping kick) write to Bans; the console "admin kickban" and
	// AOCAccessControl.KickBanPlayer write to BannedIDs instead. Reporting only Bans meant
	// a server could be enforcing bans this list never showed.
	bPaired = XangModPoliciesPairBans(AC);

	for (i = 0; i < AC.BannedIDs.Length; i++)
	{
		bAlreadyListed = false;
		for (j = 0; j < AC.Bans.Length; j++)
		{
			if (AC.Bans[j].NetID == AC.BannedIDs[i])
			{
				bAlreadyListed = true;
				break;
			}
		}

		if (bAlreadyListed)
			continue;

		// Show the paired DENY line in the IP column, but only when it names an address --
		// Chivalry writes a bare "DENY," for every Steam-socket ban and that is not worth a
		// column of noise.
		PolicyIndex = bPaired ? XangModNthDenyPolicy(AC, i) : INDEX_NONE;
		Policy = "";
		if (PolicyIndex != INDEX_NONE && XangModPolicyAddress(AC.IPPolicies[PolicyIndex]) != "")
			Policy = AC.IPPolicies[PolicyIndex];

		LegacyId = AC.BannedIDs[i];
		Packet = new class'AOCRConPacket';
		Packet.SetMessageType(RCONX_BAN_INFO);
		Packet.AddQWord(LegacyId.Uid);
		Packet.AddString("(uid ban list)");
		Packet.AddString("Banned by console kickban -- no name or reason recorded");
		Packet.AddInt(0);
		Packet.AddString(class'OnlineSubsystem'.static.UniqueNetIdToString(LegacyId));
		Packet.AddString(Policy);
		SendPacket(Packet);
		Count++;
		LegacyUids++;
	}

	// And a third store: DENY lines that belong to nobody. Super.CheckIPPolicy walks
	// IPPolicies, so these are live bans too. Skipped entirely when the arrays pair up,
	// since then every DENY line was already reported on its uid's row above.
	for (i = 0; !bPaired && i < AC.IPPolicies.Length; i++)
	{
		Policy = AC.IPPolicies[i];

		// An empty mask matches no address in Engine.AccessControl.CheckIPPolicy, so a bare
		// "DENY," is inert -- listing it as a ban would be a lie.
		if (!XangModIsDenyPolicy(Policy) || XangModPolicyAddress(Policy) == "")
			continue;

		bAlreadyListed = false;
		for (j = 0; j < AC.Bans.Length; j++)
		{
			if (AC.Bans[j].IPPolicy ~= Policy)
			{
				bAlreadyListed = true;
				break;
			}
		}

		if (bAlreadyListed)
			continue;

		Packet = new class'AOCRConPacket';
		Packet.SetMessageType(RCONX_BAN_INFO);
		Packet.AddQWord(ZeroId);
		Packet.AddString("(ip ban)");
		Packet.AddString("IP policy -- remove from IPPolicies in the server ini to lift");
		Packet.AddInt(0);
		Packet.AddString("");
		Packet.AddString(Policy);
		SendPacket(Packet);
		Count++;
		LegacyIPs++;
	}

	// One audit line per refresh, naming what each store holds. When the list looks empty
	// this is what says whether the server has nothing or the bans are somewhere we do not
	// read -- worth far more than guessing from a blank grid.
	XangModAudit("BAN_LIST", "Bans=" $ AC.Bans.Length $ " BannedIDs=" $ AC.BannedIDs.Length
		$ " (" $ LegacyUids $ " extra) IPPolicies=" $ AC.IPPolicies.Length
		$ " (" $ LegacyIPs $ " loose DENY) paired=" $ (bPaired ? "yes" : "no") $ " sent=" $ Count);

	Packet = new class'AOCRConPacket';
	Packet.SetMessageType(RCONX_BAN_LIST_END);
	Packet.AddInt(Count);
	SendPacket(Packet);
}

/**
 * 62: list the players currently muted.
 *
 * Mute is AOCPRI.bIsAdminMuted, per-connection state -- there is no persistent mute list
 * the way AOCAccessControl keeps one for bans. So this reports connected players only,
 * and a mute is forgotten when the player disconnects or the server restarts.
 */
function HandleMuteListRequest()
{
	local AOCPlayerController PC;
	local AOCPRI APRI, Online;
	local AOCRConPacket Packet;
	local int i, Count, Live;

	for (i = 0; i < XangModShared().Mutes.Length; i++)
	{
		Online = none;
		foreach WorldInfo.AllControllers(class'AOCPlayerController', PC)
		{
			APRI = AOCPRI(PC.PlayerReplicationInfo);
			if (APRI != none && APRI.UniqueId == XangModShared().Mutes[i].NetID)
			{
				Online = APRI;
				break;
			}
		}

		Packet = new class'AOCRConPacket';
		Packet.SetMessageType(RCONX_MUTE_INFO);
		Packet.AddQWord(XangModShared().Mutes[i].NetID.Uid);
		Packet.AddString((Online != none) ? Online.PlayerName : XangModShared().Mutes[i].PlayerName);
		Packet.AddInt((Online != none && Online.Team != none) ? Online.Team.TeamIndex : -1);
		Packet.AddInt((Online != none) ? 1 : 0);
		Packet.AddInt(1);
		SendPacket(Packet);
		Count++;
	}

	// The ban list's problem again, in the other store. AOCPlayerController.ServerAdminMutePlayer
	// -- the escape-menu admin mute -- writes AOCPRI.bIsAdminMuted straight and never reaches the
	// stored list, so an in-game mute was live and invisible here. Reported with stored=0: real,
	// but gone the moment that player disconnects.
	foreach WorldInfo.AllControllers(class'AOCPlayerController', PC)
	{
		APRI = AOCPRI(PC.PlayerReplicationInfo);
		if (APRI == none || !APRI.bIsAdminMuted)
			continue;

		if (XangModFindMute(APRI.UniqueId) != INDEX_NONE)
			continue;

		Packet = new class'AOCRConPacket';
		Packet.SetMessageType(RCONX_MUTE_INFO);
		Packet.AddQWord(APRI.UniqueId.Uid);
		Packet.AddString(APRI.PlayerName);
		Packet.AddInt((APRI.Team != none) ? APRI.Team.TeamIndex : -1);
		Packet.AddInt(1);
		Packet.AddInt(0);
		SendPacket(Packet);
		Count++;
		Live++;
	}

	// Same reasoning as the ban list: say out loud what each store holds, so an empty grid can
	// be told apart from a request that never came back.
	XangModAudit("MUTE_LIST", "stored=" $ XangModShared().Mutes.Length $ " live-only=" $ Live $ " sent=" $ Count);

	Packet = new class'AOCRConPacket';
	Packet.SetMessageType(RCONX_MUTE_LIST_END);
	Packet.AddInt(Count);
	SendPacket(Packet);
}

/**
 * 42: admin text mute.
 *
 * Sets AOCPRI.bIsAdminMuted directly rather than calling ServerAdminMutePlayer, which
 * gates on the CALLER's PlayerReplicationInfo.bAdmin -- the remote console has no PRI,
 * so that path can never authorise it. Authorisation here is the RCON password.
 */
function HandleMutePlayer(AOCRConPacket Packet)
{
	local QWord PlayerId;
	local bool bMute;
	local AOCPlayerController PC;
	local AOCPRI APRI;
	local string StoredName;
	local int i;

	PlayerId = Packet.GetGUID();
	bMute    = (Packet.GetInt() != 0);

	PC = GetPlayerControllerFromGUID(PlayerId);
	if (PC == none)
	{
		// Offline: no flag to set, but the stored entry still has to be clearable or a
		// mute outlives every chance to lift it.
		for (i = 0; i < XangModShared().Mutes.Length; i++)
		{
			if (XangModShared().Mutes[i].NetID.Uid != PlayerId)
				continue;

			StoredName = XangModShared().Mutes[i].PlayerName;
			if (!bMute)
			{
				XangModRememberMute(XangModShared().Mutes[i].NetID, StoredName, false);
				XangModAudit("UNMUTE_PLAYER", StoredName @ "(offline)");
			}
			return;
		}
		return;
	}

	APRI = AOCPRI(PC.PlayerReplicationInfo);
	if (APRI == none)
		return;

	// The flag alone is not enough. Vanilla only consults bIsAdminMuted client-side in
	// AOCPlayerController.ReceiveChatMessage, and that check is skipped for Steam friends
	// of the muted player and for the muted player's own copy of the message -- so a muted
	// player still sees themselves talking, which looks exactly like mute not working.
	// XangModGame.BroadcastMessage drops the message server-side instead.
	APRI.bIsAdminMuted = bMute;
	APRI.bForceNetUpdate = true;
	XangModRememberMute(APRI.UniqueId, APRI.PlayerName, bMute);
	XangModAudit(bMute ? "MUTE_PLAYER" : "UNMUTE_PLAYER", APRI.PlayerName);
}

/* ======================= freeze, class, loadout, map ======================== */

/**
 * 60: send one player to another. Takes both ends because from here neither is "you".
 * Placement lives in XangModAdminActions: SetLocation returns false when the spot is
 * occupied, so it rings the destination rather than dropping someone inside them.
 */
function HandleTeleport(AOCRConPacket Packet)
{
	local QWord MoverId, DestId;
	local Controller Mover, Dest;   // Controller-level so bots work either end.

	MoverId = Packet.GetGUID();
	DestId  = Packet.GetGUID();

	Mover = GetControllerFromGUID(MoverId);
	Dest  = GetControllerFromGUID(DestId);

	if (Mover == none || Dest == none)
		return;

	if (Mover == Dest)
	{
		XangModAudit("TELEPORT_FAILED", DescribeController(Mover) @ "- cannot send a player to themselves");
		return;
	}

	if (Mover.Pawn == none || Dest.Pawn == none)
	{
		XangModAudit("TELEPORT_FAILED",
			DescribeController(Mover) @ "->" @ DescribeController(Dest) @ "- both must be alive");
		return;
	}

	if (class'XangModAdminActions'.static.Teleport(Mover.Pawn, Dest.Pawn))
		XangModAudit("TELEPORT", DescribeController(Mover) @ "->" @ DescribeController(Dest));
	else
		XangModAudit("TELEPORT_FAILED",
			DescribeController(Mover) @ "->" @ DescribeController(Dest) @ "- no free space there");
}

/** 61: launch a player. No damage -- Kill (25) is there for that. */
function HandleSlap(AOCRConPacket Packet)
{
	local QWord PlayerId;
	local Controller PC;    // Controller-level: a slap only needs a Pawn.
	local int Power;

	PlayerId = Packet.GetGUID();
	Power    = Packet.GetInt();

	PC = GetControllerFromGUID(PlayerId);
	if (PC == none)
		return;

	if (PC.Pawn == none)
	{
		XangModAudit("SLAP_FAILED", DescribeController(PC) @ "- not alive");
		return;
	}

	Power = Clamp(Power, 50, 2000);
	class'XangModAdminActions'.static.Slap(PC.Pawn, Power);
	XangModAudit("SLAP", DescribeController(PC) @ "power" @ Power);
}

/**
 * 51: freeze or release a player, via TB's tutorial input blocking
 * (ScriptToggleInput -> ClientScriptToggleInput, already a reliable client function :7572).
 *
 * NOT anti-cheat. TB's own comment there: "This isn't a safe way of preventing a player
 * from performing some action. It's intended for SP/Tutorials." Enforcement is
 * client-side, so a modified client ignores it. Talk is left unblocked on purpose.
 */
function XangModSetFrozen(AOCPlayerController PC, bool bFrozen)
{
	// bEnable == true means ALLOWED (ClientScriptToggleInput stores the negation), so
	// freezing passes false.
	local bool bAllow;
	bAllow = !bFrozen;

	PC.ScriptToggleInput(EINBLOCK_MoveForward,   bAllow);
	PC.ScriptToggleInput(EINBLOCK_MoveBackward,  bAllow);
	PC.ScriptToggleInput(EINBLOCK_MoveLeft,      bAllow);
	PC.ScriptToggleInput(EINBLOCK_MoveRight,     bAllow);
	PC.ScriptToggleInput(EINBLOCK_Jump,          bAllow);
	PC.ScriptToggleInput(EINBLOCK_Crouch,        bAllow);
	PC.ScriptToggleInput(EINBLOCK_Sprint,        bAllow);
	PC.ScriptToggleInput(EINBLOCK_Dodge,         bAllow);
	PC.ScriptToggleInput(EINBLOCK_AttackSlash,   bAllow);
	PC.ScriptToggleInput(EINBLOCK_AttackStab,    bAllow);
	PC.ScriptToggleInput(EINBLOCK_AttackOverhead,bAllow);
	PC.ScriptToggleInput(EINBLOCK_AttackShove,   bAllow);
	PC.ScriptToggleInput(EINBLOCK_AttackSprint,  bAllow);
	PC.ScriptToggleInput(EINBLOCK_Block,         bAllow);
	PC.ScriptToggleInput(EINBLOCK_Feint,         bAllow);
}

function HandleSetFrozen(AOCRConPacket Packet)
{
	local QWord PlayerId;
	local AOCPlayerController PC;
	local bool bFrozen;

	PlayerId = Packet.GetGUID();
	bFrozen  = (Packet.GetInt() != 0);

	PC = GetPlayerControllerFromGUID(PlayerId);
	if (PC == none)
		return;

	XangModSetFrozen(PC, bFrozen);
	XangModAudit(bFrozen ? "FREEZE" : "UNFREEZE",
		DescribeController(PC) @ "- client-side block, not cheat-proof");
}

/**
 * 52: change class, keeping the team. FamilyInfos as above, indexed by EAOCClass
 * (0 Archer, 1 ManAtArms, 2 Vanguard, 3 Knight, 4 SiegeEngineer).
 *
 * bForceSwitch=true so SetNewClass picks a loadout legal for the new class. Vanilla applies
 * on next spawn; immediate=1 kills the pawn so it lands now -- a flag, not the default,
 * because killing someone mid-fight to change their class is a rude surprise.
 */
function HandleSetClass(AOCRConPacket Packet)
{
	local QWord PlayerId;
	local AOCPlayerController PC;
	local AOCGRI GRI;
	local AOCFamilyInfo NewFamily;
	local int ClassIndex, bImmediate, Index;

	PlayerId   = Packet.GetGUID();
	ClassIndex = Packet.GetInt();
	bImmediate = Packet.GetInt();

	PC = GetPlayerControllerFromGUID(PlayerId);
	GRI = AOCGRI(WorldInfo.GRI);
	if (PC == none || GRI == none)
		return;

	if (PC.CurrentFamilyInfo == none)
	{
		XangModAudit("SET_CLASS_FAILED", DescribeController(PC) @ "- has not picked a class yet");
		return;
	}
	if (ClassIndex < 0 || ClassIndex > 4)
	{
		XangModAudit("SET_CLASS_FAILED", DescribeController(PC) @ "- bad class index" @ ClassIndex);
		return;
	}

	Index = ClassIndex;
	if (PC.CurrentFamilyInfo.FamilyFaction == EFAC_MASON)
		Index += 5;

	NewFamily = GRI.FamilyInfos[Index];
	if (NewFamily == none)
	{
		XangModAudit("SET_CLASS_FAILED", DescribeController(PC) @ "- FamilyInfos[" $ Index $ "] is none");
		return;
	}

	PC.SetNewClass(NewFamily, false, true);

	if (bImmediate != 0 && PC.Pawn != none)
		PC.Pawn.Died(none, class'AOCDmgType_Swing', vect(0, 0, 0));

	XangModAudit("SET_CLASS", DescribeController(PC) @ "->" @ NewFamily
		@ (bImmediate != 0 ? "(respawned now)" : "(applies on next spawn)"));
}

/**
 * 53: list the weapons this class may take, as indices into AOCFamilyInfo.New*Weapons.
 * Opcode 56 sets by the same index, so no class paths on the wire and no strings to trust.
 */
function HandleLoadoutRequest(AOCRConPacket Packet)
{
	local QWord PlayerId;
	local AOCPlayerController PC;
	local AOCRConPacket Reply;
	local AOCFamilyInfo Fam;
	local int i;

	PlayerId = Packet.GetGUID();
	PC = GetPlayerControllerFromGUID(PlayerId);
	if (PC == none || PC.CurrentFamilyInfo == none)
		return;

	Fam = PC.CurrentFamilyInfo;

	for (i = 0; i < Fam.NewPrimaryWeapons.Length; i++)
		SendLoadoutOption(PlayerId, SLOT_PRIMARY, i, Fam.NewPrimaryWeapons[i].CWeapon);
	for (i = 0; i < Fam.NewSecondaryWeapons.Length; i++)
		SendLoadoutOption(PlayerId, SLOT_SECONDARY, i, Fam.NewSecondaryWeapons[i].CWeapon);
	for (i = 0; i < Fam.NewTertiaryWeapons.Length; i++)
		SendLoadoutOption(PlayerId, SLOT_TERTIARY, i, Fam.NewTertiaryWeapons[i].CWeapon);

	Reply = new class'AOCRConPacket';
	Reply.SetMessageType(RCONX_LOADOUT_END);
	Reply.AddQWord(PlayerId);
	Reply.AddInt(Fam.NewPrimaryWeapons.Length);
	Reply.AddInt(Fam.NewSecondaryWeapons.Length);
	Reply.AddInt(Fam.NewTertiaryWeapons.Length);
	SendPacket(Reply);
}

function SendLoadoutOption(QWord PlayerId, int Slot, int Index, class<AOCWeapon> W)
{
	local AOCRConPacket Reply;

	Reply = new class'AOCRConPacket';
	Reply.SetMessageType(RCONX_LOADOUT_OPTION);
	Reply.AddQWord(PlayerId);
	Reply.AddInt(Slot);
	Reply.AddInt(Index);
	Reply.AddString((W != none) ? string(W.Name) : "(none)");
	SendPacket(Reply);
}

/**
 * 56: set loadout by index; -1 leaves a slot alone. Server-side only on purpose -- this is
 * what they spawn with. Their own class menu will not show it until it next refreshes.
 */
function HandleSetLoadout(AOCRConPacket Packet)
{
	local QWord PlayerId;
	local AOCPlayerController PC;
	local AOCFamilyInfo Fam;
	local class<AOCWeapon> Prim, Sec, Tert;
	local int iPrim, iSec, iTert;

	PlayerId = Packet.GetGUID();
	iPrim    = Packet.GetInt();
	iSec     = Packet.GetInt();
	iTert    = Packet.GetInt();

	PC = GetPlayerControllerFromGUID(PlayerId);
	if (PC == none || PC.CurrentFamilyInfo == none)
		return;

	Fam  = PC.CurrentFamilyInfo;
	Prim = PC.PrimaryWeapon;
	Sec  = PC.SecondaryWeapon;
	Tert = PC.TertiaryWeapon;

	if (iPrim >= 0 && iPrim < Fam.NewPrimaryWeapons.Length)
		Prim = Fam.NewPrimaryWeapons[iPrim].CWeapon;
	if (iSec >= 0 && iSec < Fam.NewSecondaryWeapons.Length)
		Sec = Fam.NewSecondaryWeapons[iSec].CWeapon;
	if (iTert >= 0 && iTert < Fam.NewTertiaryWeapons.Length)
		Tert = Fam.NewTertiaryWeapons[iTert].CWeapon;

	// AltPrimaryWeapon is carried through untouched -- it is not part of the choice lists
	// and clobbering it would drop the alternate mode of whatever they are holding.
	PC.SetWeapons(Prim, PC.AltPrimaryWeapon, Sec, Tert);

	XangModAudit("SET_LOADOUT", DescribeController(PC) @ "->" @ Prim @ "/" @ Sec @ "/" @ Tert
		@ "(applies on next spawn)");
}

/**
 * 57: one snapshot of where everyone is.
 *
 * Reads Pawn.Location, not the replicated AOCPRI.PawnLocation -- that only refreshes on a 2s
 * timer (AOCPRI.uc:192) and we already run server-side. PawnLocation is the fallback for a
 * dead pawn. Yaw in degrees so the client need not know UE3 rotator units.
 */
function SendPlayerPositions()
{
	local AOCRConPacket Reply;
	local PlayerReplicationInfo PRI;
	local AOCPRI APRI;
	local Controller C;
	local Vector Loc;
	local int Count, Yaw, bAlive;

	// Bail out through the terminator, never by returning. The client swaps in a frame on
	// PLAYER_POS_END; a bare return leaves it waiting and the map simply never updates,
	// which is indistinguishable from the opcode not being implemented at all.
	if (WorldInfo.GRI == none)
	{
		XangModAudit("PLAYER_POS_FAILED", "no GameReplicationInfo yet");
		Reply = new class'AOCRConPacket';
		Reply.SetMessageType(RCONX_PLAYER_POS_END);
		Reply.AddInt(0);
		SendPacket(Reply);
		return;
	}

	foreach WorldInfo.GRI.PRIArray(PRI)
	{
		if (PRI == none || PRI.bOnlySpectator)
			continue;

		EnsureUniqueId(PRI);

		APRI = AOCPRI(PRI);
		C = Controller(PRI.Owner);

		bAlive = 0;
		Yaw = 0;

		if (C != none && C.Pawn != none)
		{
			Loc = C.Pawn.Location;
			Yaw = (C.Pawn.Rotation.Yaw & 65535) * 360 / 65536;
			bAlive = 1;
		}
		else if (APRI != none)
		{
			Loc = APRI.PawnLocation;   // last known, from the 2s timer
		}
		else
		{
			continue;
		}

		Reply = new class'AOCRConPacket';
		Reply.SetMessageType(RCONX_PLAYER_POS);
		Reply.AddQWord(PRI.UniqueId.Uid);
		Reply.AddString(PRI.PlayerName);
		Reply.AddInt((PRI.Team != none) ? PRI.Team.TeamIndex : -1);
		Reply.AddInt(int(Loc.X));
		Reply.AddInt(int(Loc.Y));
		Reply.AddInt(int(Loc.Z));
		Reply.AddInt(Yaw);
		Reply.AddInt(bAlive);
		Reply.AddInt((APRI != none) ? APRI.CurrentHealth : 0);
		SendPacket(Reply);
		Count++;
	}

	Reply = new class'AOCRConPacket';
	Reply.SetMessageType(RCONX_PLAYER_POS_END);
	Reply.AddInt(Count);
	SendPacket(Reply);
}

/**
 * 49: turn tournament mode on or off, and optionally set the ready threshold.
 *
 * bTournamentMode only gates the pre-round (AOCGame.ShouldStartRound, :3062) and StartRound
 * clears it (:3099), so it is one-shot per round start -- vanilla behaviour, not a bug.
 * The InitGame side effects (:3344) are reapplied here since a mid-match toggle skips
 * InitGame; they are not reverted on disable, because we cannot know the original config.
 */
function HandleSetTournament(AOCRConPacket Packet)
{
	local AOCGame Game;
	local int bEnabled, ThresholdPercent;

	bEnabled         = Packet.GetInt();
	ThresholdPercent = Packet.GetInt();

	Game = AOCGame(WorldInfo.Game);
	if (Game == none || Game.GameReplicationInfo == none)
	{
		XangModAudit("TOURNAMENT_FAILED", (Game == none)
			? "the game is not an AOCGame"
			: "no GameReplicationInfo yet");
		return;
	}

	Game.bTournamentMode = (bEnabled != 0);
	AOCGRI(Game.GameReplicationInfo).bTournamentModeWaiting = Game.bTournamentMode;

	if (ThresholdPercent > 0)
	{
		Game.TournamentTeamReadyThreshold = float(ThresholdPercent) / 100.0f;
		AOCGRI(Game.GameReplicationInfo).fTournamentReadyThreshold = Game.TournamentTeamReadyThreshold;
	}

	if (Game.bTournamentMode)
	{
		Game.bAutoBalance = false;
		Game.bDeathBasedAutoBalance = false;
		AOCGRI(Game.GameReplicationInfo).bBalanceTeams = false;
		Game.bUseMaxPingLimit = false;
		Game.bDisableTeamDamagePenalty = true;
		// Vanilla's InitGame block also grants these (:3351); without bAdminCanPause an
		// in-game admin's console pause is refused by AllowPausing even in tournament mode.
		Game.bAdminCanPause = true;
		Game.bAnyUserCanGetSteamID = true;
	}
	else
	{
		// bTournamentMode is globalconfig (AOCGame.uc:399) and InitGame re-reads it every
		// map (:3337), so clearing only the live value lets it come back. Enable stays
		// runtime-only on purpose; disable is the escape hatch for a stuck server.
		class'AOCGame'.default.bTournamentMode = false;
		class'AOCGame'.static.StaticSaveConfig();
		Game.SaveConfig();
	}

	Game.GameReplicationInfo.bForceNetUpdate = true;

	XangModAudit(Game.bTournamentMode ? "TOURNAMENT_ON" : "TOURNAMENT_OFF",
		"ready threshold" @ int(Game.TournamentTeamReadyThreshold * 100) $ "%"
		@ (Game.bTournamentMode
			? "- applies in the pre-round, clears when the round starts"
			: "- also cleared from the ini so it cannot return on map change"));
}

/**
 * 50: force everyone ready (vanilla AdminReadyAll, :5235), or clear every ready flag.
 * ready=0 has no vanilla equivalent and also drops bAdminForcedTournamentReady, so
 * ShouldStartRound goes back to counting instead of staying latched from last round.
 */
function HandleReadyAll(AOCRConPacket Packet)
{
	local AOCGame Game;
	local AOCPlayerController PC;
	local int bReady, Count;

	bReady = Packet.GetInt();

	Game = AOCGame(WorldInfo.Game);
	if (Game == none)
		return;

	if (bReady != 0)
	{
		Game.AdminReadyAll();

		foreach WorldInfo.AllControllers(class'AOCPlayerController', PC)
		{
			// AdminReadyAll sets the flag but never nudges replication or announces it.
			if (PC.PlayerReplicationInfo != none)
				PC.PlayerReplicationInfo.bForceNetUpdate = true;
			PC.NotifyReady(true);
			Count++;
		}

		Game.BroadcastMessage(none, "An admin marked all players ready.", EFAC_ALL, true, true, "#4CC964");
		XangModAudit("READY_ALL", "forced" @ Count @ "player(s) ready");
		return;
	}

	foreach WorldInfo.AllControllers(class'AOCPlayerController', PC)
	{
		PC.bTournamentReady = false;
		if (AOCPRI(PC.PlayerReplicationInfo) != none)
		{
			AOCPRI(PC.PlayerReplicationInfo).bTournamentReady = false;
			PC.PlayerReplicationInfo.bForceNetUpdate = true;
		}
		PC.NotifyReady(false);
		Count++;
	}
	Game.bAdminForcedTournamentReady = false;

	Game.BroadcastMessage(none, "An admin cleared all ready flags.", EFAC_ALL, true, true, "#D1A04A");
	XangModAudit("UNREADY_ALL", "cleared" @ Count @ "player(s) and the admin ready override");
}

/**
 * 43: pause / unpause. Borrows a controller to own the pause -- an admin if one is
 * connected, otherwise the first.
 *
 * Calls AOCGame.SetPause (:4801), not PlayerController.SetPause: XangMod's override of the
 * latter is admin-gated, and AOCGame's is what sets AOCGRI.Speed and calls NotifyPaused.
 *
 * bPauseable is forced on around the call and restored after. AOCGame inherits
 * bPauseable=False from UTGame.uc:3396, so AllowPausing (:2794) falls through to
 * bAdminCanPause && IsAdmin -- false in the ini, and the borrowed controller is no admin.
 * Without the flip SetPause just returns false.
 *
 * bIsPaused lives on the XangMod PC subclasses and is not set here, so in-game "unpause"
 * (which checks the caller's own flag) cannot clear an RCON pause -- unpause over RCON.
 */
function HandleSetPause(AOCRConPacket Packet)
{
	local bool bPause;
	local AOCPlayerController PC, Chosen;
	local AOCGame Game;

	bPause = (Packet.GetInt() != 0);

	Game = AOCGame(WorldInfo.Game);
	if (Game == none)
		return;

	foreach WorldInfo.AllControllers(class'AOCPlayerController', PC)
	{
		if (Chosen == none)
			Chosen = PC;

		if (PC.PlayerReplicationInfo != none && PC.PlayerReplicationInfo.bAdmin)
		{
			Chosen = PC;
			break;
		}
	}

	if (Chosen == none)
	{
		XangModAudit("SET_PAUSE_FAILED", "nobody connected to own the pause");
		return;
	}

	if (bPause)
	{
		if (WorldInfo.Pauser != none)
			return;

		Chosen.bFire = 0;

		if (!XangModShared().bXangModPauseForced)
		{
			XangModShared().bXangModPauseableWas = Game.bPauseable;
			XangModShared().bXangModPauseForced = true;
		}
		Game.bPauseable = true;

		if (!Game.SetPause(Chosen))
		{
			Game.bPauseable = XangModShared().bXangModPauseableWas;
			XangModShared().bXangModPauseForced = false;
			XangModAudit("SET_PAUSE_FAILED", "the game refused the pause");
			return;
		}
		Chosen.PauseRumbleForAllPlayers();
	}
	else
	{
		// While ClearPause runs: AllowPausing() false takes the wipe-the-list branch, which
		// also unpauses, but keep the flag on so the normal delegate path is used instead.
		Game.ClearPause();
		Chosen.PauseRumbleForAllPlayers(false);

		if (XangModShared().bXangModPauseForced)
		{
			Game.bPauseable = XangModShared().bXangModPauseableWas;
			XangModShared().bXangModPauseForced = false;
		}
	}

	// AOCGame.SetPause already broadcasts its own "paused the game" system message (naming
	// the borrowed controller), but ClearPause announces nothing -- so only unpause needs one.
	if (!bPause)
		Game.BroadcastMessage(none, "An admin unpaused the match.", EFAC_ALL, true, true, "#4CC964");

	XangModAudit("SET_PAUSE", (bPause ? "paused" : "unpaused") @ "via" @ DescribeController(Chosen));
}

/**
 * 44: end the match now, awarding it to a team.
 *
 * EndGame wants a winning PRI rather than a team index, so the team's top scorer
 * stands in for it -- that is what AOCGame.GetHighestScoreFromTeam is for. A team with
 * nobody on it ends the match with no winner rather than failing silently.
 */
function HandleEndMatch(AOCRConPacket Packet)
{
	local int WinningTeam;
	local string Reason;
	local PlayerReplicationInfo WinnerPRI;
	local AOCGame Game;

	WinningTeam = Packet.GetInt();
	Reason      = Packet.GetString();

	Game = AOCGame(WorldInfo.Game);
	if (Game == none)
		return;

	if (WinningTeam >= 0)
		WinnerPRI = Game.GetHighestScoreFromTeam(WinningTeam);

	// No team named, or nobody left on it. Fall back to whoever the game itself would crown --
	// the same call AOCGame.ManuallyEndGame makes. AOCFFA and AOCDuel read Winner.PlayerName
	// without a null check, so handing them none costs the end screen its name.
	if (WinnerPRI == none)
		WinnerPRI = Game.GetHighestScoreFromTeam(Game.GetWinningTeam());

	// EndGame's Reason is a match-end CONDITION string, not anything a player ever sees --
	// which is why the reason never reached chat. Announce it separately first, while there is
	// still a round to announce it into.
	if (Reason != "")
		Game.BroadcastMessage(none, "Match ended by admin:" @ Reason, EFAC_ALL, true, true, "#D1A04A");

	XangModAudit("END_MATCH", "team" @ WinningTeam @ "|" @ Reason);

	// "TimeLimit" is not decoration, it is the only value that works in every mode.
	// AOCFFA.EndGame runs its body only for Reason ~= "TimeLimit" (Medieval Warfare also
	// accepts "Admin action"; Deadliest Warrior's copy does not), and AOCDuel.EndGame gates its
	// main branch on "TimeLimit" alone. Anything else is a SILENT no-op in free-for-all -- the
	// packet is handled, the audit fires, and the match simply never ends. Every base AOCGame
	// mode passes Reason straight to EndLogging and ignores it, so nothing is lost by it.
	Game.EndGame(WinnerPRI, "TimeLimit");
}

/** 45: toggle auto team balance. */
function HandleSetAutoBalance(AOCRConPacket Packet)
{
	local bool bEnable;

	bEnable = (Packet.GetInt() != 0);

	if (AOCGRI(WorldInfo.GRI) == none)
		return;

	AOCGRI(WorldInfo.GRI).bBalanceTeams = bEnable;
	XangModAudit("SET_AUTOBALANCE", bEnable ? "on" : "off");
}

/**
 * 46: game speed as an integer percent (no float on the wire); 100 is normal.
 * AOCGame.SetGameSpeed rather than a slomo console command: it calls NotifySpeedChanged and
 * republishes AOCGRI.Speed, which the bare command does not. Clamped 10-400 -- zero stops
 * the match with no way to type the command that would restore it.
 */
function HandleSetGameSpeed(AOCRConPacket Packet)
{
	local int SpeedPercent;
	local float NewSpeed;

	SpeedPercent = Packet.GetInt();
	SpeedPercent = Clamp(SpeedPercent, 10, 400);
	NewSpeed = float(SpeedPercent) / 100.0;

	if (WorldInfo.Game == none)
		return;

	XangModAudit("SET_GAME_SPEED", SpeedPercent $ "%");
	WorldInfo.Game.SetGameSpeed(NewSpeed);
}

/** 47: restart the current match. */
function HandleRestartMatch()
{
	if (WorldInfo.Game == none)
		return;

	// NOT RestartGame(): with bChangeLevels set it calls GetNextMap() and travels there, so
	// it cycles the rotation instead of restarting -- and the map change clears tournament
	// mode on the way. "?restart" is what XangMod's own AdminRestartMap uses.
	XangModAudit("RESTART_MATCH", "reloading the current map");
	WorldInfo.ServerTravel("?restart", false);
}

DefaultProperties
{
	// XangModBlockedConsoleCommands is deliberately NOT seeded here: it is a config array, and
	// the compiler refuses the import ("property is config"), which left the block list
	// empty at runtime. The defaults live in DefaultXangMod.ini instead.
}
