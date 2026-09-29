// RT Chat (internal name: Real time chat) - WhatsApp-style realtime chat.
// Backend: Supabase (chat, storage, presence). Auth: Firebase Google sign-in.
// Local persistence: SQLite. Single-file by design; sections are marked.
// ignore_for_file: curly_braces_in_flow_control_structures, use_build_context_synchronously
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate' show ReceivePort;
import 'dart:math' as math;
import 'dart:ui' as ui show FontFeature, IsolateNameServer, PlatformDispatcher, ImageByteFormat, instantiateImageCodec, Image, PathOperation;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:cryptography/cryptography.dart' as cr;
import 'package:file_picker/file_picker.dart';
import 'package:firebase_auth/firebase_auth.dart' as fb;
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:http/http.dart' as http;
import 'package:image_picker/image_picker.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:record/record.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:uuid/uuid.dart';
import 'package:video_player/video_player.dart';

// ───────────────────────── Config ─────────────────────────
class Cfg {
  static const appName = 'RT Chat';
  static const version = '1.1.0';
  // Raw env values (may contain accidental whitespace from secrets UI).
  static const _supabaseUrl = String.fromEnvironment('SUPABASE_URL');
  static const _supabaseAnon = String.fromEnvironment('SUPABASE_ANON_KEY');
  static const _fbApiKey = String.fromEnvironment('FIREBASE_API_KEY');
  static const _fbAppId = String.fromEnvironment('FIREBASE_APP_ID');
  static const _fbProject = String.fromEnvironment('FIREBASE_PROJECT_ID');
  static const _fbSender = String.fromEnvironment('FIREBASE_SENDER_ID');
  static const _webClientId = String.fromEnvironment('GOOGLE_WEB_CLIENT_ID');
  static const _giphyKey = String.fromEnvironment('GIPHY_API_KEY');
  static const _openRouterKey = String.fromEnvironment('OPENROUTER_API_KEY');
  /// Optional comma-separated extra keys for rotation when free tier rate-limits.
  static const _openRouterKeysExtra = String.fromEnvironment('OPENROUTER_API_KEYS');
  static const _openRouterModel = String.fromEnvironment('OPENROUTER_MODEL', defaultValue: 'openrouter/free');
  static const maxUploadMb = int.fromEnvironment('MAX_UPLOAD_MB', defaultValue: 25);
  static const debugPassword = 'pass'; // dev debug log lock (not shown to users)
  static const editWindow = Duration(minutes: 15);
  static const deleteWindow = Duration(hours: 48);
  /// Soft cap on remote media objects for free-tier Supabase (~1 GB). Local copies stay on device.
  static const storageFileSoftLimit = 100;

  static String get supabaseUrl => _supabaseUrl.trim();
  static String get supabaseAnon => _supabaseAnon.trim();
  static String get fbApiKey => _fbApiKey.trim();
  static String get fbAppId => _fbAppId.trim();
  static String get fbProject => _fbProject.trim();
  static String get fbSender => _fbSender.trim();
  static String get webClientId => _webClientId.trim();
  static String get giphyKey => _giphyKey.trim();
  static String get openRouterKey => _openRouterKey.trim();
  static String get openRouterModel =>
      _openRouterModel.trim().isEmpty ? 'openrouter/free' : _openRouterModel.trim();

  /// Primary key + optional extras (comma/newline/space separated).
  static List<String> get openRouterKeys {
    final raw = '$_openRouterKey,$_openRouterKeysExtra';
    final seen = <String>{};
    final out = <String>[];
    for (final part in raw.split(RegExp(r'[,\s]+'))) {
      final k = part.trim();
      if (k.isEmpty || seen.contains(k)) continue;
      seen.add(k);
      out.add(k);
    }
    return out;
  }

  static bool get arteeEnabled => openRouterKeys.isNotEmpty;

  /// Supabase is required. Firebase is optional (Google sign-in not required).
  static bool get configured => supabaseUrl.isNotEmpty && supabaseAnon.isNotEmpty;
  static bool get firebaseConfigured =>
      [fbApiKey, fbAppId, fbProject, fbSender].every((e) => e.isNotEmpty);
}

// ───────────────────────── Local identity (no Google required) ─────────────────────────
/// Stable per-install user id. Name/username live on Supabase as the profile.
class LocalAuth {
  static const _key = 'rt_local_uid';
  static const FlutterSecureStorage _store = FlutterSecureStorage();
  static final Uuid _uuid = Uuid();

  /// Bumped on sign-out / login so AuthGate reloads identity.
  static final ValueNotifier<int> rev = ValueNotifier<int>(0);

  static Future<String?> readUid() async {
    try {
      final v = await _store.read(key: _key);
      if (v != null && v.isNotEmpty) return v;
    } catch (e) {
      DLog.d('auth', 'secure read uid failed: $e');
    }
    return Prefs.sp.getString(_key);
  }

  static Future<void> setUid(String id) async {
    try {
      await _store.write(key: _key, value: id);
    } catch (e) {
      DLog.d('auth', 'secure write uid failed: $e');
    }
    await Prefs.sp.setString(_key, id);
  }

  static Future<String> ensureUid() async {
    final existing = await readUid();
    if (existing != null) return existing;
    final id = _uuid.v4();
    await setUid(id);
    return id;
  }

  static Future<String> newUid() async {
    final id = _uuid.v4();
    await setUid(id);
    return id;
  }

  static Future<void> clear() async {
    try {
      await _store.delete(key: _key);
    } catch (_) {}
    await Prefs.sp.remove(_key);
  }

  /// PIN is 4–8 digits. Hash is SHA-256(pin|uid|pepper).
  static Future<String> hashPin(String pin, String uid) async {
    final h = await cr.Sha256().hash(utf8.encode('$pin|$uid|rt-chat-pin-v1'));
    return base64Encode(h.bytes);
  }
}

// ───────────────────────── Debug log (hidden, password locked) ─────────────────────────
class DLog {
  static final List<String> lines = <String>[];
  static final ValueNotifier<int> tick = ValueNotifier<int>(0);
  static void d(String tag, Object? msg) {
    final t = DateTime.now();
    final s = '${two(t.hour)}:${two(t.minute)}:${two(t.second)}.${t.millisecond.toString().padLeft(3, '0')} [$tag] $msg';
    lines.add(s);
    if (lines.length > 800) lines.removeRange(0, 200);
    tick.value++;
    if (kDebugMode) debugPrint(s);
  }
}

// ───────────────────────── Preferences & theme data ─────────────────────────
const accents = <Color>[
  Color(0xFF00A884),
  Color(0xFF3B82F6),
  Color(0xFF8B5CF6),
  Color(0xFFEF4444),
  Color(0xFFF59E0B),
  Color(0xFFEC4899),
];
const accentNames = ['Green', 'Blue', 'Purple', 'Red', 'Amber', 'Pink'];
// [light, dark] chat backgrounds
const walls = <List<Color>>[
  [Color(0xFFEFEAE2), Color(0xFF0B141A)],
  [Color(0xFFE3F2FD), Color(0xFF0D1B2A)],
  [Color(0xFFF3E5F5), Color(0xFF1A1024)],
  [Color(0xFFE8F5E9), Color(0xFF0F1F14)],
  [Color(0xFFFFFFFF), Color(0xFF000000)],
];
const wallNames = ['Sand', 'Sky', 'Lilac', 'Mint', 'Plain'];

class Prefs {
  static late SharedPreferences sp;
  static final ValueNotifier<int> rev = ValueNotifier<int>(0);
  static int get themeMode => (sp.getInt('theme_mode') ?? 0).clamp(0, 2).toInt(); // 0 system 1 light 2 dark
  static int get accent => (sp.getInt('accent') ?? 0).clamp(0, accents.length - 1).toInt();
  static int get wall => (sp.getInt('wall') ?? 0).clamp(0, walls.length - 1).toInt();
  static bool get lowData => sp.getBool('low_data') ?? false;
  static List<String> get customStickers => List<String>.from(sp.getStringList('custom_stickers') ?? const <String>[]);
  static Future<void> setCustomStickers(List<String> paths) async {
    await sp.setStringList('custom_stickers', paths);
    rev.value++;
  }

  static Future<void> setInt(String k, int v) async {
    await sp.setInt(k, v);
    rev.value++;
  }

  static Future<void> setBool(String k, bool v) async {
    await sp.setBool(k, v);
    rev.value++;
  }
}

/// Custom image stickers stored under app documents.
class StickerStore {
  static Future<Directory> _dir() async {
    final root = await getApplicationDocumentsDirectory();
    final d = Directory(p.join(root.path, 'stickers'));
    if (!await d.exists()) await d.create(recursive: true);
    return d;
  }

  static Future<String?> importFromPath(String srcPath) async {
    try {
      final f = File(srcPath);
      if (!await f.exists()) return null;
      final dir = await _dir();
      final name = 'stk_${DateTime.now().millisecondsSinceEpoch}${p.extension(srcPath).isEmpty ? '.png' : p.extension(srcPath)}';
      final dest = p.join(dir.path, name);
      await f.copy(dest);
      final list = Prefs.customStickers.toList();
      list.insert(0, dest);
      // Cap library size
      while (list.length > 80) {
        final old = list.removeLast();
        try {
          await File(old).delete();
        } catch (_) {}
      }
      await Prefs.setCustomStickers(list);
      return dest;
    } catch (e) {
      DLog.d('sticker', '$e');
      return null;
    }
  }

  static Future<void> remove(String path) async {
    final list = Prefs.customStickers.where((e) => e != path).toList();
    await Prefs.setCustomStickers(list);
    try {
      await File(path).delete();
    } catch (_) {}
  }
}

// ───────────────────────── Utilities ─────────────────────────
String two(int n) => n.toString().padLeft(2, '0');
int _i(Object? v) => v is num ? v.toInt() : int.tryParse('${v ?? ''}') ?? 0;
bool _b(Object? v) => v == true || v == 1;
int _isoMs(Object? v) => DateTime.tryParse('${v ?? ''}')?.millisecondsSinceEpoch ?? 0;
int nowMs() => DateTime.now().millisecondsSinceEpoch;

String fmtTime(int ts) {
  final d = DateTime.fromMillisecondsSinceEpoch(ts);
  final h = d.hour % 12 == 0 ? 12 : d.hour % 12;
  return '$h:${two(d.minute)} ${d.hour < 12 ? 'am' : 'pm'}';
}

bool sameDay(int a, int b) {
  final x = DateTime.fromMillisecondsSinceEpoch(a), y = DateTime.fromMillisecondsSinceEpoch(b);
  return x.year == y.year && x.month == y.month && x.day == y.day;
}

String dayLabel(int ts) {
  final now = nowMs();
  if (sameDay(ts, now)) return 'Today';
  if (sameDay(ts, now - 86400000)) return 'Yesterday';
  final d = DateTime.fromMillisecondsSinceEpoch(ts);
  return '${d.day}/${d.month}/${d.year}';
}

String listTime(int ts) {
  if (ts == 0) return '';
  final now = nowMs();
  if (sameDay(ts, now)) return fmtTime(ts);
  return dayLabel(ts);
}

String lastSeenText(int ts) => ts == 0 ? '' : 'last seen ${dayLabel(ts).toLowerCase()} at ${fmtTime(ts)}';

String fmtSize(int b) {
  if (b < 1024) return '$b B';
  if (b < 1024 * 1024) return '${(b / 1024).toStringAsFixed(0)} KB';
  return '${(b / 1048576).toStringAsFixed(1)} MB';
}

String mimeOf(String name) {
  final e = p.extension(name).toLowerCase().replaceFirst('.', '');
  const m = {
    'jpg': 'image/jpeg', 'jpeg': 'image/jpeg', 'png': 'image/png', 'gif': 'image/gif', 'webp': 'image/webp',
    'mp4': 'video/mp4', 'mkv': 'video/x-matroska', 'webm': 'video/webm', '3gp': 'video/3gpp', 'mov': 'video/quicktime',
    'mp3': 'audio/mpeg', 'm4a': 'audio/mp4', 'aac': 'audio/aac', 'wav': 'audio/wav', 'ogg': 'audio/ogg', 'opus': 'audio/ogg',
    'pdf': 'application/pdf', 'txt': 'text/plain', 'zip': 'application/zip',
  };
  return m[e] ?? 'application/octet-stream';
}

String kindOfFile(String name) {
  final m = mimeOf(name);
  if (m.startsWith('image/')) return 'image';
  if (m.startsWith('video/')) return 'video';
  if (m.startsWith('audio/')) return 'audio';
  return 'file';
}

String previewOf(Msg m) {
  if (m.delAll) return 'This message was deleted';
  switch (m.kind) {
    case 'image':
      return '📷 Photo';
    case 'video':
      return '🎥 Video';
    case 'audio':
      return '🎤 Voice message';
    case 'gif':
      return 'GIF';
    case 'file':
      return '📄 ${m.mediaName ?? 'File'}';
    default:
      return m.body;
  }
}

String chatTitle(ChatRow c, Map<String, Profile> pm) {
  if (c.isAi) return 'Artee AI';
  if (c.isDirect) return pm[c.peer]?.name ?? 'Chat';
  return c.name.isEmpty ? 'Chat' : c.name;
}

String? chatPhoto(ChatRow c, Map<String, Profile> pm) => c.isDirect ? pm[c.peer]?.photo : c.photo;

void toast(BuildContext c, String s) {
  ScaffoldMessenger.of(c)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(s), duration: const Duration(seconds: 3)));
}

// ───────────────────────── Models ─────────────────────────
class Profile {
  final String uid, username, name;
  final String? photo, about, pubkey;
  final int lastSeen;
  const Profile({required this.uid, required this.username, required this.name, this.photo, this.about, this.pubkey, this.lastSeen = 0});
  factory Profile.server(Map<String, dynamic> m) => Profile(
        uid: m['uid'] as String,
        username: (m['username'] ?? '') as String,
        name: (m['name'] ?? '') as String,
        photo: m['photo'] as String?,
        about: m['about'] as String?,
        pubkey: m['pubkey'] as String?,
        lastSeen: _isoMs(m['last_seen']),
      );
  factory Profile.row(Map<String, Object?> r) => Profile(
        uid: r['uid'] as String,
        username: (r['username'] ?? '') as String,
        name: (r['name'] ?? '') as String,
        photo: r['photo'] as String?,
        about: r['about'] as String?,
        pubkey: r['pubkey'] as String?,
        lastSeen: _i(r['last_seen']),
      );
  Map<String, Object?> toRow() =>
      {'uid': uid, 'username': username, 'name': name, 'photo': photo, 'about': about, 'pubkey': pubkey, 'last_seen': lastSeen};
}

class ChatRow {
  final String id, kind, name;
  final String? photo, owner, peer;
  final int created;
  const ChatRow({required this.id, required this.kind, this.name = '', this.photo, this.owner, this.peer, this.created = 0});
  bool get isDirect => kind == 'direct';
  bool get isGroup => kind == 'group';
  bool get isChannel => kind == 'channel';
  bool get isAi => kind == 'ai';
  factory ChatRow.row(Map<String, Object?> r) => ChatRow(
        id: r['id'] as String,
        kind: (r['kind'] ?? 'direct') as String,
        name: (r['name'] ?? '') as String,
        photo: r['photo'] as String?,
        owner: r['owner'] as String?,
        peer: r['peer'] as String?,
        created: _i(r['created']),
      );
  Map<String, Object?> toRow() =>
      {'id': id, 'kind': kind, 'name': name, 'photo': photo, 'owner': owner, 'peer': peer, 'created': created};
}

class Msg {
  final String id, chatId, sender, kind, body;
  final String? mediaUrl, mediaName, localPath, replyTo;
  final int mediaSize, ts, status, myRcpt;
  final bool edited, delAll, pinned, pending;
  const Msg({
    required this.id, required this.chatId, required this.sender, required this.kind, required this.body,
    this.mediaUrl, this.mediaName, this.localPath, this.replyTo,
    this.mediaSize = 0, required this.ts, this.status = 1, this.myRcpt = 0,
    this.edited = false, this.delAll = false, this.pinned = false, this.pending = false,
  });
  bool get mine => sender == Svc.me;
  factory Msg.fromRow(Map<String, Object?> r) => Msg(
        id: r['id'] as String,
        chatId: r['chat_id'] as String,
        sender: r['sender'] as String,
        kind: (r['kind'] ?? 'text') as String,
        body: (r['body'] ?? '') as String,
        mediaUrl: r['media_url'] as String?,
        mediaName: r['media_name'] as String?,
        localPath: r['local_path'] as String?,
        replyTo: r['reply_to'] as String?,
        mediaSize: _i(r['media_size']),
        ts: _i(r['ts']),
        status: _i(r['status']),
        myRcpt: _i(r['my_rcpt']),
        edited: _b(r['edited']),
        delAll: _b(r['del_all']),
        pinned: _b(r['pinned']),
        pending: _b(r['pending']),
      );
}

class ChatItem {
  final ChatRow chat;
  final Msg? last;
  final int unread;
  ChatItem(this.chat, this.last, this.unread);
}

// ───────────────────────── Local database (persistence) ─────────────────────────
class Db {
  static late Database d;
  static final StreamController<String> _ch = StreamController<String>.broadcast();
  static Stream<String> get changes => _ch.stream;
  static final Set<String> _dirty = <String>{};
  static Timer? _deb;

  /// Debounced change notification so bursts of writes cause one UI refresh.
  static void bump(String chatId) {
    _dirty.add(chatId);
    _deb ??= Timer(const Duration(milliseconds: 120), () {
      final ids = _dirty.toList();
      _dirty.clear();
      _deb = null;
      for (final id in ids) _ch.add(id);
    });
  }

  static const _schema = <String>[
    'CREATE TABLE chats(id TEXT PRIMARY KEY, kind TEXT, name TEXT, photo TEXT, owner TEXT, peer TEXT, created INTEGER DEFAULT 0)',
    'CREATE TABLE members(chat_id TEXT, uid TEXT, role TEXT, PRIMARY KEY(chat_id, uid))',
    'CREATE TABLE profiles(uid TEXT PRIMARY KEY, username TEXT, name TEXT, photo TEXT, about TEXT, pubkey TEXT, last_seen INTEGER DEFAULT 0)',
    'CREATE TABLE msgs(id TEXT PRIMARY KEY, chat_id TEXT, sender TEXT, kind TEXT, body TEXT, media_url TEXT, media_name TEXT, '
        'media_size INTEGER DEFAULT 0, local_path TEXT, reply_to TEXT, ts INTEGER, edited INTEGER DEFAULT 0, del_all INTEGER DEFAULT 0, '
        'del_me INTEGER DEFAULT 0, pinned INTEGER DEFAULT 0, pending INTEGER DEFAULT 0, status INTEGER DEFAULT 1, my_rcpt INTEGER DEFAULT 0)',
    'CREATE INDEX idx_msgs_chat ON msgs(chat_id, ts)',
    'CREATE TABLE rcpt(mid TEXT, uid TEXT, st INTEGER, PRIMARY KEY(mid, uid))',
    'CREATE TABLE kv(k TEXT PRIMARY KEY, v TEXT)',
  ];

  static Future<void> open(String uid) async {
    final path = p.join(await getDatabasesPath(), 'rtchat_$uid.db');
    d = await openDatabase(path, version: 1, onCreate: (db, v) async {
      for (final s in _schema) await db.execute(s);
    });
    DLog.d('db', 'opened $path');
  }

  static Future<String?> kvGet(String k) async {
    final r = await d.query('kv', where: 'k=?', whereArgs: [k]);
    return r.isEmpty ? null : r.first['v'] as String?;
  }

  static Future<void> kvSet(String k, String v) => d.insert('kv', {'k': k, 'v': v}, conflictAlgorithm: ConflictAlgorithm.replace);

  static Future<void> putProfile(Profile pr) => d.insert('profiles', pr.toRow(), conflictAlgorithm: ConflictAlgorithm.replace);

  static Future<Profile?> profile(String uid) async {
    final r = await d.query('profiles', where: 'uid=?', whereArgs: [uid]);
    return r.isEmpty ? null : Profile.row(r.first);
  }

  static Future<Map<String, Profile>> profileMap() async {
    final r = await d.query('profiles');
    return {for (final x in r) x['uid'] as String: Profile.row(x)};
  }

  static Future<void> putChat(ChatRow c) => d.insert('chats', c.toRow(), conflictAlgorithm: ConflictAlgorithm.replace);

  static Future<ChatRow?> chat(String id) async {
    final r = await d.query('chats', where: 'id=?', whereArgs: [id]);
    return r.isEmpty ? null : ChatRow.row(r.first);
  }

  static Future<void> setMembers(String chatId, List<Map<String, dynamic>> ms) async {
    final b = d.batch();
    b.delete('members', where: 'chat_id=?', whereArgs: [chatId]);
    for (final m in ms) {
      b.insert('members', {'chat_id': chatId, 'uid': m['uid'], 'role': m['role'] ?? 'member'}, conflictAlgorithm: ConflictAlgorithm.replace);
    }
    await b.commit(noResult: true);
  }

  static Future<int> memberCount(String chatId) async =>
      Sqflite.firstIntValue(await d.rawQuery('SELECT COUNT(*) FROM members WHERE chat_id=?', [chatId])) ?? 0;

  static Future<Msg?> msg(String id) async {
    final r = await d.query('msgs', where: 'id=?', whereArgs: [id]);
    return r.isEmpty ? null : Msg.fromRow(r.first);
  }

  static Future<bool> hasMsg(String id) async => (await d.query('msgs', columns: ['id'], where: 'id=?', whereArgs: [id])).isNotEmpty;

  static Future<void> putMsg(Msg m) async {
    await d.insert(
      'msgs',
      {
        'id': m.id,
        'chat_id': m.chatId,
        'sender': m.sender,
        'kind': m.kind,
        'body': m.body,
        'media_url': m.mediaUrl,
        'media_name': m.mediaName,
        'local_path': m.localPath,
        'reply_to': m.replyTo,
        'media_size': m.mediaSize,
        'ts': m.ts,
        'status': m.status,
        'my_rcpt': m.myRcpt,
        'edited': m.edited ? 1 : 0,
        'del_all': m.delAll ? 1 : 0,
        'del_me': 0,
        'pinned': m.pinned ? 1 : 0,
        'pending': m.pending ? 1 : 0,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  /// Insert/replace a message coming from the server, keeping local-only state.
  static Future<void> putServerMsg(Map<String, Object?> row) async {
    final ex = await d.query('msgs', columns: ['del_me', 'status', 'my_rcpt', 'local_path'], where: 'id=?', whereArgs: [row['id']]);
    if (ex.isNotEmpty) {
      row['del_me'] = ex.first['del_me'];
      row['my_rcpt'] = math.max(_i(ex.first['my_rcpt']), _i(row['my_rcpt']));
      row['local_path'] = ex.first['local_path'];
      row['status'] = math.max(_i(ex.first['status']), _i(row['status']));
    }
    await d.insert('msgs', row, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  static Future<List<Msg>> messages(String chatId, int limit) async {
    final r = await d.query('msgs', where: 'chat_id=? AND del_me=0', whereArgs: [chatId], orderBy: 'ts DESC', limit: limit);
    return r.map(Msg.fromRow).toList();
  }

  static Future<List<ChatItem>> chatList(String me) async {
    final rows = await d.rawQuery(
        'SELECT c.*, (SELECT id FROM msgs WHERE chat_id=c.id AND del_me=0 ORDER BY ts DESC LIMIT 1) AS last_id, '
        '(SELECT COUNT(*) FROM msgs u WHERE u.chat_id=c.id AND u.sender!=? AND u.my_rcpt<3 AND u.del_all=0 AND u.del_me=0) AS unread '
        'FROM chats c',
        [me]);
    final ids = rows.map((r) => r['last_id']).whereType<String>().toList();
    final last = <String, Msg>{};
    if (ids.isNotEmpty) {
      final q = await d.query('msgs', where: 'id IN (${List.filled(ids.length, '?').join(',')})', whereArgs: ids);
      for (final r in q) {
        final m = Msg.fromRow(r);
        last[m.id] = m;
      }
    }
    final out = [for (final r in rows) ChatItem(ChatRow.row(r), last[r['last_id']], _i(r['unread']))];
    out.sort((a, b) {
      if (a.chat.isAi && !b.chat.isAi) return -1;
      if (!a.chat.isAi && b.chat.isAi) return 1;
      return (b.last?.ts ?? b.chat.created).compareTo(a.last?.ts ?? a.chat.created);
    });
    return out;
  }
}

// ───────────────────────── Encryption (X25519 + HKDF + AES-256-GCM) ─────────────────────────
// Direct chats: key = HKDF(X25519(myPrivate, peerPublic)). Groups: random 32-byte group key,
// wrapped for every member with their pairwise key. Channels are public (not end-to-end encrypted).
class Crypt {
  static final cr.X25519 _x = cr.X25519();
  static final cr.AesGcm _aes = cr.AesGcm.with256bits();
  static const FlutterSecureStorage _store = FlutterSecureStorage();
  static late cr.KeyPair _kp;
  static String pub = '';
  static final Map<String, cr.SecretKey> _pairCache = {};

  static Future<void> init(String uid, {List<int>? restoreSeed}) async {
    _pairCache.clear();
    final k = 'rt_seed_$uid';
    List<int> seed;
    if (restoreSeed != null && restoreSeed.length == 32) {
      seed = restoreSeed;
      await _store.write(key: k, value: base64Encode(seed));
      DLog.d('crypt', 'restored identity key from backup');
    } else {
      String? s;
      try {
        s = await _store.read(key: k);
      } catch (e) {
        DLog.d('crypt', 'secure read failed: $e');
      }
      if (s != null && s.isNotEmpty) {
        seed = base64Decode(s);
      } else {
        final r = math.Random.secure();
        seed = List<int>.generate(32, (_) => r.nextInt(256));
        await _store.write(key: k, value: base64Encode(seed));
        DLog.d('crypt', 'generated new identity key');
      }
    }
    _kp = await _x.newKeyPairFromSeed(seed);
    final pk = await _kp.extractPublicKey() as cr.SimplePublicKey;
    pub = base64Encode(pk.bytes);
  }

  static Future<List<int>?> readSeed(String uid) async {
    try {
      final s = await _store.read(key: 'rt_seed_$uid');
      if (s == null || s.isEmpty) return null;
      return base64Decode(s);
    } catch (_) {
      return null;
    }
  }

  /// Derive an AES key from the account PIN to wrap/unwrap the identity seed.
  static Future<cr.SecretKey> pinKey(String pin, String uid) async {
    final h = await cr.Sha256().hash(utf8.encode('$pin|$uid|rt-chat-seed-v1'));
    return cr.SecretKey(h.bytes);
  }

  static Future<String> backupSeed(String pin, String uid) async {
    final seed = await readSeed(uid);
    if (seed == null) throw 'No local key to back up';
    final key = await pinKey(pin, uid);
    return seal(key, base64Encode(seed));
  }

  static Future<List<int>> restoreSeed(String pin, String uid, String backup) async {
    final key = await pinKey(pin, uid);
    final b64 = await open(key, backup);
    return base64Decode(b64);
  }

  static Future<cr.SecretKey> pair(String peerPubB64) async {
    final c = _pairCache[peerPubB64];
    if (c != null) return c;
    final remote = cr.SimplePublicKey(base64Decode(peerPubB64), type: cr.KeyPairType.x25519);
    final shared = await _x.sharedSecretKey(keyPair: _kp, remotePublicKey: remote);
    final key = await cr.Hkdf(hmac: cr.Hmac.sha256(), outputLength: 32)
        .deriveKey(secretKey: shared, nonce: utf8.encode('rtchat-v1'), info: utf8.encode('rtchat-pair'));
    return _pairCache[peerPubB64] = key;
  }

  static Future<String> seal(cr.SecretKey key, String text) async {
    final box = await _aes.encrypt(utf8.encode(text), secretKey: key);
    return base64Encode(box.concatenation());
  }

  static Future<String> open(cr.SecretKey key, String b64) async {
    final box = cr.SecretBox.fromConcatenation(base64Decode(b64), nonceLength: 12, macLength: 16);
    return utf8.decode(await _aes.decrypt(box, secretKey: key));
  }
}

class Keys {
  static final Map<String, cr.SecretKey> _g = {};

  static Future<cr.SecretKey?> forChat(ChatRow c) async {
    if (c.isChannel) return null;
    if (c.isDirect) {
      final pr = await Db.profile(c.peer ?? '');
      final k = pr?.pubkey;
      if (k == null || k.isEmpty) return null;
      return Crypt.pair(k);
    }
    final cached = _g[c.id];
    if (cached != null) return cached;
    final v = await Db.kvGet('gk_${c.id}');
    if (v == null) return null;
    return _g[c.id] = cr.SecretKey(base64Decode(v));
  }

  static Future<void> saveGroup(String id, List<int> bytes) async {
    await Db.kvSet('gk_$id', base64Encode(bytes));
    _g[id] = cr.SecretKey(bytes);
  }
}

// ───────────────────────── Notifications (with inline reply) ─────────────────────────
/// Runs in a background isolate when the user replies from the notification shade.
/// It only forwards the reply to the live main isolate (which owns keys + network).
@pragma('vm:entry-point')
void notifBg(NotificationResponse r) {
  if (r.actionId == 'reply' && r.input != null && r.payload != null) {
    ui.IsolateNameServer.lookupPortByName('rt_reply')?.send([r.payload, r.input]);
  }
}

class Notif {
  static final FlutterLocalNotificationsPlugin _p = FlutterLocalNotificationsPlugin();

  static Future<void> init(void Function(NotificationResponse) onResp) async {
    const android = AndroidInitializationSettings('@mipmap/ic_launcher');
    await _p.initialize(const InitializationSettings(android: android),
        onDidReceiveNotificationResponse: onResp, onDidReceiveBackgroundNotificationResponse: notifBg);
    final a = _p.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
    try {
      await a?.requestNotificationsPermission();
    } catch (e) {
      DLog.d('notif', 'permission request failed: $e');
    }
  }

  static int _id(String chatId) => chatId.hashCode & 0x7fffffff;

  static Future<void> show(ChatRow c, String title, List<String> lines) async {
    final details = AndroidNotificationDetails(
      'rt_messages',
      'Messages',
      channelDescription: 'New message notifications',
      importance: Importance.high,
      priority: Priority.high,
      category: AndroidNotificationCategory.message,
      styleInformation: InboxStyleInformation(lines, contentTitle: title, summaryText: Cfg.appName),
      actions: const <AndroidNotificationAction>[
        AndroidNotificationAction('reply', 'Reply',
            inputs: <AndroidNotificationActionInput>[AndroidNotificationActionInput(label: 'Type a reply')],
            showsUserInterface: false,
            allowGeneratedReplies: true),
      ],
    );
    await _p.show(_id(c.id), title, lines.last, NotificationDetails(android: details), payload: c.id);
  }

  static Future<void> cancel(String chatId) => _p.cancel(_id(chatId));

  static Future<String?> launchChatId() async {
    final d = await _p.getNotificationAppLaunchDetails();
    return d?.didNotificationLaunchApp == true ? d?.notificationResponse?.payload : null;
  }
}

final GlobalKey<NavigatorState> navKey = GlobalKey<NavigatorState>();

// ───────────────────────── Artee AI (OpenRouter + free web search) ─────────────────────────
/// Built-in assistant in RT Chat. Free OpenRouter model + client-side web search tool.
/// Always presents as Artee AI (never Grok / underlying model names).
class ArteeAi {
  static const chatId = 'artee-ai';
  static const senderId = 'artee-ai';

  static const systemPrompt = """
You are Artee AI, the built-in assistant inside the RT Chat messaging app.

Identity rules (never break these):
- Your name is Artee AI. Never say you are Grok, ChatGPT, Claude, Gemini, Llama, Qwen, or any other model.
- Never mention OpenRouter, xAI, providers, or the underlying model name.
- If asked who you are: "I'm Artee AI, the assistant built into RT Chat."

Style:
- Helpful, friendly, clear, lightly witty - like a smart friend in the chat.
- Concise unless the user asks for depth.

Tools:
- You have a web_search tool. Use it when the user needs current facts, news, prices, scores, "today", "latest", or anything that may change.
- Do not invent live data. If search returns nothing useful, say so.
- After search results arrive, answer in plain language. You may briefly cite sources by name/URL.
- You can also help with writing, ideas, explanations, study, and RT Chat tips without searching.
""";

  /// OpenAI-style tool the free model can call; we execute search on-device (no OpenRouter search fee).
  static final List<Map<String, dynamic>> tools = [
    {
      'type': 'function',
      'function': {
        'name': 'web_search',
        'description':
            'Search the public web for current information. Use for news, facts, prices, sports, weather, or anything time-sensitive.',
        'parameters': {
          'type': 'object',
          'properties': {
            'query': {
              'type': 'string',
              'description': 'Short search query, e.g. "Nigeria election results 2026"',
            },
          },
          'required': ['query'],
        },
      },
    },
  ];

  static ChatRow chatRow() => ChatRow(
        id: chatId,
        kind: 'ai',
        name: 'Artee AI',
        owner: Svc.me,
        created: nowMs(),
      );

  static Future<void> ensureChat() async {
    final existing = await Db.chat(chatId);
    if (existing != null) return;
    await Db.putChat(chatRow());
    Db.bump('*');
  }

  static String _scrub(String text) {
    return text
        .replaceAll(RegExp(r'\bI am Grok\b', caseSensitive: false), 'I am Artee AI')
        .replaceAll(RegExp(r"\bI'm Grok\b", caseSensitive: false), "I'm Artee AI")
        .replaceAll(RegExp(r'\bGrok\b'), 'Artee AI')
        .replaceAll(RegExp(r'\bChatGPT\b'), 'Artee AI')
        .replaceAll(RegExp(r'\bClaude\b'), 'Artee AI');
  }

  /// Free web search via DuckDuckGo Instant Answer API (no API key, no OpenRouter search cost).
  static Future<String> webSearch(String query) async {
    final q = query.trim();
    if (q.isEmpty) return 'Empty query.';
    try {
      final uri = Uri.https('api.duckduckgo.com', '/', {
        'q': q,
        'format': 'json',
        'no_html': '1',
        'skip_disambig': '1',
      });
      final res = await http.get(uri, headers: {'User-Agent': 'RTChat-ArteeAI/1.0'}).timeout(const Duration(seconds: 20));
      if (res.statusCode != 200) return 'Search failed (${res.statusCode}).';
      final data = jsonDecode(res.body) as Map<String, dynamic>;
      final buf = StringBuffer();
      final heading = (data['Heading'] as String?)?.trim() ?? '';
      final abs = (data['AbstractText'] as String?)?.trim() ?? '';
      final absUrl = (data['AbstractURL'] as String?)?.trim() ?? '';
      final answer = (data['Answer'] as String?)?.trim() ?? '';
      final def = (data['Definition'] as String?)?.trim() ?? '';
      if (heading.isNotEmpty) buf.writeln('Topic: $heading');
      if (answer.isNotEmpty) buf.writeln('Answer: $answer');
      if (abs.isNotEmpty) {
        buf.writeln('Summary: $abs');
        if (absUrl.isNotEmpty) buf.writeln('Source: $absUrl');
      }
      if (def.isNotEmpty) buf.writeln('Definition: $def');
      final related = data['RelatedTopics'];
      if (related is List) {
        var n = 0;
        for (final item in related) {
          if (n >= 6) break;
          if (item is Map) {
            final text = (item['Text'] as String?)?.trim() ?? '';
            final url = (item['FirstURL'] as String?)?.trim() ?? '';
            if (text.isEmpty) continue;
            n++;
            buf.writeln('- $text${url.isNotEmpty ? ' ($url)' : ''}');
          }
        }
      }
      final results = data['Results'];
      if (results is List) {
        for (final item in results.take(4)) {
          if (item is Map) {
            final text = (item['Text'] as String?)?.trim() ?? '';
            final url = (item['FirstURL'] as String?)?.trim() ?? '';
            if (text.isNotEmpty) buf.writeln('- $text${url.isNotEmpty ? ' ($url)' : ''}');
          }
        }
      }
      final out = buf.toString().trim();
      if (out.isEmpty) return await _wikiSearch(q);
      return out;
    } catch (e) {
      DLog.d('artee-search', '$e');
      try {
        return await _wikiSearch(q);
      } catch (e2) {
        return 'Search unavailable: $e2';
      }
    }
  }

  static Future<String> _wikiSearch(String q) async {
    final uri = Uri.https('en.wikipedia.org', '/w/api.php', {
      'action': 'query',
      'list': 'search',
      'srsearch': q,
      'srlimit': '5',
      'format': 'json',
      'utf8': '1',
    });
    final res = await http.get(uri, headers: {'User-Agent': 'RTChat-ArteeAI/1.0'}).timeout(const Duration(seconds: 15));
    if (res.statusCode != 200) return 'No search results.';
    final data = jsonDecode(res.body) as Map<String, dynamic>;
    final search = (data['query'] as Map?)?['search'] as List? ?? [];
    if (search.isEmpty) return 'No results found for "$q".';
    final buf = StringBuffer('Wikipedia results for "$q":\n');
    for (final item in search) {
      if (item is! Map) continue;
      final title = item['title'] ?? '';
      final snippet = (item['snippet'] as String? ?? '').replaceAll(RegExp(r'<[^>]+>'), '');
      buf.writeln('- $title: $snippet');
    }
    return buf.toString();
  }

  static int _keyIdx = 0;
  static int _modelIdx = 0;

  /// Free models to try when the preferred one is rate-limited or missing.
  static const fallbackModels = <String>[
    'openrouter/free',
    'qwen/qwen3.8-27b:free',
    'nvidia/nemotron-3-nano-30b-a3b:free',
    'meta-llama/llama-3.3-70b-instruct:free',
    'google/gemma-3-27b-it:free',
    'mistralai/mistral-small-3.1-24b-instruct:free',
  ];

  static List<String> get _models {
    final pref = Cfg.openRouterModel;
    final list = <String>[];
    if (pref.isNotEmpty) list.add(pref);
    for (final m in fallbackModels) {
      if (!list.contains(m)) list.add(m);
    }
    return list;
  }

  static String get _currentKey {
    final keys = Cfg.openRouterKeys;
    if (keys.isEmpty) return '';
    return keys[_keyIdx % keys.length];
  }

  static String get _currentModel {
    final models = _models;
    return models[_modelIdx % models.length];
  }

  static void _rotateKey() {
    final keys = Cfg.openRouterKeys;
    if (keys.length <= 1) return;
    _keyIdx = (_keyIdx + 1) % keys.length;
    DLog.d('artee', 'rotated API key -> index $_keyIdx');
  }

  static void _rotateModel() {
    final models = _models;
    if (models.length <= 1) return;
    _modelIdx = (_modelIdx + 1) % models.length;
    DLog.d('artee', 'rotated model -> ${_currentModel}');
  }

  static Future<Map<String, dynamic>> _chatRequest(
    List<Map<String, dynamic>> messages, {
    bool withTools = true,
    String? model,
    String? apiKey,
  }) async {
    final key = apiKey ?? _currentKey;
    final mod = model ?? _currentModel;
    final body = <String, dynamic>{
      'model': mod,
      'messages': messages,
      'temperature': 0.7,
      'max_tokens': 1200,
    };
    if (withTools) {
      body['tools'] = tools;
      body['tool_choice'] = 'auto';
    }
    final res = await http
        .post(
          Uri.parse('https://openrouter.ai/api/v1/chat/completions'),
          headers: {
            'Authorization': 'Bearer $key',
            'Content-Type': 'application/json',
            'HTTP-Referer': 'https://rtchat.app',
            'X-Title': 'RT Chat Artee AI',
          },
          body: jsonEncode(body),
        )
        .timeout(const Duration(seconds: 90));
    if (res.statusCode < 200 || res.statusCode >= 300) {
      DLog.d('artee', 'HTTP ${res.statusCode} model=$mod: ${res.body}');
      final low = res.body.toLowerCase();
      if (res.statusCode == 401) throw 'Artee AI key is invalid. Check OPENROUTER_API_KEY.';
      if (res.statusCode == 402 || low.contains('credit')) {
        throw 'OpenRouter needs credits for this model. Use a :free model id.';
      }
      throw _HttpErr(res.statusCode, res.body);
    }
    return jsonDecode(res.body) as Map<String, dynamic>;
  }

  /// Retries across keys and free models on 429 / model errors.
  static Future<Map<String, dynamic>> _chatRequestResilient(
    List<Map<String, dynamic>> messages, {
    bool withTools = true,
  }) async {
    final keys = Cfg.openRouterKeys;
    final models = _models;
    final attempts = (keys.isEmpty ? 1 : keys.length) * models.length;
    Object? lastErr;

    for (var i = 0; i < attempts; i++) {
      try {
        return await _chatRequest(messages, withTools: withTools);
      } on _HttpErr catch (e) {
        lastErr = e;
        final retryable = e.code == 429 || e.code == 503 || e.code == 502 ||
            e.code == 404 || e.code == 400;
        if (!retryable) rethrow;

        // 429: rotate key first, then model; short backoff.
        if (e.code == 429) {
          if (keys.length > 1) {
            _rotateKey();
          } else {
            _rotateModel();
          }
          // After trying all keys once on this model, also rotate model.
          if (keys.length > 1 && (i + 1) % keys.length == 0) {
            _rotateModel();
          }
          await Future<void>.delayed(Duration(milliseconds: 400 + 200 * i));
          continue;
        }
        // Bad model / tools unsupported: drop tools or rotate model.
        if (e.code == 400 || e.code == 404) {
          if (withTools && (e.body.contains('tool') || e.body.contains('model'))) {
            // Caller may retry without tools; signal via special code.
            rethrow;
          }
          _rotateModel();
          await Future<void>.delayed(const Duration(milliseconds: 300));
          continue;
        }
        _rotateModel();
        await Future<void>.delayed(const Duration(milliseconds: 300));
      }
    }
    if (lastErr is _HttpErr && lastErr.code == 429) {
      throw 'Artee AI is rate-limited on free models. Wait a minute, or add more OPENROUTER_API_KEYS / a small OpenRouter credit.';
    }
    throw lastErr ?? 'Artee AI could not reply.';
  }

  static Future<String> complete(List<Msg> history, String userText) async {
    if (!Cfg.arteeEnabled) {
      return 'Artee AI is not set up yet. Add the OPENROUTER_API_KEY GitHub secret and rebuild the app.';
    }
    final recent = history.reversed.take(20).toList().reversed.toList();
    final messages = <Map<String, dynamic>>[
      {'role': 'system', 'content': systemPrompt.trim()},
    ];
    for (final m in recent) {
      if (m.delAll || m.body.isEmpty || m.kind != 'text') continue;
      final role = m.sender == senderId ? 'assistant' : 'user';
      messages.add({'role': role, 'content': m.body});
    }
    if (messages.isEmpty || messages.last['role'] != 'user' || messages.last['content'] != userText) {
      messages.add({'role': 'user', 'content': userText});
    }

    const maxRounds = 3;
    var useTools = true;
    for (var round = 0; round < maxRounds; round++) {
      Map<String, dynamic> data;
      try {
        data = await _chatRequestResilient(messages, withTools: useTools);
      } on _HttpErr catch (e) {
        if (useTools && (e.code == 400 || e.code == 404 || e.body.contains('tool'))) {
          useTools = false;
          data = await _chatRequestResilient(messages, withTools: false);
        } else if (e.code == 429) {
          return 'Artee AI is rate-limited on free models. Wait a minute, or add more OPENROUTER_API_KEYS / a small OpenRouter credit.';
        } else {
          return 'Artee AI could not reply right now (${e.code}). Try again.';
        }
      } catch (e) {
        return e.toString();
      }

      final choices = data['choices'] as List?;
      if (choices == null || choices.isEmpty) return 'Artee AI sent an empty reply.';
      final msg = choices.first['message'] as Map<String, dynamic>? ?? {};
      final toolCalls = msg['tool_calls'] as List?;

      if (toolCalls == null || toolCalls.isEmpty) {
        var text = (msg['content'] as String?)?.trim() ?? '';
        if (text.isEmpty) return 'Artee AI sent an empty reply.';
        return _scrub(text);
      }

      messages.add(msg);
      for (final call in toolCalls) {
        if (call is! Map) continue;
        final id = call['id']?.toString() ?? 'call_$round';
        final fn = call['function'] as Map? ?? {};
        final name = fn['name']?.toString() ?? '';
        var argsRaw = fn['arguments']?.toString() ?? '{}';
        Map<String, dynamic> args = {};
        try {
          args = jsonDecode(argsRaw) as Map<String, dynamic>;
        } catch (_) {}
        String result;
        if (name == 'web_search') {
          final q = (args['query'] ?? userText).toString();
          result = await webSearch(q);
        } else {
          result = 'Unknown tool: $name';
        }
        messages.add({
          'role': 'tool',
          'tool_call_id': id,
          'content': result,
        });
      }
    }
    return 'Artee AI took too long searching. Try a shorter question.';
  }

  static Future<void> sendUserMessage(String text) async {
    await ensureChat();
    final id = Svc.newId();
    final ts = nowMs();
    final user = Msg(
      id: id,
      chatId: chatId,
      sender: Svc.me,
      kind: 'text',
      body: text,
      ts: ts,
      status: 3,
      pending: false,
    );
    await Db.putMsg(user);
    Db.bump(chatId);

    final aid = Svc.newId();
    final thinking = Msg(
      id: aid,
      chatId: chatId,
      sender: senderId,
      kind: 'text',
      body: '...',
      ts: ts + 1,
      status: 3,
      pending: true,
    );
    await Db.putMsg(thinking);
    Db.bump(chatId);

    try {
      final hist = await Db.messages(chatId, 40);
      final ctx = [for (final m in hist) if (m.id != aid) m];
      final reply = await complete(ctx, text);
      await Db.d.update('msgs', {'body': reply, 'pending': 0}, where: 'id=?', whereArgs: [aid]);
      Db.bump(chatId);
    } catch (e) {
      DLog.d('artee', '$e');
      await Db.d.update('msgs', {
        'body': '$e',
        'pending': 0,
      }, where: 'id=?', whereArgs: [aid]);
      Db.bump(chatId);
    }
  }
}

class _HttpErr implements Exception {
  final int code;
  final String body;
  _HttpErr(this.code, this.body);
  @override
  String toString() => 'HTTP $code';
}

// ───────────────────────── Service layer ─────────────────────────
class Svc {
  static String me = '';
  static Profile? meP;
  static SupabaseClient get sb => Supabase.instance.client;
  static final ValueNotifier<Set<String>> online = ValueNotifier<Set<String>>(<String>{});
  static String? openChatId;
  static bool foreground = true;
  static RealtimeChannel? _db, _pres;
  static Timer? _retry;
  static bool _flushing = false, _syncing = false, _began = false, _again = false;
  static DateTime _lastSync = DateTime.fromMillisecondsSinceEpoch(0);
  static const Uuid _uuid = Uuid();
  static final math.Random _rnd = math.Random.secure();
  static ReceivePort? _port;
  // receipts waiting to be sent: message id -> [chatId, status]
  static final Map<String, List<Object>> _rq = {};

  static String newId() => _uuid.v4();

  // ── session ──
  /// Returns true when the user still has to create a profile (username).
  static Future<bool> start(String uid) async {
    me = uid;
    await Db.open(me);
    await Crypt.init(me);
    try {
      final row = await sb.from('profiles').select().eq('uid', me).maybeSingle();
      if (row == null) return true;
      meP = Profile.server(row);
      await Db.putProfile(meP!);
      await sb.from('profiles').update({'pubkey': Crypt.pub, 'last_seen': DateTime.now().toUtc().toIso8601String()}).eq('uid', me);
    } catch (e) {
      DLog.d('start', 'offline start: $e');
      meP = await Db.profile(me);
      if (meP == null) rethrow;
    }
    return false;
  }

  static Future<void> createProfile(String username, String name, {String? pin}) async {
    final row = <String, dynamic>{
      'uid': me,
      'username': username,
      'name': name,
      'pubkey': Crypt.pub,
    };
    if (pin != null && pin.isNotEmpty) {
      row['pin_hash'] = await LocalAuth.hashPin(pin, me);
      try {
        row['key_backup'] = await Crypt.backupSeed(pin, me);
      } catch (e) {
        DLog.d('auth', 'key backup failed: $e');
      }
    }
    await sb.from('profiles').insert(row);
    final saved = await sb.from('profiles').select().eq('uid', me).single();
    meP = Profile.server(saved);
    await Db.putProfile(meP!);
  }

  /// Restore an account after reinstall.
  /// - Accounts with a PIN + key_backup restore encryption keys (old chats readable).
  /// - Legacy accounts (no PIN) restore the username only; old encrypted messages stay unreadable.
  static Future<void> loginWithUsername(String username, String pin) async {
    final u = username.trim().toLowerCase();
    final row = await sb.from('profiles').select().eq('username', u).maybeSingle();
    if (row == null) throw 'No account with that username.';
    final uid = row['uid'] as String;
    final hash = (row['pin_hash'] as String?)?.trim() ?? '';
    final backup = (row['key_backup'] as String?)?.trim() ?? '';
    List<int>? seed;
    if (hash.isEmpty) {
      // Pre-PIN account: can restore identity id, but not E2E keys.
    } else {
      if (pin.isEmpty) throw 'This account needs its PIN.';
      final h = await LocalAuth.hashPin(pin, uid);
      if (h != hash) throw 'Wrong PIN.';
      if (backup.isNotEmpty) {
        try {
          seed = await Crypt.restoreSeed(pin, uid, backup);
        } catch (e) {
          DLog.d('auth', 'seed restore failed: $e');
          throw 'PIN ok but key backup could not be opened. Old messages may stay locked.';
        }
      }
    }
    await LocalAuth.setUid(uid);
    // Pre-init seed so Svc.start → Crypt.init uses the restored key.
    if (seed != null) {
      await Crypt.init(uid, restoreSeed: seed);
    }
    LocalAuth.rev.value++;
  }

  /// Let a legacy (no-PIN) account set a PIN and upload a key backup so future reinstalls keep chat history.
  static Future<void> setRecoveryPin(String pin) async {
    if (me.isEmpty) throw 'Not signed in';
    if (!RegExp(r'^\d{4,8}$').hasMatch(pin)) throw 'PIN must be 4–8 digits.';
    final hash = await LocalAuth.hashPin(pin, me);
    final backup = await Crypt.backupSeed(pin, me);
    await sb.from('profiles').update({'pin_hash': hash, 'key_backup': backup}).eq('uid', me);
  }

  /// Drop oldest remote media when the bucket is getting large (free-tier safety).
  /// Phone-local copies are not touched.
  static Future<void> purgeStorageIfNeeded() async {
    try {
      final root = await sb.storage.from('media').list();
      final paths = <String>[];
      final stamped = <(String, DateTime)>[];
      for (final item in root) {
        final meta = item.metadata;
        final isFolder = meta == null || (item.id == null && (meta['mimetype'] == null && meta['size'] == null));
        if (isFolder && item.name != 'avatars') {
          try {
            final kids = await sb.storage.from('media').list(path: item.name);
            for (final k in kids) {
              final pth = '${item.name}/${k.name}';
              paths.add(pth);
              DateTime ts = DateTime.fromMillisecondsSinceEpoch(0);
              try {
                if (k.createdAt != null) ts = DateTime.tryParse(k.createdAt!) ?? ts;
              } catch (_) {}
              stamped.add((pth, ts));
            }
          } catch (e) {
            DLog.d('purge', 'list ${item.name}: $e');
          }
        } else if (item.name.isNotEmpty) {
          final pth = item.name;
          DateTime ts = DateTime.fromMillisecondsSinceEpoch(0);
          try {
            if (item.createdAt != null) ts = DateTime.tryParse(item.createdAt!) ?? ts;
          } catch (_) {}
          stamped.add((pth, ts));
        }
      }
      // Also scan avatars folder
      try {
        final av = await sb.storage.from('media').list(path: 'avatars');
        for (final k in av) {
          final pth = 'avatars/${k.name}';
          DateTime ts = DateTime.fromMillisecondsSinceEpoch(0);
          try {
            if (k.createdAt != null) ts = DateTime.tryParse(k.createdAt!) ?? ts;
          } catch (_) {}
          stamped.add((pth, ts));
        }
      } catch (_) {}

      if (stamped.length <= Cfg.storageFileSoftLimit) return;
      stamped.sort((a, b) => a.$2.compareTo(b.$2));
      final excess = stamped.length - Cfg.storageFileSoftLimit + 25;
      final doomed = [for (final e in stamped.take(excess)) e.$1];
      if (doomed.isEmpty) return;
      for (var i = 0; i < doomed.length; i += 50) {
        final chunk = doomed.sublist(i, i + 50 > doomed.length ? doomed.length : i + 50);
        try {
          await sb.storage.from('media').remove(chunk);
        } catch (e) {
          DLog.d('purge', 'remove: $e');
        }
      }
      DLog.d('purge', 'removed ${doomed.length} remote files (kept local copies)');
    } catch (e) {
      DLog.d('purge', '$e');
    }
  }

  static Future<void> updateProfile({String? name, String? about, String? photo}) async {
    final m = <String, dynamic>{};
    if (name != null) m['name'] = name;
    if (about != null) m['about'] = about;
    if (photo != null) m['photo'] = photo;
    if (m.isEmpty) return;
    await sb.from('profiles').update(m).eq('uid', me);
    final row = await sb.from('profiles').select().eq('uid', me).single();
    meP = Profile.server(row);
    await Db.putProfile(meP!);
  }

  static Future<void> begin() async {
    if (!_began) {
      _began = true;
      _listen();
      _startPresence();
      _registerPort();
      _retry = Timer.periodic(const Duration(seconds: 15), (_) => flushPending());
      // Occasional free-tier storage sweep (does not delete local phone files).
      Timer(const Duration(seconds: 8), () => unawaited(purgeStorageIfNeeded()));
    }
    await sync();
  }

  static Future<void> stop() async {
    _began = false;
    _retry?.cancel();
    await _db?.unsubscribe();
    await _pres?.unsubscribe();
    _db = null;
    _pres = null;
    ui.IsolateNameServer.removePortNameMapping('rt_reply');
    _port?.close();
    _port = null;
    me = '';
    meP = null;
  }

  static void onLifecycle(AppLifecycleState s) {
    if (s == AppLifecycleState.resumed) {
      foreground = true;
      if (DateTime.now().difference(_lastSync).inSeconds > 20) sync();
      _pres?.track({'uid': me});
      touchSeen();
    } else if (s == AppLifecycleState.paused) {
      foreground = false;
      touchSeen();
      _pres?.untrack();
    }
  }

  static Future<void> touchSeen() async {
    try {
      await sb.from('profiles').update({'last_seen': DateTime.now().toUtc().toIso8601String()}).eq('uid', me);
    } catch (_) {}
  }

  static void _registerPort() {
    ui.IsolateNameServer.removePortNameMapping('rt_reply');
    _port?.close();
    final rp = ReceivePort();
    _port = rp;
    ui.IsolateNameServer.registerPortWithName(rp.sendPort, 'rt_reply');
    rp.listen((msg) {
      if (msg is List && msg.length == 2) replyFromNotif('${msg[0]}', '${msg[1]}');
    });
  }

  static Future<void> replyFromNotif(String chatId, String text) async {
    final c = await Db.chat(chatId);
    if (c == null || text.trim().isEmpty) return;
    if (c.isChannel && c.owner != me) return;
    await send(c, body: text.trim());
    await markRead(c);
    await Notif.cancel(chatId);
  }

  static Future<void> openFromNotif(String chatId) async {
    final c = await Db.chat(chatId);
    if (c == null) return;
    navKey.currentState?.push(MaterialPageRoute(builder: (_) => ChatScreen(chat: c)));
  }

  // ── realtime ──
  static void _listen() {
    _db?.unsubscribe();
    _db = sb
        .channel('rt-db')
        .onPostgresChanges(
            event: PostgresChangeEvent.all,
            schema: 'public',
            table: 'messages',
            callback: (pl) {
              final r = pl.newRecord;
              if (r.isNotEmpty) _ingestMsg(r, live: true).catchError((Object e) => DLog.d('rt', 'msg ingest: $e'));
            })
        .onPostgresChanges(
            event: PostgresChangeEvent.all,
            schema: 'public',
            table: 'receipts',
            callback: (pl) {
              final r = pl.newRecord;
              if (r.isNotEmpty) _ingestRcpt(r).catchError((Object e) => DLog.d('rt', 'rcpt ingest: $e'));
            })
        .onPostgresChanges(
            event: PostgresChangeEvent.insert,
            schema: 'public',
            table: 'chat_members',
            callback: (pl) {
              if (pl.newRecord['uid'] == me) sync();
            })
        .subscribe((status, [err]) => DLog.d('rt', 'db channel: $status ${err ?? ''}'));
  }

  static void applyLowData() {
    online.value = <String>{};
    _startPresence();
  }

  static void _startPresence() {
    _pres?.unsubscribe();
    if (Prefs.lowData) return; // saves data: no presence in low data mode
    final ch = sb.channel('online', opts: RealtimeChannelConfig(key: me));
    ch.onPresenceSync((_) {
      final ids = <String>{};
      final dynamic st = ch.presenceState();
      if (st is Map) {
        ids.addAll(st.keys.map((e) => e.toString()));
      } else if (st is Iterable) {
        for (final s in st) {
          ids.add((s as dynamic).key.toString());
        }
      }
      online.value = ids;
    }).subscribe((status, [err]) async {
      if (status == RealtimeSubscribeStatus.subscribed) await ch.track({'uid': me});
    });
    _pres = ch;
  }

  // ── sync (pull everything newer than the cursor) ──
  static Future<void> sync() async {
    if (me.isEmpty) return;
    if (_syncing) {
      _again = true;
      return;
    }
    _syncing = true;
    _lastSync = DateTime.now();
    try {
      final mine = await sb.from('chat_members').select('chat_id').eq('uid', me);
      final ids = [for (final r in mine) r['chat_id'] as String];
      if (ids.isNotEmpty) {
        final chats = await sb.from('chats').select().inFilter('id', ids);
        final members = await sb.from('chat_members').select().inFilter('chat_id', ids);
        final uids = {for (final m in members) m['uid'] as String};
        final profs = await sb.from('profiles').select().inFilter('uid', uids.toList());
        for (final pr in profs) await Db.putProfile(Profile.server(pr));
        for (final c in chats) {
          final cid = c['id'] as String;
          final ms = [for (final m in members) if (m['chat_id'] == cid) m];
          String? peer;
          if (c['kind'] == 'direct') {
            for (final m in ms) if (m['uid'] != me) peer = m['uid'] as String;
          }
          await Db.setMembers(cid, ms);
          await Db.putChat(ChatRow(
              id: cid,
              kind: (c['kind'] ?? 'direct') as String,
              name: (c['name'] ?? '') as String,
              photo: c['photo'] as String?,
              owner: c['owner'] as String?,
              peer: peer,
              created: _isoMs(c['created_at'])));
        }
        await _pullGroupKeys();
        await _pullMessages(ids);
        await _pullReceipts(ids);
      }
      await flushPending();
      Db.bump('*');
    } catch (e) {
      DLog.d('sync', 'failed: $e');
    } finally {
      _syncing = false;
      if (_again) {
        _again = false;
        unawaited(sync());
      }
    }
  }

  static Future<void> _pullGroupKeys() async {
    final rows = await sb.from('group_keys').select().eq('uid', me);
    for (final r in rows) {
      final cid = r['chat_id'] as String;
      if (await Db.kvGet('gk_$cid') != null) continue;
      final from = await Db.profile(r['from_uid'] as String);
      if (from?.pubkey == null) continue;
      try {
        final key = await Crypt.pair(from!.pubkey!);
        final raw = await Crypt.open(key, r['wrapped'] as String);
        await Keys.saveGroup(cid, base64Decode(raw));
      } catch (e) {
        DLog.d('keys', 'cannot unwrap group key for $cid: $e');
      }
    }
  }

  static Future<void> _pullMessages(List<String> ids) async {
    var cur = await Db.kvGet('cur_msgs') ?? '1970-01-01T00:00:00+00:00';
    while (true) {
      final rows = await sb
          .from('messages')
          .select()
          .inFilter('chat_id', ids)
          .gt('updated_at', cur)
          .order('updated_at', ascending: true)
          .limit(300);
      if (rows.isEmpty) break;
      for (final r in rows) await _ingestMsg(r);
      cur = rows.last['updated_at'] as String;
      await Db.kvSet('cur_msgs', cur);
      if (rows.length < 300) break;
    }
  }

  static Future<void> _pullReceipts(List<String> ids) async {
    var cur = await Db.kvGet('cur_rcpt') ?? '1970-01-01T00:00:00+00:00';
    while (true) {
      final rows = await sb
          .from('receipts')
          .select()
          .inFilter('chat_id', ids)
          .gt('updated_at', cur)
          .order('updated_at', ascending: true)
          .limit(500);
      if (rows.isEmpty) break;
      for (final r in rows) await _ingestRcpt(r);
      cur = rows.last['updated_at'] as String;
      await Db.kvSet('cur_rcpt', cur);
      if (rows.length < 500) break;
    }
  }

  static Future<String> decryptBody(ChatRow c, String body, bool enc) async {
    if (!enc || body.isEmpty) return body;
    final k = await Keys.forChat(c);
    if (k == null) return '🔒 Waiting for encryption key…';
    try {
      return await Crypt.open(k, body);
    } catch (e) {
      return "🔒 Message can't be decrypted";
    }
  }

  static Future<void> _ingestMsg(Map<String, dynamic> r, {bool live = false}) async {
    final chat = await Db.chat(r['chat_id'] as String);
    if (chat == null) return; // not one of my chats
    final id = r['id'] as String;
    final sender = r['sender'] as String;
    final mine = sender == me;
    final deleted = r['deleted'] == true;
    final isNew = !await Db.hasMsg(id);
    final body = deleted ? '' : await decryptBody(chat, (r['body'] ?? '') as String, r['enc'] == true);
    final row = <String, Object?>{
      'id': id,
      'chat_id': chat.id,
      'sender': sender,
      'kind': r['kind'] ?? 'text',
      'body': body,
      'media_url': deleted ? null : r['media_url'],
      'media_name': r['media_name'],
      'media_size': _i(r['media_size']),
      'local_path': null,
      'reply_to': r['reply_to'],
      'ts': _i(r['ts']),
      'edited': r['edited'] == true ? 1 : 0,
      'del_all': deleted ? 1 : 0,
      'del_me': 0,
      'pinned': r['pinned'] == true ? 1 : 0,
      'pending': 0,
      'status': 1,
      'my_rcpt': mine ? 3 : (chat.isChannel ? 0 : 2),
    };
    await Db.putServerMsg(row);
    if (!mine && isNew && !chat.isChannel) _queueRcpt(id, chat.id, 2);
    Db.bump(chat.id);
    if (!mine && isNew && live && !deleted) _notify(chat);
    if (!mine && isNew) unawaited(_flushRcpts());
  }

  static void _queueRcpt(String mid, String chatId, int st) {
    final ex = _rq[mid];
    if (ex != null && (ex[1] as int) >= st) return;
    _rq[mid] = [chatId, st];
  }

  static Future<void> _flushRcpts() async {
    if (_rq.isEmpty) return;
    final batch = Map<String, List<Object>>.from(_rq);
    try {
      await sb.from('receipts').upsert([
        for (final e in batch.entries) {'message_id': e.key, 'uid': me, 'chat_id': e.value[0], 'st': e.value[1]}
      ]);
      for (final e in batch.entries) {
        if (_rq[e.key]?[1] == e.value[1]) _rq.remove(e.key);
      }
    } catch (e) {
      DLog.d('rcpt', 'flush failed: $e');
    }
  }

  static Future<void> _ingestRcpt(Map<String, dynamic> r) async {
    final uid = r['uid'] as String;
    if (uid == me) return;
    final mid = r['message_id'] as String;
    final m = await Db.msg(mid);
    if (m == null || m.sender != me) return;
    await Db.d.insert('rcpt', {'mid': mid, 'uid': uid, 'st': _i(r['st'])}, conflictAlgorithm: ConflictAlgorithm.replace);
    final others = math.max(1, await Db.memberCount(m.chatId) - 1);
    final deliv = Sqflite.firstIntValue(await Db.d.rawQuery('SELECT COUNT(*) FROM rcpt WHERE mid=? AND st>=2', [mid])) ?? 0;
    final read = Sqflite.firstIntValue(await Db.d.rawQuery('SELECT COUNT(*) FROM rcpt WHERE mid=? AND st>=3', [mid])) ?? 0;
    final st = read >= others ? 3 : (deliv >= others ? 2 : 1);
    if (st > m.status) {
      await Db.d.update('msgs', {'status': st}, where: 'id=?', whereArgs: [mid]);
      Db.bump(m.chatId);
    }
  }

  static Future<void> markRead(ChatRow c) async {
    final rows = await Db.d.query('msgs',
        columns: ['id'], where: 'chat_id=? AND sender!=? AND my_rcpt<3', whereArgs: [c.id, me]);
    if (rows.isEmpty) return;
    await Db.d.update('msgs', {'my_rcpt': 3}, where: 'chat_id=? AND sender!=? AND my_rcpt<3', whereArgs: [c.id, me]);
    if (!c.isChannel) {
      for (final r in rows) _queueRcpt(r['id'] as String, c.id, 3);
      unawaited(_flushRcpts());
    }
    Db.bump(c.id);
    unawaited(Notif.cancel(c.id));
  }

  static Future<void> _notify(ChatRow c) async {
    if (foreground && openChatId == c.id) return;
    final rows = await Db.d.query('msgs',
        where: 'chat_id=? AND sender!=? AND my_rcpt<3 AND del_all=0 AND del_me=0',
        whereArgs: [c.id, me],
        orderBy: 'ts DESC',
        limit: 5);
    if (rows.isEmpty) return;
    final pm = await Db.profileMap();
    final lines = rows.reversed.map((r) {
      final m = Msg.fromRow(r);
      final who = c.isDirect ? '' : '${pm[m.sender]?.name ?? ''}: ';
      return who + previewOf(m);
    }).toList();
    await Notif.show(c, chatTitle(c, pm), lines);
  }

  // ── sending ──
  static Future<void> send(ChatRow c,
      {String kind = 'text', String body = '', String? localPath, String? name, int size = 0, String? url, String? replyTo}) async {
    final id = newId();
    await Db.d.insert('msgs', {
      'id': id, 'chat_id': c.id, 'sender': me, 'kind': kind, 'body': body, 'media_url': url, 'media_name': name,
      'media_size': size, 'local_path': localPath, 'reply_to': replyTo, 'ts': nowMs(), 'edited': 0, 'del_all': 0,
      'del_me': 0, 'pinned': 0, 'pending': 1, 'status': 0, 'my_rcpt': 3,
    });
    Db.bump(c.id);
    unawaited(push(id));
  }

  static Future<String> upload(String chatId, String id, String path, String name) async {
    final safe = name.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
    final key = '$chatId/${id}_$safe';
    await sb.storage
        .from('media')
        .upload(key, File(path), fileOptions: FileOptions(contentType: mimeOf(name), upsert: true));
    unawaited(purgeStorageIfNeeded());
    return sb.storage.from('media').getPublicUrl(key);
  }

  static Future<bool> push(String id) async {
    final m = await Db.msg(id);
    if (m == null || !m.pending) return true;
    final c = await Db.chat(m.chatId);
    if (c == null) return false;
    try {
      var url = m.mediaUrl;
      if (url == null && m.localPath != null) {
        url = await upload(c.id, id, m.localPath!, m.mediaName ?? p.basename(m.localPath!));
        await Db.d.update('msgs', {'media_url': url}, where: 'id=?', whereArgs: [id]);
      }
      var wire = m.body;
      var enc = false;
      if (!c.isChannel && m.body.isNotEmpty) {
        final k = await Keys.forChat(c);
        if (k == null) throw 'no encryption key yet';
        wire = await Crypt.seal(k, m.body);
        enc = true;
      }
      await sb.from('messages').upsert({
        'id': id, 'chat_id': c.id, 'sender': me, 'kind': m.kind, 'body': wire, 'enc': enc, 'media_url': url,
        'media_name': m.mediaName, 'media_size': m.mediaSize, 'reply_to': m.replyTo, 'ts': m.ts,
      });
      await Db.d.update('msgs', {'pending': 0, 'status': 1}, where: 'id=? AND status<1', whereArgs: [id]);
      await Db.d.update('msgs', {'pending': 0}, where: 'id=?', whereArgs: [id]);
      Db.bump(c.id);
      return true;
    } catch (e) {
      DLog.d('push', 'failed $id: $e');
      return false;
    }
  }

  static Future<void> flushPending() async {
    if (_flushing || me.isEmpty) return;
    _flushing = true;
    try {
      final rows = await Db.d.query('msgs', columns: ['id'], where: 'pending=1 AND sender=?', whereArgs: [me], orderBy: 'ts ASC');
      for (final r in rows) {
        if (!await push(r['id'] as String)) break;
      }
      await _flushRcpts();
    } finally {
      _flushing = false;
    }
  }

  static Future<void> edit(Msg m, ChatRow c, String text) async {
    var wire = text;
    if (!c.isChannel) {
      final k = await Keys.forChat(c);
      if (k == null) throw 'no key';
      wire = await Crypt.seal(k, text);
    }
    await sb.from('messages').update({'body': wire, 'edited': true}).eq('id', m.id);
    await Db.d.update('msgs', {'body': text, 'edited': 1}, where: 'id=?', whereArgs: [m.id]);
    Db.bump(c.id);
  }

  static Future<void> deleteForEveryone(Msg m) async {
    await sb.from('messages').update({'deleted': true, 'body': '', 'media_url': null}).eq('id', m.id);
    await Db.d.update('msgs', {'del_all': 1, 'body': '', 'media_url': null, 'pinned': 0}, where: 'id=?', whereArgs: [m.id]);
    final u = m.mediaUrl;
    if (u != null && u.startsWith(Cfg.supabaseUrl)) {
      final i = u.indexOf('/media/');
      if (i > 0) {
        try {
          await sb.storage.from('media').remove([Uri.decodeComponent(u.substring(i + 7))]);
        } catch (_) {}
      }
    }
    Db.bump(m.chatId);
  }

  static Future<void> deleteForMe(Msg m) async {
    await Db.d.update('msgs', {'del_me': 1}, where: 'id=?', whereArgs: [m.id]);
    Db.bump(m.chatId);
  }

  static Future<void> togglePin(Msg m) async {
    final v = !m.pinned;
    await sb.from('messages').update({'pinned': v}).eq('id', m.id);
    await Db.d.update('msgs', {'pinned': v ? 1 : 0}, where: 'id=?', whereArgs: [m.id]);
    Db.bump(m.chatId);
  }

  static Future<void> refreshProfile(String uid) async {
    try {
      final row = await sb.from('profiles').select().eq('uid', uid).maybeSingle();
      if (row != null) await Db.putProfile(Profile.server(row));
    } catch (_) {}
  }

  // ── chats ──
  static String _clean(String q) => q.replaceAll(RegExp(r'[,()%*\\]'), ' ').trim();

  static Future<List<Profile>> searchUsers(String q) async {
    final s = _clean(q);
    if (s.isEmpty) return [];
    final rows = await sb.from('profiles').select().or('username.ilike.%$s%,name.ilike.%$s%').neq('uid', me).limit(25);
    return [for (final r in rows) Profile.server(r)];
  }

  static Future<List<ChatRow>> searchChannels(String q) async {
    final s = _clean(q);
    var f = sb.from('chats').select().eq('kind', 'channel');
    final rows = s.isEmpty ? await f.limit(30) : await f.ilike('name', '%$s%').limit(30);
    return [
      for (final r in rows)
        ChatRow(id: r['id'] as String, kind: 'channel', name: (r['name'] ?? '') as String, photo: r['photo'] as String?, owner: r['owner'] as String?, created: _isoMs(r['created_at']))
    ];
  }

  static Future<ChatRow> openArtee() async {
    await ArteeAi.ensureChat();
    return (await Db.chat(ArteeAi.chatId)) ?? ArteeAi.chatRow();
  }

  static Future<ChatRow> openDirect(Profile peer) async {
    final ids = [me, peer.uid]..sort();
    final id = 'd_${ids[0]}_${ids[1]}';
    final ex = await Db.chat(id);
    if (ex != null) return ex;
    await sb.from('chats').upsert({'id': id, 'kind': 'direct', 'name': '', 'owner': me});
    await sb.from('chat_members').upsert([
      {'chat_id': id, 'uid': me, 'role': 'member'},
      {'chat_id': id, 'uid': peer.uid, 'role': 'member'},
    ]);
    await Db.putProfile(peer);
    final c = ChatRow(id: id, kind: 'direct', owner: me, peer: peer.uid, created: nowMs());
    await Db.putChat(c);
    await Db.setMembers(id, [
      {'uid': me}, {'uid': peer.uid}
    ]);
    Db.bump(id);
    return c;
  }

  static Future<ChatRow> createGroup(String name, List<Profile> others) async {
    final id = newId();
    final gk = List<int>.generate(32, (_) => _rnd.nextInt(256));
    final all = [meP!, ...others];
    for (final u in others) {
      if (u.pubkey == null || u.pubkey!.isEmpty) throw '${u.name} has not set up encryption yet';
    }
    await sb.from('chats').insert({'id': id, 'kind': 'group', 'name': name, 'owner': me});
    await sb.from('chat_members').insert([
      for (final u in all) {'chat_id': id, 'uid': u.uid, 'role': u.uid == me ? 'admin' : 'member'}
    ]);
    final wraps = <Map<String, dynamic>>[];
    for (final u in others) {
      final k = await Crypt.pair(u.pubkey!);
      wraps.add({'chat_id': id, 'uid': u.uid, 'from_uid': me, 'wrapped': await Crypt.seal(k, base64Encode(gk))});
    }
    await sb.from('group_keys').insert(wraps);
    await Keys.saveGroup(id, gk);
    for (final u in others) await Db.putProfile(u);
    final c = ChatRow(id: id, kind: 'group', name: name, owner: me, created: nowMs());
    await Db.putChat(c);
    await Db.setMembers(id, [for (final u in all) {'uid': u.uid, 'role': u.uid == me ? 'admin' : 'member'}]);
    Db.bump(id);
    return c;
  }

  static Future<ChatRow> createChannel(String name) async {
    final id = newId();
    await sb.from('chats').insert({'id': id, 'kind': 'channel', 'name': name, 'owner': me});
    await sb.from('chat_members').insert({'chat_id': id, 'uid': me, 'role': 'admin'});
    final c = ChatRow(id: id, kind: 'channel', name: name, owner: me, created: nowMs());
    await Db.putChat(c);
    await Db.setMembers(id, [
      {'uid': me, 'role': 'admin'}
    ]);
    Db.bump(id);
    return c;
  }

  static Future<ChatRow> joinChannel(ChatRow c) async {
    await sb.from('chat_members').upsert({'chat_id': c.id, 'uid': me, 'role': 'member'});
    await Db.putChat(ChatRow(id: c.id, kind: 'channel', name: c.name, photo: c.photo, owner: c.owner, created: c.created));
    await sync();
    return (await Db.chat(c.id)) ?? c;
  }

  static Future<String> uploadAvatar(String path) async {
    final key = 'avatars/${me}_${nowMs()}.jpg';
    await sb.storage.from('media').upload(key, File(path), fileOptions: FileOptions(contentType: 'image/jpeg', upsert: true));
    return sb.storage.from('media').getPublicUrl(key);
  }
}

// ───────────────────────── App entry ─────────────────────────
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  FlutterError.onError = (d) => DLog.d('flutter', d.exceptionAsString());
  ui.PlatformDispatcher.instance.onError = (e, s) {
    DLog.d('error', '$e');
    return true;
  };
  Prefs.sp = await SharedPreferences.getInstance();
  runApp(const RtApp());
}

void onNotif(NotificationResponse r) {
  final id = r.payload;
  if (id == null) return;
  if (r.actionId == 'reply') {
    final t = r.input?.trim();
    if (t != null && t.isNotEmpty) Svc.replyFromNotif(id, t);
    return;
  }
  Svc.openFromNotif(id);
}

class Boot {
  static Future<void> init() async {
    if (!Cfg.configured) return;
    // Firebase is optional; local identity does not need it.
    if (Cfg.firebaseConfigured) {
      try {
        await Firebase.initializeApp(
            options: FirebaseOptions(apiKey: Cfg.fbApiKey, appId: Cfg.fbAppId, messagingSenderId: Cfg.fbSender, projectId: Cfg.fbProject));
      } catch (e) {
        DLog.d('boot', 'firebase: $e');
      }
    }
    await Supabase.initialize(url: Cfg.supabaseUrl, anonKey: Cfg.supabaseAnon);
    await Notif.init(onNotif);
    DLog.d('boot', 'ready');
  }
}

ThemeData buildTheme(Brightness b) {
  final acc = accents[Prefs.accent];
  final dark = b == Brightness.dark;
  final cs = ColorScheme.fromSeed(
    seedColor: acc,
    brightness: b,
    surface: dark ? const Color(0xFF0B141A) : const Color(0xFFF7F8FA),
  );
  return ThemeData(
    useMaterial3: true,
    colorScheme: cs,
    scaffoldBackgroundColor: dark ? const Color(0xFF0B141A) : const Color(0xFFF0F2F5),
    splashFactory: InkRipple.splashFactory,
    pageTransitionsTheme: const PageTransitionsTheme(builders: {
      TargetPlatform.android: CupertinoPageTransitionsBuilder(),
    }),
    appBarTheme: AppBarTheme(
      backgroundColor: dark ? const Color(0xFF1A242D) : Colors.white,
      foregroundColor: dark ? Colors.white : const Color(0xFF111B21),
      elevation: 0,
      scrolledUnderElevation: 0.8,
      centerTitle: false,
      titleTextStyle: TextStyle(
        fontSize: 18,
        fontWeight: FontWeight.w700,
        color: dark ? Colors.white : const Color(0xFF111B21),
      ),
    ),
    floatingActionButtonTheme: FloatingActionButtonThemeData(
      backgroundColor: acc,
      foregroundColor: Colors.white,
      elevation: 4,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
    ),
    dividerColor: dark ? Colors.white10 : Colors.black12,
  );
}

class Pal {
  final Color wall, mine, other, text, sub, tick;
  Pal(this.wall, this.mine, this.other, this.text, this.sub, this.tick);
  static Pal of(BuildContext c) {
    final dark = Theme.of(c).brightness == Brightness.dark;
    final acc = accents[Prefs.accent];
    return Pal(
      walls[Prefs.wall][dark ? 1 : 0],
      dark ? Color.alphaBlend(acc.withOpacity(0.48), const Color(0xFF0B1F18)) : Color.alphaBlend(acc.withOpacity(0.22), const Color(0xFFF0FFF8)),
      dark ? const Color(0xFF1A2730) : const Color(0xFFFFFFFF),
      dark ? const Color(0xFFF2F5F7) : const Color(0xFF0B141A),
      dark ? const Color(0xFF8B9CA6) : const Color(0xFF5B6B75),
      const Color(0xFF53BDEB),
    );
  }
}

class RtApp extends StatefulWidget {
  const RtApp({super.key});
  @override
  State<RtApp> createState() => _RtAppState();
}

class _RtAppState extends State<RtApp> {
  late final Future<void> boot = Boot.init();

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<int>(
      valueListenable: Prefs.rev,
      builder: (_, __, ___) => MaterialApp(
        title: Cfg.appName,
        navigatorKey: navKey,
        debugShowCheckedModeBanner: false,
        theme: buildTheme(Brightness.light),
        darkTheme: buildTheme(Brightness.dark),
        themeMode: const [ThemeMode.system, ThemeMode.light, ThemeMode.dark][Prefs.themeMode],
        home: FutureBuilder<void>(
          future: boot,
          builder: (c, s) {
            if (s.connectionState != ConnectionState.done) return const Splash();
            if (s.hasError) return InfoScreen(title: 'Startup problem', text: '${s.error}');
            if (!Cfg.configured) {
              return const InfoScreen(
                  title: 'Setup needed',
                  text: 'This build has no Supabase keys. Add SUPABASE_URL and SUPABASE_ANON_KEY as GitHub secrets and run the workflow again.');
            }
            return const AuthGate();
          },
        ),
      ),
    );
  }
}

class Splash extends StatelessWidget {
  const Splash({super.key});
  @override
  Widget build(BuildContext context) => Scaffold(
        body: Center(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Icon(Icons.chat_bubble, size: 64, color: accents[Prefs.accent]),
            const SizedBox(height: 12),
            const Text(Cfg.appName, style: TextStyle(fontSize: 26, fontWeight: FontWeight.w700)),
          ]),
        ),
      );
}

class InfoScreen extends StatelessWidget {
  final String title, text;
  final VoidCallback? onRetry;
  const InfoScreen({super.key, required this.title, required this.text, this.onRetry});
  @override
  Widget build(BuildContext context) => Scaffold(
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(28),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Text(title, style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w700)),
              const SizedBox(height: 12),
              Text(text, textAlign: TextAlign.center),
              if (onRetry != null) ...[
                const SizedBox(height: 16),
                FilledButton(onPressed: onRetry, child: const Text('Retry')),
                TextButton(onPressed: signOut, child: const Text('Sign out')),
              ],
            ]),
          ),
        ),
      );
}

Future<void> signOut() async {
  await Svc.stop();
  await LocalAuth.clear();
  try {
    if (Cfg.firebaseConfigured) await fb.FirebaseAuth.instance.signOut();
  } catch (_) {}
  try {
    await GoogleSignIn().signOut();
  } catch (_) {}
  LocalAuth.rev.value++;
}

Future<String?> askText(BuildContext c, String title, {String hint = '', String initial = '', int maxLen = 60, bool obscure = false}) {
  final ctl = TextEditingController(text: initial);
  return showDialog<String>(
    context: c,
    builder: (dc) => AlertDialog(
      title: Text(title),
      content: TextField(controller: ctl, autofocus: true, maxLength: maxLen, obscureText: obscure, decoration: InputDecoration(hintText: hint)),
      actions: [
        TextButton(onPressed: () => Navigator.pop(dc), child: const Text('Cancel')),
        FilledButton(onPressed: () => Navigator.pop(dc, ctl.text.trim()), child: const Text('OK')),
      ],
    ),
  );
}

class Avatar extends StatelessWidget {
  final String? url;
  final String name;
  final double r;
  final IconData? icon;
  const Avatar({super.key, this.url, this.name = '', this.r = 24, this.icon});
  @override
  Widget build(BuildContext context) {
    final bg = Theme.of(context).colorScheme.primaryContainer;
    final fg = Theme.of(context).colorScheme.onPrimaryContainer;
    if (url != null && url!.isNotEmpty) {
      return CircleAvatar(radius: r, backgroundColor: bg, backgroundImage: CachedNetworkImageProvider(url!, maxWidth: 200));
    }
    return CircleAvatar(
      radius: r,
      backgroundColor: bg,
      child: icon != null
          ? Icon(icon, size: r, color: fg)
          : Text(name.isEmpty ? '?' : String.fromCharCode(name.runes.first).toUpperCase(),
              style: TextStyle(fontSize: r * 0.8, color: fg, fontWeight: FontWeight.w600)),
    );
  }
}

// ───────────────────────── Auth (local identity + optional PIN recovery) ─────────────────────────
class AuthGate extends StatefulWidget {
  const AuthGate({super.key});
  @override
  State<AuthGate> createState() => _AuthGateState();
}

class _AuthGateState extends State<AuthGate> {
  Future<String?>? _uid;

  @override
  void initState() {
    super.initState();
    LocalAuth.rev.addListener(_reload);
    _uid = LocalAuth.readUid();
  }

  @override
  void dispose() {
    LocalAuth.rev.removeListener(_reload);
    super.dispose();
  }

  void _reload() {
    if (!mounted) return;
    setState(() => _uid = LocalAuth.readUid());
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<String?>(
        future: _uid,
        builder: (c, s) {
          if (s.connectionState != ConnectionState.done) return const Splash();
          if (s.hasError) {
            return InfoScreen(
              title: 'Could not start',
              text: '${s.error}',
              onRetry: () => setState(() => _uid = LocalAuth.readUid()),
            );
          }
          final uid = s.data;
          if (uid != null && uid.isNotEmpty) {
            return SessionGate(key: ValueKey('${uid}-${LocalAuth.rev.value}'), uid: uid);
          }
          return const WelcomeScreen();
        },
      );
}

class WelcomeScreen extends StatelessWidget {
  const WelcomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final acc = accents[Prefs.accent];
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Column(children: [
            const Spacer(),
            Icon(Icons.chat_bubble, size: 72, color: acc),
            const SizedBox(height: 14),
            const Text(Cfg.appName, style: TextStyle(fontSize: 30, fontWeight: FontWeight.w800)),
            const SizedBox(height: 8),
            const Text('Simple, fast, private messaging.', textAlign: TextAlign.center),
            const Spacer(),
            SizedBox(
              width: double.infinity,
              height: 50,
              child: FilledButton(
                onPressed: () async {
                  await LocalAuth.newUid();
                  LocalAuth.rev.value++;
                },
                child: const Text('Create account'),
              ),
            ),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              height: 50,
              child: OutlinedButton(
                onPressed: () {
                  Navigator.of(context).push(MaterialPageRoute(builder: (_) => const LoginScreen()));
                },
                child: const Text('Log in with username'),
              ),
            ),
            const SizedBox(height: 24),
          ]),
        ),
      ),
    );
  }
}

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});
  @override
  State<LoginScreen> createState() => _LoginState();
}

class _LoginState extends State<LoginScreen> {
  final un = TextEditingController();
  final pin = TextEditingController();
  bool busy = false;
  String? err;

  Future<void> _go() async {
    final u = un.text.trim().toLowerCase();
    if (u.isEmpty) {
      setState(() => err = 'Enter your username.');
      return;
    }
    setState(() {
      busy = true;
      err = null;
    });
    try {
      await Svc.loginWithUsername(u, pin.text.trim());
      if (mounted) Navigator.of(context).pop(); // AuthGate rebuilds via LocalAuth.rev
    } catch (e) {
      if (mounted) {
        setState(() {
          busy = false;
          err = '$e';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Log in')),
        body: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(children: [
            const Text(
              'Use the username from an account you already created. '
              'If that account has a PIN, enter it. Older accounts (before PIN support) only need the username.',
              style: TextStyle(fontSize: 13),
            ),
            const SizedBox(height: 20),
            TextField(
              controller: un,
              autocorrect: false,
              decoration: const InputDecoration(labelText: 'Username', prefixText: '@', border: OutlineInputBorder()),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: pin,
              obscureText: true,
              keyboardType: TextInputType.number,
              maxLength: 8,
              decoration: const InputDecoration(
                labelText: 'PIN (if you set one)',
                border: OutlineInputBorder(),
                helperText: '4–8 digits. Leave blank for accounts made before PINs.',
              ),
            ),
            if (err != null) Padding(padding: const EdgeInsets.only(top: 8), child: Text(err!, style: const TextStyle(color: Colors.redAccent))),
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              height: 48,
              child: FilledButton(
                onPressed: busy ? null : _go,
                child: busy ? const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2)) : const Text('Log in'),
              ),
            ),
          ]),
        ),
      );
}

class SessionGate extends StatefulWidget {
  final String uid;
  const SessionGate({super.key, required this.uid});
  @override
  State<SessionGate> createState() => _SessionGateState();
}

class _SessionGateState extends State<SessionGate> {
  late Future<bool> f = Svc.start(widget.uid);
  bool done = false;

  @override
  Widget build(BuildContext context) => FutureBuilder<bool>(
        future: f,
        builder: (c, s) {
          if (s.connectionState != ConnectionState.done) return const Splash();
          if (s.hasError) {
            return InfoScreen(
                title: 'Could not start',
                text: 'Please check your internet connection.\n${s.error}',
                onRetry: () => setState(() => f = Svc.start(widget.uid)));
          }
          if (s.data! && !done) return OnboardScreen(onDone: () => setState(() => done = true));
          return const HomeScreen();
        },
      );
}

class OnboardScreen extends StatefulWidget {
  final VoidCallback onDone;
  const OnboardScreen({super.key, required this.onDone});
  @override
  State<OnboardScreen> createState() => _OnboardState();
}

class _OnboardState extends State<OnboardScreen> {
  late final TextEditingController un = TextEditingController();
  late final TextEditingController nm = TextEditingController();
  late final TextEditingController pin = TextEditingController();
  late final TextEditingController pin2 = TextEditingController();
  bool busy = false;
  String? err;

  Future<void> _save() async {
    final u = un.text.trim().toLowerCase();
    final n = nm.text.trim();
    final p = pin.text.trim();
    final p2 = pin2.text.trim();
    if (!RegExp(r'^[a-z0-9_]{3,20}$').hasMatch(u)) {
      setState(() => err = 'Username: 3-20 letters, numbers or underscore.');
      return;
    }
    if (n.isEmpty) {
      setState(() => err = 'Enter your name.');
      return;
    }
    if (!RegExp(r'^\d{4,8}$').hasMatch(p)) {
      setState(() => err = 'PIN must be 4–8 digits (you will need it if you reinstall).');
      return;
    }
    if (p != p2) {
      setState(() => err = 'PINs do not match.');
      return;
    }
    setState(() {
      busy = true;
      err = null;
    });
    try {
      await Svc.createProfile(u, n, pin: p);
      widget.onDone();
    } on PostgrestException catch (e) {
      setState(() {
        busy = false;
        err = e.code == '23505' ? 'That username is taken. Try another.' : 'Could not save: ${e.message}';
      });
    } catch (e) {
      setState(() {
        busy = false;
        err = 'Could not save. Check your connection.\n$e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final acc = accents[Prefs.accent];
    return Scaffold(
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            const SizedBox(height: 12),
            Icon(Icons.chat_bubble, size: 56, color: acc),
            const SizedBox(height: 10),
            const Text(Cfg.appName, textAlign: TextAlign.center, style: TextStyle(fontSize: 26, fontWeight: FontWeight.w800)),
            const SizedBox(height: 8),
            const Text('Choose a name, username and PIN. The PIN lets you recover this account after reinstalling.', textAlign: TextAlign.center),
            const SizedBox(height: 24),
            TextField(controller: nm, maxLength: 40, textCapitalization: TextCapitalization.words, decoration: const InputDecoration(labelText: 'Your name', border: OutlineInputBorder())),
            const SizedBox(height: 12),
            TextField(
                controller: un,
                maxLength: 20,
                autocorrect: false,
                decoration: const InputDecoration(labelText: 'Username (unique)', prefixText: '@', border: OutlineInputBorder())),
            const SizedBox(height: 12),
            TextField(
                controller: pin,
                obscureText: true,
                keyboardType: TextInputType.number,
                maxLength: 8,
                decoration: const InputDecoration(labelText: 'PIN (4–8 digits)', border: OutlineInputBorder())),
            const SizedBox(height: 12),
            TextField(
                controller: pin2,
                obscureText: true,
                keyboardType: TextInputType.number,
                maxLength: 8,
                decoration: const InputDecoration(labelText: 'Confirm PIN', border: OutlineInputBorder())),
            if (err != null) Padding(padding: const EdgeInsets.only(top: 8), child: Text(err!, style: const TextStyle(color: Colors.redAccent))),
            const SizedBox(height: 16),
            SizedBox(
                height: 50,
                child: FilledButton(
                    onPressed: busy ? null : _save,
                    child: busy ? const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2)) : const Text('Continue'))),
            const SizedBox(height: 12),
            TextButton(onPressed: signOut, child: const Text('Back / reset')),
          ]),
        ),
      ),
    );
  }
}

// ───────────────────────── Home ─────────────────────────
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});
  @override
  State<HomeScreen> createState() => _HomeState();
}

class _HomeState extends State<HomeScreen> with WidgetsBindingObserver, SingleTickerProviderStateMixin {
  late final TabController tc = TabController(length: 2, vsync: this);
  List<ChatItem> items = [];
  Map<String, Profile> pm = {};
  StreamSubscription<String>? sub;
  bool syncing = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    tc.addListener(() {
      if (!tc.indexIsChanging) setState(() {});
    });
    sub = Db.changes.listen((_) => load());
    unawaited(ArteeAi.ensureChat());
    load();
    Svc.begin().whenComplete(() {
      if (mounted) setState(() => syncing = false);
      load();
    });
    Notif.launchChatId().then((id) {
      if (id != null) Svc.openFromNotif(id);
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState s) => Svc.onLifecycle(s);

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    sub?.cancel();
    tc.dispose();
    super.dispose();
  }

  Future<void> load() async {
    final l = await Db.chatList(Svc.me);
    final m = await Db.profileMap();
    if (mounted) {
      setState(() {
        items = l;
        pm = m;
      });
    }
  }

  Widget list(bool channels) {
    final l = items.where((e) => e.chat.isChannel == channels).toList();
    if (l.isEmpty) {
      return Center(
          child: Padding(
        padding: const EdgeInsets.all(32),
        child: Text(channels ? 'No channels yet.\nTap + to discover or create one.' : 'Your chats live here.\nTap + to message someone, or open Artee AI from the menu.',
            textAlign: TextAlign.center),
      ));
    }
    return ListView.builder(
      itemCount: l.length,
      itemExtent: 72,
      itemBuilder: (c, i) => ChatTile(item: l[i], pm: pm),
    );
  }

  @override
  Widget build(BuildContext context) {
    final acc = accents[Prefs.accent];
    return Scaffold(
      appBar: AppBar(
        title: Text(Cfg.appName, style: TextStyle(fontWeight: FontWeight.w800, color: acc)),
        actions: [
          PopupMenuButton<String>(
            onSelected: (v) async {
              if (v == 'artee') {
                final c = await Svc.openArtee();
                if (context.mounted) Navigator.push(context, MaterialPageRoute(builder: (_) => ChatScreen(chat: c)));
              }
              if (v == 'group') Navigator.push(context, MaterialPageRoute(builder: (_) => const UserSearchScreen(group: true)));
              if (v == 'settings') Navigator.push(context, MaterialPageRoute(builder: (_) => const SettingsScreen()));
            },
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'artee', child: Text('Artee AI')),
              PopupMenuItem(value: 'group', child: Text('New group')),
              PopupMenuItem(value: 'settings', child: Text('Settings')),
            ],
          ),
        ],
        bottom: TabBar(controller: tc, tabs: const [Tab(text: 'Chats'), Tab(text: 'Channels')]),
      ),
      body: Column(children: [
        if (syncing) const LinearProgressIndicator(minHeight: 2),
        Expanded(child: TabBarView(controller: tc, children: [list(false), list(true)])),
      ]),
      floatingActionButton: FloatingActionButton(
        onPressed: () => Navigator.push(
            context,
            MaterialPageRoute(
                builder: (_) => tc.index == 0 ? const UserSearchScreen(group: false) : const ChannelsScreen())),
        child: Icon(tc.index == 0 ? Icons.chat : Icons.campaign),
      ),
    );
  }
}

class ChatTile extends StatelessWidget {
  final ChatItem item;
  final Map<String, Profile> pm;
  const ChatTile({super.key, required this.item, required this.pm});

  @override
  Widget build(BuildContext context) {
    final c = item.chat;
    final last = item.last;
    final pal = Pal.of(context);
    final title = chatTitle(c, pm);
    return InkWell(
      onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => ChatScreen(chat: c))),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Row(children: [
          Avatar(url: chatPhoto(c, pm), name: title, r: 26, icon: c.isAi ? Icons.auto_awesome : (c.isChannel ? Icons.campaign : (c.isGroup ? Icons.groups : null))),
          const SizedBox(width: 14),
          Expanded(
            child: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
              const SizedBox(height: 3),
              Row(children: [
                if (last != null && last.mine && !c.isChannel && !last.delAll) ...[Ticks(m: last, size: 15), const SizedBox(width: 3)],
                Expanded(
                  child: Text(
                    last == null ? (c.isChannel ? 'Channel' : 'Say hi 👋') : (last.mine && last.kind == 'text' ? 'You: ' : '') + previewOf(last),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: pal.sub, fontStyle: last?.delAll == true ? FontStyle.italic : FontStyle.normal),
                  ),
                ),
              ]),
            ]),
          ),
          const SizedBox(width: 8),
          Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.end, children: [
            Text(last == null ? '' : listTime(last.ts),
                style: TextStyle(fontSize: 12, color: item.unread > 0 ? accents[Prefs.accent] : pal.sub)),
            const SizedBox(height: 4),
            if (item.unread > 0)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                decoration: BoxDecoration(color: accents[Prefs.accent], borderRadius: BorderRadius.circular(12)),
                child: Text('${item.unread}', style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w600)),
              )
            else
              const SizedBox(height: 18),
          ]),
        ]),
      ),
    );
  }
}

// ───────────────────────── Find people / create group ─────────────────────────
class UserSearchScreen extends StatefulWidget {
  final bool group;
  const UserSearchScreen({super.key, required this.group});
  @override
  State<UserSearchScreen> createState() => _UserSearchState();
}

class _UserSearchState extends State<UserSearchScreen> {
  final ctl = TextEditingController();
  List<Profile> res = [];
  final Map<String, Profile> sel = {};
  Timer? deb;
  bool busy = false, searched = false;

  void _changed(String q) {
    deb?.cancel();
    deb = Timer(const Duration(milliseconds: 350), () async {
      if (q.trim().isEmpty) {
        setState(() {
          res = [];
          searched = false;
        });
        return;
      }
      try {
        final r = await Svc.searchUsers(q);
        if (mounted) {
          setState(() {
            res = r;
            searched = true;
          });
        }
      } catch (e) {
        DLog.d('search', '$e');
        if (mounted) toast(context, 'Search failed. Check your connection.');
      }
    });
  }

  Future<void> _open(ChatRow c) async {
    if (!mounted) return;
    Navigator.pushReplacement(context, MaterialPageRoute(builder: (_) => ChatScreen(chat: c)));
  }

  Future<void> _tap(Profile pr) async {
    if (widget.group) {
      setState(() => sel.containsKey(pr.uid) ? sel.remove(pr.uid) : sel[pr.uid] = pr);
      return;
    }
    if (pr.pubkey == null || pr.pubkey!.isEmpty) {
      toast(context, '${pr.name} has not finished setting up yet.');
      return;
    }
    setState(() => busy = true);
    try {
      await _open(await Svc.openDirect(pr));
    } catch (e) {
      DLog.d('chat', 'open direct failed: $e');
      if (mounted) {
        setState(() => busy = false);
        toast(context, 'Could not start chat. Check your connection.');
      }
    }
  }

  Future<void> _next() async {
    final name = await askText(context, 'Group name', hint: 'e.g. Weekend plans');
    if (name == null || name.isEmpty) return;
    setState(() => busy = true);
    try {
      await _open(await Svc.createGroup(name, sel.values.toList()));
    } catch (e) {
      DLog.d('group', 'create failed: $e');
      if (mounted) {
        setState(() => busy = false);
        toast(context, 'Could not create group: $e');
      }
    }
  }

  @override
  void dispose() {
    deb?.cancel();
    ctl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(
          title: TextField(
            controller: ctl,
            autofocus: true,
            onChanged: _changed,
            decoration: InputDecoration(hintText: widget.group ? 'Add members: search username or name' : 'Search username or name', border: InputBorder.none),
          ),
        ),
        body: Column(children: [
          if (busy) const LinearProgressIndicator(minHeight: 2),
          if (widget.group && sel.isNotEmpty)
            SizedBox(
              height: 52,
              child: ListView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                children: [
                  for (final u in sel.values)
                    Padding(
                      padding: const EdgeInsets.only(right: 6),
                      child: InputChip(label: Text(u.name.isEmpty ? u.username : u.name), onDeleted: () => setState(() => sel.remove(u.uid))),
                    )
                ],
              ),
            ),
          Expanded(
            child: res.isEmpty
                ? Center(child: Text(searched ? 'No one found.' : 'Type a username to find people.'))
                : ListView.builder(
                    itemCount: res.length,
                    itemBuilder: (c, i) {
                      final u = res[i];
                      return ListTile(
                        leading: Avatar(url: u.photo, name: u.name),
                        title: Text(u.name.isEmpty ? '@${u.username}' : u.name),
                        subtitle: Text('@${u.username}${u.about == null || u.about!.isEmpty ? '' : ' · ${u.about}'}', maxLines: 1, overflow: TextOverflow.ellipsis),
                        trailing: widget.group ? Checkbox(value: sel.containsKey(u.uid), onChanged: (_) => _tap(u)) : null,
                        onTap: busy ? null : () => _tap(u),
                      );
                    }),
          ),
        ]),
        floatingActionButton: widget.group && sel.isNotEmpty && !busy
            ? FloatingActionButton(onPressed: _next, child: const Icon(Icons.arrow_forward))
            : null,
      );
}

class ChannelsScreen extends StatefulWidget {
  const ChannelsScreen({super.key});
  @override
  State<ChannelsScreen> createState() => _ChannelsState();
}

class _ChannelsState extends State<ChannelsScreen> {
  final ctl = TextEditingController();
  List<ChatRow> res = [];
  Timer? deb;
  bool busy = false;

  @override
  void initState() {
    super.initState();
    _search('');
  }

  Future<void> _search(String q) async {
    try {
      final r = await Svc.searchChannels(q);
      if (mounted) setState(() => res = r);
    } catch (e) {
      DLog.d('channels', '$e');
    }
  }

  void _changed(String q) {
    deb?.cancel();
    deb = Timer(const Duration(milliseconds: 350), () => _search(q));
  }

  Future<void> _open(ChatRow c, {bool join = false}) async {
    setState(() => busy = true);
    try {
      final local = await Db.chat(c.id);
      final ch = local ?? (join ? await Svc.joinChannel(c) : c);
      if (mounted) Navigator.pushReplacement(context, MaterialPageRoute(builder: (_) => ChatScreen(chat: ch)));
    } catch (e) {
      DLog.d('channels', 'open failed $e');
      if (mounted) {
        setState(() => busy = false);
        toast(context, 'Could not open channel.');
      }
    }
  }

  Future<void> _create() async {
    final name = await askText(context, 'Channel name');
    if (name == null || name.isEmpty) return;
    setState(() => busy = true);
    try {
      final c = await Svc.createChannel(name);
      if (mounted) Navigator.pushReplacement(context, MaterialPageRoute(builder: (_) => ChatScreen(chat: c)));
    } catch (e) {
      if (mounted) {
        setState(() => busy = false);
        toast(context, 'Could not create channel.');
      }
    }
  }

  @override
  void dispose() {
    deb?.cancel();
    ctl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(
          title: TextField(controller: ctl, onChanged: _changed, decoration: const InputDecoration(hintText: 'Find channels', border: InputBorder.none)),
          actions: [IconButton(tooltip: 'Create channel', icon: const Icon(Icons.add_circle_outline), onPressed: busy ? null : _create)],
        ),
        body: Column(children: [
          if (busy) const LinearProgressIndicator(minHeight: 2),
          Expanded(
            child: res.isEmpty
                ? const Center(child: Text('No channels found.'))
                : ListView.builder(
                    itemCount: res.length,
                    itemBuilder: (c, i) => ListTile(
                      leading: Avatar(url: res[i].photo, name: res[i].name, icon: Icons.campaign),
                      title: Text(res[i].name),
                      trailing: TextButton(onPressed: busy ? null : () => _open(res[i], join: true), child: const Text('Open')),
                      onTap: busy ? null : () => _open(res[i], join: true),
                    ),
                  ),
          ),
        ]),
      );
}

// ───────────────────────── Chat screen ─────────────────────────
class ChatScreen extends StatefulWidget {
  final ChatRow chat;
  const ChatScreen({super.key, required this.chat});
  @override
  State<ChatScreen> createState() => _ChatState();
}

class _ChatState extends State<ChatScreen> {
  late ChatRow chat = widget.chat;
  List<Msg> msgs = [];
  Map<String, Profile> profs = {};
  Map<String, Msg> byId = {};
  int limit = 50, members = 0;
  bool more = true, panel = false, hasText = false;
  bool recording = false, recLock = false;
  DateTime? recStarted;
  Timer? _recTick;
  int recSecs = 0;
  Msg? replyTo, editing;
  final ctl = TextEditingController();
  final focus = FocusNode();
  final scroll = ScrollController();
  final AudioRecorder _rec = AudioRecorder();
  String? _recPath;
  StreamSubscription<String>? sub;

  bool get canPost => chat.isAi || !chat.isChannel || chat.owner == Svc.me;
  bool get canVoice => canPost && !chat.isAi && editing == null;

  @override
  void initState() {
    super.initState();
    Svc.openChatId = chat.id;
    sub = Db.changes.where((id) => id == chat.id || id == '*').listen((_) => load());
    ctl.addListener(() {
      final h = ctl.text.trim().isNotEmpty;
      if (h != hasText) setState(() => hasText = h);
    });
    focus.addListener(() {
      if (focus.hasFocus && panel) setState(() => panel = false);
    });
    scroll.addListener(() {
      if (more && scroll.hasClients && scroll.position.pixels > scroll.position.maxScrollExtent - 300) {
        more = false;
        limit += 50;
        load();
      }
    });
    load();
    if (chat.isDirect && chat.peer != null) {
      Svc.refreshProfile(chat.peer!).then((_) => Db.bump(chat.id));
    }
  }

  @override
  void dispose() {
    if (Svc.openChatId == chat.id) Svc.openChatId = null;
    sub?.cancel();
    ctl.dispose();
    focus.dispose();
    scroll.dispose();
    _recTick?.cancel();
    unawaited(_rec.dispose());
    super.dispose();
  }

  Future<bool> _ensureMic() async {
    final st = await Permission.microphone.request();
    if (!st.isGranted) {
      if (mounted) toast(context, 'Microphone permission is required for voice messages.');
      return false;
    }
    return true;
  }

  Future<void> startVoice() async {
    if (!canVoice || recording || recLock) return;
    if (!await _ensureMic()) return;
    recLock = true;
    try {
      final dir = await getTemporaryDirectory();
      final path = p.join(dir.path, 'voice_${DateTime.now().millisecondsSinceEpoch}.m4a');
      if (await _rec.hasPermission()) {
        await _rec.start(const RecordConfig(encoder: AudioEncoder.aacLc, bitRate: 96000, sampleRate: 44100), path: path);
        _recPath = path;
        recStarted = DateTime.now();
        recSecs = 0;
        _recTick?.cancel();
        _recTick = Timer.periodic(const Duration(seconds: 1), (_) {
          if (!mounted || !recording) return;
          setState(() => recSecs = DateTime.now().difference(recStarted!).inSeconds);
        });
        if (mounted) setState(() => recording = true);
        HapticFeedback.lightImpact();
      }
    } catch (e) {
      DLog.d('voice', 'start: $e');
      if (mounted) toast(context, 'Could not start recording.');
    } finally {
      recLock = false;
    }
  }

  Future<void> cancelVoice() async {
    _recTick?.cancel();
    _recTick = null;
    try {
      await _rec.stop();
    } catch (_) {}
    final path = _recPath;
    _recPath = null;
    recStarted = null;
    recSecs = 0;
    if (path != null) {
      try {
        final f = File(path);
        if (await f.exists()) await f.delete();
      } catch (_) {}
    }
    if (mounted) setState(() => recording = false);
  }

  Future<void> stopVoiceAndSend() async {
    if (!recording) return;
    _recTick?.cancel();
    _recTick = null;
    String? path;
    try {
      path = await _rec.stop();
    } catch (e) {
      DLog.d('voice', 'stop: $e');
    }
    path ??= _recPath;
    _recPath = null;
    final started = recStarted;
    recStarted = null;
    recSecs = 0;
    if (mounted) setState(() => recording = false);
    if (path == null || !File(path).existsSync()) return;
    final secs = started == null ? 1 : DateTime.now().difference(started).inSeconds.clamp(1, 600);
    if (secs < 1) {
      try {
        await File(path).delete();
      } catch (_) {}
      return;
    }
    final r = replyTo;
    if (mounted) setState(() => replyTo = null);
    try {
      await Svc.send(chat, kind: 'audio', localPath: path, name: 'voice.m4a', size: await File(path).length(), body: '$secs', replyTo: r?.id);
      toBottom();
      HapticFeedback.selectionClick();
    } catch (e) {
      DLog.d('voice', 'send: $e');
      if (mounted) toast(context, 'Could not send voice message.');
    }
  }

  Future<void> load() async {
    final l = await Db.messages(chat.id, limit);
    final pm = await Db.profileMap();
    final n = await Db.memberCount(chat.id);
    final fresh = await Db.chat(chat.id);
    if (!mounted) return;
    setState(() {
      msgs = l;
      profs = pm;
      members = n;
      if (fresh != null) chat = fresh;
      more = l.length >= limit;
      byId = {for (final m in l) m.id: m};
    });
    if (Svc.foreground && Svc.openChatId == chat.id) Svc.markRead(chat);
  }

  void insertText(String s) {
    final t = ctl.text;
    final sel = ctl.selection;
    final a = sel.isValid ? sel.start : t.length;
    final b = sel.isValid ? sel.end : t.length;
    ctl.value = TextEditingValue(text: t.replaceRange(a, b, s), selection: TextSelection.collapsed(offset: a + s.length));
  }

  void startReply(Msg m) {
    if (!canPost || m.delAll) return;
    setState(() {
      replyTo = m;
      editing = null;
    });
    focus.requestFocus();
  }

  void startEdit(Msg m) {
    setState(() {
      editing = m;
      replyTo = null;
    });
    ctl.text = m.body;
    ctl.selection = TextSelection.collapsed(offset: m.body.length);
    focus.requestFocus();
  }

  void cancelBanner() {
    setState(() {
      if (editing != null) ctl.clear();
      replyTo = null;
      editing = null;
    });
  }

  void toBottom() {
    if (scroll.hasClients) scroll.jumpTo(0);
  }

  void _burstReact(BuildContext bubbleCtx) {
    final box = bubbleCtx.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return;
    final origin = box.localToGlobal(Offset(box.size.width / 2, box.size.height / 2));
    final overlay = Overlay.of(context);
    late OverlayEntry entry;
    entry = OverlayEntry(builder: (_) => _HeartBurst(origin: origin, onDone: () => entry.remove()));
    overlay.insert(entry);
  }

  Future<void> sendText() async {
    final t = ctl.text.trim();
    if (t.isEmpty) return;
    final ed = editing;
    if (ed != null) {
      try {
        await Svc.edit(ed, chat, t);
      } catch (e) {
        DLog.d('edit', '$e');
        if (mounted) toast(context, 'Could not edit. Check your connection.');
      }
      if (mounted) setState(() => editing = null);
      ctl.clear();
      return;
    }
    final r = replyTo;
    ctl.clear();
    setState(() => replyTo = null);
    if (chat.isAi) {
      await ArteeAi.sendUserMessage(t);
    } else {
      await Svc.send(chat, body: t, replyTo: r?.id);
    }
    toBottom();
  }

  Future<void> sendPath(String path, String name, String kind) async {
    final size = await File(path).length();
    if (size > Cfg.maxUploadMb * 1024 * 1024) {
      if (mounted) toast(context, 'File too large. Max ${Cfg.maxUploadMb} MB (yours is ${fmtSize(size)}).');
      return;
    }
    final r = replyTo;
    setState(() => replyTo = null);
    await Svc.send(chat, kind: kind, localPath: path, name: name, size: size, replyTo: r?.id);
    toBottom();
  }

  Future<void> attach(String type) async {
    try {
      if (type == 'photo' || type == 'camera') {
        final low = Prefs.lowData;
        final x = await ImagePicker().pickImage(
            source: type == 'camera' ? ImageSource.camera : ImageSource.gallery, imageQuality: low ? 45 : 75, maxWidth: low ? 1024 : 1600);
        if (x != null) await sendPath(x.path, p.basename(x.path), 'image');
      } else {
        final res = await FilePicker.platform
            .pickFiles(type: type == 'video' ? FileType.video : (type == 'audio' ? FileType.audio : FileType.any));
        final f = res?.files.single;
        if (f != null && f.path != null) await sendPath(f.path!, f.name, kindOfFile(f.name));
      }
    } catch (e) {
      DLog.d('attach', '$e');
      if (mounted) toast(context, 'Could not attach that file.');
    }
  }

  void attachSheet() {
    focus.unfocus();
    Widget item(IconData i, String label, String type, Color col) => InkWell(
          onTap: () {
            Navigator.pop(context);
            attach(type);
          },
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            CircleAvatar(radius: 26, backgroundColor: col, child: Icon(i, color: Colors.white)),
            const SizedBox(height: 6),
            Text(label, style: const TextStyle(fontSize: 12)),
          ]),
        );
    showModalBottomSheet(
      context: context,
      builder: (_) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Wrap(spacing: 28, runSpacing: 18, alignment: WrapAlignment.center, children: [
            item(Icons.photo, 'Photo', 'photo', Colors.purple),
            item(Icons.photo_camera, 'Camera', 'camera', Colors.pink),
            item(Icons.videocam, 'Video', 'video', Colors.red),
            item(Icons.headphones, 'Audio', 'audio', Colors.orange),
            item(Icons.insert_drive_file, 'File', 'file', Colors.blue),
          ]),
        ),
      ),
    );
  }

  void actions(Msg m) {
    final age = nowMs() - m.ts;
    final canEdit = m.mine && m.kind == 'text' && !m.pending && !m.delAll && age < Cfg.editWindow.inMilliseconds;
    final canDelAll = m.mine && !m.pending && !m.delAll && age < Cfg.deleteWindow.inMilliseconds;
    final canPin = !m.pending && !m.delAll && (!chat.isChannel || chat.owner == Svc.me);
    final canCopy = !m.delAll && m.body.isNotEmpty && m.kind != 'sticker';
    focus.unfocus();
    Widget tile(IconData i, String t, VoidCallback f, {Color? color}) => ListTile(
          leading: Icon(i, color: color),
          title: Text(t, style: TextStyle(color: color)),
          onTap: () {
            Navigator.pop(context);
            f();
          },
        );
    showModalBottomSheet(
      context: context,
      builder: (_) => SafeArea(
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            if (canPost && !m.delAll) tile(Icons.reply, 'Reply', () => startReply(m)),
            if (canCopy)
              tile(Icons.copy, 'Copy text', () {
                Clipboard.setData(ClipboardData(text: m.body));
                toast(context, 'Copied');
              }),
            if (canEdit) tile(Icons.edit, 'Edit', () => startEdit(m)),
            if (canPin)
              tile(m.pinned ? Icons.push_pin_outlined : Icons.push_pin, m.pinned ? 'Unpin' : 'Pin message', () async {
                try {
                  await Svc.togglePin(m);
                } catch (_) {
                  if (mounted) toast(context, 'Could not update pin. Check your connection.');
                }
              }),
            tile(Icons.delete_outline, 'Delete for me', () => Svc.deleteForMe(m)),
            if (canDelAll)
              tile(Icons.delete_forever, 'Delete for everyone', () async {
                final ok = await showDialog<bool>(
                  context: context,
                  builder: (dc) => AlertDialog(
                    title: const Text('Delete for everyone?'),
                    content: const Text('This message will be removed for all members.'),
                    actions: [
                      TextButton(onPressed: () => Navigator.pop(dc, false), child: const Text('Cancel')),
                      FilledButton(onPressed: () => Navigator.pop(dc, true), child: const Text('Delete')),
                    ],
                  ),
                );
                if (ok == true) {
                  try {
                    await Svc.deleteForEveryone(m);
                  } catch (_) {
                    if (mounted) toast(context, 'Could not delete. Check your connection.');
                  }
                }
              }, color: Colors.redAccent),
          ]),
        ),
      ),
    );
  }

  void info() {
    if (chat.isDirect) return;
    showModalBottomSheet(
      context: context,
      builder: (_) => FutureBuilder<List<Map<String, Object?>>>(
        future: Db.d.query('members', where: 'chat_id=?', whereArgs: [chat.id]),
        builder: (c, s) {
          final rows = s.data ?? [];
          return SafeArea(
            child: ListView(shrinkWrap: true, children: [
              ListTile(title: Text(chat.name, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 18)), subtitle: Text(chat.isChannel ? 'Channel · $members followers' : 'Group · $members members')),
              for (final r in rows)
                ListTile(
                  leading: Avatar(url: profs[r['uid']]?.photo, name: profs[r['uid']]?.name ?? '?', r: 18),
                  title: Text(r['uid'] == Svc.me ? 'You' : (profs[r['uid']]?.name ?? 'Member')),
                  subtitle: Text('@${profs[r['uid']]?.username ?? ''}'),
                  trailing: r['role'] == 'admin' ? const Text('admin') : null,
                ),
            ]),
          );
        },
      ),
    );
  }

  Widget subtitle(Pal pal) {
    final acc = accents[Prefs.accent];
    if (chat.isDirect) {
      return ValueListenableBuilder<Set<String>>(
        valueListenable: Svc.online,
        builder: (_, s, __) {
          final on = s.contains(chat.peer);
          final t = on ? 'online' : lastSeenText(profs[chat.peer]?.lastSeen ?? 0);
          return t.isEmpty ? const SizedBox.shrink() : Text(t, style: TextStyle(fontSize: 12, color: on ? acc : pal.sub));
        },
      );
    }
    return Text(chat.isChannel ? '$members followers' : '$members members', style: TextStyle(fontSize: 12, color: pal.sub));
  }

  Widget item(int i, Pal pal) {
    final m = msgs[i];
    final older = i + 1 < msgs.length ? msgs[i + 1] : null;
    final showDay = older == null || !sameDay(older.ts, m.ts);
    final firstOfRun = older == null || showDay || older.sender != m.sender;
    final rep = m.replyTo == null ? null : byId[m.replyTo];
    return Column(key: ValueKey(m.id), children: [
      if (showDay)
        Container(
          margin: const EdgeInsets.symmetric(vertical: 8),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          decoration: BoxDecoration(color: pal.other, borderRadius: BorderRadius.circular(8)),
          child: Text(dayLabel(m.ts), style: TextStyle(fontSize: 12, color: pal.sub)),
        ),
      SwipeToReply(
        onReply: () => startReply(m),
        child: Align(
          alignment: m.mine ? Alignment.centerRight : Alignment.centerLeft,
          child: Padding(
            padding: EdgeInsets.fromLTRB(10, firstOfRun ? 6 : 1, 10, 1),
            child: MsgBubble(
              m: m,
              chat: chat,
              pal: pal,
              senderName: chat.isGroup && !m.mine && firstOfRun ? (profs[m.sender]?.name ?? 'Member') : null,
              reply: rep,
              replyName: rep == null ? null : (rep.mine ? 'You' : (profs[rep.sender]?.name ?? 'Member')),
              onLong: () => actions(m),
              onReact: () => _burstReact(context),
            ),
          ),
        ),
      ),
    ]);
  }

  @override
  Widget build(BuildContext context) {
    final pal = Pal.of(context);
    final title = chatTitle(chat, profs);
    final pinned = msgs.where((m) => m.pinned && !m.delAll).toList();
    final banner = editing ?? replyTo;
    return PopScope(
      canPop: !panel,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && panel) setState(() => panel = false);
      },
      child: Scaffold(
        backgroundColor: pal.wall,
        appBar: AppBar(
          titleSpacing: 0,
          title: InkWell(
            onTap: info,
            child: Row(children: [
              Avatar(url: chatPhoto(chat, profs), name: title, r: 19, icon: chat.isAi ? Icons.auto_awesome : (chat.isChannel ? Icons.campaign : (chat.isGroup ? Icons.groups : null))),
              const SizedBox(width: 10),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisAlignment: MainAxisAlignment.center, children: [
                  Text(title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600)),
                  subtitle(pal),
                ]),
              ),
            ]),
          ),
        ),
        body: Column(children: [
          if (pinned.isNotEmpty)
            Material(
              color: pal.other,
              child: ListTile(
                dense: true,
                leading: const Icon(Icons.push_pin, size: 18),
                title: Text(previewOf(pinned.first), maxLines: 1, overflow: TextOverflow.ellipsis),
                trailing: (!chat.isChannel || chat.owner == Svc.me)
                    ? IconButton(icon: const Icon(Icons.close, size: 18), onPressed: () => Svc.togglePin(pinned.first))
                    : null,
              ),
            ),
          Expanded(
            child: msgs.isEmpty
                ? Center(
                    child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
                        decoration: BoxDecoration(
                          color: pal.other,
                          borderRadius: BorderRadius.circular(16),
                          boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.06), blurRadius: 12, offset: const Offset(0, 4))],
                        ),
                        child: Text(
                          chat.isAi
                              ? 'Ask Artee AI anything ✨'
                              : (chat.isChannel ? 'No posts yet.' : 'No messages yet.\nHold the mic to send a voice note 🎤'),
                          textAlign: TextAlign.center,
                          style: TextStyle(color: pal.sub, height: 1.35),
                        )))
                : ListView.builder(
                    controller: scroll,
                    reverse: true,
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    itemCount: msgs.length,
                    addAutomaticKeepAlives: false,
                    itemBuilder: (c, i) => item(i, pal),
                  ),
          ),
          SafeArea(
            top: false,
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              if (banner != null)
                Container(
                  color: pal.other,
                  padding: const EdgeInsets.fromLTRB(14, 6, 4, 6),
                  child: Row(children: [
                    Icon(editing != null ? Icons.edit : Icons.reply, size: 18, color: accents[Prefs.accent]),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                          editing != null ? 'Editing message' : 'Reply to ${banner.mine ? 'yourself' : (profs[banner.sender]?.name ?? 'message')}: ${previewOf(banner)}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(color: pal.sub)),
                    ),
                    IconButton(icon: const Icon(Icons.close, size: 18), onPressed: cancelBanner),
                  ]),
                ),
              if (!canPost)
                Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(14),
                    color: pal.other,
                    child: Text('Only the channel owner can post here.', textAlign: TextAlign.center, style: TextStyle(color: pal.sub)))
              else
                Padding(
                  padding: const EdgeInsets.fromLTRB(6, 6, 6, 6),
                  child: recording
                  ? Container(
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                      decoration: BoxDecoration(
                        color: pal.other,
                        borderRadius: BorderRadius.circular(28),
                        border: Border.all(color: Colors.redAccent.withOpacity(0.5)),
                      ),
                      child: Row(children: [
                        Container(
                          width: 12,
                          height: 12,
                          decoration: const BoxDecoration(color: Colors.redAccent, shape: BoxShape.circle),
                        ),
                        const SizedBox(width: 10),
                        Text(
                          '${recSecs ~/ 60}:${(recSecs % 60).toString().padLeft(2, '0')}',
                          style: TextStyle(color: pal.text, fontWeight: FontWeight.w800, fontSize: 16, fontFeatures: const [ui.FontFeature.tabularFigures()]),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            'Release to send',
                            style: TextStyle(color: pal.sub, fontWeight: FontWeight.w600),
                          ),
                        ),
                        TextButton(onPressed: cancelVoice, child: const Text('Cancel')),
                      ]),
                    )
                  : Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
                    Expanded(
                      child: Container(
                        decoration: BoxDecoration(
                          color: pal.other,
                          borderRadius: BorderRadius.circular(28),
                          boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.06), blurRadius: 8, offset: const Offset(0, 2))],
                        ),
                        child: Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
                          IconButton(
                            icon: Icon(panel ? Icons.keyboard : Icons.emoji_emotions_outlined, color: pal.sub),
                            onPressed: () {
                              if (panel) {
                                setState(() => panel = false);
                                focus.requestFocus();
                              } else {
                                focus.unfocus();
                                setState(() => panel = true);
                              }
                            },
                          ),
                          Expanded(
                            child: Padding(
                              padding: const EdgeInsets.symmetric(vertical: 12),
                              child: TextField(
                                controller: ctl,
                                focusNode: focus,
                                minLines: 1,
                                maxLines: 6,
                                keyboardType: TextInputType.multiline,
                                textCapitalization: TextCapitalization.sentences,
                                style: TextStyle(color: pal.text, fontSize: 16),
                                decoration: InputDecoration.collapsed(hintText: 'Message', hintStyle: TextStyle(color: pal.sub)),
                              ),
                            ),
                          ),
                          if (editing == null) IconButton(icon: Icon(Icons.attach_file, color: pal.sub), onPressed: attachSheet),
                        ]),
                      ),
                    ),
                    const SizedBox(width: 8),
                    // Send when typing; hold mic for voice when empty
                    if (hasText || editing != null)
                      Material(
                        color: accents[Prefs.accent],
                        shape: const CircleBorder(),
                        elevation: 3,
                        shadowColor: accents[Prefs.accent].withOpacity(0.5),
                        child: InkWell(
                          customBorder: const CircleBorder(),
                          onTap: hasText || editing != null ? sendText : null,
                          child: const SizedBox(
                            width: 52,
                            height: 52,
                            child: Icon(Icons.send_rounded, color: Colors.white, size: 24),
                          ),
                        ),
                      )
                    else if (canVoice)
                      GestureDetector(
                        onLongPressStart: (_) => startVoice(),
                        onLongPressEnd: (_) => stopVoiceAndSend(),
                        onLongPressCancel: cancelVoice,
                        child: Tooltip(
                          message: 'Hold to record voice',
                          child: Material(
                            color: accents[Prefs.accent],
                            shape: const CircleBorder(),
                            elevation: 3,
                            shadowColor: accents[Prefs.accent].withOpacity(0.5),
                            child: const SizedBox(
                              width: 52,
                              height: 52,
                              child: Icon(Icons.mic_rounded, color: Colors.white, size: 26),
                            ),
                          ),
                        ),
                      )
                    else
                      Material(
                        color: accents[Prefs.accent].withOpacity(0.4),
                        shape: const CircleBorder(),
                        child: const SizedBox(width: 48, height: 48, child: Icon(Icons.send_rounded, color: Colors.white54, size: 22)),
                      ),
                  ]),
                ),
              if (panel && canPost)
                SizedBox(
                  height: 320,
                  child: MediaPanel(
                    onEmoji: insertText,
                    onSticker: (s) async {
                      await Svc.send(chat, kind: 'sticker', body: s, replyTo: replyTo?.id);
                      if (mounted) setState(() => replyTo = null);
                      toBottom();
                    },
                    onGif: (u) async {
                      await Svc.send(chat, kind: 'gif', url: u, name: 'giphy.gif', replyTo: replyTo?.id);
                      if (mounted) setState(() => replyTo = null);
                      toBottom();
                    },
                    onImageSticker: (path) async {
                      await Svc.send(chat, kind: 'sticker', localPath: path, name: path.split('/').last, replyTo: replyTo?.id);
                      if (mounted) setState(() {
                        replyTo = null;
                        panel = false;
                      });
                      toBottom();
                    },
                  ),
                ),
            ]),
          ),
        ]),
      ),
    );
  }
}

// ───────────────────────── Swipe to reply ─────────────────────────
class SwipeToReply extends StatefulWidget {
  final Widget child;
  final VoidCallback onReply;
  const SwipeToReply({super.key, required this.child, required this.onReply});
  @override
  State<SwipeToReply> createState() => _SwipeState();
}

class _SwipeState extends State<SwipeToReply> with SingleTickerProviderStateMixin {
  double dx = 0, from = 0;
  bool fired = false;
  late final AnimationController ac = AnimationController(vsync: this, duration: const Duration(milliseconds: 180))
    ..addListener(() => setState(() => dx = from * (1 - Curves.easeOut.transform(ac.value))));

  @override
  void dispose() {
    ac.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onHorizontalDragUpdate: (d) {
        if (ac.isAnimating) ac.stop();
        final v = (dx + d.delta.dx).clamp(0.0, 72.0).toDouble();
        if (v != dx) setState(() => dx = v);
        if (dx >= 56 && !fired) {
          fired = true;
          HapticFeedback.selectionClick();
        }
      },
      onHorizontalDragEnd: (_) {
        if (fired) widget.onReply();
        fired = false;
        from = dx;
        ac.forward(from: 0);
      },
      onHorizontalDragCancel: () {
        fired = false;
        from = dx;
        ac.forward(from: 0);
      },
      child: Stack(alignment: Alignment.centerLeft, children: [
        if (dx > 8)
          Opacity(
            opacity: (dx / 56).clamp(0.0, 1.0).toDouble(),
            child: const Padding(padding: EdgeInsets.only(left: 12), child: CircleAvatar(radius: 14, child: Icon(Icons.reply, size: 16))),
          ),
        Transform.translate(offset: Offset(dx, 0), child: widget.child),
      ]),
    );
  }
}

// ───────────────────────── Message bubble & content ─────────────────────────
class Ticks extends StatelessWidget {
  final Msg m;
  final double size;
  const Ticks({super.key, required this.m, this.size = 16});
  @override
  Widget build(BuildContext context) {
    final pal = Pal.of(context);
    if (m.pending) return Icon(Icons.access_time, size: size, color: pal.sub);
    if (m.status >= 3) return Icon(Icons.done_all, size: size, color: pal.tick);
    if (m.status == 2) return Icon(Icons.done_all, size: size, color: pal.sub);
    return Icon(Icons.done, size: size, color: pal.sub);
  }
}

class LinkText extends StatefulWidget {
  final String text;
  final TextStyle style;
  final Color linkColor;
  const LinkText({super.key, required this.text, required this.style, required this.linkColor});
  @override
  State<LinkText> createState() => _LinkTextState();
}

class _LinkTextState extends State<LinkText> {
  static final RegExp _url = RegExp(r'(https?:\/\/[^\s]+|www\.[^\s]+)', caseSensitive: false);
  final List<TapGestureRecognizer> _recs = [];

  void _clear() {
    for (final r in _recs) r.dispose();
    _recs.clear();
  }

  @override
  void dispose() {
    _clear();
    super.dispose();
  }

  Future<void> _open(String u) async {
    try {
      await launchUrl(Uri.parse(u.toLowerCase().startsWith('http') ? u : 'https://$u'), mode: LaunchMode.externalApplication);
    } catch (e) {
      DLog.d('link', 'cannot open $u: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    _clear();
    final t = widget.text;
    final spans = <InlineSpan>[];
    var last = 0;
    for (final m in _url.allMatches(t)) {
      var u = m.group(0)!;
      while (u.isNotEmpty && '.,!?;:)]}\'"'.contains(u[u.length - 1])) {
        u = u.substring(0, u.length - 1);
      }
      if (u.isEmpty) continue;
      if (m.start > last) spans.add(TextSpan(text: t.substring(last, m.start)));
      final r = TapGestureRecognizer()..onTap = () => _open(u);
      _recs.add(r);
      spans.add(TextSpan(text: u, recognizer: r, style: TextStyle(color: widget.linkColor, decoration: TextDecoration.underline)));
      last = m.start + u.length;
    }
    if (last < t.length) spans.add(TextSpan(text: t.substring(last)));
    return Text.rich(TextSpan(style: widget.style, children: spans));
  }
}


class _HeartBurst extends StatefulWidget {
  final Offset origin;
  final VoidCallback onDone;
  const _HeartBurst({required this.origin, required this.onDone});
  @override
  State<_HeartBurst> createState() => _HeartBurstState();
}

class _HeartBurstState extends State<_HeartBurst> with SingleTickerProviderStateMixin {
  late final AnimationController c = AnimationController(vsync: this, duration: const Duration(milliseconds: 900))..forward();
  @override
  void initState() {
    super.initState();
    c.addStatusListener((s) {
      if (s == AnimationStatus.completed) widget.onDone();
    });
  }
  @override
  void dispose() {
    c.dispose();
    super.dispose();
  }
  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: AnimatedBuilder(
        animation: c,
        builder: (_, __) {
          final t = Curves.easeOut.transform(c.value);
          return Stack(children: [
            for (var i = 0; i < 7; i++)
              Positioned(
                left: widget.origin.dx - 12 + (i - 3) * 16.0 * t,
                top: widget.origin.dy - 20 - 80 * t - (i % 3) * 10.0,
                child: Opacity(
                  opacity: (1 - t).clamp(0.0, 1.0),
                  child: Transform.scale(
                    scale: 0.6 + t * 0.8,
                    child: Text(['❤️', '💕', '✨', '💖'][i % 4], style: TextStyle(fontSize: 18.0 + (i % 3) * 4)),
                  ),
                ),
              ),
          ]);
        },
      ),
    );
  }
}

class MsgBubble extends StatelessWidget {
  final Msg m;
  final ChatRow chat;
  final Pal pal;
  final String? senderName, replyName;
  final Msg? reply;
  final VoidCallback onLong;
  final VoidCallback? onReact;
  const MsgBubble({super.key, required this.m, required this.chat, required this.pal, this.senderName, this.reply, this.replyName, required this.onLong, this.onReact});

  Widget footer() => Row(mainAxisSize: MainAxisSize.min, children: [
        if (m.pinned) Padding(padding: const EdgeInsets.only(right: 3), child: Icon(Icons.push_pin, size: 12, color: pal.sub)),
        if (m.edited && !m.delAll) Padding(padding: const EdgeInsets.only(right: 4), child: Text('edited', style: TextStyle(fontSize: 11, color: pal.sub))),
        Text(fmtTime(m.ts), style: TextStyle(fontSize: 11, color: pal.sub)),
        if (m.mine && !chat.isChannel && !m.delAll) ...[const SizedBox(width: 3), Ticks(m: m, size: 15)],
      ]);

  Widget content(BuildContext context) {
    final txt = TextStyle(fontSize: 16, color: pal.text);
    if (m.delAll) return Text('🚫 This message was deleted', style: TextStyle(fontSize: 15, fontStyle: FontStyle.italic, color: pal.sub));
    final cap = m.body.isNotEmpty && m.kind != 'text' && m.kind != 'sticker'
        ? Padding(padding: const EdgeInsets.only(top: 4), child: LinkText(text: m.body, style: txt, linkColor: pal.tick))
        : const SizedBox.shrink();
    switch (m.kind) {
      case 'image':
      case 'gif':
        return Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [ImageMsg(m: m), cap]);
      case 'video':
        return Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [VideoTile(m: m), cap]);
      case 'audio':
        return Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [AudioBubble(m: m, pal: pal), cap]);
      case 'file':
        return Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [FileTile(m: m, pal: pal), cap]);
      case 'sticker':
        if ((m.localPath != null && File(m.localPath!).existsSync()) || (m.mediaUrl != null && m.mediaUrl!.isNotEmpty)) {
          return StickerImage(m: m);
        }
        return Text(m.body.isEmpty ? '⭐' : m.body, style: const TextStyle(fontSize: 72));
      default:
        return LinkText(text: m.body, style: txt, linkColor: pal.tick);
    }
  }

  @override
  Widget build(BuildContext context) {
    final maxW = MediaQuery.sizeOf(context).width * 0.78;
    final sticker = m.kind == 'sticker' && !m.delAll;
    final acc = accents[Prefs.accent];
    final radius = m.mine
        ? const BorderRadius.only(topLeft: Radius.circular(18), topRight: Radius.circular(18), bottomLeft: Radius.circular(18), bottomRight: Radius.circular(6))
        : const BorderRadius.only(topLeft: Radius.circular(18), topRight: Radius.circular(18), bottomLeft: Radius.circular(6), bottomRight: Radius.circular(18));
    return GestureDetector(
      onLongPress: onLong,
      onDoubleTap: onReact,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxW),
        child: Container(
          padding: sticker ? const EdgeInsets.symmetric(horizontal: 4) : const EdgeInsets.fromLTRB(10, 7, 10, 6),
          decoration: sticker
              ? null
              : BoxDecoration(
                  gradient: m.mine
                      ? LinearGradient(
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                          colors: [
                            Color.alphaBlend(acc.withOpacity(0.35), pal.mine),
                            pal.mine,
                          ],
                        )
                      : null,
                  color: m.mine ? null : pal.other,
                  borderRadius: radius,
                  border: m.mine ? null : Border.all(color: Colors.black.withOpacity(0.04)),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withOpacity(m.mine ? 0.12 : 0.06),
                      blurRadius: m.mine ? 10 : 8,
                      offset: const Offset(0, 3),
                    ),
                  ],
                ),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
            if (senderName != null)
              Padding(padding: const EdgeInsets.only(bottom: 2), child: Text(senderName!, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: acc))),
            if (m.replyTo != null && !m.delAll)
              Container(
                margin: const EdgeInsets.only(bottom: 4),
                padding: const EdgeInsets.fromLTRB(8, 4, 8, 4),
                decoration: BoxDecoration(color: Colors.black.withOpacity(0.08), borderRadius: BorderRadius.circular(6), border: Border(left: BorderSide(color: acc, width: 3))),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                  Text(replyName ?? 'Message', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: acc)),
                  Text(reply == null ? 'Original message' : previewOf(reply!), maxLines: 2, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 13, color: pal.sub)),
                ]),
              ),
            content(context),
            const SizedBox(height: 2),
            Align(alignment: Alignment.centerRight, child: footer()),
          ]),
        ),
      ),
    );
  }
}

class StickerImage extends StatelessWidget {
  final Msg m;
  const StickerImage({super.key, required this.m});
  @override
  Widget build(BuildContext context) {
    final lp = m.localPath;
    if (lp != null && File(lp).existsSync()) {
      return Image.file(File(lp), width: 140, height: 140, fit: BoxFit.contain, errorBuilder: (_, __, ___) => const Text('⭐', style: TextStyle(fontSize: 64)));
    }
    if (m.mediaUrl != null && m.mediaUrl!.isNotEmpty) {
      return CachedNetworkImage(imageUrl: m.mediaUrl!, width: 140, height: 140, fit: BoxFit.contain, errorWidget: (_, __, ___) => const Text('⭐', style: TextStyle(fontSize: 64)));
    }
    return Text(m.body.isEmpty ? '⭐' : m.body, style: const TextStyle(fontSize: 72));
  }
}

class ImageMsg extends StatefulWidget {
  final Msg m;
  const ImageMsg({super.key, required this.m});
  @override
  State<ImageMsg> createState() => _ImageMsgState();
}

class _ImageMsgState extends State<ImageMsg> {
  File? local;
  late bool load = !Prefs.lowData;

  @override
  void initState() {
    super.initState();
    final lp = widget.m.localPath;
    if (lp != null && File(lp).existsSync()) local = File(lp);
  }

  @override
  Widget build(BuildContext context) {
    final m = widget.m;
    final w = 230.0, h = m.kind == 'gif' ? 170.0 : 230.0;
    Widget child;
    if (local != null) {
      child = Image.file(local!, fit: BoxFit.cover, cacheWidth: 460, errorBuilder: (_, __, ___) => const Icon(Icons.broken_image));
    } else if (m.mediaUrl == null) {
      child = const Center(child: CircularProgressIndicator(strokeWidth: 2));
    } else if (!load) {
      child = Container(
        color: Colors.black12,
        child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
          const Icon(Icons.download, size: 32),
          const SizedBox(height: 4),
          Text(m.mediaSize > 0 ? fmtSize(m.mediaSize) : 'Tap to load', style: const TextStyle(fontSize: 12)),
        ]),
      );
    } else {
      child = CachedNetworkImage(
        imageUrl: m.mediaUrl!,
        fit: BoxFit.cover,
        memCacheWidth: 460,
        fadeInDuration: const Duration(milliseconds: 120),
        placeholder: (_, __) => Container(color: Colors.black12),
        errorWidget: (_, __, ___) => const Center(child: Icon(Icons.broken_image)),
      );
    }
    return GestureDetector(
      onTap: () {
        if (!load && local == null) {
          setState(() => load = true);
        } else {
          Navigator.push(context, MaterialPageRoute(builder: (_) => ImageScreen(url: m.mediaUrl, file: local)));
        }
      },
      child: ClipRRect(borderRadius: BorderRadius.circular(8), child: SizedBox(width: w, height: h, child: child)),
    );
  }
}

class ImageScreen extends StatelessWidget {
  final String? url;
  final File? file;
  const ImageScreen({super.key, this.url, this.file});
  @override
  Widget build(BuildContext context) => Scaffold(
        backgroundColor: Colors.black,
        appBar: AppBar(backgroundColor: Colors.black, foregroundColor: Colors.white),
        body: Center(
          child: InteractiveViewer(
            maxScale: 5,
            child: file != null ? Image.file(file!) : CachedNetworkImage(imageUrl: url ?? '', placeholder: (_, __) => const CircularProgressIndicator()),
          ),
        ),
      );
}

class VideoTile extends StatelessWidget {
  final Msg m;
  const VideoTile({super.key, required this.m});
  @override
  Widget build(BuildContext context) => GestureDetector(
        onTap: () {
          final lp = m.localPath;
          if (m.mediaUrl == null && lp == null) return;
          Navigator.push(context, MaterialPageRoute(builder: (_) => PlayerScreen(url: m.mediaUrl, path: lp, title: m.mediaName ?? 'Video', audio: false)));
        },
        child: ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: Container(
            width: 230,
            height: 140,
            color: Colors.black87,
            child: Stack(alignment: Alignment.center, children: [
              const CircleAvatar(radius: 26, backgroundColor: Colors.black54, child: Icon(Icons.play_arrow, color: Colors.white, size: 34)),
              Positioned(
                left: 8,
                bottom: 6,
                child: Text('${m.mediaName ?? 'Video'}${m.mediaSize > 0 ? ' · ${fmtSize(m.mediaSize)}' : ''}',
                    style: const TextStyle(color: Colors.white70, fontSize: 11)),
              ),
              if (m.pending) const Positioned(right: 8, top: 8, child: SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))),
            ]),
          ),
        ),
      );
}

class FileTile extends StatelessWidget {
  final Msg m;
  final Pal pal;
  const FileTile({super.key, required this.m, required this.pal});
  @override
  Widget build(BuildContext context) => InkWell(
        onTap: () async {
          if (m.mediaUrl == null) {
            toast(context, 'Still uploading…');
            return;
          }
          try {
            await launchUrl(Uri.parse(m.mediaUrl!), mode: LaunchMode.externalApplication);
          } catch (_) {
            if (context.mounted) toast(context, 'No app can open this file.');
          }
        },
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.insert_drive_file, size: 34, color: pal.sub),
          const SizedBox(width: 8),
          Flexible(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(m.mediaName ?? 'File', maxLines: 2, overflow: TextOverflow.ellipsis, style: TextStyle(color: pal.text, fontWeight: FontWeight.w600)),
              Text(fmtSize(m.mediaSize), style: TextStyle(fontSize: 12, color: pal.sub)),
            ]),
          ),
        ]),
      );
}

class AudioBubble extends StatefulWidget {
  final Msg m;
  final Pal pal;
  const AudioBubble({super.key, required this.m, required this.pal});
  @override
  State<AudioBubble> createState() => _AudioState();
}

class _AudioState extends State<AudioBubble> {
  VideoPlayerController? c;
  bool loading = false;

  @override
  void dispose() {
    c?.dispose();
    super.dispose();
  }

  Future<void> toggle() async {
    final m = widget.m;
    if (c == null) {
      setState(() => loading = true);
      try {
        final lp = m.localPath;
        final ctl = (lp != null && File(lp).existsSync())
            ? VideoPlayerController.file(File(lp))
            : VideoPlayerController.networkUrl(Uri.parse(m.mediaUrl ?? ''));
        await ctl.initialize();
        ctl.addListener(() {
          if (mounted) setState(() {});
        });
        c = ctl;
        await ctl.play();
      } catch (e) {
        DLog.d('audio', '$e');
        if (mounted) toast(context, 'Could not play audio.');
      }
      if (mounted) setState(() => loading = false);
      return;
    }
    final v = c!.value;
    if (v.isPlaying) {
      await c!.pause();
    } else {
      if (v.duration > Duration.zero && v.position >= v.duration) await c!.seekTo(Duration.zero);
      await c!.play();
    }
  }

  String _t(Duration d) => '${d.inMinutes}:${two(d.inSeconds % 60)}';

  @override
  Widget build(BuildContext context) {
    final v = c?.value;
    final dur = (v?.duration ?? Duration.zero).inMilliseconds.toDouble();
    final pos = (v?.position ?? Duration.zero).inMilliseconds.toDouble();
    return SizedBox(
      width: 230,
      child: Row(children: [
        loading
            ? const Padding(padding: EdgeInsets.all(12), child: SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2)))
            : IconButton(icon: Icon(v?.isPlaying == true ? Icons.pause_circle_filled : Icons.play_circle_fill, size: 36, color: widget.pal.sub), onPressed: toggle),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            SliderTheme(
              data: SliderTheme.of(context).copyWith(trackHeight: 2, thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6), overlayShape: SliderComponentShape.noOverlay),
              child: Slider(
                value: dur <= 0 ? 0 : pos.clamp(0.0, dur).toDouble(),
                max: dur <= 0 ? 1 : dur,
                onChanged: c == null ? null : (x) => c!.seekTo(Duration(milliseconds: x.toInt())),
              ),
            ),
            Text(
                c == null
                    ? (int.tryParse(widget.m.body) != null ? '0:${two(int.parse(widget.m.body) % 60)} voice note' : (widget.m.mediaName ?? 'Voice note'))
                    : '${_t(v!.position)} / ${_t(v.duration)}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 11, color: widget.pal.sub)),
          ]),
        ),
      ]),
    );
  }
}

class PlayerScreen extends StatefulWidget {
  final String? url, path;
  final String title;
  final bool audio;
  const PlayerScreen({super.key, this.url, this.path, required this.title, required this.audio});
  @override
  State<PlayerScreen> createState() => _PlayerState();
}

class _PlayerState extends State<PlayerScreen> {
  VideoPlayerController? c;
  String? err;

  @override
  void initState() {
    super.initState();
    final lp = widget.path;
    final ctl = (lp != null && File(lp).existsSync()) ? VideoPlayerController.file(File(lp)) : VideoPlayerController.networkUrl(Uri.parse(widget.url ?? ''));
    c = ctl;
    ctl.initialize().then((_) {
      if (mounted) {
        setState(() {});
        ctl.play();
      }
    }).catchError((Object e) {
      DLog.d('player', '$e');
      if (mounted) setState(() => err = 'Could not play this video.');
    });
  }

  @override
  void dispose() {
    c?.dispose();
    super.dispose();
  }

  String _t(Duration d) => '${d.inMinutes}:${two(d.inSeconds % 60)}';

  @override
  Widget build(BuildContext context) {
    final ctl = c!;
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(backgroundColor: Colors.black, foregroundColor: Colors.white, title: Text(widget.title, maxLines: 1, overflow: TextOverflow.ellipsis)),
      body: err != null
          ? Center(child: Text(err!, style: const TextStyle(color: Colors.white)))
          : !ctl.value.isInitialized
              ? const Center(child: CircularProgressIndicator())
              : Column(children: [
                  Expanded(child: Center(child: AspectRatio(aspectRatio: ctl.value.aspectRatio, child: VideoPlayer(ctl)))),
                  ValueListenableBuilder<VideoPlayerValue>(
                    valueListenable: ctl,
                    builder: (_, v, __) {
                      final dur = v.duration.inMilliseconds.toDouble();
                      final pos = v.position.inMilliseconds.toDouble();
                      return SafeArea(
                        child: Column(mainAxisSize: MainAxisSize.min, children: [
                          Slider(
                              value: dur <= 0 ? 0 : pos.clamp(0.0, dur).toDouble(),
                              max: dur <= 0 ? 1 : dur,
                              onChanged: (x) => ctl.seekTo(Duration(milliseconds: x.toInt()))),
                          Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                            Padding(padding: const EdgeInsets.only(left: 16), child: Text('${_t(v.position)} / ${_t(v.duration)}', style: const TextStyle(color: Colors.white70))),
                            IconButton(
                              iconSize: 38,
                              color: Colors.white,
                              icon: Icon(v.isPlaying ? Icons.pause_circle : Icons.play_circle),
                              onPressed: () async {
                                if (v.isPlaying) {
                                  await ctl.pause();
                                } else {
                                  if (v.position >= v.duration) await ctl.seekTo(Duration.zero);
                                  await ctl.play();
                                }
                              },
                            ),
                            const SizedBox(width: 60),
                          ]),
                        ]),
                      );
                    },
                  ),
                ]),
    );
  }
}

// ───────────────────────── Sticker Studio (crop / pen / text) ─────────────────────────
class StickerStudio extends StatefulWidget {
  const StickerStudio({super.key});
  @override
  State<StickerStudio> createState() => _StickerStudioState();
}

class _Stroke {
  final List<Offset> points;
  final Color color;
  final double width;
  _Stroke(this.points, this.color, this.width);
}

class _TextItem {
  String text;
  Offset pos;
  Color color;
  double size;
  _TextItem(this.text, this.pos, this.color, this.size);
}

class _StickerStudioState extends State<StickerStudio> {
  ui.Image? _img;
  String? _srcPath;
  final strokes = <_Stroke>[];
  _Stroke? cur;
  final texts = <_TextItem>[];
  Color penColor = Colors.white;
  double penWidth = 4;
  bool cropMode = false;
  bool textMode = false;
  Rect? crop; // relative 0-1 in image box
  Offset? cropStart;
  final boundaryKey = GlobalKey();
  bool busy = false;
  static const colors = [Colors.white, Colors.black, Colors.redAccent, Colors.amber, Colors.lightGreenAccent, Colors.cyanAccent, Colors.pinkAccent];

  Future<void> _pick() async {
    final x = await ImagePicker().pickImage(source: ImageSource.gallery, maxWidth: 1024, maxHeight: 1024, imageQuality: 92);
    if (x == null) return;
    final bytes = await File(x.path).readAsBytes();
    final codec = await ui.instantiateImageCodec(bytes);
    final frame = await codec.getNextFrame();
    if (!mounted) return;
    setState(() {
      _img = frame.image;
      _srcPath = x.path;
      strokes.clear();
      texts.clear();
      crop = null;
    });
  }

  Future<void> _save() async {
    if (_img == null || busy) return;
    setState(() => busy = true);
    try {
      await Future<void>.delayed(const Duration(milliseconds: 16));
      final box = boundaryKey.currentContext?.findRenderObject() as RenderRepaintBoundary?;
      if (box == null) throw 'render';
      final image = await box.toImage(pixelRatio: 2);
      final bd = await image.toByteData(format: ui.ImageByteFormat.png);
      if (bd == null) throw 'encode';
      final dir = await getApplicationDocumentsDirectory();
      final dest = p.join(dir.path, 'stickers', 'stk_${DateTime.now().millisecondsSinceEpoch}.png');
      await Directory(p.dirname(dest)).create(recursive: true);
      await File(dest).writeAsBytes(bd.buffer.asUint8List());
      final list = Prefs.customStickers.toList()..insert(0, dest);
      while (list.length > 80) {
        final old = list.removeLast();
        try {
          await File(old).delete();
        } catch (_) {}
      }
      await Prefs.setCustomStickers(list);
      if (mounted) {
        toast(context, 'Sticker saved');
        Navigator.pop(context, dest);
      }
    } catch (e) {
      DLog.d('studio', '$e');
      if (mounted) toast(context, 'Could not save sticker');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  void _addText() async {
    final s = await askText(context, 'Sticker text', hint: 'Type something', maxLen: 40);
    if (s == null || s.trim().isEmpty || !mounted) return;
    setState(() {
      texts.add(_TextItem(s.trim(), const Offset(40, 40), penColor, 28));
      textMode = true;
      cropMode = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final acc = accents[Prefs.accent];
    return Scaffold(
      backgroundColor: const Color(0xFF0E0E12),
      appBar: AppBar(
        backgroundColor: const Color(0xFF0E0E12),
        foregroundColor: Colors.white,
        title: const Text('Sticker Studio'),
        actions: [
          if (_img != null)
            TextButton(
              onPressed: busy ? null : _save,
              child: busy
                  ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                  : Text('Save', style: TextStyle(color: acc, fontWeight: FontWeight.w800)),
            ),
        ],
      ),
      body: Column(children: [
        Expanded(
          child: Center(
            child: _img == null
                ? Column(mainAxisSize: MainAxisSize.min, children: [
                    Icon(Icons.auto_awesome, size: 56, color: acc),
                    const SizedBox(height: 12),
                    const Text('Make a sticker', style: TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.w700)),
                    const SizedBox(height: 8),
                    const Text('Photo → draw, text, crop → save', style: TextStyle(color: Colors.white54)),
                    const SizedBox(height: 20),
                    FilledButton.icon(onPressed: _pick, icon: const Icon(Icons.add_photo_alternate), label: const Text('Choose photo')),
                  ])
                : LayoutBuilder(builder: (ctx, box) {
                    final iw = _img!.width.toDouble();
                    final ih = _img!.height.toDouble();
                    final scale = (box.maxWidth / iw).clamp(0.0, box.maxHeight / ih);
                    final w = iw * scale;
                    final h = ih * scale;
                    return InteractiveViewer(
                      minScale: 0.8,
                      maxScale: 4,
                      child: SizedBox(
                        width: w,
                        height: h,
                        child: RepaintBoundary(
                          key: boundaryKey,
                          child: GestureDetector(
                            onPanStart: (d) {
                              if (cropMode) {
                                final rx = (d.localPosition.dx / w).clamp(0.0, 1.0);
                                final ry = (d.localPosition.dy / h).clamp(0.0, 1.0);
                                cropStart = Offset(rx, ry);
                                setState(() => crop = Rect.fromPoints(cropStart!, cropStart!));
                                return;
                              }
                              if (textMode) return;
                              cur = _Stroke([d.localPosition], penColor, penWidth);
                              setState(() => strokes.add(cur!));
                            },
                            onPanUpdate: (d) {
                              if (cropMode && cropStart != null) {
                                final rx = (d.localPosition.dx / w).clamp(0.0, 1.0);
                                final ry = (d.localPosition.dy / h).clamp(0.0, 1.0);
                                setState(() => crop = Rect.fromPoints(cropStart!, Offset(rx, ry)));
                                return;
                              }
                              if (textMode && texts.isNotEmpty) {
                                setState(() => texts.last.pos = d.localPosition);
                                return;
                              }
                              if (cur == null) return;
                              setState(() => cur!.points.add(d.localPosition));
                            },
                            onPanEnd: (_) {
                              cur = null;
                              cropStart = null;
                            },
                            child: Stack(children: [
                              CustomPaint(
                                size: Size(w, h),
                                painter: _StudioPainter(image: _img!, strokes: strokes, texts: texts, crop: crop),
                              ),
                            ]),
                          ),
                        ),
                      ),
                    );
                  }),
          ),
        ),
        if (_img != null)
          Container(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 16),
            color: const Color(0xFF16161C),
            child: Column(children: [
              Row(children: [
                for (final c in colors)
                  GestureDetector(
                    onTap: () => setState(() => penColor = c),
                    child: Container(
                      width: 28,
                      height: 28,
                      margin: const EdgeInsets.only(right: 8),
                      decoration: BoxDecoration(
                        color: c,
                        shape: BoxShape.circle,
                        border: Border.all(color: penColor == c ? acc : Colors.white24, width: penColor == c ? 3 : 1),
                      ),
                    ),
                  ),
                const Spacer(),
                IconButton(
                  tooltip: 'Undo stroke',
                  onPressed: strokes.isEmpty ? null : () => setState(() => strokes.removeLast()),
                  icon: const Icon(Icons.undo, color: Colors.white70),
                ),
              ]),
              const SizedBox(height: 6),
              Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: [
                _tool(Icons.edit, 'Pen', !cropMode && !textMode, () => setState(() { cropMode = false; textMode = false; })),
                _tool(Icons.text_fields, 'Text', textMode, _addText),
                _tool(Icons.crop, 'Crop', cropMode, () => setState(() { cropMode = !cropMode; textMode = false; })),
                _tool(Icons.photo_library_outlined, 'New', false, _pick),
              ]),
            ]),
          ),
      ]),
    );
  }

  Widget _tool(IconData i, String label, bool on, VoidCallback fn) {
    final acc = accents[Prefs.accent];
    return InkWell(
      onTap: fn,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: on ? acc.withOpacity(0.25) : Colors.white10,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: on ? acc : Colors.transparent),
        ),
        child: Column(children: [
          Icon(i, color: on ? acc : Colors.white70, size: 22),
          const SizedBox(height: 4),
          Text(label, style: TextStyle(color: on ? acc : Colors.white70, fontSize: 11, fontWeight: FontWeight.w600)),
        ]),
      ),
    );
  }
}

class _StudioPainter extends CustomPainter {
  final ui.Image image;
  final List<_Stroke> strokes;
  final List<_TextItem> texts;
  final Rect? crop;
  _StudioPainter({required this.image, required this.strokes, required this.texts, this.crop});

  @override
  void paint(Canvas canvas, Size size) {
    paintImage(canvas: canvas, rect: Offset.zero & size, image: image, fit: BoxFit.fill, filterQuality: FilterQuality.medium);
    for (final s in strokes) {
      if (s.points.isEmpty) continue;
      final p = Paint()
        ..color = s.color
        ..strokeWidth = s.width
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round;
      final path = Path()..moveTo(s.points.first.dx, s.points.first.dy);
      for (var i = 1; i < s.points.length; i++) {
        path.lineTo(s.points[i].dx, s.points[i].dy);
      }
      canvas.drawPath(path, p);
    }
    for (final t in texts) {
      final tp = TextPainter(
        text: TextSpan(text: t.text, style: TextStyle(color: t.color, fontSize: t.size, fontWeight: FontWeight.w800, shadows: const [Shadow(blurRadius: 4, color: Colors.black54)])),
        textDirection: TextDirection.ltr,
      )..layout(maxWidth: size.width);
      tp.paint(canvas, t.pos);
    }
    if (crop != null) {
      final r = Rect.fromLTRB(crop!.left * size.width, crop!.top * size.height, crop!.right * size.width, crop!.bottom * size.height).normalize();
      canvas.drawPath(
        Path.combine(ui.PathOperation.difference, Path()..addRect(Offset.zero & size), Path()..addRect(r)),
        Paint()..color = Colors.black54,
      );
      canvas.drawRect(r, Paint()..color = Colors.white..style = PaintingStyle.stroke..strokeWidth = 2);
    }
  }

  @override
  bool shouldRepaint(covariant _StudioPainter old) => true;
}


// ───────────────────────── Emoji / sticker / GIF panel ─────────────────────────
final List<String> kEmojis = ('😀 😃 😄 😁 😆 😅 😂 🤣 🙂 🙃 😉 😊 😇 🥰 😍 🤩 😘 😗 😚 😙 😋 😛 😜 🤪 😝 🤑 🤗 🤭 🤫 🤔 🤐 🤨 😐 😑 😶 😏 😒 🙄 😬 😌 😔 😪 🤤 😴 😷 🤒 🤕 🤢 🤮 🤧 🥵 🥶 🥴 😵 🤯 🤠 🥳 😎 🤓 🧐 😕 😟 🙁 😮 😯 😲 😳 🥺 😦 😧 😨 😰 😥 😢 😭 😱 😖 😣 😞 😓 😩 😫 🥱 😤 😡 😠 🤬 😈 👿 💀 💩 🤡 👹 👻 👽 👾 🤖 😺 😸 😹 😻 😼 😽 🙀 😿 😾 '
        '👋 🤚 ✋ 🖖 👌 🤏 ✌️ 🤞 🤟 🤘 🤙 👈 👉 👆 👇 ☝️ 👍 👎 ✊ 👊 🤛 🤜 👏 🙌 👐 🤲 🤝 🙏 💪 🧠 👀 👅 👄 '
        '❤️ 🧡 💛 💚 💙 💜 🖤 🤍 🤎 💔 ❣️ 💕 💞 💓 💗 💖 💘 💝 💯 💢 💥 💫 💦 💨 🔥 ✨ ⭐ 🌟 🎉 🎊 🎁 🎈 🏆 🥇 ⚽ 🏀 🏈 🎮 🎧 🎵 🎶 📱 💻 📷 💡 📌 📎 ✅ ❌ ❓ ❗ '
        '🍕 🍔 🍟 🌮 🍩 🍪 🎂 🍫 🍿 ☕ 🍺 🍷 🥤 🍎 🍌 🍉 🍓 🥑 🚗 ✈️ 🚀 🌍 🏠 🌈 ☀️ 🌙 ⚡ ❄️ 🌸 🌹 🌴 '
        '🐶 🐱 🐭 🐹 🐰 🦊 🐻 🐼 🐨 🐯 🦁 🐮 🐷 🐸 🐵 🐔 🐧 🐦 🦄 🐝 🦋 🐢 🐙 🐬')
    .split(' ');

const List<String> kStickers = ['😂', '😍', '🥳', '😎', '🤯', '😭', '🙏', '👍', '🔥', '❤️', '💯', '🎉', '😴', '🤔', '🥺', '😡', '🤣', '😘', '🙌', '💪', '👀', '🤝', '😅', '🥰'];

class MediaPanel extends StatefulWidget {
  final void Function(String) onEmoji;
  final void Function(String) onSticker;
  final void Function(String) onGif;
  final Future<void> Function(String path)? onImageSticker;
  const MediaPanel({super.key, required this.onEmoji, required this.onSticker, required this.onGif, this.onImageSticker});
  @override
  State<MediaPanel> createState() => _MediaPanelState();
}

class _MediaPanelState extends State<MediaPanel> with SingleTickerProviderStateMixin {
  late final TabController tc = TabController(length: 3, vsync: this);
  List<String> gifs = [];
  bool gifBusy = false;
  final gifCtl = TextEditingController(text: 'funny');

  @override
  void dispose() {
    tc.dispose();
    gifCtl.dispose();
    super.dispose();
  }

  Future<void> loadGifs([String? q]) async {
    if (Cfg.giphyKey.isEmpty) return;
    setState(() => gifBusy = true);
    try {
      final query = (q ?? gifCtl.text).trim().isEmpty ? 'funny' : gifCtl.text.trim();
      final uri = Uri.parse('https://api.giphy.com/v1/gifs/search?api_key=${Cfg.giphyKey}&q=${Uri.encodeQueryComponent(query)}&limit=24&rating=pg-13');
      final res = await http.get(uri).timeout(const Duration(seconds: 15));
      if (res.statusCode == 200) {
        final data = jsonDecode(res.body) as Map<String, dynamic>;
        final list = data['data'] as List? ?? [];
        gifs = [
          for (final g in list)
            if (g is Map && g['images'] is Map)
              ((g['images'] as Map)['fixed_width'] as Map?)?['url'] as String? ?? ''
        ].where((e) => e.isNotEmpty).toList();
      }
    } catch (e) {
      DLog.d('giphy', '$e');
    }
    if (mounted) setState(() => gifBusy = false);
  }

  Future<void> _createSticker() async {
    final path = await Navigator.of(context).push<String>(MaterialPageRoute(builder: (_) => const StickerStudio()));
    if (path == null) return;
    if (mounted) setState(() {});
    if (widget.onImageSticker != null) await widget.onImageSticker!(path);
  }

  Future<void> _importSticker() async {
    final r = await FilePicker.platform.pickFiles(type: FileType.image, allowMultiple: true);
    if (r == null || r.files.isEmpty) return;
    var n = 0;
    for (final f in r.files) {
      if (f.path == null) continue;
      final path = await StickerStore.importFromPath(f.path!);
      if (path != null) n++;
    }
    if (mounted) {
      setState(() {});
      toast(context, n == 0 ? 'No stickers imported' : 'Imported $n sticker${n == 1 ? '' : 's'}');
    }
  }

  @override
  Widget build(BuildContext context) {
    final acc = accents[Prefs.accent];
    final custom = Prefs.customStickers.where((e) => File(e).existsSync()).toList();
    return Material(
      color: Theme.of(context).colorScheme.surface,
      elevation: 8,
      child: Column(children: [
        TabBar(
          controller: tc,
          labelColor: acc,
          indicatorColor: acc,
          tabs: const [Tab(text: 'Emoji'), Tab(text: 'Stickers'), Tab(text: 'GIF')],
          onTap: (i) {
            if (i == 2 && gifs.isEmpty && !gifBusy) loadGifs();
          },
        ),
        Expanded(
          child: TabBarView(controller: tc, children: [
            // Emoji
            GridView.builder(
              padding: const EdgeInsets.all(8),
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: 8),
              itemCount: kEmojis.length,
              itemBuilder: (_, i) => InkWell(
                onTap: () => widget.onEmoji(kEmojis[i]),
                child: Center(child: Text(kEmojis[i], style: const TextStyle(fontSize: 26))),
              ),
            ),
            // Stickers
            Column(children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
                child: Row(children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: _createSticker,
                      icon: const Icon(Icons.add_photo_alternate_outlined, size: 18),
                      label: const Text('Create'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: _importSticker,
                      icon: const Icon(Icons.folder_open, size: 18),
                      label: const Text('Import'),
                    ),
                  ),
                ]),
              ),
              Expanded(
                child: GridView.builder(
                  padding: const EdgeInsets.all(10),
                  gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: 4, mainAxisSpacing: 8, crossAxisSpacing: 8),
                  itemCount: custom.length + kStickers.length,
                  itemBuilder: (_, i) {
                    if (i < custom.length) {
                      final path = custom[i];
                      return InkWell(
                        onTap: () async {
                          if (widget.onImageSticker != null) await widget.onImageSticker!(path);
                        },
                        onLongPress: () async {
                          await StickerStore.remove(path);
                          if (mounted) setState(() {});
                        },
                        borderRadius: BorderRadius.circular(12),
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(12),
                          child: Image.file(File(path), fit: BoxFit.cover, errorBuilder: (_, __, ___) => const Icon(Icons.broken_image)),
                        ),
                      );
                    }
                    final s = kStickers[i - custom.length];
                    return InkWell(
                      onTap: () => widget.onSticker(s),
                      borderRadius: BorderRadius.circular(12),
                      child: Container(
                        alignment: Alignment.center,
                        decoration: BoxDecoration(color: Theme.of(context).colorScheme.surfaceContainerHighest, borderRadius: BorderRadius.circular(12)),
                        child: Text(s, style: const TextStyle(fontSize: 40)),
                      ),
                    );
                  },
                ),
              ),
            ]),
            // GIF
            Cfg.giphyKey.isEmpty
                ? const Center(child: Padding(padding: EdgeInsets.all(24), child: Text('Add GIPHY_API_KEY secret and rebuild to enable GIFs.\nGet a free key at developers.giphy.com', textAlign: TextAlign.center)))
                : Column(children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
                      child: TextField(
                        controller: gifCtl,
                        decoration: InputDecoration(
                          hintText: 'Search GIPHY',
                          isDense: true,
                          border: const OutlineInputBorder(),
                          suffixIcon: IconButton(icon: const Icon(Icons.search), onPressed: () => loadGifs()),
                        ),
                        onSubmitted: loadGifs,
                      ),
                    ),
                    Expanded(
                      child: gifBusy
                          ? const Center(child: CircularProgressIndicator())
                          : GridView.builder(
                              padding: const EdgeInsets.all(8),
                              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: 3, mainAxisSpacing: 6, crossAxisSpacing: 6),
                              itemCount: gifs.length,
                              itemBuilder: (_, i) => InkWell(
                                onTap: () => widget.onGif(gifs[i]),
                                child: CachedNetworkImage(imageUrl: gifs[i], fit: BoxFit.cover, memCacheWidth: 200),
                              ),
                            ),
                    ),
                  ]),
          ]),
        ),
      ]),
    );
  }
}


class GifTab extends StatefulWidget {
  final ValueChanged<String> onGif;
  const GifTab({super.key, required this.onGif});
  @override
  State<GifTab> createState() => _GifTabState();
}

class _GifTabState extends State<GifTab> {
  List<String> urls = [];
  bool loading = false;
  String? err;
  Timer? deb;

  @override
  void initState() {
    super.initState();
    if (Cfg.giphyKey.isNotEmpty && !Prefs.lowData) _fetch('');
  }

  @override
  void dispose() {
    deb?.cancel();
    super.dispose();
  }

  Future<void> _fetch(String q) async {
    setState(() {
      loading = true;
      err = null;
    });
    try {
      final params = {'api_key': Cfg.giphyKey, 'limit': '24', 'rating': 'pg', if (q.isNotEmpty) 'q': q};
      final u = Uri.https('api.giphy.com', q.isEmpty ? '/v1/gifs/trending' : '/v1/gifs/search', params);
      final r = await http.get(u).timeout(const Duration(seconds: 10));
      final j = jsonDecode(r.body) as Map<String, dynamic>;
      final l = [for (final g in (j['data'] as List)) g['images']['fixed_width']['url'] as String];
      if (mounted) setState(() => urls = l);
    } catch (e) {
      DLog.d('gif', '$e');
      if (mounted) setState(() => err = 'Could not load GIFs.');
    }
    if (mounted) setState(() => loading = false);
  }

  @override
  Widget build(BuildContext context) {
    if (Prefs.lowData) return const Center(child: Text('GIFs are off in Low data mode.'));
    if (Cfg.giphyKey.isEmpty) return const Center(child: Padding(padding: EdgeInsets.all(20), child: Text('GIF search needs a GIPHY_API_KEY (see README).', textAlign: TextAlign.center)));
    return Column(children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(8, 6, 8, 2),
        child: SizedBox(
          height: 38,
          child: TextField(
            onChanged: (q) {
              deb?.cancel();
              deb = Timer(const Duration(milliseconds: 450), () => _fetch(q.trim()));
            },
            decoration: InputDecoration(hintText: 'Search GIPHY', isDense: true, border: OutlineInputBorder(borderRadius: BorderRadius.circular(20)), prefixIcon: const Icon(Icons.search, size: 18)),
          ),
        ),
      ),
      if (loading) const LinearProgressIndicator(minHeight: 2),
      Expanded(
        child: err != null
            ? Center(child: Text(err!))
            : GridView.builder(
                padding: const EdgeInsets.all(6),
                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: 3, mainAxisSpacing: 4, crossAxisSpacing: 4),
                itemCount: urls.length,
                itemBuilder: (c, i) => GestureDetector(
                  onTap: () => widget.onGif(urls[i]),
                  child: ClipRRect(borderRadius: BorderRadius.circular(6), child: CachedNetworkImage(imageUrl: urls[i], fit: BoxFit.cover, memCacheWidth: 240, placeholder: (_, __) => Container(color: Colors.black12))),
                ),
              ),
      ),
    ]);
  }
}

// ───────────────────────── Settings ─────────────────────────
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});
  @override
  State<SettingsScreen> createState() => _SettingsState();
}

class _SettingsState extends State<SettingsScreen> {
  int taps = 0;
  bool busy = false;

  Profile? get me => Svc.meP;

  Future<void> _photo() async {
    try {
      final x = await ImagePicker().pickImage(source: ImageSource.gallery, imageQuality: 70, maxWidth: 512);
      if (x == null) return;
      setState(() => busy = true);
      final url = await Svc.uploadAvatar(x.path);
      await Svc.updateProfile(photo: url);
    } catch (e) {
      DLog.d('profile', 'photo failed: $e');
      if (mounted) toast(context, 'Could not update photo. Check your connection.');
    }
    if (mounted) setState(() => busy = false);
  }

  Future<void> _edit(String title, String initial, bool isName) async {
    final v = await askText(context, title, initial: initial, maxLen: isName ? 40 : 120);
    if (v == null || (isName && v.isEmpty)) return;
    try {
      await Svc.updateProfile(name: isName ? v : null, about: isName ? null : v);
      if (mounted) setState(() {});
    } catch (e) {
      if (mounted) toast(context, 'Could not save. Check your connection.');
    }
  }

  Future<void> _debug() async {
    final pw = await askText(context, 'Developer access', hint: 'Password', maxLen: 32, obscure: true);
    if (pw == null) return;
    if (!mounted) return;
    if (pw == Cfg.debugPassword) {
      Navigator.push(context, MaterialPageRoute(builder: (_) => const DebugScreen()));
    } else {
      toast(context, 'Wrong password');
    }
  }

  Widget header(String t) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 18, 16, 6),
        child: Text(t, style: TextStyle(fontWeight: FontWeight.w700, color: accents[Prefs.accent])),
      );

  @override
  Widget build(BuildContext context) {
    final pr = me;
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(children: [
        if (busy) const LinearProgressIndicator(minHeight: 2),
        ListTile(
          contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          leading: GestureDetector(onTap: _photo, child: Avatar(url: pr?.photo, name: pr?.name ?? '', r: 32)),
          title: Text(pr?.name ?? '', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
          subtitle: Text('@${pr?.username ?? ''}'),
          trailing: const Icon(Icons.edit),
          onTap: () => _edit('Your name', pr?.name ?? '', true),
        ),
        ListTile(
          leading: const Icon(Icons.info_outline),
          title: const Text('About'),
          subtitle: Text((pr?.about ?? '').isEmpty ? 'Hey there! I am using RT Chat.' : pr!.about!),
          onTap: () => _edit('About', pr?.about ?? '', false),
        ),
        header('Appearance'),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: SegmentedButton<int>(
            segments: const [
              ButtonSegment(value: 0, label: Text('Auto')),
              ButtonSegment(value: 1, label: Text('Light')),
              ButtonSegment(value: 2, label: Text('Dark')),
            ],
            selected: {Prefs.themeMode},
            onSelectionChanged: (s) async {
              await Prefs.setInt('theme_mode', s.first);
              if (mounted) setState(() {});
            },
          ),
        ),
        const Padding(padding: EdgeInsets.fromLTRB(16, 16, 16, 6), child: Text('Accent colour')),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Wrap(spacing: 10, children: [
            for (var i = 0; i < accents.length; i++)
              GestureDetector(
                onTap: () async {
                  await Prefs.setInt('accent', i);
                  if (mounted) setState(() {});
                },
                child: Tooltip(
                  message: accentNames[i],
                  child: CircleAvatar(
                    radius: 18,
                    backgroundColor: accents[i],
                    child: Prefs.accent == i ? const Icon(Icons.check, color: Colors.white, size: 18) : null,
                  ),
                ),
              ),
          ]),
        ),
        const Padding(padding: EdgeInsets.fromLTRB(16, 16, 16, 6), child: Text('Chat theme')),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Wrap(spacing: 10, runSpacing: 8, children: [
            for (var i = 0; i < walls.length; i++)
              GestureDetector(
                onTap: () async {
                  await Prefs.setInt('wall', i);
                  if (mounted) setState(() {});
                },
                child: Container(
                  width: 56,
                  height: 56,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: walls[i][Theme.of(context).brightness == Brightness.dark ? 1 : 0],
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: Prefs.wall == i ? accents[Prefs.accent] : Colors.grey, width: Prefs.wall == i ? 3 : 1),
                  ),
                  child: Text(wallNames[i], style: TextStyle(fontSize: 11, color: Theme.of(context).brightness == Brightness.dark ? Colors.white70 : Colors.black87)),
                ),
              ),
          ]),
        ),
        header('Data and storage'),
        SwitchListTile(
          title: const Text('Low data mode'),
          subtitle: const Text('Photos load on tap, GIFs off, smaller uploads, no live online status.'),
          value: Prefs.lowData,
          onChanged: (v) async {
            await Prefs.setBool('low_data', v);
            Svc.applyLowData();
            if (mounted) setState(() {});
          },
        ),
        ListTile(
          leading: const Icon(Icons.upload_file),
          title: const Text('Upload limit'),
          subtitle: Text('${Cfg.maxUploadMb} MB per file'),
        ),
        header('Account'),
        ListTile(
          leading: const Icon(Icons.pin),
          title: const Text('Set recovery PIN'),
          subtitle: const Text('Needed to restore chat encryption after reinstall (4–8 digits).'),
          onTap: () async {
            final p1 = await askText(context, 'New PIN', hint: '4–8 digits', maxLen: 8, obscure: true);
            if (p1 == null || !mounted) return;
            final p2 = await askText(context, 'Confirm PIN', hint: '4–8 digits', maxLen: 8, obscure: true);
            if (p2 == null || !mounted) return;
            if (p1 != p2) {
              toast(context, 'PINs do not match');
              return;
            }
            try {
              await Svc.setRecoveryPin(p1);
              if (mounted) toast(context, 'Recovery PIN saved. Remember it if you reinstall.');
            } catch (e) {
              if (mounted) toast(context, '$e');
            }
          },
        ),
        ListTile(
          leading: const Icon(Icons.logout, color: Colors.redAccent),
          title: const Text('Sign out', style: TextStyle(color: Colors.redAccent)),
          onTap: () async {
            Navigator.of(context).popUntil((r) => r.isFirst);
            await signOut();
          },
        ),
        GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () {
            taps++;
            if (taps >= 7) {
              taps = 0;
              _debug();
            }
          },
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Center(child: Text('${Cfg.appName} v${Cfg.version}', style: const TextStyle(color: Colors.grey))),
          ),
        ),
      ]),
    );
  }
}

// ───────────────────────── Developer debug log (password locked, hidden) ─────────────────────────
class DebugScreen extends StatelessWidget {
  const DebugScreen({super.key});
  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Debug log'), actions: [
          IconButton(
              icon: const Icon(Icons.copy),
              onPressed: () {
                Clipboard.setData(ClipboardData(text: DLog.lines.join('\n')));
                toast(context, 'Log copied');
              }),
          IconButton(
              icon: const Icon(Icons.sync),
              onPressed: () {
                DLog.d('debug', 'manual sync requested');
                Svc.sync();
              }),
          IconButton(
              icon: const Icon(Icons.delete_outline),
              onPressed: () {
                DLog.lines.clear();
                DLog.tick.value++;
              }),
        ]),
        body: Column(children: [
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(10),
            color: Colors.black12,
            child: Text('uid: ${Svc.me}\nlowData: ${Prefs.lowData}  maxUpload: ${Cfg.maxUploadMb}MB  v${Cfg.version}', style: const TextStyle(fontFamily: 'monospace', fontSize: 11)),
          ),
          Expanded(
            child: ValueListenableBuilder<int>(
              valueListenable: DLog.tick,
              builder: (_, __, ___) => ListView.builder(
                reverse: true,
                itemCount: DLog.lines.length,
                itemBuilder: (c, i) => Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
                  child: Text(DLog.lines[DLog.lines.length - 1 - i], style: const TextStyle(fontFamily: 'monospace', fontSize: 11)),
                ),
              ),
            ),
          ),
        ]),
      );
}
