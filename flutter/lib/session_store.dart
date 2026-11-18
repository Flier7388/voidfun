// Disk persistence for the logged-in session, so the app doesn't need a
// fresh username/password login on every launch. The sqlite store
// (E2EE keys, room cache — owned entirely by matrix-sdk-sqlite) lives
// next to the session file in the same app-support directory, so a
// restored session always sees the store it was created against.
import 'dart:convert';
import 'dart:io';

import 'package:matrix_client/src/rust/api/matrix.dart';
import 'package:path_provider/path_provider.dart';

Future<Directory> _appDataDir() async {
  final dir = await getApplicationSupportDirectory();
  if (!await dir.exists()) await dir.create(recursive: true);
  return dir;
}

/// Directory handed to `login`/`restoreSession` as `storePath` for the
/// native `matrix-sdk-sqlite` store.
Future<String> sqliteStorePath() async => '${(await _appDataDir()).path}/store';

Future<File> _sessionFile() async =>
    File('${(await _appDataDir()).path}/session.json');

/// Saves `session` to disk, overwriting any previously-saved session.
Future<void> saveSession(Session session) async {
  final file = await _sessionFile();
  await file.writeAsString(
    jsonEncode({
      'homeserverUrl': session.homeserverUrl,
      'userId': session.userId,
      'deviceId': session.deviceId,
      'accessToken': session.accessToken,
      'refreshToken': session.refreshToken,
    }),
  );
}

/// Loads a previously-saved session, or `null` if none was saved (or it
/// couldn't be parsed — a corrupt file shouldn't block startup).
Future<Session?> loadSession() async {
  final file = await _sessionFile();
  if (!await file.exists()) return null;
  try {
    final json = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
    return Session(
      homeserverUrl: json['homeserverUrl'] as String,
      userId: json['userId'] as String,
      deviceId: json['deviceId'] as String,
      accessToken: json['accessToken'] as String,
      refreshToken: json['refreshToken'] as String?,
    );
  } catch (_) {
    return null;
  }
}

/// Deletes the saved session, if any — called on logout, or after a
/// restore attempt fails (an expired/revoked token shouldn't be retried
/// forever on every launch). Also wipes the `matrix-sdk-sqlite` store
/// directory: it's keyed to the account/device that created it, and
/// `sqliteStorePath()` always returns the same fixed path regardless of
/// which account logs in next — leaving it behind makes every
/// subsequent login (same account *or* a different one) fail with
/// matrix-sdk's own "account in the store doesn't match the account in
/// the constructor" guard, since the store refuses to open under a
/// mismatched account/device (verified live 2026-11-10: logging out
/// then back in, or logging in as a different user entirely, both hit
/// this).
Future<void> clearSession() async {
  final file = await _sessionFile();
  if (await file.exists()) await file.delete();
  final store = Directory(await sqliteStorePath());
  if (!await store.exists()) return;
  // On Windows, a just-dropped `MatrixClient`'s background tasks (e.g.
  // `matrix-sdk-ui`'s `SpaceService`, which only `abort_on_drop`s its
  // room-update task rather than awaiting its exit) can still hold a
  // SQLite file handle open for a brief window after `dispose()`
  // returns. A delete attempted in that window hits a sharing
  // violation partway through and — found via a real repro — leaves a
  // *partially* deleted, corrupted store that then hangs (not errors)
  // on the next open attempt, even across a full process restart, since
  // nothing before this retried past that one bad attempt. A few
  // retries with backoff ride out the transient lock instead of
  // corrupting the store.
  for (var attempt = 0; attempt < 5; attempt++) {
    try {
      await store.delete(recursive: true);
      return;
    } on FileSystemException {
      if (attempt == 4) rethrow;
      await Future.delayed(Duration(milliseconds: 200 * (attempt + 1)));
    }
  }
}
