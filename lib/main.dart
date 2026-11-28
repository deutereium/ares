import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'core/services/hands_free_route_observer.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'core/services/android_launch_intent_service.dart';
import 'core/services/android_share_intent_service.dart';
import 'core/services/auto_messaging_service.dart';
import 'core/services/client_certificate_service.dart';
import 'core/services/connection_keepalive_service.dart';
import 'core/services/connection_manager.dart';
import 'core/services/desktop_gateway_client.dart';
import 'core/services/background_work_prefs.dart';
import 'core/services/gateway_turn_application_controller.dart';
import 'core/services/mobile_push_service.dart';
import 'core/services/connection_mutation_barrier.dart';
import 'core/services/notification_prefs.dart';
import 'core/services/hands_free_preference.dart';
import 'core/services/hermes_sign_in.dart';
import 'core/services/locale_preference.dart';
import 'core/services/text_size_preference.dart';
import 'core/services/theme_preference.dart';
import 'core/services/turn_notification_service.dart';
import 'core/theme/hermes_theme.dart';
import 'core/widgets/hermes_system_ui.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import 'package:hermes_android/core/l10n/l10n.dart';

import 'nextgen/nextgen_home.dart';
import 'nextgen/nextgen_l10n.dart';
import 'nextgen/nextgen_preferences.dart';
import 'nextgen/theme/nextgen_theme.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  // Remove any private key left behind by a cancelled connection import.
  unawaited(ClientCertificateService().cleanupStaging());
  runApp(const StartupApp());
}

/// Draws a Flutter frame before reading preferences or Android Keystore.
/// The connection store must still finish migration and credential hydration
/// before Home can access any saved connection.
class StartupApp extends StatefulWidget {
  const StartupApp({super.key, this.createConnectionManager});

  /// The production path uses [ConnectionManager.create]; tests can hold a
  /// real credential read pending without depending on the platform Keystore.
  final Future<ConnectionManager> Function(SharedPreferences)?
  createConnectionManager;

  @override
  State<StartupApp> createState() => _StartupAppState();
}

class _StartupAppState extends State<StartupApp> {
  final _shareIntents = AndroidShareIntentService();
  final _launchIntents = AndroidLaunchIntentService();
  SharedPreferences? _prefs;
  ConnectionManager? _connManager;
  Object? _startupError;

  Future<ConnectionManager> _createConnectionManager(SharedPreferences prefs) =>
      widget.createConnectionManager?.call(prefs) ??
      ConnectionManager.create(prefs);

  @override
  void initState() {
    super.initState();
    // A pending secure-store read must not keep the native splash on screen.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_initialize());
    });
  }

  Future<void> _initialize() async {
    late SharedPreferences prefs;
    ConnectionManager? connManager;
    Object? startupError;
    // Preferences/Keystore and the two Android intent channels are
    // independent. Start all three after the first frame, but do not mount
    // Home until both the credential load and initial intents have finished.
    await Future.wait<void>([
      () async {
        prefs = await SharedPreferences.getInstance();
        NextGenPreferences.load(prefs);
        try {
          // Browser sign-ins and Cloudflare Access tokens, shared by both
          // interfaces; a Keystore fault only costs those sign-ins.
          await HermesSignInVault.instance.load().catchError((Object _) {});
          connManager = await _createConnectionManager(prefs);
        } catch (error) {
          // A corrupt connection entry or a Keystore fault must lead to the
          // existing reset/retry screen, never to Home with unhydrated secrets.
          startupError = error;
        }
      }(),
      _shareIntents.initialize(),
      _launchIntents.initialize(),
    ]);
    if (!mounted) return;
    setState(() {
      _prefs = prefs;
      _connManager = connManager;
      _startupError = startupError;
    });
  }

  @override
  Widget build(BuildContext context) {
    final prefs = _prefs;
    if (prefs != null) {
      final connManager = _connManager;
      if (connManager != null) {
        return HermesApp(
          connManager: connManager,
          shareIntents: _shareIntents,
          launchIntents: _launchIntents,
        );
      }
      return _StartupRecoveryApp(
        prefs: prefs,
        error: _startupError,
        createConnectionManager: _createConnectionManager,
        onRecovered: (manager) {
          if (mounted) setState(() => _connManager = manager);
        },
      );
    }
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: hermesTheme(Brightness.light),
      darkTheme: hermesTheme(Brightness.dark),
      home: const Scaffold(body: Center(child: CircularProgressIndicator())),
    );
  }
}

/// Minimal recovery surface shown when the connection store could not be
/// loaded at launch. Offers to wipe the damaged saved-connections metadata
/// (and only that key) and retry, rather than dying silently.
class _StartupRecoveryApp extends StatelessWidget {
  static final GlobalKey _rootKey = GlobalKey();

  const _StartupRecoveryApp({
    required this.prefs,
    required this.error,
    required this.createConnectionManager,
    required this.onRecovered,
  });

  final SharedPreferences prefs;
  final Object? error;
  final Future<ConnectionManager> Function(SharedPreferences)
  createConnectionManager;
  final ValueChanged<ConnectionManager> onRecovered;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: preferredSupportedLocales(),
      locale: LocalePreference.read(prefs),
      localeListResolutionCallback: resolvePreferredLocale,
      themeMode: ThemePreferenceStore(prefs).readMode(),
      theme: hermesTheme(
        Brightness.light,
        palette: ThemePreferenceStore(prefs).readPalette(),
      ),
      darkTheme: hermesTheme(
        Brightness.dark,
        palette: ThemePreferenceStore(prefs).readPalette(),
      ),
      builder: (context, child) => HermesSystemUi(child: child!),
      home: Builder(
        key: _rootKey,
        builder: (context) => Scaffold(
          body: Center(
            child: Padding(
              padding: const EdgeInsets.all(32),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.storage_rounded, size: 48),
                  const SizedBox(height: 16),
                  Text(
                    context.l10n.hermes_could_not_load_your_saved_connections,
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    context.l10n
                        .the_local_connection_store_looks_damaged_you_can_reset_the(
                          error.runtimeType,
                        ),
                    textAlign: TextAlign.center,
                    style: const TextStyle(fontSize: 13),
                  ),
                  const SizedBox(height: 24),
                  FilledButton.icon(
                    onPressed: () async {
                      try {
                        await ConnectionManager(prefs).resetConnections();
                        final retry = await createConnectionManager(prefs);
                        onRecovered(retry);
                      } catch (retryError) {
                        // Re-read the key after the await: the recovery
                        // screen may already have been replaced by the
                        // retried app.
                        final rootContext = _rootKey.currentContext;
                        if (rootContext != null) {
                          // The context is re-read from the root key after
                          // the await and null-checked immediately above.
                          // ignore: use_build_context_synchronously
                          ScaffoldMessenger.of(rootContext).showSnackBar(
                            SnackBar(
                              content: Builder(
                                builder: (snackContext) => Text(
                                  snackContext.l10n
                                      .reset_failed_the_secure_storage_may_need_reinstall(
                                        retryError,
                                      ),
                                ),
                              ),
                            ),
                          );
                        }
                      }
                    },
                    icon: const Icon(Icons.restart_alt),
                    label: Text(context.l10n.reset_saved_connections),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class HermesApp extends StatefulWidget {
  final ConnectionManager connManager;
  final AndroidShareIntentService? shareIntents;
  final AndroidLaunchIntentService? launchIntents;
  // Optional boundaries keep root tests on the real owner and dispatchers.
  final GatewayTurnApplicationController? turnApplicationController;
  final TurnNotificationService? notifications;
  final MobilePushService? mobilePush;
  final Future<void> Function()? loadBackgroundPolicy;
  final ApiClient Function(SavedConnection)? notificationClientFactory;

  @visibleForTesting
  final Future<Session?> Function(SavedConnection, String)?
  testNotificationSessionLookup;
  const HermesApp({
    required this.connManager,
    this.shareIntents,
    this.launchIntents,
    this.turnApplicationController,
    this.notifications,
    this.mobilePush,
    this.loadBackgroundPolicy,
    this.notificationClientFactory,
    this.testNotificationSessionLookup,
    super.key,
  });

  @override
  State<HermesApp> createState() => HermesAppState();

  static ThemeMode getThemeMode(SharedPreferences prefs) {
    return ThemePreferenceStore(prefs).readMode();
  }

  static Future<void> setThemeMode(
    SharedPreferences prefs,
    ThemeMode mode,
  ) async {
    await ThemePreferenceStore(prefs).saveMode(mode);
  }

  static HermesPalette getThemePalette(SharedPreferences prefs) {
    return ThemePreferenceStore(prefs).readPalette();
  }

  static TextSizePreference getTextSizePreference(SharedPreferences prefs) {
    return TextSizePreferenceStore(prefs).read();
  }
}

class HermesAppState extends State<HermesApp> with WidgetsBindingObserver {
  late final GatewayTurnApplicationController _turnApplicationController;
  late final AutoMessagingService _autoMessaging;
  late final TurnNotificationService _notifications;
  late final MobilePushService _mobilePush;
  late final void Function(NotificationResponse) _notificationHandler;
  bool? _confirmedBackgroundPolicy;
  bool get _backgroundPolicyReady => _confirmedBackgroundPolicy != null;
  bool _rootFrameReady = false;
  bool _pushRouting = false;
  bool _pushDirty = false;
  String? _pushHintsSignature;
  int _notificationGeneration = 0;

  /// Android foreground keep-alive: while the app is backgrounded with an
  /// unresolved chat turn, a foreground service holds the process so
  /// heartbeat timers keep firing and the WebSocket survives minimization.
  /// Bounded to active turns — an idle connection never earns a persistent
  /// notification.
  final ConnectionKeepAliveService _keepAlive = ConnectionKeepAliveService();

  Object? _keepAliveTurnActivityToken;
  bool _background = false;
  bool _closingTurnOwner = false;
  String? _ongoingSignature;
  final Set<String> _ongoingChats = {};
  Future<void> _ongoingWrites = Future<void>.value();

  /// Pushes from the app root (notification taps) need a navigator below the
  /// MaterialApp this state builds.
  final GlobalKey<NavigatorState> _navigatorKey = GlobalKey<NavigatorState>();

  /// The connection a notification response should prefer: the last one the
  /// user opened.
  static const String _lastConnectionKey = 'last_connection_id';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _turnApplicationController =
        widget.turnApplicationController ?? GatewayTurnApplicationController();
    _notifications = widget.notifications ?? TurnNotificationService.shared;
    _mobilePush = widget.mobilePush ?? MobilePushService.shared;
    _notificationHandler = _handleNotificationResponse;
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    _background = lifecycle != null && lifecycle != AppLifecycleState.resumed;
    // Unknown policy is disabled, including when mounted already paused. Set
    // this before Home creates/restores any normal owner or activity callback.
    _keepAlive.onPolicyChanged(false);
    _turnApplicationController.setLifecycle(
      background: _background,
      backgroundWorkEnabled: false,
    );
    _keepAlive.onAppLifecycleState(
      lifecycle ?? AppLifecycleState.resumed,
      hasActiveTurn: _hasActiveTurn,
    );
    // The keep-alive follows the work: a turn settling (or starting) while
    // backgrounded must end (or earn) the foreground service immediately,
    // not wait for the next resume.
    _keepAliveTurnActivityToken = _turnApplicationController
        .addTurnActivityListener(_onTurnActivityChanged);
    nextGenTurnActive.addListener(_onTurnActivityChanged);
    backgroundWorkEnabled.addListener(_onBackgroundWorkPolicyChanged);
    BackgroundWorkPrefsStore.pendingChoice.addListener(
      _onBackgroundWorkPolicyChanged,
    );
    BackgroundWorkPrefsStore.confirmedChanges.addListener(
      _onBackgroundWorkPolicyConfirmed,
    );
    notificationPrefs.addListener(_syncOngoingChats);
    _mobilePush.addListener(_onMobilePushChanged);
    _turnApplicationController.conversationTarget = (c, id) =>
        TurnNotificationService.conversationTarget(widget.connManager, c, id);
    _autoMessaging = AutoMessagingService(
      manager: widget.connManager,
      turns: _turnApplicationController,
      onOpen: (c, id) => _openNotificationSession(c, id),
    );
    _autoMessaging.initialize();
    notificationResponseHandler = _notificationHandler;
    ConnectionMutationBarrier.addListener(_pruneApprovalActions);
    // A notification that launched a terminated app carries its tap/action in
    // the platform's launch details; route it once the first frame is up.
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      final initialGeneration = _notificationGeneration;
      _rootFrameReady = true;
      unawaited(_loadBackgroundPolicy());
      unawaited(NotificationPrefsStore.load());
      unawaited(HandsFreePreferenceStore.load());
      _restoreNormalSessions();
      // The singleton is process-owned, not disposed with a replaceable root.
      unawaited(
        _mobilePush.initialize(widget.connManager).catchError((Object _) {}),
      );
      _onMobilePushChanged();
      unawaited(_initializeForegroundNotifications());
      final initial = await _notifications.takeInitialNotificationResponse();
      if (initial != null &&
          mounted &&
          initialGeneration == _notificationGeneration) {
        _notificationHandler(initial);
      }
    });
  }

  Future<void> _loadBackgroundPolicy() async {
    try {
      await (widget.loadBackgroundPolicy?.call() ??
          BackgroundWorkPrefsStore.load());
      if (!mounted || _closingTurnOwner) return;
      _confirmedBackgroundPolicy = BackgroundWorkPrefsStore.confirmedEnabled;
      _onBackgroundWorkPolicyChanged();
    } catch (_) {
      // Failure leaves protection disabled, not at a speculative default.
    }
  }

  /// A classic turn, or NextGen's open chat running (Kyllene's ChatService
  /// follows the open chat the same way).
  bool get _hasActiveTurn =>
      _turnApplicationController.hasActiveTurn || nextGenTurnActive.value;

  bool get _protectBackgroundWork =>
      _confirmedBackgroundPolicy == true &&
      !BackgroundWorkPrefsStore.pendingChoice.value &&
      backgroundWorkEnabled.value;

  Future<void> _initializeForegroundNotifications() async {
    await _notifications.ensureInitialized(refreshPermission: false);
    if (!mounted || _closingTurnOwner || _background) return;
    await _notifications.ensureInitialized(
      requestPermission: true,
      refreshPermission: false,
    );
    if (!mounted || _closingTurnOwner || _background) return;
    await _notifications.refreshAuthorization();
    if (!mounted || _closingTurnOwner) return;
    _ongoingSignature = null;
    _syncOngoingChats();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _background = false;
      _restoreNormalSessions();
      if (_rootFrameReady) {
        if (!_backgroundPolicyReady) unawaited(_loadBackgroundPolicy());
        unawaited(_initializeForegroundNotifications());
        _onMobilePushChanged();
      }
    } else if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden ||
        state == AppLifecycleState.detached) {
      _background = true;
    }
    _turnApplicationController.setLifecycle(
      background: _background,
      backgroundWorkEnabled: _protectBackgroundWork,
    );
    _syncOngoingChats();
    _keepAlive.onAppLifecycleState(state, hasActiveTurn: _hasActiveTurn);
  }

  void _pruneApprovalActions() {
    prunePendingNotificationApprovals();
  }

  void _restoreNormalSessions() {
    _pruneApprovalActions();
    final connections = widget.connManager.getConnections();
    for (final connection in connections) {
      if (DesktopGatewayClient.endpointDigestFor(connection) == null) continue;
      unawaited(
        _turnApplicationController
            .normalSessionFor(connection)
            .ready
            .catchError((Object _) {}),
      );
    }
    _turnApplicationController.retainConnections(
      connections.map((connection) => connection.id).toSet(),
    );
  }

  void _onTurnActivityChanged() {
    if (_closingTurnOwner) return;
    _keepAlive.onTurnActivityChanged(_hasActiveTurn);
    _syncOngoingChats();
  }

  void _onBackgroundWorkPolicyConfirmed() {
    if (!mounted || _closingTurnOwner) return;
    _confirmedBackgroundPolicy = BackgroundWorkPrefsStore.confirmedEnabled;
    _onBackgroundWorkPolicyChanged();
  }

  void _onBackgroundWorkPolicyChanged() {
    if (_closingTurnOwner) return;
    final enabled = _protectBackgroundWork;
    _keepAlive.onPolicyChanged(enabled);
    _turnApplicationController.setLifecycle(
      background: _background,
      backgroundWorkEnabled: enabled,
    );
    _syncOngoingChats();
  }

  void _syncOngoingChats() {
    if (_closingTurnOwner) return;
    final activities = _turnApplicationController.activeChatActivities.toList()
      ..sort(
        (a, b) => '${a.connectionId}:${a.localSessionId}'.compareTo(
          '${b.connectionId}:${b.localSessionId}',
        ),
      );
    final signature = jsonEncode([
      _background,
      _protectBackgroundWork,
      notificationPrefs.value.toJson(),
      for (final activity in activities)
        [
          activity.connectionId,
          activity.localSessionId,
          activity.storedSessionId,
          activity.title,
          activity.turnId,
          activity.status,
        ],
    ]);
    if (signature == _ongoingSignature) return;
    _ongoingSignature = signature;
    _ongoingWrites = _ongoingWrites
        .then((_) async {
          if (_closingTurnOwner) return;
          final service = _notifications;
          final current = _turnApplicationController.activeChatActivities
              .toList();
          final desired = <String>{};
          var failed = false;
          for (final activity in current.where(
            (_) =>
                _background &&
                _protectBackgroundWork &&
                notificationPrefs.value.enabled,
          )) {
            if (_closingTurnOwner) break;
            final key = jsonEncode([
              activity.connectionId,
              activity.localSessionId,
            ]);
            desired.add(key);
            // A platform call can post successfully and still fail its reply.
            // Own targeted cleanup before the await, not after the whole batch.
            _ongoingChats.add(key);
            try {
              await service.showOngoingChat(
                connectionId: activity.connectionId,
                localSessionId: activity.localSessionId,
                storedSessionId: activity.storedSessionId,
                title: activity.title,
                turnId: activity.turnId,
                status: activity.status,
              );
            } catch (_) {
              failed = true;
            }
          }
          for (final stale in _ongoingChats.difference(desired)) {
            if (!await _cancelTrackedOngoingChat(stale)) failed = true;
          }
          // Retry on a later reconciliation, even if its desired state is the
          // same. Never spin immediately on a failing platform implementation.
          if (failed && _ongoingSignature == signature) {
            _ongoingSignature = null;
          }
        })
        .catchError((Object _) {
          if (_ongoingSignature == signature) _ongoingSignature = null;
        });
  }

  Future<bool> _cancelTrackedOngoingChat(String key) async {
    try {
      final identity = jsonDecode(key) as List;
      await _notifications.cancelOngoingChat(
        connectionId: identity[0] as String,
        localSessionId: identity[1] as String,
      );
      _ongoingChats.remove(key);
      return true;
    } catch (_) {
      // Keep both root ownership and the service's durable numeric index for
      // retry. One failed cancellation must not abandon its siblings.
      return false;
    }
  }

  /// The connection a notification response should act on: the last one the
  /// user opened, or the only configured one.
  SavedConnection? _notificationConnection() {
    final connections = widget.connManager.getConnections();
    final lastId = widget.connManager.prefs.getString(_lastConnectionKey);
    final preferred = connections
        .where((connection) => connection.id == lastId)
        .firstOrNull;
    return preferred ?? (connections.length == 1 ? connections.single : null);
  }

  void _onMobilePushChanged() {
    if (!_rootFrameReady || !mounted || _closingTurnOwner) return;
    // Hints only reconcile an already-owned turn. They never submit a prompt,
    // answer an input request or create/navigate to an arbitrary session.
    final signature = jsonEncode([
      _mobilePush.connectionId,
      _mobilePush.events,
    ]);
    if (_pushHintsSignature != signature) {
      _pushHintsSignature = signature;
      final connection = _connectionById(_mobilePush.connectionId);
      if (connection != null && _mobilePush.active) {
        final normal = _turnApplicationController.normalSessionFor(connection);
        unawaited(
          normal.ready
              .then<void>((_) {
                if (!mounted ||
                    _closingTurnOwner ||
                    _pushHintsSignature != signature ||
                    !_mobilePush.active ||
                    !_connectionIsCurrent(connection)) {
                  return;
                }
                for (final event in _mobilePush.events) {
                  final id = event['session_id'];
                  if (id is String) normal.findChat(id)?.requestRecovery();
                }
              })
              .catchError((Object _) {}),
        );
      }
    }
    if (_background) return; // Retain taps until foreground navigation is safe.
    if (_pushRouting && _mobilePush.hasPendingTap) ++_notificationGeneration;
    _pushDirty = true;
    if (_pushRouting) return;
    unawaited(_drainPushRoutes());
  }

  Future<void> _drainPushRoutes() async {
    _pushRouting = true;
    try {
      while (_pushDirty && mounted && !_closingTurnOwner && !_background) {
        _pushDirty = false;
        final generation = _notificationGeneration;
        final route = await _mobilePush.takePendingNotificationRoute();
        if (!mounted || _closingTurnOwner) return;
        if (generation != _notificationGeneration) continue;
        if (route == null) continue;
        // Transfer the consumed tap into root intent before checking lifecycle.
        // The navigation worker validates consent, including after resume.
        await _openNotificationSession(
          route.connection,
          route.sessionId,
          pushRoute: route,
        );
      }
    } catch (_) {
      // Optional native push failure must not break normal notification taps.
    } finally {
      _pushRouting = false;
      if (_pushDirty && mounted && !_closingTurnOwner && !_background) {
        _onMobilePushChanged();
      }
    }
  }

  bool _connectionIsCurrent(SavedConnection connection) {
    final current = _connectionById(connection.id);
    // getConnections hydrates fresh objects. Bind the complete saved account,
    // including credentials/profile, rather than testing object identity.
    return current != null &&
        MobilePushService.binding(current) ==
            MobilePushService.binding(connection);
  }

  /// Routes a notification tap (or one of its action buttons) into NextGen.
  void _handleNotificationResponse(NotificationResponse response) {
    if (!mounted || _closingTurnOwner) return;
    final route = NotificationRoute.fromResponse(response);
    final hasExplicitConnection =
        route.connectionId != null && route.connectionId!.isNotEmpty;
    final connection = hasExplicitConnection
        ? _connectionById(route.connectionId)
        : _notificationConnection();
    if (connection == null) return;
    // NextGen answers an approval button on its own socket; a body tap only
    // opens the chat.
    if (routeNotificationAnswerToNextGen(
      connectionId: connection.id,
      sessionId: route.sessionId,
      requestId: route.requestId,
      choice: route.approvalChoice,
    )) {
      routeNotificationToNextGen(connection.id, route.sessionId);
      return;
    }
    routeNotificationToNextGen(connection.id, route.sessionId);
  }

  /// The connection a payload names, or null when it no longer exists.
  SavedConnection? _connectionById(String? id) {
    if (id == null || id.isEmpty) return null;
    return widget.connManager
        .getConnections()
        .where((connection) => connection.id == id)
        .firstOrNull;
  }

  /// Opens the chat a notification was about in NextGen.
  Future<void> _openNotificationSession(
    SavedConnection connection,
    String? sessionId, {
    MobilePushRoute? pushRoute,
  }) async {
    if (!mounted ||
        _closingTurnOwner ||
        ConnectionMutationBarrier.isPending(connection.id) ||
        !_connectionIsCurrent(connection)) {
      return;
    }
    if (pushRoute != null) {
      final valid = await _mobilePush.isRouteCurrent(pushRoute);
      if (!valid || !mounted || _closingTurnOwner) return;
    }
    routeNotificationToNextGen(connection.id, sessionId);
  }

  Future<void> setTextSizePreference(TextSizePreference preference) async {
    await TextSizePreferenceStore(widget.connManager.prefs).save(preference);
    if (mounted) setState(() {});
  }

  Future<void> setThemePalette(HermesPalette palette) async {
    try {
      await ThemePreferenceStore(widget.connManager.prefs).savePalette(palette);
    } finally {
      refreshAppearancePreferences();
    }
  }

  Future<void> setLocale(Locale? locale) async {
    await LocalePreference.save(widget.connManager.prefs, locale);
    refreshAppearancePreferences();
  }

  Future<void> setThemeMode(ThemeMode mode) async {
    try {
      await ThemePreferenceStore(widget.connManager.prefs).saveMode(mode);
    } finally {
      refreshAppearancePreferences();
    }
  }

  /// Re-read preferences after a backup import without replacing the Navigator.
  void refreshAppearancePreferences() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: NextGenLook.instance,
      builder: (context, _) => _buildApp(context),
    );
  }

  Widget _buildApp(BuildContext context) {
    final look = NextGenLook.instance;
    return MaterialApp(
      navigatorKey: _navigatorKey,
      navigatorObservers: [handsFreeRouteObserver],
      onGenerateTitle: (context) => context.l10n.hermes_agent,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: preferredSupportedLocales(),
      locale: LocalePreference.read(widget.connManager.prefs),
      localeListResolutionCallback: resolvePreferredLocale,
      themeMode: look.themeMode,
      theme: nextGenTheme(Brightness.light, look),
      darkTheme: nextGenTheme(Brightness.dark, look),
      builder: (context, child) {
        final systemMediaQuery = MediaQuery.of(context);
        final preference = HermesApp.getTextSizePreference(
          widget.connManager.prefs,
        );
        return HermesSystemUi(
          child: MediaQuery(
            data: systemMediaQuery.copyWith(
              textScaler: preference.applyTo(systemMediaQuery.textScaler),
            ),
            child: NgLocalizationScope(child: child!),
          ),
        );
      },
      home: NextGenHome(connManager: widget.connManager),
    );
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    final token = _keepAliveTurnActivityToken;
    _closingTurnOwner = true;
    _autoMessaging.dispose();
    ConnectionMutationBarrier.removeListener(_pruneApprovalActions);
    prunePendingNotificationApprovals();
    ++_notificationGeneration;
    _mobilePush.removeListener(_onMobilePushChanged);
    // Do not dispose MobilePushService.shared: a root remount must still work.
    notificationPrefs.removeListener(_syncOngoingChats);
    if (identical(notificationResponseHandler, _notificationHandler)) {
      notificationResponseHandler = null;
    }
    nextGenTurnActive.removeListener(_onTurnActivityChanged);
    backgroundWorkEnabled.removeListener(_onBackgroundWorkPolicyChanged);
    BackgroundWorkPrefsStore.pendingChoice.removeListener(
      _onBackgroundWorkPolicyChanged,
    );
    BackgroundWorkPrefsStore.confirmedChanges.removeListener(
      _onBackgroundWorkPolicyConfirmed,
    );
    if (token != null) {
      _turnApplicationController.removeTurnActivityListener(token);
      _keepAliveTurnActivityToken = null;
    }
    // Belt for the detached case: if the widget tree tears down while the
    // service is up, the native side must not outlive its only controller.
    unawaited(_keepAlive.stop());
    unawaited(_turnApplicationController.close());
    unawaited(
      _ongoingWrites
          .then<void>((_) async {
            for (final key in _ongoingChats.toList()) {
              await _cancelTrackedOngoingChat(key);
            }
          })
          .catchError((Object _) {}),
    );
    super.dispose();
  }
}
