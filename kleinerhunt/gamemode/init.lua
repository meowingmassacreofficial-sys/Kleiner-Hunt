AddCSLuaFile("cl_init.lua")
AddCSLuaFile("shared.lua")
include("shared.lua")

util.AddNetworkString("kh_alert")
util.AddNetworkString("kh_reveal")
util.AddNetworkString("kh_flash")
util.AddNetworkString("kh_medic_set")  -- tells a client they are the medic
util.AddNetworkString("kh_alyx_set")   -- tells a client they are Stunstick Alyx
util.AddNetworkString("kh_alyx_signup") -- client -> server: volunteer/withdraw
util.AddNetworkString("kh_alyx_list")  -- server -> all: current volunteer list
util.AddNetworkString("kh_breen_stun") -- server -> breen: you are stunned

local CFG = KH.CFG

KH.Decoys      = {}
KH.Devices     = {}
KH.MapData     = { decoys = {}, devices = {}, basket = nil }
KH.Strikes     = 0
KH.Delivered   = 0

-- ============================================================
-- ALYX VOLUNTEERS  (collected during WAITING phase)
-- ============================================================
KH.AlyxVolunteers = {}   -- list of players who signed up
KH.MAX_ALYX       = 3

local function BroadcastAlyxList()
	net.Start("kh_alyx_list")
	local names = {}
	for _, ply in ipairs(KH.AlyxVolunteers) do
		if IsValid(ply) then table.insert(names, ply:Nick()) end
	end
	net.WriteTable(names)
	net.Broadcast()
end

net.Receive("kh_alyx_signup", function(len, ply)
	if KH.State() ~= KH.WAITING then return end

	-- Toggle: if already signed up, withdraw
	for i, v in ipairs(KH.AlyxVolunteers) do
		if v == ply then
			table.remove(KH.AlyxVolunteers, i)
			KH.Alert(ply, "You withdrew from Stunstick Alyx.", Color(200, 200, 200))
			BroadcastAlyxList()
			return
		end
	end

	if #KH.AlyxVolunteers >= KH.MAX_ALYX then
		KH.Alert(ply, "Alyx slots are full (" .. KH.MAX_ALYX .. "/" .. KH.MAX_ALYX .. ").", Color(255, 180, 100))
		return
	end

	table.insert(KH.AlyxVolunteers, ply)
	KH.Alert(ply, "You signed up as Stunstick Alyx! Press the button again to withdraw.", Color(180, 220, 255))
	BroadcastAlyxList()
end)

-- ============================================================
-- MAP DATA  (saved per-map to garrysmod/data/kleinerhunt/)
-- ============================================================
local function DataPath() return "kleinerhunt/" .. game.GetMap() .. ".json" end

function KH.SaveMapData()
	file.CreateDir("kleinerhunt")
	file.Write(DataPath(), util.TableToJSON(KH.MapData, true))
end

function KH.LoadMapData()
	local raw = file.Read(DataPath(), "DATA")
	if not raw then return false end
	local t = util.JSONToTable(raw)
	if not t then return false end
	KH.MapData = {
		decoys  = t.decoys or {},
		devices = t.devices or {},
		basket  = t.basket,
	}
	return true
end

local function ToVec(t) return Vector(t.x or t[1], t.y or t[2], t.z or t[3]) end
local function ToAng(t) return Angle(t.p or t[1], t.y2 or t[2], 0) end

-- ============================================================
-- DECOYS
-- ============================================================
local function MakeDecoy(pos, ang, patrol)
	local npc = ents.Create("npc_kleiner")
	if not IsValid(npc) then return end

	npc:SetPos(pos)
	npc:SetAngles(ang or Angle(0, math.random(0, 360), 0))
	npc:Spawn()
	npc:Activate()

	npc.KH_Decoy = true
	npc:SetHealth(1)
	npc:AddFlags(FL_NOTARGET)          -- nothing hostile cares about them
	npc:CapabilitiesClear()            -- no head-tracking, no aiming: kills the biggest tell
	npc:SetNPCState(NPC_STATE_IDLE)
	npc:SetSchedule(SCHED_IDLE_STAND)

	if patrol then
		npc.KH_Patrol = true
		npc:CapabilitiesAdd(CAP_MOVE_GROUND)
	end

	table.insert(KH.Decoys, npc)
	return npc
end

function KH.ClearDecoys()
	for _, npc in ipairs(KH.Decoys) do
		if IsValid(npc) then npc:Remove() end
	end
	KH.Decoys = {}
end

function KH.SpawnDecoys()
	KH.ClearDecoys()

	local points = table.Copy(KH.MapData.decoys)
	if #points == 0 then
		print("[KleinerHunt] No decoy points saved. Use !kh_decoy in-game.")
		return
	end

	local want = math.min(CFG.DecoyCount, #points)
	local patrolCount = math.floor(want * CFG.PatrolFraction)

	for i = 1, want do
		local idx = math.random(#points)
		local p = points[idx]
		table.remove(points, idx)
		MakeDecoy(ToVec(p.pos) + Vector(0, 0, 2), Angle(0, p.yaw or 0, 0), i <= patrolCount)
	end
end

-- Patrol tick: send wanderers to a random saved point. SCHED_FORCED_GO works
-- without a nodegraph, but placing info_node entities in Hammer makes it smoother.
timer.Create("kh_patrol", 6, 0, function()
	if KH.State() ~= KH.HUNTING and KH.State() ~= KH.HIDING then return end
	if #KH.MapData.decoys == 0 then return end

	for _, npc in ipairs(KH.Decoys) do
		if IsValid(npc) and npc.KH_Patrol and math.random() < 0.4 then
			local p = KH.MapData.decoys[math.random(#KH.MapData.decoys)]
			npc:SetLastPosition(ToVec(p.pos))
			npc:SetSchedule(SCHED_FORCED_GO)
		end
	end
end)

-- ============================================================
-- MEDIC HEAL TICK
-- Medic Kleiner heals all living Kleiners within 150 units every second.
-- ============================================================
local MEDIC_RADIUS    = 150
local MEDIC_RADIUS_SQ = MEDIC_RADIUS * MEDIC_RADIUS
local MEDIC_HEAL_AMT  = 5   -- HP per tick
local MEDIC_MAX_HP    = 100

timer.Create("kh_medic_heal", 1, 0, function()
	if KH.State() ~= KH.HUNTING then return end

	for _, medic in ipairs(team.GetPlayers(TEAM_KLEINER)) do
		if medic:Alive() and medic.KH_IsMedic then
			for _, target in ipairs(team.GetPlayers(TEAM_KLEINER)) do
				if target:Alive() and not target.KH_IsMedic then
					if medic:GetPos():DistToSqr(target:GetPos()) < MEDIC_RADIUS_SQ then
						local newHp = math.min(target:Health() + MEDIC_HEAL_AMT, MEDIC_MAX_HP)
						target:SetHealth(newHp)
					end
				end
			end
		end
	end
end)

-- ============================================================
-- DEVICES / BASKET
-- ============================================================
local function DeviceModel()
	if util.IsValidModel(CFG.DeviceModel) then return CFG.DeviceModel end
	print("[KleinerHunt] " .. CFG.DeviceModel .. " not found (is Episode Two mounted?). Using fallback.")
	return CFG.DeviceFallback
end

function KH.ClearDevices()
	for _, d in ipairs(KH.Devices) do
		if IsValid(d) then d:Remove() end
	end
	KH.Devices = {}
end

function KH.SpawnDevices()
	KH.ClearDevices()
	KH.Delivered = 0

	local points = table.Copy(KH.MapData.devices)
	if #points == 0 then
		print("[KleinerHunt] No device spawns saved. Use !kh_device in-game.")
		return
	end

	local mdl = DeviceModel()
	for i = 1, math.min(CFG.DeviceCount, #points) do
		local idx = math.random(#points)
		local p = points[idx]
		table.remove(points, idx)

		local d = ents.Create("prop_physics")
		d:SetModel(mdl)
		d:SetPos(ToVec(p.pos) + Vector(0, 0, 4))
		d:Spawn()
		d.KH_Device = true
		d:SetUseType(SIMPLE_USE)
		table.insert(KH.Devices, d)
	end
end

function KH.AttachDevice(ply, dev)
	if IsValid(ply.KH_Carrying) then return end

	dev.KH_Carrier = ply
	ply.KH_Carrying = dev

	dev:SetMoveType(MOVETYPE_NONE)
	dev:SetCollisionGroup(COLLISION_GROUP_WEAPON)
	dev:SetParent(ply)
	dev:SetLocalPos(Vector(-12, 0, 42))
	dev:SetLocalAngles(Angle(0, 0, 0))
	ply:SetNWBool("kh_carrying", true)

	KH.Alert(ply, "You have the device. Get it to the basket.")
	KH.AlertTeam(TEAM_BREEN, "A device has been picked up.")
	ply:EmitSound("items/ammopickup.wav", 60)
end

function KH.DropDevice(ply, atPos)
	local dev = ply.KH_Carrying
	ply.KH_Carrying = nil
	ply:SetNWBool("kh_carrying", false)
	if not IsValid(dev) then return end

	dev.KH_Carrier = nil
	dev:SetParent(nil)
	dev:SetPos(atPos or ply:GetPos() + Vector(0, 0, 20))
	dev:SetAngles(Angle(0, 0, 0))
	dev:SetCollisionGroup(COLLISION_GROUP_NONE)
	dev:SetMoveType(MOVETYPE_VPHYSICS)
	dev:PhysicsInit(SOLID_VPHYSICS)
	dev:PhysWake()
end

function GM:PlayerUse(ply, ent)
	if not IsValid(ent) or not ent.KH_Device then return true end
	if KH.State() ~= KH.HUNTING or ply:Team() ~= TEAM_KLEINER then return true end
	if ent:GetPos():DistToSqr(ply:GetPos()) > 90 * 90 then return true end

	KH.AttachDevice(ply, ent)
	return true
end

-- ============================================================
-- MESSAGING
-- ============================================================
function KH.Alert(ply, msg, col)
	net.Start("kh_alert")
	net.WriteString(msg)
	net.WriteColor(col or Color(255, 235, 190), false)
	net.Send(ply)
end

function KH.AlertTeam(t, msg, col)
	for _, ply in ipairs(team.GetPlayers(t)) do KH.Alert(ply, msg, col) end
end

function KH.AlertAll(msg, col)
	net.Start("kh_alert")
	net.WriteString(msg)
	net.WriteColor(col or Color(255, 235, 190), false)
	net.Broadcast()
end

-- ============================================================
-- ROUND FLOW
-- ============================================================
local function SetState(s, dur)
	SetGlobalInt("kh_state", s)
	SetGlobalFloat("kh_endtime", CurTime() + (dur or 0))
end

local function SyncCounters()
	local alive = 0
	for _, ply in ipairs(team.GetPlayers(TEAM_KLEINER)) do
		if ply:Alive() then alive = alive + 1 end
	end
	SetGlobalInt("kh_alive", alive)
	SetGlobalInt("kh_strikes", KH.Strikes)
	SetGlobalInt("kh_maxstrikes", CFG.MaxStrikes)
	SetGlobalInt("kh_delivered", KH.Delivered)
	SetGlobalInt("kh_devgoal", CFG.DevicesToWin)
	return alive
end

function KH.StartRound()
	local players = player.GetAll()

	if #players < 2 then
		KH.AlertAll("Need at least 2 players.")
		SetState(KH.WAITING)
		return
	end

	KH.Strikes = 0
	KH.Delivered = 0

	-- Pick Breen: prefer someone who hasn't been Breen recently
	local pool = {}
	for _, ply in ipairs(players) do
		if not ply.KH_WasBreen then table.insert(pool, ply) end
	end
	if #pool == 0 then
		for _, ply in ipairs(players) do ply.KH_WasBreen = false end
		pool = players
	end

	local breen = pool[math.random(#pool)]
	breen.KH_WasBreen = true

	for _, ply in ipairs(players) do
		ply.KH_IsMedic  = false
		ply.KH_Carrying = nil
		ply:SetTeam(ply == breen and TEAM_BREEN or TEAM_KLEINER)
		ply:SetNWBool("kh_medic", false)
		ply:Spawn()
	end

	-- Pick one random Kleiner as the medic (only if 2+ Kleiners)
	local kleiners = team.GetPlayers(TEAM_KLEINER)
	if #kleiners >= 2 then
		local medic = kleiners[math.random(#kleiners)]
		medic.KH_IsMedic = true
		medic:SetNWBool("kh_medic", true)
		net.Start("kh_medic_set")
		net.Send(medic)
		KH.Alert(medic, "You are the Medic Kleiner. Heal your allies.", Color(255, 130, 130))
	end

	-- Assign Alyx volunteers (remove any who became Breen first)
	for _, ply in ipairs(players) do
		ply.KH_IsAlyx   = false
		ply.KH_AlyxStunned = false
		ply:SetNWBool("kh_alyx", false)
	end

	for _, vol in ipairs(KH.AlyxVolunteers) do
		if IsValid(vol) and vol:Team() == TEAM_KLEINER then
			vol.KH_IsAlyx = true
			vol:SetNWBool("kh_alyx", true)
			net.Start("kh_alyx_set")
			net.Send(vol)
			KH.Alert(vol, "You are Stunstick Alyx. Stun Breen to protect your team.", Color(180, 220, 255))
		end
	end
	KH.AlyxVolunteers = {}  -- clear for next round

	KH.SpawnDecoys()
	KH.SpawnDevices()

	SetState(KH.HIDING, CFG.HideTime)
	SyncCounters()

	KH.AlertTeam(TEAM_KLEINER, "Hide among the decoys. Stay still, stay boring.", Color(120, 200, 255))
	KH.Alert(breen, "Wait here. Then find every real Kleiner.", Color(255, 120, 110))
end

local function EndRound(winner, reason)
	SetState(KH.POST, CFG.PostTime)
	SetGlobalInt("kh_winner", winner)
	KH.AlertAll(reason, winner == TEAM_BREEN and Color(255, 120, 110) or Color(120, 220, 150))

	for _, ply in ipairs(team.GetPlayers(winner)) do
		ply:AddFrags(1)
	end

	-- Freeze Breen's hunt, let everyone see the reveal
	for _, npc in ipairs(KH.Decoys) do
		if IsValid(npc) then npc:SetSchedule(SCHED_IDLE_STAND) end
	end
end

function KH.CheckWin()
	if KH.State() ~= KH.HUNTING then return end

	if KH.Delivered >= CFG.DevicesToWin then
		return EndRound(TEAM_KLEINER, "The Kleiners delivered the device. Breen loses.")
	end

	if KH.Strikes >= CFG.MaxStrikes then
		return EndRound(TEAM_KLEINER, "Breen accused too many innocent decoys. Kleiners win.")
	end

	local alive = SyncCounters()
	if alive == 0 then
		return EndRound(TEAM_BREEN, "Every real Kleiner has been found. Breen wins.")
	end
end

-- Main tick
timer.Create("kh_tick", 0.5, 0, function()
	local s = KH.State()

	if s == KH.WAITING then
		if #player.GetAll() >= 2 then
			SetState(KH.WAITING, 0)
			KH.StartRound()
		end
		return
	end

	if s == KH.HIDING then
		if KH.TimeLeft() <= 0 then
			SetState(KH.HUNTING, CFG.HuntTime)
			KH.AlertAll("The hunt has begun.", Color(255, 160, 120))
		end
		return
	end

	if s == KH.HUNTING then
		-- Basket delivery check
		if KH.MapData.basket then
			local bpos = ToVec(KH.MapData.basket)
			for _, ply in ipairs(team.GetPlayers(TEAM_KLEINER)) do
				if ply:Alive() and IsValid(ply.KH_Carrying) then
					if ply:GetPos():DistToSqr(bpos) < CFG.BasketRadius ^ 2 then
						local dev = ply.KH_Carrying
						KH.DropDevice(ply)
						if IsValid(dev) then dev:Remove() end
						KH.Delivered = KH.Delivered + 1
						KH.AlertAll("A device reached the basket. (" .. KH.Delivered .. "/" .. CFG.DevicesToWin .. ")")
					end
				end
			end
		end

		KH.CheckWin()

		if KH.State() == KH.HUNTING and KH.TimeLeft() <= 0 then
			EndRound(TEAM_KLEINER, "Time expired. The Kleiners survived.")
		end
		return
	end

	if s == KH.POST and KH.TimeLeft() <= 0 then
		KH.ClearDecoys()
		KH.ClearDevices()
		KH.StartRound()
	end
end)

-- Forced taunts so silence doesn't give players away
timer.Create("kh_taunt", 1, 0, function()
	if CFG.TauntInterval <= 0 or KH.State() ~= KH.HUNTING then return end
	KH.NextTaunt = KH.NextTaunt or 0
	if CurTime() < KH.NextTaunt then return end
	KH.NextTaunt = CurTime() + CFG.TauntInterval

	local alive = {}
	for _, ply in ipairs(team.GetPlayers(TEAM_KLEINER)) do
		if ply:Alive() then table.insert(alive, ply) end
	end
	if #alive == 0 then return end

	local ply = alive[math.random(#alive)]
	ply:EmitSound(CFG.Taunts[math.random(#CFG.Taunts)], 75)
	KH.Alert(ply, "You blurted something out.", Color(255, 200, 120))
end)

-- ============================================================
-- ELIMINATION / ACCUSATION
-- ============================================================
function KH.Eliminate(ply, breen)
	-- Alyx can only be eliminated if Breen stunned her first this round
	if ply.KH_IsAlyx and not ply.KH_AlyxStunned then
		KH.Alert(breen, "That\'s Alyx. You need to stun her first!", Color(255, 160, 80))
		KH.Strike(breen, nil)  -- costs a strike for wasting the accusation
		return
	end

	if IsValid(ply.KH_Carrying) then KH.DropDevice(ply, ply:GetPos() + Vector(0, 0, 20)) end

	ply:EmitSound("vo/npc/male01/pain0" .. math.random(1, 4) .. ".wav", 80)
	ply:Kill()
	ply:SetTeam(TEAM_SPEC)

	timer.Simple(3, function()
		if IsValid(ply) and ply:Team() == TEAM_SPEC then
			ply:Spectate(OBS_MODE_ROAMING)
		end
	end)

	KH.AlertAll(ply:Nick() .. " was a real Kleiner.", Color(255, 140, 130))
	KH.CheckWin()
end

function KH.Strike(breen, npc)
	KH.Strikes = KH.Strikes + 1

	if IsValid(npc) then
		npc:EmitSound("vo/k_lab/kl_ohdear.wav", 90)
		npc:Remove()
	end

	breen.KH_SlowUntil = CurTime() + CFG.StrikePenalty

	net.Start("kh_flash")
	net.Send(breen)

	-- Everyone hears it; Kleiners get his position for a moment
	sound.Play("ambient/energy/zap9.wav", breen:GetPos(), 110, 100)
	net.Start("kh_reveal")
	net.WriteVector(breen:GetPos())
	net.WriteFloat(CurTime() + CFG.RevealTime)
	net.Broadcast()

	KH.AlertAll("Breen accused a decoy. (" .. KH.Strikes .. "/" .. CFG.MaxStrikes .. ")", Color(255, 200, 120))
	SyncCounters()
	KH.CheckWin()
end

-- ============================================================
-- STUNSTICK ALYX: stun Breen on hit
-- ============================================================
local STUN_DURATION = 8.0

hook.Add("EntityTakeDamage", "kh_alyx_hit", function(target, dmginfo)
	if KH.State() ~= KH.HUNTING then return end
	if not target:IsPlayer() then return end
	-- If Breen hits Alyx with any weapon, mark her as stun-vulnerable
	if target.KH_IsAlyx then
		local attacker = dmginfo:GetAttacker()
		if IsValid(attacker) and attacker:IsPlayer() and attacker:Team() == TEAM_BREEN then
			target.KH_AlyxStunned = true
			KH.Alert(target, "You\'ve been stunned! Breen can now eliminate you.", Color(255, 120, 80))
			KH.Alert(attacker, "You stunned Alyx! Accuse her now.", Color(255, 200, 120))
		end
		return
	end
	if target:Team() ~= TEAM_BREEN then return end

	local attacker = dmginfo:GetAttacker()
	if not IsValid(attacker) or not attacker:IsPlayer() then return end
	if not attacker.KH_IsAlyx then return end

	-- Stun Breen
	local stunUntil = CurTime() + STUN_DURATION
	target.KH_StunUntil = stunUntil
	target.KH_SlowUntil = stunUntil  -- also applies the movement slow

	net.Start("kh_breen_stun")
	net.WriteFloat(stunUntil)
	net.Send(target)

	sound.Play("weapons/stunstick/stunstick_hit" .. math.random(1,2) .. ".wav", target:GetPos(), 100)
	KH.AlertAll(attacker:Nick() .. " stunned Breen for 8 seconds!", Color(180, 220, 255))
	KH.Alert(target, "You have been stunned by Stunstick Alyx!", Color(255, 160, 80))
end)

-- ============================================================
-- PLAYER SETUP
-- ============================================================
local ALYX_MODEL = "models/alyx.mdl"

function GM:PlayerSetModel(ply)
	local t = ply:Team()
	if t == TEAM_BREEN then
		util.PrecacheModel(CFG.BreenModel)
		ply:SetModel(CFG.BreenModel)
	elseif ply.KH_IsAlyx then
		util.PrecacheModel(ALYX_MODEL)
		ply:SetModel(ALYX_MODEL)
	else
		util.PrecacheModel(CFG.KleinerModel)
		ply:SetModel(CFG.KleinerModel)
	end
end

function GM:PlayerLoadout(ply)
	ply:RemoveAllAmmo()
	if ply:Team() == TEAM_BREEN then
		ply:Give("weapon_kh_accuse")
		ply:Give("weapon_ar2")
		ply:Give("weapon_357")
		ply:Give("weapon_crowbar")
		ply:Give("weapon_shotgun")
		ply:GiveAmmo(60, "AR2")
		ply:GiveAmmo(12, "357")
		ply:GiveAmmo(30, "Buckshot")
		ply:SetWalkSpeed(CFG.BreenWalk)
		ply:SetRunSpeed(CFG.BreenRun)
	elseif ply.KH_IsMedic then
		-- Medic Kleiner: fists only, no crowbar
		ply:SetWalkSpeed(CFG.KleinerWalk)
		ply:SetRunSpeed(CFG.KleinerRun)
	elseif ply.KH_IsAlyx then
		-- Stunstick Alyx: stunstick only
		ply:Give("weapon_stunstick")
		ply:SetWalkSpeed(CFG.KleinerWalk + 20)  -- slightly faster than Kleiners
		ply:SetRunSpeed(CFG.KleinerRun + 30)
	else
		ply:Give("weapon_crowbar")
		ply:SetWalkSpeed(CFG.KleinerWalk)
		ply:SetRunSpeed(CFG.KleinerRun)
	end
	return true
end

function GM:PlayerSpawn(ply)
	self.BaseClass:PlayerSpawn(ply)

	if ply:Team() == TEAM_SPEC then
		ply:Spectate(OBS_MODE_ROAMING)
		ply:StripWeapons()
		return
	end

	ply:UnSpectate()
	ply:SetColor(Color(255, 255, 255))
	ply:SetPlayerColor(Vector(1, 1, 1))
	ply.KH_Carrying = nil
end

function GM:PlayerInitialSpawn(ply)
	self.BaseClass:PlayerInitialSpawn(ply)
	ply:SetTeam(TEAM_SPEC)
	SyncCounters()
end

function GM:PlayerDeathThink(ply)
	return false -- no mid-round respawns
end

function GM:PlayerDeath(ply, inflictor, attacker)
	if IsValid(ply.KH_Carrying) then KH.DropDevice(ply, ply:GetPos() + Vector(0, 0, 20)) end
	self.BaseClass:PlayerDeath(ply, inflictor, attacker)
	SyncCounters()
end

function GM:PlayerDisconnected(ply)
	if IsValid(ply.KH_Carrying) then KH.DropDevice(ply, ply:GetPos() + Vector(0, 0, 20)) end
	timer.Simple(0.1, function() KH.CheckWin() end)
end

function GM:PlayerSwitchFlashlight(ply, on)
	return ply:Team() == TEAM_BREEN -- a Kleiner with a flashlight is not a decoy
end

function GM:PlayerCanPickupWeapon(ply, wep)
	return ply:Team() == TEAM_BREEN
end

function GM:PlayerShouldTakeDamage(ply, attacker)
	return false -- eliminations only happen through accusation
end

function GM:Move(ply, mv)
	-- Slowdowns: carrying a device, or serving a strike penalty
	if ply:Team() == TEAM_KLEINER and IsValid(ply.KH_Carrying) then
		mv:SetMaxClientSpeed(mv:GetMaxClientSpeed() * CFG.CarrySlowdown)
	elseif ply:Team() == TEAM_BREEN and (ply.KH_SlowUntil or 0) > CurTime() then
		mv:SetMaxClientSpeed(mv:GetMaxClientSpeed() * 0.35)
	end
	return self.BaseClass:Move(ply, mv)
end

function GM:SetupMove(ply, mv, cmd)
	-- Freeze Breen during the hiding phase
	if KH.State() == KH.HIDING and ply:Team() == TEAM_BREEN then
		mv:SetForwardSpeed(0)
		mv:SetSideSpeed(0)
		mv:SetMaxClientSpeed(0)
	end
	return self.BaseClass:SetupMove(ply, mv, cmd)
end

-- Keep sandbox spawning out of live rounds
function GM:PlayerSpawnObject(ply)
	if KH.State() == KH.HUNTING or KH.State() == KH.HIDING then
		return ply:IsAdmin()
	end
	return true
end

function GM:CanTool(ply)
	return ply:IsAdmin() or KH.State() == KH.WAITING
end

-- ============================================================
-- SETUP COMMANDS  (admin, type in chat)
-- ============================================================
local commands = {
	["!kh_decoy"] = function(ply)
		table.insert(KH.MapData.decoys, {
			pos = { x = ply:GetPos().x, y = ply:GetPos().y, z = ply:GetPos().z },
			yaw = ply:EyeAngles().y,
		})
		KH.SaveMapData()
		return "Decoy point #" .. #KH.MapData.decoys .. " saved."
	end,

	["!kh_device"] = function(ply)
		table.insert(KH.MapData.devices, {
			pos = { x = ply:GetPos().x, y = ply:GetPos().y, z = ply:GetPos().z },
		})
		KH.SaveMapData()
		return "Device spawn #" .. #KH.MapData.devices .. " saved."
	end,

	["!kh_basket"] = function(ply)
		local p = ply:GetPos()
		KH.MapData.basket = { x = p.x, y = p.y, z = p.z }
		KH.SaveMapData()
		return "Basket location set here."
	end,

	["!kh_clear"] = function(ply)
		KH.MapData = { decoys = {}, devices = {}, basket = nil }
		KH.SaveMapData()
		return "All saved points cleared."
	end,

	["!kh_start"] = function(ply)
		KH.ClearDecoys()
		KH.ClearDevices()
		KH.StartRound()
		return "Round restarted."
	end,

	["!kh_info"] = function(ply)
		return string.format("%d decoy points, %d device spawns, basket: %s",
			#KH.MapData.decoys, #KH.MapData.devices, KH.MapData.basket and "set" or "NOT SET")
	end,
}

function GM:PlayerSay(ply, text)
	local cmd = string.lower(string.Trim(text))
	local fn = commands[cmd]
	if not fn then return end

	if not ply:IsAdmin() then
		KH.Alert(ply, "Admins only.")
		return ""
	end

	KH.Alert(ply, fn(ply), Color(150, 255, 150))
	return ""
end

hook.Add("Initialize", "kh_load", function()
	if KH.LoadMapData() then
		print(string.format("[KleinerHunt] Loaded %d decoy points, %d device spawns.",
			#KH.MapData.decoys, #KH.MapData.devices))
	else
		print("[KleinerHunt] No map data yet. Use !kh_decoy / !kh_device / !kh_basket as admin.")
	end
end)
