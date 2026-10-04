import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/theme/app_theme.dart';
import '../../core/utils/units.dart';
import '../../data/models/control.dart';
import '../../widgets/common.dart';
import 'dashboard_screen.dart';
import 'emergency_admin_screen.dart';
import 'history_screen.dart';
import 'intersection_detail_screen.dart';
import 'intersections_screen.dart';
import 'live_controller.dart';
import 'live_map_screen.dart';
import 'settings_screen.dart';
import 'signals_screen.dart';
import 'traffic_analysis_screen.dart';
import 'vehicles_screen.dart';

class _Section {
  const _Section(this.label, this.icon, this.selectedIcon, this.builder);
  final String label;
  final IconData icon;
  final IconData selectedIcon;
  final WidgetBuilder builder;
}

final _sections = <_Section>[
  _Section('Dashboard', Icons.dashboard_outlined, Icons.dashboard, (_) => const DashboardScreen()),
  _Section('Live map', Icons.map_outlined, Icons.map, (_) => const LiveMapScreen()),
  _Section('Vehicles', Icons.directions_car_outlined, Icons.directions_car, (_) => const VehiclesScreen()),
  _Section('Intersections', Icons.traffic_outlined, Icons.traffic, (_) => const IntersectionsScreen()),
  _Section('Traffic analysis', Icons.analytics_outlined, Icons.analytics, (_) => const TrafficAnalysisScreen()),
  _Section('Emergency', Icons.emergency_outlined, Icons.emergency, (_) => const EmergencyAdminScreen()),
  _Section('Signal control', Icons.settings_input_component_outlined, Icons.settings_input_component,
      (_) => const SignalsScreen()),
  _Section('History', Icons.history_outlined, Icons.history, (_) => const HistoryScreen()),
  _Section('Settings', Icons.settings_outlined, Icons.settings, (_) => const SettingsScreen()),
];

/// Manager dashboard. Wide screens (tablet, web) get a navigation rail with every section;
/// phones get four main tabs plus "More".
class ManagerShell extends StatefulWidget {
  const ManagerShell({super.key});

  @override
  State<ManagerShell> createState() => _ManagerShellState();
}

class _ManagerShellState extends State<ManagerShell> {
  int _index = 0;
  StreamSubscription<LiveEvent>? _events;

  @override
  void initState() {
    super.initState();
    _events = context.read<LiveController>().events.listen(_onEvent);
  }

  @override
  void dispose() {
    _events?.cancel();
    super.dispose();
  }

  void _onEvent(LiveEvent e) {
    if (!mounted) return;
    if (e.type == 'MODE_CHANGED') {
      _onModeChanged(e);
      return;
    }
    final code = e.data['vehicleCode'] ?? '';
    final text = switch (e.type) {
      'EMERGENCY_STARTED' => 'Emergency vehicle $code is active${e.data['isSimulated'] == true ? ' (simulated)' : ''}',
      'EMERGENCY_ENDED' => 'Emergency ended for $code',
      'AUTHORIZATION_REQUESTED' => 'New emergency authorisation request from $code',
      _ => null,
    };
    if (text == null) return;
    final emergencyIndex = _sections.indexWhere((s) => s.label == 'Emergency');
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      backgroundColor: e.type == 'EMERGENCY_STARTED' ? StatusColors.emergency : null,
      behavior: SnackBarBehavior.floating,
      content: Row(children: [
        Icon(e.type == 'EMERGENCY_ENDED' ? Icons.check_circle : Icons.emergency, color: Colors.white),
        const SizedBox(width: 10),
        Expanded(child: Text(text)),
      ]),
      action: SnackBarAction(label: 'View', textColor: Colors.white, onPressed: () => setState(() => _index = emergencyIndex)),
    ));
  }

  /// "I2 now Adaptive: High congestion detected", with a shortcut to the intersection.
  void _onModeChanged(LiveEvent e) {
    final to = e.data['toMode'] as String? ?? '';
    final code = e.data['intersectionCode'] as String? ?? '';
    final id = e.data['intersectionId'] as String?;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      backgroundColor: ModeColors.of(to),
      duration: const Duration(seconds: 6),
      content: Row(children: [
        Icon(ModeColors.icon(to), color: Colors.white),
        const SizedBox(width: 10),
        Expanded(child: Text('$code now ${modeLabel(to).toLowerCase()}: ${e.data['headline'] ?? ''}')),
      ]),
      action: id == null
          ? null
          : SnackBarAction(
              label: 'View',
              textColor: Colors.white,
              onPressed: () => Navigator.push(
                  context, MaterialPageRoute(builder: (_) => IntersectionDetailScreen(intersectionId: id))),
            ),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.sizeOf(context).width >= 900;
    if (wide) {
      const railText = Color(0xFFB9C6E4);
      return Scaffold(
        body: Row(children: [
          DecoratedBox(
            decoration: const BoxDecoration(gradient: Brand.rail),
            child: NavigationRail(
              backgroundColor: Colors.transparent,
              selectedIndex: _index,
              onDestinationSelected: (i) => setState(() => _index = i),
              labelType: NavigationRailLabelType.all,
              indicatorColor: Colors.white.withValues(alpha: 0.14),
              selectedIconTheme: const IconThemeData(color: Colors.white),
              unselectedIconTheme: const IconThemeData(color: railText),
              selectedLabelTextStyle: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700, fontSize: 12),
              unselectedLabelTextStyle: const TextStyle(color: railText, fontSize: 12),
              leading: Padding(
                padding: const EdgeInsets.fromLTRB(8, 16, 8, 12),
                child: Column(children: [
                  Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(gradient: Brand.action, borderRadius: BorderRadius.circular(14)),
                    child: const Icon(Icons.traffic, color: Colors.white, size: 26),
                  ),
                  const SizedBox(height: 6),
                  const Text('Smart Traffic',
                      style: TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.w800)),
                ]),
              ),
              destinations: [
                for (final s in _sections)
                  NavigationRailDestination(
                      icon: Icon(s.icon), selectedIcon: Icon(s.selectedIcon), label: Text(s.label)),
              ],
            ),
          ),
          Expanded(child: _sections[_index].builder(context)),
        ]),
      );
    }
    const tabs = 4;
    final inMore = _index >= tabs;
    return Scaffold(
      body: inMore
          ? _sections[_index].builder(context)
          : IndexedStack(index: _index, children: [for (var i = 0; i < tabs; i++) _sections[i].builder(context)]),
      bottomNavigationBar: NavigationBar(
        selectedIndex: inMore ? tabs : _index,
        onDestinationSelected: (i) {
          if (i < tabs) {
            setState(() => _index = i);
          } else {
            _showMore();
          }
        },
        destinations: [
          for (var i = 0; i < tabs; i++)
            NavigationDestination(
                icon: Icon(_sections[i].icon), selectedIcon: Icon(_sections[i].selectedIcon), label: _sections[i].label),
          NavigationDestination(
            icon: Badge(
              isLabelVisible: context.watch<LiveController>().emergencies.isNotEmpty,
              backgroundColor: StatusColors.emergency,
              child: const Icon(Icons.more_horiz),
            ),
            label: inMore ? _sections[_index].label : 'More',
          ),
        ],
      ),
    );
  }

  void _showMore() {
    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: ListView(shrinkWrap: true, children: [
          for (var i = 4; i < _sections.length; i++)
            ListTile(
              leading: Icon(_sections[i].icon),
              title: Text(_sections[i].label),
              selected: _index == i,
              onTap: () {
                Navigator.pop(sheetContext);
                setState(() => _index = i);
              },
            ),
        ]),
      ),
    );
  }
}

/// Small "Live · 2 s ago" indicator for manager app bars.
class ConnectionIndicator extends StatelessWidget {
  const ConnectionIndicator({super.key});

  @override
  Widget build(BuildContext context) {
    final live = context.watch<LiveController>();
    final (label, color) = switch (live.connection) {
      LiveConnection.live => ('Live', StatusColors.ok),
      LiveConnection.polling => ('Polling', StatusColors.warning),
      LiveConnection.connecting => ('Connecting', StatusColors.neutral),
      LiveConnection.offline => ('Offline', StatusColors.danger),
    };
    return Padding(
      padding: const EdgeInsets.only(right: 12),
      child: Ticker(
        builder: (_) => Tooltip(
          message: 'Last update ${Units.ago(live.lastUpdate)}',
          child: StatusChip(label: label, color: color, icon: Icons.circle),
        ),
      ),
    );
  }
}
