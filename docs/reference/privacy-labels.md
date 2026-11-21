# Store privacy answers

Maintainer answer sheet for App Store Connect (App Privacy) and Google Play Console (Data safety), kept in
step with <https://zerkersec.io/privacy>. Update both forms whenever section 6 or 7 of the policy
changes. Last reviewed 2026-11-12.

## Shared facts

- Privacy policy URL: `https://zerkersec.io/privacy`. Terms: `https://zerkersec.io/terms`.
- In-app link: Settings → "Privacy policy" and "Terms of service" (`app/lib/screens/settings.dart`).
- No accounts in the app. No in-app purchases. No ads. No analytics or crash-reporting SDK. The
  app has a built-in demo machine ("Try the demo" on the first screen) that reviewers can use.
- Third-party SDKs that touch the network: Firebase Core + Firebase Messaging (push token only;
  analytics deactivated in `AndroidManifest.xml` and `Info.plist`). `mobile_scanner` scans QR codes
  on device; on Android it uses Google ML Kit's barcode model, which processes frames locally.
- Permissions: INTERNET, CAMERA (QR pairing), POST_NOTIFICATIONS, FOREGROUND_SERVICE and
  FOREGROUND_SERVICE_DATA_SYNC (keeps the VPN socket alive while a session is open). iOS:
  NSCameraUsageDescription.
- Data the app sends to the developer's servers: only when the user pastes a relay URL for the
  developer-hosted relay and turns push on. Then the relay receives the credential from that URL,
  a random device id, platform and the push token, and the daemon later sends encrypted notices the
  relay cannot read. The relay operator (the developer, for the hosted relay) links the device id
  to the website account the credential belongs to. Users who paste their own relay's URL send
  nothing to the developer. Everything else stays between the phone and the user's own computer
  over their VPN.
- The developer account is an individual. Apple shows the legal name as the seller; Google shows the
  legal name, country and developer email. No address is shown because the app is free with no
  in-app purchases, so there is no "monetised" trigger.

## Apple: App Privacy (App Store Connect)

| Question | Answer |
|---|---|
| Do you or your third-party partners collect data from this app? | Yes |
| Contact Info | Not collected (the supporter email is handled on the website, not in the app) |
| Identifiers → Device ID | Collected. Linked to the user: **Yes** (the hosted relay records the device id against the website account whose credential was used). Used for tracking: **No**. Purpose: App Functionality. (The random push device id and the push token, sent to the relay only when push is on.) |
| User Content, Usage Data, Diagnostics, Location, Financial, Health, Browsing, Search, Purchases, Contacts, Sensitive Info | Not collected |
| Tracking | No. `NSPrivacyTracking` is false in `app/ios/Runner/PrivacyInfo.xcprivacy`. |
| Privacy manifest | `app/ios/Runner/PrivacyInfo.xcprivacy`: DeviceID collected, linked, App Functionality; UserDefaults accessed for reason CA92.1. |

Note: the camera is used for QR scanning only; images are not collected, so no Photos or Videos
data type applies.

## Google: Data safety (Play Console)

| Section | Answer |
|---|---|
| Does your app collect or share any of the required user data types? | Yes |
| Is all user data encrypted in transit? | Yes (TLS to the daemon with certificate pinning; HTTPS to the relay) |
| Do you provide a way for users to request data deletion? | Yes: remove the relay in Settings, unpair the phone on the daemon, delete the account at zerkersec.io/supporter (hosted relay users), or email privacy@zerkersec.io |
| Device or other IDs | Collected: yes. Shared: yes, with Google (FCM push token) as a service provider. Ephemeral: no. Required: optional (only when push is enabled). Purpose: App functionality. |
| App activity, App info and performance (crash logs, diagnostics), Personal info, Financial, Location, Messages, Photos and videos, Audio, Files, Calendar, Contacts, Health | Not collected |
| Does the app use any security practices? | Data encrypted in transit; users can request deletion; follows the Families policy: not applicable (not directed at children) |
| Independent security review | No |

Camera: used for QR codes only, frames are processed on device and discarded; nothing to declare
under Photos and videos.

## Other console answers

- Encryption / export compliance (Apple): the app uses only standard, published algorithms (TLS,
  X25519, HKDF-SHA256, XChaCha20-Poly1305) for its own protocol, so `ITSAppUsesNonExemptEncryption`
  is `false` in `Info.plist`. Aaron confirms the exemption reading and files the annual
  self-classification report with BIS if it applies to him.
- Foreground service (Play, `dataSync`): "Keeps the connection to the user's own computer open while
  they watch a session, so prompts arrive without a cloud service. Started only from the Settings
  switch, stopped from the same switch or by closing the app." Attach the demo recording.
- IP addresses: Cloudflare's short-lived request logs apply to the relay (policy section 3); not a
  collected data type in either form.

## Keep these in sync

- `zerkersec.io/privacy` sections 6 and 7 (what the app and relay keep).
- `app/ios/Runner/PrivacyInfo.xcprivacy` (collected data types and required-reason APIs).
- `app/android/app/src/main/AndroidManifest.xml` (analytics flags, permissions).
- This file, and the two store forms.
