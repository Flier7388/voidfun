//! The real `app_bridge` API surface: login, session persist/restore,
//! sync, room list, timeline read, send.
//!
//! This is the *only* place `#[frb]` macros exist in the codebase (see
//! `docs/ARCHITECTURE.md`) — `matrix-client` (`crates/matrix-client`)
//! carries no bridge-tooling awareness at all. Every function here is a
//! thin wrapper: convert `matrix-client`'s real types to/from the plain,
//! `String`-based mirror structs below (not `matrix-client`'s own types
//! directly — those carry `ruma` ID types in some fields, which Dart has
//! no use for anyway), and convert `matrix_client::ClientError` to a
//! plain `String` message. Error *kinds* aren't distinguished on the
//! Dart side yet — revisit only if the UI actually needs to branch on
//! more than "show this message".

use crate::frb_generated::StreamSink;
use futures_util::StreamExt;

pub use matrix_client::{MatrixClient, RoomTimeline};

#[flutter_rust_bridge::frb(init)]
pub fn init_app() {
    // Default utilities - feel free to customize
    flutter_rust_bridge::setup_default_user_utils();
}

/// A logged-in session's identity and tokens, flattened to plain strings
/// for the Dart side. Mirrors `matrix_client::Session`, which uses real
/// `ruma` ID types internally.
pub struct Session {
    /// The homeserver URL this session was established against.
    pub homeserver_url: String,
    /// The fully-qualified user ID, e.g. `@test:example.org`.
    pub user_id: String,
    /// This device's ID, as assigned by the homeserver at login.
    pub device_id: String,
    /// The current access token.
    pub access_token: String,
    /// The current refresh token, if the homeserver issued one.
    pub refresh_token: Option<String>,
}

impl From<matrix_client::Session> for Session {
    fn from(session: matrix_client::Session) -> Self {
        Self {
            homeserver_url: session.homeserver_url,
            user_id: session.user_id.to_string(),
            device_id: session.device_id.to_string(),
            access_token: session.access_token,
            refresh_token: session.refresh_token,
        }
    }
}

impl TryFrom<Session> for matrix_client::Session {
    type Error = String;

    fn try_from(session: Session) -> Result<Self, Self::Error> {
        Ok(Self {
            homeserver_url: session.homeserver_url,
            user_id: session
                .user_id
                .try_into()
                .map_err(|e| format!("invalid user id: {e}"))?,
            device_id: session.device_id.into(),
            access_token: session.access_token,
            refresh_token: session.refresh_token,
        })
    }
}

/// A joined room's identity and display name. Mirrors
/// `matrix_client::RoomSummary` (already plain strings — duplicated here
/// anyway so every bridge-crossing type lives next to its conversion).
pub struct RoomSummary {
    /// The room's ID, e.g. `!abc123:example.org`.
    pub room_id: String,
    /// The room's computed display name.
    pub display_name: String,
}

impl From<matrix_client::RoomSummary> for RoomSummary {
    fn from(room: matrix_client::RoomSummary) -> Self {
        Self {
            room_id: room.room_id,
            display_name: room.display_name,
        }
    }
}

/// A joined room member's identity. Mirrors `matrix_client::RoomMemberSummary`.
pub struct RoomMemberSummary {
    /// The member's fully-qualified user ID.
    pub user_id: String,
    /// The member's display name (falls back to their user ID's
    /// localpart if none is set).
    pub display_name: String,
    /// `true` for moderators/administrators/creators (power level 50+).
    pub is_admin: bool,
}

impl From<matrix_client::RoomMemberSummary> for RoomMemberSummary {
    fn from(member: matrix_client::RoomMemberSummary) -> Self {
        Self {
            user_id: member.user_id,
            display_name: member.display_name,
            is_admin: member.is_admin,
        }
    }
}

/// A joined space's identity and display name. Mirrors
/// `matrix_client::SpaceSummary`.
pub struct SpaceSummary {
    /// The space's room ID, e.g. `!abc123:example.org`.
    pub room_id: String,
    /// The space's computed display name.
    pub display_name: String,
}

impl From<matrix_client::SpaceSummary> for SpaceSummary {
    fn from(space: matrix_client::SpaceSummary) -> Self {
        Self {
            room_id: space.room_id,
            display_name: space.display_name,
        }
    }
}

/// A live timeline's backward-pagination state. Mirrors
/// `matrix_client::BackPaginationStatus`.
pub struct BackPaginationStatus {
    /// `true` while a backward-pagination request is in flight.
    pub is_paginating: bool,
    /// `true` once the room's full history has been reached.
    pub hit_timeline_start: bool,
}

impl From<matrix_client::BackPaginationStatus> for BackPaginationStatus {
    fn from(status: matrix_client::BackPaginationStatus) -> Self {
        Self {
            is_paginating: status.is_paginating,
            hit_timeline_start: status.hit_timeline_start,
        }
    }
}

/// A single plain-text timeline message. Mirrors
/// `matrix_client::TimelineMessage`.
pub struct TimelineMessage {
    /// The sending user's ID.
    pub sender: String,
    /// The message's plain-text body.
    pub body: String,
    /// When the event was sent, in milliseconds since the Unix epoch.
    pub timestamp_ms: u64,
}

impl From<matrix_client::TimelineMessage> for TimelineMessage {
    fn from(message: matrix_client::TimelineMessage) -> Self {
        Self {
            sender: message.sender,
            body: message.body,
            timestamp_ms: message.timestamp_ms,
        }
    }
}

/// Logs in with a username and password against `homeserver_url`.
/// `store_path` is a directory the app controls (e.g. from
/// `path_provider` on the Dart side) for the local `matrix-sdk-sqlite`
/// store.
#[flutter_rust_bridge::frb]
pub async fn login(
    homeserver_url: String,
    username: String,
    password: String,
    store_path: String,
) -> Result<MatrixClient, String> {
    MatrixClient::login(
        &homeserver_url,
        &username,
        &password,
        std::path::Path::new(&store_path),
    )
    .await
    .map_err(|error| error.to_string())
}

/// Rebuilds a client from a previously-saved [`Session`], without
/// logging in again.
#[flutter_rust_bridge::frb]
pub async fn restore_session(store_path: String, session: Session) -> Result<MatrixClient, String> {
    let session: matrix_client::Session = session.try_into()?;
    MatrixClient::restore(std::path::Path::new(&store_path), session)
        .await
        .map_err(|error| error.to_string())
}

/// Returns the current session for persistence, or `None` if somehow not
/// logged in.
#[flutter_rust_bridge::frb]
pub fn client_session(client: &MatrixClient) -> Option<Session> {
    client.session().map(Into::into)
}

/// Returns the logged-in account's own display name, or `None` if none
/// is set.
#[flutter_rust_bridge::frb]
pub async fn account_display_name(client: &MatrixClient) -> Result<Option<String>, String> {
    client
        .account_display_name()
        .await
        .map_err(|error| error.to_string())
}

/// Starts the sync service.
#[flutter_rust_bridge::frb]
pub async fn start_sync(client: &MatrixClient) {
    client.start_sync().await;
}

/// Stops the sync service.
#[flutter_rust_bridge::frb]
pub async fn stop_sync(client: &MatrixClient) {
    client.stop_sync().await;
}

/// Returns a snapshot of all currently-joined rooms.
#[flutter_rust_bridge::frb]
pub async fn rooms(client: &MatrixClient) -> Result<Vec<RoomSummary>, String> {
    client
        .rooms()
        .await
        .map(|rooms| rooms.into_iter().map(Into::into).collect())
        .map_err(|error| error.to_string())
}

/// Streams the joined room list: pushes the current snapshot
/// immediately, then a fresh snapshot every time it changes, until the
/// Dart side cancels its subscription.
#[flutter_rust_bridge::frb]
pub async fn rooms_stream(client: &MatrixClient, sink: StreamSink<Vec<RoomSummary>>) {
    let (initial, updates) = client.subscribe_rooms().await;
    // `subscribe_rooms`'s stream is built on `StreamExt::then` (each
    // update awaits a per-room display-name lookup), which makes it
    // `!Unpin` — pin it on the stack before polling.
    futures_util::pin_mut!(updates);
    if sink
        .add(initial.into_iter().map(Into::into).collect())
        .is_err()
    {
        return;
    }
    while let Some(snapshot) = updates.next().await {
        if sink
            .add(snapshot.into_iter().map(Into::into).collect())
            .is_err()
        {
            return;
        }
    }
}

/// Returns a snapshot of all currently-joined direct-message rooms (1:1
/// rooms flagged via `m.direct` account data).
#[flutter_rust_bridge::frb]
pub async fn direct_rooms(client: &MatrixClient) -> Result<Vec<RoomSummary>, String> {
    client
        .direct_rooms()
        .await
        .map(|rooms| rooms.into_iter().map(Into::into).collect())
        .map_err(|error| error.to_string())
}

/// Streams the joined DM room list, same push pattern as [`rooms_stream`].
#[flutter_rust_bridge::frb]
pub async fn direct_rooms_stream(client: &MatrixClient, sink: StreamSink<Vec<RoomSummary>>) {
    let (initial, updates) = client.subscribe_direct_rooms().await;
    futures_util::pin_mut!(updates);
    if sink
        .add(initial.into_iter().map(Into::into).collect())
        .is_err()
    {
        return;
    }
    while let Some(snapshot) = updates.next().await {
        if sink
            .add(snapshot.into_iter().map(Into::into).collect())
            .is_err()
        {
            return;
        }
    }
}

/// Returns a snapshot of the user's top-level joined spaces.
#[flutter_rust_bridge::frb]
pub async fn spaces(client: &MatrixClient) -> Vec<SpaceSummary> {
    client.spaces().await.into_iter().map(Into::into).collect()
}

/// Streams the user's top-level joined spaces, same push pattern as
/// [`rooms_stream`].
#[flutter_rust_bridge::frb]
pub async fn spaces_stream(client: &MatrixClient, sink: StreamSink<Vec<SpaceSummary>>) {
    let (initial, mut updates) = client.subscribe_top_level_joined_spaces().await;
    if sink
        .add(initial.into_iter().map(Into::into).collect())
        .is_err()
    {
        return;
    }
    while let Some(snapshot) = updates.next().await {
        if sink
            .add(snapshot.into_iter().map(Into::into).collect())
            .is_err()
        {
            return;
        }
    }
}

/// Returns the chat rooms directly inside the given space.
#[flutter_rust_bridge::frb]
pub async fn space_rooms(
    client: &MatrixClient,
    space_id: String,
) -> Result<Vec<RoomSummary>, String> {
    client
        .space_rooms(&space_id)
        .await
        .map(|rooms| rooms.into_iter().map(Into::into).collect())
        .map_err(|error| error.to_string())
}

/// Returns the given room's joined members.
#[flutter_rust_bridge::frb]
pub async fn room_members(
    client: &MatrixClient,
    room_id: String,
) -> Result<Vec<RoomMemberSummary>, String> {
    client
        .room_members(&room_id)
        .await
        .map(|members| members.into_iter().map(Into::into).collect())
        .map_err(|error| error.to_string())
}

/// Builds a timeline handle for the given room ID.
#[flutter_rust_bridge::frb]
pub async fn timeline_for(client: &MatrixClient, room_id: String) -> Result<RoomTimeline, String> {
    client
        .timeline_for(&room_id)
        .await
        .map_err(|error| error.to_string())
}

/// Stops this timeline's live `timelineMessagesStream`, if any is
/// running. Call this before discarding a `RoomTimeline` (switching
/// rooms, logging out) — otherwise, on a quiet room, the Rust-side
/// stream task never notices the Dart side stopped listening and leaks
/// the `Timeline` forever. See `matrix_client::RoomTimeline::
/// subscribe_messages`'s doc comment for the full explanation.
#[flutter_rust_bridge::frb]
pub fn stop_timeline(timeline: &RoomTimeline) {
    timeline.stop();
}

/// Returns a snapshot of the timeline's current plain-text messages.
#[flutter_rust_bridge::frb]
pub async fn timeline_messages(timeline: &RoomTimeline) -> Vec<TimelineMessage> {
    timeline
        .messages()
        .await
        .into_iter()
        .map(Into::into)
        .collect()
}

/// Streams the timeline's plain-text messages: pushes the current
/// snapshot immediately, then a fresh snapshot every time the timeline
/// changes, until the Dart side cancels its subscription (a `sink.add`
/// error means the listener is gone — stop producing, don't retry).
#[flutter_rust_bridge::frb]
pub async fn timeline_messages_stream(timeline: &RoomTimeline, sink: StreamSink<Vec<TimelineMessage>>) {
    let (initial, updates) = timeline.subscribe_messages().await;
    // Same reason as `rooms_stream`'s pin_mut: the underlying
    // `async_stream::stream!`-built stream is `!Unpin`.
    futures_util::pin_mut!(updates);
    if sink
        .add(initial.into_iter().map(Into::into).collect())
        .is_err()
    {
        return;
    }
    while let Some(snapshot) = updates.next().await {
        if sink
            .add(snapshot.into_iter().map(Into::into).collect())
            .is_err()
        {
            return;
        }
    }
}

/// Adds up to `num_events` older events to the start of this room's
/// timeline. Returns whether this reached the start of the room's
/// history. Safe to call while another call on the same `timeline` is
/// still in flight — see `matrix_client::RoomTimeline::
/// paginate_backwards`'s doc comment for why.
#[flutter_rust_bridge::frb]
pub async fn paginate_backwards(timeline: &RoomTimeline, num_events: u16) -> Result<bool, String> {
    timeline
        .paginate_backwards(num_events)
        .await
        .map_err(|error| error.to_string())
}

/// Streams this room's backward-pagination state: pushes the current
/// value immediately, then a fresh one on every change, until the Dart
/// side cancels its subscription. Same push pattern as
/// [`timeline_messages_stream`]; produces nothing at all for a timeline
/// not in live mode (never the case for anything [`timeline_for`] hands
/// out).
#[flutter_rust_bridge::frb]
pub async fn back_pagination_status_stream(
    timeline: &RoomTimeline,
    sink: StreamSink<BackPaginationStatus>,
) {
    let Some((initial, statuses)) = timeline.subscribe_back_pagination_status().await else {
        return;
    };
    futures_util::pin_mut!(statuses);
    if sink.add(initial.into()).is_err() {
        return;
    }
    while let Some(status) = statuses.next().await {
        if sink.add(status.into()).is_err() {
            return;
        }
    }
}

/// Sends a plain-text message to this room's timeline.
#[flutter_rust_bridge::frb]
pub async fn send_text(timeline: &RoomTimeline, body: String) -> Result<(), String> {
    timeline
        .send_text(&body)
        .await
        .map_err(|error| error.to_string())
}
