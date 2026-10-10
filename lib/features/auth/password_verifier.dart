import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

/// Lets a user who has signed in online on this device at least once unlock
/// the app again with no network. Only a salted PBKDF2-HMAC-SHA256 hash is
/// kept (in the platform keystore) — never the password itself.
class PasswordVerifier {
  const PasswordVerifier({required this.userId, required this.salt, required this.hash, required this.iterations});

  final String userId;
  final String salt;
  final String hash;
  final int iterations;

  static const defaultIterations = 20000;

  static PasswordVerifier create(String userId, String password, {int iterations = defaultIterations}) {
    final rnd = Random.secure();
    final salt = base64Encode(List<int>.generate(16, (_) => rnd.nextInt(256)));
    return PasswordVerifier(
        userId: userId, salt: salt, hash: _derive(password, salt, iterations), iterations: iterations);
  }

  bool verify(String password) => _constantTimeEquals(_derive(password, salt, iterations), hash);

  Map<String, dynamic> toJson() => {'userId': userId, 'salt': salt, 'hash': hash, 'iterations': iterations};

  factory PasswordVerifier.fromJson(Map<String, dynamic> j) => PasswordVerifier(
        userId: j['userId'] as String,
        salt: j['salt'] as String,
        hash: j['hash'] as String,
        iterations: j['iterations'] as int,
      );

  /// PBKDF2 with a single 32-byte block (dkLen == HMAC-SHA256 output size).
  static String _derive(String password, String salt, int iterations) {
    final hmac = Hmac(sha256, utf8.encode(password));
    final saltBytes = base64Decode(salt);
    var u = hmac.convert(Uint8List.fromList([...saltBytes, 0, 0, 0, 1])).bytes;
    final out = Uint8List.fromList(u);
    for (var i = 1; i < iterations; i++) {
      u = hmac.convert(u).bytes;
      for (var j = 0; j < out.length; j++) {
        out[j] ^= u[j];
      }
    }
    return base64Encode(out);
  }

  static bool _constantTimeEquals(String a, String b) {
    if (a.length != b.length) return false;
    var diff = 0;
    for (var i = 0; i < a.length; i++) {
      diff |= a.codeUnitAt(i) ^ b.codeUnitAt(i);
    }
    return diff == 0;
  }
}
