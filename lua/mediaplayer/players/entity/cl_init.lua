include "shared.lua"

DEFINE_BASECLASS( "mp_base" )

local print = print
local IsValid = IsValid
local cam = cam
local Start3D2D = cam.Start3D2D
local End3D2D = cam.End3D2D
local RealTime = RealTime
local LocalPlayer = LocalPlayer
local CursorVisible = vgui.CursorVisible

-- Distance culling threshold (squared to avoid sqrt)
local MAX_DRAW_DISTANCE_SQR = 2500 * 2500

-- Must match cl_draw.lua fadeout timing
local InfoDisplayTime = 3
local InfoFadeTime = 1

function MEDIAPLAYER:NetReadUpdate()
	local entIndex = net.ReadUInt(16)
	local ent = Entity(entIndex)
	local mpEnt = self.Entity

	if MediaPlayer.DEBUG then
		print("MEDIAPLAYER.NetReadUpdate[entity]: ", ent, entIndex)
	end

	if ent ~= mpEnt then
		if IsValid(ent) and ent ~= NULL then
			ent:InstallMediaPlayer( self )
		else
			-- Wait until the entity becomes valid
			self._EntIndex = entIndex
		end
	end
end

local RenderScale = 0.1
local InfoScale = 1 / 17

function MEDIAPLAYER:GetOrientation()
	local ent = self.Entity

	if ent then
		return ent:GetMediaPlayerPosition()
	end

	return nil
end

---
-- Draws the idlescreen; this is drawn when there is no media playing.
--
function MEDIAPLAYER:DrawIdlescreen( w, h )
	local browser = MediaPlayer.GetIdlescreen()

	if IsValid(browser) then
		self:DrawHTML( browser, w, h )
	end
end

local BaseInfoHeight = 60

--[[---------------------------------------------------------
	Screen cursor

	Arrow pointer drawn where the mouse is hovering, since CEF renders
	the page without one. Split into convex pieces because
	surface.DrawPoly can't draw the concave arrow in one go. Points are
	offsets from the tip in units of cursor height, wound clockwise.
-----------------------------------------------------------]]

local CURSOR_SHAPE = {
	{ 0, 0,  0.20, 0.68,  0, 0.86 },
	{ 0, 0,  0.32, 0.63,  0.20, 0.68 },
	{ 0, 0,  0.60, 0.63,  0.32, 0.63 },
	{ 0.32, 0.63,  0.46, 0.94,  0.34, 1.00,  0.20, 0.68 },
}

-- Reused every frame to avoid allocating while the cursor is shown
local cursorPolys = {}
for i = 1, #CURSOR_SHAPE do
	local poly = {}
	for v = 1, #CURSOR_SHAPE[i] / 2 do
		poly[v] = { x = 0, y = 0 }
	end
	cursorPolys[i] = poly
end

local function DrawCursorShape( ox, oy, size )
	for i = 1, #CURSOR_SHAPE do
		local shape, poly = CURSOR_SHAPE[i], cursorPolys[i]

		for v = 1, #poly do
			local vert = poly[v]
			vert.x = ox + shape[v * 2 - 1] * size
			vert.y = oy + shape[v * 2] * size
		end

		surface.DrawPoly( poly )
	end
end

local function DrawScreenCursor( x, y, h )
	local size = math.max( 16, h * 0.05 )
	local outline = size * 0.06

	draw.NoTexture()

	-- Dark outline so the cursor stands out on light and dark pages
	surface.SetDrawColor( 0, 0, 0, 220 )
	DrawCursorShape( x - outline, y - outline, size )
	DrawCursorShape( x + outline, y + outline, size )

	surface.SetDrawColor( 255, 255, 255, 255 )
	DrawCursorShape( x, y, size )
end

function MEDIAPLAYER:Draw( bDrawingDepth, bDrawingSkybox )

	local ent = self.Entity

	-- When fullscreen is active, check if HUDPaint is actually rendering.
	-- If it isn't (e.g. gmod_camera suppresses HUD), fall back to 3D rendering.
	if self._isFullscreen then
		if self._hudPaintFired then
			-- HUDPaint is working, let DrawFullscreen handle it
			self._hudPaintFired = false
			return
		end
		-- HUDPaint didn't fire since last frame, fall through to 3D rendering
	end

	if not IsValid(ent) or
			(ent.IsDormant and ent:IsDormant()) then
		return
	end

	-- Distance culling: skip all rendering if player is too far
	if LocalPlayer():EyePos():DistToSqr(ent:GetPos()) > MAX_DRAW_DISTANCE_SQR then
		return
	end

	local media = self:GetMedia()
	local w, h, pos, ang = self:GetOrientation()
	if not w then return end

	-- Render scale
	local rw, rh = w / RenderScale, h / RenderScale

	if IsValid(media) then

		-- Custom media draw function
		if media.Draw then
			Start3D2D( pos, ang, RenderScale )
				media:Draw( rw, rh )
			End3D2D()
		else
			Start3D2D( pos, ang, RenderScale )
				draw.SimpleText( MediaPlayer.L("mp.ui.unsupported_media"), "DermaDefault", rw / 2, rh / 2, color_white, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER )
			End3D2D()
		end

		-- Mouse cursor from holding the context menu over the screen
		local cursorX, cursorY = self._cursorX, self._cursorY
		if cursorX then
			Start3D2D( pos, ang, RenderScale )
				DrawScreenCursor( cursorX * rw, cursorY * rh, rh )
			End3D2D()
		end

		-- Skip the 3D2D pass entirely if media info has fully faded
		local elapsed = RealTime() - self._LastMediaUpdate
		if CursorVisible() or elapsed <= InfoDisplayTime + InfoFadeTime then
			-- scale based off of height
			local scale = InfoScale * ( h / BaseInfoHeight )

			-- Media info
			Start3D2D( pos, ang, scale )
				local iw, ih = w / scale, h / scale
				self:DrawMediaInfo( media, iw, ih )
			End3D2D()
		end

	else

		Start3D2D( pos, ang, RenderScale )
			self:DrawIdlescreen( rw, rh )
		End3D2D()

	end

end

function MEDIAPLAYER:SetMedia( media )
	if media then
		-- Set entity on media for 3D audio support and setting proper
		-- browser resolution
		media.Entity = self:GetEntity()
	end

	BaseClass.SetMedia( self, media )
end

---
-- Mouse click intersected with 3D2D screen.
--
function MEDIAPLAYER:OnMousePressed( x, y )
	local media = self:GetMedia()
	if media and media:IsMouseInputEnabled() then
		media:OnMousePressed( x, y )
	end
end

function MEDIAPLAYER:OnMouseWheeled( scrollDelta )
	local media = self:GetMedia()
	if media and media:IsMouseInputEnabled() then
		media:OnMouseWheeled( scrollDelta )
	end
end

---
-- Mouse is hovering over the 3D2D screen while the context menu is open.
-- Called every frame while it is.
--
-- @return boolean	True if the media took the cursor.
function MEDIAPLAYER:OnMouseMoved( x, y )
	local media = self:GetMedia()

	if IsValid( media ) and media:IsMouseInputEnabled() and media:OnMouseMoved( x, y ) then
		self._cursorX, self._cursorY = x, y
		return true
	end

	if self._cursorX then
		self:OnMouseLeft()
	end

	return false
end

function MEDIAPLAYER:OnMouseLeft()
	self._cursorX, self._cursorY = nil, nil

	local media = self:GetMedia()
	if IsValid( media ) then
		media:OnMouseLeft()
	end
end
