--[[---------------------------------------------------------
	Subtitles for videos that carry their own tracks (MKV).

	A job belongs to one media (media._subtitles). It reads the track list of the file
	on demand, picks a subtitle track from the viewer's language preference
	(mediaplayer_cc_lang) or from the track dropdown of the settings menu, and keeps the
	lines around the playback position available to the player page:

	- Only a small window of lines is read at a time, through ranged requests (see
	  subtitles/matroska.lua), and written to the data folder as txt files.
	- With styling on, ASS tracks are also written as an ASS script and the fonts the file
	  carries are downloaded, so the page can draw them the way the file intends. Plain
	  text is shown until that is ready.

	The page script talks to Lua through two functions without trust in either direction:
	the page calls gmod.subtitlesReady() and gmod.subtitlesLog( text ); Lua only ever
	calls MPSubs.load / font / clear with names it generated itself.
-----------------------------------------------------------]]

local Matroska = include( "mediaplayer/subtitles/matroska.lua" )

local Subtitles = MediaPlayer.Subtitles or {}
MediaPlayer.Subtitles = Subtitles

Subtitles.EVENT_CHANGED = "mp.events.subtitlesChanged"
Subtitles.SupportsAudioSelection = false -- the page cannot switch audio tracks yet

-- jobs that are running, so changes of the settings reach them
Subtitles.jobs = Subtitles.jobs or setmetatable( {}, { __mode = "k" } )

local SUBTITLE_DIR = "mediaplayer/subtitles"
local ASSET_URL = "asset://garrysmod/data/" .. SUBTITLE_DIR .. "/"
local JASSUB_URL = "https://cdn.jsdelivr.net/npm/jassub@1.8.8/dist/"

-- Seconds of subtitles read around the playback position. The first window after
-- starting or seeking is small so that text shows quickly; larger ones follow.
local WINDOW_BEHIND = 10
local COVER_AHEAD = 30
local EXTEND_AHEAD = 120
local REFILL_AHEAD = 20 -- read the next window when less than this is left
local MIN_WINDOW_INTERVAL = 3 -- seconds between windows, whatever the file contains

local MAX_RETRIES = 3
local RETRY_DELAY = 10 -- seconds
local STALE_FILE_AGE = 24 * 60 * 60
local FONT_CONCURRENCY = 2

local subtitleJobs = 0
local staleFilesPurged = false

function Subtitles.Log( ... )
	if MediaPlayer.DEBUG then
		print( "[MediaPlayer Subtitles]", ... )
	end
end

local Log = Subtitles.Log

local function Changed()
	hook.Run( Subtitles.EVENT_CHANGED )
end

local function StylingEnabled()
	local cvar = MediaPlayer.Cvars.SubtitleStyling
	return not cvar or cvar:GetBool()
end

-- The viewer's preferred language ("ko", "zh-tw", ...), or nil when subtitles are off.
local function WantedLanguage()
	local cvar = MediaPlayer.Cvars.CaptionLang
	if not cvar then return nil end

	local lang = cvar:GetString():gsub( "[^%a%-]", "" ):lower()
	if lang == "" or lang == "off" then return nil end

	return lang
end

--[[---------------------------------------------------------
	Track naming and choosing
-----------------------------------------------------------]]

-- ISO 639-2 codes (what MKV files use) of the languages in the language setting
local LanguageCodes = {
	eng = "en", kor = "ko", jpn = "ja", chi = "zh", zho = "zh", spa = "es",
	fre = "fr", fra = "fr", ger = "de", deu = "de", rus = "ru", por = "pt",
	ita = "it", ind = "id", tha = "th", vie = "vi", ara = "ar",
}

local LanguageNames = {
	en = "English", ko = "한국어", ja = "日本語", zh = "中文", es = "Español", fr = "Français",
	de = "Deutsch", ru = "Русский", pt = "Português", it = "Italiano", id = "Bahasa Indonesia",
	th = "ไทย", vi = "Tiếng Việt", ar = "العربية",
}

local CodecNames = {
	["S_TEXT/ASS"] = "ASS", ["S_TEXT/SSA"] = "SSA", ["S_TEXT/UTF8"] = "SRT",
	["A_AAC"] = "AAC", ["A_AC3"] = "AC3", ["A_EAC3"] = "E-AC3", ["A_DTS"] = "DTS",
	["A_OPUS"] = "Opus", ["A_VORBIS"] = "Vorbis", ["A_FLAC"] = "FLAC", ["A_MPEG/L3"] = "MP3",
}

local function TrackLanguage( track )
	if track.languageTag then
		local primary = track.languageTag:lower():match( "^(%a+)" )
		if primary then return LanguageCodes[primary] or primary end
	end

	return LanguageCodes[( track.language or "" ):lower()]
end

-- Files label Chinese subtitles as Simplified or Traditional in the track name or tag.
local function ChineseScript( track )
	local text = ( ( track.languageTag or "" ) .. " " .. ( track.name or "" ) ):lower()

	for _, hint in ipairs( { "hant", "tradit", "cht", "-tw", "-hk", "繁" } ) do
		if text:find( hint, 1, true ) then return "zh-tw" end
	end

	for _, hint in ipairs( { "hans", "simpl", "chs", "-cn", "简" } ) do
		if text:find( hint, 1, true ) then return "zh-cn" end
	end
end

-- Picks the track that best fits the wanted language, or nil when there is none.
local function ChooseTrack( tracks, wanted )
	local language = wanted:match( "^(%a+)" )
	local best, bestScore

	for _, track in ipairs( tracks ) do
		if TrackLanguage( track ) == language then
			local score = 1

			if not track.forced then score = score + 4 end -- forced tracks only hold signs and foreign speech
			if track.default then score = score + 1 end
			if language == "zh" and ChineseScript( track ) == wanted then score = score + 2 end

			if not bestScore or score > bestScore then
				best, bestScore = track, score
			end
		end
	end

	return best
end

local function TrackLabel( track, index )
	local lang = TrackLanguage( track )
	local base = track.name

	if not base or base == "" then
		base = lang and ( LanguageNames[lang] or lang:upper() ) or ( "Track " .. index )
	end

	local codec = CodecNames[track.codec] or ( track.codec or "" ):gsub( "^%a_", "" )
	local label = codec ~= "" and ( base .. " (" .. codec .. ")" ) or base

	if track.forced then
		label = label .. " [forced]"
	end

	return label
end

--[[---------------------------------------------------------
	Data folder
-----------------------------------------------------------]]

local function PlainPath( key ) return SUBTITLE_DIR .. "/s" .. key .. ".txt" end
local function AssPath( key ) return SUBTITLE_DIR .. "/a" .. key .. ".txt" end
local function FontPath( key ) return SUBTITLE_DIR .. "/f" .. key .. ".dat" end

local function PrepareDirectory()
	if not file.IsDir( "mediaplayer", "DATA" ) then file.CreateDir( "mediaplayer" ) end
	if not file.IsDir( SUBTITLE_DIR, "DATA" ) then file.CreateDir( SUBTITLE_DIR ) end

	-- Files of sessions that could not clean up (crash, disconnect)
	if staleFilesPurged then return end
	staleFilesPurged = true

	for _, pattern in ipairs( { "*.txt", "*.dat" } ) do
		for _, name in ipairs( ( file.Find( SUBTITLE_DIR .. "/" .. pattern, "DATA" ) ) ) do
			local path = SUBTITLE_DIR .. "/" .. name

			if os.time() - file.Time( path, "DATA" ) > STALE_FILE_AGE then
				file.Delete( path )
			end
		end
	end
end

-- file.Write only returns a success value in recent builds
local function WriteChecked( path, content )
	file.Write( path, content )
	return file.Exists( path, "DATA" )
end

-- One line per subtitle: start ms, end ms, text; tab separated, with "\" and line
-- breaks in the text escaped. The first line lets the page recognise the format.
local function SerializePlain( events )
	local out, seen = { "MPSUB1" }, {}

	for _, event in ipairs( events ) do
		local text = event.text

		if text then
			-- layered scripts repeat a line once per layer
			local key = event.start .. "|" .. event.stop .. "|" .. text

			if not seen[key] then
				seen[key] = true

				text = text:gsub( "\\", "\\\\" ):gsub( "\n", "\\n" )

				out[#out + 1] = ( "%d\t%d\t%s" ):format(
					math.floor( event.start * 1000 + 0.5 ),
					math.floor( event.stop * 1000 + 0.5 ),
					text )
			end
		end
	end

	return table.concat( out, "\n" ) .. "\n"
end

local function SerializeAss( header, events )
	local out = { header }

	for _, event in ipairs( events ) do
		if event.line then
			out[#out + 1] = event.line .. "\n"
		end
	end

	return table.concat( out )
end

--[[---------------------------------------------------------
	Player page script

	Runs inside the player page. The text is only ever handed to VTTCue (never
	innerHTML), file names are checked again here, and the renderer library is
	loaded from a pinned version.
-----------------------------------------------------------]]

Subtitles.PageScript = ( [=[
	<script>
		(function() {
			var DIR = '%s';
			var LIB = '%s';
			var MAX_CUES = 5000;
			var video = document.getElementById('player');
			var track = null;
			var latest = 0;
			var fonts = [];
			var ass = null;
			var renderer = null;
			var rendererState = 'idle';
			var styled = false;
			var fontsAtStart = 0;

			// The functions the game gives the page can arrive a moment after the page's
			// scripts first run, so messages wait for them and the page asks again until
			// they are there.
			var logQueue = [];

			function flushLog() {
				if (typeof gmod === 'undefined' || !gmod.subtitlesLog) return;
				while (logQueue.length) gmod.subtitlesLog(logQueue.shift());
			}

			function log(message) {
				if (logQueue.length < 20) logQueue.push(String(message).slice(0, 200));
				flushLog();
			}

			function announce(attemptsLeft) {
				if (typeof gmod !== 'undefined' && gmod.subtitlesReady) {
					gmod.subtitlesReady();
					flushLog();
				} else if (attemptsLeft > 0) {
					setTimeout(function() { announce(attemptsLeft - 1); }, 100);
				}
			}

			function get(url, type, done) {
				var x = new XMLHttpRequest();
				x.open('GET', url);
				if (type !== 'text') x.responseType = type;
				x.onload = function() { done(null, type === 'text' ? x.responseText : x.response); };
				x.onerror = function() { done('could not read ' + url.slice(-24)); };
				x.send();
			}

			function parse(text) {
				var lines = text.split('\n');
				if (lines[0] !== 'MPSUB1') return null;

				var cues = [];
				for (var i = 1; i < lines.length && cues.length < MAX_CUES; i++) {
					var f = lines[i].split('\t');
					if (f.length !== 3) continue;

					var start = Number(f[0]) / 1000;
					var end = Number(f[1]) / 1000;
					if (!(end > start)) continue;

					var body = f[2].replace(/\\(.)/g, function(m, c) { return c === 'n' ? '\n' : c; });
					body = body.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
					cues.push(new VTTCue(start, end, body));
				}
				return cues;
			}

			function showPlain(on) {
				if (track) track.mode = on ? 'showing' : 'hidden';
			}

			function setPlain(cues) {
				if (!track) {
					track = video.addTextTrack('subtitles', 'Subtitles', 'und');
					track.mode = styled ? 'hidden' : 'showing';
				}
				while (track.cues && track.cues.length) track.removeCue(track.cues[0]);
				for (var i = 0; i < cues.length; i++) track.addCue(cues[i]);
			}

			function stopStyled() {
				if (renderer && rendererState === 'ready') {
					try { renderer.freeTrack(); } catch (e) {}
				}
				styled = false;
				showPlain(true);
			}

			function fail(reason) {
				rendererState = 'failed';
				styled = false;
				showPlain(true);
				log('styled rendering unavailable: ' + reason);
			}

			function loadScript(src, done) {
				var s = document.createElement('script');
				s.onload = function() { done(null); };
				s.onerror = function() { done('script blocked or offline'); };
				s.src = src;
				(document.head || document.documentElement).appendChild(s);
			}

			// Plain text stays on screen until the renderer says it is ready.
			function startRenderer() {
				if (rendererState !== 'idle' || !ass) return;
				rendererState = 'loading';

				loadScript(LIB + 'jassub.umd.js', function(err) {
					if (err || !window.JASSUB) return fail(err || 'library missing');

					get(LIB + 'jassub-worker.js', 'text', function(err, code) {
						if (err) return fail(err);

						try {
							// A worker must come from the page's own origin, so it goes through a blob.
							var workerUrl = URL.createObjectURL(new Blob([code], { type: 'text/javascript' }));
							fontsAtStart = fonts.length;
							renderer = new window.JASSUB({
								video: video,
								subContent: ass,
								workerUrl: workerUrl,
								wasmUrl: LIB + 'jassub-worker.wasm',
								legacyWasmUrl: LIB + 'jassub-worker.wasm.js',
								fonts: fonts.slice(),
								availableFonts: { 'liberation sans': LIB + 'default.woff2' }
							});
						} catch (e) {
							return fail(e && e.message || e);
						}

						renderer.addEventListener('ready', function() {
							rendererState = 'ready';
							for (var i = fontsAtStart; i < fonts.length; i++) renderer.addFont(fonts[i]);
							if (ass) {
								renderer.setTrack(ass);
								styled = true;
								showPlain(false);
								log('styled rendering active');
							}
						});
						renderer.addEventListener('error', function(e) {
							fail(e && e.message || 'renderer error');
						});

						setTimeout(function() {
							if (rendererState === 'loading') fail('timed out');
						}, 30000);
					});
				});
			}

			function load(id, wantStyled) {
				if (!video || typeof id !== 'string' || !/^[0-9]+_[0-9]+$/.test(id)) return;

				var mine = ++latest;

				get(DIR + 's' + id + '.txt', 'text', function(err, text) {
					if (mine !== latest) return;

					var cues = err ? null : parse(text);
					if (cues) setPlain(cues); else log('unreadable file s' + id + (err ? ': ' + err : ''));

					if (!wantStyled) {
						ass = null;
						if (styled) stopStyled();
						return;
					}

					get(DIR + 'a' + id + '.txt', 'text', function(err, script) {
						if (mine !== latest) return;

						if (err || !script || script.indexOf('[Events]') < 0) {
							log('unreadable file a' + id + (err ? ': ' + err : ''));
							return;
						}

						ass = script;

						if (rendererState === 'ready') {
							renderer.setTrack(ass);
							if (!styled) { styled = true; showPlain(false); }
						} else {
							startRenderer();
						}
					});
				});
			}

			function font(id) {
				if (typeof id !== 'string' || !/^[0-9]+_[0-9]+$/.test(id)) return;

				get(DIR + 'f' + id + '.dat', 'arraybuffer', function(err, data) {
					if (err || !data || !data.byteLength) return log('unreadable font ' + id);

					var bytes = new Uint8Array(data);
					fonts.push(bytes);
					if (rendererState === 'ready') renderer.addFont(bytes);
				});
			}

			function clear() {
				latest++;
				ass = null;
				if (track) while (track.cues && track.cues.length) track.removeCue(track.cues[0]);
				if (styled) stopStyled();
			}

			window.MPSubs = { load: load, font: font, clear: clear };

			announce(100); // up to about 10 seconds
		})();
	</script>
]=] ):format( ASSET_URL, JASSUB_URL )

local JS_Load = "if(window.MPSubs)MPSubs.load('%s',%s);"
local JS_Font = "if(window.MPSubs)MPSubs.font('%s');"
local JS_Clear = "if(window.MPSubs)MPSubs.clear();"

--[[---------------------------------------------------------
	Job
-----------------------------------------------------------]]

local Job = {}
Job.__index = Job

local function NewJob( media )
	subtitleJobs = subtitleJobs + 1

	return setmetatable( {
		media = media,
		url = media.url,
		id = subtitleJobs,
		state = "idle", -- idle, loading, ready, failed (the file's track list)
		cancelled = false,
		epoch = 0, -- bumped whenever running reads must be forgotten
		subtitleTracks = {},
		audioTracks = {},
		selected = nil, -- subtitle track number, 0 for off
		selectedAudio = nil,
		manual = false, -- chosen in the menu rather than by the language setting
		openRetries = 0, nextOpenAt = 0,
		windowRetries = 0, nextWindowAt = 0,
		seq = 0, fontFiles = {}, fontsSent = 0,
	}, Job )
end

function Job:Cancelled( epoch )
	return self.cancelled or ( epoch ~= nil and self.epoch ~= epoch )
end

function Job:FindSubtitleTrack( number )
	for _, track in ipairs( self.subtitleTracks ) do
		if track.number == number then return track end
	end
end

function Job:SelectedTrack()
	return self.selected and self.selected ~= 0 and self:FindSubtitleTrack( self.selected ) or nil
end

-- Styling applies to ASS tracks only: plain text tracks have nothing to style, and the
-- page's own text rendering has the system fonts that CJK text needs.
function Job:WantsStyle()
	local track = self:SelectedTrack()
	return track ~= nil and Matroska.IsAssTrack( track ) and StylingEnabled()
end

function Job:UseStyled()
	return self:WantsStyle() and self.fontsState == "done" and #self.fontFiles > 0
end

--- Reading the file's tracks ------------------------------------------------

function Job:RetryOpenLater( err )
	self.openRetries = self.openRetries + 1
	self.nextOpenAt = RealTime() + RETRY_DELAY
	self.state = "failed"

	Log( "could not read the track list:", err, "(attempt " .. self.openRetries .. ")" )
	Changed()
end

-- Reads the track list if that has not happened yet. Cheap to call repeatedly.
function Job:EnsureTracks()
	if self.cancelled or self.state == "loading" or self.state == "ready" then return end

	if self.state == "failed" and ( self.openRetries >= MAX_RETRIES or RealTime() < self.nextOpenAt ) then
		return
	end

	self.state = "loading"
	Log( "reading the track list of", self.url )
	Changed()

	PrepareDirectory()

	Matroska.HTTPReader( self.url, function( err, read )
		if self.cancelled then return end
		if err then return self:RetryOpenLater( err ) end

		Matroska.Open( read, function( openErr, mkv )
			if self.cancelled then return end
			if openErr then return self:RetryOpenLater( openErr ) end

			self.mkv = mkv
			self.audioTracks = Matroska.GetAudioTracks( mkv )

			self.subtitleTracks = {}
			for _, track in ipairs( Matroska.GetSubtitleTracks( mkv ) ) do
				local supported, reason = Matroska.IsSubtitleSupported( track )

				if supported then
					self.subtitleTracks[#self.subtitleTracks + 1] = track
				else
					Log( "track", track.number, "skipped:", reason )
				end
			end

			self.state = "ready"
			self.openRetries = 0
			Log( #self.subtitleTracks .. " subtitle track(s), " .. #self.audioTracks .. " audio track(s)" )

			self:ApplyPreference()
			Changed()
		end, function() return self.cancelled end )
	end )
end

-- Chooses the track from the language setting, unless one was picked in the menu.
function Job:ApplyPreference()
	if self.manual or self.state ~= "ready" then return end

	local wanted = WantedLanguage()
	local track = wanted and ChooseTrack( self.subtitleTracks, wanted )
	local number = track and track.number or 0

	if wanted and not track then
		Log( "no '" .. wanted .. "' subtitle track in the file" )
	end

	if number ~= self.selected then
		Log( "selected subtitle track", number, track and track.name or "" )
		self:SetSelected( number )
	end
end

function Job:PreferenceChanged()
	self.manual = false

	if self.state == "ready" then
		self:ApplyPreference()
	elseif WantedLanguage() then
		self:EnsureTracks()
	end
end

function Job:SetSelected( number )
	self.selected = number
	self:ResetWindow()
	Changed()
end

--- Windows -------------------------------------------------------------------

function Job:DeleteWindowFiles()
	if self.current then
		file.Delete( PlainPath( self.current ) )
		file.Delete( AssPath( self.current ) )
	end
end

function Job:ClearPage()
	local browser = self.browser

	if self.pageReady and IsValid( browser ) then
		browser:QueueJavascript( JS_Clear )
	end
end

-- Forgets the window and everything that is still being read for it.
function Job:ResetWindow()
	self.epoch = self.epoch + 1
	self.busy = false
	self.dead = false
	self.displayed = false
	self.from, self.to, self.window = nil, nil, nil
	self.windowRetries, self.nextWindowAt = 0, 0

	self:DeleteWindowFiles()
	self.current = nil
	self:ClearPage()
end

-- Called from the media's Sync(): opens the file if the language setting asks for
-- subtitles, then reads the next window whenever the position leaves the loaded one.
function Job:Update()
	if self.cancelled then return end

	if self.state == "idle" or self.state == "failed" then
		if WantedLanguage() then self:EnsureTracks() end
		return
	end

	local track = self:SelectedTrack()
	if self.state ~= "ready" or not track or self.busy or self.dead then return end

	if self:WantsStyle() then self:EnsureFonts() end

	local now = self.media:CurrentTime()
	if now < 0 or not IsValid( self.browser ) then return end

	-- the loaded window still covers the position
	if self.to and now >= self.from and now < self.to - REFILL_AHEAD then return end

	if RealTime() < self.nextWindowAt then return end

	self:ReadWindow( track, now )
end

function Job:RetryWindowLater( err )
	self.windowRetries = self.windowRetries + 1
	self.nextWindowAt = RealTime() + RETRY_DELAY

	Log( "window read failed:", err, "(attempt " .. self.windowRetries .. ")" )

	if self.windowRetries >= MAX_RETRIES then
		self.dead = true
		Log( "giving up on this track" )
	end

	Changed()
end

function Job:ReadWindow( track, now )
	-- Extending the window that is on screen reads a lot; after starting or seeking (the
	-- position is not inside the loaded window) only a little, so lines show quickly.
	local extending = self.to ~= nil and now >= self.from and now < self.to
	local from = math.max( now - WINDOW_BEHIND, 0 )
	local to = now + ( extending and EXTEND_AHEAD or COVER_AHEAD )
	local epoch = self.epoch

	self.busy = true

	Matroska.ReadRange( self.mkv, track.number, from, to, {
		cancelled = function() return self:Cancelled( epoch ) end,
	}, function( err, events, coveredTo )
		if self:Cancelled( epoch ) then return end

		self.busy = false

		if err then return self:RetryWindowLater( err ) end

		self.windowRetries = 0
		self.nextWindowAt = RealTime() + MIN_WINDOW_INTERVAL

		Log( ( "window %.0f-%.0fs: %d line(s)" ):format( from, coveredTo, #events ) )

		self:WriteWindow( events, from, coveredTo )
	end )
end

function Job:WriteWindow( events, from, to )
	local track = self:SelectedTrack()
	if not track then return end

	self.seq = self.seq + 1

	local key = ( "%d_%d" ):format( self.id, self.seq )
	local styled = self:UseStyled()
	local header = styled and Matroska.GetAssHeader( track )

	if styled and not header then
		Log( "the track has no usable ASS header, showing plain text" )
		styled = false
	end

	if not WriteChecked( PlainPath( key ), SerializePlain( events ) )
		or ( styled and not WriteChecked( AssPath( key ), SerializeAss( header, events ) ) ) then
		Log( "could not write to the data folder (" .. SUBTITLE_DIR .. ")" )
		self.dead = true
		file.Delete( PlainPath( key ) )
		file.Delete( AssPath( key ) )
		return
	end

	self:DeleteWindowFiles()

	self.current, self.currentStyled = key, styled
	self.from, self.to = from, to
	self.window = { events = events, from = from, to = to }
	self.displayed = true

	self:Send()
	Changed()
end

-- Writes the window that is already loaded again, for example once the fonts have arrived.
function Job:Rewrite()
	local window = self.window

	if window then
		self:WriteWindow( window.events, window.from, window.to )
	end
end

--- Fonts ----------------------------------------------------------------------

-- Downloads the fonts the file carries, once, in the background.
function Job:EnsureFonts()
	if self.fontsState then return end

	self.fontsState = "listing"
	Log( "looking for embedded fonts" )
	Changed()

	Matroska.GetFonts( self.mkv, function( err, fonts )
		if self.cancelled then return end

		if err or #fonts == 0 then
			self.fontsState = "none"
			Log( err and ( "could not list fonts: " .. err ) or "the file has no embedded fonts, showing plain text" )
			Changed()
			return
		end

		Log( #fonts .. " embedded font(s)" )

		self.fontQueue, self.fontIndex, self.fontsActive = fonts, 0, 0
		self.fontsState = "loading"

		self:PumpFonts()
		Changed()
	end, function() return self.cancelled end )
end

function Job:PumpFonts()
	local queue = self.fontQueue

	while not self.cancelled and self.fontsActive < FONT_CONCURRENCY and self.fontIndex < #queue do
		self.fontIndex = self.fontIndex + 1

		local font = queue[self.fontIndex]
		local key = ( "%d_%d" ):format( self.id, self.fontIndex )
		local path = FontPath( key )

		if WriteChecked( path, "" ) then
			self.fontsActive = self.fontsActive + 1

			Matroska.ReadAttachment( self.mkv, font, function( chunk )
				file.Append( path, chunk )
			end, { cancelled = function() return self.cancelled end }, function( err )
				self.fontsActive = self.fontsActive - 1
				if self.cancelled then return end

				if err or file.Size( path, "DATA" ) ~= font.size then
					Log( "font failed:", font.name, err or "size mismatch" )
					file.Delete( path )
				else
					Log( "font ready:", font.name )
					self.fontFiles[#self.fontFiles + 1] = key
					self:Send()
				end

				self:PumpFonts()
			end )
		else
			Log( "could not write", path )
		end
	end

	if self.fontsActive == 0 and self.fontIndex >= #queue and self.fontsState == "loading" then
		self.fontsState = "done"
		Log( "fonts done:", #self.fontFiles, "of", #queue )

		self:Rewrite()
		Changed()
	end
end

function Job:StylingChanged()
	if self.cancelled then return end

	Log( "styling", StylingEnabled() and "on" or "off" )

	if self:WantsStyle() then self:EnsureFonts() end

	self:Rewrite()
	Changed()
end

--- Player page ----------------------------------------------------------------

-- Called whenever the page is (re)loaded.
function Job:AttachPage( browser )
	self.browser = browser
	self.pageReady = false
	self.fontsSent = 0

	-- The page calls these; they take nothing that is acted on.
	browser:AddFunction( "gmod", "subtitlesReady", function()
		if self.cancelled or self.browser ~= browser then return end

		self.pageReady = true
		Log( "page ready" )
		self:Send()
	end )

	browser:AddFunction( "gmod", "subtitlesLog", function( message )
		if type( message ) == "string" then
			Log( "page:", message:sub( 1, 200 ) )
		end
	end )
end

-- Hands the page what it does not have yet: new fonts first, then the current window.
function Job:Send()
	local browser = self.browser
	if self.cancelled or not self.pageReady or not IsValid( browser ) then return end

	for i = self.fontsSent + 1, #self.fontFiles do
		browser:QueueJavascript( JS_Font:format( self.fontFiles[i] ) )
	end
	self.fontsSent = #self.fontFiles

	if self.current then
		browser:QueueJavascript( JS_Load:format( self.current, self.currentStyled and "true" or "false" ) )
	end
end

function Job:Cancel()
	if self.cancelled then return end

	self.cancelled = true
	self.epoch = self.epoch + 1
	Subtitles.jobs[self] = nil

	self:DeleteWindowFiles()

	for i = 1, #self.fontFiles do
		file.Delete( FontPath( self.fontFiles[i] ) )
	end

	-- a font that was being written
	for i = 1, ( self.fontIndex or 0 ) do
		file.Delete( FontPath( ( "%d_%d" ):format( self.id, i ) ) )
	end

	Log( "stopped" )
	Changed()
end

--[[---------------------------------------------------------
	Used by services
-----------------------------------------------------------]]

-- Returns nil, reason when the media has no tracks to offer.
function Subtitles.Eligible( media )
	local path = media.urlinfo and media.urlinfo.path
	local ext = path and path:match( "[^/]+%.(%S+)$" ) or ""

	if ext:lower() ~= "mkv" then
		return nil, "not an .mkv file (" .. ( ext ~= "" and ext or "no extension" ) .. ")"
	end

	return true
end

-- Creates the media's job if it has none, and connects it to the player page.
function Subtitles.Attach( media, browser )
	local job = media._subtitles

	if not job or job.cancelled then
		local ok, reason = Subtitles.Eligible( media )

		if not ok then
			Log( "not used for this media:", reason )
			return nil
		end

		job = NewJob( media )
		media._subtitles = job
		Subtitles.jobs[job] = true

		Log( "subtitles available for", media.url, "- language preference:", WantedLanguage() or "off" )
		Changed()
	end

	job:AttachPage( browser )

	return job
end

function Subtitles.Detach( media )
	local job = media._subtitles

	if job then
		job:Cancel()
	end
end

--[[---------------------------------------------------------
	Used by the settings menu
-----------------------------------------------------------]]

-- unavailable: no tracks to offer for this media; loading; failed; none: the file has
-- no (usable) subtitle tracks; ready
function Subtitles.GetStatus( job )
	if not job or job.cancelled then return "unavailable" end
	if job.state == "failed" then return "failed" end
	if job.state ~= "ready" then return "loading" end
	if #job.subtitleTracks == 0 then return "none" end

	return "ready"
end

-- True while subtitles are being prepared: the track list, the first lines after
-- choosing a track or seeking, and the fonts for styled rendering.
function Subtitles.IsLoading( job )
	if not job or job.cancelled then return false end
	if job.state == "idle" or job.state == "loading" then return job.state == "loading" end
	if job.state ~= "ready" then return false end

	if job:SelectedTrack() and not job.dead and not job.displayed then return true end

	return job:WantsStyle() and ( job.fontsState == "listing" or job.fontsState == "loading" ) or false
end

-- { label, value, selected } for the dropdown, and whether it can be used
function Subtitles.GetChoices( job )
	local choices = {
		{ label = MediaPlayer.L( "mp.settings.subtitles_off" ), value = 0, selected = job.selected == 0 },
	}

	for index, track in ipairs( job.subtitleTracks ) do
		choices[#choices + 1] = {
			label = TrackLabel( track, index ),
			value = track.number,
			selected = job.selected == track.number,
		}
	end

	return choices, true
end

function Subtitles.Choose( job, number )
	if not job or job.cancelled or job.state ~= "ready" then return end
	if number ~= 0 and not job:FindSubtitleTrack( number ) then return end

	job.manual = true
	Log( "subtitle track chosen in the menu:", number )

	if job.selected ~= number then
		job:SetSelected( number )
	else
		Changed()
	end
end

function Subtitles.GetAudioChoices( job )
	local choices = {}
	local selected = job.selectedAudio

	if not selected then
		for _, track in ipairs( job.audioTracks ) do
			if track.default then selected = track.number break end
		end
		selected = selected or ( job.audioTracks[1] and job.audioTracks[1].number )
	end

	for index, track in ipairs( job.audioTracks ) do
		choices[#choices + 1] = {
			label = TrackLabel( track, index ),
			value = track.number,
			selected = selected == track.number,
		}
	end

	return choices
end

-- The page cannot switch audio tracks yet (SupportsAudioSelection), so this only
-- remembers the choice.
function Subtitles.ChooseAudio( job, number )
	if not job or job.cancelled then return end

	job.selectedAudio = number
	Changed()
end

--[[---------------------------------------------------------
	Settings that reach running jobs
-----------------------------------------------------------]]

cvars.AddChangeCallback( "mediaplayer_cc_lang", function()
	for job in pairs( Subtitles.jobs ) do
		job:PreferenceChanged()
	end
end, "MP.Subtitles" )

cvars.AddChangeCallback( "mediaplayer_subtitle_styling", function()
	for job in pairs( Subtitles.jobs ) do
		job:StylingChanged()
	end
end, "MP.Subtitles" )
