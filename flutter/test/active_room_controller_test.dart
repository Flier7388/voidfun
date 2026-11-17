import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:matrix_client/active_room_controller.dart';
import 'package:matrix_client/src/rust/api/matrix.dart';

// `RoomTimeline` is an empty abstract interface in the generated
// bindings (`abstract class RoomTimeline implements RustOpaqueInterface
// {}`), so a stub needs no real native handle — `noSuchMethod` absorbs
// the `RustOpaqueInterface` members (`dispose`, `isDisposed`, ...) that
// only mean something with the library loaded. This is what lets these
// tests run under plain `flutter test`, with no homeserver and no
// `libapp_bridge.so`.
class _FakeTimeline implements RoomTimeline {
  _FakeTimeline(this.roomId);

  final String roomId;

  @override
  dynamic noSuchMethod(Invocation invocation) => null;

  @override
  String toString() => 'timeline($roomId)';
}

RoomSummary _room(String id) => RoomSummary(roomId: id, displayName: id);

TimelineMessage _message(String body) => TimelineMessage(
  sender: '@someone:example.org',
  body: body,
  timestampMs: BigInt.zero,
);

/// One recorded call to the fake `paginateBackwards`, with its own
/// completer so a test can resolve backfill pages out of order — the
/// same reason `_opens` is keyed per room rather than reused.
class _PaginateCall {
  _PaginateCall(this.roomId);

  final String roomId;
  final Completer<bool> completer = Completer<bool>();
}

/// Drives [ActiveRoomController] with hand-resolved opens so a test can
/// decide the order two concurrent room switches complete in — which is
/// the entire subject here. Nothing touches FFI.
class _Harness {
  final Map<String, Completer<RoomTimeline>> _opens = {};
  final List<Future<void>> _pending = [];

  /// Room IDs whose timeline had `stopTimeline` called on it.
  final List<String> stopped = [];

  /// Live message streams handed to the controller, by room ID.
  final Map<String, StreamController<List<TimelineMessage>>> streams = {};

  /// Live backward-pagination status streams handed to the controller,
  /// by room ID.
  final Map<String, StreamController<BackPaginationStatus>> statusStreams =
      {};

  /// Every `paginateBackwards` call, in the order it was issued. Left
  /// unresolved by default — a test only needs to complete one if it's
  /// asserting something about the backfill loop itself.
  final List<_PaginateCall> paginateCalls = [];

  /// Room IDs a member fetch was issued for, in order.
  final List<String> memberRequests = [];

  Completer<List<RoomMemberSummary>>? pendingMembers;

  late final ActiveRoomController controller =
      ActiveRoomController.withDependencies(
        openTimeline: (roomId) {
          final completer = Completer<RoomTimeline>();
          _opens[roomId] = completer;
          return completer.future;
        },
        messagesOf: (timeline) {
          final roomId = (timeline as _FakeTimeline).roomId;
          final stream = StreamController<List<TimelineMessage>>.broadcast();
          streams[roomId] = stream;
          return stream.stream;
        },
        stopTimeline: (timeline) async {
          stopped.add((timeline as _FakeTimeline).roomId);
        },
        sendText: (timeline, body) async {},
        loadMembers: (roomId) {
          memberRequests.add(roomId);
          final completer = Completer<List<RoomMemberSummary>>();
          pendingMembers = completer;
          return completer.future;
        },
        paginateBackwards: (timeline, numEvents) {
          final call = _PaginateCall((timeline as _FakeTimeline).roomId);
          paginateCalls.add(call);
          return call.completer.future;
        },
        backPaginationStatusOf: (timeline) {
          final roomId = (timeline as _FakeTimeline).roomId;
          final stream = StreamController<BackPaginationStatus>.broadcast();
          statusStreams[roomId] = stream;
          return stream.stream;
        },
      );

  /// Resolves the backfill page at [index] in [paginateCalls]'s order.
  Future<void> resolvePaginate(int index, {required bool hitStart}) async {
    paginateCalls[index].completer.complete(hitStart);
    await pumpEventQueue();
  }

  /// Clicks [roomId] and lets the request actually reach `openTimeline`.
  /// The pump is the point: a second `open` called in the same microtask
  /// supersedes the first *before* it ever issues its request (real, and
  /// handled), but that isn't the overlap these tests are about — a
  /// click landing while an earlier one is already backfilling is.
  Future<void> click(String roomId) async {
    _pending.add(controller.open(_room(roomId)));
    await pumpEventQueue();
  }

  /// Completes the in-flight open for [roomId]. Removing the completer
  /// means reopening the same room gets a fresh one.
  Future<void> resolve(String roomId) async {
    await pumpEventQueue();
    final completer = _opens.remove(roomId);
    expect(completer, isNotNull, reason: 'no open in flight for $roomId');
    completer!.complete(_FakeTimeline(roomId));
    await pumpEventQueue();
  }

  /// Fails the in-flight open for [roomId].
  Future<void> fail(String roomId, Object error) async {
    await pumpEventQueue();
    final completer = _opens.remove(roomId);
    expect(completer, isNotNull, reason: 'no open in flight for $roomId');
    completer!.completeError(error);
    await pumpEventQueue();
  }

  /// Waits for every [click] issued so far to finish unwinding.
  Future<void> settle() async {
    await Future.wait(_pending);
    _pending.clear();
    await pumpEventQueue();
  }

  void dispose() {
    for (final stream in streams.values) {
      stream.close();
    }
    for (final stream in statusStreams.values) {
      stream.close();
    }
  }
}

void main() {
  group('ActiveRoomController latest-request-wins', () {
    test('a slow earlier open never overwrites a later one', () async {
      final harness = _Harness();
      addTearDown(harness.dispose);
      final controller = harness.controller;

      // Click A, let it reach the backfill, then click B on top of it.
      await harness.click('!a:example.org');
      await harness.click('!b:example.org');

      // The later click resolves first, then the earlier one arrives
      // late — the exact ordering that left the UI showing the room the
      // user clicked *first*.
      await harness.resolve('!b:example.org');
      expect(controller.room?.roomId, '!b:example.org');

      await harness.resolve('!a:example.org');
      await harness.settle();

      expect(
        controller.room?.roomId,
        '!b:example.org',
        reason: 'the last clicked room must stay open',
      );
    });

    test('a superseded open stops the timeline it built', () async {
      final harness = _Harness();
      addTearDown(harness.dispose);

      await harness.click('!a:example.org');
      await harness.click('!b:example.org');

      await harness.resolve('!b:example.org');
      await harness.resolve('!a:example.org');
      await harness.settle();

      expect(
        harness.stopped,
        contains('!a:example.org'),
        reason: 'the losing timeline must not be left running',
      );
      expect(
        harness.stopped,
        isNot(contains('!b:example.org')),
        reason: 'the winning timeline must stay alive',
      );
    });

    test('messages from a superseded room never reach the UI', () async {
      final harness = _Harness();
      addTearDown(harness.dispose);
      final controller = harness.controller;

      await harness.click('!a:example.org');
      await harness.resolve('!a:example.org');
      await harness.settle();

      harness.streams['!a:example.org']!.add([_message('from room A')]);
      await pumpEventQueue();
      expect(controller.messages.single.body, 'from room A');

      await harness.click('!b:example.org');
      await harness.resolve('!b:example.org');
      await harness.settle();

      // Room A's subscription is cancelled, but even a late emission
      // from a stream that hasn't torn down yet must not repaint B.
      harness.streams['!a:example.org']!.add([_message('late from room A')]);
      await pumpEventQueue();

      expect(controller.room?.roomId, '!b:example.org');
      expect(
        controller.messages,
        isEmpty,
        reason: "room B's timeline emitted nothing yet",
      );
    });

    test('a stale failure raises no banner over the open room', () async {
      final harness = _Harness();
      addTearDown(harness.dispose);
      final controller = harness.controller;

      await harness.click('!a:example.org');
      await harness.click('!b:example.org');

      await harness.resolve('!b:example.org');
      await harness.fail('!a:example.org', StateError('backfill failed'));
      await harness.settle();

      expect(controller.error, isNull);
      expect(controller.busy, isFalse, reason: 'the winner cleared its own');
      expect(controller.room?.roomId, '!b:example.org');
    });

    test('close() invalidates an open still in flight', () async {
      final harness = _Harness();
      addTearDown(harness.dispose);
      final controller = harness.controller;

      await harness.click('!a:example.org');
      await controller.close();

      await harness.resolve('!a:example.org');
      await harness.settle();

      expect(controller.room, isNull, reason: 'the space switch won');
      expect(harness.stopped, contains('!a:example.org'));
    });

    test('reopening the same room is not treated as stale', () async {
      final harness = _Harness();
      addTearDown(harness.dispose);
      final controller = harness.controller;

      await harness.click('!a:example.org');
      await harness.resolve('!a:example.org');
      await harness.settle();

      await harness.click('!a:example.org');
      await harness.resolve('!a:example.org');
      await harness.settle();

      expect(controller.room?.roomId, '!a:example.org');
      expect(
        harness.stopped,
        ['!a:example.org'],
        reason: 'only the first handle is stopped, the fresh one stays',
      );
    });

    test('members of the room you left never land on the one you opened',
        () async {
      final harness = _Harness();
      addTearDown(harness.dispose);
      final controller = harness.controller;

      await harness.click('!a:example.org');
      await harness.resolve('!a:example.org');
      await harness.settle();

      controller.toggleMembers();
      await pumpEventQueue();
      expect(harness.memberRequests, ['!a:example.org']);
      final staleMembers = harness.pendingMembers!;

      // Switch away before room A's member list comes back.
      await harness.click('!b:example.org');
      await harness.resolve('!b:example.org');
      await harness.settle();

      staleMembers.complete([
        RoomMemberSummary(
          userId: '@from-room-a:example.org',
          displayName: 'From room A',
          isAdmin: false,
        ),
      ]);
      await pumpEventQueue();

      expect(
        controller.members.any((m) => m.userId == '@from-room-a:example.org'),
        isFalse,
        reason: "room A's members must not show under room B",
      );
    });
  });

  group('ActiveRoomController background backfill', () {
    test('open() does not wait for backfill to finish', () async {
      final harness = _Harness();
      addTearDown(harness.dispose);
      final controller = harness.controller;

      await harness.click('!a:example.org');
      await harness.resolve('!a:example.org');
      // `settle()` awaits `open()`'s own returned future. If backfill
      // were awaited inline instead of fire-and-forget, this would hang
      // forever — the one page issued below is deliberately never
      // resolved.
      await harness.settle();

      expect(controller.room?.roomId, '!a:example.org');
      expect(controller.busy, isFalse);
      expect(
        harness.paginateCalls,
        hasLength(1),
        reason: 'backfill should have started in the background',
      );
    });

    test('a superseded room stops requesting further backfill pages',
        () async {
      final harness = _Harness();
      addTearDown(harness.dispose);

      await harness.click('!a:example.org');
      await harness.resolve('!a:example.org');
      await harness.settle();
      expect(harness.paginateCalls.map((c) => c.roomId), [
        '!a:example.org',
      ]);

      // Switch away before room A's first backfill page comes back.
      await harness.click('!b:example.org');
      await harness.resolve('!b:example.org');
      await harness.settle();

      // Room A's page finally resolves late, reporting there's more
      // history to fetch — the loop must not ask for a second page,
      // since room A isn't the open room anymore.
      await harness.resolvePaginate(0, hitStart: false);

      expect(
        harness.paginateCalls.where((c) => c.roomId == '!a:example.org'),
        hasLength(1),
        reason: 'a stale backfill loop must not request a second page',
      );
    });

    test('loadingHistory and hasMoreHistory follow the status stream',
        () async {
      final harness = _Harness();
      addTearDown(harness.dispose);
      final controller = harness.controller;

      await harness.click('!a:example.org');
      await harness.resolve('!a:example.org');
      await harness.settle();

      expect(controller.loadingHistory, isFalse);
      expect(controller.hasMoreHistory, isTrue);

      harness.statusStreams['!a:example.org']!.add(
        const BackPaginationStatus(isPaginating: true, hitTimelineStart: false),
      );
      await pumpEventQueue();
      expect(controller.loadingHistory, isTrue);
      expect(controller.hasMoreHistory, isTrue);

      harness.statusStreams['!a:example.org']!.add(
        const BackPaginationStatus(isPaginating: false, hitTimelineStart: true),
      );
      await pumpEventQueue();
      expect(controller.loadingHistory, isFalse);
      expect(
        controller.hasMoreHistory,
        isFalse,
        reason: 'hitting the timeline start means nothing more to fetch',
      );
    });

    test('switching rooms resets loadingHistory/hasMoreHistory', () async {
      final harness = _Harness();
      addTearDown(harness.dispose);
      final controller = harness.controller;

      await harness.click('!a:example.org');
      await harness.resolve('!a:example.org');
      await harness.settle();

      harness.statusStreams['!a:example.org']!.add(
        const BackPaginationStatus(isPaginating: false, hitTimelineStart: true),
      );
      await pumpEventQueue();
      expect(controller.hasMoreHistory, isFalse);

      await harness.click('!b:example.org');
      await harness.resolve('!b:example.org');
      await harness.settle();

      expect(
        controller.hasMoreHistory,
        isTrue,
        reason: "room B hasn't been backfilled at all yet",
      );
      expect(controller.loadingHistory, isFalse);
    });
  });
}
