// A chat running elsewhere (Telegram, another device) must resume reliably:
// history is hydrated before the live bind, transient resume failures get a
// bounded retry, a definitive "session not found" is never retried, and a
// reconnect rebinds the stored session instead of trusting a stale runtime id.
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/dashboard_api_client.dart';
import 'package:hermes_android/core/services/ws_client.dart';
import 'package:hermes_android/nextgen/data/chat_controller.dart';
import 'package:hermes_android/nextgen/data/nextgen_gateway.dart';

SavedConnection _conn() => SavedConnection(
  id: 'c1',
  label: 'Home',
  host: '10.0.0.5',
  port: 9119,
  apiKey: '',
  desktopGatewayUrl: 'http://10.0.0.5:9119',
  singleLogin: true,
  signInMethod: 'none',
);

class _ResumeGateway extends NextGenGateway {
  _ResumeGateway() : super(_conn());

  final calls = <({String method, Map<String, dynamic> params})>[];
  final reconnects = StreamController<void>.broadcast();
  final _socket = WsClient('http://10.0.0.5:9119');

  Future<Map<String, dynamic>> Function(
    String method,
    Map<String, dynamic> params,
  )?
  onCall;

  List<({String method, Map<String, dynamic> params})> callsTo(String m) =>
      calls.where((c) => c.method == m).toList();

  @override
  WsClient? get socket => _socket;

  @override
  Stream<void> get reconnected => reconnects.stream;

  @override
  Future<WsClient> connected({
    Duration timeout = const Duration(seconds: 20),
  }) async => _socket;

  @override
  Future<Map<String, dynamic>> call(
    String method,
    Map<String, dynamic> params, {
    Duration timeout = const Duration(seconds: 30),
  }) async {
    calls.add((method: method, params: Map<String, dynamic>.from(params)));
    final handler = onCall;
    if (handler == null) return const {};
    return Map<String, dynamic>.from(await handler(method, params));
  }

  @override
  void dispose() {
    unawaited(reconnects.close());
    _socket.close();
    super.dispose();
  }
}

class _HistoryApi extends DashboardApiClient {
  _HistoryApi(super.dashboard) : super.withDashboard();

  final order = <String>[];
  List<Map<String, dynamic>> rows = const [];

  @override
  Future<Uint8List> getMessagesBytes(
    String sessionId, {
    int? limit,
    int offset = 0,
    bool latest = false,
    String? profile,
  }) async {
    order.add('history');
    return Uint8List.fromList(
      utf8.encode(jsonEncode({'messages': rows})),
    );
  }
}

NgChatController _chat(_ResumeGateway gateway) => NgChatController(
  gateway,
  sessionId: 'stored',
)..resumeRetryDelays = const [
  Duration.zero,
  Duration.zero,
  Duration.zero,
];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('a transient resume failure is retried with a bounded budget', () async {
    final gateway = _ResumeGateway();
    final api = _HistoryApi(gateway.dashboard);
    gateway.api = api;
    var attempts = 0;
    gateway.onCall = (method, params) async {
      if (method == 'session.resume') {
        attempts++;
        if (attempts < 3) throw StateError('Not connected');
        return {'session_id': 'rt-1'};
      }
      return const {};
    };
    final chat = _chat(gateway);
    addTearDown(() {
      chat.dispose();
      gateway.dispose();
    });

    await chat.open();
    expect(attempts, 3);
    expect(chat.runtimeId, 'rt-1');
    expect(chat.resumeError, isNull);
  });

  test('exhausted retries surface an error and a manual retry can recover', () async {
    final gateway = _ResumeGateway();
    final api = _HistoryApi(gateway.dashboard);
    gateway.api = api;
    var attempts = 0;
    gateway.onCall = (method, params) async {
      if (method == 'session.resume') {
        attempts++;
        throw StateError('Not connected');
      }
      return const {};
    };
    final chat = _chat(gateway);
    addTearDown(() {
      chat.dispose();
      gateway.dispose();
    });

    await chat.open();
    expect(attempts, 4, reason: 'the first try plus three retries');
    expect(chat.resumeError, isNotNull);
    expect(chat.error, isNotNull);

    gateway.onCall = (method, params) async {
      if (method == 'session.resume') return {'session_id': 'rt-2'};
      return const {};
    };
    await chat.retryResume();
    expect(chat.runtimeId, 'rt-2');
    expect(chat.resumeError, isNull);
    expect(chat.error, isNull);
  });

  test('a definitive session-not-found is not retried', () async {
    final gateway = _ResumeGateway();
    final api = _HistoryApi(gateway.dashboard);
    gateway.api = api;
    var attempts = 0;
    gateway.onCall = (method, params) async {
      if (method == 'session.resume') {
        attempts++;
        throw JsonRpcError('session.resume', 'session not found', code: 4007);
      }
      return const {};
    };
    final chat = _chat(gateway);
    addTearDown(() {
      chat.dispose();
      gateway.dispose();
    });

    await chat.open();
    expect(attempts, 1);
    expect(chat.resumeError, contains('session not found'));
  });

  test('a reconnect rebinds the stored session, not the stale runtime', () async {
    final gateway = _ResumeGateway();
    final api = _HistoryApi(gateway.dashboard);
    gateway.api = api;
    var resumes = 0;
    gateway.onCall = (method, params) async {
      if (method == 'session.resume') {
        resumes++;
        return {'session_id': 'rt-$resumes'};
      }
      return const {};
    };
    final chat = _chat(gateway);
    addTearDown(() {
      chat.dispose();
      gateway.dispose();
    });

    await chat.open();
    expect(chat.runtimeId, 'rt-1');

    gateway.reconnects.add(null);
    await pumpEventQueue(times: 100);

    final resumeCalls = gateway.callsTo('session.resume');
    expect(resumeCalls.length, greaterThan(1));
    expect(resumeCalls.last.params['session_id'], 'stored');
    expect(chat.runtimeId, 'rt-$resumes');
    expect(gateway.callsTo('prompt.submit'), isEmpty);
  });

  test('a running chat elsewhere hydrates history before binding, never re-sends', () async {
    final gateway = _ResumeGateway();
    final api = _HistoryApi(gateway.dashboard);
    gateway.api = api;
    api.rows = [
      {'id': 1, 'role': 'user', 'content': 'Do it'},
      {'id': 2, 'role': 'assistant', 'content': 'Working'},
    ];
    final order = api.order;
    gateway.onCall = (method, params) async {
      order.add(method);
      if (method == 'session.resume') {
        return {'session_id': 'rt-1', 'running': true};
      }
      return const {};
    };
    final chat = _chat(gateway);
    addTearDown(() {
      chat.dispose();
      gateway.dispose();
    });

    await chat.open();
    expect(order.indexOf('history'), lessThan(order.indexOf('session.resume')));
    expect(chat.running, isTrue);
    expect(chat.items.whereType<NgUserItem>().map((i) => i.text), ['Do it']);
    expect(gateway.callsTo('prompt.submit'), isEmpty);
  });
}
