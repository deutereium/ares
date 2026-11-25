import '../models/connection.dart';
import 'connection_manager.dart';

/// Persists a profile choice on an existing saved connection.
///
/// Ares selects the Hermes profile per request, so changing profile means
/// editing the connection and letting the UI rebuild its gateway from the
/// updated [SavedConnection]. Callers must then reload and re-switch the
/// gateway; this class deliberately does no navigation.
class ProfileSwitchService {
  const ProfileSwitchService(this._manager);

  final ConnectionManager _manager;

  /// [profile] is null for the gateway's own default profile. Pass an empty
  /// string to clear an explicit choice; [updateConnection] treats null as
  /// "leave unchanged".
  Future<void> apply(SavedConnection connection, String? profile) {
    return _manager.updateConnection(
      connection.id,
      connection.label,
      connection.host,
      connection.port,
      connection.apiKey,
      gatewayPrefix: connection.gatewayPrefix,
      dashboardPrefix: connection.dashboardPrefix,
      dashboardProxied: connection.dashboardProxied,
      desktopGatewayUrl: connection.desktopGatewayUrl,
      dashboardPort: connection.dashboardPortOverride,
      dashboardUsername: connection.dashboardUsername,
      dashboardPassword: connection.dashboardPassword,
      gatewayProfile: profile,
      clientCertificate: connection.clientCertificate,
    );
  }
}
