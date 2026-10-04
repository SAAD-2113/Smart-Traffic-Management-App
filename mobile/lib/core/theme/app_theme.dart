import 'package:flutter/material.dart';

/// Brand colours and gradients: deep navy to blue to cyan, used for headers and primary actions.
class Brand {
  static const navy = Color(0xFF0B1B3F);
  static const indigo = Color(0xFF1E3A8A);
  static const blue = Color(0xFF1D4ED8);
  static const cyan = Color(0xFF0891B2);
  static const teal = Color(0xFF0D9488);

  /// Hero headers (dashboard, login, driver home). White text on top.
  static const hero = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [navy, indigo, Color(0xFF0E7490)],
    stops: [0.0, 0.55, 1.0],
  );

  /// Primary call-to-action buttons.
  static const action = LinearGradient(colors: [blue, cyan]);

  /// Navigation rail in the manager layout ("control room").
  static const rail = LinearGradient(
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
    colors: [Color(0xFF0B1B3F), Color(0xFF0A1530)],
  );
}

/// Colours with a meaning: status (good / warning / serious / critical) and states.
/// They are always shown with an icon and a label, never as colour alone.
class StatusColors {
  static const ok = Color(0xFF0CA30C);
  static const warning = Color(0xFFFAB219);
  static const alert = Color(0xFFEC835A);
  static const danger = Color(0xFFD03B3B);
  static const info = Color(0xFF2A78D6);
  static const neutral = Color(0xFF7C8AA0);
  static const emergency = Color(0xFFD50000);
  static const simulated = Color(0xFF7E57C2);

  static Color congestion(String level) => switch (level) {
        'LOW' => ok,
        'MODERATE' => warning,
        'HIGH' => alert,
        'SEVERE' => danger,
        _ => neutral,
      };

  /// Signal lamp colours (real-world semantics). ALL_RED shows red.
  static Color light(String state) => SignalColors.lamp(state);

  /// A darker step of [color] for text on light surfaces (yellow/orange text is unreadable otherwise).
  static Color readable(Color color, Brightness brightness) {
    if (brightness == Brightness.dark) return color;
    final hsl = HSLColor.fromColor(color);
    return hsl.lightness > 0.38 ? hsl.withLightness(0.32).toColor() : color;
  }
}

/// Traffic-light lamps.
class SignalColors {
  static const green = Color(0xFF22C55E);
  static const yellow = Color(0xFFFACC15);
  static const red = Color(0xFFEF4444);
  static const off = Color(0xFF3B4558);

  static Color lamp(String state) => switch (state) {
        'GREEN' => green,
        'YELLOW' || 'FLASHING' => yellow,
        'RED' || 'ALL_RED' => red,
        _ => off,
      };
}

/// Signal-control modes. Each has a colour, an icon and a label (see ModeBadge).
class ModeColors {
  static const fixed = Color(0xFF2A78D6);
  static const adaptive = Color(0xFF7C3AED);
  static const emergency = Color(0xFFD50000);

  static Color of(String mode) => switch (mode) {
        'FIXED_TIME' => fixed,
        'ADAPTIVE' => adaptive,
        'EMERGENCY_PRIORITY' => emergency,
        _ => StatusColors.neutral,
      };

  static LinearGradient gradient(String mode) => switch (mode) {
        'ADAPTIVE' => const LinearGradient(colors: [Color(0xFF5B21B6), Color(0xFF8B5CF6)]),
        'EMERGENCY_PRIORITY' => const LinearGradient(colors: [Color(0xFFB91C1C), Color(0xFFEF4444)]),
        _ => const LinearGradient(colors: [Color(0xFF1D4ED8), Color(0xFF3B82F6)]),
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

  static ThemeData _build(Brightness brightness) {
    final dark = brightness == Brightness.dark;
    final base = ColorScheme.fromSeed(seedColor: Brand.blue, brightness: brightness);
    final scheme = base.copyWith(
      primary: dark ? const Color(0xFF6FA3FF) : Brand.blue,
      secondary: dark ? const Color(0xFF22D3EE) : Brand.cyan,
      surface: dark ? const Color(0xFF0E172B) : Colors.white,
      surfaceContainerLowest: dark ? const Color(0xFF0A1222) : const Color(0xFFF8FAFE),
      surfaceContainerLow: dark ? const Color(0xFF111B31) : const Color(0xFFF3F6FC),
      surfaceContainer: dark ? const Color(0xFF14203A) : const Color(0xFFEEF2FA),
      surfaceContainerHigh: dark ? const Color(0xFF182643) : const Color(0xFFE8EDF7),
      outline: dark ? const Color(0xFF3A4A6B) : const Color(0xFFB8C3D6),
      outlineVariant: dark ? const Color(0xFF223152) : const Color(0xFFE1E7F1),
      onSurfaceVariant: dark ? const Color(0xFFA9B5CC) : const Color(0xFF55627A),
    );
    final background = dark ? const Color(0xFF070D1A) : const Color(0xFFF2F5FB);
    final radius = BorderRadius.circular(18);
    return ThemeData(
      colorScheme: scheme,
      useMaterial3: true,
      fontFamily: 'Roboto',
      visualDensity: VisualDensity.standard,
      scaffoldBackgroundColor: background,
      appBarTheme: AppBarTheme(
        centerTitle: false,
        backgroundColor: background,
        foregroundColor: scheme.onSurface,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0.5,
        titleTextStyle: TextStyle(
          fontFamily: 'Roboto', fontSize: 21, fontWeight: FontWeight.w800, color: scheme.onSurface, letterSpacing: -0.2),
      ),
      cardTheme: CardThemeData(
        elevation: 0,
        margin: EdgeInsets.zero,
        color: scheme.surface,
        surfaceTintColor: Colors.transparent,
        shadowColor: Colors.black.withValues(alpha: dark ? 0.4 : 0.06),
        shape: RoundedRectangleBorder(borderRadius: radius, side: BorderSide(color: scheme.outlineVariant)),
      ),
      inputDecorationTheme: InputDecorationTheme(
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(14)),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14), borderSide: BorderSide(color: scheme.outlineVariant)),
        filled: true,
        fillColor: scheme.surfaceContainerLowest,
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          minimumSize: const Size(64, 52),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
          textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700, letterSpacing: 0.2),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          minimumSize: const Size(64, 48),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
          side: BorderSide(color: scheme.outline),
        ),
      ),
      segmentedButtonTheme: SegmentedButtonThemeData(
        style: SegmentedButton.styleFrom(
          selectedBackgroundColor: scheme.primary.withValues(alpha: dark ? 0.28 : 0.12),
          selectedForegroundColor: dark ? Colors.white : Brand.blue,
        ),
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: dark ? const Color(0xFF0A1222) : Colors.white,
        indicatorColor: scheme.primary.withValues(alpha: dark ? 0.25 : 0.12),
        surfaceTintColor: Colors.transparent,
        elevation: 3,
        labelTextStyle: WidgetStatePropertyAll(
            TextStyle(fontFamily: 'Roboto', fontSize: 12, fontWeight: FontWeight.w600, color: scheme.onSurface)),
      ),
      dividerTheme: DividerThemeData(color: scheme.outlineVariant, space: 1),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: scheme.surface,
        surfaceTintColor: Colors.transparent,
        shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: scheme.surface,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22)),
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      ),
      listTileTheme: const ListTileThemeData(contentPadding: EdgeInsets.symmetric(horizontal: 16)),
    );
  }
}

/// Categorical series colours in a fixed order (validated for colour-vision deficiency on
/// adjacent pairs). A colour follows its entity: intersection n always gets slot n.
class ChartColors {
  static const _light = [
    Color(0xFF2A78D6), Color(0xFFEB6834), Color(0xFF1BAF7A), Color(0xFFEDA100),
    Color(0xFFE87BA4), Color(0xFF008300), Color(0xFF4A3AA7), Color(0xFFE34948),
  ];
  static const _dark = [
    Color(0xFF3987E5), Color(0xFFD95926), Color(0xFF199E70), Color(0xFFC98500),
    Color(0xFFD55181), Color(0xFF008300), Color(0xFF9085E9), Color(0xFFE66767),
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
