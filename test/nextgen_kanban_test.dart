import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/nextgen/data/nextgen_kanban.dart';

class _FakeApi implements NgKanbanApi {
  final calls = <({String method, Map<String, dynamic> body})>[];

  Map<String, dynamic> boardJson = {
    'columns': [
      {
        'name': 'todo',
        'tasks': [
          {
            'id': 't1',
            'title': 'One',
            'status': 'todo',
            'assignee': 'sol',
            'priority': 2,
            'comment_count': 3,
            'progress': {'done': 1, 'total': 4},
            'latest_summary': 'in progress',
          },
        ],
      },
      {'name': 'done', 'tasks': []},
    ],
    'assignees': ['sol', 'nanox'],
    'now': 100,
  };

  Map<String, dynamic> detailJson = {
    'task': {'id': 't1', 'title': 'One', 'status': 'todo'},
    'comments': [
      {'author': 'deu', 'body': 'looks good', 'created_at': 5},
    ],
  };

  @override
  Future<Map<String, dynamic>> board() async {
    calls.add((method: 'board', body: <String, dynamic>{}));
    return boardJson;
  }

  @override
  Future<Map<String, dynamic>> task(String id) async {
    calls.add((method: 'task', body: {'id': id}));
    return detailJson;
  }

  @override
  Future<Map<String, dynamic>> createTask(Map<String, dynamic> body) async {
    calls.add((method: 'create', body: body));
    return {
      'task': {'id': 'new', 'title': body['title'], 'status': 'triage'},
    };
  }

  @override
  Future<Map<String, dynamic>> moveTask(
    String id,
    String status, {
    String? summary,
  }) async {
    calls.add((
      method: 'move',
      body: {
        'id': id,
        'status': status,
        if (summary != null) 'summary': summary,
      },
    ));
    return {
      'task': {'id': id, 'title': 'One', 'status': status},
    };
  }

  @override
  Future<Map<String, dynamic>> addComment(String id, String body) async {
    calls.add((method: 'comment', body: {'id': id, 'body': body}));
    return {'ok': true};
  }
}

void main() {
  test('board parses workflow lanes in order and keeps card fields', () {
    final board = NgKanbanBoard.fromJson({
      'columns': [
        {'name': 'done', 'tasks': []},
        {
          'name': 'todo',
          'tasks': [
            {
              'id': 't1',
              'title': 'One',
              'status': 'todo',
              'assignee': 'sol',
              'priority': 2,
              'comment_count': 3,
              'progress': {'done': 1, 'total': 4},
              'latest_summary': 'in progress',
            },
          ],
        },
      ],
      'assignees': ['sol'],
    });

    expect(board.columns.map((c) => c.name), ngKanbanStatuses);
    expect(board.columnCount('todo'), 1);
    expect(board.columnCount('done'), 0);
    final task = board.columns.firstWhere((c) => c.name == 'todo').tasks.single;
    expect(task.title, 'One');
    expect(task.assignee, 'sol');
    expect(task.priority, 2);
    expect(task.commentCount, 3);
    expect(task.progress, '1/4');
    expect(task.latestSummary, 'in progress');
    expect(board.assignees, ['sol']);
  });

  test('manual moves never target worker-owned lanes', () {
    expect(ngKanbanCanMove('todo', 'ready'), isTrue);
    expect(ngKanbanCanMove('triage', 'blocked'), isFalse);
    expect(ngKanbanCanMove('ready', 'running'), isFalse);
    expect(ngKanbanCanMove('blocked', 'review'), isFalse);
    expect(ngKanbanCanMove('review', 'todo'), isTrue);
    expect(ngKanbanCanMove('done', 'done'), isFalse);
    expect(ngKanbanMoveTargets('review'), ['triage', 'todo', 'ready', 'done']);
  });

  test('create, move and comment hit the REST shapes', () async {
    final api = _FakeApi();
    final model = NgKanbanModel(api);
    addTearDown(model.dispose);

    await model.createTask(title: '  Ship it  ', priority: 1, placement: 'triage');
    await model.moveTask('t1', 'ready');
    await model.addComment('t1', 'ping');

    final create = api.calls.firstWhere((c) => c.method == 'create').body;
    expect(create['title'], 'Ship it');
    expect(create['priority'], 1);
    expect(create['triage'], isTrue);
    expect(create.containsKey('body'), isFalse);
    expect(create.containsKey('assignee'), isFalse);
    final move = api.calls.firstWhere((c) => c.method == 'move').body;
    expect(move, {'id': 't1', 'status': 'ready'});
    final comment = api.calls.firstWhere((c) => c.method == 'comment').body;
    expect(comment, {'id': 't1', 'body': 'ping'});
    expect(model.board, isNotNull);
  });

  test('create files the card in the chosen lane', () async {
    final api = _FakeApi();
    final model = NgKanbanModel(api);
    addTearDown(model.dispose);

    await model.createTask(title: 'Later', placement: 'todo');

    final create = api.calls.firstWhere((c) => c.method == 'create').body;
    expect(create['triage'], isFalse);
    final move = api.calls.where((c) => c.method == 'move').single.body;
    expect(move, {'id': 'new', 'status': 'todo'});
  });

  test('a completion note rides on the move to done', () async {
    final api = _FakeApi();
    final model = NgKanbanModel(api);
    addTearDown(model.dispose);

    await model.moveTask('t1', 'done', summary: '  shipped the fix  ');

    final move = api.calls.firstWhere((c) => c.method == 'move').body;
    expect(move, {
      'id': 't1',
      'status': 'done',
      'summary': 'shipped the fix',
    });
  });

  test('blocked detail surfaces the event reason', () {
    final detail = NgKanbanDetail.fromJson({
      'task': {'id': 't1', 'title': 'One', 'status': 'blocked'},
      'comments': const [],
      'events': [
        {
          'kind': 'blocked',
          'payload': {'reason': 'waiting on credentials'},
          'created_at': 9,
        },
      ],
    });
    expect(detail.blockReason, 'waiting on credentials');
  });

  test('detail parses comments', () async {
    final api = _FakeApi();
    final model = NgKanbanModel(api);
    addTearDown(model.dispose);

    final detail = await model.loadDetail('t1');
    expect(detail.task.id, 't1');
    expect(detail.comments.single.author, 'deu');
    expect(detail.comments.single.body, 'looks good');
    expect(detail.comments.single.createdAt, 5);
  });
}
