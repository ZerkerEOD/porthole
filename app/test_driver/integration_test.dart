// Host-side driver for `flutter drive --driver=test_driver/integration_test.dart`.
// Screenshots the test takes with binding.takeScreenshot(name) are written to
// build/screenshots/<name>.png, relative to the app directory.
import 'dart:io';

import 'package:integration_test/integration_test_driver_extended.dart';

Future<void> main() async {
  await integrationDriver(
    onScreenshot: (String name, List<int> bytes, [Map<String, Object?>? args]) async {
      final file = File('build/screenshots/$name.png');
      file.parent.createSync(recursive: true);
      file.writeAsBytesSync(bytes);
      return true;
    },
  );
}
