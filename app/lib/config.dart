/// Build-time configuration. Everything here is non-secret and set with
/// --dart-define (or --dart-define-from-file=dart_defines/store.json); the
/// defaults produce a build with push off and no demo machine.
library;

import 'dart:io' show Platform;

class BuildConfig {
  // Android values come from google-services.json, iOS values from GoogleService-Info.plist;
  // the Firebase app id and API key differ per platform, the sender and project do not.
  static const fbApiKey = String.fromEnvironment('FB_API_KEY');
  static const fbAppId = String.fromEnvironment('FB_APP_ID');
  static const fbIosApiKey = String.fromEnvironment('FB_IOS_API_KEY');
  static const fbIosAppId = String.fromEnvironment('FB_IOS_APP_ID');
  static const fbSenderId = String.fromEnvironment('FB_SENDER_ID');
  static const fbProjectId = String.fromEnvironment('FB_PROJECT_ID');
  static const fbIosBundleId = String.fromEnvironment('FB_IOS_BUNDLE_ID');

  /// Where the self-hosting guide lives (linked from Settings).
  static const relayDocsUrl = 'https://github.com/ZerkerEOD/porthole/blob/main/docs/self-host-relay.md';

  /// Adds the built-in demo machine at launch (screenshot runs).
  static const demo = bool.fromEnvironment('PH_DEMO');

  /// Push is only possible when Firebase options are compiled in. The relay
  /// itself is chosen by the user in Settings.
  static String get platformApiKey => Platform.isIOS ? fbIosApiKey : fbApiKey;
  static String get platformAppId => Platform.isIOS ? fbIosAppId : fbAppId;
  static bool get pushCapable => platformApiKey.isNotEmpty && platformAppId.isNotEmpty && fbSenderId.isNotEmpty && fbProjectId.isNotEmpty;
}
