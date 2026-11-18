# Roadmap

*[Читать на русском](ROADMAP.ru.md)*

Scope for this repository is **desktop only: Windows + Linux**, no
Android/iOS/macOS. A phone client is planned as a **separate repository
with its own roadmap**, not a milestone in this one.

## Rules

- Each milestone lists concrete tasks with acceptance criteria. Don't
  start the next milestone's tasks until the current one's criteria are
  actually met. Exception: **spikes** (time-boxed experiments, e.g. the
  call architecture) and CI work may run in parallel; a spike's result
  is not a milestone task until its acceptance is met.
- Each milestone carries an area tag: `base`, `security`, `chat`,
  `spaces`, `media`, `calls`, `quality`.
- A task is `[x]` only when its acceptance criterion was checked
  against a real homeserver (and, where stated, a second client such
  as Element), not just unit-tested.
- Anything discovered mid-milestone that doesn't fit goes to
  **Backlog** at the bottom, not into the current milestone.

## Why this order

1. **Encryption comes before chat features.** Most DMs and private
   rooms are end-to-end encrypted by default, so replies/reactions/
   media can't be properly tested without working E2EE first.
2. **Accounts/onboarding right after.** Registration, invites and
   joining rooms are needed before anyone but the author can use the
   app.
3. **Chat → awareness → room management → media → calls.** Each step
   builds on the previous one; calls are last because they're the
   riskiest and least standardized part.
4. **CI for the Flutter app is early**, not at the end: it's cheap and
   catches regressions in every later milestone.

## Current state — verified 2026-11-09 (+ fixes through 2026-11-12)

**Backend** (`crates/matrix-client`, `matrix-sdk`/`matrix-sdk-ui` 0.19.1):
- Login (username/password, bare server name or full URL) and session
  restore (persisted on the Flutter side).
- Sync via `SyncService`.
- Joined rooms and top-level spaces: snapshot + live updates. A
  space's child rooms: snapshot only.
- Per-room timeline: snapshot + live updates, background history
  backfill, plain-text send.
- Not built: E2EE verification, registration, replies, reactions,
  edits, search, read receipts, typing, media (only cache retention
  policy exists), notifications, voice/video.

**UI** (Flutter + `flutter_rust_bridge`):
- Custom dark theme, real 3-pane layout (rail / room list / room view),
  Home, Direct Messages and space screens, member drawer, settings
  (profile + logout).
- Explore, Search, Inbox and most of Settings are explicit
  "Not implemented yet" placeholders.

**Platforms:** Linux built and run-tested. Windows: Rust workspace
checked in CI, Flutter Windows build **never run** — unverified.

**Testing/CI:** 3 Rust tests (mock homeserver) + 1 Flutter widget test
file. CI runs `fmt`/`check`/`clippy`/`test`/`cargo-deny`/`cargo-audit`
on Ubuntu + Windows; it doesn't build or test the Flutter app yet.

**Build tag:** `0.1.0-alpha`.

### Fixed issues (history)

- Bare domain in the homeserver field now works
  (`server_name_or_homeserver_url`, `.well-known` discovery) — 2026-11-12.
- History backfill moved to a cancellable background task instead of
  blocking room-open — 2026-11-12.
- Room switching hang: the 2026-11-11 fix (disposing the old
  `RoomTimeline` in `_stopCurrentTimeline()`) was reverted 2026-11-12/13
  — disposing a timeline whose live stream hadn't yet noticed
  cancellation caused the same hang. The open/switch logic was later
  extracted into `ActiveRoomController` (2026-11-15). The actual cause —
  `_detach()` awaited the Dart-side stream cancellation *before* calling
  `stopTimeline`, the only thing that can end those streams — was found
  and fixed 2026-11-17 (call `stopTimeline` first). **Not yet confirmed
  against a live click-through.**
- Full history backfill via `paginate_backwards` (up to 10 × 50 events,
  stops at room start) — 2026-11-11.
- MSC3417 call rooms were hidden from a space's room list; filter
  narrowed to exclude only `RoomType::Space` — 2026-11-11.

---

## 0.0.1-alpha — done

- [x] Log in to a Matrix homeserver (username/password).
- [x] Start sync, confirm it runs against a real server.
- [x] Send a plain-text message and read it back.

## 0.1.0-alpha — UI shell (finishing) `base`

**Goal:** a real, fully custom-styled desktop interface wired to live
data.

- [x] 3-pane layout, custom dark theme, live room/space navigation.
- [x] Member list drawer.
- [x] Settings dialog (avatar, display name, user ID, logout).
- [x] Direct Messages tab (`Room::is_dm()`).
  *Remaining check:* a DM started from another client shows up with the
  other user's name (no DM-flagged room existed at verification time).
- [x] Windows desktop build actually works.
  **Acceptance:** `flutter build windows` succeeds, the `.exe`
  launches, logs in and sends a message (CI runner or real machine).
  Confirmed 2026-11-18: `flutter-windows-build` passes in CI (now
  uploads the build as an artifact instead of discarding it), and the
  owner ran that build on a real Windows machine — logged in and
  reports it behaves the same as the Linux build. The first real
  attempt hit a genuine bug this surfaced (a failed login left a stale
  `matrix-sdk-sqlite` store behind, poisoning the next attempt with a
  device-mismatch error) — fixed the same day.
- [ ] Flutter app is built and widget-tested in CI on Linux + Windows.
  **Acceptance:** a CI run is green with `flutter analyze`,
  `flutter test` and a desktop build on both OSes.

## 0.2.0-alpha — encryption & session security `security`

**Goal:** encrypted rooms work like in any mainstream client, and
credentials aren't lying around in plaintext.

- [ ] Send and receive in an encrypted room.
  **Acceptance:** in a room created in Element with encryption on,
  messages sent from both sides decrypt correctly; no "unable to
  decrypt" for messages sent after login.
- [ ] Show encryption state in the UI.
  **Acceptance:** encrypted rooms show an indicator; undecryptable
  events show a clear placeholder instead of an empty or broken row.
- [ ] Device verification (SAS emoji) — incoming and outgoing.
  **Acceptance:** verifying this session against Element works in both
  directions and both sides show it as verified.
- [ ] Cross-signing and secret storage: bootstrap on a fresh account,
  recovery-key entry on an existing one.
  **Acceptance:** a new login on an account with encrypted history +
  recovery key makes old messages readable (key backup restored).
- [ ] Encrypted local store, secrets in the OS keyring.
  **Acceptance:** no access token or store passphrase in plaintext
  anywhere on disk (checked with a grep over the app's data dir) on
  Linux and Windows.
- [ ] Session list and remote sign-out.
  **Acceptance:** other sessions of the account are listed; signing one
  out in this app logs it out in the other client.

## 0.3.0-alpha — accounts & onboarding `base`

**Goal:** someone other than the author can sign up, log in, get
invited and join rooms.

- [ ] Registration from the app (UIAA flow; registration token, plus
  captcha/email if the server demands them).
  **Acceptance:** a brand-new account is created on a test homeserver
  from the app alone and lands in a working session. If a target
  server only offers OAuth/OIDC (MAS), the criterion is the browser
  hand-off flow instead.
- [ ] Optional: OAuth/OIDC or SSO login.
  **Acceptance:** login against a server that disables password login
  works via the system browser.
- [ ] Pending invites: list, accept, decline.
  **Acceptance:** an invite sent from another client appears, and
  accepting it opens the room.
- [ ] Join a room by alias, room ID or `matrix.to` link; leave a room.
  **Acceptance:** both work and the room list updates live.
- [ ] Account settings: change display name/avatar, change password.
  **Acceptance:** changes are visible in another client.
- [ ] Login/registration error handling: wrong password, unreachable
  server, bad server name, rate limit — each with a readable message.

## 0.4.0-alpha — core chat features `chat`

**Goal:** the timeline behaves like a real chat client.

- [ ] Reply to a message.
  **Acceptance:** shows the quoted original inline and round-trips
  correctly in Element.
- [ ] React with an emoji.
  **Acceptance:** reactions aggregate under the message and are visible
  in another client.
- [ ] Edit and delete (redact) own messages.
  **Acceptance:** edited message shows "(edited)"; deleted one
  disappears or shows "deleted" in both clients.
- [ ] Markdown input and safe HTML rendering (bold, code, quotes,
  links).
  **Acceptance:** formatted messages render the same in this app and in
  Element; no unsanitized HTML reaches the widget tree.
- [ ] Infinite scroll back in history.
  **Acceptance:** scrolling to the top loads older events without
  blocking the UI; no duplicates or gaps.
- [ ] Send queue with retry.
  **Acceptance:** a message sent while offline shows a failed/pending
  state and is delivered (or can be retried) once the network is back.
- [ ] Search within the open timeline.
  **Acceptance:** a query highlights/jumps to matches in loaded
  messages. (Server-side search doesn't work in encrypted rooms —
  see Backlog.)

## 0.5.0-alpha — awareness & notifications `chat`

**Goal:** you can tell what's new without opening every room.

- [ ] Read receipts and a fully-read marker.
  **Acceptance:** reading a room in this app marks it read in Element
  and vice versa.
- [ ] Unread counters and highlight/mention badges on rooms and spaces.
  **Acceptance:** counters match Element's for the same account.
- [ ] Typing indicators (show and send).
- [ ] Desktop notifications while the app is running, with per-room
  mute settings.
  **Acceptance:** a message in an unmuted, unfocused room raises an OS
  notification on Linux and Windows; muted rooms stay silent.
- [ ] System tray icon with unread state; app can run minimized.

## 0.6.0-beta — rooms & spaces management `spaces`

**Goal:** rooms and spaces are manageable, not just browsable.

- [x] List top-level joined spaces and a space's child rooms.
- [ ] Live updates for a space's child rooms (currently snapshot only).
  **Acceptance:** a room added to a space from another client appears
  without pressing refresh.
- [ ] Member roles from `m.room.power_levels`.
  **Acceptance:** the member drawer shows admin/moderator/member
  matching the room's real power levels.
- [ ] Gate admin actions (kick, ban, invite, room settings) by the
  current user's power level.
  **Acceptance:** a non-privileged user can't see or trigger what they
  lack permission for; a privileged user can.
- [ ] Create a room or space; edit name, topic, avatar.
  **Acceptance:** results are immediately visible in another client.
- [ ] Invite users to a room.
- [ ] Explore: public room directory with search and join.
  **Acceptance:** the placeholder is replaced by a working directory
  of the homeserver.
- [ ] Nested subspaces.

## 0.7.0-beta — media `media`

**Goal:** images and files actually work, including in encrypted rooms.

- [ ] Download and display images inline, via `matrix-storage` cache.
  **Acceptance:** an image from another client renders inline, in both
  plain and encrypted rooms, and isn't re-downloaded on every scroll.
- [ ] Avatars (users, rooms, spaces) from the media repository.
- [ ] Send image/file (picker, drag-and-drop, clipboard paste) with
  upload progress.
  **Acceptance:** a file sent from here opens correctly in Element,
  encrypted rooms included.
- [ ] Open/save received files; basic video and audio playback.
- [ ] Media gallery view for a room.
  **Acceptance:** all room images in a grid, loaded from cache where
  available.
- [ ] Media cache retention policy actually enforced.
  **Acceptance:** cache stays under the configured limit.

## 0.8.0-beta — voice (and video if feasible) `calls`

**Goal:** calls work well enough to be usable.

Technical note: the current Matrix calling standard is MatrixRTC
(MSC4143) with a LiveKit SFU, as used by Element Call — not legacy 1:1
WebRTC signalling. The implementation route (embed Element Call via the
SDK widget driver vs. native LiveKit client in Flutter) must be decided
and spiked **before** this milestone starts. The decision and its
rationale go into `docs/ARCHITECTURE.md`.

- [ ] Spike: choose the call architecture and prove a 2-party call.
- [ ] 1:1 voice call.
  **Acceptance:** call connects against the project's own homeserver
  stack, audio works both ways, and normal network conditions don't
  produce noticeable lag/dropouts. Interop with Element Call is
  verified.
- [ ] Incoming call notification and answer/decline.
- [ ] Group voice in a call room (MSC3417 rooms are already listed).
- [ ] Optional: video and screen sharing.

## 0.9.0-rc — stabilization & distribution `quality`

**Goal:** confidence to call it done, on both real target platforms.

- [ ] Full manual click-through pass on Linux and Windows.
  **Acceptance:** a written test log covering login, registration,
  E2EE + verification, rooms, spaces, timeline, send, media,
  reactions/replies/edits, notifications, voice — both OSes, no crashes.
- [ ] All critical bugs from that pass fixed.
- [ ] CI smoke-tests the Flutter app on both platforms (extends the
  0.1.0 CI job).
- [ ] Packaging: Linux (AppImage/Flatpak or Nix package) and a Windows
  installer or portable zip.
  **Acceptance:** a clean machine without a dev toolchain installs and
  runs it.
- [ ] Security pass against `docs/SECURITY.md`: dependency audit,
  secrets handling, log scrubbing (no tokens/keys/message bodies in
  logs or crash reports).
- [ ] Update path: documented way to upgrade (auto-update or manual).
- [ ] Basic accessibility and keyboard navigation (tab order, shortcuts
  for room switching and send).

## 1.0.0 — release `quality`

- [ ] UX polish pass against the `design/` reference, no rough edges
  in core flows.
- [ ] Localization: at least English and Russian.
- [ ] User documentation (install, log in/register, verify a device,
  basic usage).
- [ ] Android client: **not in this repository.** Future, separate
  project with its own roadmap once this one reaches 1.0.

## Release criteria for 1.0

1.0.0 does not mean "all of Matrix is implemented". It means the core
scenarios are reliable, secure and predictable. All of the following
must hold:

- Login, registration, E2EE with device verification and key recovery,
  text chat (reply/react/edit/delete), media and 1:1 voice calls work
  on **both** Linux and Windows, per the written test log from 0.9.0.
- No known crash, data-loss or credential-leak bug in the core flows.
- No secrets (tokens, keys, message bodies) in plaintext on disk or in
  logs.
- CI builds and smoke-tests the Flutter app on both platforms; a clean
  machine can install and run the released build.
- Anything in the UI that isn't implemented is either hidden or
  clearly marked — no fake data.
- Known limitations are listed in the user documentation.

## Out of scope

- Android, iOS and macOS clients (a phone client is a separate
  repository).
- A web version.
- Bridges, bots and a plugin system.
- Implementing a homeserver or custom protocol extensions.

## Backlog (post-1.0 / unscheduled)

- Threads.
- Server-side search; local search index for encrypted rooms (server
  search can't see encrypted content).
- Multi-account.
- Polls, location sharing, pinned messages, stickers/custom emoji.
- URL previews.
- Moderation tools: report content, ignore user, bulk redact.
- Room upgrades, knock/restricted join rules.
- Push on desktop beyond "app is running" (background service).
