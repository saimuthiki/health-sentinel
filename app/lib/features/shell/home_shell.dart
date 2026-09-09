import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../core/theme/hp_palette.dart';

/// The five places the app lives, held in a stateful shell so that scrolling
/// away from Today and coming back does not lose your place.
///
/// Five is the most a bottom bar can hold before the labels stop being readable,
/// and each one is a noun a person would use: what to do now, what my results
/// say, what to eat, ask a question, everything else.
class HomeShell extends StatelessWidget {
  const HomeShell({super.key, required this.navigationShell});

  final StatefulNavigationShell navigationShell;

  static const List<_Destination> _destinations = <_Destination>[
    _Destination('Today', Icons.wb_sunny_outlined, Icons.wb_sunny),
    _Destination('Reports', Icons.science_outlined, Icons.science),
    _Destination('Plan', Icons.restaurant_outlined, Icons.restaurant),
    _Destination('Chat', Icons.forum_outlined, Icons.forum),
    _Destination('More', Icons.more_horiz_rounded, Icons.more_horiz),
  ];

  void _goBranch(int index) {
    navigationShell.goBranch(
      index,
      initialLocation: index == navigationShell.currentIndex,
    );
  }

  @override
  Widget build(BuildContext context) {
    final HpPalette p = context.hp;
    return Scaffold(
      body: navigationShell,
      bottomNavigationBar: DecoratedBox(
        decoration: BoxDecoration(
          border: Border(top: BorderSide(color: p.hairline)),
        ),
        child: NavigationBar(
          selectedIndex: navigationShell.currentIndex,
          onDestinationSelected: _goBranch,
          destinations: <Widget>[
            for (final _Destination d in _destinations)
              NavigationDestination(
                icon: Icon(d.icon),
                selectedIcon: Icon(d.selectedIcon),
                label: d.label,
                tooltip: d.label,
              ),
          ],
        ),
      ),
    );
  }
}

class _Destination {
  const _Destination(this.label, this.icon, this.selectedIcon);

  final String label;
  final IconData icon;
  final IconData selectedIcon;
}
