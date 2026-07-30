DeriveGamemode("sandbox")

GM.Name    = "Kleiner Hunt"
GM.Author  = "you"
GM.TeamBased = true

-- ============================================================
-- CONFIG  (tune everything here)
-- ============================================================
KH = KH or {}
KH.CFG = {
	-- Round pacing (seconds)
	HideTime      = 45,
	HuntTime      = 420,
	PostTime      = 12,

	-- Decoys
	DecoyCount    = 60,
	PatrolFraction = 0.25,

	-- Objective
	DevicesToWin  = 1,
	DeviceCount   = 3,
	BasketRadius  = 96,

	-- Breen
	MaxStrikes    = 5,
	AccuseRange   = 110,
	AccuseCooldown = 1.2,
	StrikePenalty = 3.0,
	RevealTime    = 4.0,

	-- Speeds — these are set via SetWalkSpeed/SetRunSpeed which GMod
	-- reads correctly. The base sandbox walk is 200, run is 450.
	KleinerWalk   = 120,   -- raised: 55 felt like molasses
	KleinerRun    = 220,
	CarrySlowdown = 0.6,
	TauntInterval = 35,

	BreenWalk     = 200,
	BreenRun      = 380,

	-- Models
	KleinerModel  = "models/kleiner.mdl",
	BreenModel    = "models/breen.mdl",
	DeviceModel   = "models/magnusson_device.mdl",
	DeviceFallback = "models/props_junk/propane_tank001a.mdl",

	Taunts = {
		"vo/k_lab/kl_wonderful.wav",
		"vo/k_lab/kl_hitting.wav",
		"vo/k_lab/kl_ohdear.wav",
		"vo/k_lab/kl_ah.wav",
		"vo/k_lab/kl_hesitate.wav",
	},
}

-- ============================================================
-- TEAMS / STATE
-- ============================================================
TEAM_KLEINER = 1
TEAM_BREEN   = 2
TEAM_SPEC    = 3

KH.WAITING = 0
KH.HIDING  = 1
KH.HUNTING = 2
KH.POST    = 3

function GM:CreateTeams()
	team.SetUp(TEAM_KLEINER, "Kleiners", Color(90, 170, 230))
	team.SetUp(TEAM_BREEN,   "Dr. Breen", Color(220, 90, 80))
	team.SetUp(TEAM_SPEC,    "Spectators", Color(150, 150, 150))
	team.SetSpawnPoint(TEAM_KLEINER, {"info_player_start", "info_player_deathmatch"})
	team.SetSpawnPoint(TEAM_BREEN,   {"info_player_start", "info_player_deathmatch"})
end

function KH.State()    return GetGlobalInt("kh_state", KH.WAITING) end
function KH.EndTime()  return GetGlobalFloat("kh_endtime", 0) end
function KH.TimeLeft() return math.max(0, KH.EndTime() - CurTime()) end

-- ============================================================
-- ANIMATIONS
-- CalcMainActivity runs every frame on both client and server.
-- We only override for Kleiner-team players so they blend with NPCs.
-- Alyx and Breen use default sandbox animations.
-- ============================================================
function GM:CalcMainActivity(ply, vel)
	-- Let Breen, Alyx, and Spec use normal animations
	if ply:Team() ~= TEAM_KLEINER then
		return self.BaseClass:CalcMainActivity(ply, vel)
	end
	if not ply:Alive() then
		return self.BaseClass:CalcMainActivity(ply, vel)
	end
	-- Alyx uses default too
	if ply:GetNWBool("kh_alyx", false) then
		return self.BaseClass:CalcMainActivity(ply, vel)
	end

	local speed = vel:Length2D()
	local ideal = ACT_IDLE

	if not ply:OnGround() then
		ideal = ACT_JUMP
	elseif ply:Crouching() then
		ideal = speed > 10 and ACT_WALK_CROUCH or ACT_COVER_LOW
	elseif speed > 150 then
		ideal = ACT_RUN
	elseif speed > 20 then
		ideal = ACT_WALK
	end

	ply.CalcIdeal = ideal
	return ideal, ply.CalcSeqOverride or -1
end

-- Suppress weapon bobbing / sway for Kleiners so they look still when idle
function GM:CalcView(ply, origin, angles, fov)
	if ply:Team() == TEAM_KLEINER and ply:Alive() then
		-- Only suppress bob, don't change anything else
		ply:SetViewPunchAngles(Angle(0, 0, 0))
	end
	return self.BaseClass:CalcView(ply, origin, angles, fov)
end
