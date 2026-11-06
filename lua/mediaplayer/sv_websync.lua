--[[---------------------------------------------------------
	Webpage input sync: server relay

	Receives input events from a viewer of a webpage and forwards them to
	every other viewer of the same media player. Any listener can send;
	there is no single controller.
-----------------------------------------------------------]]

local WS = MediaPlayer.WebSync

util.AddNetworkString( WS.NET )

-- Per-player token bucket so one client can't flood the net channel
local EVENTS_PER_SECOND = 60
local BURST = 90

local buckets = setmetatable( {}, { __mode = "k" } )

local function takeToken( ply )
	local now = RealTime()
	local bucket = buckets[ply]

	if not bucket then
		bucket = { tokens = BURST, last = now }
		buckets[ply] = bucket
	end

	bucket.tokens = math.min( BURST, bucket.tokens + ( now - bucket.last ) * EVENTS_PER_SECOND )
	bucket.last = now

	if bucket.tokens < 1 then
		return false
	end

	bucket.tokens = bucket.tokens - 1
	return true
end

net.Receive( WS.NET, function( len, ply )
	if not IsValid( ply ) then return end
	if len > WS.MAX_BITS then return end
	if not MediaPlayer.Cvars.AllowWebpages:GetBool() then return end
	if not takeToken( ply ) then return end

	local mp = MediaPlayer.GetById( net.ReadString() )
	if not IsValid( mp ) or not mp:HasListener( ply ) then return end

	if not WS.IsWebpage( mp:GetMedia() ) then return end

	local ev = WS.Read( false )
	if not ev then return end

	local receivers = {}
	for _, listener in ipairs( mp:GetListeners() ) do
		if listener ~= ply and IsValid( listener ) then
			receivers[#receivers + 1] = listener
		end
	end

	if #receivers == 0 then return end

	if MediaPlayer.DEBUG and ev.t ~= "move" then
		print( "MEDIAPLAYER.WebSync:", mp:GetId(), ply, ev.t )
	end

	net.Start( WS.NET )
		net.WriteString( mp:GetId() )
		WS.Write( ev, ply:Nick():sub( 1, 32 ) )
	net.Send( receivers )
end )
