// Bot chats are one canonical "Bot Chat" on the bot's own profile. Every
// session RPC and the REST transcript must carry that profile, a bot with no
// canonical session opens an empty chat that creates one on first send, the
// sidebar keeps its tab across rebuilds, and the chat header names the bot.
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/dashboard_api_client.dart';
import 'package:hermes_android/core/services/ws_client.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:hermes_android/nextgen/data/chat_controller.dart';
import 'package:hermes_android/nextgen/data/nextgen_bots.dart';
import 'package:hermes_android/nextgen/data/nextgen_gateway.dart';
import 'package:hermes_android/nextgen/nextgen_preferences.dart';
import 'package:hermes_android/nextgen/theme/nextgen_theme.dart';
import 'package:hermes_android/nextgen/ui/avatar.dart';
import 'package:hermes_android/nextgen/ui/bots_pane.dart';
import 'package:hermes_android/nextgen/ui/chat_view.dart';
import 'package:hermes_android/nextgen/ui/nextgen_scope.dart';
import 'package:hermes_android/nextgen/ui/sessions_sidebar.dart';
import 'package:shared_preferences/shared_preferences.dart';

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

const _canonicalReady = {
  'params': {
    'payload': {'session_authority': true},
  },
};

class _RoutingGateway extends NextGenGateway {
  _RoutingGateway({bool authority = true}) : super(_conn()) {
    if (authority) readyFrame = _canonicalReady;
  }

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

  final reads = <({String id, String? profile})>[];
  List<Map<String, dynamic>> rows = const [];

  @override
  Future<Uint8List> getMessagesBytes(
    String sessionId, {
    int? limit,
    int offset = 0,
    bool latest = false,
    String? profile,
  }) async {
    reads.add((id: sessionId, profile: profile));
    return Uint8List.fromList(
      utf8.encode(jsonEncode({'messages': rows})),
    );
  }
}

NgScope _scope(Widget child, NextGenGateway gateway) {
  return NgScope(
    connManager: ConnectionManager(_prefs!),
    gateway: gateway,
    connections: [_conn()],
    switchTo: (_) async {},
    addGateway: () async {},
    signOut: (_) async {},
    reload: () async {},
    signInAgain: () async {},
    child: child,
  );
}

SharedPreferences? _prefs;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    _prefs = await SharedPreferences.getInstance();
  });

  group('profile-scoped bot chats', () {
    test('resume, history, replay and prompts carry the bot profile', () async {
      final gateway = _RoutingGateway();
      final api = _HistoryApi(gateway.dashboard);
      gateway.api = api;
      gateway.onCall = (method, params) async {
        switch (method) {
          case 'session.resume':
            return {
              'session_id': 'rt-1',
              'replay_epoch': 'e1',
              'last_sequence': 0,
            };
          case 'session.events.since':
            return {
              'events': const [],
              'latest_seq': 0,
              'truncated': false,
              'epoch': 'e1',
            };
          case 'prompt.submit':
            return {'status': 'started'};
        }
        return const {};
      };
      final chat = NgChatController(
        gateway,
        sessionId: 'bot-stored',
        sessionProfile: 'work-bot',
      );
      addTearDown(() {
        chat.dispose();
        gateway.dispose();
      });

      await chat.open();
      expect(api.reads.single.profile, 'work-bot');
      expect(
        gateway.callsTo('session.resume').single.params['profile'],
        'work-bot',
      );

      gateway.reconnects.add(null);
      await pumpEventQueue(times: 50);
      expect(
        gateway.callsTo('session.events.since').single.params['profile'],
        'work-bot',
      );

      expect(await chat.send('hello'), isTrue);
      expect(
        gateway.callsTo('prompt.submit').single.params['profile'],
        'work-bot',
      );
    });

    test('a new bot chat creates a hidden Bot Chat on the bot profile', () async {
      final gateway = _RoutingGateway();
      gateway.onCall = (method, params) async {
        if (method == 'session.create') {
          return {
            'session_id': 'rt-new',
            'stored_session_id': 'stored-new',
          };
        }
        if (method == 'prompt.submit') return {'status': 'started'};
        return const {};
      };
      final chat = NgChatController(
        gateway,
        sessionProfile: 'work-bot',
        identity: const NgChatIdentity(botName: 'Helper'),
      );
      addTearDown(() {
        chat.dispose();
        gateway.dispose();
      });

      expect(await chat.send('hello'), isTrue);
      final create = gateway.callsTo('session.create').single.params;
      expect(create['profile'], 'work-bot');
      expect(create['title'], 'Bot Chat');
      expect(create['hidden'], isTrue);
      expect(create['follow_profile_config'], isTrue);
      expect(
        gateway.callsTo('prompt.submit').single.params['profile'],
        'work-bot',
      );
    });
  });

  group('sidebar tab', () {
    testWidgets('is driven from outside and survives a rebuild', (tester) async {
      final gateway = _RoutingGateway();
      gateway.onCall = (method, params) async {
        if (method == 'profiles.list') return {'profiles': const []};
        if (method == 'groups.list') return {'rooms': const []};
        return const {};
      };
      addTearDown(gateway.dispose);
      final scope = _scope(const SizedBox(), gateway);
      final sessions = NgSessionsModel(scope);
      final bots = NgBotsModel(scope);
      addTearDown(() {
        sessions.dispose();
        bots.dispose();
      });
      final changed = <NgSidebarTab>[];

      Widget build(NgSidebarTab tab) => MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        theme: nextGenTheme(Brightness.light, NextGenLook.instance),
        home: _scope(
          Scaffold(
            body: NgSessionsSidebar(
              model: sessions,
              currentSessionId: null,
              onOpen: (_) {},
              onNewChat: (_) {},
              onDestination: (_) {},
              bots: bots,
              selectedTab: tab,
              onTabChanged: changed.add,
            ),
          ),
          gateway,
        ),
      );

      await tester.pumpWidget(build(NgSidebarTab.bots));
      await tester.pump();
      expect(find.byType(NgBotsPane), findsOneWidget);

      await tester.pumpWidget(build(NgSidebarTab.sessions));
      await tester.pump();
      expect(find.byType(NgBotsPane), findsNothing);

      await tester.tap(
        find.descendant(
          of: find.byKey(const Key('ng-sidebar-tabs')),
          matching: find.text('Bots'),
        ),
      );
      await tester.pump();
      expect(changed, contains(NgSidebarTab.bots));
    });
  });

  group('chat header', () {
    testWidgets('a bot shows its avatar, name and description', (tester) async {
      final gateway = _RoutingGateway();
      addTearDown(gateway.dispose);
      final chat = NgChatController(
        gateway,
        sessionId: 'bot-stored',
        sessionProfile: 'work-bot',
        title: 'Bot Chat',
        identity: const NgChatIdentity(
          profileName: 'work-bot',
          botName: 'Helper',
          botDescription: 'Does the chores',
        ),
      );
      addTearDown(chat.dispose);

      await tester.pumpWidget(
        MaterialApp(
          theme: nextGenTheme(Brightness.light, NextGenLook.instance),
          home: _scope(
            NgChatView(
              chat: chat,
              onOpenSidebar: () {},
              onNewChat: () {},
            ),
            gateway,
          ),
        ),
      );
      await tester.pump();

      expect(find.text('Helper'), findsOneWidget);
      expect(find.text('Does the chores'), findsOneWidget);
      expect(find.byType(NgAvatar), findsOneWidget);
    });

    testWidgets('a session shows the profile and its title', (tester) async {
      final gateway = _RoutingGateway();
      addTearDown(gateway.dispose);
      final chat = NgChatController(
        gateway,
        sessionId: 'stored',
        title: 'Roadmap',
      );
      addTearDown(chat.dispose);

      await tester.pumpWidget(
        MaterialApp(
          theme: nextGenTheme(Brightness.light, NextGenLook.instance),
          home: _scope(
            NgChatView(
              chat: chat,
              onOpenSidebar: () {},
              onNewChat: () {},
            ),
            gateway,
          ),
        ),
      );
      await tester.pump();

      expect(find.text('default'), findsOneWidget);
      expect(find.text('Roadmap'), findsOneWidget);
    });
  });
}
