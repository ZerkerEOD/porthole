import 'package:flutter_test/flutter_test.dart';
import 'package:porthole/widgets/event_tile.dart';

void main() {
  test('lines that end in an operator or open a compound command are not joined for !', () {
    expect(bangCommand('cd x\ngo build ./...'), 'cd x && go build ./...');
    expect(bangCommand('for f in *; do\n  echo \$f\ndone'), isNull);
    expect(bangCommand('cd x;\nls'), isNull);
    expect(bangCommand('make &&\nmake test'), isNull);
    expect(bangCommand('if true; then\n echo y\nfi'), isNull);
    expect(bangCommand('sleep 1 &\nwait'), isNull);
    expect(bangCommand('git status'), 'git status');
  });
}
