// Bot management: the NextGen version of Desktop's Edit Profile. Title,
// description and avatar go to the same places Desktop writes them — the
// profile's `hermes-bots` ui_meta (compare-and-swap) and its avatar asset.
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../data/nextgen_bots.dart';
import '../nextgen_l10n.dart';
import '../theme/nextgen_theme.dart';
import 'avatar.dart';
import 'widgets.dart';

/// Opens the editor. Resolves true when the bot was saved.
Future<bool?> showNgBotEditSheet(
  BuildContext context, {
  required NgBotsModel model,
  required NgBot bot,
}) => showNgSheet<bool>(
  context,
  builder: (_) => _NgBotEditSheet(model: model, bot: bot),
);

class _NgBotEditSheet extends StatefulWidget {
  const _NgBotEditSheet({required this.model, required this.bot});

  final NgBotsModel model;
  final NgBot bot;

  @override
  State<_NgBotEditSheet> createState() => _NgBotEditSheetState();
}

class _NgBotEditSheetState extends State<_NgBotEditSheet> {
  late final TextEditingController _title;
  late final TextEditingController _description;
  final _picker = ImagePicker();
  Uint8List? _picked;
  bool _removeAvatar = false;
  bool _busy = false;

  NgBot get bot => widget.bot;

  @override
  void initState() {
    super.initState();
    _title = TextEditingController(text: bot.title);
    _description = TextEditingController(text: bot.description);
  }

  @override
  void dispose() {
    _title.dispose();
    _description.dispose();
    super.dispose();
  }

  Uint8List? get _shownAvatar {
    if (_picked != null) return _picked;
    if (_removeAvatar) return null;
    return widget.model.avatarBytes(bot.name);
  }

  Future<void> _pick() async {
    try {
      final file = await _picker.pickImage(
        source: ImageSource.gallery,
        maxWidth: 512,
        maxHeight: 512,
        imageQuality: 85,
      );
      if (file == null) return;
      final bytes = await file.readAsBytes();
      if (!mounted) return;
      setState(() {
        _picked = bytes;
        _removeAvatar = false;
      });
    } catch (_) {
      if (mounted) {
        ngToast(context, ngL.unable_to_prepare_this_image_try_another_one);
      }
    }
  }

  void _remove() {
    setState(() {
      _picked = null;
      _removeAvatar = true;
    });
  }

  Future<void> _save() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final saved = await widget.model.saveBot(
        name: bot.name,
        title: _title.text,
        description: _description.text,
        avatarBytes: _picked,
        removeAvatar: _removeAvatar,
      );
      if (!mounted) return;
      if (!saved) {
        setState(() => _busy = false);
        ngToast(context, ngL.unable_to_prepare_this_image_try_another_one);
        return;
      }
      Navigator.of(context).pop(true);
    } catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      ngToast(context, ngL.ng_couldn_t_save('$e'));
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = NgColors.of(context);
    final hasAvatar = bot.hasAvatar || _picked != null || _removeAvatar;
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(ngL.edit, style: NgType.heading.copyWith(color: c.text)),
            const SizedBox(height: 16),
            Center(
              child: Column(
                children: [
                  InkWell(
                    key: const Key('ng-bot-edit-avatar'),
                    onTap: _busy ? null : _pick,
                    borderRadius: BorderRadius.circular(40),
                    child: Stack(
                      children: [
                        NgAvatar(name: bot.name, bytes: _shownAvatar, size: 76),
                        Positioned(
                          right: 0,
                          bottom: 0,
                          child: Container(
                            padding: const EdgeInsets.all(4),
                            decoration: BoxDecoration(
                              color: c.accent,
                              shape: BoxShape.circle,
                              border: Border.all(color: c.sheet, width: 2),
                            ),
                            child: Icon(
                              Icons.photo_camera_outlined,
                              size: 14,
                              color: c.onAccent,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 8),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      TextButton(
                        key: const Key('ng-bot-edit-choose'),
                        onPressed: _busy ? null : _pick,
                        child: Text(ngL.choose_image),
                      ),
                      if (hasAvatar)
                        TextButton(
                          key: const Key('ng-bot-edit-remove'),
                          onPressed: _busy ? null : _remove,
                          child: Text(ngL.ng_remove),
                        ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(height: 8),
            _field(
              key: const Key('ng-bot-edit-title'),
              controller: _title,
              label: ngL.name,
            ),
            const SizedBox(height: 12),
            _field(
              key: const Key('ng-bot-edit-description'),
              controller: _description,
              label: ngL.ng_description,
              lines: 3,
            ),
            const SizedBox(height: 18),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: _busy
                      ? null
                      : () => Navigator.of(context).maybePop(),
                  child: Text(ngL.ng_cancel),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  key: const Key('ng-bot-edit-save'),
                  onPressed: _busy ? null : _save,
                  child: _busy
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : Text(ngL.ng_save),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _field({
    required Key key,
    required TextEditingController controller,
    required String label,
    int lines = 1,
  }) {
    final c = NgColors.of(context);
    return TextField(
      key: key,
      controller: controller,
      minLines: 1,
      maxLines: lines,
      enabled: !_busy,
      style: NgType.body.copyWith(color: c.text),
      decoration: InputDecoration(
        labelText: label,
        labelStyle: NgType.caption.copyWith(color: c.text3),
        filled: true,
        fillColor: c.input,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(NgRadii.md),
          borderSide: BorderSide.none,
        ),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 14,
          vertical: 12,
        ),
      ),
    );
  }
}
