AddCSLuaFile()

SWEP.PrintName = "Accusation"
SWEP.Author    = ""
SWEP.Purpose   = "Point at a Kleiner and accuse. Be right."
SWEP.Slot      = 0
SWEP.SlotPos   = 0
SWEP.DrawAmmo  = false
SWEP.DrawCrosshair = true

SWEP.Spawnable = false
SWEP.AdminOnly = true

SWEP.ViewModel  = "models/weapons/v_pistol.mdl"
SWEP.WorldModel = ""
SWEP.UseHands   = false

SWEP.Primary.ClipSize    = -1
SWEP.Primary.DefaultClip = -1
SWEP.Primary.Automatic   = false
SWEP.Primary.Ammo        = "none"

SWEP.Secondary.ClipSize    = -1
SWEP.Secondary.DefaultClip = -1
SWEP.Secondary.Automatic   = false
SWEP.Secondary.Ammo        = "none"

function SWEP:Initialize()
	self:SetHoldType("normal")
end

function SWEP:PrimaryAttack()
	local ply = self:GetOwner()
	if not IsValid(ply) then return end

	self:SetNextPrimaryFire(CurTime() + (KH.CFG.AccuseCooldown or 1.2))

	if KH.State() ~= KH.HUNTING then return end
	if (ply.KH_SlowUntil or 0) > CurTime() then return end

	local tr = util.TraceLine({
		start  = ply:EyePos(),
		endpos = ply:EyePos() + ply:GetAimVector() * (KH.CFG.AccuseRange or 110),
		filter = ply,
		mask   = MASK_SHOT_HULL,
	})

	ply:SetAnimation(PLAYER_ATTACK1)
	if not SERVER then return end

	local ent = tr.Entity
	if not IsValid(ent) then
		KH.Alert(ply, "You accused thin air.", Color(180, 180, 180))
		return
	end

	if ent:IsPlayer() and ent:Team() == TEAM_KLEINER and ent:Alive() then
		KH.Eliminate(ent, ply)
	elseif ent.KH_Decoy then
		KH.Strike(ply, ent)
	else
		KH.Alert(ply, "Not a Kleiner.", Color(180, 180, 180))
	end
end

function SWEP:SecondaryAttack()
	local ply = self:GetOwner()
	if not IsValid(ply) or not SERVER then return end

	self:SetNextSecondaryFire(CurTime() + 8)

	-- Breen's PA taunt: pressure the hiders into moving
	for _, p in ipairs(player.GetAll()) do
		p:EmitSound("vo/citadel/br_hello.wav", 100)
	end
	KH.AlertAll("Breen is addressing the facility.", Color(255, 160, 150))
end

if CLIENT then
	function SWEP:DrawHUD()
		local x, y = ScrW() / 2, ScrH() / 2
		surface.SetDrawColor(255, 90, 80, 200)
		surface.DrawOutlinedRect(x - 12, y - 12, 24, 24, 2)
		surface.DrawRect(x - 1, y - 1, 2, 2)
	end
end
