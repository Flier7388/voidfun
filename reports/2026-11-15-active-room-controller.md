# Room-switch race: latest-request-wins, then extracted into a controller (2026-11-15)

## The bug
Switching rooms inside a space stalled for seconds after a few clicks,
then released all the pending switches at once in a burst. Instrumented
on 2026-11-13: `_RoomRow`'s tap reached `_openRoom` every single time, so
the click was never the problem.

## Root cause
`_openRoom` (`home_screen.dart`) allowed concurrent runs with no
staleness check after `await timelineFor(...)`. With A clicked, then B:

1. A cancels the old subscription, stops the old timeline, goes into
   `timelineFor` — three real network round-trips of backfill
   (`MAX_BACKFILL_PAGES` × `BACKFILL_PAGE_SIZE` = 3×30, `timeline.rs`).
2. B does the same; `_stopCurrentTimeline()` stops the *same*
   `_timeline`, because A never nulled the field.
3. B returns first and installs room B plus its subscription.
4. A returns late and **overwrites** `_selectedRoom`, `_timeline` and
   `_timelineSubscription` — dropping the reference to B's live
   subscription without cancelling it. The UI shows the room clicked
   *earlier*, and B's `subscribe_messages` task runs on with no owner.

Enough orphaned streams accumulated to congest FRB's call dispatch,
which is what the "all unsticks at once" burst was. Note this is the
same leak class as the 2026-11-09 fix (see that report) arriving by a
different route — not the `tokio::spawn` backfill (reverted 2026-11-13)
and not `.dispose()` (reverted 2026-11-13), both of which were blamed
first.

## The fix, in two steps

### 1. Latest-request-wins
A monotonic generation ticket, taken at entry and re-checked after every
`await`. A superseded request writes no state and calls `stopTimeline()`
on the timeline it built, rather than dropping the handle. `busy` cannot
do this job: it means "something is loading", not "*your* load still
matters", and gating on it would drop the user's newest click instead of
the stale one.

### 2. `ActiveRoomController` (`lib/active_room_controller.dart`)
The guard worked but lived in a widget as a rule enforced by comments —
exactly how an invariant silently breaks the next time someone adds an
`await`. So the open-room concern moved into one `ChangeNotifier` that
owns the room, timeline, subscription, members and its own busy/error:

- `_HomeScreenState` went 581 → 448 lines and now holds zero FFI calls
  for this concern; it keeps the room/space/DM lists, tab/space
  selection and session identity.
- Every dependency is injectable (`withDependencies`), which is what
  makes the race testable at all.
- The members race fell out for free: `refreshMembers` pins the
  *current* generation, so members of the room you left can no longer
  land under the room you opened.
- No new dependency — `ChangeNotifier` is in Flutter. Deliberately not
  bloc/riverpod: a framework buys less than this one class for a 10-file
  UI, and a dependency is forever.

Two shared fields stayed shared on purpose, with both owners combined in
`build`: the room list's refresh button is disabled while *either*
concern loads (`_busy || _activeRoom.busy`), and the error banner shows
`_error ?? _activeRoom.error`.

## Verification
`test/active_room_controller_test.dart`, 7 tests, no homeserver and no
`libapp_bridge.so` needed — `RoomTimeline` is an empty abstract
interface in the generated bindings, so a `noSuchMethod` stub stands in.
The harness hand-resolves opens, so a test picks which of two concurrent
switches completes first.

Checked that the tests actually pin the behaviour: with
`_isStale`'s generation comparison removed, **5 of 7 fail**. The two
that still pass are pinning other things — subscription teardown, and
the negative control that reopening the same room is *not* stale.

- `dart analyze`: clean.
- `flutter test`: 10 pass. `widget_test.dart` fails, pre-existing and
  unrelated — `MatrixClientApp` starts in `_Stage.restoring` and only
  shows `LoginScreen` after `loadSession()`; adding `pumpAndSettle()`
  makes it time out instead, because `path_provider`'s channel is
  absent under `flutter test` and `_tryRestore` only guards
  `restoreSession`. Needs the channel mocked or a seam in `main.dart`.
- `flutter build linux`: succeeds.
- Not done: the manual click-through (10 rapid switches, spaces, DMs,
  closing the screen mid-open). The automated tests cover the same
  orderings deterministically, but they are not a substitute for the app
  under a real homeserver.

## Still open
- The native `Timeline` still leaks until Dart's GC/FRB finalizer runs.
  `_detach` deliberately does not `.dispose()` — see its doc comment and
  the 2026-11-13 revert. Only `dispose()` disposes eagerly.
- `timeline_for` is still uncancellable: a superseded open finishes its
  3×30 backfill and throws the result away. Threading a
  `CancellationToken` into `paginate_backwards` would stop the wasted
  traffic, but it does *not* remove the need for the generation guard —
  cancellation is always racy, so a request can still land just before
  the cancel does.
- `ROADMAP.md`'s "Switching rooms gets stuck — Fixed 2026-11-11" entry is
  wrong: that fix was the `.dispose()` call reverted on 2026-11-13.
