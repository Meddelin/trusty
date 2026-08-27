import 'package:flutter/material.dart';

/// The Telegram mark, drawn as a path for the same reason as [GitHubMark]:
/// no SVG dependency, no bitmap asset. Converted once from the official
/// 24x24 outline, with curves flattened offline.
class TelegramMark extends StatelessWidget {
  const TelegramMark({super.key, this.size = 18, this.color});

  final double size;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    return SizedBox.square(
      dimension: size,
      child: CustomPaint(
        painter: _TelegramMarkPainter(
          color ?? IconTheme.of(context).color ?? const Color(0xFF000000),
        ),
      ),
    );
  }
}

class _TelegramMarkPainter extends CustomPainter {
  const _TelegramMarkPainter(this.color);

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final path = Path()
      ..moveTo(9.78, 18.65)
      ..lineTo(10.06, 14.42)
      ..lineTo(17.74, 7.5)
      ..cubicTo(18.08, 7.19, 17.67, 7.04, 17.22, 7.31)
      ..lineTo(7.74, 13.3)
      ..lineTo(3.64, 12)
      ..cubicTo(2.76, 11.75, 2.75, 11.14, 3.84, 10.7)
      ..lineTo(19.81, 4.54)
      ..cubicTo(20.54, 4.21, 21.24, 4.72, 20.96, 5.84)
      ..lineTo(18.24, 18.65)
      ..cubicTo(18.05, 19.56, 17.5, 19.78, 16.74, 19.36)
      ..lineTo(12.6, 16.3)
      ..lineTo(10.61, 18.23)
      ..cubicTo(10.38, 18.46, 10.19, 18.65, 9.78, 18.65)
      ..close();
    // The source outline is authored on a 24x24 grid.
    canvas.save();
    canvas.scale(size.width / 24, size.height / 24);
    canvas.drawPath(
      path,
      Paint()
        ..color = color
        ..style = PaintingStyle.fill,
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(_TelegramMarkPainter old) => old.color != color;
}
