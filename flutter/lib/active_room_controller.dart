import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:matrix_client/src/rust/api/matrix.dart';

/// Opens a room's timeline. Defaults to `timelineFor`.
typedef OpenTimeline = Future<RoomTimeline> Function(String roomId);

/// Live message stream for an open timeline. Defaults to
/// `timelineMessagesStream`.
typedef MessagesOf = Stream<List<TimelineMessage>> Function(
  RoomTimeline timeline,
);

/// Stops a timeline's Rust-side push loop. Defaults to `stopTimeline`.
typedef StopTimeline = Future<void> Function(RoomTimeline timeline);

/// Sends a plain-text message. Defaults to `sendText`.
typedef SendText = Future<void> Function(RoomTimeline timeline, String body);

/// Fetches a room's joined members. Defaults to `roomMembers`.
typedef LoadMembers = Future<List<RoomMemberSummary>> Function(String roomId);

/// Adds one page of older events to a timeline. Defaults to
/// `paginateBackwards`.
typedef PaginateBackwards =
    Future<bool> Function(RoomTimeline timeline, int numEvents);

/// Live backward-pagination status for a timeline. Defaults to
/// `backPaginationStatusStream`.
typedef BackPaginationStatusOf = Stream<BackPaginationStatus> Function(
  RoomTimeline timeline,
);

/// Owns everything about *the room that is currently open*: its timeline
/// handle, the live message subscription feeding it, its member list,
/// and the busy/error state of opening it.
///
/// Extracted out of `_HomeScreenState` on 2026-11-15, and not for
/// tidiness — the screen had ~15 fields and six independent async flows
/// sharing one `_busy`/`_error`, and that is what let the room-switch
/// race (below) exist in the first place. With one owner, "only the
/// latest open wins" is enforced in one place and is testable without a
/// GUI (`test/active_room_controller_test.dart`), instead of being a
/// rule that lives in a comment and silently breaks the next time
/// someone adds an `await`.
///
/// The screen keeps what isn't this concern: the room/space/DM lists and
/// their subscriptions, the active tab/space, and the session identity.
class ActiveRoomController extends ChangeNotifier {
  /// Wires every dependency to the real `flutter_rust_bridge` API.
  ActiveRoomController({required MatrixClient client})
    : _openTimeline = ((roomId) =>
            timelineFor(client: client, roomId: roomId)),
      _messagesOf = ((timeline) => timelineMessagesStream(timeline: timeline)),
      _stopTimeline = ((timeline) => stopTimeline(timeline: timeline)),
      _sendText = ((timeline, body) => sendText(timeline: timeline, body: body)),
      _loadMembers = ((roomId) => roomMembers(client: client, roomId: roomId)),
      _paginateBackwards = ((timeline, numEvents) =>
          paginateBackwards(timeline: timeline, numEvents: numEvents)),
      _backPaginationStatusOf = ((timeline) =>
          backPaginationStatusStream(timeline: timeline));

  /// Seam for tests: lets them drive the ordering of concurrent opens
  /// (which is the whole point — the race is about *which* request
  /// resolves first) without a `MatrixClient`, a homeserver, or the
  /// native library loaded.
  @visibleForTesting
  ActiveRoomController.withDependencies({
    required OpenTimeline openTimeline,
    required MessagesOf messagesOf,
    required StopTimeline stopTimeline,
    required SendText sendText,
    required LoadMembers loadMembers,
    required PaginateBackwards paginateBackwards,
    required BackPaginationStatusOf backPaginationStatusOf,
  }) : _openTimeline = openTimeline,
       _messagesOf = messagesOf,
       _stopTimeline = stopTimeline,
       _sendText = sendText,
       _loadMembers = loadMembers,
       _paginateBackwards = paginateBackwards,
       _backPaginationStatusOf = backPaginationStatusOf;

  final OpenTimeline _openTimeline;
  final MessagesOf _messagesOf;
  final StopTimeline _stopTimeline;
  final SendText _sendText;
  final LoadMembers _loadMembers;
  final PaginateBackwards _paginateBackwards;
  final BackPaginationStatusOf _backPaginationStatusOf;

  /// How many raw timeline events to request per backfill page once a
  /// room is open. See [_maxBackfillPages].
  static const int _backfillPageSize = 30;

  /// How many backfill pages to request before giving up — bounds the
  /// request count for a room with a very long history rather than
  /// paginating all the way back on every open. Same 3×30 budget
  /// `timeline_for` (`crates/matrix-client/src/timeline.rs`) used to
  /// apply *before* showing the room (moved here 2026-11-15, running
  /// after instead — see [_backfill]).
  static const int _maxBackfillPages = 3;

  // The room the most recent `open()` call targeted, whether or not it
  // has finished yet. Lets a repeat click on the same row — fired again
  // before the first click's `open()` resolved, e.g. a real room's
  // `timeline_builder().build()` taking a visible moment to decrypt and
  // load history — be ignored instead of bumping `_generation` and
  // restarting the race from scratch. Without this, impatiently
  // re-clicking a slow-to-open room never lets any single `open()` run
  // long enough to finish; it only ever does once the user stops
  // clicking, which looks like "it takes N clicks" when N is really
  // just "however many times you clicked before you got tired of it".
  String? _pendingRoomId;
  RoomSummary? _room;
  RoomTimeline? _timeline;
  StreamSubscription<List<TimelineMessage>>? _subscription;
  StreamSubscription<BackPaginationStatus>? _paginationSubscription;
  List<TimelineMessage> _messages = const [];
  List<RoomMemberSummary> _members = const [];
  bool _loadingHistory = false;
  bool _hasMoreHistory = true;
  bool _busy = false;
  bool _membersBusy = false;
  bool _membersOpen = false;
  String? _error;
  bool _disposed = false;

  /// Monotonic ticket for open requests: "latest request wins". Every
  /// [open] takes the next value and re-checks it after each `await`, so
  /// a slow earlier switch can never install its timeline over the room
  /// a later click already opened. A `busy` flag can't do this job — it
  /// says "something is loading", not "*your* load is still the one that
  /// matters", and gating on it would drop the user's newest click
  /// instead of the stale one. Also bumped by [close] and [dispose] so
  /// their teardown invalidates anything still in flight.
  int _generation = 0;

  /// The open room, or `null` when none is (nothing selected yet, or
  /// [close]d by a space switch).
  RoomSummary? get room => _room;

  /// Messages of the open room, newest-last. Pushed by the live
  /// subscription, not polled.
  List<TimelineMessage> get messages => _messages;

  /// Joined members of the open room; only fetched while [membersOpen].
  List<RoomMemberSummary> get members => _members;

  /// `true` while a backfill page is actively being fetched from the
  /// server for the open room. Drives a "loading history" indicator —
  /// unlike [busy], this never blocks the room from showing; it's purely
  /// informational.
  bool get loadingHistory => _loadingHistory;

  /// `true` as long as the open room's history isn't fully backfilled
  /// yet. Starts `true` for a freshly-opened room and flips to `false`
  /// once a backfill page reports it reached the start of the room.
  bool get hasMoreHistory => _hasMoreHistory;

  /// `true` while a room is being opened or a message sent.
  bool get busy => _busy;

  /// `true` while the member list is being fetched.
  bool get membersBusy => _membersBusy;

  /// Whether the members panel is showing. Stays on across a room
  /// switch (matches how the design mockup treats it) — [open] just
  /// refetches for the newly-opened room.
  bool get membersOpen => _membersOpen;

  /// Last error from this concern, for the screen's error banner.
  String? get error => _error;

  /// A request is stale once a newer one has started or the controller
  /// is gone. Replaces the `mounted` checks this logic used to need when
  /// it lived in a `State`.
  bool _isStale(int generation) => _disposed || generation != _generation;

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  /// Opens [room], superseding any open still in flight.
  Future<void> open(RoomSummary room) async {
    // Already the target of an `open()` still in flight: ignore, rather
    // than restarting the race. Reopening a room that's already fully
    // open (not busy) is a deliberate refresh, not blocked by this
    // guard — see the "reopening the same room" test.
    if (_busy && room.roomId == _pendingRoomId) return;
    _pendingRoomId = room.roomId;
    final generation = ++_generation;
    await _detach();
    // A newer open landed while we were detaching — it has already torn
    // down the old timeline itself, so there is nothing left to do.
    if (_isStale(generation)) return;
    _busy = true;
    _error = null;
    _notify();
    try {
      final timeline = await _openTimeline(room.roomId);
      // `timeline_for` returns as soon as the local `Timeline` is built —
      // it does not backfill from the server, so this `await` is fast
      // and rarely overlaps with another click. A loser must still not
      // write any state, and must stop the timeline it just built —
      // dropping the handle would leave its Rust-side task running with
      // no subscriber.
      if (_isStale(generation)) {
        await _stopTimeline(timeline);
        return;
      }
      // `_subscription` is null for the winner in the common case, but
      // cancel rather than assume it — overwriting a live subscription
      // is exactly the leak this logic used to have.
      await _cancelSubscription();
      if (_isStale(generation)) {
        await _stopTimeline(timeline);
        return;
      }
      _room = room;
      _timeline = timeline;
      _messages = const [];
      _members = const [];
      // Reset per-room: a freshly-opened room hasn't been backfilled at
      // all yet, regardless of what the room just left showed.
      _loadingHistory = false;
      _hasMoreHistory = true;
      _notify();
      if (_membersOpen) unawaited(refreshMembers());
      // Real push updates via matrix-client's `subscribe_messages`
      // (`Timeline::subscribe_filter_map`'s VectorDiff stream,
      // re-flattened to a plain snapshot per update) — the first
      // emission is the current snapshot, every one after that is a live
      // update. No polling.
      _subscription = _messagesOf(timeline).listen(
        (messages) {
          _messages = messages;
          _notify();
        },
        onError: (e) {
          _error = e.toString();
          _notify();
        },
      );
      _paginationSubscription = _backPaginationStatusOf(timeline).listen((
        status,
      ) {
        _loadingHistory = status.isPaginating;
        _hasMoreHistory = !status.hitTimelineStart;
        _notify();
      });
      // Fire-and-forget, *not* awaited by `open()` — the room is already
      // showing by this point (whatever's in the local event cache from
      // live sync), and backfilling more history from the server is
      // background work layered on top, not a precondition for opening.
      // This used to be `timeline_for`'s job, done synchronously before
      // the room could show at all (reverted 2026-11-15): two other
      // `matrix-rust-sdk` clients, Element X (`RustTimeline.kt`) and
      // `git/robrix` (`room_screen.rs`), both show the cached timeline
      // immediately and only paginate afterward.
      unawaited(_backfill(timeline, generation));
    } catch (e) {
      // Only the current request owns `_error`/`_busy`: a stale failure
      // must not raise a banner over the room the user actually has
      // open, nor clear the spinner a newer switch is still showing.
      if (!_isStale(generation)) {
        _error = e.toString();
        _notify();
      }
    } finally {
      if (!_isStale(generation)) {
        _busy = false;
        _notify();
      }
    }
  }

  /// Closes the open room and invalidates any open in flight. Used when
  /// the selection goes away rather than moving — switching space, for
  /// one, where an `open` still backfilling would otherwise finish and
  /// re-populate a room that isn't in the newly-selected space.
  ///
  /// Deliberately leaves [error] alone: a failure the user hasn't seen
  /// acknowledged shouldn't vanish because they clicked a space.
  Future<void> close() async {
    _generation++;
    _pendingRoomId = null;
    await _detach();
    _room = null;
    _messages = const [];
    _members = const [];
    _membersOpen = false;
    _membersBusy = false;
    _notify();
  }

  /// Sends [body] to the open room. Returns `true` when it went out, so
  /// the caller can clear its input field only on success.
  Future<bool> send(String body) async {
    final timeline = _timeline;
    if (timeline == null || body.isEmpty) return false;
    _busy = true;
    _notify();
    try {
      await _sendText(timeline, body);
      // No manual refetch needed — the active subscription picks up the
      // local echo (and its later confirmation) on its own.
      return true;
    } catch (e) {
      _error = e.toString();
      return false;
    } finally {
      _busy = false;
      _notify();
    }
  }

  /// Shows/hides the members panel, fetching on open.
  void toggleMembers() {
    _membersOpen = !_membersOpen;
    _notify();
    if (_membersOpen) unawaited(refreshMembers());
  }

  /// Refetches the open room's member list.
  Future<void> refreshMembers() async {
    final room = _room;
    if (room == null) return;
    // Pinned to the *current* generation, not a new one: this load
    // belongs to whichever room is open now, so a room switch makes it
    // stale. Without this, members of the room you just left could land
    // on top of the one you just opened.
    final generation = _generation;
    _membersBusy = true;
    _notify();
    try {
      final members = await _loadMembers(room.roomId);
      if (_isStale(generation)) return;
      _members = members;
      _notify();
    } catch (e) {
      if (!_isStale(generation)) {
        _error = e.toString();
        _notify();
      }
    } finally {
      if (!_isStale(generation)) {
        _membersBusy = false;
        _notify();
      }
    }
  }

  /// Clears the error banner.
  void clearError() {
    _error = null;
    _notify();
  }

  /// Requests up to [_maxBackfillPages] pages of older history for
  /// [timeline], stopping early once the start of the room is reached —
  /// or once [generation] is superseded, so a room the user has already
  /// switched away from stops asking the server for more of a history
  /// nobody's looking at. Doesn't cancel a page already in flight (the
  /// SDK's own event cache would just hand a concurrent caller the same
  /// result anyway, see `RoomTimeline::paginate_backwards`'s doc
  /// comment) — it only skips *starting* another one.
  ///
  /// A failed page is silently swallowed rather than surfaced as
  /// [error]: the room is already open and usable, so a backfill
  /// hiccup is strictly "less history than hoped for", not a broken
  /// state worth a banner over the room the user can see fine.
  Future<void> _backfill(RoomTimeline timeline, int generation) async {
    for (var page = 0; page < _maxBackfillPages; page++) {
      if (_isStale(generation)) return;
      bool hitStart;
      try {
        hitStart = await _paginateBackwards(timeline, _backfillPageSize);
      } catch (_) {
        return;
      }
      if (hitStart) return;
    }
  }

  /// Cancels the live message subscription, clearing the field *before*
  /// awaiting so a concurrent caller can't find and cancel the same
  /// subscription twice (or install a new one that this call then
  /// cancels out from under it). Awaiting matters: the stream is backed
  /// by Rust-side `subscribe_messages`, whose loop only notices
  /// cancellation at its next iteration, and we want it done emitting
  /// before the next room's stream starts.
  Future<void> _cancelSubscription() async {
    final subscription = _subscription;
    _subscription = null;
    await subscription?.cancel();
  }

  /// Cancels the live backward-pagination status subscription, same
  /// reasoning and same ordering as [_cancelSubscription].
  Future<void> _cancelPaginationSubscription() async {
    final subscription = _paginationSubscription;
    _paginationSubscription = null;
    await subscription?.cancel();
  }

  /// Detaches from the open timeline: trip the Rust-side cancellation
  /// token *first*, then cancel both Dart subscriptions.
  ///
  /// That order is load-bearing, not cosmetic. Both live streams
  /// (`subscribe_messages`, `subscribe_back_pagination_status`) are
  /// Rust `tokio::select!` loops that only end when their
  /// `cancel.cancelled()` branch wins — which is exactly what
  /// `stopTimeline` triggers. Awaiting a Dart `StreamSubscription.cancel()`
  /// *before* that call waits for a Rust loop that has no way to notice
  /// the cancellation yet, since nothing has told it to. On a quiet room
  /// (no new events, no backfill status changes) that wait never
  /// resolves on its own.
  ///
  /// Found via a real repro switching rooms needed exactly 3 clicks
  /// before it "took": click 1's `_detach()` got stuck awaiting
  /// `_cancelSubscription()`; click 2's got stuck one step later,
  /// awaiting `_cancelPaginationSubscription()` (the first subscription
  /// was already null, so that await was a no-op); click 3 was the
  /// first to actually reach `_stopTimeline`, which flips the
  /// cancellation token and unblocks *both* of the earlier clicks'
  /// stuck awaits at once — matching the "several pending switches
  /// finally unsticking together in a burst" symptom this file's
  /// history already describes for a related `dispose()` attempt
  /// (2026-11-12/13, reverted): same underlying cause, different
  /// trigger. Calling `stopTimeline` first removes the deadlock outright
  /// rather than just making it less likely to stack up.
  ///
  /// Still deliberately does *not* also call `.dispose()` on the handle
  /// here — [dispose] is the one place that may dispose eagerly; see its
  /// own comment for why a hot path like this one shouldn't.
  Future<void> _detach() async {
    final timeline = _timeline;
    _timeline = null;
    if (timeline != null) await _stopTimeline(timeline);
    await _cancelSubscription();
    await _cancelPaginationSubscription();
  }

  @override
  void dispose() {
    _disposed = true;
    // Invalidate every in-flight `open`: whichever one resolves after
    // this point takes its stale branch and stops the timeline it built.
    _generation++;
    _subscription?.cancel();
    _subscription = null;
    _paginationSubscription?.cancel();
    _paginationSubscription = null;
    final timeline = _timeline;
    _timeline = null;
    if (timeline != null) {
      _stopTimeline(timeline);
      // Unlike `_detach`'s other callers (see its doc comment for why it
      // no longer disposes), this is a one-time final teardown, not a
      // hot path repeated clicks pile onto — safe to dispose eagerly.
      timeline.dispose();
    }
    super.dispose();
  }
}
