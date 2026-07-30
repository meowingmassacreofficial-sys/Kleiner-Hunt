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
	DecoyCount    = 60,    -- how many npc_kleiners to spawn (capped by saved points)
	PatrolFraction = 0.25, -- fraction of decoys that wander between points

	-- Objective
	DevicesToWin  = 1,     -- devices Kleiners must deliver to the basket
	DeviceCount   = 3,     -- how many spawn on the map
	BasketRadius  = 96,

	-- Breen
	MaxStrikes    = 5,     -- wrong accusations before Kleiners win
	AccuseRange   = 110,
	AccuseCooldown = 1.2,
	StrikePenalty = 3.0,   -- seconds Breen is slowed + flashed
	RevealTime    = 4.0,   -- seconds Kleiners see Breen's position after a strike

	-- Blending
	KleinerWalk   = 55,    -- must roughly match npc_kleiner's walk speed
	KleinerRun    = 105,
	CarrySlowdown = 0.6,   -- speed multiplier while carrying a device
	TauntInterval = 35,    -- forced random Kleiner voice line, 0 to disable

	BreenWalk     = 130,
	BreenRun      = 210,

	-- Models
	KleinerModel  = "models/kleiner.mdl",
	BreenModel    = "models/breen.mdl",
	DeviceModel   = "models/magnusson_device.mdl", -- verify: EP2 must be mounted
	DeviceFallback = "models/props_junk/propane_tank001a.mdl",

	-- Kleiner voice lines used for taunts. Verify these exist on your install;
	-- missing sounds just fail silently. Browse sound/vo/k_lab/ to add more.
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

function KH.State()   return GetGlobalInt("kh_state", KH.WAITING) end
function KH.EndTime() return GetGlobalFloat("kh_endtime", 0) end
function KH.TimeLeft() return math.max(0, KH.EndTime() - CurTime()) end

-- ============================================================
-- BLENDING: make players animate like the NPCs they hide among
-- ============================================================
function GM:CalcMainActivity(ply, vel)
	if ply:Team() ~= TEAM_KLEINER or not ply:Alive() then
		return self.BaseClass:CalcMainActivity(ply, vel)
	end

	ply.CalcIdeal = ACT_IDLE
	local speed = vel:Length2D()

	if not ply:OnGround() then
		ply.CalcIdeal = ACT_JUMP
	elseif ply:Crouching() then
		ply.CalcIdeal = speed > 10 and ACT_WALK_CROUCH or ACT_COVER_LOW
	elseif speed > 90 then
		ply.CalcIdeal = ACT_RUN
	elseif speed > 10 then
		ply.CalcIdeal = ACT_WALK
	end

	return ply.CalcIdeal, ply.CalcSeqOverride or -1
end
