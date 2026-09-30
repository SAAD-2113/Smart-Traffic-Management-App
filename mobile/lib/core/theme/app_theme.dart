import 'package:flutter/material.dart';

/// Colours with a meaning. Used consistently for status chips, map markers and charts.
class StatusColors {
  static const ok = Color(0xFF2E7D32);
  static const warning = Color(0xFFF9A825);
  static const alert = Color(0xFFEF6C00);
  static const danger = Color(0xFFC62828);
  static const info = Color(0xFF1565C0);
  static const neutral = Color(0xFF78909C);
  static const emergency = Color(0xFFD50000);
  static const simulated = Color(0xFF7E57C2);

  static Color congestion(String level) => switch (level) {
        'LOW' => ok,
        'MODERATE' => warning,
        'HIGH' => alert,
        'SEVERE' => danger,
        _ => neutral,
      };

  static Color light(String state) => switch (state) {
        'GREEN' => const Color(0xFF00C853),
        'YELLOW' => const Color(0xFFFFD600),
        'ALL_RED' => const Color(0xFFD50000),
        _ => neutral,
      };
}

class AppTheme {
  static const _seed = Color(0xFF0D47A1);

  static ThemeData light() => _build(Brightness.light);
  static ThemeData dark() => _build(Brightness.dark);

  static ThemeData _build(Brightness brightness) {
    final scheme = ColorScheme.fromSeed(seedColor: _seed, brightness: brightness);
    return ThemeData(
      colorScheme: scheme,
      useMaterial3: true,
      fontFamily: 'Roboto',
      visualDensity: VisualDensity.standard,
      appBarTheme: AppBarTheme(
        centerTitle: false,
        backgroundColor: scheme.surface,
        foregroundColor: scheme.onSurface,
        elevation: 0,
        scrolledUnderElevation: 1,
      ),
      cardTheme: CardThemeData(
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: BorderSide(color: scheme.outlineVariant),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
        filled: true,
        fillColor: scheme.surfaceContainerLowest,
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          minimumSize: const Size(64, 52),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          minimumSize: const Size(64, 48),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        ),
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
