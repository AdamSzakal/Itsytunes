# Elan Player

A small macOS music player for a local folder. It tags songs and fetches album art automatically, and can save audio from YouTube.

Work in progress. Try it: download `ElanPlayer.zip` from [Releases](https://github.com/AdamSzakal/TinyPlayer/releases).

## Build

Requires macOS 14 and Xcode.

```sh
./scripts/build-app.sh
open "build/Elan Player.app"
```

YouTube downloads need `brew install yt-dlp ffmpeg` and a YouTube Data API key (Settings).
