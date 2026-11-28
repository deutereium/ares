import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../data/nextgen_kanban.dart';
import '../nextgen_l10n.dart';
import '../theme/nextgen_theme.dart';
import 'nextgen_scope.dart';
import 'widgets.dart';

class _CachedKanban {
  _CachedKanban(this.dashboard, this.model);
  final Object dashboard;
  final NgKanbanModel model;
}

/// Boards are small and the page is reopened often, so keep the last board per
/// gateway. A reopened page paints it before the first refresh lands; polling
/// still stops when the page closes.
final Map<String, _CachedKanban> _kanbanCache = {};

NgKanbanModel cachedNgKanbanModel(NgScope scope) {
  final key = '${scope.connection.id}|${scope.gateway.url.display}';
  final dashboard = scope.gateway.dashboard;
  final hit = _kanbanCache[key];
  if (hit != null && identical(hit.dashboard, dashboard)) return hit.model;
  hit?.model.dispose();
  final model = NgKanbanModel(DashboardKanbanApi(dashboard));
  _kanbanCache[key] = _CachedKanban(dashboard, model);
  return model;
}

/// Kanban board served by the kanban dashboard plugin. Lanes follow the
/// default workflow; cards can move between the columns the plugin accepts.
class NgKanbanPage extends StatefulWidget {
  const NgKanbanPage({super.key, this.model});

  /// Test seam; the page owns its model when none is supplied.
  final NgKanbanModel? model;

  @override
  State<NgKanbanPage> createState() => _NgKanbanPageState();
}

class _NgKanbanPageState extends State<NgKanbanPage> {
  NgKanbanModel? _own;

  NgKanbanModel get _model => widget.model ?? _own!;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (widget.model != null) return;
    _own ??= cachedNgKanbanModel(NgScope.of(context));
    _own!.startPolling();
  }

  @override
  void dispose() {
    // The cache owns the model; only this page's polling stops.
    _own?.stopPolling();
    super.dispose();
  }

  Future<void> _createTask() async {
    final board = _model.board;
    if (board == null) return;
    final created = await showNgSheet<NgKanbanTask>(
      context,
      builder: (_) => _NewTaskSheet(
        model: _model,
        assignees: board.assignees,
        tasks: board.tasks,
      ),
    );
    if (!mounted || created == null) return;
    await _openTask(created);
  }

  Future<void> _openTask(NgKanbanTask task) async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => _NgKanbanTaskPage(model: _model, task: task),
      ),
    );
    unawaited(_model.refresh());
  }

  Future<void> _move(NgKanbanTask task, String status) async {
    var note = '';
    if (status == 'done' && _needsCompletionNote(task)) {
      final entered = await _askCompletionNote(context);
      if (!mounted || entered == null) return;
      note = entered;
    }
    try {
      await _model.moveTask(
        task.id,
        status,
        summary: note.isEmpty ? null : note,
      );
    } catch (e) {
      if (!mounted) return;
      ngToast(context, _readable(e));
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = NgColors.of(context);
    return NgPage(
      title: ngL.ng_kanban,
      actions: [
        IconButton(
          key: const Key('ng-kanban-refresh'),
          icon: const Icon(Icons.refresh),
          onPressed: () => unawaited(_model.refresh()),
        ),
      ],
      floating: FloatingActionButton.extended(
        backgroundColor: c.accent,
        foregroundColor: c.onAccent,
        onPressed: _createTask,
        icon: const Icon(Icons.add),
        label: Text(ngL.ng_new_task),
      ),
      body: AnimatedBuilder(
        animation: _model,
        builder: (context, _) {
          final board = _model.board;
          if (board == null) {
            if (_model.loading) {
              return const Center(child: CircularProgressIndicator());
            }
            return ListView(
              children: [
                NgEmpty(
                  icon: Icons.cloud_off_outlined,
                  title: ngL.ng_couldn_t_load_kanban,
                  body: _model.error,
                  action: FilledButton.icon(
                    onPressed: () => unawaited(_model.refresh()),
                    icon: const Icon(Icons.refresh, size: 18),
                    label: Text(ngL.retry),
                  ),
                ),
              ],
            );
          }
          return ListView.separated(
            key: const Key('ng-kanban-board'),
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.fromLTRB(12, 6, 12, 96),
            itemCount: board.columns.length,
            separatorBuilder: (_, _) => const SizedBox(width: 10),
            itemBuilder: (context, index) {
              final column = board.columns[index];
              return SizedBox(
                width: 262,
                child: _Lane(
                  column: column,
                  onOpen: _openTask,
                  onMove: _move,
                ),
              );
            },
          );
        },
      ),
    );
  }
}

String _statusLabel(String status) => switch (status) {
  'triage' => ngL.ng_kanban_triage,
  'todo' => ngL.ng_kanban_todo,
  'scheduled' => ngL.ng_scheduled,
  'ready' => ngL.ng_ready,
  'running' => ngL.ng_running,
  'blocked' => ngL.ng_kanban_blocked,
  'review' => ngL.ng_kanban_review,
  'done' => ngL.ng_kanban_done,
  _ => status,
};

Color _statusTone(NgColors c, String status) => switch (status) {
  'running' => c.success,
  'ready' => c.accentText,
  'blocked' => c.danger,
  'review' => c.warning,
  'done' => c.text3,
  'triage' => c.warning,
  _ => c.text2,
};

String _readable(Object error) {
  final text = '$error';
  return text.startsWith('Exception: ') ? text.substring(11) : text;
}

/// A card with no stored result cannot complete without a human's note: the
/// gateway refuses an evidence-free completion. Review approval is exempt.
bool _needsCompletionNote(NgKanbanTask task) =>
    task.status != 'review' &&
    (task.result == null || task.result!.trim().isEmpty);

Future<String?> _askCompletionNote(BuildContext context) =>
    showNgSheet<String>(
      context,
      builder: (_) => const _CompletionNoteSheet(),
    );

String _ago(int? since, int now) {
  if (since == null || since <= 0) return '';
  final seconds = (now - since).clamp(0, 1 << 31);
  if (seconds < 60) return '${seconds}s';
  if (seconds < 3600) return '${seconds ~/ 60}m';
  return '${seconds ~/ 3600}h';
}

class _Lane extends StatelessWidget {
  const _Lane({
    required this.column,
    required this.onOpen,
    required this.onMove,
  });

  final NgKanbanColumn column;
  final ValueChanged<NgKanbanTask> onOpen;
  final void Function(NgKanbanTask task, String status) onMove;

  @override
  Widget build(BuildContext context) {
    final c = NgColors.of(context);
    return DragTarget<NgKanbanTask>(
      onWillAcceptWithDetails: (details) =>
          ngKanbanCanMove(details.data.status, column.name),
      onAcceptWithDetails: (details) => onMove(details.data, column.name),
      builder: (context, candidates, _) {
        final hot = candidates.isNotEmpty;
        return Container(
          key: Key('ng-kanban-column-${column.name}'),
          decoration: BoxDecoration(
            color: c.surface,
            borderRadius: BorderRadius.circular(NgRadii.lg),
            border: Border.all(
              color: hot ? c.accent : c.stroke,
              width: hot ? 1.5 : 1,
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 10, 12, 6),
                child: Row(
                  children: [
                    Container(
                      width: 7,
                      height: 7,
                      decoration: BoxDecoration(
                        color: _statusTone(c, column.name),
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        _statusLabel(column.name),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: NgType.label.copyWith(color: c.text),
                      ),
                    ),
                    Text(
                      '${column.tasks.length}',
                      style: NgType.caption.copyWith(color: c.text3),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: column.tasks.isEmpty
                    ? Align(
                        alignment: Alignment.topCenter,
                        child: Padding(
                          padding: const EdgeInsets.only(top: 16),
                          child: Text(
                            ngL.ng_no_tasks,
                            style: NgType.caption.copyWith(color: c.text3),
                          ),
                        ),
                      )
                    : ListView.builder(
                        padding: const EdgeInsets.fromLTRB(8, 2, 8, 10),
                        itemCount: column.tasks.length,
                        itemBuilder: (context, index) {
                          final task = column.tasks[index];
                          return Padding(
                            padding: const EdgeInsets.only(bottom: 8),
                            child: LongPressDraggable<NgKanbanTask>(
                              data: task,
                              feedback: Material(
                                type: MaterialType.transparency,
                                child: SizedBox(
                                  width: 246,
                                  child: _TaskCard(task: task, now: 0),
                                ),
                              ),
                              childWhenDragging: Opacity(
                                opacity: 0.35,
                                child: _TaskCard(task: task, now: 0),
                              ),
                              child: GestureDetector(
                                key: Key('ng-kanban-task-${task.id}'),
                                onTap: () => onOpen(task),
                                child: _TaskCard(
                                  task: task,
                                  now: DateTime.now().millisecondsSinceEpoch,
                                ),
                              ),
                            ),
                          );
                        },
                      ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _TaskCard extends StatelessWidget {
  const _TaskCard({required this.task, required this.now});

  final NgKanbanTask task;
  final int now;

  @override
  Widget build(BuildContext context) {
    final c = NgColors.of(context);
    final running = task.status == 'running' ? _ago(task.currentRunStartedAt, now ~/ 1000) : '';
    return NgCard(
      padding: const EdgeInsets.all(10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            task.title,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: NgType.bodySmall.copyWith(color: c.text),
          ),
          if (task.latestSummary != null) ...[
            const SizedBox(height: 5),
            Text(
              task.latestSummary!,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: NgType.caption.copyWith(color: c.text2),
            ),
          ],
          const SizedBox(height: 8),
          Wrap(
            spacing: 6,
            runSpacing: 4,
            children: [
              if (task.assignee != null) _badge(c, task.assignee!, c.accentText),
              if (task.priority > 0) _badge(c, 'P${task.priority}', c.warning),
              if (running.isNotEmpty) _badge(c, running, c.success),
              if (task.progress != null) _badge(c, task.progress!, c.text2),
              if (task.commentCount > 0)
                _badge(c, '${task.commentCount}', c.text3),
            ],
          ),
        ],
      ),
    );
  }

  Widget _badge(NgColors c, String text, Color tone) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
    decoration: BoxDecoration(
      color: c.surface2,
      borderRadius: BorderRadius.circular(6),
    ),
    child: Text(text, style: NgType.caption.copyWith(color: tone)),
  );
}

class _NgKanbanTaskPage extends StatefulWidget {
  const _NgKanbanTaskPage({required this.model, required this.task});

  final NgKanbanModel model;
  final NgKanbanTask task;

  @override
  State<_NgKanbanTaskPage> createState() => _NgKanbanTaskPageState();
}

class _NgKanbanTaskPageState extends State<_NgKanbanTaskPage> {
  final _comment = TextEditingController();
  NgKanbanDetail? _detail;
  String? _error;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void dispose() {
    _comment.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final detail = await widget.model.loadDetail(widget.task.id);
      if (!mounted) return;
      setState(() {
        _detail = detail;
        _error = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = _readable(e));
    }
  }

  Future<void> _move(String status) async {
    final task = _detail?.task ?? widget.task;
    var note = '';
    if (status == 'done' && _needsCompletionNote(task)) {
      final entered = await _askCompletionNote(context);
      if (!mounted || entered == null) return;
      note = entered;
    }
    setState(() => _busy = true);
    try {
      await widget.model.moveTask(
        widget.task.id,
        status,
        summary: note.isEmpty ? null : note,
      );
      await _load();
      if (!mounted) return;
      ngToast(context, _statusLabel(status));
    } catch (e) {
      if (!mounted) return;
      ngToast(context, _readable(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _sendComment() async {
    final text = _comment.text.trim();
    if (text.isEmpty || _busy) return;
    setState(() => _busy = true);
    try {
      await widget.model.addComment(widget.task.id, text);
      _comment.clear();
      await _load();
    } catch (e) {
      if (!mounted) return;
      ngToast(context, _readable(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = NgColors.of(context);
    final detail = _detail;
    final task = detail?.task ?? widget.task;
    final blockReason = detail?.blockReason;
    final targets = ngKanbanMoveTargets(task.status);
    return NgPage(
      title: task.title.isEmpty ? task.id : task.title,
      actions: [
        if (targets.isNotEmpty)
          PopupMenuButton<String>(
            key: const Key('ng-kanban-move'),
            enabled: !_busy,
            tooltip: ngL.ng_move_to,
            onSelected: _move,
            itemBuilder: (context) => [
              for (final status in targets)
                PopupMenuItem<String>(
                  value: status,
                  child: Text(_statusLabel(status)),
                ),
            ],
          ),
      ],
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 6, 16, 32),
        children: [
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Text(
                _error!,
                style: NgType.caption.copyWith(color: c.danger),
              ),
            ),
          NgCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    _pill(c, _statusLabel(task.status), _statusTone(c, task.status)),
                    const Spacer(),
                    Text(
                      task.id,
                      style: NgType.code.copyWith(color: c.text3),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                Text(
                  task.title,
                  style: NgType.heading.copyWith(color: c.text),
                ),
                if (task.assignee != null || task.priority > 0) ...[
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 4,
                    children: [
                      if (task.assignee != null)
                        Text(
                          '${ngL.ng_assignee}: ${task.assignee}',
                          style: NgType.caption.copyWith(color: c.text2),
                        ),
                      if (task.priority > 0)
                        Text(
                          '${ngL.ng_priority}: P${task.priority}',
                          style: NgType.caption.copyWith(color: c.text2),
                        ),
                    ],
                  ),
                ],
              ],
            ),
          ),
          if (task.status == 'blocked') ...[
            const SizedBox(height: 14),
            NgCard(
              color: c.danger.withValues(alpha: 0.10),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.block, size: 18, color: c.danger),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          task.blockKind == null
                              ? ngL.ng_kanban_blocked
                              : '${ngL.ng_kanban_blocked} · ${task.blockKind}',
                          style: NgType.label.copyWith(color: c.danger),
                        ),
                        if (blockReason != null) ...[
                          const SizedBox(height: 4),
                          SelectableText(
                            blockReason,
                            style: NgType.bodySmall.copyWith(color: c.text),
                          ),
                        ],
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ],
          if (task.body != null) ...[
            const SizedBox(height: 14),
            NgCard(
              child: SelectableText(
                task.body!,
                style: NgType.bodySmall.copyWith(color: c.text),
              ),
            ),
          ],
          if (task.latestSummary != null) ...[
            const SizedBox(height: 14),
            NgSectionLabel(ngL.ng_summary),
            NgCard(
              child: SelectableText(
                task.latestSummary!,
                style: NgType.bodySmall.copyWith(color: c.text2),
              ),
            ),
          ],
          const SizedBox(height: 14),
          NgSectionLabel(ngL.ng_add_comment),
          if (detail == null)
            const Padding(
              padding: EdgeInsets.all(16),
              child: Center(child: CircularProgressIndicator()),
            )
          else
            for (final comment in detail.comments)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: NgCard(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        comment.author,
                        style: NgType.caption.copyWith(color: c.accentText),
                      ),
                      const SizedBox(height: 4),
                      SelectableText(
                        comment.body,
                        style: NgType.bodySmall.copyWith(color: c.text),
                      ),
                    ],
                  ),
                ),
              ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: TextField(
                  key: const Key('ng-kanban-task-comment'),
                  controller: _comment,
                  minLines: 1,
                  maxLines: 4,
                  enabled: !_busy,
                  decoration: InputDecoration(
                    hintText: ngL.ng_add_comment,
                    filled: true,
                    fillColor: c.input,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(NgRadii.md),
                      borderSide: BorderSide.none,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              IconButton.filled(
                key: const Key('ng-kanban-task-send'),
                onPressed: _busy ? null : _sendComment,
                icon: const Icon(Icons.send),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _pill(NgColors c, String text, Color tone) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
    decoration: BoxDecoration(
      color: c.surface2,
      borderRadius: BorderRadius.circular(999),
    ),
    child: Text(text, style: NgType.caption.copyWith(color: tone)),
  );
}

class _NewTaskSheet extends StatefulWidget {
  const _NewTaskSheet({
    required this.model,
    required this.assignees,
    required this.tasks,
  });

  final NgKanbanModel model;
  final List<String> assignees;
  final List<NgKanbanTask> tasks;

  @override
  State<_NewTaskSheet> createState() => _NewTaskSheetState();
}

class _PickedAttachment {
  const _PickedAttachment(this.name, this.bytes);
  final String name;
  final List<int> bytes;
}

class _NewTaskSheetState extends State<_NewTaskSheet> {
  final _title = TextEditingController();
  final _body = TextEditingController();
  String _assignee = '';
  int _priority = 0;
  String _placement = 'todo';
  bool _busy = false;
  final Set<String> _parents = <String>{};
  final Set<String> _children = <String>{};
  final List<_PickedAttachment> _attachments = <_PickedAttachment>[];

  @override
  void dispose() {
    _title.dispose();
    _body.dispose();
    super.dispose();
  }

  String _taskTitle(String id) {
    for (final task in widget.tasks) {
      if (task.id == id) return task.title;
    }
    return id;
  }

  Future<void> _pickTasks({
    required String title,
    required Set<String> selected,
  }) async {
    final picked = await showDialog<Set<String>>(
      context: context,
      builder: (context) {
        final local = Set<String>.of(selected);
        return StatefulBuilder(
          builder: (context, setLocal) {
            final c = NgColors.of(context);
            return AlertDialog(
              backgroundColor: c.surface,
              title: Text(title, style: NgType.title.copyWith(color: c.text)),
              content: SizedBox(
                width: double.maxFinite,
                child: widget.tasks.isEmpty
                    ? Text(
                        'No other tasks yet.',
                        style: NgType.bodySmall.copyWith(color: c.text3),
                      )
                    : SingleChildScrollView(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            for (final task in widget.tasks)
                              CheckboxListTile(
                                value: local.contains(task.id),
                                dense: true,
                                contentPadding: EdgeInsets.zero,
                                controlAffinity:
                                    ListTileControlAffinity.leading,
                                title: Text(
                                  task.title,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: NgType.bodySmall.copyWith(
                                    color: c.text,
                                  ),
                                ),
                                subtitle: Text(
                                  task.status,
                                  style: NgType.caption.copyWith(
                                    color: c.text3,
                                  ),
                                ),
                                onChanged: (value) {
                                  setLocal(() {
                                    if (value == true) {
                                      local.add(task.id);
                                    } else {
                                      local.remove(task.id);
                                    }
                                  });
                                },
                              ),
                          ],
                        ),
                      ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: Text(ngL.ng_cancel),
                ),
                FilledButton(
                  onPressed: () => Navigator.of(context).pop(local),
                  child: Text(ngL.ng_save),
                ),
              ],
            );
          },
        );
      },
    );
    if (picked != null) {
      setState(() => selected
        ..clear()
        ..addAll(picked));
    }
  }

  Future<void> _pickFiles() async {
    try {
      final result = await FilePicker.platform.pickFiles(
        allowMultiple: true,
        withData: true,
      );
      if (result == null || !mounted) return;
      final picked = <_PickedAttachment>[];
      for (final file in result.files) {
        final bytes = file.bytes;
        if (bytes == null || bytes.isEmpty) continue;
        picked.add(_PickedAttachment(file.name, bytes));
      }
      if (picked.isNotEmpty) {
        setState(() => _attachments.addAll(picked));
      }
    } catch (e) {
      if (mounted) ngToast(context, _readable(e));
    }
  }

  Future<void> _create() async {
    final title = _title.text.trim();
    if (title.isEmpty || _busy) return;
    setState(() => _busy = true);
    final failures = <String>[];
    try {
      final task = await widget.model.createTask(
        title: title,
        body: _body.text,
        assignee: _assignee.isEmpty ? null : _assignee,
        priority: _priority,
        placement: _placement,
        parentIds: _parents.toList(growable: false),
      );
      for (final child in _children) {
        if (child == task.id) continue;
        try {
          await widget.model.linkChild(task.id, child);
        } catch (e) {
          failures.add('${_taskTitle(child)}: ${_readable(e)}');
        }
      }
      for (final file in _attachments) {
        try {
          await widget.model.uploadAttachment(
            task.id,
            filename: file.name,
            bytes: file.bytes,
          );
        } catch (e) {
          failures.add('${file.name}: ${_readable(e)}');
        }
      }
      if (!mounted) return;
      if (failures.isNotEmpty) {
        ngToast(
          context,
          'Task created, but some links or files failed: ${failures.first}',
        );
      }
      Navigator.of(context).pop(task);
    } catch (e) {
      if (!mounted) return;
      ngToast(context, _readable(e));
      setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = NgColors.of(context);
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          16,
          4,
          16,
          MediaQuery.viewInsetsOf(context).bottom + 16,
        ),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                ngL.ng_new_task,
                style: NgType.title.copyWith(color: c.text),
              ),
              const SizedBox(height: 14),
              _field(
                c,
                key: const Key('ng-kanban-new-task-title'),
                controller: _title,
                label: ngL.ng_task_title,
                autofocus: true,
              ),
              const SizedBox(height: 10),
              _field(
                c,
                key: const Key('ng-kanban-new-task-body'),
                controller: _body,
                label: ngL.ng_description,
                lines: 3,
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  Text(
                    ngL.ng_assignee,
                    style: NgType.caption.copyWith(color: c.text2),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: DropdownButton<String>(
                      value: _assignee,
                      isExpanded: true,
                      items: [
                        DropdownMenuItem(
                          value: '',
                          child: Text(ngL.ng_unassigned),
                        ),
                        for (final name in widget.assignees)
                          DropdownMenuItem(value: name, child: Text(name)),
                      ],
                      onChanged: _busy
                          ? null
                          : (value) =>
                                setState(() => _assignee = value ?? ''),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  Text(
                    ngL.ng_priority,
                    style: NgType.caption.copyWith(color: c.text2),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: SegmentedButton<int>(
                      segments: const [
                        ButtonSegment(value: 0, label: Text('0')),
                        ButtonSegment(value: 1, label: Text('1')),
                        ButtonSegment(value: 2, label: Text('2')),
                        ButtonSegment(value: 3, label: Text('3')),
                      ],
                      selected: {_priority},
                      onSelectionChanged: _busy
                          ? null
                          : (values) =>
                                setState(() => _priority = values.first),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Text(
                ngL.ng_place_in,
                style: NgType.caption.copyWith(color: c.text2),
              ),
              const SizedBox(height: 6),
              SegmentedButton<String>(
                segments: [
                  ButtonSegment(
                    value: 'triage',
                    label: Text(ngL.ng_kanban_triage),
                  ),
                  ButtonSegment(
                    value: 'todo',
                    label: Text(ngL.ng_kanban_todo),
                  ),
                  ButtonSegment(value: 'ready', label: Text(ngL.ng_ready)),
                ],
                selected: {_placement},
                onSelectionChanged: _busy
                    ? null
                    : (values) => setState(() => _placement = values.first),
              ),
              const SizedBox(height: 10),
              Text(
                'Relationships',
                style: NgType.caption.copyWith(color: c.text2),
              ),
              const SizedBox(height: 6),
              _relationRow(
                c,
                label: 'Parents',
                ids: _parents,
                onPick: () =>
                    _pickTasks(title: 'Parent tasks', selected: _parents),
              ),
              const SizedBox(height: 6),
              _relationRow(
                c,
                label: 'Children',
                ids: _children,
                onPick: () =>
                    _pickTasks(title: 'Child tasks', selected: _children),
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  Text(
                    'Attachments',
                    style: NgType.caption.copyWith(color: c.text2),
                  ),
                  const Spacer(),
                  TextButton.icon(
                    onPressed: _busy ? null : _pickFiles,
                    icon: const Icon(Icons.attach_file, size: 16),
                    label: Text(ngL.ng_attach),
                  ),
                ],
              ),
              if (_attachments.isNotEmpty)
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    for (final file in _attachments)
                      InputChip(
                        label: ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 180),
                          child: Text(
                            file.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        onDeleted: _busy
                            ? null
                            : () => setState(() => _attachments.remove(file)),
                      ),
                  ],
                ),
              const SizedBox(height: 18),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: _busy
                        ? null
                        : () => Navigator.of(context).pop(),
                    child: Text(ngL.ng_cancel),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    key: const Key('ng-kanban-new-task-create'),
                    onPressed: _busy ? null : _create,
                    child: Text(ngL.ng_create),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _relationRow(
    NgColors c, {
    required String label,
    required Set<String> ids,
    required VoidCallback onPick,
  }) {
    return InkWell(
      onTap: _busy ? null : onPick,
      borderRadius: BorderRadius.circular(NgRadii.md),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: c.input,
          borderRadius: BorderRadius.circular(NgRadii.md),
        ),
        child: Row(
          children: [
            Text(label, style: NgType.bodySmall.copyWith(color: c.text2)),
            const SizedBox(width: 8),
            Expanded(
              child: ids.isEmpty
                  ? Text(
                      'None',
                      style: NgType.caption.copyWith(color: c.text3),
                    )
                  : Wrap(
                      spacing: 6,
                      runSpacing: 4,
                      children: [
                        for (final id in ids)
                          Chip(
                            label: ConstrainedBox(
                              constraints: const BoxConstraints(maxWidth: 140),
                              child: Text(
                                _taskTitle(id),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            visualDensity: VisualDensity.compact,
                          ),
                      ],
                    ),
            ),
            Icon(Icons.chevron_right, size: 18, color: c.text3),
          ],
        ),
      ),
    );
  }

  InputDecoration _decoration(NgColors c, String label) => InputDecoration(
    labelText: label,
    filled: true,
    fillColor: c.input,
    border: OutlineInputBorder(
      borderRadius: BorderRadius.circular(NgRadii.md),
      borderSide: BorderSide.none,
    ),
  );

  Widget _field(
    NgColors c, {
    required Key key,
    required TextEditingController controller,
    required String label,
    int lines = 1,
    bool autofocus = false,
  }) => TextField(
    key: key,
    controller: controller,
    minLines: 1,
    maxLines: lines,
    autofocus: autofocus,
    enabled: !_busy,
    decoration: _decoration(c, label),
  );
}

/// The gateway refuses to complete a card that has no stored result unless the
/// person doing it leaves a note, so this sheet supplies that record.
class _CompletionNoteSheet extends StatefulWidget {
  const _CompletionNoteSheet();

  @override
  State<_CompletionNoteSheet> createState() => _CompletionNoteSheetState();
}

class _CompletionNoteSheetState extends State<_CompletionNoteSheet> {
  final _note = TextEditingController();

  @override
  void dispose() {
    _note.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = NgColors.of(context);
    final canSave = _note.text.trim().isNotEmpty;
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          16,
          4,
          16,
          MediaQuery.viewInsetsOf(context).bottom + 16,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              ngL.ng_completion_note,
              style: NgType.title.copyWith(color: c.text),
            ),
            const SizedBox(height: 4),
            Text(
              ngL.ng_completion_note_hint,
              style: NgType.caption.copyWith(color: c.text3),
            ),
            const SizedBox(height: 12),
            TextField(
              key: const Key('ng-kanban-done-note'),
              controller: _note,
              autofocus: true,
              minLines: 2,
              maxLines: 4,
              textCapitalization: TextCapitalization.sentences,
              onChanged: (_) => setState(() {}),
              decoration: InputDecoration(
                filled: true,
                fillColor: c.input,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(NgRadii.md),
                  borderSide: BorderSide.none,
                ),
              ),
            ),
            const SizedBox(height: 12),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: Text(ngL.ng_cancel),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  key: const Key('ng-kanban-done-confirm'),
                  onPressed: canSave
                      ? () => Navigator.of(context).pop(_note.text.trim())
                      : null,
                  child: Text(ngL.ng_kanban_done),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
