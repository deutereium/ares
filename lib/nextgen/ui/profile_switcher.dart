// NextGen entry point for switching the Hermes profile on the current gateway.
// The gateway keeps one connection; only the profile selected per REST/WS
// request changes, so the switch is a metadata edit plus a gateway rebuild.
import 'package:flutter/material.dart';

import '../../core/services/profile_switch_service.dart';
import '../nextgen_preferences.dart';
import '../nextgen_l10n.dart';
import '../theme/nextgen_theme.dart';
import 'nextgen_scope.dart';
import 'widgets.dart';

class _ProfileChoice {
  const _ProfileChoice(this.name);
  final String? name;
}

/// Shows the profile picker and applies the choice. Returns true when the
/// active gateway was rebuilt for a different profile.
Future<bool> showNgProfileSwitcher(BuildContext context) async {
  final scope = NgScope.of(context);
  final connection = scope.connection;
  List<String> profiles;
  try {
    profiles = await scope.gateway.api.listProfiles();
  } catch (e) {
    if (context.mounted) ngToast(context, '$e');
    return false;
  }
  if (!context.mounted) return false;
  profiles = profiles.where((p) => p != connection.gatewayProfile).toList();

  final current = connection.gatewayProfile;
  final chosen = await showNgSheet<_ProfileChoice>(context, builder: (ctx) {
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
                        name == null ? Icons.dns_outlined : Icons.person_outline,
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
      ngToast(
        context,
        chosen.name ?? ngL.ng_server_default,
      );
    }
    return true;
  } catch (e) {
    if (context.mounted) ngToast(context, '$e');
    return false;
  }
}
