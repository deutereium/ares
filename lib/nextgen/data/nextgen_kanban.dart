import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../core/services/connection_manager.dart';

/// Columns the kanban plugin serves for the default workflow, in board order.
const List<String> ngKanbanStatuses = <String>[
  'triage',
  'todo',
  'scheduled',
  'ready',
  'running',
  'blocked',
  'review',
  'done',
];

/// Worker-owned columns: a card can leave them, never be dragged into them.
/// `archived` is a filter, not a lane.
const Set<String> ngKanbanLockedTargets = <String>{
  'running',
  'review',
  'scheduled',
  'archived',
};

/// Manual transitions the gateway accepts, mirrored from the plugin's
/// `DEFAULT_WORKFLOW` manual map. It is a client-side hint: the server is the
/// authority and still refuses an invalid move with a readable 409.
const Map<String, Set<String>> ngKanbanManualMoves = <String, Set<String>>{
  'triage': {'todo', 'ready'},
  'todo': {'triage', 'scheduled', 'ready'},
  'scheduled': {'triage', 'todo', 'ready'},
  'ready': {'triage', 'todo', 'scheduled', 'blocked', 'review', 'done'},
  'running': {
    'triage',
    'todo',
    'scheduled',
    'ready',
    'blocked',
    'review',
    'done',
  },
  'blocked': {'triage', 'todo', 'scheduled', 'ready', 'done'},
  'review': {'triage', 'todo', 'ready', 'done'},
  'done': {'triage', 'todo', 'ready'},
  'archived': {'triage', 'todo', 'ready'},
};

bool ngKanbanCanMove(String from, String to) {
  if (from == to) return false;
  if (ngKanbanLockedTargets.contains(to)) return false;
  return ngKanbanManualMoves[from]?.contains(to) ?? false;
}

/// Lanes a card can be moved to by hand, in board order.
List<String> ngKanbanMoveTargets(String from) => ngKanbanStatuses
    .where((status) => ngKanbanCanMove(from, status))
    .toList(growable: false);

int? _int(Object? value) {
  if (value is num) return value.toInt();
  return int.tryParse(value?.toString() ?? '');
}

String? _text(Object? value) {
  final text = value?.toString().trim() ?? '';
  return text.isEmpty ? null : text;
}

Map<String, dynamic> _map(Object? value) =>
    value is Map ? Map<String, dynamic>.from(value) : const <String, dynamic>{};

class NgKanbanTask {
  const NgKanbanTask({
    required this.id,
    required this.title,
    required this.status,
    this.assignee,
    this.tenant,
    this.latestSummary,
    this.body,
    this.priority = 0,
    this.commentCount = 0,
    this.progressDone,
    this.progressTotal,
    this.currentRunStartedAt,
    this.createdAt,
    this.completedAt,
    this.archived = false,
    this.raw = const <String, dynamic>{},
  });

  final String id;
  final String title;
  final String status;
  final String? assignee;
  final String? tenant;
  final String? latestSummary;
  final String? body;
  final int priority;
  final int commentCount;
  final int? progressDone;
  final int? progressTotal;
  final int? currentRunStartedAt;
  final int? createdAt;
  final int? completedAt;
  final bool archived;

  /// The server card, kept so the detail page can show fields this model does
  /// not name yet.
  final Map<String, dynamic> raw;

  String? get progress =>
      progressDone != null && progressTotal != null && progressTotal! > 0
      ? '$progressDone/$progressTotal'
      : null;

  factory NgKanbanTask.fromJson(Map<String, dynamic> json) {
    final progress = _map(json['progress']);
    final done = _int(progress['done']);
    final total = _int(progress['total']);
    return NgKanbanTask(
      id: json['id']?.toString() ?? '',
      title: (json['title']?.toString() ?? '').trim(),
      status: (json['status']?.toString() ?? 'todo').trim(),
      assignee: _text(json['assignee']),
      tenant: _text(json['tenant']),
      latestSummary: _text(json['latest_summary']),
      body: _text(json['body']),
      priority: _int(json['priority']) ?? 0,
      commentCount: _int(json['comment_count']) ?? 0,
      progressDone: total == null || total <= 0 ? null : done,
      progressTotal: total == null || total <= 0 ? null : total,
      currentRunStartedAt: _int(json['current_run_started_at']),
      createdAt: _int(json['created_at']),
      completedAt: _int(json['completed_at']),
      archived: json['archived'] == true ||
          (json['status']?.toString() == 'archived'),
      raw: json,
    );
  }
}

class NgKanbanColumn {
  const NgKanbanColumn({required this.name, required this.tasks});

  final String name;
  final List<NgKanbanTask> tasks;

  factory NgKanbanColumn.fromJson(Map<String, dynamic> json) => NgKanbanColumn(
    name: (json['name']?.toString() ?? 'todo').trim(),
    tasks: (json['tasks'] as List? ?? const <dynamic>[])
        .whereType<Map>()
        .map((row) => NgKanbanTask.fromJson(_map(row)))
        .toList(growable: false),
  );
}

class NgKanbanBoard {
  const NgKanbanBoard({
    required this.columns,
    this.assignees = const <String>[],
    this.tenants = const <String>[],
    this.now = 0,
  });

  final List<NgKanbanColumn> columns;
  final List<String> assignees;
  final List<String> tenants;
  final int now;

  List<NgKanbanTask> get tasks =>
      [for (final column in columns) ...column.tasks];

  int columnCount(String status) => columns
      .where((column) => column.name == status)
      .fold(0, (sum, column) => sum + column.tasks.length);

  factory NgKanbanBoard.fromJson(Map<String, dynamic> json) {
    final parsed = (json['columns'] as List? ?? const <dynamic>[])
        .whereType<Map>()
        .map((row) => NgKanbanColumn.fromJson(_map(row)))
        .toList(growable: false);
    final byName = <String, NgKanbanColumn>{
      for (final column in parsed) column.name: column,
    };
    final columns = <NgKanbanColumn>[
      for (final status in ngKanbanStatuses)
        byName.remove(status) ??
            NgKanbanColumn(name: status, tasks: const <NgKanbanTask>[]),
      for (final column in byName.values) column,
    ];
    return NgKanbanBoard(
      columns: columns,
      assignees: (json['assignees'] as List? ?? const <dynamic>[])
          .map((name) => name.toString())
          .where((name) => name.isNotEmpty)
          .toList(growable: false),
      tenants: (json['tenants'] as List? ?? const <dynamic>[])
          .map((name) => name.toString())
          .where((name) => name.isNotEmpty)
          .toList(growable: false),
      now: _int(json['now']) ?? 0,
    );
  }
}

class NgKanbanComment {
  const NgKanbanComment({
    required this.author,
    required this.body,
    this.createdAt,
  });

  final String author;
  final String body;
  final int? createdAt;

  factory NgKanbanComment.fromJson(Map<String, dynamic> json) =>
      NgKanbanComment(
        author: _text(json['author']) ?? 'dashboard',
        body: json['body']?.toString() ?? '',
        createdAt: _int(json['created_at']),
      );
}

class NgKanbanDetail {
  const NgKanbanDetail({required this.task, required this.comments});

  final NgKanbanTask task;
  final List<NgKanbanComment> comments;

  factory NgKanbanDetail.fromJson(Map<String, dynamic> json) => NgKanbanDetail(
    task: NgKanbanTask.fromJson(_map(json['task'])),
    comments: (json['comments'] as List? ?? const <dynamic>[])
        .whereType<Map>()
        .map((row) => NgKanbanComment.fromJson(_map(row)))
        .toList(growable: false),
  );
}

/// The REST surface the board needs. Production calls go through the dashboard
/// client (cookie auth and profile scoping); tests pass a recording double.
abstract class NgKanbanApi {
  Future<Map<String, dynamic>> board();
  Future<Map<String, dynamic>> task(String id);
  Future<Map<String, dynamic>> createTask(Map<String, dynamic> body);
  Future<Map<String, dynamic>> moveTask(String id, String status);
  Future<Map<String, dynamic>> addComment(String id, String body);
}

class DashboardKanbanApi implements NgKanbanApi {
  DashboardKanbanApi(this._dashboard);

  final DashboardClient _dashboard;

  static const String _base = 'plugins/kanban';

  @override
  Future<Map<String, dynamic>> board() =>
      _dashboard.apiGet('$_base/board');

  @override
  Future<Map<String, dynamic>> task(String id) =>
      _dashboard.apiGet('$_base/tasks/$id');

  @override
  Future<Map<String, dynamic>> createTask(Map<String, dynamic> body) =>
      _dashboard.apiPost('$_base/tasks', body: body);

  @override
  Future<Map<String, dynamic>> moveTask(String id, String status) =>
      _dashboard.apiPatch('$_base/tasks/$id', body: {'status': status});

  @override
  Future<Map<String, dynamic>> addComment(String id, String body) =>
      _dashboard.apiPost(
        '$_base/tasks/$id/comments',
        body: {'body': body, 'author': 'ares'},
      );
}

/// Board state for one kanban board. The page starts and stops polling; the
/// model never notifies synchronously from a widget's initState.
class NgKanbanModel extends ChangeNotifier {
  NgKanbanModel(this.api);

  final NgKanbanApi api;

  NgKanbanBoard? _board;
  bool _loading = false;
  String? _error;
  Timer? _poll;
  bool _disposed = false;

  NgKanbanBoard? get board => _board;
  bool get loading => _loading;
  String? get error => _error;

  void startPolling() {
    if (_poll != null) return;
    unawaited(Future<void>.microtask(refresh));
    _poll = Timer.periodic(const Duration(seconds: 12), (_) {
      unawaited(refresh());
    });
  }

  void stopPolling() {
    _poll?.cancel();
    _poll = null;
  }

  Future<void> refresh() async {
    if (_disposed) return;
    if (_board == null) {
      _loading = true;
      notifyListeners();
    }
    try {
      final json = await api.board();
      if (_disposed) return;
      _board = NgKanbanBoard.fromJson(json);
      _error = null;
    } catch (e) {
      if (_disposed) return;
      _error = '$e';
    } finally {
      if (!_disposed) {
        _loading = false;
        notifyListeners();
      }
    }
  }

  Future<NgKanbanTask> createTask({
    required String title,
    String? body,
    String? assignee,
    int priority = 0,
  }) async {
    final json = await api.createTask({
      'title': title.trim(),
      if (body != null && body.trim().isNotEmpty) 'body': body.trim(),
      if (assignee != null && assignee.isNotEmpty) 'assignee': assignee,
      'priority': priority,
    });
    await refresh();
    return NgKanbanTask.fromJson(_map(json['task']));
  }

  Future<NgKanbanDetail> loadDetail(String id) async {
    final json = await api.task(id);
    return NgKanbanDetail.fromJson(json);
  }

  Future<void> moveTask(String id, String status) async {
    await api.moveTask(id, status);
    await refresh();
  }

  Future<void> addComment(String id, String body) async {
    await api.addComment(id, body);
  }

  @override
  void dispose() {
    _disposed = true;
    stopPolling();
    super.dispose();
  }
}
