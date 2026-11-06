DEFINE_BASECLASS( "mp_service_browser" )

SERVICE.Name 	= "Webpage"
SERVICE.Id 		= "www"
SERVICE.Base 	= "res"
SERVICE.Abstract = true -- This service must be handled as a special case.

if CLIENT then

	local WS = MediaPlayer.WebSync

	local SetDrawColor = surface.SetDrawColor
	local DrawRect = surface.DrawRect
	local SetFont = surface.SetFont
	local GetTextSize = surface.GetTextSize
	local SimpleText = draw.SimpleText

	local colorWarn = Color( 255, 200, 60, 255 )
	local colorText = Color( 200, 200, 200, 255 )

	-- Webpages are only loaded for players who turned on "Show webpages", since
	-- loading one reveals the player's IP address to the site.
	function SERVICE:Play()
		if not MediaPlayer.Cvars.ShowWebpages:GetBool() then
			-- Skip the browser; Draw explains why the screen is empty
			self._webHidden = true
			baseclass.Get( "mp_service_base" ).Play( self )
			return
		end

		self._webHidden = nil
		BaseClass.Play( self )
	end

	function SERVICE:Stop()
		if IsValid( self.Browser ) then
			WS.Detach( self.Browser )
		end

		BaseClass.Stop( self )
	end

	function SERVICE:OnBrowserReady( browser )
		BaseClass.OnBrowserReady( self, browser )

		-- Share this player's input on the page with the other viewers (and
		-- show theirs), before the page loads so the first document is covered
		WS.Attach( self, browser )

		browser:OpenURL( self.url )
	end

	function SERVICE:IsMouseInputEnabled()
		return IsValid( self.Browser )
	end

	function SERVICE:Draw( w, h )
		if not self._webHidden then
			return BaseClass.Draw( self, w, h )
		end

		SetDrawColor( 0, 0, 0, 255 )
		DrawRect( 0, 0, w, h )

		local lines = {
			{ MediaPlayer.L( "mp.webpage.hidden_title" ), colorWarn },
			{ MediaPlayer.L( "mp.webpage.hidden_detail" ), colorText },
			{ MediaPlayer.L( "mp.webpage.hidden_note" ), colorText },
		}

		SetFont( "MediaTitle" )

		local gap = 20
		local maxWidth, totalHeight = 0, gap * ( #lines - 1 )
		for _, line in ipairs( lines ) do
			local tw, th = GetTextSize( line[1] )
			line.w, line.h = tw, th
			maxWidth = math.max( maxWidth, tw )
			totalHeight = totalHeight + th
		end

		-- Shrink everything uniformly so the widest line fits the screen
		local scale = math.min( 1, ( w - 80 ) / maxWidth, ( h - 80 ) / totalHeight )

		local mat = Matrix()
		mat:Translate( Vector( w / 2, h / 2, 0 ) )
		mat:Scale( Vector( scale, scale, 1 ) )
		mat:Translate( Vector( -w / 2, -h / 2, 0 ) )
		cam.PushModelMatrix( mat, true )

		local y = h / 2 - totalHeight / 2
		for _, line in ipairs( lines ) do
			SimpleText( line[1], "MediaTitle", w / 2, y + line.h / 2, line[2],
				TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER )
			y = y + line.h + gap
		end

		cam.PopModelMatrix()
	end

else

	function SERVICE:Match( url )
		return false
	end

end
