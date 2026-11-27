# Ares NextGen interactive group chat (section C)

Repo: `/home/serei/.hermes/cache/scratch/ares`
Prerequisite: `SPEC.md` sections A/B/D/E are implemented and committed by the previous task. Use the same model `freellmapi/opencode-deepseek-v4.1-flash`.

Goal: replace the read-only bottom sheet with a full-screen, interactive group chat that works for both hosted gateway rooms and Desktop-mirrored rooms. NextGen only. Do not push.

## User symptom

Tapping a group in Bots opens a small detail bar. The user cannot type or send messages. It must open like a bot chat with a message list and composer.

## Files

- `lib/nextgen/data/group_chat_controller.dart` (new)
- `lib/nextgen/ui/group_chat_page.dart` (new)
- `lib/nextgen/ui/bots_pane.dart`
- `lib/nextgen/ui/main_page.dart`
- `lib/nextgen/data/nextgen_bots.dart`
- `test/nextgen_group_chat_test.dart` (new)

## Data model changes

In `lib/nextgen/data/nextgen_bots.dart`:
- Add `class NgGroupMember { final String name; final String handle; final String profile; }`.
- Change `NgGroupChat.members` from `List<String>` to `List<NgGroupMember>`, keeping a `List<String> get memberNames` compatibility getter for existing UI/tests.
- Parse mirror members from `room['members']` with `name`, `handle`, and the profile name (`name`, falling back to handle).
- Parse hosted room members from `groups.list` `members[]` (`handle`, `profile`, `display_name`).
- Preserve existing `preview`, `lastActiveMs`, `messages`, `gatewayRoom`, `roomId`, and `id`.

## Hosted rooms (`gatewayRoom == true && roomId != null`)

`NgGroupChatController`:
- `Future<void> load()` calls `groups.state {room_id, profile?}` then pages `groups.log {room_id, limit:100, since_seq: cursor}` until `has_more == false` or a safe bound (10 pages).
- Parse `RoomEvent` rows (`seq`, `kind`, `actor`, `payload`, `created_at`) into `NgGroupMessage`; use `payload['text']` when present. Duplicate seq values are ignored.
- `Future<void> send(String text)`:
  - Add an optimistic `NgGroupMessage` with a local id and `pending: true`.
  - Call `groups.send {room_id, event_id: uuid, payload: {text}}`.
  - On JSON-RPC ACK, mark the optimistic row confirmed; on failure mark it failed and keep the text for retry. Never silently duplicate.
  - Re-read `groups.log` after ACK.
- Poll `groups.log` every 2s while the page is mounted; stop on dispose. Ignore results if the room changed.

## Desktop-mirrored rooms (`gatewayRoom == false`)

These rooms are the `ui_meta['hermes-bots-groups']` projection. Their members are bot profiles. Read `/opt/hermes-agent/apps/desktop/src/plugins/hermes-bots/group-turns.ts`, `group-round-prompt.ts`, and `canonical-chat.ts` before coding.

`NgGroupChatController.load()` uses the messages already parsed in `NgGroupChat`.

`send(String text)`:
1. Append the user's message to the in-memory room log.
2. Resolve responders:
   - Parse `@name`, `@all`, `@everyone` from the user text case-insensitively.
   - If explicit mentions resolve, only those members respond. Otherwise rotate through members from the last responder index and ask all members in sequence (first pass may ask every member; `(pass)` replies are recorded but not rendered as substantive text).
3. For each responder:
   - Ensure a hidden per-room member session:
     - Try `session.resume {session_id: storedId, profile: member.profile, omit_messages: true}` for any stored pointer kept in a local `Map<String,String>` keyed `<roomId>:<member.profile>`.
     - On a definitive session-not-found (code 4007) call `session.create {source: gateway.sessionAuthority ? 'gui' : 'desktop', profile: member.profile, title: 'Group: <roomId> · legacy', hidden: true, room_plumbing: true, follow_profile_config: true}`. Store `stored_session_id`; keep `session_id` as runtime.
     - A transient resume failure must NOT mint a new session. Surface an error instead.
   - Build the turn prompt using this compact Desktop-compatible shape:
     ```
     [Group chat: "<room name>"] You are @<member handle>, one participant in a group chat with @<other handles> and the user.

     New messages in the room since your last turn (oldest first):
       User (user): <text>

     Rules for this room:
     - Reply with ONE conversational message ONLY if you have something new worth adding...
     - If you have nothing new to add, reply with exactly "(pass)".
     - Mention a teammate as @name to pull them in; mention @user only for a judgment call...
     - Never reveal content from your private 1:1 chats. Your reply text goes to the room verbatim...
     ```
   - Submit with `prompt.submit {session_id: runtime, profile: member.profile, text: turnPrompt, submission_id: uuid}`.
   - Poll `session.resume {session_id: storedId ?? runtime, profile: member.profile}` every 2s up to 180s. Extend while `running == true` up to 20 minutes. Detect new assistant messages after the pre-submit baseline. Append the newest assistant reply to the room log unless it is exactly `(pass)`.
   - A gateway refusal must surface as an inline error; do not claim delivery.
4. After all responders settle, persist the bounded mirror:
   - Read `profiles.list {include_sessions:false}` to get the default profile's `ui_meta_revisions['hermes-bots-groups']` and current mirror.
   - Replace only this room with last 16 messages, max 1200 chars/message, envelope `{version:3, rooms, deleted, updatedAt}`.
   - Call `profiles.configure {name:'default', ui_meta:{'hermes-bots-groups': mirror}, ui_meta_expected_revisions:{'hermes-bots-groups': revision}}`.
   - On CAS conflict, re-read once and retry; if still conflicting, keep in-memory messages and show "saved locally only".

## Page UI

`NgGroupChatPage`:
- `const NgGroupChatPage({super.key, required this.controller})`.
- Full-screen `Scaffold` with `AppBar`: back button, `NgAvatarStack` from member names, room name, subtitle with member handles.
- `ListView` of messages using `NgAvatar` for authors and bubble/styled text. Show pending/failed state on optimistic rows.
- Bottom composer: `TextField` (Enter sends, Shift+Enter newline) plus send `IconButton`. Disable while sending. Show `controller.error` inline above the composer.
- Use `NgColors` tokens only. No raw `Color(0x...)` or `Colors.red` outside theme roots.

`bots_pane.dart`:
- Remove `showNgGroupChatSheet` usage.
- `_GroupRow.onTap` calls `widget.onOpenGroup(group)`.

`main_page.dart`:
- `_openGroup` stops calling `showNgGroupChatSheet` and instead:
  ```
  final controller = NgGroupChatController(
    gateway: NgScope.of(context).gateway,
    group: group,
    bots: _bots?.bots ?? const [],
    avatarFor: (name) => _bots?.avatarBytes(name),
  );
  Navigator.of(context).push(MaterialPageRoute<void>(
    builder: (_) => NgGroupChatPage(controller: controller),
  ));
  ```
- Do not close the drawer by rebuilding the main chat; use `Navigator.push`.

## Verification

Use local Flutter if available:
```bash
FLUTTER=/home/serei/.hermes/cache/scratch/flutter-sdk/bin/flutter
$FLUTTER test test/nextgen_group_chat_test.dart
$FLUTTER test test/nextgen_bots_test.dart
$FLUTTER analyze lib test
```

Observed behavior to verify with fake gateway calls:
- Hosted group load sends `groups.state` and `groups.log`.
- Hosted group send sends `groups.send` with `event_id`.
- Mirrored group send sends `prompt.submit` with the bot profile, not `default`.
- A transient resume failure does not create a new session.
- The page renders a composer and messages, not a bottom sheet.
- No raw color literals and all existing tests stay green.

Commit when done. Do not push.
