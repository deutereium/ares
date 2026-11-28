import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/app_update_service.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test('Play builds never contact the GitHub APK updater', () async {
    expect(AppUpdateService.isPlayBuild, isTrue);
    // This opt-in suite intentionally lives outside test/ so the ordinary
    // suite runs it only with ARES_PLAY_BUILD=true.
    // ignore: invalid_use_of_visible_for_testing_member
    SharedPreferences.setMockInitialValues({});
    var requests = 0;
    final client = MockClient((request) async {
      requests++;
      return http.Response('{}', 500);
    });
    final preferences = await SharedPreferences.getInstance();
    final service = AppUpdateService(client: client, preferences: preferences);
    final result = await service.checkForUpdate(
      currentVersion: '4.0.0',
      force: true,
    );
    expect(result.outcome, AppUpdateOutcome.failed);
    expect(await service.launchPromptRelease(currentVersion: '4.0.0'), isNull);
    expect(await service.checkOnLaunchEnabled(), isFalse);
    expect(requests, 0);
    client.close();
  });
}
