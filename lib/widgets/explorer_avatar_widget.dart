import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../services/explorer_avatar_service.dart';

/// Procedural RPG Explorer Avatar portrait that visually reflects the user's
/// unique seed (palette, skin tone, hair, cloak) AND evolves its explorer gear
/// (cap -> binoculars -> compass medallion -> tricorn & monocle -> astrolabe
/// halo -> wizard stars -> admiral crown) as Explorer XP/level rises!
class ExplorerAvatarWidget extends StatelessWidget {
  final ExplorerAvatarProfile avatar;
  final double size;
  final bool showLevelBadge;

  const ExplorerAvatarWidget({
    super.key,
    required this.avatar,
    this.size = 56,
    this.showLevelBadge = false,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      height: size,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Container(
            width: size,
            height: size,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(
                color: avatar.accessoryTier >= 5
                    ? const Color(0xFFF59E0B)
                    : avatar.primaryColor.withValues(alpha: 0.65),
                width: avatar.accessoryTier >= 5 ? 2.5 : 1.8,
              ),
              boxShadow: avatar.accessoryTier >= 4
                  ? [
                      BoxShadow(
                        color: avatar.auraColor.withValues(alpha: 0.28),
                        blurRadius: 10,
                        spreadRadius: 1,
                      ),
                    ]
                  : null,
            ),
            child: ClipOval(
              child: CustomPaint(
                size: Size.square(size),
                painter: _ExplorerAvatarPainter(avatar),
              ),
            ),
          ),
          if (showLevelBadge)
            Positioned(
              right: -2,
              bottom: -2,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                decoration: BoxDecoration(
                  color: avatar.primaryColor,
                  borderRadius: BorderRadius.circular(99),
                  border: Border.all(color: Colors.white, width: 1.5),
                ),
                child: Text(
                  'Lv${avatar.accessoryTier}',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 9.5,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _ExplorerAvatarPainter extends CustomPainter {
  final ExplorerAvatarProfile avatar;

  const _ExplorerAvatarPainter(this.avatar);

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    final cx = w * 0.5;
    final cy = h * 0.5;

    // 1. Background radial glow
    final bgPaint = Paint()
      ..shader = RadialGradient(
        colors: [
          avatar.primaryColor.withValues(alpha: 0.22),
          avatar.primaryColor.withValues(alpha: 0.55),
        ],
      ).createShader(Rect.fromLTWH(0, 0, w, h));
    canvas.drawRect(Rect.fromLTWH(0, 0, w, h), bgPaint);

    // Level 5+ Astrolabe / Starburst Halo behind character
    if (avatar.accessoryTier >= 5) {
      final haloPaint = Paint()
        ..color = const Color(0xFFFBBF24).withValues(alpha: 0.45)
        ..style = PaintingStyle.stroke
        ..strokeWidth = w * 0.03;
      canvas.drawCircle(Offset(cx, cy * 0.96), w * 0.41, haloPaint);
      for (var i = 0; i < 8; i++) {
        final angle = i * math.pi / 4;
        final p1 = Offset(
          cx + math.cos(angle) * w * 0.35,
          cy * 0.96 + math.sin(angle) * w * 0.35,
        );
        final p2 = Offset(
          cx + math.cos(angle) * w * 0.46,
          cy * 0.96 + math.sin(angle) * w * 0.46,
        );
        canvas.drawLine(p1, p2, haloPaint);
      }
    }

    // 2. Explorer Cloak / Shoulders
    final cloakPaint = Paint()..color = avatar.cloakColor;
    final cloakPath = Path()
      ..moveTo(w * 0.14, h * 1.05)
      ..quadraticBezierTo(cx, h * 0.62, w * 0.86, h * 1.05)
      ..close();
    canvas.drawPath(cloakPath, cloakPaint);

    // Scarf / collar trim
    final trimPaint = Paint()..color = avatar.secondaryColor;
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromCenter(
          center: Offset(cx, h * 0.74),
          width: w * 0.38,
          height: h * 0.11,
        ),
        Radius.circular(w * 0.06),
      ),
      trimPaint,
    );

    // 3. Head
    final skinPaint = Paint()..color = avatar.skinTone;
    canvas.drawCircle(Offset(cx, h * 0.48), w * 0.23, skinPaint);

    // Rosy cheeks
    final cheekPaint = Paint()
      ..color = const Color(0xFFF43F5E).withValues(alpha: 0.2);
    canvas.drawCircle(Offset(cx - w * 0.12, h * 0.52), w * 0.04, cheekPaint);
    canvas.drawCircle(Offset(cx + w * 0.12, h * 0.52), w * 0.04, cheekPaint);

    // 4. Eyes & Smile
    final eyePaint = Paint()..color = const Color(0xFF1F2937);
    final eyeY = h * 0.46;
    if (avatar.eyeStyle == 2) {
      // Determined adventure eyes
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromCenter(
            center: Offset(cx - w * 0.08, eyeY),
            width: w * 0.065,
            height: w * 0.045,
          ),
          Radius.circular(w * 0.02),
        ),
        eyePaint,
      );
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromCenter(
            center: Offset(cx + w * 0.08, eyeY),
            width: w * 0.065,
            height: w * 0.045,
          ),
          Radius.circular(w * 0.02),
        ),
        eyePaint,
      );
    } else {
      canvas.drawCircle(Offset(cx - w * 0.08, eyeY), w * 0.032, eyePaint);
      canvas.drawCircle(Offset(cx + w * 0.08, eyeY), w * 0.032, eyePaint);
      final glint = Paint()..color = Colors.white;
      canvas.drawCircle(
        Offset(cx - w * 0.09, eyeY - w * 0.01),
        w * 0.011,
        glint,
      );
      canvas.drawCircle(
        Offset(cx + w * 0.07, eyeY - w * 0.01),
        w * 0.011,
        glint,
      );
    }

    // Cheerful smile
    final smilePaint = Paint()
      ..color = const Color(0xFF7C2D12)
      ..style = PaintingStyle.stroke
      ..strokeWidth = w * 0.028
      ..strokeCap = StrokeCap.round;
    final smileRect = Rect.fromCenter(
      center: Offset(cx, h * 0.54),
      width: w * 0.14,
      height: h * 0.08,
    );
    canvas.drawArc(smileRect, 0.2, math.pi - 0.4, false, smilePaint);

    // 5. Hair / Headgear (evolves with RPG level!)
    final hatPaint = Paint()..color = avatar.primaryColor;
    final goldPaint = Paint()..color = const Color(0xFFF59E0B);

    if (avatar.accessoryTier >= 7) {
      // Mythic Explorer Crown
      final crownPath = Path()
        ..moveTo(cx - w * 0.22, h * 0.30)
        ..lineTo(cx - w * 0.18, h * 0.12)
        ..lineTo(cx - w * 0.07, h * 0.22)
        ..lineTo(cx, h * 0.09)
        ..lineTo(cx + w * 0.07, h * 0.22)
        ..lineTo(cx + w * 0.18, h * 0.12)
        ..lineTo(cx + w * 0.22, h * 0.30)
        ..close();
      canvas.drawPath(crownPath, goldPaint);
      canvas.drawCircle(Offset(cx, h * 0.22), w * 0.035, Paint()..color = const Color(0xFF38BDF8));
    } else if (avatar.accessoryTier >= 4) {
      // Vasco da Gama / Cartographer Explorer Hat
      canvas.drawOval(
        Rect.fromCenter(
          center: Offset(cx, h * 0.30),
          width: w * 0.62,
          height: h * 0.14,
        ),
        hatPaint,
      );
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromCenter(
            center: Offset(cx, h * 0.23),
            width: w * 0.36,
            height: h * 0.18,
          ),
          Radius.circular(w * 0.07),
        ),
        hatPaint,
      );
      // Golden hatband
      canvas.drawRect(
        Rect.fromCenter(
          center: Offset(cx, h * 0.28),
          width: w * 0.36,
          height: h * 0.04,
        ),
        goldPaint,
      );
      // Monocle!
      final monocle = Paint()
        ..color = const Color(0xFFFBBF24)
        ..style = PaintingStyle.stroke
        ..strokeWidth = w * 0.025;
      canvas.drawCircle(Offset(cx + w * 0.08, eyeY), w * 0.06, monocle);
    } else {
      // Level 1-3: Scout Cap / Bandana
      final capArc = Rect.fromCenter(
        center: Offset(cx, h * 0.38),
        width: w * 0.48,
        height: h * 0.36,
      );
      canvas.drawArc(capArc, math.pi, math.pi, true, hatPaint);
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(cx - w * 0.04, h * 0.32, w * 0.32, h * 0.06),
          Radius.circular(w * 0.03),
        ),
        Paint()..color = avatar.secondaryColor,
      );
    }

    // Level 2+: Binoculars / Compass Medallion on chest
    if (avatar.accessoryTier >= 2) {
      canvas.drawCircle(Offset(cx, h * 0.85), w * 0.075, goldPaint);
      canvas.drawCircle(
        Offset(cx, h * 0.85),
        w * 0.045,
        Paint()..color = Colors.white,
      );
      canvas.drawCircle(
        Offset(cx, h * 0.85),
        w * 0.02,
        Paint()..color = const Color(0xFFDC2626),
      );
    }
  }

  @override
  bool shouldRepaint(covariant _ExplorerAvatarPainter oldDelegate) =>
      oldDelegate.avatar.seed != avatar.seed ||
      oldDelegate.avatar.accessoryTier != avatar.accessoryTier;
}
