local _, ArenaAnalytics = ... -- Namespace
local ArenaTracker = ArenaAnalytics.ArenaTracker;

-- Local module aliases
local AAmatch = ArenaAnalytics.AAmatch;
local Constants = ArenaAnalytics.Constants;
local API = ArenaAnalytics.API;
local Helpers = ArenaAnalytics.Helpers;
local Internal = ArenaAnalytics.Internal;
local Localization = ArenaAnalytics.Localization;
local Inspection = ArenaAnalytics.Inspection;
local Events = ArenaAnalytics.Events;
local TablePool = ArenaAnalytics.TablePool;
local Debug = ArenaAnalytics.Debug;
local ArenaRatedInfo = ArenaAnalytics.ArenaRatedInfo;

-------------------------------------------------------------------------
-- ArenaTracker subsection
-- Responsible for processing when gates open, through chat messages.
-------------------------------------------------------------------------

local currentArena = {};
function ArenaTracker:InitializeSubmodule_GatesOpened()
    currentArena = ArenaAnalyticsTransientDB.currentArena;
end

function ArenaTracker:HandleArenaMessages(msg)
	if(msg and not API:IsSecretValue(msg)) then
		return;
	end

	if(not ArenaTracker:IsTrackingArena()) then
		return;
	end

	local isStart, timeTillStart = Constants:CheckTimerMessage(msg);

	if(not timeTillStart) then
		return;
	end

	Debug:LogGreen("HandleArenaMessages:", msg);

	if(not currentArena.hasRealStartTime) then
		local newTime = (time() + timeTillStart);

		if(currentArena.startTime) then
			Debug:LogGreen("Start Time changed by broadcast message:", currentArena.startTime, newTime, newTime - time());
		end

		currentArena.startTime = newTime;
	end

	-- Trigger Start handling logic
	if(isStart) then
		ArenaTracker:HandleArenaGatesOpened(msg);
	end
end

-- Gates opened, match has officially started
function ArenaTracker:HandleArenaGatesOpened(...)
	local isShuffle = ArenaTracker:IsTrackingShuffle();
	Debug:LogGreen("ArenaTracker:HandleArenaGatesOpened() triggered! IsShuffle:", isShuffle);

	-- Only set the overall match start time once (first round gates open)
	if(not currentArena.hasRealStartTime) then
		currentArena.startTime = time();
		currentArena.hasRealStartTime = true;
	end

	-- Initialize shuffle round data before ForceTeamsUpdate (which calls CheckRoundEnded).
	if(isShuffle) then
		-- Only set the win baseline for the first round (when nil).
		-- In Midnight the scoreboard is unavailable during prep and returns 0, which would
		-- overwrite the correct baseline CommitCurrentRound stored at the end of the prior round,
		-- making every round after the first win appear as a win (myWins cumulative > reset-to-0).
		if(currentArena.round.wins == nil) then
			local myWins, totalWins = ArenaTracker:GetCurrentWins();
			currentArena.round.wins = myWins or 0;
			currentArena.round.totalWins = totalWins or 0;
		end
		Debug:Log("Round wins baseline:", currentArena.round.wins, currentArena.round.totalWins);

		currentArena.round.startTime = time();
		currentArena.round.hasStarted = true;
	end

	-- snapshot arena token names while they're still readable; names become secret mid-round
	if(API.hasSecrets) then
		currentArena.round.tokenNames = TablePool:Acquire();
		for i = 1, 3 do
			local token = "arena" .. i;
			local name = API:GetUnitFullName(token);
			if(API:IsValidValue(name)) then
				currentArena.round.tokenNames[token] = name;
			end
		end

		currentArena.round.pollLog = {};
		ArenaTracker:ResetPollDeadState();
		ArenaTracker:StartEnemyDeathPoll(); -- no-op if already running; only starts once per match
	end

	ArenaTracker:FillMissingPlayers();
	ArenaTracker:ForceTeamsUpdate();
	ArenaTracker:UpdateRoundTeam();

	Debug:Log("Match started!", API:GetCurrentMapID(), GetZoneText(), #currentArena.players);
end
