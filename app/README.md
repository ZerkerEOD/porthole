# Porthole app

Flutter app for Android and iOS (Linux desktop for development). See the
repository README for what Porthole is.

## Develop

```sh
flutter pub get
flutter run -d linux --dart-define=PH_NO_SPLASH=true --dart-define=PH_DEMO=true   # demo machine, no daemon needed
flutter analyze && flutter test
```

`scripts/dev-smoke.sh` in the repository root starts a daemon for the
integration test in `integration_test/`.

## Store builds

Build-time values live in `dart_defines/store.json` (Firebase client options,
not secrets). Release signing on Android reads `android/key.properties`
(gitignored; `storeFile=upload.jks`). iOS is archived by fastlane on a Mac
(`ios/fastlane`), signed through match. `Jenkinsfile.mobile` in the
repository root runs both.

```sh
flutter build appbundle --release --dart-define-from-file=dart_defines/store.json
cd ios && bundle exec fastlane build build_number:auto && bundle exec fastlane testflight_upload
```

Icons are generated from `assets/icon/*.svg` with
`dart run flutter_launcher_icons` (config in `pubspec.yaml`).
