// Full-screen room chat for the Bots tab. Unlike the old detail sheet this
// has a real transcript and composer: hosted rooms post through groups.send,
// mirrored rooms drive member sessions and fold their replies into the room.
import 'dart:async';

import 'package:flutter/material.dart';

import '../data/nextgen_bots.dart';
import '../nextgen_l10n.dart';
import '../theme/nextgen_theme.dart';
import 'avatar.dart';
import '../data/group_chat_controller.dart';

class NgGroupChatPage extends StatefulWidget {
  const NgGroupChatPage({
    super.key,
    required this.controller,
  });

  final NgGroupChatController controller;

  @override
  State<NgGroupChatPage> createState() => _NgGroupChatPageState();
}

class _NgGroupChatPageState extends State<NgGroupChatPage> {
  final _draft = TextEditingController();
  final _scroll = ScrollController();
  bool _boundary = true;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onChanged);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onChanged);
    _draft.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _onChanged() {
    if (!mounted) return;
    setState(() {});
    if (_boundary && _scroll.hasClients) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!_scroll.hasClients) return;
        _scroll.jumpTo(_scroll.position.maxScrollExtent);
      });
    }
  }

  Future<void> _send() async {
    final text = _draft.text.trim();
    if (text.isEmpty || widget.controller.sending) return;
    _draft.clear();
    _boundary = true;
    await widget.controller.send(text);
  }

  @override
  Widget build(BuildContext context) {
    final c = NgColors.of(context);
    final controller = widget.controller;
    final group = controller.group;
    return Scaffold(
      backgroundColor: c.background,
      appBar: AppBar(
        backgroundColor: c.background,
        surfaceTintColor: c.background,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => Navigator.of(context).maybePop(),
        ),
        titleSpacing: 0,
        title: Row(
          children: [
            NgAvatarStack(names: group.memberNames, size: 28),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    group.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: NgType.heading.copyWith(color: c.text),
                  ),
                  Text(
                    '${ngL.ng_members}: ${group.memberNames.join(', ')}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: NgType.caption.copyWith(color: c.text3),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
      body: SafeArea(
        child: Column(
          children: [
            if (controller.error != null)
              Container(
                width: double.infinity,
                margin: const EdgeInsets.fromLTRB(12, 8, 12, 0),
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                decoration: BoxDecoration(
                  color: c.dangerSoft,
                  borderRadius: BorderRadius.circular(NgRadii.md),
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        controller.error!,
                        style: NgType.bodySmall.copyWith(color: c.danger),
                      ),
                    ),
                    TextButton(
                      onPressed: () => unawaited(controller.load()),
                      child: Text(ngL.ng_retry),
                    ),
                  ],
                ),
              ),
            Expanded(
              child: controller.loading && controller.messages.isEmpty
                  ? const Center(child: CircularProgressIndicator())
                  : NotificationListener<ScrollNotification>(
                      onNotification: (n) {
                        if (n is ScrollUpdateNotification) {
                          _boundary =
                              _scroll.position.pixels >=
                              _scroll.position.maxScrollExtent - 48;
                        }
                        return false;
                      },
                      child: ListView.builder(
                        controller: _scroll,
                        padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
                        itemCount: controller.messages.length,
                        itemBuilder: (context, i) =>
                            _message(context, controller.messages[i]),
                      ),
                    ),
            ),
            _composer(c, controller),
          ],
        ),
      ),
    );
  }

  Widget _message(BuildContext context, NgGroupMessage message) {
    final c = NgColors.of(context);
    final mine = message.isUser;
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment:
            mine ? MainAxisAlignment.end : MainAxisAlignment.start,
        children: [
          if (!mine) ...[
            NgAvatar(name: message.author, size: 28),
            const SizedBox(width: 8),
          ],
          ConstrainedBox(
            constraints: BoxConstraints(
              maxWidth: MediaQuery.sizeOf(context).width * 0.74,
            ),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
              decoration: BoxDecoration(
                color: mine ? c.userBubble : c.surface2,
                borderRadius: BorderRadius.circular(NgRadii.md),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (!mine)
                    Text(
                      message.author,
                      style: NgType.caption.copyWith(color: c.text3),
                    ),
                  Text(
                    message.text,
                    style: NgType.body.copyWith(
                      color: mine ? c.onUserBubble : c.text,
                    ),
                  ),
                  if (message.pending || message.failed)
                    Text(
                      message.failed ? ngL.ng_retry : ngL.ng_working,
                      style: NgType.caption.copyWith(
                        color: message.failed ? c.danger : c.text3,
                      ),
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _composer(NgColors c, NgGroupChatController controller) {
    return Container(
      padding: const EdgeInsets.fromLTRB(10, 8, 10, 10),
      decoration: BoxDecoration(
        color: c.surface,
        border: Border(top: BorderSide(color: c.stroke)),
      ),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              key: const Key('ng-group-composer'),
              controller: _draft,
              minLines: 1,
              maxLines: 4,
              enabled: !controller.sending,
              textInputAction: TextInputAction.send,
              onSubmitted: (_) => unawaited(_send()),
              decoration: InputDecoration(
                hintText: ngL.ng_message_hermes,
                hintStyle: NgType.body.copyWith(color: c.textMuted),
                filled: true,
                fillColor: c.input,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(NgRadii.full),
                  borderSide: BorderSide.none,
                ),
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 10,
                ),
              ),
            ),
          ),
          const SizedBox(width: 8),
          IconButton(
            key: const Key('ng-group-send'),
            tooltip: ngL.ng_send,
            icon: controller.sending
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.send),
            onPressed: controller.sending ? null : () => unawaited(_send()),
          ),
        ],
      ),
    );
  }
}
