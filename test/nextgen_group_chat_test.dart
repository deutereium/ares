// Interactive groups: hosted rooms read their log and send through
// groups.send; mirrored Desktop rooms prompt member profiles and show replies
// in a full-screen chat page with a composer.
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/dashboard_api_client.dart';
import 'package:hermes_android/nextgen/data/group_chat_controller.dart';
import 'package:hermes_android/nextgen/data/nextgen_bots.dart';
import 'package:hermes_android/nextgen/data/nextgen_gateway.dart';
import 'package:hermes_android/nextgen/nextgen_preferences.dart';
import 'package:hermes_android/nextgen/theme/nextgen_theme.dart';
import 'package:hermes_android/nextgen/ui/group_chat_page.dart';

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

class _Gateway extends NextGenGateway {
  _Gateway() : super(_conn());

  final calls = <({String method, Map<String, dynamic> params})>[];
  final handlers = <String, Future<Map<String, dynamic>> Function(
    Map<String, dynamic> params,
  )>{};

  List<({String method, Map<String, dynamic> params})> callsTo(String m) =>
      calls.where((c) => c.method == m).toList();

  @override
  Future<Map<String, dynamic>> call(
    String method,
    Map<String, dynamic> params, {
    Duration timeout = const Duration(seconds: 30),
  }) async {
    calls.add((method: method, params: Map<String, dynamic>.from(params)));
    final handler = handlers[method];
    if (handler == null) return const {};
    return Map<String, dynamic>.from(await handler(params));
  }
}

class _Api extends DashboardApiClient {
  _Api(super.dashboard) : super.withDashboard();

  List<Map<String, dynamic>> rows = const [];

  @override
  Future<Uint8List> getMessagesBytes(
    String sessionId, {
    int? limit,
    int offset = 0,
    bool latest = false,
    String? profile,
  }) async =>
      Uint8List.fromList(
        utf8.encode(jsonEncode({'messages': rows})),
      );
}

NgGroupChat _hosted() => NgGroupChat(
  id: 'canonical:room-1',
  name: 'Ops',
  preview: '',
  lastActiveMs: 0,
  members: const ['kiro', 'aleph'],
  messages: const [],
  gatewayRoom: true,
  roomId: 'room-1',
);

NgGroupChat _mirrored() => NgGroupChat(
  id: 'IP group',
  name: 'IP group',
  preview: '',
  lastActiveMs: 0,
  members: const ['kiro'],
  memberProfiles: const {'kiro': 'kiro'},
  messages: const [],
  gatewayRoom: false,
);

void main() {
  test('hosted rooms load the log and send through groups.send', () async {
    final gateway = _Gateway();
    gateway.handlers['groups.state'] = (_) async => {
      'room': {
        'room_id': 'room-1',
        'name': 'Ops',
        'members': const [],
        'authority_gateway_id': 'gw',
        'authority_epoch': 1,
        'revision': 1,
        'created_at': 0,
        'updated_at': 0,
      },
    };
    gateway.handlers['groups.log'] = (params) async => {
      'events': [
        {
          'seq': 1,
          'event_id': 'e1',
          'kind': 'message.user',
          'actor': {'kind': 'user', 'id': 'user'},
          'payload': {'text': 'ping'},
          'created_at': 1000,
        },
        {
          'seq': 2,
          'event_id': 'e2',
          'kind': 'message.member',
          'actor': {'kind': 'member', 'id': 'kiro', 'profile': 'kiro'},
          'payload': {'text': 'pong'},
          'created_at': 2000,
        },
      ],
      'cursor': 2,
      'latest_seq': 2,
      'has_more': false,
      'authority': {'gateway_id': 'gw', 'epoch': 1},
    };
    gateway.handlers['groups.send'] = (params) async => {
      'event': {
        'room_id': 'room-1',
        'seq': 3,
        'event_id': params['event_id']?.toString() ?? 'e3',
        'kind': 'message.user',
        'actor': {'kind': 'user', 'id': 'user'},
        'payload': {'text': params['payload']?['text'] ?? ''},
        'created_at': 3000,
      },
      'accepted': true,
    };
    final controller = NgGroupChatController(
      gateway: gateway,
      group: _hosted(),
    );
    addTearDown(controller.dispose);

    await controller.load();

    expect(controller.messages.map((m) => m.text), ['ping', 'pong']);
    expect(controller.messages.last.isUser, isFalse);
    await controller.send('hello');
    final send = gateway.callsTo('groups.send').single.params;
    expect(send['room_id'], 'room-1');
    expect(send['event_id'], isNotEmpty);
    expect(send['payload']?['text'], 'hello');
    expect(controller.messages.last.text, 'hello');
  });

  test('mirrored rooms prompt the member profile and show the reply', () async {
    final gateway = _Gateway();
    final api = _Api(gateway.dashboard);
    gateway.api = api;
    api.rows = [
      {'id': 1, 'role': 'user', 'content': 'hello @kiro'},
    ];
    gateway.handlers['session.resume'] = (_) async => {
      'session_id': 'rt-1',
      'session_key': 'stored-1',
    };
    gateway.handlers['prompt.submit'] = (_) async => {'status': 'started'};
    final controller = NgGroupChatController(
      gateway: gateway,
      group: _mirrored(),
      memberSessions: const {'kiro': 'stored-1'},
    )
      ..pollInterval = Duration.zero
      ..maxPolls = 3;
    addTearDown(controller.dispose);
    gateway.handlers['prompt.submit'] = (params) async {
      api.rows = [
        {'id': 1, 'role': 'user', 'content': 'hello @kiro'},
        {'id': 2, 'role': 'assistant', 'content': 'on it'},
      ];
      return {'status': 'started'};
    };

    await controller.send('hello @kiro');

    final submit = gateway.callsTo('prompt.submit').single.params;
    expect(submit['profile'], 'kiro');
    expect(submit['text'], contains('[Group chat: "IP group"]'));
    expect(
      controller.messages.map((m) => m.text),
      contains('on it'),
    );
  });

  test('a transient resume failure does not mint a new session', () async {
    final gateway = _Gateway();
    gateway.handlers['session.resume'] = (_) async => throw StateError(
      'Not connected',
    );
    final controller = NgGroupChatController(
      gateway: gateway,
      group: _mirrored(),
      memberSessions: const {'kiro': 'stored-1'},
    );
    addTearDown(controller.dispose);

    await controller.send('hello');

    expect(gateway.callsTo('session.create'), isEmpty);
    expect(controller.error, isNotNull);
  });

  testWidgets('the page shows messages and a composer', () async {
    final gateway = _Gateway();
    final controller = NgGroupChatController(
      gateway: gateway,
      group: _hosted(),
    );
    addTearDown(controller.dispose);
    controller.messages.add(
      const NgGroupMessage(
        author: 'kiro',
        text: 'pong',
        atMs: 1000,
        isUser: false,
      ),
    );
    controller.notifyListeners();

    await tester.pumpWidget(
      MaterialApp(
        theme: nextGenTheme(Brightness.light, NextGenLook.instance),
        home: NgGroupChatPage(controller: controller),
      ),
    );

    expect(find.byType(TextField), findsOneWidget);
    expect(find.byIcon(Icons.send), findsOneWidget);
    expect(find.text('pong'), findsOneWidget);
  });
}
