import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:warningapplication_1/services/app_settings_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
  });

  test('default values should all be off', () async {
    final settings = AppSettingsService.instance;

    await settings.load();

    expect(settings.floatingOverlayEnabled, isFalse);
    expect(settings.homeWarningEnabled, isFalse);
    expect(settings.voiceBroadcastEnabled, isFalse);
  });
}
