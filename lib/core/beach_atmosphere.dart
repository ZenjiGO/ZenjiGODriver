import 'package:flutter/material.dart';
import 'theme.dart';

/// Global background layer: a calm, cool gradient with a faint brand glow at the top.
/// (The old beach photo and decorative circles were removed: they made content harder to read.)
class BeachAtmosphere extends StatelessWidget {
  final Widget child;
  // Kept so existing call sites keep compiling; the photo layer is no longer drawn.
  final bool showImage;
  final double imageOpacity;

  const BeachAtmosphere({
    super.key,
    required this.child,
    this.showImage = false,
    this.imageOpacity = 0,
  });

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Stack(
      fit: StackFit.expand,
      children: [
        DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: dark
                  ? const [Color(0xFF0A2533), Color(0xFF071E2B), Color(0xFF061923)]
                  : const [Color(0xFFF4F8FA), Color(0xFFF8FAFB), Color(0xFFFFFFFF)],
            ),
          ),
        ),
        Positioned(
          top: -140,
          left: 0,
          right: 0,
          child: IgnorePointer(
            child: Container(
              height: 300,
              decoration: BoxDecoration(
                gradient: RadialGradient(
                  radius: 0.9,
                  colors: [
                    (dark ? ZenjiColors.darkAccent : ZenjiColors.green).withValues(alpha: dark ? .16 : .10),
                    Colors.transparent,
                  ],
                ),
              ),
            ),
          ),
        ),
        child,
      ],
    );
  }
}
