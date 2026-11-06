# Configuration

ConVars are defined primarily in `lua/mediaplayer/sh_cvars.lua`. The spatial hear-radius ConVar is created by the server-side spatial player implementation.

## Server ConVars

| ConVar | Default | Flags / scope | Description |
|---|---:|---|---|
| `mediaplayer_debug` | `0` | Shared (server and client) | Enables verbose diagnostic logging in the realm where it is set |
| `mediaplayer_allow_webpages` | `1` | Archived, notified, replicated | Allows otherwise-unmatched URLs to use the generic webpage service, and relays viewers' mouse, scroll, keyboard and navigation on a webpage to the other viewers |
| `mediaplayer_queue_limit` | `64` | Replicated | Maximum number of queued items per media player |
| `mediaplayer_spatial_hear_radius` | `1800` | Archived, notified, replicated | Maximum distance at which players are listeners of a spatial anchor (Source units) |

Webpages are allowed by default, but each player decides for themselves: the client setting `mediaplayer_show_webpages` (off by default) controls whether webpages load in their game at all. Loading a page reveals the player's IP address to that site, so the settings tab asks for confirmation before turning it on. Players who leave it off see a notice on the screen instead.

On a shared webpage every viewer can control the page. Mouse movement, clicks, scrolling, keypresses, typed text (including passwords) and navigation are sent to the other viewers who have webpages enabled, and theirs to you. There is no separate setting for this; it follows `mediaplayer_allow_webpages`. Set `mediaplayer_allow_webpages 0` on servers where you don't want arbitrary pages or shared input. Arbitrary webpages are less predictable and expand the external-content attack surface, so restrict request permissions if that matters for your server.

Keyboard input only reaches a page that can take keyboard focus, which the screen cursor does not currently provide, so shared typing works only where the page receives keys by other means.

## Client ConVars

| ConVar | Default | Archived | Description |
|---|---:|---|---|
| `mediaplayer_volume` | `0.15` | Yes | Master playback volume (0–1) |
| `mediaplayer_resolution` | `480` | Yes | Browser render resolution height |
| `mediaplayer_3daudio` | `1` | Yes | Enables distance-based volume |
| `mediaplayer_mute_unfocused` | `1` | Yes | Mutes playback while the game window is unfocused |
| `mediaplayer_fullscreen` | `0` | No | Enables fullscreen playback |
| `mediaplayer_draw_thumbnails` | `0` | Yes | Draws thumbnails on screens |
| `mediaplayer_proximity_min` | `100` | Yes | Distance where proximity volume is full |
| `mediaplayer_proximity_max` | `1000` | Yes | Distance where proximity volume reaches zero |
| `mediaplayer_cc_lang` | `off` | Yes | Subtitle language code for YouTube and embedded MKV subtitles; `off` disables subtitles |
| `mediaplayer_subtitle_styling` | `1` | Yes | Draws embedded ASS subtitles with the file's own styling and fonts |

Most client settings are also exposed through the in-game **Media Player** menubar options.

## Spatial audio behavior

The server-side hear radius determines who becomes a listener of a spatial player. Client-side proximity settings control volume attenuation when `mediaplayer_3daudio` is enabled. These are separate controls: changing the client fade distances does not change the server listener radius.

If `mediaplayer_proximity_min` is greater than or equal to `mediaplayer_proximity_max`, the client ensures a non-zero range to avoid division by zero.

## Lua configuration table

The addon initializes `MediaPlayer.config` and merges values with:

```lua
MediaPlayer.SetConfig({
    example = {
        option = true
    }
})
```

Read nested values with:

```lua
local value = MediaPlayer.GetConfigValue("example.option")
```

Client defaults and hosted HTML endpoints are configured in `lua/mediaplayer/config/client.lua`. The current configuration points to the project's hosted request and YouTube helper pages.

## Related

- [Permissions](permissions.md)
- [Spatial Media](spatial-media.md)
- [Console commands](commands.md)
