import 'dart:async';

import 'package:flutter/material.dart';
import 'package:matrix_client/active_room_controller.dart';
import 'package:matrix_client/src/rust/api/matrix.dart';
import 'package:matrix_client/theme.dart';
import 'package:matrix_client/widgets/member_drawer.dart';
import 'package:matrix_client/widgets/rail_nav.dart';
import 'package:matrix_client/widgets/room_list.dart';
import 'package:matrix_client/widgets/room_view.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key, required this.client, required this.onLogout});

  final MatrixClient client;
  final VoidCallback onLogout;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final _messageController = TextEditingController();

  // Everything about the open room — its timeline, live message
  // subscription, members, and the busy/error state of opening it —
  // lives in this controller, not in these fields. See its doc comment:
  // the screen used to own all of it directly, and that is what let the
  // room-switch race exist.
  late final ActiveRoomController _activeRoom;

  // The screen's *own* loading/error state: the room/space/DM list
  // fetches and the initial sync. The open-room concern has its own
  // (`_activeRoom.busy`/`.error`); `build` shows the two combined.
  String? _error;
  bool _busy = false;

  List<RoomSummary> _rooms = [];

  RailTab? _activeTab = RailTab.home;
  String? _userId;
  String? _displayName;

  List<SpaceSummary> _spaces = [];
  SpaceSummary? _activeSpace;
  List<RoomSummary> _spaceRooms = [];
  StreamSubscription<List<RoomSummary>>? _roomsSubscription;
  StreamSubscription<List<SpaceSummary>>? _spacesSubscription;

  List<RoomSummary> _directRooms = [];
  StreamSubscription<List<RoomSummary>>? _directRoomsSubscription;

  @override
  void initState() {
    super.initState();
    _activeRoom = ActiveRoomController(client: widget.client)
      ..addListener(_onActiveRoomChanged);
    _startSync();
    _loadSession();
    // Real push updates for both lists (matrix_sdk::Client::rooms_stream
    // / SpaceService::subscribe_to_top_level_joined_spaces, re-flattened
    // to plain snapshots) — no fixed post-sync delay needed, the first
    // emission just arrives whenever the store actually has data.
    _roomsSubscription = roomsStream(client: widget.client).listen(
      (roomList) {
        if (mounted) setState(() => _rooms = roomList);
      },
      onError: (e) {
        if (mounted) setState(() => _error = e.toString());
      },
    );
    _spacesSubscription = spacesStream(client: widget.client).listen(
      (spaceList) {
        if (mounted) setState(() => _spaces = spaceList);
      },
      onError: (e) {
        if (mounted) setState(() => _error = e.toString());
      },
    );
    _directRoomsSubscription = directRoomsStream(client: widget.client).listen(
      (roomList) {
        if (mounted) setState(() => _directRooms = roomList);
      },
      onError: (e) {
        if (mounted) setState(() => _error = e.toString());
      },
    );
  }

  Future<void> _loadSession() async {
    final session = await clientSession(client: widget.client);
    if (mounted) setState(() => _userId = session?.userId);
    try {
      final name = await accountDisplayName(client: widget.client);
      if (mounted) setState(() => _displayName = name);
    } catch (_) {
      // Not critical — the settings panel just falls back to the user
      // ID if this fails, same as every other display-name fallback in
      // the app.
    }
  }

  // The controller is the single source of truth for the open room, so
  // any change in it is a repaint for this screen.
  void _onActiveRoomChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    // Invalidates anything the controller still has in flight and tears
    // down the timeline/subscription it owns.
    _activeRoom.removeListener(_onActiveRoomChanged);
    _activeRoom.dispose();
    _roomsSubscription?.cancel();
    _spacesSubscription?.cancel();
    _directRoomsSubscription?.cancel();
    _messageController.dispose();
    super.dispose();
  }

  Future<void> _startSync() async {
    setState(() => _busy = true);
    try {
      await startSync(client: widget.client);
    } catch (e) {
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  // Manual-refresh button on the Home room list — a one-shot re-fetch on
  // top of the live `_roomsSubscription`, kept mainly as a user-visible
  // "nudge it" affordance; the list updates on its own regardless.
  Future<void> _refreshRooms() async {
    try {
      final roomList = await rooms(client: widget.client);
      setState(() => _rooms = roomList);
    } catch (e) {
      setState(() => _error = e.toString());
    }
  }

  // Manual-refresh button on the Direct Messages room list — same
  // one-shot re-fetch pattern as `_refreshRooms`, on top of the live
  // `_directRoomsSubscription`.
  Future<void> _refreshDirectRooms() async {
    try {
      final roomList = await directRooms(client: widget.client);
      setState(() => _directRooms = roomList);
    } catch (e) {
      setState(() => _error = e.toString());
    }
  }

  void _selectTab(RailTab tab) {
    setState(() {
      _activeTab = tab;
      _activeSpace = null;
    });
  }

  Future<void> _selectSpace(SpaceSummary space) async {
    // Closing invalidates any `open` still backfilling — otherwise it
    // would finish and re-populate a room that isn't in the
    // newly-selected space.
    await _activeRoom.close();
    if (!mounted) return;
    setState(() {
      _activeTab = null;
      _activeSpace = space;
    });
    await _refreshSpaceRooms();
  }

  Future<void> _refreshSpaceRooms() async {
    final space = _activeSpace;
    if (space == null) return;
    setState(() => _busy = true);
    try {
      final roomList = await spaceRooms(
        client: widget.client,
        spaceId: space.roomId,
      );
      setState(() => _spaceRooms = roomList);
    } catch (e) {
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _sendMessage() async {
    // Only clear the composer if the message actually went out — the
    // controller owns the send and reports whether it did.
    if (await _activeRoom.send(_messageController.text)) {
      _messageController.clear();
    }
  }

  @override
  Widget build(BuildContext context) {
    // One banner, two owners: the screen's own list/sync failures and
    // the open-room concern's. The screen's wins when both are set —
    // it's the one that broke the thing you're looking at.
    final error = _error ?? _activeRoom.error;
    return Scaffold(
      backgroundColor: MatrixColors.bgContainer,
      body: SafeArea(
        child: Column(
          children: [
            if (error != null)
              Container(
                width: double.infinity,
                color: MatrixColors.criticalContainer,
                padding: const EdgeInsets.all(8),
                child: Text(
                  error,
                  style: const TextStyle(color: MatrixColors.criticalMain),
                ),
              ),
            Expanded(
              child: Row(
                children: [
                  RailNav(
                    activeTab: _activeTab,
                    spaces: _spaces,
                    activeSpaceId: _activeSpace?.roomId,
                    userId: _userId,
                    displayName: _displayName,
                    onSelect: _selectTab,
                    onSelectSpace: _selectSpace,
                    onLogout: widget.onLogout,
                  ),
                  const VerticalDivider(
                    width: 1,
                    color: MatrixColors.bgContainerLine,
                  ),
                  if (_activeSpace != null) ...[
                    RoomList(
                      title: _activeSpace!.displayName,
                      rooms: _spaceRooms,
                      selectedRoomId: _activeRoom.room?.roomId,
                      onSelect: _activeRoom.open,
                      onRefresh: _refreshSpaceRooms,
                      // The room list's refresh button is disabled while
                      // either concern is loading — same single spinner
                      // the screen showed before the split.
                      busy: _busy || _activeRoom.busy,
                    ),
                    const VerticalDivider(
                      width: 1,
                      color: MatrixColors.bgContainerLine,
                    ),
                    RoomView(
                      room: _activeRoom.room,
                      messages: _activeRoom.messages,
                      messageController: _messageController,
                      onSend: _sendMessage,
                      busy: _activeRoom.busy,
                      loadingHistory: _activeRoom.loadingHistory,
                      membersOpen: _activeRoom.membersOpen,
                      onToggleMembers: _activeRoom.toggleMembers,
                    ),
                    if (_activeRoom.membersOpen &&
                        _activeRoom.room != null) ...[
                      const VerticalDivider(
                        width: 1,
                        color: MatrixColors.bgContainerLine,
                      ),
                      MemberDrawer(
                        members: _activeRoom.members,
                        busy: _activeRoom.membersBusy,
                      ),
                    ],
                  ] else if (_activeTab == RailTab.home) ...[
                    RoomList(
                      rooms: _rooms,
                      selectedRoomId: _activeRoom.room?.roomId,
                      onSelect: _activeRoom.open,
                      onRefresh: _refreshRooms,
                      // The room list's refresh button is disabled while
                      // either concern is loading — same single spinner
                      // the screen showed before the split.
                      busy: _busy || _activeRoom.busy,
                    ),
                    const VerticalDivider(
                      width: 1,
                      color: MatrixColors.bgContainerLine,
                    ),
                    RoomView(
                      room: _activeRoom.room,
                      messages: _activeRoom.messages,
                      messageController: _messageController,
                      onSend: _sendMessage,
                      busy: _activeRoom.busy,
                      loadingHistory: _activeRoom.loadingHistory,
                      membersOpen: _activeRoom.membersOpen,
                      onToggleMembers: _activeRoom.toggleMembers,
                    ),
                    if (_activeRoom.membersOpen &&
                        _activeRoom.room != null) ...[
                      const VerticalDivider(
                        width: 1,
                        color: MatrixColors.bgContainerLine,
                      ),
                      MemberDrawer(
                        members: _activeRoom.members,
                        busy: _activeRoom.membersBusy,
                      ),
                    ],
                  ] else if (_activeTab == RailTab.direct) ...[
                    RoomList(
                      title: 'Direct Messages',
                      rooms: _directRooms,
                      selectedRoomId: _activeRoom.room?.roomId,
                      onSelect: _activeRoom.open,
                      onRefresh: _refreshDirectRooms,
                      // The room list's refresh button is disabled while
                      // either concern is loading — same single spinner
                      // the screen showed before the split.
                      busy: _busy || _activeRoom.busy,
                    ),
                    const VerticalDivider(
                      width: 1,
                      color: MatrixColors.bgContainerLine,
                    ),
                    RoomView(
                      room: _activeRoom.room,
                      messages: _activeRoom.messages,
                      messageController: _messageController,
                      onSend: _sendMessage,
                      busy: _activeRoom.busy,
                      loadingHistory: _activeRoom.loadingHistory,
                      membersOpen: _activeRoom.membersOpen,
                      onToggleMembers: _activeRoom.toggleMembers,
                    ),
                    if (_activeRoom.membersOpen &&
                        _activeRoom.room != null) ...[
                      const VerticalDivider(
                        width: 1,
                        color: MatrixColors.bgContainerLine,
                      ),
                      MemberDrawer(
                        members: _activeRoom.members,
                        busy: _activeRoom.membersBusy,
                      ),
                    ],
                  ] else
                    const Expanded(child: _ComingSoon()),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// design/style.css's `.lobby-placeholder` tone — used for rail tabs that
// don't have a real screen behind them yet (no explore/inbox/search API
// on the Rust side, settings/feedback still just mockup dialogs).
class _ComingSoon extends StatelessWidget {
  const _ComingSoon();

  @override
  Widget build(BuildContext context) {
    return const ColoredBox(
      color: MatrixColors.surfaceContainer,
      child: Center(
        child: Text(
          'Not implemented yet',
          style: TextStyle(color: MatrixColors.onContainerDim, fontSize: 13),
        ),
      ),
    );
  }
}
