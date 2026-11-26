// Bots tab of the NextGen sidebar. Group chats live here, matching Hermes
// Desktop; Sessions remains the place for ordinary chats only.
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../data/nextgen_bots.dart';
import '../nextgen_l10n.dart';
import '../theme/nextgen_theme.dart';
import 'avatar.dart';
import 'bot_edit_sheet.dart';
import 'widgets.dart';

class NgBotsPane extends StatefulWidget {
  const NgBotsPane({
    super.key,
    required this.model,
    required this.onOpenBot,
    required this.onOpenGroup,
  });

  final NgBotsModel model;
  final ValueChanged<NgBot> onOpenBot;
  final ValueChanged<NgGroupChat> onOpenGroup;

  @override
  State<NgBotsPane> createState() => _NgBotsPaneState();
}

class _NgBotsPaneState extends State<NgBotsPane> {
  @override
  void initState() {
    super.initState();
    widget.model.startPolling();
  }

  @override
  void dispose() {
    widget.model.stopPolling();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = NgColors.of(context);
    final model = widget.model;
    return AnimatedBuilder(
      animation: model,
      builder: (context, _) {
        if (model.loading && model.bots.isEmpty && model.groups.isEmpty) {
          return const Center(child: CircularProgressIndicator());
        }
        if (model.error != null &&
            model.bots.isEmpty &&
            model.groups.isEmpty) {
          return NgEmpty(
            icon: Icons.cloud_off_outlined,
            title: ngL.ng_couldn_t_load_insights,
            body: model.error,
          );
        }
        final groups = model.filteredGroups;
        final sections = model.botSections;
        final empty = groups.isEmpty && sections.isEmpty;
        return ListView(
          key: const Key('ng-bots-list'),
          padding: const EdgeInsets.only(bottom: 12),
          children: [
            if (empty)
              Padding(
                padding: const EdgeInsets.all(24),
                child: NgEmpty(
                  icon: Icons.smart_toy_outlined,
                  title: ngL.ng_no_bots,
                  body: ngL.ng_search_bots,
                ),
              ),
            if (groups.isNotEmpty) ...[
              _sectionHeader(Icons.groups_outlined, ngL.ng_group_chats, groups.length),
              for (final group in groups)
                _GroupRow(
                  group: group,
                  onTap: () => widget.onOpenGroup(group),
                  onManage: () => _manageGroup(group),
                ),
            ],
            for (final entry in sections.entries) ...[
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 14, 16, 6),
                child: Text(
                  entry.key == 'unassigned' ? ngL.ng_unassigned : entry.key,
                  style: NgType.caption.copyWith(color: c.text3),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              for (final bot in entry.value)
                _BotRow(
                  bot: bot,
                  bytes: model.avatarBytes(bot.name),
                  onTap: () => widget.onOpenBot(bot),
                  onManage: () => _manageBot(bot),
                ),
            ],
          ],
        );
      },
    );
  }

  Future<void> _manageBot(NgBot bot) async {
    await showNgBotEditSheet(
      context,
      model: widget.model,
      bot: bot,
    );
  }

  Future<void> _manageGroup(NgGroupChat group) async {
    final action = await showNgSheet<String>(
      context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.edit_outlined),
              title: Text(ngL.ng_rename),
              onTap: () => Navigator.of(ctx).pop('rename'),
            ),
            ListTile(
              leading: const Icon(Icons.delete_outline),
              title: Text(ngL.ng_delete),
              onTap: () => Navigator.of(ctx).pop('delete'),
            ),
          ],
        ),
      ),
    );
    if (!mounted || action == null) return;
    switch (action) {
      case 'rename':
        final name = await ngPromptText(
          context,
          title: ngL.ng_rename,
          initial: group.name,
          confirm: ngL.ng_save,
        );
        if (name == null || !mounted) return;
        await _run(
          () => widget.model.renameGroup(group, name),
          fail: ngL.ng_couldn_t_rename,
        );
        break;
      case 'delete':
        final ok = await ngConfirm(
          context,
          title: ngL.ng_delete,
          body: ngL.ng_it_is_removed_from_the_gateway,
          confirm: ngL.ng_delete,
        );
        if (!ok || !mounted) return;
        await _run(
          () => widget.model.deleteGroup(group),
          fail: ngL.ng_couldn_t_save,
        );
        break;
      default:
        break;
    }
  }

  Future<void> _run(Future<void> Function() action,
      {required String Function(Object) fail}) async {
    try {
      await action();
    } catch (e) {
      if (mounted) ngToast(context, fail('$e'));
    }
  }

  Widget _sectionHeader(IconData icon, String label, int count) {
    final c = NgColors.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 6),
      child: Row(
        children: [
          Icon(icon, size: 15, color: c.text3),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              label.toUpperCase(),
              style: NgType.caption.copyWith(color: c.text3),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          Text('$count', style: NgType.caption.copyWith(color: c.text3)),
        ],
      ),
    );
  }
}

class _BotRow extends StatelessWidget {
  const _BotRow({
    required this.bot,
    required this.bytes,
    required this.onTap,
    required this.onManage,
  });

  final NgBot bot;
  final Uint8List? bytes;
  final VoidCallback onTap;
  final VoidCallback onManage;

  @override
  Widget build(BuildContext context) {
    final c = NgColors.of(context);
    return ListTile(
      key: Key('ng-bot-${bot.name}'),
      onTap: onTap,
      onLongPress: onManage,
      leading: NgAvatar(name: bot.name, bytes: bytes),
      title: Row(
        children: [
          Expanded(
            child: Text(
              bot.title,
              style: NgType.body.copyWith(color: c.text),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (bot.lastActiveMs > 0)
            Text(
              ngAgo(DateTime.fromMillisecondsSinceEpoch(bot.lastActiveMs)),
              style: NgType.caption.copyWith(color: c.text3),
            ),
        ],
      ),
      subtitle: Text(
        bot.preview.isEmpty ? bot.description : bot.preview,
        style: NgType.caption.copyWith(color: c.text3),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: IconButton(
        key: Key('ng-bot-manage-${bot.name}'),
        tooltip: ngL.edit,
        icon: Icon(Icons.more_vert, size: 20, color: c.text3),
        onPressed: onManage,
      ),
    );
  }
}

class _GroupRow extends StatelessWidget {
  const _GroupRow({
    required this.group,
    required this.onTap,
    required this.onManage,
  });

  final NgGroupChat group;
  final VoidCallback onTap;
  final VoidCallback onManage;

  @override
  Widget build(BuildContext context) {
    final c = NgColors.of(context);
    return ListTile(
      key: Key('ng-group-${group.id}'),
      onTap: onTap,
      onLongPress: onManage,
      leading: NgAvatarStack(names: group.members),
      title: Row(
        children: [
          Expanded(
            child: Text(
              group.name,
              style: NgType.body.copyWith(color: c.text),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (group.lastActiveMs > 0)
            Text(
              ngAgo(DateTime.fromMillisecondsSinceEpoch(group.lastActiveMs)),
              style: NgType.caption.copyWith(color: c.text3),
            ),
        ],
      ),
      subtitle: Text(
        group.preview,
        style: NgType.caption.copyWith(color: c.text3),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: IconButton(
        key: Key('ng-group-manage-${group.id}'),
        tooltip: ngL.ng_rename,
        icon: Icon(Icons.more_vert, size: 20, color: c.text3),
        onPressed: onManage,
      ),
    );
  }
}

/// Read-only room detail until a full group chat composer is wired. Messages
/// and the roster come straight from the Desktop ui_meta mirror.
Future<void> showNgGroupChatSheet(
  BuildContext context, {
  required NgGroupChat group,
  required Map<String, Uint8List?> avatars,
}) =>
    showNgSheet(
      context,
      builder: (context) => SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(context).height * 0.72,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 12),
                child: Row(
                  children: [
                    NgAvatarStack(names: group.members),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        group.name,
                        style: NgType.heading,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ),
              if (group.members.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      '${ngL.ng_members}: ${group.members.join(', ')}',
                      style: NgType.caption.copyWith(
                        color: NgColors.of(context).text3,
                      ),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ),
              Flexible(
                child: ListView.builder(
                  shrinkWrap: true,
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
                  itemCount: group.messages.length,
                  itemBuilder: (context, i) {
                    final m = group.messages[i];
                    return Padding(
                      padding: const EdgeInsets.only(bottom: 10),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          NgAvatar(
                            name: m.isUser ? 'default' : m.author,
                            bytes: avatars[m.author],
                            size: 28,
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  m.isUser ? 'You' : m.author,
                                  style: NgType.caption.copyWith(
                                    color: NgColors.of(context).text3,
                                  ),
                                ),
                                Text(m.text, style: NgType.body),
                              ],
                            ),
                          ),
                        ],
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
