// Headless widget tests for the sidebar rail — no server, no real display,
// just the widget tree. Exercises the exact wiring the project owner found
// broken by hand earlier (a space behaving like an openable room): here,
// the regression is "tapping a space must call onSelectSpace, not get
// mistaken for one of the plain nav tabs".

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matrix_client/src/rust/api/matrix.dart';
import 'package:matrix_client/widgets/rail_nav.dart';

void _noop() {}

void main() {
  const space = SpaceSummary(
    roomId: '!space:example.org',
    displayName: 'Служебное пространство',
  );

  Widget buildRail({
    RailTab? activeTab = RailTab.home,
    String? activeSpaceId,
    required ValueChanged<RailTab> onSelect,
    required ValueChanged<SpaceSummary> onSelectSpace,
    VoidCallback onLogout = _noop,
  }) {
    return MaterialApp(
      home: Scaffold(
        body: RailNav(
          activeTab: activeTab,
          spaces: [space],
          activeSpaceId: activeSpaceId,
          userId: '@test:example.org',
          displayName: null,
          onSelect: onSelect,
          onSelectSpace: onSelectSpace,
          onLogout: onLogout,
        ),
      ),
    );
  }

  testWidgets('renders a tab for every joined space', (tester) async {
    await tester.pumpWidget(
      buildRail(onSelect: (_) {}, onSelectSpace: (_) {}),
    );

    expect(find.byTooltip(space.displayName), findsOneWidget);
  });

  testWidgets('tapping a space calls onSelectSpace, not onSelect', (
    tester,
  ) async {
    SpaceSummary? selectedSpace;
    RailTab? selectedTab;

    await tester.pumpWidget(
      buildRail(
        onSelect: (tab) => selectedTab = tab,
        onSelectSpace: (s) => selectedSpace = s,
      ),
    );

    await tester.tap(find.byTooltip(space.displayName));
    await tester.pump();

    expect(selectedSpace?.roomId, space.roomId);
    expect(selectedTab, isNull);
  });

  testWidgets('tapping Home calls onSelect(RailTab.home)', (tester) async {
    RailTab? selectedTab;

    await tester.pumpWidget(
      buildRail(
        activeTab: null,
        onSelect: (tab) => selectedTab = tab,
        onSelectSpace: (_) {},
      ),
    );

    await tester.tap(find.byTooltip('Home'));
    await tester.pump();

    expect(selectedTab, RailTab.home);
  });

  testWidgets(
    'tapping the profile avatar opens a popup instead of switching tabs',
    (tester) async {
      RailTab? selectedTab;

      await tester.pumpWidget(
        buildRail(onSelect: (tab) => selectedTab = tab, onSelectSpace: (_) {}),
      );

      await tester.tap(find.byTooltip('User Settings'));
      await tester.pumpAndSettle();

      expect(find.text('Log out'), findsOneWidget);
      expect(find.text('@test:example.org'), findsOneWidget);
      // Still showing whatever room/space was open underneath — this
      // never called onSelect, unlike the old full-screen settings tab.
      expect(selectedTab, isNull);
    },
  );

  testWidgets('tapping Log out in the profile popup calls onLogout', (
    tester,
  ) async {
    var loggedOut = false;

    await tester.pumpWidget(
      buildRail(
        onSelect: (_) {},
        onSelectSpace: (_) {},
        onLogout: () => loggedOut = true,
      ),
    );

    await tester.tap(find.byTooltip('User Settings'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Log out'));
    await tester.pumpAndSettle();

    expect(loggedOut, isTrue);
  });
}
