import 'package:flutter/cupertino.dart' show CupertinoPageTransitionsBuilder;
import 'package:flutter/material.dart';

/// Brand colours: the three signal colours on white (light) or black (dark), with a warm
/// orange as the extra accent and asphalt black for hero panels. No blue anywhere.
class Brand {
  static const red = Color(0xFFE11D2E);
  static const amber = Color(0xFFF5A300);
  static const green = Color(0xFF16A34A);
  static const greenDeep = Color(0xFF15803D);
  static const orange = Color(0xFFF97316);
  static const asphalt = Color(0xFF0B0B0C);
  static const graphite = Color(0xFF1C1917);

  /// Hero panels (dashboard, login, driver home): asphalt glass with signal glows. White text.
  static const hero = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [Color(0xFF050505), Color(0xFF1C1917), Color(0xFF2A211C)],
    stops: [0.0, 0.6, 1.0],
  );

  /// Primary call-to-action buttons: signal green, dark enough for white text.
  static const action = LinearGradient(colors: [Color(0xFF166534), Color(0xFF16A34A)]);

  /// Navigation rail in the manager layout ("control room").
  static const rail = LinearGradient(
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
    colors: [Color(0xFF0B0B0C), Color(0xFF17130F)],
  );

  /// The three lamps, for decorations (glows, stripes).
  static const signals = [red, amber, green];
}

/// Glass surfaces: translucent fill, hairline border, background blur.
class Glass {
  static const blurSigma = 18.0;

  static Color fill(Brightness b) =>
      b == Brightness.dark ? Colors.white.withValues(alpha: 0.065) : Colors.white.withValues(alpha: 0.6);

  static Color border(Brightness b) =>
      b == Brightness.dark ? Colors.white.withValues(alpha: 0.12) : Colors.black.withValues(alpha: 0.075);

  /// Bars (app bar, navigation bar): a little more opaque than cards.
  static Color bar(Brightness b) =>
      b == Brightness.dark ? Colors.black.withValues(alpha: 0.55) : Colors.white.withValues(alpha: 0.72);

  /// Dialogs and sheets sit over content, so they are nearly opaque for legibility.
  static Color sheet(Brightness b) =>
      b == Brightness.dark ? const Color(0xF2121212) : const Color(0xF5FFFFFF);

  static Color background(Brightness b) => b == Brightness.dark ? Colors.black : Colors.white;
}

/// Colours with a meaning: status (good / warning / serious / critical) and states.
/// They are always shown with an icon and a label, never as colour alone.
class StatusColors {
  static const ok = Color(0xFF16A34A);
  static const warning = Color(0xFFF5A300);
  static const alert = Color(0xFFF97316);
  static const danger = Color(0xFFDC2626);

  /// Informational (neither good nor bad): graphite.
  static const info = Color(0xFF6B635C);
  static const neutral = Color(0xFF8C857F);
  static const emergency = Color(0xFFD50000);

  /// Simulated data (demo fleet, simulator): pink, never used for real data.
  static const simulated = Color(0xFFDB2777);

  static Color congestion(String level) => switch (level) {
        'LOW' => ok,
        'MODERATE' => warning,
        'HIGH' => alert,
        'SEVERE' => danger,
        _ => neutral,
      };

  /// Signal lamp colours (real-world semantics). ALL_RED shows red.
  static Color light(String state) => SignalColors.lamp(state);

  /// A readable step of [color] for text: darker on white, lighter on black
  /// (yellow/orange text is unreadable on white otherwise, graphite on black).
  static Color readable(Color color, Brightness brightness) {
    final hsl = HSLColor.fromColor(color);
    if (brightness == Brightness.dark) return hsl.lightness < 0.55 ? hsl.withLightness(0.7).toColor() : color;
    return hsl.lightness > 0.38 ? hsl.withLightness(0.32).toColor() : color;
  }
}

/// Traffic-light lamps.
class SignalColors {
  static const green = Color(0xFF22C55E);
  static const yellow = Color(0xFFFACC15);
  static const red = Color(0xFFEF4444);
  static const off = Color(0xFF3A3633);

  static Color lamp(String state) => switch (state) {
        'GREEN' => green,
        'YELLOW' || 'FLASHING' => yellow,
        'RED' || 'ALL_RED' => red,
        _ => off,
      };
}

/// Signal-control modes. Each has a colour, an icon and a label (see ModeBadge).
class ModeColors {
  /// Fixed-time: graphite (calm default); adaptive: signal green; emergency: red.
  static const fixed = Color(0xFF57534E);
  static const adaptive = Color(0xFF16A34A);
  static const emergency = Color(0xFFD50000);

  static Color of(String mode) => switch (mode) {
        'FIXED_TIME' => fixed,
        'ADAPTIVE' => adaptive,
        'EMERGENCY_PRIORITY' => emergency,
        _ => StatusColors.neutral,
      };

  static LinearGradient gradient(String mode) => switch (mode) {
        'ADAPTIVE' => const LinearGradient(colors: [Color(0xFF14532D), Color(0xFF16A34A)]),
        'EMERGENCY_PRIORITY' => const LinearGradient(colors: [Color(0xFFB91C1C), Color(0xFFEF4444)]),
        _ => const LinearGradient(colors: [Color(0xFF1C1917), Color(0xFF57534E)]),
      };

  static IconData icon(String mode) => switch (mode) {
        'FIXED_TIME' => Icons.schedule,
        'ADAPTIVE' => Icons.auto_mode,
        'EMERGENCY_PRIORITY' => Icons.emergency,
        _ => Icons.help_outline,
      };
}

class AppTheme {
  static ThemeData light() => _build(Brightness.light);
  static ThemeData dark() => _build(Brightness.dark);

  static ColorScheme _scheme(Brightness brightness) {
    final dark = brightness == Brightness.dark;
    // Every role is set here, so no generated (blue-ish) tone can leak in from a seed.
    return ColorScheme(
      brightness: brightness,
      primary: dark ? const Color(0xFF4ADE80) : Brand.greenDeep,
      onPrimary: dark ? const Color(0xFF052E16) : Colors.white,
      primaryContainer: dark ? const Color(0xFF14532D) : const Color(0xFFDCFCE7),
      onPrimaryContainer: dark ? const Color(0xFFBBF7D0) : const Color(0xFF14532D),
      secondary: dark ? const Color(0xFFFBBF24) : const Color(0xFFB45309),
      onSecondary: dark ? const Color(0xFF1F1500) : Colors.white,
      secondaryContainer: dark ? const Color(0xFF78350F) : const Color(0xFFFEF3C7),
      onSecondaryContainer: dark ? const Color(0xFFFDE68A) : const Color(0xFF78350F),
      tertiary: dark ? const Color(0xFFFB923C) : const Color(0xFFC2410C),
      onTertiary: dark ? const Color(0xFF2A1100) : Colors.white,
      tertiaryContainer: dark ? const Color(0xFF7C2D12) : const Color(0xFFFFEDD5),
      onTertiaryContainer: dark ? const Color(0xFFFED7AA) : const Color(0xFF7C2D12),
      error: dark ? const Color(0xFFF87171) : const Color(0xFFDC2626),
      onError: dark ? const Color(0xFF2B0000) : Colors.white,
      errorContainer: dark ? const Color(0xFF7F1D1D) : const Color(0xFFFEE2E2),
      onErrorContainer: dark ? const Color(0xFFFECACA) : const Color(0xFF7F1D1D),
      surface: dark ? const Color(0xFF121212) : Colors.white,
      onSurface: dark ? const Color(0xFFF5F5F4) : const Color(0xFF0C0A09),
      onSurfaceVariant: dark ? const Color(0xFFA8A29E) : const Color(0xFF57534E),
      surfaceContainerLowest: dark ? const Color(0xFF050505) : Colors.white,
      surfaceContainerLow: dark ? const Color(0xFF0E0D0C) : const Color(0xFFFAFAF9),
      surfaceContainer: dark ? const Color(0xFF161514) : const Color(0xFFF5F5F4),
      surfaceContainerHigh: dark ? const Color(0xFF1E1C1A) : const Color(0xFFEFEDEB),
      surfaceContainerHighest: dark ? const Color(0xFF292524) : const Color(0xFFE7E5E4),
      outline: dark ? const Color(0xFF57534E) : const Color(0xFFC9C5C1),
      outlineVariant: dark ? const Color(0xFF292524) : const Color(0xFFE7E5E4),
      shadow: Colors.black,
      scrim: Colors.black,
      inverseSurface: dark ? const Color(0xFFF5F5F4) : const Color(0xFF1C1917),
      onInverseSurface: dark ? const Color(0xFF1C1917) : const Color(0xFFF5F5F4),
      inversePrimary: dark ? Brand.greenDeep : const Color(0xFF4ADE80),
      surfaceTint: Colors.transparent,
    );
  }

  static ThemeData _build(Brightness brightness) {
    final dark = brightness == Brightness.dark;
    final scheme = _scheme(brightness);
    final radius = BorderRadius.circular(20);
    final glassBorder = BorderSide(color: Glass.border(brightness));
    return ThemeData(
      colorScheme: scheme,
      useMaterial3: true,
      fontFamily: 'Roboto',
      visualDensity: VisualDensity.standard,
      // Screens are transparent: the glass backdrop (GlassBackdrop) shows through.
      scaffoldBackgroundColor: Colors.transparent,
      canvasColor: Glass.background(brightness),
      // Fade-forward transitions: the outgoing page fades out, so two translucent pages
      // never stack up visibly during a transition.
      pageTransitionsTheme: const PageTransitionsTheme(builders: {
        TargetPlatform.android: FadeForwardsPageTransitionsBuilder(backgroundColor: Colors.transparent),
        TargetPlatform.iOS: CupertinoPageTransitionsBuilder(),
        TargetPlatform.linux: FadeForwardsPageTransitionsBuilder(backgroundColor: Colors.transparent),
        TargetPlatform.windows: FadeForwardsPageTransitionsBuilder(backgroundColor: Colors.transparent),
        TargetPlatform.macOS: CupertinoPageTransitionsBuilder(),
      }),
      appBarTheme: AppBarTheme(
        centerTitle: false,
        backgroundColor: Glass.bar(brightness),
        foregroundColor: scheme.onSurface,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        shape: Border(bottom: glassBorder),
        titleTextStyle: TextStyle(
            fontFamily: 'Roboto', fontSize: 21, fontWeight: FontWeight.w800, color: scheme.onSurface, letterSpacing: -0.2),
      ),
      cardTheme: CardThemeData(
        elevation: 0,
        margin: EdgeInsets.zero,
        color: Glass.fill(brightness),
        surfaceTintColor: Colors.transparent,
        shadowColor: Colors.transparent,
        shape: RoundedRectangleBorder(borderRadius: radius, side: glassBorder),
      ),
      inputDecorationTheme: InputDecorationTheme(
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(14)),
        enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: glassBorder),
        focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(14), borderSide: BorderSide(color: scheme.primary, width: 1.6)),
        filled: true,
        fillColor: dark ? Colors.white.withValues(alpha: 0.05) : Colors.white.withValues(alpha: 0.7),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          minimumSize: const Size(64, 52),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700, letterSpacing: 0.2),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          minimumSize: const Size(64, 48),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          side: BorderSide(color: scheme.outline),
          backgroundColor: Glass.fill(brightness),
        ),
      ),
      segmentedButtonTheme: SegmentedButtonThemeData(
        style: SegmentedButton.styleFrom(
          backgroundColor: Glass.fill(brightness),
          selectedBackgroundColor: scheme.primary.withValues(alpha: dark ? 0.26 : 0.14),
          selectedForegroundColor: dark ? Colors.white : Brand.greenDeep,
          side: glassBorder,
        ),
      ),
      chipTheme: ChipThemeData(
        backgroundColor: Glass.fill(brightness),
        side: glassBorder,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: Glass.bar(brightness),
        indicatorColor: scheme.primary.withValues(alpha: dark ? 0.24 : 0.14),
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        labelTextStyle: WidgetStatePropertyAll(
            TextStyle(fontFamily: 'Roboto', fontSize: 12, fontWeight: FontWeight.w600, color: scheme.onSurface)),
      ),
      navigationRailTheme: NavigationRailThemeData(
        backgroundColor: Glass.bar(brightness),
        indicatorColor: scheme.primary.withValues(alpha: dark ? 0.24 : 0.14),
      ),
      dividerTheme: DividerThemeData(color: Glass.border(brightness), space: 1),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: Glass.sheet(brightness),
        modalBackgroundColor: Glass.sheet(brightness),
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
            borderRadius: const BorderRadius.vertical(top: Radius.circular(26)), side: glassBorder),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: Glass.sheet(brightness),
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24), side: glassBorder),
      ),
      popupMenuTheme: PopupMenuThemeData(
        color: Glass.sheet(brightness),
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16), side: glassBorder),
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        backgroundColor: dark ? const Color(0xF0262626) : const Color(0xF01C1917),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      ),
      progressIndicatorTheme: ProgressIndicatorThemeData(color: scheme.primary),
      listTileTheme: const ListTileThemeData(contentPadding: EdgeInsets.symmetric(horizontal: 16)),
    );
  }
}

/// Categorical series colours in a fixed order, without blue: orange, magenta, brown, olive,
/// pink, gold. Checked for colour-vision deficiency on adjacent pairs (dataviz validator, light
/// on white and dark on #141414). A colour follows its entity: intersection n always gets slot n.
class ChartColors {
  static const _light = [
    Color(0xFFE8590C), Color(0xFFB5179E), Color(0xFF8B4513), Color(0xFF5C940D), Color(0xFFE64980), Color(0xFFA37500),
  ];
  static const _dark = [
    Color(0xFFE16C10), Color(0xFFCA66C3), Color(0xFFA26425), Color(0xFF7CA215), Color(0xFFE5598E), Color(0xFFB88A01),
  ];

  static Color series(BuildContext context, int slot) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final list = dark ? _dark : _light;
    return list[slot % list.length];
  }

  /// Single-measure charts use slot 1 only.
  static Color primary(BuildContext context) => series(context, 0);

  static Color grid(BuildContext context) => Theme.of(context).colorScheme.outlineVariant.withValues(alpha: 0.5);
}
