--[[---------------------------------------------------------
	Matroska (MKV) subtitle reader.

	Reads only the parts of a file it needs through ranged HTTP requests, so it
	never downloads a whole video. Subtitle lines are located through the file's
	Cues index and only the lines inside a requested time range are read.

	This file knows nothing about the media player; reads go through an injected,
	asynchronous function so the parsing can be tested without Garry's Mod.

	read( offset, length, callback )
		offset is 0-based. callback( data ) or callback( nil, err ).
		A short or empty string means end of file.

	API:
		Matroska.HTTPReader( url, callback )          callback( err, read )
		Matroska.Open( read, callback, cancelled )    callback( err, file )
		Matroska.GetSubtitleTracks( file )            list of tracks
		Matroska.GetAudioTracks( file )               list of tracks
		Matroska.IsSubtitleSupported( track )         ok, reason
		Matroska.IsAssTrack( track )                  boolean
		Matroska.ReadRange( file, trackNumber, from, to, opts, callback )
			callback( err, events, coveredTo )
			events is sorted by start: { start, stop, text, order, line }, in seconds.
			text is plain UTF-8 ("\n" between rows) and nil for lines that only draw
			shapes. line is the event as an ASS "Dialogue:" line, for ASS tracks only.
		Matroska.GetAssHeader( track )                ASS script up to the events
		Matroska.GetFonts( file, callback, cancelled )          callback( err, fonts )
		Matroska.ReadAttachment( file, attachment, sink, opts, callback )

	Everything read from the file is untrusted: sizes, counts and bytes are
	capped, and nothing from it is ever executed.
-----------------------------------------------------------]]

local Matroska = {}

local byte, sub, find, format = string.byte, string.sub, string.find, string.format
local gsub = string.gsub
local floor = math.floor
local band = bit.band
local sort = table.sort
local cocreate, coresume, costatus, coyield =
	coroutine.create, coroutine.resume, coroutine.status, coroutine.yield

local MAX_ELEMENT_BODY = 8 * 1024 * 1024 -- largest header element (Tracks, Cues) that is read
local MAX_BLOCK_BODY = 1024 * 1024
local MAX_TRACK_CUES = 100000 -- more lines than any real subtitle track has
local MAX_TEXT_BYTES = 1000 -- per line
local DEFAULT_DURATION = 5 -- seconds, used when a line carries no duration
local DEFAULT_CONCURRENCY = 8 -- parallel reads
local DEFAULT_MAX_EVENTS = 2000 -- lines per range
local DEFAULT_MAX_BYTES = 4 * 1024 * 1024 -- data read per range
local MAX_RUN_GAP = 32 * 1024 -- blocks closer than this are read with one request
local MAX_RUN_SPAN = 512 * 1024 -- upper bound for the data covered by one request
local RUN_TAIL = 2048 -- extra bytes read after the last block of a run

local MAX_LINE_BYTES = 4000 -- per ASS line
local MAX_HEADER_BYTES = 256 * 1024 -- ASS script header
local MAX_ATTACHMENTS = 64 -- attachments looked at
local MAX_FONT_BYTES = 32 * 1024 * 1024 -- per font
local MAX_FONTS_TOTAL = 128 * 1024 * 1024
local FONT_CHUNK = 4 * 1024 * 1024 -- bytes per request when reading an attachment

local TRACK_TYPE_AUDIO = 2
local TRACK_TYPE_SUBTITLE = 17

local ID = {
	EBML = 0x1A45DFA3, Segment = 0x18538067,
	SeekHead = 0x114D9B74, Seek = 0x4DBB, SeekID = 0x53AB, SeekPosition = 0x53AC,
	Info = 0x1549A966, TimestampScale = 0x2AD7B1, Duration = 0x4489,
	Tracks = 0x1654AE6B, TrackEntry = 0xAE, TrackNumber = 0xD7, TrackUID = 0x73C5,
	TrackType = 0x83, FlagEnabled = 0xB9, FlagDefault = 0x88, FlagForced = 0x55AA,
	CodecID = 0x86, CodecPrivate = 0x63A2, Language = 0x22B59C,
	LanguageBCP47 = 0x22B59D, TrackName = 0x536E,
	ContentEncodings = 0x6D80, ContentEncoding = 0x6240, ContentCompression = 0x5034,
	ContentCompAlgo = 0x4254, ContentCompSettings = 0x4255,
	Cues = 0x1C53BB6B, CuePoint = 0xBB, CueTime = 0xB3, CueTrackPositions = 0xB7,
	CueTrack = 0xF7, CueClusterPosition = 0xF1, CueRelativePosition = 0xF0,
	CueDuration = 0xB2,
	Cluster = 0x1F43B675, BlockGroup = 0xA0, Block = 0xA1,
	BlockDuration = 0x9B, SimpleBlock = 0xA3,
	Attachments = 0x1941A469, AttachedFile = 0x61A7, FileName = 0x466E,
	FileMediaType = 0x4660, FileData = 0x465C,
}

--[[---------------------------------------------------------
	Binary helpers (positions are 1-based string indexes)
-----------------------------------------------------------]]

-- Reads an EBML variable-length integer. With keepMarker the length marker bit
-- is kept (element IDs). Returns value, length, isUnknownSize.
local function ReadVint( s, p, keepMarker )
	local b = byte( s, p )
	if not b then return nil end

	local len, mask = 1, 0x80
	while len <= 8 and band( b, mask ) == 0 do
		len = len + 1
		mask = mask / 2
	end
	if len > 8 or p + len - 1 > #s then return nil end

	local low = band( b, mask - 1 )
	local v = keepMarker and b or low
	local allOnes = low == mask - 1
	for i = 1, len - 1 do
		local c = byte( s, p + i )
		v = v * 256 + c
		if c ~= 0xFF then allOnes = false end
	end

	return v, len, allOnes
end

local function ReadUInt( s, a, b )
	local v = 0
	for i = a, b do
		v = v * 256 + byte( s, i )
	end
	return v
end

local function ReadString( s, a, b )
	local str = sub( s, a, b )
	return ( str:gsub( "%z.*$", "" ) )
end

local function ReadFloat( s, a, b )
	local len = b - a + 1

	if len == 4 then
		local v = ReadUInt( s, a, b )
		local sign = v >= 2 ^ 31 and -1 or 1
		local exp = floor( v / 2 ^ 23 ) % 256
		local man = v % 2 ^ 23
		if exp == 255 then return nil end
		if exp == 0 then return sign * man * 2 ^ -149 end
		return sign * ( 1 + man / 2 ^ 23 ) * 2 ^ ( exp - 127 )
	elseif len == 8 then
		local hi, lo = ReadUInt( s, a, a + 3 ), ReadUInt( s, a + 4, b )
		local sign = hi >= 2 ^ 31 and -1 or 1
		local exp = floor( hi / 2 ^ 20 ) % 2048
		local man = ( hi % 2 ^ 20 ) * 2 ^ 32 + lo
		if exp == 2047 then return nil end
		if exp == 0 then return sign * man * 2 ^ -1074 end
		return sign * ( 1 + man / 2 ^ 52 ) * 2 ^ ( exp - 1023 )
	end
end

-- Iterates the child elements found in s[p..e]: id, bodyStart, bodyEnd
local function Children( s, p, e )
	return function()
		if p > e then return end

		local id, idLen = ReadVint( s, p, true )
		if not id then return end

		local size, szLen, unknown = ReadVint( s, p + idLen )
		if not size then return end

		local bodyStart = p + idLen + szLen
		local bodyEnd = unknown and e or bodyStart + size - 1
		if bodyEnd > e then bodyEnd = e end

		p = bodyEnd + 1
		return id, bodyStart, bodyEnd
	end
end

--[[---------------------------------------------------------
	Coroutine plumbing so the parsing code can read top to
	bottom while the reads themselves are asynchronous.
-----------------------------------------------------------]]

-- Runs fn in a coroutine. Reads yield; when fn returns, callback( nil, result )
-- is called, and if it errors, callback( message ).
local function Spawn( fn, callback )
	local co = cocreate( fn )

	local function step( ... )
		local ok, request = coresume( co, ... )
		if not ok then
			return callback( tostring( request ) )
		end
		if costatus( co ) == "suspended" then
			return request( step )
		end
		return callback( nil, request )
	end

	return step()
end

local function Fetch( ctx, offset, length )
	if ctx.cancelled and ctx.cancelled() then
		error( "cancelled", 0 )
	end

	local data, err = coyield( function( resume )
		ctx.read( offset, length, resume )
	end )

	if not data then
		error( "read failed at " .. offset .. ": " .. tostring( err ), 0 )
	end

	ctx.requests = ctx.requests + 1
	ctx.bytes = ctx.bytes + #data

	return data
end

--[[---------------------------------------------------------
	Open: container header, Info, Tracks, SeekHead
-----------------------------------------------------------]]

local function ParseSeekHead( s, a, b, segStart, map )
	for id, ba, bb in Children( s, a, b ) do
		if id == ID.Seek then
			local seekId, seekPos
			for cid, ca, cb in Children( s, ba, bb ) do
				if cid == ID.SeekID then seekId = ReadUInt( s, ca, cb )
				elseif cid == ID.SeekPosition then seekPos = ReadUInt( s, ca, cb ) end
			end
			if seekId and seekPos then
				map[seekId] = segStart + seekPos
			end
		end
	end
end

local function ParseContentEncodings( s, a, b, track )
	for id, ba, bb in Children( s, a, b ) do
		if id == ID.ContentEncoding then
			for cid, ca, cb in Children( s, ba, bb ) do
				if cid == ID.ContentCompression then
					local algo, settings = 0, ""
					for kid, ka, kb in Children( s, ca, cb ) do
						if kid == ID.ContentCompAlgo then algo = ReadUInt( s, ka, kb )
						elseif kid == ID.ContentCompSettings then settings = sub( s, ka, kb ) end
					end
					track.compression = algo -- 0 zlib, 1 bzlib, 2 lzo, 3 header stripping
					track.stripPrefix = settings
				else
					track.encrypted = true
				end
			end
		end
	end
end

local function ParseTracks( s )
	local tracks = {}

	for id, a, b in Children( s, 1, #s ) do
		if id == ID.TrackEntry then
			local t = { enabled = true, default = true, forced = false, language = "eng" }

			for cid, ca, cb in Children( s, a, b ) do
				if cid == ID.TrackNumber then t.number = ReadUInt( s, ca, cb )
				elseif cid == ID.TrackType then t.type = ReadUInt( s, ca, cb )
				elseif cid == ID.CodecID then t.codec = ReadString( s, ca, cb )
				elseif cid == ID.CodecPrivate then t.codecPrivate = sub( s, ca, cb )
				elseif cid == ID.Language then t.language = ReadString( s, ca, cb )
				elseif cid == ID.LanguageBCP47 then t.languageTag = ReadString( s, ca, cb )
				elseif cid == ID.TrackName then t.name = ReadString( s, ca, cb )
				elseif cid == ID.FlagEnabled then t.enabled = ReadUInt( s, ca, cb ) ~= 0
				elseif cid == ID.FlagDefault then t.default = ReadUInt( s, ca, cb ) ~= 0
				elseif cid == ID.FlagForced then t.forced = ReadUInt( s, ca, cb ) ~= 0
				elseif cid == ID.ContentEncodings then ParseContentEncodings( s, ca, cb, t ) end
			end

			if t.number then
				tracks[#tracks + 1] = t
			end
		end
	end

	return tracks
end

-- Reads an element header at an absolute offset. `head` is an optional string
-- already fetched from file offset 0, used to avoid a request.
local function ReadHeaderAt( ctx, head, off )
	local s, p
	if head and off + 32 <= #head then
		s, p = head, off + 1
	else
		s, p = Fetch( ctx, off, 32 ), 1
	end

	local id, idLen = ReadVint( s, p, true )
	if not id then return nil end

	local size, szLen, unknown = ReadVint( s, p + idLen )
	if not size then return nil end

	return id, idLen + szLen, size, unknown
end

local function ReadBody( ctx, head, off, hdrLen, size )
	if size > MAX_ELEMENT_BODY then
		error( "element too large (" .. size .. " bytes)", 0 )
	end

	local start = off + hdrLen
	if head and start + size <= #head then
		return sub( head, start + 1, start + size )
	end

	local data = Fetch( ctx, start, size )
	if #data < size then error( "truncated element", 0 ) end

	return data
end

function Matroska.Open( read, callback, cancelled )
	local ctx = { read = read, requests = 0, bytes = 0, cancelled = cancelled }

	Spawn( function()
		local head = Fetch( ctx, 0, 16384 )

		local id, idLen = ReadVint( head, 1, true )
		if id ~= ID.EBML then error( "not a Matroska file", 0 ) end

		local size, szLen = ReadVint( head, 1 + idLen )
		if not size then error( "damaged EBML header", 0 ) end

		local p = 1 + idLen + szLen + size
		local sid, sidLen = ReadVint( head, p, true )
		if sid ~= ID.Segment then error( "segment not found", 0 ) end

		local _, sszLen = ReadVint( head, p + sidLen )
		if not sszLen then error( "damaged segment header", 0 ) end

		local segStart = ( p - 1 ) + sidLen + sszLen

		local file = {
			ctx = ctx, segStart = segStart, timestampScale = 1000000,
			duration = nil, tracks = {}, seek = {}, cues = {},
		}

		-- Walk the top-level elements that precede the first Cluster.
		local off = segStart
		for _ = 1, 64 do
			local eid, hdrLen, esize, unknown = ReadHeaderAt( ctx, head, off )
			if not eid or eid == ID.Cluster or unknown then break end

			if eid == ID.SeekHead then
				local body = ReadBody( ctx, head, off, hdrLen, esize )
				ParseSeekHead( body, 1, #body, segStart, file.seek )
			elseif eid == ID.Info then
				local body = ReadBody( ctx, head, off, hdrLen, esize )
				local duration
				for cid, ca, cb in Children( body, 1, #body ) do
					if cid == ID.TimestampScale then file.timestampScale = ReadUInt( body, ca, cb )
					elseif cid == ID.Duration then duration = ReadFloat( body, ca, cb ) end
				end
				if duration then
					file.duration = duration * file.timestampScale / 1e9
				end
			elseif eid == ID.Tracks then
				file.tracks = ParseTracks( ReadBody( ctx, head, off, hdrLen, esize ) )
			end

			off = off + hdrLen + esize
		end

		return file
	end, callback )
end

--[[---------------------------------------------------------
	Cues: where each subtitle block of one track is stored
-----------------------------------------------------------]]

-- Returns the cue entries of one track sorted by time: { time, cluster, rel, duration }.
-- Only the requested track is kept; the video's entries make up most of the element
-- and would only waste memory.
local function LoadCues( ctx, file, trackNumber )
	if file.cues[trackNumber] then return file.cues[trackNumber] end

	local off = file.seek[ID.Cues]
	if not off then
		error( "file has no Cues index", 0 )
	end

	local id, hdrLen, size, unknown = ReadHeaderAt( ctx, nil, off )
	if id ~= ID.Cues or unknown then
		error( "Cues element not found at the position the SeekHead gave", 0 )
	end

	local body = ReadBody( ctx, nil, off, hdrLen, size )
	local list, seen = {}, {}

	for pid, pa, pb in Children( body, 1, #body ) do
		if pid == ID.CuePoint then
			local time
			local entries = {}

			for cid, ca, cb in Children( body, pa, pb ) do
				if cid == ID.CueTime then
					time = ReadUInt( body, ca, cb )
				elseif cid == ID.CueTrackPositions then
					local e = {}
					for kid, ka, kb in Children( body, ca, cb ) do
						if kid == ID.CueTrack then e.track = ReadUInt( body, ka, kb )
						elseif kid == ID.CueClusterPosition then e.cluster = ReadUInt( body, ka, kb )
						elseif kid == ID.CueRelativePosition then e.rel = ReadUInt( body, ka, kb )
						elseif kid == ID.CueDuration then e.duration = ReadUInt( body, ka, kb ) end
					end

					if e.track == trackNumber and e.cluster and e.rel then
						entries[#entries + 1] = e
					end
				end
			end

			if time then
				for _, e in ipairs( entries ) do
					-- one entry per block
					local key = e.cluster .. ":" .. e.rel
					if not seen[key] then
						seen[key] = true
						e.time = time
						list[#list + 1] = e
					end
				end
			end

			if #list > MAX_TRACK_CUES then
				error( "subtitle track has too many lines", 0 )
			end
		end
	end

	-- An empty list would look like a film without dialogue; say what is wrong instead.
	if #list == 0 then
		error( "the file's Cues do not index this subtitle track", 0 )
	end

	sort( list, function( a, b ) return a.time < b.time end )

	file.cues[trackNumber] = list
	return list
end

-- First index whose time is at or after `units` (the file's own time unit).
local function LowerBound( list, units )
	local lo, hi = 1, #list + 1
	while lo < hi do
		local mid = floor( ( lo + hi ) / 2 )
		if list[mid].time < units then lo = mid + 1 else hi = mid end
	end
	return lo
end

--[[---------------------------------------------------------
	Reading subtitle blocks
-----------------------------------------------------------]]

-- Parses the block element starting at buf[p]. Returns the block, or nil and a
-- reason. When the buffer ends inside the element the reason is "truncated" and a
-- third value gives how many bytes are needed from p.
local function ParseBlock( buf, p, trackNumber, cue )
	local id, idLen = ReadVint( buf, p, true )
	if id ~= ID.BlockGroup and id ~= ID.SimpleBlock then
		return nil, "not a block element"
	end

	local size, szLen, unknown = ReadVint( buf, p + idLen )
	if not size or unknown or size > MAX_BLOCK_BODY then
		return nil, "bad block size"
	end

	local hdr = idLen + szLen
	if p + hdr + size - 1 > #buf then
		return nil, "truncated", hdr + size
	end

	local bs, be = p + hdr, p + hdr + size - 1
	local blockA, blockB, duration

	if id == ID.BlockGroup then
		for cid, ca, cb in Children( buf, bs, be ) do
			if cid == ID.Block then blockA, blockB = ca, cb
			elseif cid == ID.BlockDuration then duration = ReadUInt( buf, ca, cb ) end
		end
	else
		blockA, blockB = bs, be
	end
	if not blockA then return nil, "no block in group" end

	local tn, tl = ReadVint( buf, blockA )
	if tn ~= trackNumber then return nil, "block belongs to another track" end

	local flags = byte( buf, blockA + tl + 2 )
	if not flags then return nil, "damaged block" end
	if band( flags, 0x06 ) ~= 0 then return nil, "laced block" end

	return {
		time = cue.time,
		duration = duration or cue.duration,
		data = sub( buf, blockA + tl + 3, blockB ),
	}
end

local function ReadBlockAt( ctx, off, trackNumber, cue )
	local buf = Fetch( ctx, off, 1024 )
	local block, reason, needed = ParseBlock( buf, 1, trackNumber, cue )

	if reason == "truncated" then
		buf = Fetch( ctx, off, needed )
		block, reason = ParseBlock( buf, 1, trackNumber, cue )
	end

	return block, reason
end

local function ClusterHeaderLength( ctx, file, cluster )
	local head = Fetch( ctx, file.segStart + cluster, 16 )
	local id, idLen = ReadVint( head, 1, true )
	local size, szLen = ReadVint( head, 1 + ( idLen or 0 ) )

	if id ~= ID.Cluster or not size then
		error( "cue does not point at a cluster", 0 )
	end

	return idLen + szLen
end

-- Reads one block through the Cluster header, which is measured rather than assumed.
local function ReadSubtitleBlock( ctx, file, cue, clusterData, trackNumber )
	local cstart = clusterData[cue.cluster]

	if not cstart then
		cstart = file.segStart + cue.cluster + ClusterHeaderLength( ctx, file, cue.cluster )
		clusterData[cue.cluster] = cstart
	end

	local block, reason = ReadBlockAt( ctx, cstart + cue.rel, trackNumber, cue )
	if not block then
		if reason == "laced block" then return nil end
		error( reason, 0 )
	end

	return block
end

-- Reads all cues of a run with a single request. Cues that do not parse where the
-- Cluster header length put them are returned for individual, verified reads.
local function ReadRun( ctx, run, trackNumber )
	local buf = Fetch( ctx, run.start, run.cues[#run.cues].abs - run.start + RUN_TAIL )
	local blocks, retry = {}, {}

	for _, cue in ipairs( run.cues ) do
		local block, reason = ParseBlock( buf, cue.abs - run.start + 1, trackNumber, cue )

		if block then
			blocks[#blocks + 1] = block
		elseif reason ~= "laced block" then
			retry[#retry + 1] = cue
		end
	end

	return { blocks = blocks, retry = retry }
end

-- Groups cues that lie close together in the file into runs.
local function PlanRuns( file, queue )
	local hdrLen = file.clusterHdrLen

	for _, cue in ipairs( queue ) do
		cue.abs = file.segStart + cue.cluster + hdrLen + cue.rel
	end

	sort( queue, function( a, b ) return a.abs < b.abs end )

	local runs, run = {}, nil

	for _, cue in ipairs( queue ) do
		if run and cue.abs - run.last <= MAX_RUN_GAP and cue.abs - run.start < MAX_RUN_SPAN then
			run.cues[#run.cues + 1] = cue
			run.last = cue.abs
		else
			run = { start = cue.abs, last = cue.abs, cues = { cue } }
			runs[#runs + 1] = run
		end
	end

	return runs
end

--[[---------------------------------------------------------
	Turning a block into plain text
-----------------------------------------------------------]]

local function IsAssTrack( track )
	return track.codec == "S_TEXT/ASS" or track.codec == "S_TEXT/SSA"
end

-- Matroska stores ASS as "ReadOrder,Layer,Style,Name,MarginL,MarginR,MarginV,Effect,Text"
-- with the start and end time removed. Text may itself contain commas.
local function SplitAssBlock( data )
	local pos, readOrder, middleStart = 1, nil, nil

	for i = 1, 8 do
		local comma = find( data, ",", pos, true )
		if not comma then return nil end

		if i == 1 then
			readOrder = sub( data, 1, comma - 1 )
			middleStart = comma + 1
		end

		pos = comma + 1
	end

	-- readOrder, "Layer,Style,Name,MarginL,MarginR,MarginV,Effect", Text
	return tonumber( readOrder ) or 0, sub( data, middleStart, pos - 2 ), sub( data, pos )
end

local function AssTime( seconds )
	local cs = floor( seconds * 100 + 0.5 )

	return format( "%d:%02d:%02d.%02d", floor( cs / 360000 ), floor( cs / 6000 ) % 60, floor( cs / 100 ) % 60, cs % 100 )
end

-- The block rebuilt as a "Dialogue:" line of an ASS script (Matroska drops the times).
local function AssDialogue( start, stop, middle, text )
	local layer, rest = middle:match( "^([^,]*),(.*)$" )
	if not layer then return nil end

	text = gsub( text, "[\r\n]+", "\\N" ) -- a raw line break would split the line
	if #text > MAX_LINE_BYTES then return nil end

	return format( "Dialogue: %d,%s,%s,%s,%s", tonumber( layer ) or 0, AssTime( start ), AssTime( stop ), rest, text )
end

local function AssToText( text )
	-- vector drawings ({\p1}m 0 0 l ...) are shapes, not words
	if find( text, "{[^}]*\\p[1-9]" ) then return nil end

	text = gsub( text, "{[^}]*}", "" ) -- override tags
	text = gsub( text, "\\[Nn]", "\n" )
	text = gsub( text, "\\h", " " )

	return text
end

local function SrtToText( text )
	text = gsub( text, "{[^}]*}", "" ) -- SSA-style overrides sometimes appear in SRT
	text = gsub( text, "<[^>]*>", "" )

	return text
end

local function CleanText( text )
	text = gsub( text, "\t", " " )
	text = gsub( text, "[%z\1-\8\11-\31\127]", "" ) -- control characters; "\n" is kept
	text = text:match( "^%s*(.-)%s*$" )

	if #text > MAX_TEXT_BYTES then
		text = sub( text, 1, MAX_TEXT_BYTES )
	end

	if text == "" then return nil end
	return text
end

-- Returns { start, stop, text, order, line } (seconds), or nil if the block holds nothing usable.
local function BuildEvent( track, block, toSec )
	local data = block.data
	if track.stripPrefix and track.compression == 3 then
		data = track.stripPrefix .. data
	end

	local start = block.time * toSec
	local stop = start + ( block.duration and block.duration * toSec or DEFAULT_DURATION )
	if stop <= start then stop = start + DEFAULT_DURATION end

	local text, order, line

	if IsAssTrack( track ) then
		local middle, body
		order, middle, body = SplitAssBlock( data )
		if not body then return nil end

		line = AssDialogue( start, stop, middle, body )
		text = AssToText( body )
	else
		-- plain text tracks have no ReadOrder; time order is the script order
		order = floor( start * 1000 )
		text = SrtToText( data )
	end

	text = text and CleanText( text )
	if not text and not line then return nil end

	return { start = start, stop = stop, text = text, order = order, line = line }
end

--[[---------------------------------------------------------
	Public API
-----------------------------------------------------------]]

local SUPPORTED_CODECS = {
	["S_TEXT/ASS"] = true, ["S_TEXT/SSA"] = true, ["S_TEXT/UTF8"] = true,
}

Matroska.IsAssTrack = IsAssTrack

function Matroska.GetAudioTracks( file )
	local list = {}
	for _, t in ipairs( file.tracks ) do
		if t.type == TRACK_TYPE_AUDIO then
			list[#list + 1] = t
		end
	end
	return list
end

function Matroska.GetSubtitleTracks( file )
	local list = {}
	for _, t in ipairs( file.tracks ) do
		if t.type == TRACK_TYPE_SUBTITLE then
			list[#list + 1] = t
		end
	end
	return list
end

function Matroska.IsSubtitleSupported( track )
	if track.type ~= TRACK_TYPE_SUBTITLE then
		return false, "not a subtitle track"
	end

	if not SUPPORTED_CODECS[track.codec] then
		return false, "unsupported subtitle codec " .. tostring( track.codec )
	end

	if track.encrypted or ( track.compression and track.compression ~= 3 ) then
		return false, "subtitle track is compressed or encrypted (algorithm " ..
			tostring( track.compression ) .. ")"
	end

	return true
end

local function TaskTime( task )
	if task.cue then return task.cue.time end

	local first = task.cues[1].time
	for _, cue in ipairs( task.cues ) do
		if cue.time < first then first = cue.time end
	end
	return first
end

local function ByStart( a, b )
	if a.start ~= b.start then return a.start < b.start end
	return a.order < b.order
end

---
-- Reads the lines of one subtitle track that start between `from` and `to` (seconds).
--
-- opts.cancelled()     return true to stop; no further reads are started
-- opts.maxEvents       lines read at most (default DEFAULT_MAX_EVENTS)
-- opts.maxBytes        data read at most (default DEFAULT_MAX_BYTES)
-- opts.concurrency     parallel reads (default DEFAULT_CONCURRENCY)
--
-- callback( err, events, coveredTo ). coveredTo is `to`, or earlier when a limit
-- cut the range short; lines after it were not read.
--
function Matroska.ReadRange( file, trackNumber, from, to, opts, callback )
	opts = opts or {}

	local track
	for _, t in ipairs( file.tracks ) do
		if t.number == trackNumber and t.type == TRACK_TYPE_SUBTITLE then track = t end
	end
	if not track then return callback( "no such subtitle track" ) end

	local supported, reason = Matroska.IsSubtitleSupported( track )
	if not supported then return callback( reason ) end

	-- This call's view of the file's context: it counts into the same totals but carries
	-- this call's own cancellation check.
	local ctx = setmetatable( { cancelled = opts.cancelled }, { __index = file.ctx, __newindex = file.ctx } )
	local startBytes = ctx.bytes
	local toSec = file.timestampScale / 1e9
	local maxEvents = opts.maxEvents or DEFAULT_MAX_EVENTS
	local maxBytes = opts.maxBytes or DEFAULT_MAX_BYTES
	local workers = opts.concurrency or DEFAULT_CONCURRENCY
	local coveredTo = to

	local function cancelled()
		return opts.cancelled and opts.cancelled()
	end

	Spawn( function()
		local cues = LoadCues( ctx, file, trackNumber )

		local queue = {}
		for i = LowerBound( cues, from / toSec ), #cues do
			local cue = cues[i]
			if cue.time * toSec > to then break end

			if #queue >= maxEvents then
				coveredTo = cue.time * toSec
				break
			end

			queue[#queue + 1] = cue
		end

		if #queue == 0 then return {} end

		if not file.clusterHdrLen then
			file.clusterHdrLen = ClusterHeaderLength( ctx, file, queue[1].cluster )
		end

		return PlanRuns( file, queue )
	end, function( err, tasks )
		if err then return callback( err ) end

		local events, failed = {}, 0
		local nextTask, active = 1, 0
		local clusterData = {}
		local finished, stopped = false, false

		local function finish()
			if finished then return end
			finished = true

			if cancelled() then
				return callback( "cancelled" )
			end

			if failed > 0 and #events == 0 then
				return callback( "could not read subtitle data" )
			end

			sort( events, ByStart )

			-- exact repeats only; the same text on another layer is a different line
			local out, seen = {}, {}
			for _, event in ipairs( events ) do
				local key = event.line or ( event.start .. "|" .. event.stop .. "|" .. event.text )
				if not seen[key] then
					seen[key] = true
					out[#out + 1] = event
				end
			end

			callback( nil, out, coveredTo )
		end

		local Pump

		-- pcall() cannot wrap a coroutine.yield() in Lua 5.1 / LuaJIT, so every task is
		-- read in its own coroutine and finished tasks start the next one.
		local function Launch( task )
			active = active + 1

			Spawn( function()
				if task.cues then
					return ReadRun( ctx, task, trackNumber )
				end

				local block = ReadSubtitleBlock( ctx, file, task.cue, clusterData, trackNumber )
				return { blocks = { block }, retry = {} }
			end, function( taskErr, result )
				active = active - 1

				if taskErr then
					failed = failed + 1
				else
					for _, block in ipairs( result.blocks ) do
						local event = BuildEvent( track, block, toSec )
						if event then events[#events + 1] = event end
					end

					-- cues that did not parse in place are read again, one by one
					for _, cue in ipairs( result.retry ) do
						tasks[#tasks + 1] = { cue = cue }
					end
				end

				return Pump()
			end )
		end

		-- Starts reads until every slot is busy or nothing is left.
		function Pump()
			while not stopped and active < workers and nextTask <= #tasks do
				if cancelled() then
					stopped = true
					break
				end

				if ctx.bytes - startBytes > maxBytes then
					-- lines of the reads that were not started are missing; report the range as shorter
					stopped = true
					for i = nextTask, #tasks do
						local time = TaskTime( tasks[i] ) * toSec
						if time < coveredTo then coveredTo = time end
					end
					break
				end

				local task = tasks[nextTask]
				nextTask = nextTask + 1
				Launch( task )
			end

			if active == 0 and ( stopped or nextTask > #tasks ) then
				finish()
			end
		end

		Pump()
	end )
end

--[[---------------------------------------------------------
	ASS script header and embedded fonts
-----------------------------------------------------------]]

local ASS_EVENT_FORMAT = "Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text"

---
-- The ASS script of a track up to its events (script info, styles), from the track's
-- CodecPrivate. Append "Dialogue:" lines to get a complete script. Returns nil when
-- the header is missing or too large.
--
function Matroska.GetAssHeader( track )
	local header = track.codecPrivate
	if not header or header == "" or #header > MAX_HEADER_BYTES then return nil end

	header = gsub( header, "^\239\187\191", "" ) -- byte order mark
	header = gsub( header, "\r\n?", "\n" )
	header = gsub( header, "%s+$", "" )

	local events = find( header, "[Events]", 1, true )
	if not events then
		header = header .. "\n\n[Events]"
		events = find( header, "[Events]", 1, true )
	end

	if not find( header, "Format:", events, true ) then
		header = header .. "\n" .. ASS_EVENT_FORMAT
	end

	return header .. "\n"
end

local FONT_EXTENSIONS = { ttf = true, otf = true, ttc = true, otc = true, woff = true, woff2 = true }

local function IsFontFile( name, mime )
	local ext = name and name:match( "%.(%w+)$" )
	if ext and FONT_EXTENSIONS[ext:lower()] then return true end

	mime = mime and mime:lower() or ""
	return find( mime, "font", 1, true ) ~= nil or find( mime, "truetype", 1, true ) ~= nil
		or find( mime, "opentype", 1, true ) ~= nil
end

---
-- Lists the font attachments of the file: { name, mime, offset, size } (offset is where
-- the font's bytes start in the file). Only the small header of each attachment is read,
-- never the fonts themselves.
--
-- callback( err, fonts )
--
function Matroska.GetFonts( file, callback, cancelled )
	local ctx = setmetatable( { cancelled = cancelled }, { __index = file.ctx, __newindex = file.ctx } )

	Spawn( function()
		local fonts = {}

		local off = file.seek[ID.Attachments]
		if not off then return fonts end

		local id, hdrLen, size, unknown = ReadHeaderAt( ctx, nil, off )
		if id ~= ID.Attachments or unknown then
			error( "Attachments element not found at the position the SeekHead gave", 0 )
		end

		local pos, last, total = off + hdrLen, off + hdrLen + size, 0

		for _ = 1, MAX_ATTACHMENTS do
			if pos >= last then break end

			local buf = Fetch( ctx, pos, 2048 )

			local fid, fidLen = ReadVint( buf, 1, true )
			if not fid then break end

			local fsize, fszLen = ReadVint( buf, 1 + fidLen )
			if not fsize then break end

			local bodyStart = fidLen + fszLen -- 0-based, within buf and relative to pos

			if fid == ID.AttachedFile then
				local name, mime, dataOffset, dataSize
				local p, limit = bodyStart + 1, math.min( #buf, bodyStart + fsize )

				while p <= limit do
					local cid, cidLen = ReadVint( buf, p, true )
					if not cid then break end

					local csize, cszLen = ReadVint( buf, p + cidLen )
					if not csize then break end

					local cbody = p + cidLen + cszLen

					if cid == ID.FileData then
						dataOffset, dataSize = pos + cbody - 1, csize
						break
					end

					if cbody + csize - 1 > #buf then break end

					if cid == ID.FileName then name = sub( buf, cbody, cbody + csize - 1 )
					elseif cid == ID.FileMediaType then mime = sub( buf, cbody, cbody + csize - 1 ) end

					p = cbody + csize
				end

				if dataOffset and dataSize > 0 and dataSize <= MAX_FONT_BYTES
					and total + dataSize <= MAX_FONTS_TOTAL and IsFontFile( name, mime ) then
					total = total + dataSize
					fonts[#fonts + 1] = { name = name, mime = mime, offset = dataOffset, size = dataSize }
				end
			end

			pos = pos + bodyStart + fsize
		end

		return fonts
	end, callback )
end

---
-- Reads an attachment in chunks, handing each to sink( data ) in order, so a large
-- font never has to be held in memory whole.
--
-- callback( err )
--
function Matroska.ReadAttachment( file, attachment, sink, opts, callback )
	local ctx = setmetatable( { cancelled = opts and opts.cancelled }, { __index = file.ctx, __newindex = file.ctx } )

	Spawn( function()
		local done = 0

		while done < attachment.size do
			local length = math.min( FONT_CHUNK, attachment.size - done )
			local data = Fetch( ctx, attachment.offset + done, length )

			if #data ~= length then error( "attachment is truncated", 0 ) end

			sink( data )
			done = done + length
		end

		return true
	end, function( err ) callback( err ) end )
end

--[[---------------------------------------------------------
	GMod adapter: ranged reads over HTTP()
-----------------------------------------------------------]]

local function HeaderValue( headers, name )
	if type( headers ) ~= "table" then return nil end

	for key, value in pairs( headers ) do
		if type( key ) == "string" and key:lower() == name then
			return tostring( value )
		end
	end
end

---
-- Checks that the server honours Range requests and, if so, calls back with a
-- read function for the url. Without that check a server that ignores Range
-- would answer the first read with the entire video; HTTP() only returns once
-- the whole body has been downloaded, so the answer could not be refused in time.
--
-- callback( err, read )
--
function Matroska.HTTPReader( url, callback )
	if type( url ) ~= "string" or not url:match( "^https?://" ) then
		return callback( "not an http(s) url" )
	end

	local function read( offset, length, done )
		local sent = HTTP( {
			url = url,
			method = "GET",
			headers = { Range = format( "bytes=%d-%d", offset, offset + length - 1 ) },
			success = function( code, body )
				if code == 206 then
					done( body )
				elseif code == 416 then
					done( "" ) -- offset is past the end of the file
				else
					done( nil, "HTTP " .. tostring( code ) )
				end
			end,
			failed = function( reason ) done( nil, tostring( reason ) ) end,
		} )

		if not sent then done( nil, "request could not be sent" ) end
	end

	local sent = HTTP( {
		url = url,
		method = "HEAD",
		success = function( code, _, headers )
			local ranges = HeaderValue( headers, "accept-ranges" )

			if code ~= 200 then
				return callback( "HTTP " .. tostring( code ) )
			end

			if not ( ranges and ranges:lower():find( "bytes", 1, true ) ) then
				return callback( "server does not support range requests" )
			end

			callback( nil, read )
		end,
		failed = function( reason ) callback( tostring( reason ) ) end,
	} )

	if not sent then callback( "request could not be sent" ) end
end

return Matroska
