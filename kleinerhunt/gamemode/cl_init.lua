include("shared.lua")

local CFG = KH.CFG

surface.CreateFont("KH_Big",   { font = "Roboto", size = 46, weight = 700 })
surface.CreateFont("KH_Med",   { font = "Roboto", size = 24, weight = 600 })
surface.CreateFont("KH_Small", { font = "Roboto", size = 18, weight = 500 })

-- ============================================================
-- Hide every tell the default HUD would give away
-- ============================================================
local hidden = {
	CHudHealth = true, CHudBattery = true, CHudAmmo = true,
	CHudSecondaryAmmo = true, CHudSuitPower = true, CHudCrosshair = true,
}

function GM:HUDShouldDraw(name)
	if hidden[name] then return false end
	return self.BaseClass:HUDShouldDraw(name)
end

-- No floating names over players: that is the whole game
function GM:HUDDrawTargetID()
	return false
end

function GM:PostPlayerDraw() end

-- ============================================================
-- Alerts
-- ============================================================
local alerts = {}

net.Receive("kh_alert", function()
	local msg = net.ReadString()
	local col = net.ReadColor(false)
	table.insert(alerts, { msg = msg, col = col, die = CurTime() + 5 })
end)

local flashUntil = 0
net.Receive("kh_flash", function()
	flashUntil = CurTime() + CFG.StrikePenalty
end)

local revealPos, revealUntil = nil, 0
net.Receive("kh_reveal", function()
	revealPos = net.ReadVector()
	revealUntil = net.ReadFloat()
end)

-- ============================================================
-- HUD
-- ============================================================
local function FormatTime(t)
	return string.format("%d:%02d", math.floor(t / 60), math.floor(t % 60))
end

local phaseNames = {
	[KH.WAITING] = "Waiting for players",
	[KH.HIDING]  = "Hiding",
	[KH.HUNTING] = "Hunting",
	[KH.POST]    = "Round over",
}

function GM:HUDPaint()
	local ply = LocalPlayer()
	if not IsValid(ply) then return end

	local sw = ScrW()
	local state = KH.State()

	-- Top center: phase + timer
	local phase = phaseNames[state] or "?"
	draw.SimpleText(phase, "KH_Med", sw / 2, 18, Color(230, 230, 230, 220), TEXT_ALIGN_CENTER)
	if state == KH.HIDING or state == KH.HUNTING or state == KH.POST then
		draw.SimpleText(FormatTime(KH.TimeLeft()), "KH_Big", sw / 2, 40,
			state == KH.HIDING and Color(140, 200, 255) or Color(255, 235, 200), TEXT_ALIGN_CENTER)
	end

	-- Left: role + objective
	local t = ply:Team()
	local roleCol = t == TEAM_BREEN and Color(255, 120, 110)
		or t == TEAM_KLEINER and Color(140, 200, 255)
		or Color(170, 170, 170)
	local roleName = t == TEAM_BREEN and "DR. BREEN"
		or t == TEAM_KLEINER and "KLEINER"
		or "SPECTATOR"

	draw.SimpleText(roleName, "KH_Med", 24, ScrH() - 108, roleCol)

	local alive = GetGlobalInt("kh_alive", 0)
	local delivered = GetGlobalInt("kh_delivered", 0)
	local devgoal = GetGlobalInt("kh_devgoal", 1)
	local strikes = GetGlobalInt("kh_strikes", 0)
	local maxStrikes = GetGlobalInt("kh_maxstrikes", 5)

	draw.SimpleText("Real Kleiners remaining: " .. alive, "KH_Small", 24, ScrH() - 78, Color(220, 220, 220))
	draw.SimpleText("Devices delivered: " .. delivered .. " / " .. devgoal, "KH_Small", 24, ScrH() - 56, Color(220, 220, 220))
	draw.SimpleText("Breen's strikes: " .. strikes .. " / " .. maxStrikes, "KH_Small", 24, ScrH() - 34, Color(255, 200, 140))

	if ply:GetNWBool("kh_carrying", false) then
		draw.SimpleText("CARRYING DEVICE - you are slower and visible", "KH_Med",
			sw / 2, ScrH() - 70, Color(255, 210, 120), TEXT_ALIGN_CENTER)
	end

	-- Alerts, newest at the bottom
	for i = #alerts, 1, -1 do
		if CurTime() > alerts[i].die then table.remove(alerts, i) end
	end
	for i, a in ipairs(alerts) do
		local alpha = math.Clamp((a.die - CurTime()) * 255, 0, 255)
		draw.SimpleText(a.msg, "KH_Med", sw / 2, 120 + (i - 1) * 26,
			ColorAlpha(a.col, alpha), TEXT_ALIGN_CENTER)
	end

	-- Strike penalty flash
	if CurTime() < flashUntil then
		local a = math.Clamp((flashUntil - CurTime()) / CFG.StrikePenalty, 0, 1) * 200
		surface.SetDrawColor(255, 60, 40, a)
		surface.DrawRect(0, 0, ScrW(), ScrH())
		draw.SimpleText("WRONG", "KH_Big", sw / 2, ScrH() / 2 - 30, Color(255, 255, 255, a + 55), TEXT_ALIGN_CENTER)
	end

	-- Breen's position revealed to Kleiners after a wrong accusation
	if revealPos and CurTime() < revealUntil and t ~= TEAM_BREEN then
		local scr = revealPos:ToScreen()
		if scr.visible then
			local a = math.Clamp((revealUntil - CurTime()) * 120, 0, 255)
			surface.SetDrawColor(255, 90, 80, a)
			surface.DrawOutlinedRect(scr.x - 16, scr.y - 16, 32, 32, 2)
			draw.SimpleText("BREEN", "KH_Small", scr.x, scr.y + 20, Color(255, 120, 110, a), TEXT_ALIGN_CENTER)
		end
	end
end

-- Kleiners keep first person: seeing your own body breaks the illusion of blending
function GM:ShouldDrawLocalPlayer()
	return false
end

-- ============================================================
-- MEDIC: track if this client is the medic
-- ============================================================
local isMedic = false

net.Receive("kh_medic_set", function()
	isMedic = true
end)

-- Reset medic flag on round restart (state goes to HIDING)
hook.Add("Think", "kh_medic_reset", function()
	if KH.State() == KH.WAITING or KH.State() == KH.POST then
		isMedic = false
	end
end)

-- Red glow around all medic Kleiners (visible to everyone including Breen)
hook.Add("PreDrawTranslucentRenderables", "kh_medic_glow", function()
	if KH.State() ~= KH.HUNTING and KH.State() ~= KH.HIDING then return end

	for _, ply in ipairs(team.GetPlayers(TEAM_KLEINER)) do
		if IsValid(ply) and ply:Alive() and ply:GetNWBool("kh_medic", false) then
			local pos = ply:GetPos() + Vector(0, 0, 36)

			-- Soft pulsing red halo using a sprite
			local pulse = math.abs(math.sin(CurTime() * 2)) * 0.5 + 0.5
			local size  = 80 + pulse * 30
			local alpha = math.floor(120 + pulse * 80)

			render.SetMaterial(Material("sprites/light_glow02_add"))
			render.DrawSprite(pos, size, size, Color(255, 60, 60, alpha))
		end
	end
end)

-- Medic's own HUD: show heal range ring and role label
hook.Add("HUDPaint", "kh_medic_hud", function()
	local ply = LocalPlayer()
	if not IsValid(ply) or not isMedic then return end
	if not ply:Alive() or ply:Team() ~= TEAM_KLEINER then return end
	if KH.State() ~= KH.HUNTING then return end

	-- Role label in red at top of screen
	draw.SimpleText("MEDIC KLEINER", "KH_Med", ScrW() / 2, 90,
		Color(255, 100, 100, 220), TEXT_ALIGN_CENTER)

	-- Count nearby allies in range
	local count = 0
	for _, target in ipairs(team.GetPlayers(TEAM_KLEINER)) do
		if target ~= ply and target:Alive() then
			if ply:GetPos():DistToSqr(target:GetPos()) < 150 * 150 then
				count = count + 1
			end
		end
	end

	if count > 0 then
		draw.SimpleText("Healing " .. count .. " Kleiner" .. (count > 1 and "s" or ""),
			"KH_Small", ScrW() / 2, 114, Color(255, 160, 160, 200), TEXT_ALIGN_CENTER)
	end
end)

-- ============================================================
-- STUNSTICK ALYX CLIENT
-- ============================================================
local isAlyx      = false
local alyxVolunteers = {}   -- list of names shown in the UI
local stunUntil   = 0
local STUN_DURATION = 8.0

net.Receive("kh_alyx_set", function()
	isAlyx = true
end)

net.Receive("kh_alyx_list", function()
	alyxVolunteers = net.ReadTable()
end)

net.Receive("kh_breen_stun", function()
	stunUntil = net.ReadFloat()
end)

-- Reset on new round
hook.Add("Think", "kh_alyx_reset", function()
	if KH.State() == KH.WAITING or KH.State() == KH.POST then
		isAlyx = false
	end
end)

-- Alyx sign-up button: visible only during WAITING phase
hook.Add("HUDPaint", "kh_alyx_signup_ui", function()
	if KH.State() ~= KH.WAITING then return end
	local ply = LocalPlayer()
	if not IsValid(ply) then return end

	local sw, sh = ScrW(), ScrH()
	local bw, bh = 240, 48
	local bx, by = sw / 2 - bw / 2, sh - 160

	-- Volunteer list
	draw.SimpleText("STUNSTICK ALYX SLOTS  " .. #alyxVolunteers .. " / 3",
		"KH_Small", sw / 2, by - 36, Color(180, 220, 255, 200), TEXT_ALIGN_CENTER)
	for i, name in ipairs(alyxVolunteers) do
		draw.SimpleText(i .. ". " .. name, "KH_Small",
			sw / 2, by - 16 + (i - 1) * 18, Color(220, 220, 220, 180), TEXT_ALIGN_CENTER)
	end

	-- Check if this player is already signed up
	local myName = ply:Nick()
	local signedUp = false
	for _, n in ipairs(alyxVolunteers) do
		if n == myName then signedUp = true break end
	end

	-- Draw button
	local col = signedUp and Color(60, 140, 220) or Color(40, 40, 60)
	local border = signedUp and Color(120, 180, 255) or Color(100, 100, 130)
	surface.SetDrawColor(col)
	surface.DrawRect(bx, by, bw, bh)
	surface.SetDrawColor(border)
	surface.DrawOutlinedRect(bx, by, bw, bh, 2)
	draw.SimpleText(
		signedUp and "✓ SIGNED UP AS ALYX" or "SIGN UP AS STUNSTICK ALYX",
		"KH_Small", sw / 2, by + bh / 2, Color(255, 255, 255), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER
	)

	-- Click detection
	if input.IsMouseDown(MOUSE_LEFT) then
		local mx, my = gui.MousePos()
		if mx >= bx and mx <= bx + bw and my >= by and my <= by + bh then
			if not KH._alyxClickHeld then
				net.Start("kh_alyx_signup")
				net.SendToServer()
				KH._alyxClickHeld = true
			end
		else
			KH._alyxClickHeld = false
		end
	else
		KH._alyxClickHeld = false
	end
end)

-- Alyx role HUD indicator
hook.Add("HUDPaint", "kh_alyx_hud", function()
	local ply = LocalPlayer()
	if not IsValid(ply) or not isAlyx then return end
	if not ply:Alive() or ply:Team() ~= TEAM_KLEINER then return end

	draw.SimpleText("STUNSTICK ALYX", "KH_Med", ScrW() / 2, 90,
		Color(180, 220, 255, 220), TEXT_ALIGN_CENTER)
	draw.SimpleText("Hit Breen with your stunstick to stun him for 8 seconds.",
		"KH_Small", ScrW() / 2, 114, Color(180, 200, 230, 180), TEXT_ALIGN_CENTER)
end)

-- Breen stun screen effect
hook.Add("HUDPaint", "kh_breen_stun_hud", function()
	if CurTime() >= stunUntil then return end
	local frac = (stunUntil - CurTime()) / STUN_DURATION
	local a = math.floor(frac * 160)
	-- Blue-white electrical flash
	surface.SetDrawColor(100, 180, 255, a)
	surface.DrawRect(0, 0, ScrW(), ScrH())
	draw.SimpleText("STUNNED", "KH_Big", ScrW() / 2, ScrH() / 2 - 30,
		Color(255, 255, 255, a + 60), TEXT_ALIGN_CENTER)
	draw.SimpleText(string.format("%.1f", stunUntil - CurTime()) .. "s",
		"KH_Med", ScrW() / 2, ScrH() / 2 + 20,
		Color(200, 230, 255, a + 40), TEXT_ALIGN_CENTER)
end)

-- ============================================================
-- CHASE MUSIC
-- Plays privately for any Kleiner within 800 units of Breen.
-- Fades out smoothly when they move out of range.
-- ============================================================
local CHASE_SOUND     = "kh_chase.mp3"
local CHASE_RADIUS    = 800
local CHASE_RADIUS_SQ = CHASE_RADIUS * CHASE_RADIUS
local FADE_TIME       = 3.0
local MAX_VOL         = 0.8

local chaseChannel  = nil
local chaseActive   = false
local fadeOutUntil  = 0

sound.AddFile("kh_chase.mp3")

local function StopChase(fade)
	if not IsValid(chaseChannel) then
		chaseActive = false
		return
	end
	if fade then
		fadeOutUntil = CurTime() + FADE_TIME
	else
		chaseChannel:Stop()
		chaseChannel = nil
		chaseActive  = false
		fadeOutUntil = 0
	end
end

local function StartChase()
	if chaseActive then return end
	fadeOutUntil = 0

	sound.PlayFile("sound/" .. CHASE_SOUND, "noblock", function(ch, err, errStr)
		if not IsValid(ch) then
			print("[KleinerHunt] Chase music failed: " .. tostring(errStr))
			return
		end
		chaseChannel = ch
		chaseChannel:SetVolume(MAX_VOL)
		chaseChannel:EnableLooping(true)
		chaseChannel:Play()
		chaseActive = true
	end)
end

hook.Add("Think", "kh_chase_music", function()
	local ply = LocalPlayer()
	if not IsValid(ply) then return end

	if ply:Team() ~= TEAM_KLEINER or not ply:Alive() then
		if chaseActive then StopChase(false) end
		return
	end

	if KH.State() ~= KH.HUNTING then
		if chaseActive then StopChase(false) end
		return
	end

	-- Find Breen
	local breen = nil
	for _, p in ipairs(team.GetPlayers(TEAM_BREEN)) do
		if p:Alive() then breen = p break end
	end

	if not IsValid(breen) then
		if chaseActive then StopChase(true) end
		return
	end

	local inRange = ply:GetPos():DistToSqr(breen:GetPos()) < CHASE_RADIUS_SQ

	if inRange then
		fadeOutUntil = 0
		StartChase()
	elseif chaseActive and fadeOutUntil == 0 then
		StopChase(true)
	end

	-- Fade out tick
	if fadeOutUntil > 0 and IsValid(chaseChannel) then
		local frac = (fadeOutUntil - CurTime()) / FADE_TIME
		if frac <= 0 then
			chaseChannel:Stop()
			chaseChannel = nil
			chaseActive  = false
			fadeOutUntil = 0
		else
			chaseChannel:SetVolume(MAX_VOL * frac)
		end
	end
end)
