import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Where a chat opens.
enum OpenAt {
  lastRead('last_read', 'Last read position', 'Where you left off, with new messages below.'),
  lastMessage('last_message', 'Top of the last message', "The start of Claude's latest reply."),
  bottom('bottom', 'Bottom', 'The newest message.');

  const OpenAt(this.value, this.label, this.description);
  final String value, label, description;

  static OpenAt byValue(String? v) => OpenAt.values.where((o) => o.value == v).firstOrNull ?? OpenAt.bottom;
}

/// Chat preferences kept on this phone, read synchronously by the session
/// screen once [load] has run.
class ChatPrefs extends ChangeNotifier {
  static const openAtKey = 'chat.open_at';

  OpenAt openAt = OpenAt.bottom;

  Future<void> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      openAt = OpenAt.byValue(prefs.getString(openAtKey));
      notifyListeners();
    } catch (_) {}
  }

  Future<void> setOpenAt(OpenAt v) async {
    if (v == openAt) return;
    openAt = v;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(openAtKey, v.value);
    } catch (_) {}
  }
}
