// NextGen Bots roster. Desktop gets this from profiles.list plus the
// hermes-bots ui_meta projection; group chats are part of the Bots surface,
// never the Sessions list. All calls go through the profile-aware gateway
// socket so a live profile switch rebuilds this model with the shell.
import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';

import '../ui/nextgen_scope.dart';

class NgBot {
  const NgBot({
    required this.name,
    required this.title,
    required this.section,
    required this.description,
    required this.preview,
    required this.lastActiveMs,
    required this.hasAvatar,
    this.sessionId,
    this.sessionTitle,
    this.model,
  });

  final String name;
  final String title;
  final String section;
  final String description;
  final String preview;
  final int lastActiveMs;
  final bool hasAvatar;
  final String? sessionId;
  final String? sessionTitle;
  final String? model;
}

class NgGroupMessage {
  const NgGroupMessage({
    required this.author,
    required this.text,
    required this.atMs,
    required this.isUser,
    this.pending = false,
    this.failed = false,
  });

  final String author;
  final String text;
  final int atMs;
  final bool isUser;
  final bool pending;
  final bool failed;
}

class NgGroupChat {
  const NgGroupChat({
    required this.id,
    required this.name,
    required this.preview,
    required this.lastActiveMs,
    required this.members,
    required this.messages,
    required this.gatewayRoom,
    this.roomId,
    this.memberProfiles = const <String, String>{},
  });

  final String id;
  final String name;
  final String preview;
  final int lastActiveMs;
  final List<String> members;
  final List<NgGroupMessage> messages;
  final bool gatewayRoom;
  final String? roomId;

  /// Room handle → gateway profile. Mirrored rooms store one bot profile per
  /// member; hosted rooms use the `profile` from their roster row.
  final Map<String, String> memberProfiles;

  /// Compatibility name for callers that only need display handles.
  List<String> get memberNames => members;
}

class NgBotsModel extends ChangeNotifier {
  NgBotsModel(this.scope);

  NgScope scope;

  List<NgBot> _bots = const [];
  List<NgGroupChat> _groups = const [];
  final Map<String, Uint8List> _avatars = {};
  final Set<String> _avatarRequests = {};
  String _query = '';
  bool _loading = false;
  String? _error;
  Timer? _poll;

  List<NgBot> get bots => _bots;
  List<NgGroupChat> get groups => _groups;
  bool get loading => _loading;
  String? get error => _error;

  String get query => _query;
  set query(String value) {
    final q = value.trim().toLowerCase();
    if (q == _query) return;
    _query = q;
    notifyListeners();
  }

  List<NgBot> get filteredBots {
    if (_query.isEmpty) return _bots;
    return _bots
        .where(
          (b) =>
              b.name.toLowerCase().contains(_query) ||
              b.title.toLowerCase().contains(_query) ||
              b.description.toLowerCase().contains(_query) ||
              b.preview.toLowerCase().contains(_query),
        )
        .toList(growable: false);
  }

  List<NgGroupChat> get filteredGroups {
    if (_query.isEmpty) return _groups;
    return _groups
        .where(
          (g) =>
              g.name.toLowerCase().contains(_query) ||
              g.preview.toLowerCase().contains(_query) ||
              g.members.any((m) => m.toLowerCase().contains(_query)),
        )
        .toList(growable: false);
  }

  /// Section name -> bots, with named sections before Unassigned.
  Map<String, List<NgBot>> get botSections {
    final map = <String, List<NgBot>>{};
    for (final bot in filteredBots) {
      (map.putIfAbsent(bot.section, () => <NgBot>[])).add(bot);
    }
    final ordered = <String, List<NgBot>>{};
    final named = map.keys.where((k) => k != 'unassigned').toList()..sort();
    for (final key in named) {
      ordered[key] = map[key]!;
    }
    final loose = map['unassigned'];
    if (loose != null) ordered['unassigned'] = loose;
    return ordered;
  }

  void startPolling() {
    if (_poll != null) return;
    // A pane calls this from initState. Let the current build finish before
    // refresh() flips loading and notifies listeners.
    unawaited(Future<void>.microtask(refresh));
    _poll = Timer.periodic(const Duration(seconds: 5), (_) {
      unawaited(refresh());
    });
  }

  void stopPolling() {
    _poll?.cancel();
    _poll = null;
  }

  @override
  void dispose() {
    stopPolling();
    super.dispose();
  }

  void adoptScope(NgScope next) {
    if (identical(scope.gateway, next.gateway)) return;
    _bots = const [];
    _groups = const [];
    _avatars.clear();
    _avatarRequests.clear();
    _error = null;
    scope = next;
    notifyListeners();
  }

  static Map<String, dynamic> _map(Object? value) =>
      value is Map ? Map<String, dynamic>.from(value) : <String, dynamic>{};

  static int _seconds(Object? value) {
    final n = value is num ? value : num.tryParse(value?.toString() ?? '');
    return n == null ? 0 : (n * 1000).round();
  }

  Future<void> refresh() async {
    if (_loading) return;
    _loading = true;
    _error = null;
    notifyListeners();
    try {
      final result = await scope.gateway.call('profiles.list', {
        'include_sessions': true,
      });
      final rows = (result['profiles'] as List? ?? const [])
          .whereType<Map>()
          .map((r) => _map(r))
          .toList(growable: false);
      _bots = [
        for (final row in rows) _botFrom(row),
      ]..sort((a, b) => b.lastActiveMs.compareTo(a.lastActiveMs));
      _groups = _groupsFromProfiles(rows);
      try {
        final rooms = await scope.gateway.call('groups.list', {
          'limit': 100,
        });
        final remote = (rooms['rooms'] as List? ?? const [])
            .whereType<Map>()
            .map((r) => _map(r))
            .where((r) => r['disbanded_at'] == null)
            .map(_remoteGroup)
            .whereType<NgGroupChat>();
        _groups = [..._groups, ...remote]
          ..sort((a, b) => b.lastActiveMs.compareTo(a.lastActiveMs));
      } catch (_) {
        // Older gateways have no hosted rooms; the mirrored rooms still work.
      }
      for (final bot in _bots) {
        if (bot.hasAvatar && !_avatars.containsKey(bot.name)) {
          unawaited(loadAvatar(bot));
        }
      }
    } catch (e) {
      _error = '$e';
    } finally {
      _loading = false;
      notifyListeners();
    }
  }

  NgBot _botFrom(Map<String, dynamic> row) {
    final name = row['name']?.toString() ?? '';
    final botsMeta = _map(_map(row['ui_meta'])['hermes-bots']);
    final section = (botsMeta['sectionName']?.toString() ?? '').trim();
    final canonical = _map(row['canonical_session']);
    final last = _map(row['last_session']);
    final worker = _map(row['worker_session']);
    final previewSource = canonical.isNotEmpty ? canonical : last;
    final lastMs = [
      _seconds(previewSource['last_active']),
      _seconds(worker['last_active']),
    ].reduce((a, b) => a > b ? a : b);
    final title = (botsMeta['title']?.toString() ?? '').trim().isNotEmpty
        ? (botsMeta['title']?.toString() ?? '').trim()
        : (row['display_name']?.toString() ?? '').trim().isNotEmpty
        ? (row['display_name']?.toString() ?? '').trim()
        : name;
    final preview = previewSource['preview']?.toString() ??
        (lastMs > 0 ? last['title']?.toString() ?? '' : '');
    return NgBot(
      name: name,
      title: title.isEmpty ? name : title,
      section: section.isEmpty ? 'unassigned' : section,
      description: row['description']?.toString() ?? '',
      preview: preview,
      lastActiveMs: lastMs,
      hasAvatar: row['has_avatar'] == true,
      sessionId:
          canonical['resolved_id']?.toString() ?? canonical['id']?.toString(),
      sessionTitle: canonical['title']?.toString(),
      model: row['model']?.toString(),
    );
  }

  List<NgGroupChat> _groupsFromProfiles(List<Map<String, dynamic>> rows) {
    final out = <NgGroupChat>[];
    for (final row in rows) {
      final mirror = _map(
        _map(row['ui_meta'])['hermes-bots-groups'],
      );
      final rooms = _map(mirror['rooms']);
      final deleted = _map(mirror['deleted']);
      for (final entry in rooms.entries) {
        final key = entry.key;
        if (deleted.containsKey(key)) continue;
        final room = _map(entry.value);
        final log = (room['log'] as List? ?? const [])
            .whereType<Map>()
            .map((m) => _map(m))
            .toList(growable: false);
        final messages = <NgGroupMessage>[];
        for (final m in log) {
          final from = _map(m['from']);
          messages.add(
            NgGroupMessage(
              author: from['name']?.toString() ?? '',
              text: m['text']?.toString() ?? '',
              atMs: (m['at'] is num)
                  ? (m['at'] as num).round()
                  : int.tryParse(m['at']?.toString() ?? '') ?? 0,
              isUser: from['kind']?.toString() == 'user',
            ),
          );
        }
        messages.sort((a, b) => a.atMs.compareTo(b.atMs));
        final last = messages.isEmpty ? null : messages.last;
        final preview = last == null
            ? ''
            : '${last.isUser ? 'You' : last.author}: ${last.text}';
        final memberRows = (room['members'] as List? ?? const [])
            .whereType<Map>()
            .map(_map)
            .toList(growable: false);
        final memberProfiles = <String, String>{
          for (final m in memberRows)
            if ((m['name']?.toString() ?? '').isNotEmpty)
              (m['name']?.toString() ?? ''): (m['profile']?.toString() ??
                  m['handle']?.toString() ??
                  m['name']?.toString() ?? ''),
        };
        out.add(
          NgGroupChat(
            id: key,
            name: room['name']?.toString() ?? key,
            preview: preview,
            lastActiveMs: last?.atMs ?? 0,
            members: memberProfiles.keys.toList(growable: false),
            messages: messages,
            gatewayRoom: false,
            roomId: room['roomId']?.toString(),
            memberProfiles: memberProfiles,
          ),
        );
      }
    }
    return out;
  }

  NgGroupChat? _remoteGroup(Map<String, dynamic> room) {
    final id = room['room_id']?.toString();
    if (id == null || id.isEmpty) return null;
    final event = _map(room['event'] ?? room['claim_event']);
    final payload = _map(event['payload']);
    final text = payload['text']?.toString() ?? '';
    final memberRows = (room['members'] as List? ?? const [])
        .whereType<Map>()
        .map(_map)
        .toList(growable: false);
    final memberProfiles = <String, String>{
      for (final m in memberRows)
        if ((m['handle']?.toString() ?? m['profile']?.toString() ?? '').isNotEmpty)
          (m['handle']?.toString() ?? m['profile']?.toString() ?? ''):
              (m['profile']?.toString() ??
                  m['display_name']?.toString() ??
                  m['handle']?.toString() ??
                  ''),
    };
    return NgGroupChat(
      id: 'canonical:$id',
      name: room['name']?.toString() ?? id,
      preview: text,
      lastActiveMs: _seconds(room['updated_at']),
      members: memberProfiles.keys.toList(growable: false),
      messages: const [],
      gatewayRoom: true,
      roomId: id,
      memberProfiles: memberProfiles,
    );
  }

  Future<Uint8List?> loadAvatar(NgBot bot) async {
    final cached = _avatars[bot.name];
    if (cached != null) return cached;
    if (!_avatarRequests.add(bot.name)) return null;
    try {
      final reply = await scope.gateway.call('profiles.get_asset', {
        'name': bot.name,
        'asset': 'avatar',
      });
      if (reply['found'] != true) return null;
      final data = reply['data']?.toString() ?? '';
      final comma = data.indexOf(',');
      if (comma < 0 || comma + 1 >= data.length) return null;
      final bytes = base64Decode(data.substring(comma + 1));
      _avatars[bot.name] = bytes;
      notifyListeners();
      return bytes;
    } catch (_) {
      return null;
    } finally {
      _avatarRequests.remove(bot.name);
    }
  }

  Uint8List? avatarBytes(String name) => _avatars[name];
}
