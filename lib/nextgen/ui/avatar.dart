// Bot avatars: server bytes when present, otherwise the same two-dot face
// language Hermes Desktop draws for its generated bot identities.
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../nextgen_l10n.dart';
import '../theme/nextgen_theme.dart';

class NgAvatar extends StatelessWidget {
  const NgAvatar({
    super.key,
    required this.name,
    this.bytes,
    this.size = 36,
  });

  final String name;
  final Uint8List? bytes;
  final double size;

  static const _palette = <Color>[
    Color(0xFF8B5CF6),
    Color(0xFF3B82F6),
    Color(0xFF06B6D4),
    Color(0xFF10B981),
    Color(0xFFF59E0B),
    Color(0xFFEF4444),
    Color(0xFFEC4899),
  ];

  static Color colorFor(String name) {
    var hash = 0;
    for (final unit in utf8.encode(name.isEmpty ? '?' : name)) {
      hash = (hash * 31 + unit) & 0x7fffffff;
    }
    if (name == 'default') return const Color(0xFF8B5CF6);
    return _palette[hash % _palette.length];
  }

  @override
  Widget build(BuildContext context) {
    final c = NgColors.of(context);
    final color = colorFor(name);
    final radius = BorderRadius.circular(size * 0.22);
    return ClipRRect(
      borderRadius: radius,
      child: SizedBox(
        width: size,
        height: size,
        child: bytes == null
            ? Container(
                color: Color.alphaBlend(color.withValues(alpha: 0.28), c.surface),
                alignment: Alignment.center,
                child: CustomPaint(
                  painter: _FacePainter(color: c.text),
                  size: Size(size, size),
                ),
              )
            : Image.memory(bytes!, fit: BoxFit.cover),
      ),
    );
  }
}

class _FacePainter extends CustomPainter {
  const _FacePainter({required this.color});

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = color;
    final r = size.width * 0.075;
    final y = size.height * 0.42;
    canvas.drawCircle(Offset(size.width * 0.36, y), r, paint);
    canvas.drawCircle(Offset(size.width * 0.64, y), r, paint);
    final mouth = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = size.width * 0.055
      ..strokeCap = StrokeCap.round;
    final path = Path()
      ..moveTo(size.width * 0.38, size.height * 0.66)
      ..quadraticBezierTo(
        size.width * 0.5,
        size.height * 0.74,
        size.width * 0.62,
        size.height * 0.66,
      );
    canvas.drawPath(path, mouth);
  }

  @override
  bool shouldRepaint(covariant _FacePainter old) => old.color != color;
}

/// Overlapping avatars for group chats.
class NgAvatarStack extends StatelessWidget {
  const NgAvatarStack({super.key, required this.names, this.size = 30});

  final List<String> names;
  final double size;

  @override
  Widget build(BuildContext context) {
    final shown = names.take(3).toList(growable: false);
    if (shown.isEmpty) {
      return Icon(
        Icons.group_outlined,
        size: size,
        color: NgColors.of(context).text3,
      );
    }
    return SizedBox(
      width: size + (shown.length - 1) * size * 0.55,
      height: size,
      child: Stack(
        children: [
          for (var i = 0; i < shown.length; i++)
            Positioned(
              left: i * size * 0.55,
              child: Container(
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: NgColors.of(context).background,
                ),
                child: NgAvatar(name: shown[i], size: size),
              ),
            ),
        ],
      ),
    );
  }
}

/// Kept public so callers can label avatars consistently with the app locale.
String ngBotAvatarLabel(BuildContext context, String name) =>
    '${ngL.ng_bots}: $name';
