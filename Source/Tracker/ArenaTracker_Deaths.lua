local _, ArenaAnalytics = ... -- Namespace
local ArenaTracker = ArenaAnalytics.ArenaTracker;

-- Local module aliases
local API = ArenaAnalytics.API;
local Helpers = ArenaAnalytics.Helpers;
local TablePool = ArenaAnalytics.TablePool;
local Debug = ArenaAnalytics.Debug;

-------------------------------------------------------------------------

local currentArena = {};
function ArenaTracker:InitializeSubmodule_Deaths()
    currentArena = ArenaAnalyticsTransientDB.currentArena;
end


function ArenaTracker:GetDeathData()
	assert(currentArena);
	if(type(currentArena.deathData) ~= "table") then
		Debug:LogError("Force reset DeathData from non-table value!");
		currentArena.deathData = TablePool:Acquire();
	end
	return currentArena.deathData;
end


local function hasValidDeathData(playerGUID)
	local deathData = ArenaTracker:GetDeathData();

	local existingData = deathData[playerGUID];
	if(type(existingData) == "table" and tonumber(existingData.time) and existingData.name) then
		return true;
	end

	return false;
end

local function removeDeath(playerGUID)
	local deathData = ArenaTracker:GetDeathData();
	deathData[playerGUID] = nil;
end

-- Called from unit actions, to remove false deaths
function ArenaTracker:TryRemoveFromDeaths(playerGUID, spell)
	if(not hasValidDeathData(playerGUID)) then
		removeDeath(playerGUID);
		return;
	end

	local deathData = ArenaTracker:GetDeathData();
	local existingData = deathData[playerGUID];

	if(existingData) then
		local timeSinceDeath = time() - existingData.time;

		local minimumDelay = existingData.isHunter and 2 or 10;
		if(existingData.hasKillCredit) then
			minimumDelay = minimumDelay + 5;
		end

		if(timeSinceDeath > minimumDelay) then
			Debug:Log("Removed death by post-death action: ", spell, " for player: ", existingData.name, " Time since death: ", timeSinceDeath);
			removeDeath(playerGUID);
		end
	end
end


-- Called via UNIT_HEALTH unit events; detects deaths mid-round since UNIT_DIED doesn't fire in Midnight.
function ArenaTracker:HandleUnitHealth(unit)
	if(not ArenaTracker:IsTrackingShuffle()) then return end
	if(not UnitIsDeadOrGhost(unit)) then return end

	-- UnitIsFeignDeath is only valid for friendly units; skip feign death for party tokens
	if(UnitIsFeignDeath and UnitIsFeignDeath(unit) and not unit:find("^arena")) then return end

	local guid = Helpers:UnitGUID(unit);
	local name = API:GetUnitFullName(unit);

	-- Use GUID as key if non-secret, else fall back to name
	local key = (guid and not API:IsSecretValue(guid)) and guid or nil;
	if(key == nil) then
		key = (name and not API:IsSecretValue(name)) and name or nil;
	end

	-- fallback: use the token→name snapshot captured at gates open, before names went secret
	if(key == nil and currentArena.round and currentArena.round.tokenNames) then
		local snapshotName = currentArena.round.tokenNames[unit];
		if(snapshotName) then
			key = snapshotName;
			name = snapshotName;
			Debug:Log("HandleUnitHealth: resolved dead unit via gates-open snapshot:", unit, name);
		end
	end

	if(key == nil) then
		Debug:Log("HandleUnitHealth: no valid key for dead unit:", unit);
		return;
	end

	Debug:Log("HandleUnitHealth: dead unit detected:", unit, name);
	ArenaTracker:HandlePlayerDeath(key, false, name);
end


-- Handle a player's death, through death or kill credit message
-- hintName: optional destName from combat log, used as fallback when GUID lookup fails (e.g. Midnight secrets)
function ArenaTracker:HandlePlayerDeath(playerGUID, isKillCredit, hintName)
	if(playerGUID == nil) then
		Debug:LogWarning("HandlePlayerDeath called with invalid GUID.");
		return;
	end

	local name, realm, class, race, isFemale = API:GetPlayerInfoByGUID(playerGUID);

	-- In Midnight, enemy GUIDs may be secret; GetPlayerInfoByGUID returns nil.
	-- Fall back to destName from the combat log if it's a valid (non-secret) string.
	if(name == nil and API:IsValidValue(hintName)) then
		name = hintName;
	end

	-- Last resort: scan arena/party unit tokens for a newly dead player.
	-- In Midnight, both destGUID and destName may be secret; unit tokens are still accessible.
	-- Party member names ("party1"/"party2") are always readable; enemy names ("arena1"-"arena3") may still be secret.
	if(name == nil) then
		for _, token in ipairs({"player", "party1", "party2", "arena1", "arena2", "arena3"}) do
			if(UnitIsDeadOrGhost(token)) then
				local tokenName = API:GetUnitFullName(token);
				if(API:IsValidValue(tokenName)) then
					name = tokenName;
					if(class == nil) then
						local _, tokenClass = UnitClass(token);
						class = API:IsValidValue(tokenClass) and tokenClass or nil;
					end
					Debug:Log("HandlePlayerDeath: identified dead player via unit token:", token, name);
					break;
				end
			end
		end
	end

	if(name == nil or name == "") then
		Debug:LogError("Invalid name of dead player. Skipping..");
		return;
	end

	if(not realm or realm == "") then
		-- GetUnitFullName already returns "Name-Realm"; ToFullName handles both formats.
		name = API:ToFullName(name);
	else
		name = name .. "-" .. realm;
	end

	-- resolve class from tracked player data when GUID lookup failed (e.g. snapshot-name keys from poll)
	if(class == nil and name) then
		local player = ArenaTracker:GetPlayer(name);
		if(player) then
			class = player.class;
		end
	end

	Debug:LogGreen("Player Kill!", isKillCredit, name);

	-- Store death
	local deathData = ArenaTracker:GetDeathData();
	local death = type(deathData[playerGUID]) == "table" and deathData[playerGUID] or TablePool:Acquire();
	death.time = time();
	death.name = name;
	death.isHunter = (class == "HUNTER") or nil;
	death.hasKillCredit = isKillCredit or death.hasKillCredit;

	deathData[playerGUID] = death;
	Debug:LogGreen("Assigned death:", death.name, playerGUID);

	if(ArenaTracker:IsTrackingShuffle() and (isKillCredit or class ~= "HUNTER")) then
		C_Timer.After(0, ArenaTracker.HandleRoundEnd);
	end
end


-- Commits current deaths to player stats (May be overridden by scoreboard, if value is trusted for the expansion)
function ArenaTracker:CommitDeaths()
	local deathData = ArenaTracker:GetDeathData();
	for key,data in pairs(deathData) do
		local player = ArenaTracker:GetPlayer(key);
		if(player and data) then
			-- Increment deaths
			player.deaths = (player.deaths or 0) + 1;
		else
			Debug:LogWarning("ArenaTracker:CommitDeaths failed to assign deaths for player:", player and player.name, key);
		end
	end

	wipe(currentArena.deathData);
end


-- Fetch the real first death when saving the match
function ArenaTracker:GetFirstDeathFromCurrentArena()
	local deathData = ArenaTracker:GetDeathData();
	if(deathData == nil) then
		return;
	end

	local bestKey, bestTime;
	for key,data in pairs(deathData) do
		if(key and type(data) == "table" and data.time) then
			if(bestTime == nil or data.time < bestTime) then
				bestKey = key;
				bestTime = data.time;
			end
		else
			local player = ArenaTracker:GetPlayer(key);
			Debug:LogError("Invalid death data found:", key, player and player.name, type(data));
			--Debug:LogTable(deathData);
		end
	end

	if(not bestKey or not deathData[bestKey]) then
		Debug:Log("Death data missing from currentArena. HasKey:", bestKey ~= nil);
		return nil;
	end

	local firstDeathData = deathData[bestKey];
	return firstDeathData.name, firstDeathData.time;
end
