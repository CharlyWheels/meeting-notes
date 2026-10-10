# CharlyWheels fork

This `local` branch is what runs on Carlos's Mac: upstream Meeting Notes plus
features not yet released upstream, built from source.

- Automatic recording for Teams/Zoom (commit "Record Teams and Zoom meetings
  automatically, opt-in"). Not offered upstream.
- No updates: the Sparkle updater is never started, and "Check for Updates…"
  and the update channel setting are removed. As a second guard, automatic
  checks are off in Info.plist and the feed points at an empty
  `appcast-local.xml`.

## Updating

```sh
git fetch upstream
git checkout local
git merge upstream/main
MEETING_NOTES_CODE_SIGN_IDENTITY=- ./scripts/stable-build.sh
```

`stable-build.sh` refuses to run while a meeting is being recorded. The app is
ad-hoc signed (no Apple Development certificate); its designated requirement
is the bundle id, so macOS keeps the granted permissions across rebuilds.

The official 1.3.2 app is kept in `~/Documents/software/backups/` in case of
going back to it.
