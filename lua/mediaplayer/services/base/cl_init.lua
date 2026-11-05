include "shared.lua"

function SERVICE:Volume( volume )
	if volume then
		self._volume = tonumber(volume) or self._volume
	end
	return self._volume
end

function SERVICE:IsPaused()
	return self._PauseTime ~= nil
end

function SERVICE:Stop()
	self._playing = false
	self:emit("stop")
end

function SERVICE:PlayPause()
	if self:IsPlaying() then
		self:Pause()
	else
		self:Play()
	end
end

function SERVICE:Sync()
	-- Implement this in timed services
end

function SERVICE:NetWriteRequest()
	-- Send any additional net data here
end

function SERVICE:OnMousePressed( x, y )
end

function SERVICE:OnMouseWheeled( scrollDelta )
end

---
-- Mouse is hovering over the screen; called every frame while it is.
--
-- @param x number	Horizontal position on the screen, 0 to 1.
-- @param y number	Vertical position on the screen, 0 to 1.
-- @return boolean	True if the service has taken the cursor.
function SERVICE:OnMouseMoved( x, y )
	return false
end

---
-- Mouse stopped hovering over the screen.
function SERVICE:OnMouseLeft()
end

function SERVICE:IsMouseInputEnabled()
	return false
end
