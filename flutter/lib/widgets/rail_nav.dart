import 'package:flutter/material.dart';
import 'package:matrix_client/src/rust/api/matrix.dart';
import 'package:matrix_client/theme.dart';

// Sidebar rail (design/index.html's <nav class="rail">). Only `home` and
// a selected space have real screens behind them today — matrix-client
// has no DM/explore/inbox/search API yet, and settings/search/feedback
// are still just dialogs in the mockup. Those other tabs are wired (tap,
// active indicator) but route to a placeholder rather than fabricating
// content that isn't backed by real data.
enum RailTab { home, direct, explore, addSpace, feedback, search, inbox }

class RailNav extends StatelessWidget {
  const RailNav({
    super.key,
    required this.activeTab,
    required this.spaces,
    required this.activeSpaceId,
    required this.userId,
    required this.displayName,
    required this.onSelect,
    required this.onSelectSpace,
    required this.onLogout,
  });

  final RailTab? activeTab;
  final List<SpaceSummary> spaces;
  final String? activeSpaceId;
  final String? userId;
  final String? displayName;
  final ValueChanged<RailTab> onSelect;
  final ValueChanged<SpaceSummary> onSelectSpace;
  final VoidCallback onLogout;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 66,
      decoration: const BoxDecoration(
        color: MatrixColors.bgContainer,
        border: Border(
          right: BorderSide(color: MatrixColors.bgContainerLine),
        ),
      ),
      child: Column(
        children: [
          const SizedBox(height: 10),
          Expanded(
            child: SingleChildScrollView(
              child: Column(
                children: [
                  _RailStack(
                    children: [
                      _RailItem(
                        icon: Icons.home_rounded,
                        tooltip: 'Home',
                        active: activeTab == RailTab.home,
                        onTap: () => onSelect(RailTab.home),
                      ),
                      _RailItem(
                        icon: Icons.person_outline,
                        tooltip: 'Direct Messages',
                        active: activeTab == RailTab.direct,
                        onTap: () => onSelect(RailTab.direct),
                      ),
                    ],
                  ),
                  if (spaces.isNotEmpty) ...[
                    const _RailSep(),
                    _RailStack(
                      children: [
                        for (final space in spaces)
                          _RailItem(
                            tooltip: space.displayName,
                            active: activeSpaceId == space.roomId,
                            colorSeed: space.roomId,
                            avatarText: initials(space.displayName),
                            onTap: () => onSelectSpace(space),
                          ),
                      ],
                    ),
                  ],
                  const _RailSep(),
                  _RailStack(
                    children: [
                      _RailItem(
                        icon: Icons.explore_outlined,
                        tooltip: 'Explore Community',
                        active: activeTab == RailTab.explore,
                        onTap: () => onSelect(RailTab.explore),
                      ),
                      _RailItem(
                        icon: Icons.add,
                        tooltip: 'Add Space',
                        active: activeTab == RailTab.addSpace,
                        onTap: () => onSelect(RailTab.addSpace),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          const _RailSep(),
          _RailStack(
            bottomPadded: true,
            children: [
              // TODO(2026-11-18): should open as a floating popup next to
              // this rail item — same `_UserMenuItem` pattern as the
              // profile avatar below — instead of switching the whole
              // content pane via `onSelect`. Matches the mockup, which
              // also treats feedback as an overlay dialog
              // (`design/index.html`'s `feedbackOverlay`), not a lobby
              // pane. Still routed through `onSelect`/`_ComingSoon` for
              // now — no feedback-submission backend to send it to yet.
              _RailItem(
                icon: Icons.star_border_rounded,
                tooltip: 'Leave Feedback',
                active: activeTab == RailTab.feedback,
                onTap: () => onSelect(RailTab.feedback),
              ),
              _RailItem(
                icon: Icons.search,
                tooltip: 'Search',
                active: activeTab == RailTab.search,
                onTap: () => onSelect(RailTab.search),
              ),
              // TODO(2026-11-18): owner wants this as a floating popup
              // too, same as Leave Feedback above — a diff from the
              // mockup, which renders Inbox as a full lobby pane via
              // `buildInbox()`. No invites API on the Rust side yet
              // either way (ROADMAP 0.3.0 "Pending invites"), so still
              // routed through `onSelect`/`_ComingSoon` for now.
              _RailItem(
                icon: Icons.mail_outline,
                tooltip: 'Inbox',
                active: activeTab == RailTab.inbox,
                onTap: () => onSelect(RailTab.inbox),
              ),
              _UserMenuItem(
                userId: userId,
                displayName: displayName,
                onLogout: onLogout,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _RailStack extends StatelessWidget {
  const _RailStack({required this.children, this.bottomPadded = false});

  final List<Widget> children;
  final bool bottomPadded;

  @override
  Widget build(BuildContext context) {
    final spaced = <Widget>[];
    for (final child in children) {
      if (spaced.isNotEmpty) spaced.add(const SizedBox(height: 8));
      spaced.add(child);
    }
    return Padding(
      padding: EdgeInsets.fromLTRB(0, 8, 0, bottomPadded ? 10 : 8),
      child: Column(children: spaced),
    );
  }
}

// The profile avatar's rail entry. Not a `_RailItem` — it doesn't
// navigate to a screen, it opens a small popup right next to itself
// (design/style.css's `.menu-item`/`.menu-item--critical`, the same
// pattern the mockup uses for a room's "..." menu), so logging out
// doesn't cost you whatever room/space you had open. Replaced an
// earlier `RailTab.settings` full-screen panel that did exactly that.
class _UserMenuItem extends StatelessWidget {
  const _UserMenuItem({
    required this.userId,
    required this.displayName,
    required this.onLogout,
  });

  final String? userId;
  final String? displayName;
  final VoidCallback onLogout;

  @override
  Widget build(BuildContext context) {
    final userId = this.userId;
    final name = displayName ?? userId?.replaceFirst('@', '') ?? '?';
    final avatarColor = userId == null
        ? MatrixColors.secondaryContainer
        : colorForMxid(userId);

    return Tooltip(
      message: 'User Settings',
      child: SizedBox(
        width: double.infinity,
        height: 42,
        child: Center(
          child: PopupMenuButton<void>(
            tooltip: '',
            color: MatrixColors.surfaceContainer,
            surfaceTintColor: Colors.transparent,
            elevation: 8,
            offset: const Offset(52, 0),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(10),
              side: const BorderSide(color: MatrixColors.bgContainerLine),
            ),
            constraints: const BoxConstraints(minWidth: 220, maxWidth: 260),
            itemBuilder: (context) => [
              PopupMenuItem<void>(
                enabled: false,
                child: Row(
                  children: [
                    CircleAvatar(
                      radius: 16,
                      backgroundColor: avatarColor,
                      child: Text(
                        initials(name),
                        style: const TextStyle(
                          color: MatrixColors.surfaceContainer,
                          fontWeight: FontWeight.bold,
                          fontSize: 13,
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            name,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: MatrixColors.onContainer,
                              fontWeight: FontWeight.bold,
                              fontSize: 13.5,
                            ),
                          ),
                          if (userId != null)
                            Text(
                              userId,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                color: MatrixColors.onContainerDim,
                                fontSize: 12,
                              ),
                            ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              const PopupMenuDivider(),
              PopupMenuItem<void>(
                onTap: onLogout,
                child: const Row(
                  children: [
                    Icon(
                      Icons.logout,
                      size: 16,
                      color: MatrixColors.criticalMain,
                    ),
                    SizedBox(width: 10),
                    Text(
                      'Log out',
                      style: TextStyle(color: MatrixColors.criticalMain),
                    ),
                  ],
                ),
              ),
            ],
            child: CircleAvatar(
              radius: 21,
              backgroundColor: avatarColor,
              child: Text(
                initials(name),
                style: const TextStyle(
                  color: MatrixColors.surfaceContainer,
                  fontWeight: FontWeight.bold,
                  fontSize: 15,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _RailSep extends StatelessWidget {
  const _RailSep();

  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.symmetric(vertical: 2),
      child: Center(
        child: SizedBox(
          width: 32,
          height: 1,
          child: ColoredBox(color: MatrixColors.bgContainerLine),
        ),
      ),
    );
  }
}

// A rail nav entry. Either an outlined icon (nav tabs with no backing
// screen yet) or a colored initials circle (`colorSeed`/`avatarText` set
// — used for both the real joined spaces and the logged-in user, same
// visual treatment design/style.css gives both via `.rail-avatar[style*=
// "--mx"]`).
class _RailItem extends StatelessWidget {
  const _RailItem({
    this.icon,
    required this.tooltip,
    required this.active,
    required this.onTap,
    this.colorSeed,
    this.avatarText,
  });

  final IconData? icon;
  final String tooltip;
  final bool active;
  final VoidCallback onTap;
  final String? colorSeed;
  final String? avatarText;

  @override
  Widget build(BuildContext context) {
    final Widget avatar;
    if (colorSeed != null) {
      avatar = CircleAvatar(
        radius: 21,
        backgroundColor: colorForMxid(colorSeed!),
        child: Text(
          avatarText ?? '?',
          style: const TextStyle(
            color: MatrixColors.surfaceContainer,
            fontWeight: FontWeight.bold,
            fontSize: 15,
          ),
        ),
      );
    } else {
      avatar = Container(
        width: 42,
        height: 42,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(color: MatrixColors.bgContainerLine),
        ),
        alignment: Alignment.center,
        child: Icon(
          icon,
          size: 20,
          color: active ? MatrixColors.primaryMain : MatrixColors.onContainerDim,
        ),
      );
    }

    return Tooltip(
      message: tooltip,
      child: SizedBox(
        width: double.infinity,
        height: 42,
        child: Stack(
          alignment: Alignment.centerLeft,
          children: [
            if (active)
              Container(
                width: 4,
                height: 24,
                decoration: const BoxDecoration(
                  color: MatrixColors.primaryMain,
                  borderRadius: BorderRadius.horizontal(
                    right: Radius.circular(4),
                  ),
                ),
              ),
            Center(
              child: Material(
                color: Colors.transparent,
                shape: const CircleBorder(),
                child: InkWell(
                  customBorder: const CircleBorder(),
                  onTap: onTap,
                  hoverColor: MatrixColors.bgContainerHover,
                  child: avatar,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
