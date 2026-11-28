// NextGen entry point for switching the Hermes profile on the current gateway.
// The gateway keeps one connection; only the profile selected per REST/WS
// request changes, so the switch is a metadata edit plus a gateway rebuild.
import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';

import '../../core/services/profile_switch_service.dart';
import '../nextgen_preferences.dart';
import '../nextgen_l10n.dart';
import '../theme/nextgen_theme.dart';
import 'nextgen_scope.dart';
import 'widgets.dart';

const _profileCacheTtl = Duration(seconds: 60);

class _CachedProfiles {
  _CachedProfiles(this.profiles, this.fetchedAt);
  final List<String> profiles;
  final DateTime fetchedAt;
}

final Map<String, _CachedProfiles> _profileCache = {};

String _profileCacheKey(NgScope scope) =>
    '${scope.connection.id}|${scope.gateway.url.display}';

/// Persisted copy of the last profile list, so a cold start can aggregate
/// across profiles before the first network round trip completes.
String _profilePrefsKey(NgScope scope) =>
    'nextgen_profiles_cache.${scope.connection.id}.${scope.gateway.url.display}';

/// The last profile list read for [scope], including a stale entry. Chat lists
/// use this to decide whether they can aggregate across profiles without
/// spending a round trip every refresh.
List<String>? cachedNgProfiles(NgScope scope) {
  final key = _profileCacheKey(scope);
  final hit = _profileCache[key];
  if (hit != null && hit.profiles.isNotEmpty) return hit.profiles;
  // A previous launch may have discovered the profiles before this one
  // connected. Use that list immediately and let [ngProfiles] refresh it.
  final raw = scope.prefs.getString(_profilePrefsKey(scope));
  if (raw == null || raw.isEmpty) return null;
  try {
    final decoded = jsonDecode(raw);
    if (decoded is! List) return null;
    final profiles = decoded
        .whereType<String>()
        .where((p) => p.trim().isNotEmpty)
        .toList(growable: false);
    if (profiles.isEmpty) return null;
    _profileCache[key] = _CachedProfiles(
      profiles,
      DateTime.fromMillisecondsSinceEpoch(0),
    );
    return profiles;
  } catch (_) {
    return null;
  }
}

/// Profile label used on chat rows. The server's own store is called
/// `default`; a connection without a profile still shows it that way.
String ngProfileLabel(String? profile) =>
    (profile == null || profile.trim().isEmpty)
    ? ngL.ng_server_default
    : profile.trim();

/// Profile lists change rarely. Keep the last answer per gateway so opening
/// the switcher does not spend two seconds on a round trip every time.
Future<List<String>> ngProfiles(NgScope scope) async {
  final key = _profileCacheKey(scope);
  final hit = _profileCache[key];
  if (hit != null &&
      hit.profiles.isNotEmpty &&
      DateTime.now().difference(hit.fetchedAt) < _profileCacheTtl) {
    return hit.profiles;
  }
  final profiles = await scope.gateway.api.listProfiles();
  // An empty answer is not a profile list: never cache it, or the sidebar
  // stays single-profile until the TTL expires.
  if (profiles.isNotEmpty) {
    _profileCache[key] = _CachedProfiles(profiles, DateTime.now());
    unawaited(
      scope.prefs.setString(_profilePrefsKey(scope), jsonEncode(profiles)),
    );
  }
  return profiles;
}

/// Best-effort warm-up so the first switch tap is usually instant too.
Future<void> warmNgProfiles(NgScope scope) async {
  try {
    await ngProfiles(scope);
  } catch (_) {}
}

const _profileDescriptionTtl = Duration(minutes: 5);

class _CachedProfileDescriptions {
  _CachedProfileDescriptions(this.descriptions, this.fetchedAt);
  final Map<String, String> descriptions;
  final DateTime fetchedAt;
}

final Map<String, _CachedProfileDescriptions> _profileDescriptionCache = {};

/// Profile descriptions change even less often than the name list. Keep the
/// last answer per gateway so a picker can show what each profile is for
/// without blocking on a round trip.
Future<Map<String, String>> ngProfileDescriptions(NgScope scope) async {
  final key = _profileCacheKey(scope);
  final hit = _profileDescriptionCache[key];
  if (hit != null &&
      DateTime.now().difference(hit.fetchedAt) < _profileDescriptionTtl) {
    return hit.descriptions;
  }
  try {
    final rows = await scope.gateway.api.listProfileSummaries();
    final descriptions = {
      for (final row in rows)
        if (row.description.trim().isNotEmpty)
          row.name: row.description.trim(),
    };
    _profileDescriptionCache[key] = _CachedProfileDescriptions(
      descriptions,
      DateTime.now(),
    );
    return descriptions;
  } catch (_) {
    return hit?.descriptions ?? const {};
  }
}

class _ProfileChoice {
  const _ProfileChoice(this.name);
  final String? name;
}

/// Sentinel for "the connection's own profile" in the new-chat picker, where a
/// plain null already means the user dismissed the sheet.
const _ownProfile = '\u0000own';

/// Asks which profile a new chat should live on. Returns null when the user
/// dismisses the sheet, or a record whose [profile] is null for the
/// connection's own profile. Gateways with no other profile answer at once.
Future<({String? profile})?> showNgNewChatProfilePicker(
  BuildContext context,
) async {
  final scope = NgScope.of(context);
  final current = scope.connection.gatewayProfile?.trim();
  // The connection now runs on the system-default profile, which the gateway
  // stores as `default`; it is the "own" choice, not another profile.
  final ownName = (current == null || current.isEmpty) ? 'default' : current;
  var names = cachedNgProfiles(scope);
  if (names == null || names.isEmpty) {
    // The warm-up can lose a race with the first New Chat; ask once here too.
    try {
      names = await ngProfiles(scope);
    } catch (_) {
      names = const <String>[];
    }
    if (!context.mounted) return null;
  }
  final others = names
      .where((p) => p.trim().isNotEmpty && p != ownName)
      .toList(growable: false);
  if (others.isEmpty) return (profile: null);

  final descriptions = ngProfileDescriptions(scope);
  final chosen = await showNgSheet<String>(
    context,
    builder: (ctx) {
      final c = NgColors.of(ctx);
      Widget card({
        required String key,
        required String label,
        required String description,
        required IconData icon,
        required bool selected,
        required VoidCallback onTap,
      }) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Material(
          color: selected ? c.accentSoft : c.surface,
          borderRadius: BorderRadius.circular(NgRadii.md),
          child: InkWell(
            key: Key(key),
            borderRadius: BorderRadius.circular(NgRadii.md),
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              child: Row(
                children: [
                  Container(
                    width: 38,
                    height: 38,
                    decoration: BoxDecoration(
                      color: selected ? c.accent : c.well,
                      shape: BoxShape.circle,
                    ),
                    child: Icon(
                      icon,
                      size: 20,
                      color: selected ? c.onAccent : c.accentText,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Flexible(
                              child: Text(
                                label,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: NgType.label.copyWith(
                                  color: c.text,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                            if (selected) ...[
                              const SizedBox(width: 8),
                              Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 6,
                                  vertical: 2,
                                ),
                                decoration: BoxDecoration(
                                  color: c.accent,
                                  borderRadius: BorderRadius.circular(
                                    NgRadii.full,
                                  ),
                                ),
                                child: Text(
                                  'Current',
                                  style: NgType.caption.copyWith(
                                    color: c.onAccent,
                                    fontSize: 10,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ),
                            ],
                          ],
                        ),
                        const SizedBox(height: 3),
                        Text(
                          description.isEmpty
                              ? 'No description yet.'
                              : description,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: NgType.caption.copyWith(color: c.text3),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  Icon(
                    selected ? Icons.check_circle : Icons.chevron_right,
                    size: selected ? 20 : 18,
                    color: selected ? c.accent : c.text3,
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      return ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(ctx).size.height * 0.72,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 4, 20, 14),
              child: Row(
                children: [
                  Container(
                    width: 40,
                    height: 40,
                    decoration: BoxDecoration(
                      color: c.accentSoft,
                      borderRadius: BorderRadius.circular(NgRadii.md),
                    ),
                    child: Icon(
                      Icons.add_comment_outlined,
                      size: 20,
                      color: c.accentText,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          ngL.ng_new_chat,
                          style: NgType.heading.copyWith(color: c.text),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          ngL.ng_profiles,
                          style: NgType.caption.copyWith(color: c.text3),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            Flexible(
              child: FutureBuilder<Map<String, String>>(
                future: descriptions,
                builder: (ctx, snapshot) {
                  final found = snapshot.data ?? const <String, String>{};
                  final ownDescription =
                      found[current] ?? found[ownName] ?? '';
                  return ListView(
                    shrinkWrap: true,
                    padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
                    children: [
                      card(
                        key: 'ng-new-chat-profile-own',
                        label: ngProfileLabel(current),
                        description: ownDescription,
                        icon: Icons.dns_outlined,
                        selected: true,
                        onTap: () => Navigator.of(ctx).pop(_ownProfile),
                      ),
                      for (final name in others)
                        card(
                          key: 'ng-new-chat-profile-$name',
                          label: name,
                          description: found[name] ?? '',
                          icon: Icons.person_outline,
                          selected: false,
                          onTap: () => Navigator.of(ctx).pop(name),
                        ),
                    ],
                  );
                },
              ),
            ),
            const SizedBox(height: 8),
          ],
        ),
      );
    },
  );
  if (!context.mounted || chosen == null) return null;
  return (profile: chosen == _ownProfile ? null : chosen);
}

/// Shows the profile picker and applies the choice. Returns true when the
/// active gateway was rebuilt for a different profile.
Future<bool> showNgProfileSwitcher(BuildContext context) async {
  final scope = NgScope.of(context);
  final connection = scope.connection;
  List<String> profiles;
  try {
    profiles = await ngProfiles(scope);
  } catch (e) {
    if (context.mounted) ngToast(context, '$e');
    return false;
  }
  if (!context.mounted) return false;
  profiles = profiles.where((p) => p != connection.gatewayProfile).toList();

  final current = connection.gatewayProfile;
  final chosen = await showNgSheet<_ProfileChoice>(
    context,
    builder: (ctx) {
      final c = NgColors.of(ctx);
      return ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(ctx).size.height * 0.72,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 4, 20, 12),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  ngL.switch_profile,
                  style: NgType.heading.copyWith(color: c.text),
                ),
              ),
            ),
            Flexible(
              child: ListView(
                shrinkWrap: true,
                children: [
                  for (final name in <String?>[null, ...profiles])
                    ListTile(
                      leading: Icon(
                        name == null
                            ? Icons.dns_outlined
                            : Icons.person_outline,
                        color: c.accentText,
                      ),
                      title: Text(
                        name ?? ngL.ng_server_default,
                        style: TextStyle(color: c.text),
                      ),
                      selected: name == current,
                      trailing: name == current
                          ? Icon(Icons.check, color: c.accent)
                          : null,
                      onTap: () => Navigator.of(ctx).pop(_ProfileChoice(name)),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 8),
          ],
        ),
      );
    },
  );
  if (chosen == null || !context.mounted) return false;
  if (chosen.name == current) return false;

  final service = ProfileSwitchService(scope.connManager);
  try {
    // null means "server default"; updateConnection clears with an empty
    // string and leaves the field unchanged when given null.
    await service.apply(connection, chosen.name ?? '');
    await NextGenPreferences.setLastSession(scope.prefs, connection.id, null);
    await scope.reload();
    await scope.switchTo(connection.id);
    if (context.mounted) {
      ngToast(context, chosen.name ?? ngL.ng_server_default);
    }
    return true;
  } catch (e) {
    if (context.mounted) ngToast(context, '$e');
    return false;
  }
}
