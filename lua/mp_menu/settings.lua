local L = MediaPlayer.L

-- ─────────────────────────────────────────────
-- Proximity radius visualization
-- ─────────────────────────────────────────────

local minColor = Color(0, 220, 0, 200)
local maxColor = Color(220, 0, 0, 200)
local playerColor       = Color(0, 0, 0, 220)
local playerTextColor   = Color(255, 255, 255, 255)
local playerTextBgColor = Color(0, 0, 0, 180)

local showProximityRadius = false

-- Localized math/render/engine functions for render hot loops
local math_pi = math.pi
local math_cos = math.cos
local math_sin = math.sin
local math_Round = math.Round
local render_SetColorMaterial = render.SetColorMaterial
local render_StartBeam = render.StartBeam
local render_AddBeam = render.AddBeam
local render_EndBeam = render.EndBeam
local Vector = Vector
local Angle = Angle
local EyeAngles = EyeAngles
local LocalPlayer = LocalPlayer
local IsValid = IsValid
local cam_Start3D2D = cam.Start3D2D
local cam_End3D2D = cam.End3D2D
local surface_SetFont = surface.SetFont
local surface_GetTextSize = surface.GetTextSize
local surface_SetDrawColor = surface.SetDrawColor
local surface_DrawRect = surface.DrawRect
local draw_SimpleText = draw.SimpleText
local TEXT_ALIGN_CENTER = TEXT_ALIGN_CENTER

local function DrawThickCircle(pos, radius, color, width, segments)
	segments = segments or 64
	width = width or 6
	local step = (2 * math_pi) / segments

	render_SetColorMaterial()
	render_StartBeam(segments + 1)
	for i = 0, segments do
		local angle = i * step
		local p = pos + Vector(math_cos(angle) * radius, math_sin(angle) * radius, 1)
		render_AddBeam(p, width, i / segments, color)
	end
	render_EndBeam()
end

local function ProximityRadiusHook(depth, skybox, skybox3d)
	if skybox or skybox3d then return end
	if not MediaPlayer.Cvars.Audio3D:GetBool() then return end

	local minDist = MediaPlayer.Cvars.ProximityMin:GetFloat()
	local maxDist = MediaPlayer.Cvars.ProximityMax:GetFloat()
	local ply = LocalPlayer()
	local plyPos = ply:GetPos()

	for _, mp in pairs(MediaPlayer.List) do
		if not IsValid(mp) then continue end
		if mp:GetType() == "mimic" then continue end
		local ent = mp.Entity
		if not IsValid(ent) then continue end
		local pos = ent:GetPos()

		if minDist > 0 then
			DrawThickCircle(pos, minDist, minColor, 6, 64)
		end
		if maxDist > 0 then
			DrawThickCircle(pos, maxDist, maxColor, 6, 64)
		end

		-- Player distance circle + text
		local distance = plyPos:Distance(pos)

		DrawThickCircle(pos, distance, playerColor, 4, 64)

		-- Direction from entity to player (flattened to XY plane)
		local dir = (plyPos - pos)
		dir.z = 0
		local len = dir:Length()
		if len > 0 then
			dir = dir / len
		else
			dir = Vector(1, 0, 0)
		end

		-- Position text INWARD from the circle edge (toward entity center)
		-- so the player sees it in front of them, not inside them
		local textPos = pos + dir * (distance - 100) + Vector(0, 0, 50)

		local billboardAng = Angle(0, EyeAngles().y - 90, 90)

		cam_Start3D2D(textPos, billboardAng, 0.25)
			local text = string.format( L("mp.settings.proximity_units"), math_Round(distance) )
			surface_SetFont("DermaLarge")
			local tw, th = surface_GetTextSize(text)
			surface_SetDrawColor(playerTextBgColor)
			surface_DrawRect(-tw / 2 - 6, -th / 2 - 4, tw + 12, th + 8)
			draw_SimpleText(text, "DermaLarge", 0, 0, playerTextColor, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
		cam_End3D2D()
	end
end

local function SetProximityRadius(enabled)
	showProximityRadius = enabled
	if enabled then
		hook.Add("PostDrawTranslucentRenderables", "MP.Settings.ProximityRadius", ProximityRadiusHook)
	else
		hook.Remove("PostDrawTranslucentRenderables", "MP.Settings.ProximityRadius")
	end
end

-- ─────────────────────────────────────────────
-- Language display names
-- ─────────────────────────────────────────────

-- local LanguageNames = {
-- 	["en"]    = "English",
-- 	["de"]    = "Deutsch",
-- 	["fr"]    = "Français",
-- 	["es-ES"] = "Español",
-- 	["it"]    = "Italiano",
-- 	["pt-BR"] = "Português (BR)",
-- 	["ru"]    = "Русский",
-- 	["uk"]    = "Українська",
-- 	["pl"]    = "Polski",
-- 	["nl"]    = "Nederlands",
-- 	["cs"]    = "Čeština",
-- 	["hu"]    = "Magyar",
-- 	["no"]    = "Norsk",
-- 	["fi"]    = "Suomi",
-- 	["tr"]    = "Türkçe",
-- 	["ja"]    = "日本語",
-- 	["ko"]    = "한국어",
-- 	["zh-CN"] = "简体中文",
-- 	["zh-TW"] = "繁體中文",
-- 	["en-PT"] = "Pirate Speak",
-- 	["tlh"]   = "Klingon (tlhIngan Hol)",
-- }

-- ─────────────────────────────────────────────
-- Subtitle languages: { code, display name }. Add or remove as needed.
-- ─────────────────────────────────────────────

local CAPTION_LANGS = {
	{ "off",   "Off" },
	{ "en",    "English" },
	{ "ko",    "한국어" },
	{ "ja",    "日本語" },
	{ "zh-CN", "简体中文" },
	{ "zh-TW", "繁體中文" },
	{ "es-ES", "Español" },
	{ "fr",    "Français" },
	{ "de",    "Deutsch" },
	{ "ru",    "Русский" },
	{ "pt-BR", "Português" },
	{ "it",    "Italiano" },
	{ "id",    "Bahasa Indonesia" },
	{ "th",    "ไทย" },
	{ "vi",    "Tiếng Việt" },
	{ "ar",    "العربية" },
}

-- ─────────────────────────────────────────────
-- Control factory functions
-- ─────────────────────────────────────────────

local function CreateSectionLabel(parent, i18nKey)
	local label = vgui.Create("DLabel", parent)
	label:SetText(L(i18nKey))
	label:SetFont("DermaDefaultBold")
	label:SetTextColor(Color(220, 220, 220))
	label:Dock(TOP)
	label:DockMargin(0, 15, 0, 5)
	label:SizeToContents()
	return label
end

local function CreateFieldLabel(parent, i18nKey)
	local label = vgui.Create("DLabel", parent)
	label:SetText(L(i18nKey))
	label:SetTextColor(Color(190, 190, 190))
	label:Dock(TOP)
	label:DockMargin(0, 8, 0, 3)
	label:SizeToContents()
	return label
end

local function CreateCheckbox(parent, i18nKey, convar)
	local cb = vgui.Create("DCheckBoxLabel", parent)
	cb:SetText(L(i18nKey))

	if convar then
		cb:SetConVar(convar)
	end

	cb:Dock(TOP)
	cb:DockMargin(0, 5, 0, 0)
	cb:SizeToContents()
	return cb
end

local function CreateSlider(parent, i18nKey, convar, min, max, decimals)
	local slider = vgui.Create("DNumSlider", parent)
	slider:SetText(L(i18nKey))
	slider:SetConVar(convar)
	slider:SetMin(min)
	slider:SetMax(max)
	slider:SetDecimals(decimals or 0)
	slider:Dock(TOP)
	slider:DockMargin(0, 5, 0, 0)
	return slider
end

-- A dropdown for choosing a track of the video that is playing. It opens inside the panel,
-- pushing the controls below it down, instead of as a popup menu: a popup opened from the
-- sidebar cannot be clicked, because while the cursor is over the sidebar it makes itself
-- the front-most popup every frame (PANEL:Think in sidebar.lua), above the menu.
local SELECT_HEIGHT = 25
local selectBar = Color(30, 30, 30)
local selectBarHover = Color(48, 48, 48)
local selectBarOff = Color(24, 24, 24)
local selectBorder = Color(78, 78, 78)
local selectOptionHover = Color(58, 58, 58)
local selectOptionActive = Color(96, 96, 96)
local selectText = Color(225, 225, 225)
local selectTextOff = Color(130, 130, 130)
local selectArrow = Color(195, 195, 195)

local function CreateTrackSelect(parent, onSelect)
	local box = vgui.Create("DPanel", parent)
	box:Dock(TOP)
	box:DockMargin(0, 0, 0, 0)
	box:SetTall(SELECT_HEIGHT)
	box:SetPaintBackground(false)

	box.enabled = false
	box.open = false
	box.loading = false
	box.onSelect = onSelect

	local bar = vgui.Create("DButton", box)
	bar:Dock(TOP)
	bar:SetTall(SELECT_HEIGHT)
	bar:SetFont("DermaDefault")
	bar:SetContentAlignment(4)
	bar:SetTextInset(8, 0)
	bar:SetText("")

	bar.Paint = function(self, w, h)
		surface.SetDrawColor(not box.enabled and selectBarOff or (self:IsHovered() and selectBarHover or selectBar))
		surface.DrawRect(0, 0, w, h)
		surface.SetDrawColor(selectBorder)
		surface.DrawOutlinedRect(0, 0, w, h)

		-- loading indicator: a ring of dots with a fading tail, left of the arrow
		if box.loading then
			local step = math.floor(SysTime() * 10)

			draw.NoTexture()
			for i = 0, 7 do
				local angle = math.rad(i * 45)
				local fade = ((i - step) % 8) / 8

				surface.SetDrawColor(selectArrow.r, selectArrow.g, selectArrow.b, 50 + 205 * fade)
				surface.DrawRect(w - 36 + math.cos(angle) * 5 - 1, h / 2 + math.sin(angle) * 5 - 1, 3, 3)
			end
		end

		-- arrow: points down when closed, up when open
		local x, y = w - 14, h / 2
		draw.NoTexture()
		surface.SetDrawColor(box.enabled and selectArrow or selectTextOff)
		if box.open then
			surface.DrawPoly({ { x = x - 4, y = y + 2 }, { x = x, y = y - 3 }, { x = x + 4, y = y + 2 } })
		else
			surface.DrawPoly({ { x = x - 4, y = y - 2 }, { x = x + 4, y = y - 2 }, { x = x, y = y + 3 } })
		end
	end

	bar.DoClick = function()
		if box.enabled then
			box:SetOpen(not box.open)
		end
	end

	local list = vgui.Create("DPanel", box)
	list:Dock(TOP)
	list:SetPaintBackground(false)
	list:SetVisible(false)

	box.bar = bar
	box.list = list

	-- Opens or closes the list; the box grows and shrinks with it.
	function box:SetOpen(open)
		self.open = (open and self.enabled and #list:GetChildren() > 0) and true or false

		list:SetVisible(self.open)
		self:SetTall(SELECT_HEIGHT + (self.open and list:GetTall() or 0))
		self:InvalidateParent(true)
	end

	-- Shows or hides the loading indicator next to the arrow.
	function box:SetLoading(loading)
		self.loading = loading and true or false
	end

	-- Nothing to choose from: shows `text` and cannot be opened.
	function box:SetStatus(text)
		list:Clear()
		list:SetTall(0)
		bar:SetText(text)
		bar:SetTextColor(selectTextOff)
		self.enabled = false
		self:SetOpen(false)
	end

	-- choices: array of { label, value, selected }; `enabled` false shows them but locks the box.
	function box:SetChoices(choices, enabled)
		list:Clear()

		local shown = choices[1] and choices[1].label or ""

		for _, choice in ipairs(choices) do
			if choice.selected then
				shown = choice.label
			end

			local option = vgui.Create("DButton", list)
			option:Dock(TOP)
			option:SetTall(SELECT_HEIGHT)
			option:SetFont("DermaDefault")
			option:SetContentAlignment(4)
			option:SetTextInset(8, 0)
			option:SetText(choice.label)
			option:SetTextColor(selectText)

			option.Paint = function(self, w, h)
				if choice.selected then
					surface.SetDrawColor(selectOptionActive)
				elseif self:IsHovered() then
					surface.SetDrawColor(selectOptionHover)
				else
					surface.SetDrawColor(selectBar)
				end

				surface.DrawRect(0, 0, w, h)
			end

			option.DoClick = function()
				box:SetOpen(false)

				if box.onSelect then
					box.onSelect(choice.value)
				end
			end
		end

		list:SetTall(#choices * SELECT_HEIGHT)
		bar:SetText(shown)

		self.enabled = enabled ~= false
		bar:SetTextColor(self.enabled and selectText or selectTextOff)

		-- stay open if it was, resized for the new list
		self:SetOpen(self.open)
	end

	return box
end

local function CreateHint(parent)
	local hint = vgui.Create("DLabel", parent)
	hint:SetTextColor(Color(150, 150, 150, 200))
	hint:SetWrap(true)
	hint:SetAutoStretchVertical(true)
	hint:Dock(TOP)
	hint:DockMargin(0, 4, 0, 0)
	hint:SetVisible(false)
	return hint
end

-- ─────────────────────────────────────────────
-- Settings tab panel
-- ─────────────────────────────────────────────

local bgcolor = Color(18, 18, 18, 255)

local PANEL = {}

function PANEL:Init()
	self:DockPadding(0, 0, 0, 0)
	self:BuildContent()

	hook.Add(MP.EVENTS.UI.MEDIA_PLAYER_CHANGED, self, self.OnMediaPlayerChanged)
	hook.Add(MediaPlayer.Subtitles.EVENT_CHANGED, self, self.OnSubtitlesChanged)
end

function PANEL:OnRemove()
	hook.Remove(MP.EVENTS.UI.MEDIA_PLAYER_CHANGED, self)
	hook.Remove(MediaPlayer.Subtitles.EVENT_CHANGED, self)
end

function PANEL:BuildContent()
	self:Clear()

	local scroll = vgui.Create("DScrollPanel", self)
	scroll:Dock(FILL)
	scroll:DockMargin(10, 10, 10, 10)

	-- Audio section
	CreateSectionLabel(scroll, "mp.settings.audio")

	local audio3DCheckbox = CreateCheckbox(scroll, "mp.settings.3d_audio", "mediaplayer_3daudio")
	CreateCheckbox(scroll, "mp.settings.mute_unfocused", "mediaplayer_mute_unfocused")

	local proxMin = CreateSlider(scroll, "mp.settings.proximity_min", "mediaplayer_proximity_min", 0, 5000, 0)
	local proxMax = CreateSlider(scroll, "mp.settings.proximity_max", "mediaplayer_proximity_max", 0, 5000, 0)

	local clampingProxy = false

	proxMin.OnValueChanged = function(_, val)
		if clampingProxy then return end
		local max = MediaPlayer.Cvars.ProximityMax:GetFloat()
		if val >= max then
			clampingProxy = true
			proxMin:SetValue(math.max(0, max - 1))
			clampingProxy = false
		end
	end

	proxMax.OnValueChanged = function(_, val)
		if clampingProxy then return end
		local min = MediaPlayer.Cvars.ProximityMin:GetFloat()
		if val <= min then
			clampingProxy = true
			proxMax:SetValue(math.min(5000, min + 1))
			clampingProxy = false
		end
	end

	local radiusToggle = CreateCheckbox(scroll, "mp.settings.show_radius", nil)
	radiusToggle:SetValue(showProximityRadius)
	radiusToggle.OnChange = function(_, checked)
		SetProximityRadius(checked)
	end

	-- Disable proximity controls when 3D audio is disabled
	local function UpdateProximityControlsEnabled()
		local enabled = MediaPlayer.Cvars.Audio3D:GetBool()
		proxMin:SetEnabled(enabled)
		proxMax:SetEnabled(enabled)
		radiusToggle:SetEnabled(enabled)
	end

	-- Add callback to 3D audio checkbox
	audio3DCheckbox.OnChange = function(_, checked)
		UpdateProximityControlsEnabled()
	end

	-- Set initial state
	UpdateProximityControlsEnabled()

	-- Subtitles: the language preference (mediaplayer_cc_lang) and the track of the video that is playing
	CreateSectionLabel(scroll, "mp.settings.subtitles")

	CreateFieldLabel(scroll, "mp.settings.subtitle_language")

	self.LanguageSelect = CreateTrackSelect(scroll, function(code)
		RunConsoleCommand("mediaplayer_cc_lang", code)
		self:RefreshLanguage(code)
	end)

	CreateFieldLabel(scroll, "mp.settings.subtitle_track")

	self.SubtitleSelect = CreateTrackSelect(scroll, function(trackNumber)
		local job = self:GetSubtitleJob()

		if job then
			MediaPlayer.Subtitles.Choose(job, trackNumber)
		end
	end)

	CreateCheckbox(scroll, "mp.settings.subtitle_styling", "mediaplayer_subtitle_styling")

	CreateSectionLabel(scroll, "mp.settings.audio_track")

	self.AudioSelect = CreateTrackSelect(scroll, function(trackNumber)
		local job = self:GetSubtitleJob()

		if job then
			MediaPlayer.Subtitles.ChooseAudio(job, trackNumber)
		end
	end)

	self.AudioHint = CreateHint(scroll)

	self:RefreshTracks()
end

-- ─────────────────────────────────────────────
-- Subtitle / audio track dropdowns
-- ─────────────────────────────────────────────

local StatusText = {
	unavailable = "mp.settings.subtitles_unavailable",
	loading     = "mp.settings.subtitles_loading",
	failed      = "mp.settings.subtitles_failed",
	none        = "mp.settings.subtitles_none",
	noaudio     = "mp.settings.audio_none",
}

function PANEL:OnMediaPlayerChanged(mp)
	self.mp = mp
	self:RefreshTracks()
end

-- Several changes can arrive together (and before the media has stored its job), so
-- redraw once on the next tick.
function PANEL:OnSubtitlesChanged()
	if self.refreshQueued then return end
	self.refreshQueued = true

	timer.Simple(0, function()
		if not IsValid(self) then return end

		self.refreshQueued = false
		self:RefreshTracks()
	end)
end

-- The subtitle job of whatever the sidebar's media player is playing, if there is one.
function PANEL:GetSubtitleJob()
	local mp = self.mp
	local media = IsValid(mp) and mp:GetMedia()
	local job = media and media._subtitles

	if job and not job.cancelled then
		return job
	end
end

-- Shows the language preference; `code` is given when it was just changed, as the
-- convar does not hold the new value yet.
function PANEL:RefreshLanguage(code)
	local current = (code or MediaPlayer.Cvars.CaptionLang:GetString() or "off"):lower()
	local choices = {}

	for _, pair in ipairs(CAPTION_LANGS) do
		choices[#choices + 1] = {
			label = pair[1] == "off" and L("mp.settings.subtitles_off") or pair[2],
			value = pair[1],
			selected = pair[1]:lower() == current,
		}
	end

	self.LanguageSelect:SetChoices(choices, true)
end

function PANEL:RefreshTracks()
	local Subtitles = MediaPlayer.Subtitles
	local job = self:GetSubtitleJob()

	self:RefreshLanguage()

	-- The track list is read on demand, so it is also available while subtitles are off.
	if job then
		job:EnsureTracks()
	end

	-- Subtitles
	local status = Subtitles.GetStatus(job)

	if status == "ready" then
		self.SubtitleSelect:SetChoices(Subtitles.GetChoices(job))
	else
		self.SubtitleSelect:SetStatus(L(StatusText[status]))
	end

	self.SubtitleSelect:SetLoading(Subtitles.IsLoading(job))

	-- Audio: the file's tracks are listed, but cannot be switched yet
	local audioChoices = job and job.state == "ready" and Subtitles.GetAudioChoices(job) or {}

	if #audioChoices > 0 then
		self.AudioSelect:SetChoices(audioChoices, Subtitles.SupportsAudioSelection)
	else
		-- "none" and "ready" describe the subtitles; for audio the file simply has no tracks
		local audioStatus = (status == "none" or status == "ready") and "noaudio" or status
		self.AudioSelect:SetStatus(L(StatusText[audioStatus]))
	end

	self.AudioHint:SetText(L("mp.settings.audio_track_soon"))
	self.AudioHint:SetVisible(#audioChoices > 0 and not Subtitles.SupportsAudioSelection)
end

function PANEL:Paint(w, h)
	surface.SetDrawColor(bgcolor)
	surface.DrawRect(0, 0, w, h)
end

derma.DefineControl("MP.SettingsTab", "", PANEL, "Panel")