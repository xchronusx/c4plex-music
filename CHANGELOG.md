# Changelog

## 1.0.1 - Stream dropout fixes

Fixes songs that refuse to play or cut out with "Network Failure", "Server
cannot be reached" or "Track cannot be found".

- Transcode session ids are now unique per stream. 1.0.0 reused one session
  per track, so seeking, restarting a track, repeat on a one-track queue, a
  duplicate track next in line, or replaying a recent track opened a second
  request on a live transcoder job and killed the stream.
- Direct Play now checks the file container as well as the codec (MP3 in
  .mp3, AAC in .m4a/.mp4/.aac, FLAC in .flac). Anything else transcodes.
- A direct-played track that is refused by the engine or dies early (format
  the engine can't use, or a Part key gone stale after a library rescan) is
  retried once as a transcode, and transcodes from then on.
- A transcoded stream that drops mid-song resumes from where it stopped
  instead of skipping to the next track. Retries are capped per track.

## 1.0.0 - Initial release

A native Control4 media service that streams a Plex Media Server's music library
through the Control4 Digital Audio engine, the same way the built-in streaming
services do.

- Browse Artists, Albums, Playlists, and an Extras home (radio stations, recently
  played/added, most played, genres, decades, and curated moods), plus
  whole-library search with A-Z jump scrolling.
- Artist pages: Play All, Shuffle All, Play Mix (artist radio, Plex Pass), Top
  Tracks, Discography, and in-library Similar Artists.
- Item menus: Play Now, Play Next, Add To Queue, Shuffle Play, Play Mix, and Add
  To Favorites; Play All / Shuffle All on albums, playlists, and Top Tracks.
- Now Playing with artwork, progress, transports, shuffle, and repeat; gapless
  advance; play progress reported back to Plex.
- plex.tv/link account pairing (or a pasted token), automatic server discovery,
  optional device auto-rename, and an optional daily update check (off by default).
- Direct Play (MP3/AAC/FLAC) with MP3 transcode fallback.
