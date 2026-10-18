# LocalLoom

A macOS menu bar app that records your screen and puts a share link on your clipboard
when you stop (Cmd+Shift+L).

## Two ways to share

**This Mac (via ngrok).** No server to run. The app keeps recordings on your Mac and
shares them through your own ngrok account. Links only work while your Mac is awake and
online, and ngrok's free plan shows viewers a warning page and caps bandwidth.

**My server.** Recordings upload to a [localloom-server](server/README.md) you host, in a
homelab or on your own cloud machine, so links keep working when your Mac is off. Uploads
happen in the background. The link is copied right away and starts playing once the
upload finishes.

Pick one under **Preferences → Destination**. Each recording stays with the destination
it was made with, so switching later doesn't move existing links.

## Build

Requires Xcode (or the Swift toolchain) and an internet connection for the first build.

```sh
./make-app.sh            # builds LocalLoom.app; add --sign "Developer ID ..." to sign
open LocalLoom.app
```

`make-app.sh` downloads a pinned, checksum-verified Node.js and bundles it with the server,
which the app runs privately on 127.0.0.1 in "This Mac" mode. It builds for your Mac's
architecture only. Install ngrok with `brew install ngrok` or place the binary at
`Sources/LocalLoom/Resources/ngrok`.

Tokens are kept in your login keychain. Builds signed ad hoc (the default) get a new
signature each time, so macOS may ask once after each rebuild for keychain access, and
again for screen recording permission.

## Tests

```sh
cd server && npm test   # server
swift test              # app's server client, run against the real server (needs node on PATH)
```
