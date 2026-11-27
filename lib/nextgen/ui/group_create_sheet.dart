import 'package:flutter/material.dart';

import '../data/nextgen_bots.dart';
import '../nextgen_l10n.dart';
import '../theme/nextgen_theme.dart';
import 'widgets.dart';

/// Creates a hosted group chat: a name plus two to six bot members.
Future<String?> showNgGroupCreateSheet(
  BuildContext context, {
  required NgBotsModel model,
}) => showNgSheet<String>(
  context,
  builder: (_) => _NgGroupCreateSheet(model: model),
);

class _NgGroupCreateSheet extends StatefulWidget {
  const _NgGroupCreateSheet({required this.model});

  final NgBotsModel model;

  @override
  State<_NgGroupCreateSheet> createState() => _NgGroupCreateSheetState();
}

class _NgGroupCreateSheetState extends State<_NgGroupCreateSheet> {
  final _name = TextEditingController();
  final Set<String> _members = <String>{};
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  bool get _canCreate =>
      !_busy && _members.length >= 2 && _members.length <= 6;

  Future<void> _create() async {
    final name = _name.text.trim();
    if (name.isEmpty || !_canCreate) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final roomId = await widget.model.createGroup(
        name,
        _members.toList(growable: false),
      );
      if (!mounted) return;
      Navigator.of(context).pop(roomId);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = '$e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = NgColors.of(context);
    final bots = widget.model.bots;
    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * 0.72,
        ),
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
                ngL.ng_new_group_chat,
                style: NgType.title.copyWith(color: c.text),
              ),
              const SizedBox(height: 14),
              TextField(
                key: const Key('ng-group-create-name'),
                controller: _name,
                autofocus: true,
                enabled: !_busy,
                textCapitalization: TextCapitalization.sentences,
                decoration: InputDecoration(
                  labelText: ngL.ng_group_name,
                  filled: true,
                  fillColor: c.input,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(NgRadii.md),
                    borderSide: BorderSide.none,
                  ),
                ),
              ),
              const SizedBox(height: 14),
              Text(
                ngL.ng_select_members,
                style: NgType.caption.copyWith(color: c.text2),
              ),
              const SizedBox(height: 2),
              Text(
                ngL.ng_group_member_range,
                style: NgType.caption.copyWith(color: c.text3),
              ),
              const SizedBox(height: 4),
              if (bots.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  child: Text(
                    ngL.ng_no_bots,
                    style: NgType.bodySmall.copyWith(color: c.text3),
                  ),
                )
              else
                Flexible(
                  child: ListView(
                    shrinkWrap: true,
                    children: [
                      for (final bot in bots)
                        CheckboxListTile(
                          key: Key('ng-group-create-member-${bot.name}'),
                          value: _members.contains(bot.name),
                          dense: true,
                          contentPadding: EdgeInsets.zero,
                          title: Text(
                            bot.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          subtitle: Text(
                            bot.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: NgType.caption.copyWith(color: c.text3),
                          ),
                          onChanged: _busy
                              ? null
                              : (checked) => setState(() {
                                  if (checked == true) {
                                    if (_members.length < 6) {
                                      _members.add(bot.name);
                                    }
                                  } else {
                                    _members.remove(bot.name);
                                  }
                                }),
                        ),
                    ],
                  ),
                ),
              if (_error != null) ...[
                const SizedBox(height: 8),
                Text(
                  _error!,
                  style: NgType.caption.copyWith(color: c.danger),
                ),
              ],
              const SizedBox(height: 12),
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
                    key: const Key('ng-group-create-submit'),
                    onPressed: _canCreate ? _create : null,
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
}
