// Disk cache for bot avatars. The gateway stores one avatar per profile and
// returns it over the socket on every connect; a phone that keeps the bytes
// paints the roster instantly and only re-asks once the entry ages out.
import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';

class NgAvatarCache {
  NgAvatarCache._();

  static const Duration maxAge = Duration(days: 7);

  static Future<Directory> _dir() async {
    final base = await getApplicationSupportDirectory();
    final dir = Directory('${base.path}/ng-avatars');
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  static String _key(String connectionId, String name) {
    final conn = connectionId.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
    final bot = name.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
    return '$conn-$bot.img';
  }

  static Future<Uint8List?> read(String connectionId, String name) async {
    try {
      final file = File('${(await _dir()).path}/${_key(connectionId, name)}');
      if (!await file.exists()) return null;
      final stat = await file.stat();
      if (DateTime.now().difference(stat.modified) > maxAge) return null;
      final bytes = await file.readAsBytes();
      return bytes.isEmpty ? null : bytes;
    } catch (_) {
      return null;
    }
  }

  static Future<void> write(
    String connectionId,
    String name,
    Uint8List bytes,
  ) async {
    if (bytes.isEmpty) return;
    try {
      final file = File('${(await _dir()).path}/${_key(connectionId, name)}');
      await file.writeAsBytes(bytes, flush: true);
    } catch (_) {
      // A cache miss is cheaper than a broken roster.
    }
  }

  static Future<void> remove(String connectionId, String name) async {
    try {
      final file = File('${(await _dir()).path}/${_key(connectionId, name)}');
      if (await file.exists()) await file.delete();
    } catch (_) {
      // Nothing to do: the stale file ages out.
    }
  }
}
