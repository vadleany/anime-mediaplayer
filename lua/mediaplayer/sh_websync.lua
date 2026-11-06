--[[---------------------------------------------------------
	Webpage input sync

	While a webpage is playing on a media player, mouse movement, clicks,
	scrolling, keypresses, text input and navigation from any viewer are
	relayed through the server to every other viewer of that page.

	This file holds the event format shared by the client and the server.
	An event is a table with a `t` field naming its type:

		move   x, y            Cursor position, 0-1023 across the page
		click  x, y, b, sel    Button (0 left, 2 right) and target element
		scroll x, y            Scroll position, 0-65535 of the scrollable area
		key    d, k, c, m      Pressed state, key, code and modifier bits
		input  sel, v          Value typed into a form field
		nav    url             The page navigated somewhere else

	`sel` is a CSS selector for the target element and is only ever passed to
	querySelector on the receiving page, never run as code.
-----------------------------------------------------------]]

MediaPlayer.WebSync = MediaPlayer.WebSync or {}
local WS = MediaPlayer.WebSync

WS.NET = "MEDIAPLAYER.WebSync"

-- Largest message the server accepts from a client, in bits
WS.MAX_BITS = 8 * 4096

local TYPE_BITS = 3

local TYPE_IDS = {
	move   = 0,
	click  = 1,
	scroll = 2,
	key    = 3,
	input  = 4,
	nav    = 5,
}

local TYPE_NAMES = {}
for name, id in pairs( TYPE_IDS ) do
	TYPE_NAMES[id] = name
end

local MAX_SELECTOR = 300
local MAX_VALUE = 1024
local MAX_KEY = 32
local MAX_URL = 2048
local MAX_NAME = 32

-- Control characters other than tab, newline and carriage return
local CONTROL_CHARS = "[%z\1-\8\11\12\14-\31\127]"

local function cleanString( str, max )
	if not isstring( str ) then return nil end
	if #str > max then return nil end

	return ( string.gsub( str, CONTROL_CHARS, "" ) )
end

local function clampInt( value, max )
	value = tonumber( value )
	if not value or value ~= value then return nil end

	return math.Clamp( math.floor( value + 0.5 ), 0, max )
end

local function isWebUrl( url )
	return url:match( "^https?://[^%s]+$" ) ~= nil
end

--- Validates an event from untrusted input (the page's script) and returns a
-- clean copy, or nil if it isn't a valid event.
function WS.Sanitize( raw )
	if not istable( raw ) then return nil end

	local t = raw.t

	if t == "move" then
		local x, y = clampInt( raw.x, 1023 ), clampInt( raw.y, 1023 )
		if x and y then
			return { t = t, x = x, y = y }
		end

	elseif t == "click" then
		local x, y = clampInt( raw.x, 1023 ), clampInt( raw.y, 1023 )
		local b = clampInt( raw.b, 3 )
		local sel = cleanString( raw.sel or "", MAX_SELECTOR )
		if x and y and b and sel then
			return { t = t, x = x, y = y, b = b, sel = sel }
		end

	elseif t == "scroll" then
		local x, y = clampInt( raw.x, 65535 ), clampInt( raw.y, 65535 )
		if x and y then
			return { t = t, x = x, y = y }
		end

	elseif t == "key" then
		local k = cleanString( raw.k, MAX_KEY )
		local c = cleanString( raw.c or "", MAX_KEY )
		local m = clampInt( raw.m or 0, 15 )
		if k and c and m then
			return { t = t, d = ( raw.d == true or raw.d == 1 ), k = k, c = c, m = m }
		end

	elseif t == "input" then
		local sel = cleanString( raw.sel, MAX_SELECTOR )
		local v = cleanString( raw.v, MAX_VALUE )
		if sel and v then
			return { t = t, sel = sel, v = v }
		end

	elseif t == "nav" then
		local url = cleanString( raw.url, MAX_URL )
		if url and isWebUrl( url ) then
			return { t = t, url = url }
		end
	end

	return nil
end

--- Writes an event to the current net message.
-- @param ev  A table returned by WS.Sanitize.
-- @param who Name of the player the event came from; added when the server
--            relays an event so viewers can label the cursor.
function WS.Write( ev, who )
	net.WriteUInt( TYPE_IDS[ev.t], TYPE_BITS )

	if who ~= nil then
		net.WriteString( who )
	end

	if ev.t == "move" then
		net.WriteUInt( ev.x, 10 )
		net.WriteUInt( ev.y, 10 )

	elseif ev.t == "click" then
		net.WriteUInt( ev.x, 10 )
		net.WriteUInt( ev.y, 10 )
		net.WriteUInt( ev.b, 2 )
		net.WriteString( ev.sel )

	elseif ev.t == "scroll" then
		net.WriteUInt( ev.x, 16 )
		net.WriteUInt( ev.y, 16 )

	elseif ev.t == "key" then
		net.WriteBool( ev.d )
		net.WriteString( ev.k )
		net.WriteString( ev.c )
		net.WriteUInt( ev.m, 4 )

	elseif ev.t == "input" then
		net.WriteString( ev.sel )
		net.WriteString( ev.v )

	elseif ev.t == "nav" then
		net.WriteString( ev.url )
	end
end

--- Reads an event from the current net message and validates it.
-- @param hasWho Whether the sender's name precedes the event fields.
-- @return table|nil, string|nil Event and sender name; nil if invalid.
function WS.Read( hasWho )
	local t = TYPE_NAMES[net.ReadUInt( TYPE_BITS )]
	if not t then return nil end

	local who
	if hasWho then
		who = cleanString( net.ReadString(), MAX_NAME ) or ""
	end

	local raw = { t = t }

	if t == "move" then
		raw.x = net.ReadUInt( 10 )
		raw.y = net.ReadUInt( 10 )

	elseif t == "click" then
		raw.x = net.ReadUInt( 10 )
		raw.y = net.ReadUInt( 10 )
		raw.b = net.ReadUInt( 2 )
		raw.sel = net.ReadString()

	elseif t == "scroll" then
		raw.x = net.ReadUInt( 16 )
		raw.y = net.ReadUInt( 16 )

	elseif t == "key" then
		raw.d = net.ReadBool()
		raw.k = net.ReadString()
		raw.c = net.ReadString()
		raw.m = net.ReadUInt( 4 )

	elseif t == "input" then
		raw.sel = net.ReadString()
		raw.v = net.ReadString()

	elseif t == "nav" then
		raw.url = net.ReadString()
	end

	return WS.Sanitize( raw ), who
end

--- Whether the media is a webpage, the only kind of media that shares input.
function WS.IsWebpage( media )
	return media ~= nil and media.Id == "www"
end
