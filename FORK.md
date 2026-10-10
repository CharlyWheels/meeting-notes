# CharlyWheels fork

This `local` branch is what runs on Carlos's Mac: upstream Meeting Notes plus
features not yet released upstream, built from source.

- `feature/auto-record-video-calls` — automatic recording for Teams/Zoom
  (upstream PR: https://github.com/foeken/meeting-notes/pull/20).
- Sparkle automatic updates are off and the feed points at an empty
  `appcast-local.xml`, so an upstream release never replaces this build.

## Updating

```sh
git fetch upstream
git checkout local
git merge upstream/main          # once the PR is merged, the feature comes from upstream
MEETING_NOTES_CODE_SIGN_IDENTITY=- ./scripts/stable-build.sh
```

`stable-build.sh` refuses to run while a meeting is being recorded. The app is
ad-hoc signed (no Apple Development certificate); its designated requirement
is the bundle id, so macOS keeps the granted permissions across rebuilds.

If the PR is merged and released, going back to the official app is enough:
download the release DMG into /Applications and stop using this folder.
