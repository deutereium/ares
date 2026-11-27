// Bot and group management write the same places Desktop does: presentation in
// the profile's `hermes-bots` ui_meta (compare-and-swap), the avatar in the
// profile asset store, and hosted rooms through groups.rename / groups.disband.
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/nextgen/data/nextgen_bots.dart';
import 'package:hermes_android/nextgen/data/nextgen_gateway.dart';
import 'package:hermes_android/nextgen/ui/nextgen_scope.dart';
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

class _FakeGateway extends NextGenGateway {
  _FakeGateway() : super(_conn());

  final calls = <({String method, Map<String, dynamic> params})>[];

  Future<Map<String, dynamic>> Function(
    String method,
    Map<String, dynamic> params,
  )?
  onCall;

  List<Map<String, dynamic>> callsTo(String method) => calls
      .where((c) => c.method == method)
      .map((c) => c.params)
      .toList(growable: false);

  @override
  Future<Map<String, dynamic>> call(
    String method,
    Map<String, dynamic> params, {
    Duration timeout = const Duration(seconds: 30),
  }) async {
    calls.add((method: method, params: Map<String, dynamic>.from(params)));
    final handler = onCall;
    if (handler == null) return <String, dynamic>{};
    return Map<String, dynamic>.from(await handler(method, params));
  }
}

Map<String, dynamic> _row({
  String name = 'sol',
  String title = 'Old',
  int revision = 4,
  String? sectionName = 'Work',
  String? sectionId = 'sec-work',
  Map<String, dynamic> extra = const {},
}) => {
  'name': name,
  'path': '/home/serei/.hermes/profiles/$name',
  'is_default': true,
  'description': 'old role',
  'has_avatar': false,
  'ui_meta': {
    'hermes-bots': {
      'title': title,
      'color': '#ff8800',
      'sectionName': ?sectionName,
      'sectionId': ?sectionId,
      ...extra,
    },
  },
  'ui_meta_revisions': {'hermes-bots': revision},
};

NgGroupChat _hosted() => const NgGroupChat(
  id: 'canonical:r1',
  name: 'Old room',
  preview: '',
  lastActiveMs: 0,
  members: ['sol'],
  messages: [],
  gatewayRoom: true,
  roomId: 'r1',
);

NgGroupChat _mirrored() => const NgGroupChat(
  id: 'room-a',
  name: 'Old mirror',
  preview: '',
  lastActiveMs: 0,
  members: ['sol'],
  messages: [],
  gatewayRoom: false,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late SharedPreferences prefs;
  late _FakeGateway gateway;
  late NgBotsModel model;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    gateway = _FakeGateway();
    model = NgBotsModel(
      NgScope(
        connManager: ConnectionManager(prefs),
        gateway: gateway,
        connections: [_conn()],
        switchTo: (_) async {},
        addGateway: () async {},
        signOut: (_) async {},
        reload: () async {},
        signInAgain: () async {},
        child: const SizedBox.shrink(),
      ),
    );
  });

  tearDown(() => model.dispose());

  Future<void> seed(Map<String, dynamic> row) async {
    gateway.onCall = (method, params) async => switch (method) {
      'profiles.list' => {'profiles': [row]},
      'groups.list' => {'rooms': []},
      _ => <String, dynamic>{},
    };
    await model.refresh();
  }

  test('saveBot writes the title into hermes-bots and the role as description',
      () async {
    await seed(_row());
    gateway.onCall = (method, params) async => switch (method) {
      'profiles.list' => {'profiles': [_row()]},
      'profiles.configure' => {
        'ok': true,
        'applied': {'ui_meta': true, 'description': true},
      },
      _ => <String, dynamic>{},
    };

    final ok = await model.saveBot(
      name: 'sol',
      title: '  Sol  ',
      description: ' helps with code ',
      sectionName: ' Main ',
    );

    expect(ok, isTrue);
    final configure = gateway.callsTo('profiles.configure').single;
    expect(configure['name'], 'sol');
    expect(configure['description'], 'helps with code');
    expect(configure['ui_meta_expected_revisions'], {'hermes-bots': 4});
    final meta = configure['ui_meta']['hermes-bots'] as Map;
    expect(meta['title'], 'Sol');
    // Fields this client does not own survive the write.
    expect(meta['color'], '#ff8800');
    expect(meta['sectionName'], 'Main');
    // "Main" had no member here, so the edit mints a folder id for Desktop.
    expect(meta['sectionId'], isA<String>());
    expect(meta['sectionId'], startsWith('sec-'));
    expect(meta['sectionId'], isNot('sec-work'));
  });

  test('saveBot keeps the folder id Desktop gave a name', () async {
    final sol = _row();
    final nanox = _row(name: 'nanox', sectionName: null, sectionId: null);
    gateway.onCall = (method, params) async => switch (method) {
      'profiles.list' => {'profiles': [sol, nanox]},
      'groups.list' => {'rooms': []},
      _ => <String, dynamic>{},
    };
    await model.refresh();
    gateway.onCall = (method, params) async => switch (method) {
      'profiles.list' => {'profiles': [sol, nanox]},
      'profiles.configure' => {
        'ok': true,
        'applied': {'ui_meta': true},
      },
      _ => <String, dynamic>{},
    };

    await model.saveBot(
      name: 'nanox',
      title: 'N',
      description: 'role',
      sectionName: 'Work',
    );

    final meta = gateway.callsTo('profiles.configure').single['ui_meta'][
        'hermes-bots'] as Map;
    expect(meta['sectionName'], 'Work');
    expect(meta['sectionId'], 'sec-work');
  });

  test('saveBot clears the section to move a bot to Unassigned', () async {
    await seed(_row());
    gateway.onCall = (method, params) async => switch (method) {
      'profiles.list' => {'profiles': [_row()]},
      'profiles.configure' => {
        'ok': true,
        'applied': {'ui_meta': true},
      },
      _ => <String, dynamic>{},
    };

    await model.saveBot(
      name: 'sol',
      title: 'Old',
      description: 'old role',
      sectionName: '  ',
    );

    final meta = gateway.callsTo('profiles.configure').single['ui_meta'][
        'hermes-bots'] as Map;
    expect(meta.containsKey('sectionName'), isFalse);
    expect(meta.containsKey('sectionId'), isFalse);
  });

  test('saveBot retries a compare-and-swap conflict against the fresh revision',
      () async {
    await seed(_row());
    var lists = 0;
    gateway.onCall = (method, params) async {
      if (method == 'profiles.list') {
        lists += 1;
        return {
          'profiles': [lists == 1 ? _row() : _row(revision: 5, title: 'Other')],
        };
      }
      if (method == 'profiles.configure') {
        if (params['ui_meta_expected_revisions']['hermes-bots'] == 4) {
          return {
            'ok': false,
            'applied': {
              'ui_meta_conflicts': {
                'hermes-bots': {'expected': 4, 'actual': 5},
              },
            },
          };
        }
        return {
          'ok': true,
          'applied': {'ui_meta': true},
        };
      }
      return <String, dynamic>{};
    };

    await model.saveBot(name: 'sol', title: 'New', description: 'role');

    final configures = gateway.callsTo('profiles.configure');
    expect(configures, hasLength(2));
    expect(configures.first['ui_meta_expected_revisions'], {'hermes-bots': 4});
    expect(configures.last['ui_meta_expected_revisions'], {'hermes-bots': 5});
    // The description is not compare-and-swapped: it is sent exactly once.
    expect(configures.first.containsKey('description'), isTrue);
    expect(configures.last.containsKey('description'), isFalse);
  });

  test('saveBot stores a PNG avatar in the asset store', () async {
    await seed(_row());
    gateway.onCall = (method, params) async => switch (method) {
      'profiles.list' => {'profiles': [_row()]},
      'profiles.configure' => {
        'ok': true,
        'applied': {'ui_meta': true},
      },
      _ => <String, dynamic>{},
    };
    final png = Uint8List.fromList([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a]);

    await model.saveBot(
      name: 'sol',
      title: 'Old',
      description: 'old role',
      avatarBytes: png,
    );

    final asset = gateway.callsTo('profiles.set_asset').single;
    expect(asset['name'], 'sol');
    expect(asset['asset'], 'avatar');
    expect(asset['data'], startsWith('data:image/png;base64,'));
    final meta = gateway.callsTo('profiles.configure').single['ui_meta'][
        'hermes-bots'] as Map;
    expect(meta['custom'], isTrue);
  });

  test('saveBot refuses an unsupported image without calling the gateway',
      () async {
    await seed(_row());
    gateway.calls.clear();

    final ok = await model.saveBot(
      name: 'sol',
      title: 'Old',
      description: 'old role',
      avatarBytes: Uint8List.fromList([0x00, 0x01, 0x02, 0x03]),
    );

    expect(ok, isFalse);
    expect(gateway.calls, isEmpty);
  });

  test('saveBot clears the avatar asset', () async {
    await seed(_row());
    gateway.onCall = (method, params) async => switch (method) {
      'profiles.list' => {'profiles': [_row()]},
      'profiles.configure' => {
        'ok': true,
        'applied': {'ui_meta': true},
      },
      _ => <String, dynamic>{},
    };

    await model.saveBot(
      name: 'sol',
      title: 'Old',
      description: 'old role',
      removeAvatar: true,
    );

    final asset = gateway.callsTo('profiles.set_asset').single;
    expect(asset['clear'], isTrue);
    final meta = gateway.callsTo('profiles.configure').single['ui_meta'][
        'hermes-bots'] as Map;
    expect(meta.containsKey('custom'), isFalse);
  });

  test('renameGroup uses groups.rename for a hosted room', () async {
    await seed(_row());
    gateway.onCall = (method, params) async => switch (method) {
      'profiles.list' => {'profiles': [_row()]},
      'groups.list' => {'rooms': []},
      _ => <String, dynamic>{},
    };

    await model.renameGroup(_hosted(), 'New room');

    final rename = gateway.callsTo('groups.rename').single;
    expect(rename['room_id'], 'r1');
    expect(rename['name'], 'New room');
    expect(rename['event_id'], isNotEmpty);
  });

  test('createGroup posts a room id, name and members', () async {
    await seed(_row());
    gateway.onCall = (method, params) async => switch (method) {
      'profiles.list' => {'profiles': [_row()]},
      'groups.list' => {'rooms': []},
      'groups.create' => {
        'room': {
          'room_id': params['room_id'],
          'name': params['name'],
          'members': params['members'],
        },
      },
      _ => <String, dynamic>{},
    };

    final id = await model.createGroup('  Team  ', ['sol', 'nanox']);

    final create = gateway.callsTo('groups.create').single;
    expect(create['name'], 'Team');
    final roster = create['members'] as List;
    expect(roster.map((m) => (m as Map)['profile']), ['sol', 'nanox']);
    expect((roster.first as Map)['target'], {
      'kind': 'local',
      'profile': 'sol',
    });
    expect(create['room_id'], startsWith('room-'));
    expect(id, create['room_id']);
  });

  test('deleteGroup disbands a hosted room', () async {
    await seed(_row());
    gateway.onCall = (method, params) async => switch (method) {
      'profiles.list' => {'profiles': [_row()]},
      'groups.list' => {'rooms': []},
      _ => <String, dynamic>{},
    };

    await model.deleteGroup(_hosted());

    expect(gateway.callsTo('groups.disband').single['room_id'], 'r1');
  });

  test('renameGroup rewrites a Desktop-mirrored room in the default profile',
      () async {
    final row = _row(extra: const {});
    row['ui_meta']['hermes-bots-groups'] = {
      'version': 3,
      'rooms': {
        'room-a': {'name': 'Old mirror', 'log': [], 'members': []},
      },
    };
    row['ui_meta_revisions'] = {
      'hermes-bots': 4,
      'hermes-bots-groups': 2,
    };
    await seed(row);
    gateway.onCall = (method, params) async => switch (method) {
      'profiles.list' => {'profiles': [row]},
      'profiles.configure' => {
        'ok': true,
        'applied': {'ui_meta': true},
      },
      _ => <String, dynamic>{},
    };

    await model.renameGroup(_mirrored(), 'Renamed mirror');

    final configure = gateway.callsTo('profiles.configure').single;
    expect(configure['name'], 'sol');
    expect(configure['ui_meta_expected_revisions'], {'hermes-bots-groups': 2});
    final mirror = configure['ui_meta']['hermes-bots-groups'] as Map;
    expect(mirror['rooms']['room-a']['name'], 'Renamed mirror');
  });

  test('deleteGroup tombstones a Desktop-mirrored room', () async {
    final row = _row();
    row['ui_meta']['hermes-bots-groups'] = {
      'version': 3,
      'rooms': {
        'room-a': {'name': 'Old mirror', 'log': [], 'members': []},
      },
    };
    row['ui_meta_revisions'] = {
      'hermes-bots': 4,
      'hermes-bots-groups': 2,
    };
    await seed(row);
    gateway.onCall = (method, params) async => switch (method) {
      'profiles.list' => {'profiles': [row]},
      'profiles.configure' => {
        'ok': true,
        'applied': {'ui_meta': true},
      },
      _ => <String, dynamic>{},
    };

    await model.deleteGroup(_mirrored());

    final configure = gateway.callsTo('profiles.configure').single;
    final mirror = configure['ui_meta']['hermes-bots-groups'] as Map;
    expect(mirror['deleted']['room-a'], isTrue);
    expect((mirror['rooms'] as Map).containsKey('room-a'), isFalse);
  });
}
