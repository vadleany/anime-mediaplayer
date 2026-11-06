--[[---------------------------------------------------------
	Webpage input sync: client

	A script injected into the webpage reports this player's real mouse,
	scroll, keyboard and input activity by logging to the console, and
	replays the activity of other viewers on this player's copy of the page.
	Only real (trusted) browser events are reported, so replayed events never
	echo back.

	Events are only ever handed to the page as JSON data for a fixed script
	to interpret; nothing from the network is run as code.
-----------------------------------------------------------]]

local WS = MediaPlayer.WebSync

local CONSOLE_PREFIX = "MPSYNC:"
local keyboardService
local escapeWasDown = false

local function setKeyboardInput( service, enabled )
	local browser = service and service.Browser
	if not IsValid( browser ) then return end

	service._webKeyboardInput = enabled and true or nil
	browser._mpKeyboardInput = enabled and true or nil
	browser.OnKeyboardInputExit = enabled and function()
		setKeyboardInput( service, false )
	end or nil
	browser:SetKeyboardInputEnabled( enabled )
	if MediaPlayer.SetKeyboardScreenCursor then
		MediaPlayer.SetKeyboardScreenCursor( enabled )
	end

	if enabled then
		keyboardService = service
		escapeWasDown = input.IsKeyDown( KEY_ESCAPE )
		browser:MakePopup()
		if browser.RequestFocus then browser:RequestFocus() end
	elseif keyboardService == service then
		keyboardService = nil
		escapeWasDown = false

		-- Release every part of the popup state. Merely disabling keyboard
		-- input leaves the DHTML panel as the VGUI focus owner after MakePopup,
		-- which can prevent the game from receiving movement and other keys.
		if browser.EndMouseHover then browser:EndMouseHover() end
		browser:SetMouseInputEnabled( false )
		browser:SetKeyboardInputEnabled( false )

		-- MakePopup can leave VGUI owning focus, and a mouse button pressed
		-- while the browser owns the cursor may never deliver its release to
		-- the game. Explicitly relinquish focus and clear all mouse buttons.
		if browser.KillFocus then browser:KillFocus() end
		gui.InternalMouseReleased( MOUSE_LEFT )
		gui.InternalMouseReleased( MOUSE_RIGHT )
		gui.InternalMouseReleased( MOUSE_MIDDLE )
		gui.EnableScreenClicker( false )

		local cx, cy = input.GetCursorPos()
		gui.InternalCursorMoved( cx, cy )
	end
end

-- Escape is often handled by the engine as a bind before the focused DHTML
-- panel receives OnKeyCodePressed. Intercept the cancel/menu binds while
-- keyboard input mode is active so Escape exits the mode instead of opening
-- the game menu. This hook is declared after setKeyboardInput so it closes
-- over the local function rather than accidentally resolving a global.
hook.Add( "PlayerBindPress", "MediaPlayer.WebSync.KeyboardEscape", function( ply, bind, pressed )
	if not pressed or not IsValid( ply ) or ply ~= LocalPlayer() then return end
	if not keyboardService or not keyboardService._webKeyboardInput then return end
	if not IsValid( keyboardService.Browser ) then
		keyboardService = nil
		return
	end

	bind = string.lower( string.Trim( bind or "" ) )
	if bind == "cancelselect" or bind == "+cancelselect" or bind == "+menu" or bind == "escape" then
		setKeyboardInput( keyboardService, false )
		return true
	end
end )

-- Some GMod/CEF focus paths do not pass Escape through PlayerBindPress or
-- the DHTML panel's key callbacks. Poll only while keyboard mode is active
-- so Escape still reaches the same cleanup routine in those cases.
hook.Add( "Think", "MediaPlayer.WebSync.KeyboardEscapeFallback", function()
	if not keyboardService or not keyboardService._webKeyboardInput then
		escapeWasDown = false
		return
	end

	if not IsValid( keyboardService.Browser ) then
		keyboardService = nil
		escapeWasDown = false
		return
	end

	local escapeDown = input.IsKeyDown( KEY_ESCAPE )
	if escapeDown and not escapeWasDown then
		setKeyboardInput( keyboardService, false )
	end
	escapeWasDown = escapeDown
end )

-- Keyboard input mode is an explicit browser interaction mode: never let
-- mouse movement rotate the player's view, even when the cursor is outside
-- every MediaPlayer screen.
hook.Add( "InputMouseApply", "MediaPlayer.WebSync.LockCamera", function()
	if keyboardService and keyboardService._webKeyboardInput then
		return true
	end
end )

local CAPTURE_JS = [=[
(function () {
	if (window.__mpSync) return;

	var MAX = 1023;
	var SCROLL_MAX = 65535;
	var quietUntil = 0;
	var lastMove = 0;
	var scrollTimer = null;
	var cursors = {};

	function send(o) {
		try { console.log('MPSYNC:' + JSON.stringify(o)); } catch (e) {}
	}

	function cssEscape(s) {
		if (window.CSS && CSS.escape) return CSS.escape(s);
		return String(s).replace(/[^a-zA-Z0-9_-]/g, '\\$&');
	}

	function selectorFor(el) {
		if (el && el.nodeType !== 1) el = el.parentElement;
		var parts = [];
		while (el && el.nodeType === 1 && parts.length < 14) {
			var tag = el.tagName.toLowerCase();
			if (el.id) {
				var q = '#' + cssEscape(el.id);
				try {
					if (document.querySelectorAll(q).length === 1) { parts.unshift(q); break; }
				} catch (e) {}
			}
			if (tag === 'html') { parts.unshift('html'); break; }
			var n = 1, s = el;
			while ((s = s.previousElementSibling)) {
				if (s.tagName === el.tagName) n++;
			}
			parts.unshift(tag + ':nth-of-type(' + n + ')');
			el = el.parentElement;
		}
		var sel = parts.join('>');
		return sel.length <= 300 ? sel : '';
	}

	function find(sel) {
		if (!sel) return null;
		try { return document.querySelector(sel); } catch (e) { return null; }
	}

	function fx(x) { return Math.max(0, Math.min(MAX, Math.round(x / Math.max(1, window.innerWidth) * MAX))); }
	function fy(y) { return Math.max(0, Math.min(MAX, Math.round(y / Math.max(1, window.innerHeight) * MAX))); }

	function scrollExtent() {
		var d = document.documentElement;
		return {
			x: Math.max(0, d.scrollWidth - window.innerWidth),
			y: Math.max(0, d.scrollHeight - window.innerHeight)
		};
	}

	/* ---- Report this player's activity ---- */

	var opts = { capture: true, passive: true };

	document.addEventListener('mousemove', function (e) {
		if (!e.isTrusted) return;
		var now = Date.now();
		if (now - lastMove < 80) return;
		lastMove = now;
		send({ t: 'move', x: fx(e.clientX), y: fy(e.clientY) });
	}, opts);

	document.addEventListener('click', function (e) {
		if (!e.isTrusted) return;
		send({ t: 'click', x: fx(e.clientX), y: fy(e.clientY), b: 0, sel: selectorFor(e.target) });
	}, opts);

	document.addEventListener('contextmenu', function (e) {
		if (!e.isTrusted) return;
		send({ t: 'click', x: fx(e.clientX), y: fy(e.clientY), b: 2, sel: selectorFor(e.target) });

		// Collect context-menu data locally; it is never sent through WebSync.
		var target = e.target && e.target.nodeType === 1 ? e.target : (e.target && e.target.parentElement);
		var link = target && target.closest ? target.closest('a[href]') : null;
		var media = target && target.closest ? target.closest('video,audio,img,source') : null;
		var linkUrl = link ? link.href : '';
		var mediaUrl = '';
		if (media) {
			mediaUrl = media.currentSrc || media.src || media.getAttribute('src') || '';
			if (!mediaUrl && media.tagName === 'SOURCE' && media.parentElement) {
				mediaUrl = media.parentElement.currentSrc || media.parentElement.src || '';
			}
		}
		var selection = '';
		try { selection = String(window.getSelection ? window.getSelection() : '').trim(); } catch (err) {}
		function safeUrl(value) {
			return value && /^https?:\/\//i.test(value) ? String(value).slice(0, 2048) : '';
		}
		linkUrl = safeUrl(linkUrl);
		mediaUrl = safeUrl(mediaUrl);
		send({
			t: 'menu',
			link: linkUrl,
			selection: selection.slice(0, 1024),
			media: mediaUrl
		});
	}, opts);

	window.addEventListener('scroll', function () {
		if (Date.now() < quietUntil || scrollTimer) return;
		scrollTimer = setTimeout(function () {
			scrollTimer = null;
			if (Date.now() < quietUntil) return;
			var ext = scrollExtent();
			send({
				t: 'scroll',
				x: ext.x ? Math.round(Math.min(1, window.scrollX / ext.x) * SCROLL_MAX) : 0,
				y: ext.y ? Math.round(Math.min(1, window.scrollY / ext.y) * SCROLL_MAX) : 0
			});
		}, 100);
	}, { passive: true });

	function keyReporter(down) {
		return function (e) {
			if (!e.isTrusted) return;
			send({
				t: 'key',
				d: down,
				k: String(e.key).slice(0, 32),
				c: String(e.code || '').slice(0, 32),
				m: (e.shiftKey ? 1 : 0) | (e.ctrlKey ? 2 : 0) | (e.altKey ? 4 : 0) | (e.metaKey ? 8 : 0)
			});
		};
	}
	document.addEventListener('keydown', keyReporter(true), opts);
	document.addEventListener('keyup', keyReporter(false), opts);

	document.addEventListener('input', function (e) {
		if (!e.isTrusted) return;
		var el = e.target;
		if (!el || !el.tagName) return;
		var tag = el.tagName;
		if (tag !== 'INPUT' && tag !== 'TEXTAREA' && tag !== 'SELECT') return;
		var type = String(el.type || '').toLowerCase();
		if (type === 'checkbox' || type === 'radio' || type === 'file' ||
			type === 'button' || type === 'submit') return;
		send({ t: 'input', sel: selectorFor(el), v: String(el.value).slice(0, 1024) });
	}, opts);

	/* ---- Replay other viewers' activity ---- */

	function showCursor(who, px, py) {
		var key = who || '?';
		var c = cursors[key];

		if (!c) {
			var hue = 0;
			for (var i = 0; i < key.length; i++) hue = (hue * 31 + key.charCodeAt(i)) % 360;

			var el = document.createElement('div');
			el.style.cssText = 'position:fixed;left:0;top:0;z-index:2147483647;' +
				'pointer-events:none;transition:transform 80ms linear;display:none;';

			var dot = document.createElement('div');
			dot.style.cssText = 'width:10px;height:10px;margin:-5px 0 0 -5px;border-radius:50%;' +
				'border:1px solid #fff;background:hsl(' + hue + ',80%,55%);';
			el.appendChild(dot);

			var label = document.createElement('div');
			label.textContent = key;
			label.style.cssText = 'position:absolute;left:8px;top:4px;padding:1px 4px;' +
				'border-radius:3px;font:11px sans-serif;color:#fff;white-space:nowrap;' +
				'background:rgba(0,0,0,.7);';
			el.appendChild(label);

			c = cursors[key] = { el: el, timer: null };
		}

		if (!c.el.parentNode) (document.body || document.documentElement).appendChild(c.el);

		c.el.style.transform = 'translate(' + px + 'px,' + py + 'px)';
		c.el.style.display = 'block';
		clearTimeout(c.timer);
		c.timer = setTimeout(function () { c.el.style.display = 'none'; }, 3000);
	}

	function replayClick(ev, px, py) {
		var el = find(ev.sel) || document.elementFromPoint(px, py);
		if (!el) return;

		if (ev.b === 2) {
			el.dispatchEvent(new MouseEvent('contextmenu', {
				bubbles: true, cancelable: true, view: window,
				clientX: px, clientY: py, button: 2
			}));
			return;
		}

		if (typeof el.focus === 'function') { try { el.focus(); } catch (e) {} }

		if (typeof el.click === 'function') {
			el.click();
		} else {
			el.dispatchEvent(new MouseEvent('click', {
				bubbles: true, cancelable: true, view: window, clientX: px, clientY: py
			}));
		}
	}

	function replayInput(ev) {
		var el = find(ev.sel);
		if (!el || !('value' in el)) return;

		var desc = Object.getOwnPropertyDescriptor(Object.getPrototypeOf(el), 'value');
		if (desc && desc.set) desc.set.call(el, ev.v); else el.value = ev.v;

		el.dispatchEvent(new Event('input', { bubbles: true }));
	}

	function replayKey(ev) {
		var target = document.activeElement || document.body;
		target.dispatchEvent(new KeyboardEvent(ev.d ? 'keydown' : 'keyup', {
			key: ev.k, code: ev.c, bubbles: true, cancelable: true,
			shiftKey: !!(ev.m & 1), ctrlKey: !!(ev.m & 2),
			altKey: !!(ev.m & 4), metaKey: !!(ev.m & 8)
		}));
	}

	window.__mpSync = {
		apply: function (ev) {
			try {
				var px = ev.x / MAX * window.innerWidth;
				var py = ev.y / MAX * window.innerHeight;

				if (ev.t === 'move') {
					showCursor(ev.who, px, py);
				} else if (ev.t === 'click') {
					showCursor(ev.who, px, py);
					replayClick(ev, px, py);
				} else if (ev.t === 'scroll') {
					var ext = scrollExtent();
					quietUntil = Date.now() + 600;
					window.scrollTo(ev.x / SCROLL_MAX * ext.x, ev.y / SCROLL_MAX * ext.y);
				} else if (ev.t === 'key') {
					replayKey(ev);
				} else if (ev.t === 'input') {
					replayInput(ev);
				}
			} catch (e) {}
		}
	};
}());
]=]

--[[---------------------------------------------------------
	Finding the media player a webpage belongs to
-----------------------------------------------------------]]

function WS.FindPlayer( media )
	for _, mp in pairs( MediaPlayer.List ) do
		if IsValid( mp ) and mp:GetMedia() == media then
			return mp
		end
	end
end

--[[---------------------------------------------------------
	Sending
-----------------------------------------------------------]]

local function sendEvent( service, ev )
	if not MediaPlayer.Cvars.AllowWebpages:GetBool() then return end

	local mp = WS.FindPlayer( service )
	if not mp then return end

	net.Start( WS.NET )
		net.WriteString( mp:GetId() )
		WS.Write( ev )
	net.SendToServer()
end

--- Starts sharing input for a webpage service. Call before the page is opened.
function WS.Attach( service, browser )
	-- The first load is every viewer's own; only later changes are shared
	service._webLastUrl = service.url

	browser.OnWebDocumentReady = function( panel )
		panel:RunJavascript( CAPTURE_JS )
	end

	browser.OnWebSync = function( _, json )
		local raw = util.JSONToTable( json )
		-- Context menus are local UI actions, not synchronized page input.
		-- Treat all page-provided values as untrusted strings.
		if istable( raw ) and raw.t == "menu" then
			local function cleanValue( value, max )
				if not isstring( value ) or #value == 0 or #value > max then return nil end
				if value:find( "[%z\1-\31]" ) then return nil end
				return value
			end

			local link = cleanValue( raw.link, 2048 )
			local selection = cleanValue( raw.selection, 1024 )
			local media = cleanValue( raw.media, 2048 )
			local validLink = link and link:match( "^https?://[^%s]+$" ) and link or nil
			local validMedia = media and media:match( "^https?://[^%s]+$" ) and media or nil
			local mp = WS.FindPlayer( service )
			if not IsValid( mp ) then return end

			-- Capture the real cursor position before releasing the browser.
			-- EndMouseHover can cause VGUI to recalculate the hovered panel.
			local cursorX, cursorY = input.GetCursorPos()

			-- The menu must own both mouse and keyboard focus while it is open.
			-- In keyboard mode the browser normally keeps keyboard focus, so
			-- temporarily release that focus without changing the mode itself.
			if IsValid( browser ) then
				if browser.EndMouseHover then browser:EndMouseHover() end
				browser:SetMouseInputEnabled( false )
				browser:SetKeyboardInputEnabled( false )
				if browser.KillFocus then browser:KillFocus() end
			end

			if MediaPlayer.SetWebContextMenuOpen then
				MediaPlayer.SetWebContextMenuOpen( true )
			end

			local menu = DermaMenu()
			local oldOnRemove = menu.OnRemove
			menu.OnRemove = function( panel )
				if MediaPlayer.SetWebContextMenuOpen then
					MediaPlayer.SetWebContextMenuOpen( false )
				end
				if oldOnRemove then oldOnRemove( panel ) end

				-- Restore webpage keyboard focus only if the user left keyboard
				-- input mode enabled (the menu can also turn it off).
				if IsValid( browser ) and service._webKeyboardInput then
					browser:SetKeyboardInputEnabled( true )
					browser:MakePopup()
					browser:SetMouseInputEnabled( false )
					if browser.RequestFocus then browser:RequestFocus() end
				end
			end
			local keyboardOption = menu:AddOption( "Keyboard Input", function()
				setKeyboardInput( service, not service._webKeyboardInput )
			end )
			keyboardOption:SetChecked( service._webKeyboardInput == true )
			keyboardOption:SetIcon( "icon16/keyboard.png" )
			menu:AddSpacer()

			if validLink then
				menu:AddOption( "Open link", function()
					if IsValid( mp ) and IsValid( browser ) then browser:OpenURL( validLink ) end
				end ):SetIcon( "icon16/link_go.png" )

				menu:AddOption( "Copy link address", function()
					SetClipboardText( validLink )
				end ):SetIcon( "icon16/link.png" )

				if MediaPlayer.ValidUrl( validLink ) then
					menu:AddOption( "Add to queue", function()
						if IsValid( mp ) then MediaPlayer.Request( mp, validLink ) end
					end ):SetIcon( "icon16/add.png" )
				end
			end

			if selection then
				if validLink then menu:AddSpacer() end
				menu:AddOption( "Copy selected text", function()
					SetClipboardText( selection )
				end ):SetIcon( "icon16/page_copy.png" )
			end

			if validMedia then
				if validLink or selection then menu:AddSpacer() end
				menu:AddOption( "Copy media URL", function()
					SetClipboardText( validMedia )
				end ):SetIcon( "icon16/film.png" )

				if not validLink and MediaPlayer.ValidUrl( validMedia ) then
					menu:AddOption( "Add to queue", function()
						if IsValid( mp ) then MediaPlayer.Request( mp, validMedia ) end
					end ):SetIcon( "icon16/add.png" )
				end
			end

			if validLink or selection or validMedia then menu:AddSpacer() end
			menu:AddOption( "Back", function()
				if IsValid( browser ) then browser:RunJavascript( "history.back();" ) end
			end ):SetIcon( "icon16/arrow_left.png" )
			menu:AddOption( "Forward", function()
				if IsValid( browser ) then browser:RunJavascript( "history.forward();" ) end
			end ):SetIcon( "icon16/arrow_right.png" )
			menu:AddOption( "Reload", function()
				if IsValid( browser ) then browser:RunJavascript( "location.reload();" ) end
			end ):SetIcon( "icon16/arrow_refresh.png" )

			-- DermaMenu's default position can be stale after the browser
			-- relinquishes its popup focus; pass the captured screen position.
			menu:Open( cursorX, cursorY )
			return
		end

		local ev = WS.Sanitize( raw )
		if ev then
			sendEvent( service, ev )
		end
	end
	browser.OnWebURLChanged = function( _, new )
		if not isstring( new ) or new == service._webLastUrl then return end
		service._webLastUrl = new

		local ev = WS.Sanitize( { t = "nav", url = new } )
		if ev then
			sendEvent( service, ev )
		end
	end
end

--- Stops sharing input. Call before the browser is released to the pool.
function WS.Detach( browser )
	if keyboardService and keyboardService.Browser == browser then
		setKeyboardInput( keyboardService, false )
	end
	browser._mpKeyboardInput = nil
	browser.OnKeyboardInputExit = nil
	browser.OnWebDocumentReady = nil
	browser.OnWebSync = nil
	browser.OnWebURLChanged = nil
end

--[[---------------------------------------------------------
	Receiving
-----------------------------------------------------------]]

-- JSON is valid script apart from these two characters on older engines
local function jsLiteral( tbl )
	local json = util.TableToJSON( tbl )
	if not json then return nil end

	json = json:gsub( "\226\128\168", "\\u2028" ):gsub( "\226\128\169", "\\u2029" )
	return json
end

net.Receive( WS.NET, function()
	local mp = MediaPlayer.GetById( net.ReadString() )
	local ev, who = WS.Read( true )

	if not ( ev and IsValid( mp ) ) then return end
	if not MediaPlayer.Cvars.AllowWebpages:GetBool() then return end

	local media = mp:GetMedia()
	if not WS.IsWebpage( media ) then return end

	local browser = media.Browser
	if not IsValid( browser ) then return end

	if ev.t == "nav" then
		if browser:GetURL() ~= ev.url then
			media._webLastUrl = ev.url
			browser:OpenURL( ev.url )
		end
		return
	end

	ev.who = who

	local json = jsLiteral( ev )
	if json then
		browser:RunJavascript( "window.__mpSync && window.__mpSync.apply(" .. json .. ");" )
	end
end )

--[[---------------------------------------------------------
	Showing or hiding webpages when the setting changes
-----------------------------------------------------------]]

cvars.AddChangeCallback( "mediaplayer_show_webpages", function( _, _, new )
	local show = tobool( new )

	for _, mp in pairs( MediaPlayer.List ) do
		local media = IsValid( mp ) and mp:GetMedia()

		if WS.IsWebpage( media ) then
			if show and media._webHidden then
				media:Play()
			elseif not show and not media._webHidden then
				media:Stop()
				media._webHidden = true
			end
		end
	end
end, "MediaPlayer.WebSync" )
