--[[---------------------------------------------------------
	Pass mouse clicks into media player browser
-----------------------------------------------------------]]

local MAX_SCREEN_DISTANCE = 1000

local function getScreenPos( ent, aimVector )
	if not ent.GetMediaPlayerPosition then return end
	local w, h, pos, ang = ent:GetMediaPlayerPosition()
	if not pos then return end
	local eyePos = LocalPlayer():EyePos()

	if pos:Distance( eyePos ) > MAX_SCREEN_DISTANCE then
		return
	end

	local screenNormal = ang:Up()

	if screenNormal:Dot( aimVector ) > 0 then
		return -- prevent clicks from behind the screen
	end

	local hitPos = util.IntersectRayWithPlane(
		eyePos,
		aimVector,
		pos,
		screenNormal
	)

	if not hitPos then
		return
	end

	if MediaPlayer.DEBUG then
		debugoverlay.Cross( hitPos, 1, 60 )
	end

	local localPos = WorldToLocal( pos, ang, hitPos, ang )
	local x, y = -localPos.x, localPos.y

	if ( x < 0 or x > w ) or ( y < 0 or y > h ) then
		return -- out of screen bounds
	end

	return x / w, y / h, hitPos
end

function MediaPlayer.DispatchScreenTrace( func, aimVector )
	if not isfunction(func) then return end
	if not aimVector then
		aimVector = LocalPlayer():GetAimVector()
	end

	for name, mp in pairs( MediaPlayer.List ) do
		local ent = mp.Entity
		if IsValid( mp ) and IsValid( ent ) and not ent:IsDormant() then
			local x, y = getScreenPos( ent, aimVector )
			if x and y then
				func(mp, x, y)
			end
		end
	end
end

local function mpMouseReleased( mp, x, y )
	mp:OnMousePressed(x, y)
end

local function mousePressed( mouseCode, aimVector )
	if mouseCode ~= MOUSE_LEFT then
		return
	end

	MediaPlayer.DispatchScreenTrace( mpMouseReleased, aimVector )
end
hook.Add( "GUIMouseReleased", "MediaPlayer.ScreenIntersect", mousePressed )


--[[---------------------------------------------------------
	Screen cursor

	While the context menu is held open and the mouse is over a
	screen, the page gets a cursor at that spot. The browser is kept
	under the real cursor (see DMediaPlayerHTML:MouseHoverAt), so
	left click, right click and scrolling reach the page as native
	input instead of going to the world.
-----------------------------------------------------------]]

local CURSOR_HOOK = "MediaPlayer.ScreenCursor"

-- Seconds to wait before retaking the cursor after another panel
-- (e.g. the sidebar) took it from the page.
local CURSOR_RETRY_DELAY = 0.25

local hoveredPlayer
local nextCursorTime = 0
local keyboardCursorEnabled = false
local webContextMenuOpen = false
local updateScreenCursor
local stopScreenCursor

-- Keyboard input mode keeps the screen cursor available without holding C.
function MediaPlayer.SetWebContextMenuOpen( open )
	webContextMenuOpen = open and true or false

	if webContextMenuOpen and hoveredPlayer then
		hoveredPlayer:OnMouseLeft()
		hoveredPlayer = nil
	end

	-- Re-evaluate VGUI hover after the menu closes so screen interaction can
	-- resume at the current cursor position.
	if not webContextMenuOpen then
		local cx, cy = input.GetCursorPos()
		gui.InternalCursorMoved( cx, cy )
	end
end

function MediaPlayer.SetKeyboardScreenCursor( enabled )
	keyboardCursorEnabled = enabled and true or false
	if keyboardCursorEnabled then
		hook.Add( "Think", CURSOR_HOOK, updateScreenCursor )
	else
		local menu = g_ContextMenu
		if not ( IsValid( menu ) and menu:IsVisible() and MediaPlayer.Cvars.ScreenCursor:GetBool() ) then
			stopScreenCursor()
		end
	end
end

-- A browser can be under the cursor while a Derma context menu is open.
-- Do not move the browser over the cursor in that case: doing so steals the
-- menu's mouse events, and can leave its options impossible to click.
local function isDermaMenuHovered()
	local panel = vgui.GetHoveredPanel()
	while IsValid( panel ) do
		local class = panel.GetClassName and panel:GetClassName() or ""
		if class == "DMenu" or class == "DMenuOption" then
			return true
		end
		panel = panel:GetParent()
	end

	return false
end

local function isOccluded( ent, eyePos, hitPos )
	local tr = util.TraceLine({
		start = eyePos,
		endpos = hitPos,
		filter = LocalPlayer()
	})

	return tr.Hit and tr.Entity ~= ent
end

-- Returns the closest unobstructed screen along the aim vector.
local function findScreenAt( aimVector )
	local eyePos = LocalPlayer():EyePos()
	local bestMP, bestX, bestY, bestHitPos, bestDistSqr

	for _, mp in pairs( MediaPlayer.List ) do
		local ent = mp.Entity
		if IsValid( mp ) and IsValid( ent ) and not ent:IsDormant() then
			local x, y, hitPos = getScreenPos( ent, aimVector )
			if x then
				local distSqr = hitPos:DistToSqr( eyePos )
				if not bestDistSqr or distSqr < bestDistSqr then
					bestMP, bestX, bestY, bestHitPos, bestDistSqr = mp, x, y, hitPos, distSqr
				end
			end
		end
	end

	-- The page takes over the mouse, so don't grab it through walls or props.
	if bestMP and not isOccluded( bestMP.Entity, eyePos, bestHitPos ) then
		return bestMP, bestX, bestY
	end
end

stopScreenCursor = function()
	if not keyboardCursorEnabled then hook.Remove( "Think", CURSOR_HOOK ) end
	nextCursorTime = 0

	if hoveredPlayer then
		if IsValid( hoveredPlayer ) then
			hoveredPlayer:OnMouseLeft()
		end

		hoveredPlayer = nil
	end
end

updateScreenCursor = function()
	-- The webpage's Derma context menu owns the cursor for its entire
	-- lifetime. Do not rely on GetHoveredPanel(): the browser popup can remain
	-- above the menu in VGUI's input order even when it is not visible.
	if webContextMenuOpen then
		if hoveredPlayer then
			if IsValid( hoveredPlayer ) then hoveredPlayer:OnMouseLeft() end
			hoveredPlayer = nil
		end
		return
	end

	local menu = g_ContextMenu

	-- OnContextMenuClose doesn't run while keys are being trapped, so also
	-- stop if the menu went away without it.
	if not keyboardCursorEnabled and ( not vgui.CursorVisible() or ( IsValid( menu ) and not menu:IsVisible() ) ) then
		stopScreenCursor()
		return
	end

	if hoveredPlayer and not IsValid( hoveredPlayer ) then
		hoveredPlayer = nil
	end

	-- Let Derma menus (including the webpage right-click menu) own the cursor.
	-- This applies in keyboard mode too, where the screen cursor otherwise
	-- remains active even while the pointer is over another VGUI panel.
	if isDermaMenuHovered() then
		if hoveredPlayer then
			hoveredPlayer:OnMouseLeft()
			hoveredPlayer = nil
		end
		return
	end

	-- IsWorldClicking is only true while the mouse is over the open world,
	-- so it tells us no other panel owns the cursor. Once the page has the
	-- cursor this is false by design, so only check it before then.
	if not hoveredPlayer and not keyboardCursorEnabled and
			( not LocalPlayer():IsWorldClicking() or RealTime() < nextCursorTime ) then
		return
	end

	local mp, x, y = findScreenAt( gui.ScreenToVector( gui.MousePos() ) )

	if hoveredPlayer and hoveredPlayer ~= mp then
		hoveredPlayer:OnMouseLeft()
		hoveredPlayer = nil
	end

	if not mp then return end

	if mp:OnMouseMoved( x, y ) then
		hoveredPlayer = mp
	elseif hoveredPlayer then
		-- Another panel took the cursor from the page
		hoveredPlayer = nil
		nextCursorTime = RealTime() + CURSOR_RETRY_DELAY
	end
end

-- Only run per-frame work while cursor control or keyboard mode is active.
local function startScreenCursor()
	if MediaPlayer.Cvars.ScreenCursor:GetBool() or keyboardCursorEnabled then
		hook.Add( "Think", CURSOR_HOOK, updateScreenCursor )
	end
end

hook.Add( "OnContextMenuOpen", CURSOR_HOOK, startScreenCursor )
hook.Add( "OnContextMenuClose", CURSOR_HOOK, function()
	if not keyboardCursorEnabled then stopScreenCursor() end
end )

-- The setting lives in the sidebar, which is only reachable while the context
-- menu is open, so it has to take effect without reopening the menu.
cvars.AddChangeCallback( "mediaplayer_screen_cursor", function( _, _, new )
	if not tobool( new ) then
		if not keyboardCursorEnabled then stopScreenCursor() end
		return
	end

	local menu = g_ContextMenu
	if IsValid( menu ) and menu:IsVisible() then
		startScreenCursor()
	end
end, CURSOR_HOOK )


--[[---------------------------------------------------------
	Pass mouse scrolling into media player browser
-----------------------------------------------------------]]

local mouseScroll = MediaPlayerUtils.Throttle(function( dt )
	MediaPlayer.DispatchScreenTrace(function(mp)
		mp:OnMouseWheeled(dt)
	end)
end, 0.01, { trailing = false })

hook.Add( "ContextMenuCreated", "MediaPlayer.Scroll", function( contextMenu )
	if contextMenu.OnMouseWheeled then return end
	contextMenu.OnMouseWheeled = function(panel, scrollDelta)
		mouseScroll(scrollDelta)
	end
end )

--[[---------------------------------------------------------
	Prevent weapons from firing while the context menu is
	open and the cursor is aiming at a screen.
-----------------------------------------------------------]]

local function isAimingAtScreen()
	local aimVector = LocalPlayer():GetAimVector()
	for name, mp in pairs( MediaPlayer.List ) do
		local ent = mp.Entity
		if IsValid( mp ) and IsValid( ent ) and not ent:IsDormant() then
			local x, y = getScreenPos( ent, aimVector )
			if x then
				return true
			end
		end
	end
end

local function preventWorldClicker()
	local ply = LocalPlayer()

	if not ply:IsWorldClicking() then return end

	local ent = ply:GetEyeTrace().Entity
	if not ( IsValid(ent) and ent.IsMediaPlayerEntity ) then return end

	if isAimingAtScreen() then
		return true
	end
end
hook.Add( "PreventScreenClicks", "MediaPlayer.PreventWorldClicker", preventWorldClicker )
