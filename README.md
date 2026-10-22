# Itsytunes

A small macOS music player for a local folder. It tags songs and finds album art automatically, and it can save audio from YouTube and sync your Bandcamp purchases.

<img width="1316" height="1005" alt="Screenshot 2026-10-15 at 10 21 40" src="https://github.com/user-attachments/assets/c897d6a8-7e03-4995-9704-d5388dc2b75f" />

Work in progress. Try it: download `Itsytunes.zip` from [Releases](https://github.com/AdamSzakal/Itsytunes/releases).

## Features

**Library**
- Plays every song in one folder and its subfolders. Works with Dropbox and iCloud folders; files that are only online are skipped unless you turn them on in Settings.
- Four views: a song list with columns you can sort, move and hide, albums with their covers, artists with their albums, or playlists. A compilation stays one album.
- Filter to show only songs from Bandcamp, songs downloaded on this Mac, or songs that are only online in Dropbox.
- Search with ⌘F. Click a cover to see it full size.

**Playlists**
- Right-click songs in any view and choose Add to Playlist, or make a new playlist from the selected songs (⇧⌘N).
- Drag songs to change their order, or onto another playlist to add them there. Delete removes the selected songs from their playlist.
- Repeat plays a playlist over and over.
- Each playlist is an .m3u8 file in the Playlists folder of your music folder, so it syncs with Dropbox or iCloud and other players can open it. A song that was renamed or moved is found again by its artist, title and length.

**Tags**
- Fills in missing title, artist, album, year, genre, track number and cover from the iTunes catalogue. MP3 files get the tags written into them.
- Cleans up titles: removes upload noise like video IDs, "(Official Video)" and track numbers. You check each change before it is saved.
- Fix Tags looks up selected songs or albums online again.
- Edit the tags of many songs at once (⌘I). Select them with ⌘-click and ⇧-click in every view; a selected album or artist includes all its songs.
- Find and replace text in one tag of the selected songs, as plain text or with a regular expression (`\d+` finds any number), with a preview of the new tags. Only the songs that change are written.

**YouTube** (⌘K)
- Search YouTube and save the audio of a video into your folder.
- A full album becomes one song per track: split by the video's chapters, by a tracklist in the description, or by the album's song lengths in the iTunes catalogue.
- New songs are selected in the list when they are ready.

**Bandcamp**
- Sign in with Bandcamp's own login page, then choose File › Sync Bandcamp to download your purchases. Later syncs get only new ones.
- Pick the format in Settings: MP3 320, MP3 V0, FLAC, AAC or Apple Lossless.
- Songs bought on Bandcamp show a small Bandcamp mark. Click it to open the artist's page.

**Playback**
- Shuffle, repeat, and the keyboard's play key. Shows in the macOS Now Playing controls.
- Keeps playing when the window is closed.

## Build

Requires macOS 14 and Xcode.

```sh
./scripts/build-app.sh
open "build/Itsytunes.app"
```

YouTube downloads need `brew install yt-dlp ffmpeg` and a YouTube Data API key (Settings). The YouTube API key and the Bandcamp sign-in are kept in your Keychain.
