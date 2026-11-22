# Build the app yourself

## When you need this

A push token belongs to the Firebase project the app was built with, and the
relay can only send to tokens of the project its service account comes from
(`relay/src/index.ts` posts to
`https://fcm.googleapis.com/v1/projects/<project>/messages:send`, where
`<project>` is `FCM_PROJECT_ID` or the service account's `project_id`). So the
app build and the relay must use the same Firebase project. The store builds
carry the project's own Firebase options, which means they only work with the
hosted relay. To use [your own relay](relay.md), build the app with your own
Firebase project as described here.

If you do not want push at all, build without `--dart-define-from-file`: the
app then has no **Push relay** field in Settings and everything else works
(see [Builds without push](../guide/push.md#builds-without-push)).

## Prerequisites

| Platform | Needs |
|---|---|
| Both | Flutter with Dart 3.11.4 or later (`environment.sdk` in `app/pubspec.yaml`), a clone of the repository |
| Android | Java 17 (`compileOptions` in `app/android/app/build.gradle.kts`), an Android SDK; the app targets API 26 and up (`minSdk`) |
| iOS | A Mac with Xcode and CocoaPods (`app/ios/Podfile`, iOS 15 and up), and an Apple Developer Program membership: the App ID's Push Notifications capability and the APNs key are registered under it |

## Pick your own app id and name

`io.zerkersec.porthole` is the project's own id. Firebase registers apps by
id, so choose your own (for example `com.example.myremote`) and set it in
every place below before you register anything with Apple or Firebase.

| File | Change |
|---|---|
| `app/android/app/build.gradle.kts` | `namespace` (line 19) and `applicationId` (line 35) |
| `app/android/app/src/main/kotlin/io/zerkersec/porthole/MainActivity.kt` | the `package` line; move the file to the matching directory |
| `app/ios/Runner.xcodeproj/project.pbxproj` | the three `PRODUCT_BUNDLE_IDENTIFIER = io.zerkersec.porthole;` lines (the Runner target); the `RunnerTests` entries follow the same prefix |
| `app/android/app/src/main/AndroidManifest.xml` | `android:label` |
| `app/ios/Runner/Info.plist` | `CFBundleDisplayName` and `CFBundleName` |

The name and icon are covered by `TRADEMARKS.md`: a modified build may not be
published under the Porthole name or icon, so a fork picks its own. Icons are
generated from `app/assets/icon/*.svg` with `dart run flutter_launcher_icons`
(see `app/README.md`).

## Apple (iOS only)

At developer.apple.com, Certificates, Identifiers & Profiles:

1. Identifiers, +, App IDs, App. Bundle ID explicit, your id from above, tick
   **Push Notifications**, Register.
2. Keys, +, tick **Apple Push Notifications service (APNs)**, Continue,
   Register, Download. The file is `AuthKey_<KEYID>.p8` and can be downloaded
   only once; keep the Key ID.
3. Membership details: note the 10-character Team ID. Firebase asks for it
   with the APNs key.

## Firebase

At console.firebase.google.com:

1. Create a project. Google Analytics is not needed.
2. Project Overview, Add app, Android. Package name: your Android
   `applicationId`. Register, then **Download google-services.json**.
3. Add app, iOS. Bundle ID: your iOS bundle id. Register, then **Download
   GoogleService-Info.plist**.
4. iOS only: Project settings (gear), Cloud Messaging, Apple app
   configuration, APNs Authentication Key, Upload the `.p8` with its Key ID and
   your Team ID.
5. Project settings, Service accounts, Firebase Admin SDK, **Generate new
   private key**. This JSON file is the relay's `FCM_SERVICE_ACCOUNT`.

The two config files are not read by the build. There is no google-services
Gradle plugin in `app/android/app/build.gradle.kts` and no plist in the Xcode
project; `app/lib/push.dart` builds `FirebaseOptions` from the values below.
Both file names are gitignored, so keep them outside the checkout and copy
values out of them.

## store.json

```sh
cd app
cp dart_defines/store.example.json dart_defines/store.json
```

`dart_defines/store.json` is gitignored. Fill each key from the config files
(`app/lib/config.dart` reads them with `String.fromEnvironment`):

| Key | Used on | Source |
|---|---|---|
| `FB_API_KEY` | Android | `google-services.json`: `client[].api_key[].current_key` |
| `FB_APP_ID` | Android | `google-services.json`: `client[].client_info.mobilesdk_app_id` (the `1:…:android:…` value) |
| `FB_IOS_API_KEY` | iOS | `GoogleService-Info.plist`: `API_KEY` |
| `FB_IOS_APP_ID` | iOS | `GoogleService-Info.plist`: `GOOGLE_APP_ID` (the `1:…:ios:…` value) |
| `FB_SENDER_ID` | both | `google-services.json`: `project_info.project_number`, the same as the plist's `GCM_SENDER_ID` |
| `FB_PROJECT_ID` | both | `google-services.json`: `project_info.project_id`, the same as the plist's `PROJECT_ID` |
| `FB_IOS_BUNDLE_ID` | iOS | `GoogleService-Info.plist`: `BUNDLE_ID` (your iOS bundle id) |

If `google-services.json` lists several `client` entries, take the one whose
`client_info.android_client_info.package_name` is your `applicationId`. The
app treats itself as push capable when the API key, app id, sender id and
project id for the running platform are all set (`pushCapable` in
`app/lib/config.dart`); an Android-only build can leave the three `FB_IOS_*`
keys empty, and an iOS-only build can leave `FB_API_KEY` and `FB_APP_ID`
empty.

## Build

### Android

```sh
cd app
flutter pub get
flutter build apk --release --dart-define-from-file=dart_defines/store.json
adb install build/app/outputs/flutter-apk/app-release.apk
```

Without `android/key.properties` the release build is signed with the debug
key (`buildTypes.release` in `app/android/app/build.gradle.kts`), which is
enough to install on your own phone. To sign with your own keystore, create
`app/android/key.properties` (gitignored) with the four keys the build reads:

```properties
storeFile=upload.jks
storePassword=…
keyAlias=upload
keyPassword=…
```

`storeFile` is resolved relative to `app/android/`.

### iOS

Open `app/ios/Runner.xcworkspace` in Xcode once, select the Runner target,
Signing & Capabilities, and choose your team; signing is set to Automatic in
the project. `app/ios/Runner/Runner.entitlements` already carries
`aps-environment`, which needs the Push Notifications capability on the App
ID registered above. Then either run straight onto a connected phone:

```sh
cd app
flutter pub get
flutter run --release --dart-define-from-file=dart_defines/store.json
```

or build an archive to distribute through TestFlight or ad hoc:

```sh
flutter build ipa --release --dart-define-from-file=dart_defines/store.json
```

## Relay with the same project

Deploy the relay as described in [Deploy](relay.md#deploy), with the service
account JSON from step 5 above as `FCM_SERVICE_ACCOUNT`. It must come from the
Firebase project in `store.json`; a service account from any other project
cannot send to this build's tokens.

Mint a relay credential. `normalizeKey` in `relay/src/entitlement.ts` accepts
`PH-` followed by four groups of four characters from `A-Z0-9`; the relay
compares the SHA-256 hex of the credential against `ENTITLEMENT_STATIC_KEYS`:

```sh
KEY="PH-$(LC_ALL=C tr -dc 'A-Z0-9' < /dev/urandom | head -c 16 | sed 's/.\{4\}/&-/g;s/-$//')"
echo "$KEY"                                   # goes into the app's relay URL
printf '%s' "$KEY" | sha256sum | cut -d' ' -f1   # goes into ENTITLEMENT_STATIC_KEYS
```

In `relay/wrangler.jsonc`:

| Field | Set to |
|---|---|
| `routes` | remove the entry; it is the project's custom domain. The Worker is then served at `<name>.<account>.workers.dev` |
| `kv_namespaces[0].id` | the id printed by `npx wrangler kv namespace create DENY` |
| `vars.FCM_PROJECT_ID` | your Firebase project id, or leave `""` to read `project_id` from the service account |
| `vars.ANDROID_PACKAGE` | your Android `applicationId` (only used when `ATTEST_MODE` is `android` or `all`) |
| `vars.ENTITLEMENT_URL` | `""` unless you run your own entitlement service. The committed value points at the project's service; with that value and an `ENTITLEMENT_SECRET` set, the relay asks that service and never consults `ENTITLEMENT_STATIC_KEYS` |
| `vars.ENTITLEMENT_STATIC_KEYS` | the SHA-256 hex from above; several credentials are separated by commas |

With `ENTITLEMENT_STATIC_KEYS` you do not need `ENTITLEMENT_SECRET`.

## Connect

1. Phone: **Settings → Push relay**, paste `https://<KEY>@<your-worker>.workers.dev`.
2. Each machine: set `[push] relay_url` to the base URL without the credential and restart the daemon.

Both steps are described in [Push notifications](../guide/push.md#use-the-hosted-relay).

## Troubleshooting

**"Relay: not active" and the relay log says `no entitlement source configured`**
:   Neither `ENTITLEMENT_URL` + `ENTITLEMENT_SECRET` nor
    `ENTITLEMENT_STATIC_KEYS` is set (`checkEntitlement` in
    `relay/src/entitlement.ts`). Set `ENTITLEMENT_STATIC_KEYS` and redeploy.

**"Relay: not active" and the relay log says `unknown credential`**
:   The credential's hash is not in `ENTITLEMENT_STATIC_KEYS`, or
    `ENTITLEMENT_URL` is still the committed value so the relay asked the
    project's entitlement service instead. Hash the credential again with
    `printf '%s'` (no trailing newline) and check `ENTITLEMENT_URL` is `""`.

**The relay is connected but the daemon log shows `push failed` with `(410)` or `relay returned 502`**
:   The relay could not deliver to the token. It answers 410 `push token gone`
    when FCM returns 400 or 404 and 502 `fcm <status>` for any other FCM
    error (`handlePush` in `relay/src/index.ts`); on 410 the daemon drops
    the grant for that device. The usual cause is a project mismatch: the
    app was built with one Firebase project's `store.json` and the relay's
    `FCM_SERVICE_ACCOUNT` belongs to another. A store build with your own
    relay fails the same way. Rebuild the app from the project the service
    account comes from.

**iOS never gets a push token**
:   See ["Apple has not issued this phone a push token
    yet"](../reference/troubleshooting.md#notifications). For a self-built
    app also confirm the APNs key is uploaded in Cloud Messaging and the App
    ID has the Push Notifications capability.
