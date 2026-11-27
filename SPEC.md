# Ares NextGen bot/group chat parity fix

Repo: `/home/serei/.hermes/cache/scratch/ares`
Branch: `main`
Base commit: `24fe78d` (quality green, build green)
Reference app: `/home/serei/.hermes/cache/scratch/hermes-mobile` (Hy4ri/hermes-mobile, Kotlin)
Desktop reference: `/opt/hermes-agent/apps/desktop/src/plugins/hermes-bots/`

Use model `freellmapi/opencode-deepseek-v4.1-flash` via `opencode run`. NextGen only. Do not touch Classic UI. Keep all existing tests green.

## User-reported bugs

1. Bot chats fail with "Session Not Found" or "Not yet for X".
2. Selecting a bot resets the drawer to Sessions.
3. Group chats open a bottom sheet/bar only; they must open a full interactive chat.
4. Chat header must change:
   - Sessions mode: profile name / title (currently title / model).
   - Bot mode: avatar + bot name / bot description (currently "Bot chat" / "Ready").
5. Chats already running on another platform (Telegram) must resume and hydrate reliably.

## Root causes already established

- Bot canonical sessions belong to the bot's own profile. `profiles.list` returns `canonical_session` from that profile, but `NgChatController` calls `session.resume`, history REST, `prompt.submit`, and `session.events.since` on the active connection profile. The gateway therefore reports the session as missing.
- `_openBot` shows "No chat yet for X" when a bot has no canonical session instead of creating one.
- `NgSessionsSidebar._tab` is local state and is lost when the drawer/widget is rebuilt.
- `NgGroupChat` rows call `showNgGroupChatSheet`, a read-only modal.
- `NgChatView` app bar hardcodes `chat.title` / `_subtitle(state)`.

## Required implementation

### A. Profile-scoped bot chat controller

Files:
- `lib/nextgen/data/chat_controller.dart`
- `lib/core/services/dashboard_api_client.dart`
- `lib/nextgen/ui/main_page.dart`
- `lib/nextgen/data/nextgen_bots.dart`

Add to `NgChatController`:
- `final String? sessionProfile;` constructor argument.
- `NgChatIdentity? identity` constructor argument, defined in the same file as:
  ```dart
  @immutable
  class NgChatIdentity {
    const NgChatIdentity({
      this.profileName,
      this.botName,
      this.botDescription,
      this.avatarBytes,
    });
    final String? profileName;
    final String? botName;
    final String? botDescription;
    final Uint8List? avatarBytes;
    bool get isBot => botName != null && botName!.trim().isNotEmpty;
  }
  ```
- `_scoped(Map<String, dynamic> params)` adding `profile: sessionProfile` when non-empty; use it for `session.resume`, `session.events.since`, `prompt.submit`, and `session.create`. Do not add `profile` to unrelated methods that reject it.
- `_fetchRows` must pass `profile: sessionProfile` to `gateway.api.getMessagesBytes`.
- When `sessionProfile` is set and `storedId == null`, `session.create` must include `profile: sessionProfile`, a bot title (`Bot Chat` or the supplied identity display name), and `follow_profile_config: true` when the gateway supports it. Read `/opt/hermes-agent/apps/desktop/src/plugins/hermes-bots/canonical-chat.ts` for the exact minimal canonical create semantics; do not invent fields.
- When a bot has no canonical session, `_openBot` must open an empty bot chat rather than showing a toast. The first send creates the session with the bot profile.
- Keep the existing LRU cache keyed so bot chats and ordinary chats with the same id cannot collide. Include `sessionProfile` in the cache key.

Add optional `String? profile` to `DashboardApiClient.getMessagesBytes` and include it in the query after `_profileQuery` so an explicit bot profile overrides the connection default.

Extend `NgBot` with the profile name it already has in `name`; do not rename it. Use `bot.name` as `sessionProfile` when opening.

### B. Preserve sidebar tab

Files:
- `lib/nextgen/ui/sessions_sidebar.dart`
- `lib/nextgen/ui/main_page.dart`

Add optional constructor args to `NgSessionsSidebar`:
- `NgSidebarTab? selectedTab`
- `ValueChanged<NgSidebarTab>? onTabChanged`

State uses `widget.selectedTab ?? NgSidebarTab.sessions`; `didUpdateWidget` syncs external changes; `_tabToggle` calls `onTabChanged` and keeps a local fallback. Existing test fixtures that omit the args must still compile.

In `_NgMainPageState`, add `NgSidebarTab _sidebarTab = NgSidebarTab.sessions`, pass `selectedTab: _sidebarTab` and `onTabChanged: (tab) => setState(() => _sidebarTab = tab)`.

### C. Interactive group chat

Files:
- `lib/nextgen/data/group_chat_controller.dart` (new)
- `lib/nextgen/ui/group_chat_page.dart` (new)
- `lib/nextgen/ui/bots_pane.dart`
- `lib/nextgen/ui/main_page.dart`
- `lib/nextgen/data/nextgen_bots.dart`

Replace `showNgGroupChatSheet` with a full-screen `NgGroupChatPage` pushed via `Navigator.of(context).push(MaterialPageRoute(...))`.

`NgGroupChatController` must:
- Accept `NextGenGateway gateway`, `NgGroupChat group`, optional `List<NgBot> bots`, and optional `Uint8List Function(String profile)? avatarFor`.
- For hosted rooms (`group.gatewayRoom && group.roomId != null`): read `groups.state {room_id, profile?}` and `groups.log {room_id, limit:100}`; send with `groups.send {room_id, event_id: <uuid>, payload:{text}}`; poll log at 2s while mounted; keep optimistic user message until ack.
- For mirrored Desktop rooms: append the user message locally, then send the text to the bot members. Read `/opt/hermes-agent/apps/desktop/src/plugins/hermes-bots/group-turns.ts` and `canonical-chat.ts` to determine the correct member session creation/resume/prompt flow. Use each bot profile from the roster, never the active default. Poll each member session for new assistant replies and append them to the room transcript. Do not claim success if the gateway refuses.
- Persist mirrored room log changes via `profiles.configure` with `ui_meta_expected_revisions` CAS when possible; if a revision conflict occurs, re-read `profiles.list` and retry once. Keep the bounded mirror shape (`version:3`, `rooms`, `deleted`, last 16 messages, 1200 chars/message) from `group-chat.ts`.
- Avoid duplicate sends: a stable `event_id` per submitted message, and only clear the pending mark on a definitive ACK.

`NgGroupChatPage`:
- Full-screen Scaffold with AppBar avatar stack, room name, member names, Back button.
- Scrollable message list with author and text.
- Composer with TextField and send IconButton; Enter sends (Shift+Enter newline), disable while sending, show send error inline.
- No WebView.

### D. Chat header identity

Files:
- `lib/nextgen/data/chat_controller.dart`
- `lib/nextgen/ui/chat_view.dart`
- `lib/nextgen/ui/main_page.dart`

Sessions mode:
- First line: `identity?.profileName ?? gateway.profile ?? 'default'`.
- Second line: `chat.title` (fallback `New chat`).
- Keep model in the existing subtitle only if needed elsewhere; it is no longer the header's first line.

Bot mode:
- Leading 36px `NgAvatar` using `identity.avatarBytes`, fallback name `identity.botName`.
- First line: `identity.botName`.
- Second line: `identity.botDescription` when non-empty, otherwise existing `ngL.ng_ready`.
- Disable rename on bot chats.

### E. Reliable resume for cross-platform running chats

Files:
- `lib/nextgen/data/chat_controller.dart`
- possibly `lib/nextgen/ui/main_page.dart`
- new test `test/nextgen_cross_platform_resume_test.dart`

Use `/home/serei/.hermes/cache/scratch/hermes-mobile/app/src/main/java/com/m57/hermescontrol/ui/chat/ChatViewModel.kt` as reference:
- Bounded retry for transient `session.resume` failures (1s, 2s, 4s, max 3), but terminal `session not found` / 4007 / 404 must not be retried blindly.
- On socket reconnect, clear stale runtime id and rebind via `session.resume`; late results from old generations must be ignored.
- While a turn is running on another platform, hydrate history first, keep the live reply, then replay/catch up. Do not re-send prompts.
- Add explicit error state with manual Retry if retries are exhausted.

## Verification

Use the local Flutter SDK at `/home/serei/.hermes/cache/scratch/flutter-sdk/bin/flutter` if available; otherwise rely on CI.

Before editing each behavior, add or identify a failing test. Run at minimum:
```bash
FLUTTER=/home/serei/.hermes/cache/scratch/flutter-sdk/bin/flutter
$FLUTTER test test/nextgen_bots_chat_routing_test.dart
$FLUTTER test test/nextgen_group_chat_test.dart
$FLUTTER test test/nextgen_cross_platform_resume_test.dart
$FLUTTER analyze lib test
```

Also run existing regressions:
```bash
$FLUTTER test test/nextgen_chat_row_menu_test.dart
$FLUTTER test test/nextgen_unread_test.dart
$FLUTTER test test/nextgen_machine_sources_test.dart
$FLUTTER test test/theme_source_guard_test.dart
```

Commit with one clear message. Do not push; the parent will review and push.
