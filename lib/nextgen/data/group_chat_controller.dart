// One interactive group room. Hosted rooms use the gateway's room log and
// send RPC; Desktop-mirrored rooms drive each member's hidden session, then
// fold the newest reply back into the room transcript.
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

import '../../core/services/ws_client.dart';
import 'history_rows.dart';
import 'nextgen_bots.dart';
import 'nextgen_gateway.dart';

class NgGroupChatController extends ChangeNotifier {
  NgGroupChatController({
    required this.gateway,
    required this.group,
    this.memberSessions = const <String, String>{},
  }) {
    messages.addAll(group.messages);
    _storedByProfile.addAll(memberSessions);
  }

  final NextGenGateway gateway;
  final NgGroupChat group;
  final Map<String, String> memberSessions;

  final List<NgGroupMessage> messages = [];
  bool loading = false;
  bool sending = false;
  String? error;

  /// Poll cadence for a hosted room, and between member-session reads for a
  /// mirrored room. Tests may set this to zero.
  Duration pollInterval = const Duration(seconds: 2);

  /// Bounded reads per member turn; a long run still finishes with an inline
  /// error instead of holding the composer forever.
  int maxPolls = 90;

  Timer? _poll;
  int _seq = 0;
  final Set<String> _seenEvents = <String>{};
  final Set<String> _seenAssistantIds = <String>{};
  final Map<String, String> _storedByProfile = <String, String>{};
  final Map<String, String> _runtimeByProfile = <String, String>{};
  final Map<String, String> _memberByProfile = <String, String>{};
  final Map<String, int> _baselineByProfile = <String, int>{};
  int _responderIndex = 0;
  bool _disposed = false;

  bool get isHosted => group.gatewayRoom && group.roomId != null;

  void startPolling() {
    if (!isHosted || _poll != null) return;
    _poll = Timer.periodic(pollInterval, (_) => unawaited(load()));
  }

  void stopPolling() {
    _poll?.cancel();
    _poll = null;
  }

  @override
  void dispose() {
    stopPolling();
    _disposed = true;
    super.dispose();
  }

  static Map<String, dynamic> _map(Object? value) =>
      value is Map ? Map<String, dynamic>.from(value) : <String, dynamic>{};

  static String _clean(Object error) => error
      .toString()
      .replaceFirst('Bad state: ', '')
      .replaceFirst('Exception: ', '')
      .replaceFirst(RegExp(r'^JsonRpcError\([^)]*\): '), '');

  static bool _isSessionAbsent(Object error) {
    if (error is JsonRpcError) {
      if (error.code == 4007 || error.code == 404) return true;
      if (error.message.toLowerCase().contains('session not found')) {
        return true;
      }
    }
    return error.toString().toLowerCase().contains('session not found');
  }

  /// Loads the room. Called when the page opens and by the hosted-room poll.
  Future<void> load() async {
    if (_disposed) return;
    loading = true;
    notifyListeners();
    try {
      if (messages.isEmpty) {
        messages.addAll(group.messages);
      }
      if (isHosted) {
        await gateway.call('groups.state', {'room_id': group.roomId});
        await _loadHostedDelta();
      }
      error = null;
    } catch (e) {
      error = _clean(e);
    } finally {
      loading = false;
      if (!_disposed) notifyListeners();
    }
  }

  Future<void> _loadHostedDelta() async {
    final roomId = group.roomId;
    if (roomId == null || roomId.isEmpty) return;
    var since = _seq;
    for (var page = 0; page < 10; page++) {
      final params = <String, dynamic>{'room_id': roomId, 'limit': 100};
      if (since > 0) params['since_seq'] = since;
      final result = await gateway.call('groups.log', params);
      final events = (result['events'] as List? ?? const [])
          .whereType<Map>()
          .map((e) => _map(e))
          .toList(growable: false);
      for (final event in events) {
        final id = event['event_id']?.toString() ?? '';
        final seq = (event['seq'] is num) ? (event['seq'] as num).toInt() : 0;
        if (id.isNotEmpty && !_seenEvents.add(id)) continue;
        if (!_messageKind(event['kind']?.toString())) continue;
        final payload = _map(event['payload']);
        final text = payload['text']?.toString() ?? '';
        if (text.isEmpty) continue;
        final actor = _map(event['actor']);
        final isUser = actor['kind']?.toString() == 'user';
        final author = actor['display_name']?.toString() ??
            actor['profile']?.toString() ??
            actor['id']?.toString() ??
            (isUser ? 'You' : 'Member');
        final at = event['created_at'];
        final seconds = at is num ? at : num.tryParse(at?.toString() ?? '');
        final atMs = seconds == null
            ? DateTime.now().millisecondsSinceEpoch
            : (seconds > 100000000000
                ? seconds.toInt()
                : (seconds * 1000).round());
        messages.add(
          NgGroupMessage(
            author: author,
            text: text,
            atMs: atMs,
            isUser: isUser,
          ),
        );
        if (seq > since) since = seq;
      }
      final cursor = result['cursor'];
      final latest = result['latest_seq'];
      final next = cursor is num
          ? cursor.toInt()
          : latest is num
              ? latest.toInt()
              : since;
      if (next > since) since = next;
      if (result['has_more'] != true) break;
    }
    _seq = since;
  }

  static bool _messageKind(String? kind) =>
      kind == 'message.user' || kind == 'message.member';

  /// Sends one room message. A gateway refusal keeps the draft in the room
  /// with a failed marker so the user can retry it visibly.
  Future<void> send(String raw) async {
    final text = raw.trim();
    if (text.isEmpty || sending || _disposed) return;
    sending = true;
    error = null;
    notifyListeners();
    try {
      if (isHosted) {
        await _sendHosted(text);
      } else {
        await _sendMirrored(text);
      }
    } catch (e) {
      error = _clean(e);
    } finally {
      sending = false;
      if (!_disposed) notifyListeners();
    }
  }

  Future<void> _sendHosted(String text) async {
    final roomId = group.roomId!;
    final eventId = const Uuid().v4();
    final index = messages.length;
    messages.add(
      NgGroupMessage(
        author: 'You',
        text: text,
        atMs: DateTime.now().millisecondsSinceEpoch,
        isUser: true,
        pending: true,
      ),
    );
    notifyListeners();
    try {
      final result = await gateway.call('groups.send', {
        'room_id': roomId,
        'event_id': eventId,
        'payload': {'text': text},
      });
      _seenEvents.add(eventId);
      final event = _map(result['event']);
      final ackId = event['event_id']?.toString() ?? '';
      if (ackId.isNotEmpty) _seenEvents.add(ackId);
      final seq = event['seq'];
      if (seq is num && seq.toInt() > _seq) _seq = seq.toInt();
      messages[index] = NgGroupMessage(
        author: 'You',
        text: text,
        atMs: DateTime.now().millisecondsSinceEpoch,
        isUser: true,
      );
    } catch (e) {
      messages[index] = NgGroupMessage(
        author: 'You',
        text: text,
        atMs: DateTime.now().millisecondsSinceEpoch,
        isUser: true,
        failed: true,
      );
      rethrow;
    }
  }

  Future<void> _sendMirrored(String text) async {
    messages.add(
      NgGroupMessage(
        author: 'You',
        text: text,
        atMs: DateTime.now().millisecondsSinceEpoch,
        isUser: true,
      ),
    );
    notifyListeners();
    for (final member in _responders(text)) {
      final profile = group.memberProfiles[member] ?? member;
      _memberByProfile[profile] = member;
      try {
        final session = await _ensureSession(member, profile);
        await _driveMember(member, profile, session.$1, session.$2, text);
      } catch (e) {
        error = _clean(e);
        break;
      }
      if (_disposed) return;
    }
    _persistMirrored();
  }

  List<String> _responders(String text) {
    final all = group.memberNames;
    if (all.isEmpty) return const [];
    final lower = text.toLowerCase();
    if (lower.contains('@all') || lower.contains('@everyone')) return all;
    final mentions = RegExp(r'@([A-Za-z0-9_.-]+)')
        .allMatches(text)
        .map((m) => m.group(1)?.toLowerCase() ?? '')
        .toSet();
    final addressed = all
        .where(
          (member) =>
              mentions.contains(member.toLowerCase()) ||
              mentions.contains(
                (group.memberProfiles[member] ?? member).toLowerCase(),
              ),
        )
        .toList(growable: false);
    if (addressed.isNotEmpty) return addressed;
    // No address: rotate from the last responder so a room stays a
    // conversation instead of summoning the full roster on every message.
    final rotated = [
      ...all.skip(_responderIndex % all.length),
      ...all.take(_responderIndex % all.length),
    ];
    _responderIndex = (_responderIndex + 1) % all.length;
    return rotated;
  }

  /// `(stored id, runtime id)`. Only a definitive session-not-found mints a
  /// new hidden room session; a transient failure is surfaced, not hidden by
  /// creating a second session for the member.
  Future<(String, String)> _ensureSession(
    String member,
    String profile,
  ) async {
    final known = memberSessions[profile] ?? _storedByProfile[profile];
    if (known != null && known.isNotEmpty) {
      try {
        final result = await gateway.call('session.resume', {
          'session_id': known,
          'profile': profile,
          'omit_messages': true,
        });
        final runtime = result['session_id']?.toString() ?? '';
        if (runtime.isNotEmpty) {
          final stored = result['session_key']?.toString() ?? known;
          _storedByProfile[profile] = stored;
          _runtimeByProfile[profile] = runtime;
          return (stored, runtime);
        }
      } catch (e) {
        if (!_isSessionAbsent(e)) rethrow;
      }
    }
    final result = await gateway.call(
      'session.create',
      {
        'source': gateway.sessionAuthority ? 'gui' : 'desktop',
        'profile': profile,
        'title': 'Group: ${group.id}',
        'hidden': true,
        'room_plumbing': true,
        'follow_profile_config': true,
      },
    );
    final stored = result['stored_session_id']?.toString() ?? '';
    final runtime = result['session_id']?.toString() ?? stored;
    if (runtime.isEmpty) {
      throw StateError('The gateway did not open a session for $member.');
    }
    _storedByProfile[profile] = stored.isEmpty ? runtime : stored;
    _runtimeByProfile[profile] = runtime;
    return (_storedByProfile[profile]!, runtime);
  }

  Future<void> _driveMember(
    String member,
    String profile,
    String stored,
    String runtime,
    String text,
  ) async {
    final rowsBefore = await _history(profile, stored);
    _baselineByProfile[profile] =
        rowsBefore.where((r) => r['role']?.toString() == 'assistant').length;
    final prompt = _turnPrompt(member, text);
    await gateway.call('prompt.submit', {
      'session_id': runtime,
      'profile': profile,
      'text': prompt,
      'submission_id': const Uuid().v4(),
    });
    for (var i = 0; i < maxPolls && !_disposed; i++) {
      if (await pollOnce(profile)) return;
      if (pollInterval > Duration.zero && i + 1 < maxPolls) {
        await Future<void>.delayed(pollInterval);
      }
    }
  }

  Future<List<Map<String, dynamic>>> _history(
    String profile,
    String stored,
  ) async =>
      ngDecodeHistory(
        await gateway.api.getMessagesBytes(
          stored,
          latest: true,
          limit: 20,
          profile: profile,
        ),
      );

  /// Reads one member session and appends its newest assistant reply to the
  /// room, unless it is the Desktop pass marker. Returns true when a
  /// substantive reply was added.
  Future<bool> pollOnce(String profile) async {
    final stored = _storedByProfile[profile] ?? _runtimeByProfile[profile];
    if (stored == null || stored.isEmpty) return false;
    final rows = await _history(profile, stored);
    final assistant = rows
        .where((r) => r['role']?.toString() == 'assistant')
        .toList(growable: false);
    final baseline = _baselineByProfile[profile] ?? 0;
    if (assistant.length <= baseline) return false;
    _baselineByProfile[profile] = assistant.length;
    final reply = assistant.last;
    final id = reply['id']?.toString() ?? '';
    if (id.isNotEmpty && !_seenAssistantIds.add(id)) return false;
    final body = _replyText(reply['content']);
    if (body.isEmpty || body == '(pass)') return false;
    messages.add(
      NgGroupMessage(
        author: _memberByProfile[profile] ?? profile,
        text: body,
        atMs: DateTime.now().millisecondsSinceEpoch,
        isUser: false,
      ),
    );
    notifyListeners();
    return true;
  }

  static String _replyText(Object? content) {
    if (content is String) return content.trim();
    if (content is List) {
      for (final part in content) {
        if (part is String && part.trim().isNotEmpty) return part.trim();
        if (part is Map) {
          final text = _map(part)['text']?.toString().trim();
          if (text != null && text.isNotEmpty) return text;
        }
      }
    }
    if (content is Map) return _map(content)['text']?.toString().trim() ?? '';
    return '';
  }

  String _turnPrompt(String member, String text) {
    final members = group.memberNames;
    final peers = members
        .where((m) => m.toLowerCase() != member.toLowerCase())
        .map((m) => '@$m')
        .join(', ');
    final lines = messages
        .where((m) => m.text.trim().isNotEmpty)
        .skip(messages.length > 8 ? messages.length - 8 : 0)
        .map(
          (m) => m.isUser
              ? 'User (user): ${m.text}'
              : '${m.author} (member): ${m.text}',
        )
        .join('\n');
    return [
      '[Group chat: "${group.name}"] You are @$member, one participant in '
          'a group chat with ${peers.isEmpty ? 'no one else yet' : peers} '
          'and the user.',
      '',
      'New messages in the room since your last turn (oldest first):',
      ...lines.split('\n').map((line) => '  $line'),
      '',
      'Rules for this room:',
      '- Reply with ONE conversational message ONLY if you have something '
          'new worth adding: build on what was said, answer a question aimed '
          'at you, or report a real result. Keep chatter short, but give '
          'real work full quality and length.',
      '- If you have nothing new to add, reply with exactly "(pass)".',
      '- Mention a teammate as @name to pull them in; mention @user only '
          'for a judgment call or a result the user needs.',
      '- Never reveal content from your private 1:1 chats. Your reply text '
          'goes to the room verbatim, with no preamble or meta-commentary.',
    ].join('\n');
  }

  /// Best-effort bounded mirror write so a native room survives a restart.
  /// A CAS conflict or old gateway leaves the in-memory room usable.
  void _persistMirrored() {
    unawaited(_persistMirroredAsync());
  }

  Future<void> _persistMirroredAsync() async {
    try {
      final listing = await gateway.call('profiles.list', {
        'include_sessions': false,
      });
      final rows = (listing['profiles'] as List? ?? const [])
          .whereType<Map>()
          .map(_map)
          .toList(growable: false);
      final owner = rows.firstWhere(
        (r) => r['is_default'] == true,
        orElse: () => rows.isEmpty ? <String, dynamic>{} : rows.first,
      );
      final name = owner['name']?.toString();
      if (name == null || name.isEmpty) return;
      final meta = _map(owner['ui_meta']);
      final mirror = _map(meta['hermes-bots-groups']);
      final rooms = _map(mirror['rooms']);
      final room = _map(rooms[group.id]);
      final log = messages
          .where((m) => m.text.isNotEmpty)
          .skip(messages.length > 16 ? messages.length - 16 : 0)
          .map(
            (m) => {
              'at': m.atMs,
              'from': {
                'kind': m.isUser ? 'user' : 'member',
                'name': m.author,
              },
              'text': m.text.length > 1200
                  ? '${m.text.substring(0, 1200)}…'
                  : m.text,
            },
          )
          .toList(growable: false);
      rooms[group.id] = {...room, 'name': group.name, 'log': log};
      final revisions = _map(owner['ui_meta_revisions']);
      final revision = revisions['hermes-bots-groups'];
      final payload = <String, dynamic>{
        'name': name,
        'ui_meta': {
          'hermes-bots-groups': {...mirror, 'rooms': rooms},
        },
      };
      if (revision != null) {
        payload['ui_meta_expected_revisions'] = {
          'hermes-bots-groups': revision,
        };
      }
      await gateway.call('profiles.configure', payload);
    } catch (_) {
      // The room stays usable in memory; persistence is best effort.
    }
  }
}
