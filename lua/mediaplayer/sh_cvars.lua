MediaPlayer.Cvars = {}

MediaPlayer.Cvars.Debug = CreateConVar( "mediaplayer_debug", 0, FCVAR_DONTRECORD, "Enables media player debug mode; logs a bunch of actions into the console." )
MediaPlayer.DEBUG = MediaPlayer.Cvars.Debug:GetBool()
cvars.AddChangeCallback( "mediaplayer_debug", function(name, old, new)
	MediaPlayer.DEBUG = tobool(new)
end)

MediaPlayer.Cvars.AllowWebpages = CreateConVar( "mediaplayer_allow_webpages", 0, {
	FCVAR_ARCHIVE,
	FCVAR_NOTIFY,
	FCVAR_REPLICATED,
	FCVAR_SERVER_CAN_EXECUTE
}, "Allows any webpage to be requested." )

MediaPlayer.Cvars.QueueLimit = CreateConVar( "mediaplayer_queue_limit", 64, {
	FCVAR_REPLICATED,
	FCVAR_SERVER_CAN_EXECUTE
}, "Maximum size of a media player queue." )

if CLIENT then

	MediaPlayer.Cvars.Resolution	= CreateClientConVar( "mediaplayer_resolution", "480", true, false )
	MediaPlayer.Cvars.Audio3D		= CreateClientConVar( "mediaplayer_3daudio", "1", true, false )
	MediaPlayer.Cvars.Volume		= CreateClientConVar( "mediaplayer_volume", "0.15", true, false )
	MediaPlayer.Cvars.MuteUnfocused	= CreateClientConVar( "mediaplayer_mute_unfocused", "1", true, false )
	MediaPlayer.Cvars.Fullscreen	= CreateClientConVar( "mediaplayer_fullscreen", "0", false, false )
	MediaPlayer.Cvars.DrawThumbnails = CreateClientConVar( "mediaplayer_draw_thumbnails", "0", true, false )
	MediaPlayer.Cvars.ProximityMin = CreateClientConVar( "mediaplayer_proximity_min", "100", true, false )
	MediaPlayer.Cvars.ProximityMax = CreateClientConVar( "mediaplayer_proximity_max", "1000", true, false )

	-- Hold the context menu key over a screen to get a cursor on the page, with left/right click and scroll.
	MediaPlayer.Cvars.ScreenCursor = CreateClientConVar( "mediaplayer_screen_cursor", "0", true, false )

	-- Per-viewer subtitle language: YouTube captions (passed to the player page) and
	-- embedded MKV subtitles (direct media).
	-- Language code (e.g. "ko", "en"); "off" disables captions.
	MediaPlayer.Cvars.CaptionLang	= CreateClientConVar( "mediaplayer_cc_lang", "off", true, false )

	-- Draw embedded ASS subtitles with the styling, fonts and positions the file defines.
	MediaPlayer.Cvars.SubtitleStyling = CreateClientConVar( "mediaplayer_subtitle_styling", "1", true, false )

	-- Choose where embedded MKV subtitles are rendered: on the player or on the HUD.
	MediaPlayer.Cvars.SubtitleMode = CreateClientConVar( "mediaplayer_subtitle_mode", "video", true, false )

end