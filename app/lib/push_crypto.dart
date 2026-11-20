/// Key agreement with the daemon (X25519 + HKDF-SHA256) and XChaCha20-Poly1305
/// decryption of push payloads. Mirrors daemon/internal/push.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

class PushKeys {
  PushKeys._(this._keyPair, this.publicKeyB64);
  final SimpleKeyPair _keyPair;
  final String publicKeyB64;

  static Future<PushKeys> generate() async {
    final kp = await X25519().newKeyPair();
    final pub = await kp.extractPublicKey();
    return PushKeys._(kp, base64Url.encode(pub.bytes).replaceAll('=', ''));
  }

  /// Derives the shared push key from the daemon's public key (base64url).
  Future<Uint8List> derive(String daemonPubB64) async {
    final padded = daemonPubB64.padRight(daemonPubB64.length + (4 - daemonPubB64.length % 4) % 4, '=');
    final peer = SimplePublicKey(base64Url.decode(padded), type: KeyPairType.x25519);
    final shared = await X25519().sharedSecretKey(keyPair: _keyPair, remotePublicKey: peer);
    final hkdf = Hkdf(hmac: Hmac.sha256(), outputLength: 32);
    final key = await hkdf.deriveKey(secretKey: shared, info: utf8.encode('porthole-push-v1'));
    return Uint8List.fromList(await key.extractBytes());
  }
}

/// Decrypts nonce||ciphertext produced by the daemon.
Future<Map<String, dynamic>?> decryptNotice(Uint8List key, String ctB64) async {
  try {
    final padded = ctB64.padRight(ctB64.length + (4 - ctB64.length % 4) % 4, '=');
    final sealed = base64Url.decode(padded);
    const nonceLen = 24;
    const macLen = 16;
    if (sealed.length < nonceLen + macLen) return null;
    final algo = Xchacha20.poly1305Aead();
    final box = SecretBox(
      sealed.sublist(nonceLen, sealed.length - macLen),
      nonce: sealed.sublist(0, nonceLen),
      mac: Mac(sealed.sublist(sealed.length - macLen)),
    );
    final pt = await algo.decrypt(box, secretKey: SecretKey(key));
    return jsonDecode(utf8.decode(pt)) as Map<String, dynamic>;
  } catch (_) {
    return null;
  }
}
