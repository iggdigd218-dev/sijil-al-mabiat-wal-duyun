// QA — الربط السحابي التلقائي الافتراضي (Zero-Config Cloud Onboarding).
//
// يوثّق العقد: رابط مخصص في الإعدادات يتقدم دائماً؛ الفراغ يتراجع إلى
// الرابط الرسمي المضمّن؛ وتجاوز الاختبارات يحاكي «لا سحابة».
import 'package:flutter_test/flutter_test.dart';
import 'package:nexora_app/core/cloud_config.dart';
import 'package:nexora_app/data/sync/workspace_service.dart';

void main() {
  tearDown(() => debugDefaultBackendUrlOverride = null);

  test('CLOUD-CFG-01 الرابط الافتراضي مثبت على مشروع Firebase الرسمي', () {
    expect(kDefaultCloudBackendUrl,
        'https://nexora-ledger-default-rtdb.europe-west1.firebasedatabase.app');
    expect(kDefaultCloudBackendUrl, startsWith('https://'));
  });

  test('CLOUD-CFG-02 فارغ/null/مسافات ⇒ التراجع للرابط الرسمي', () {
    expect(effectiveBackendUrl(null), kDefaultCloudBackendUrl);
    expect(effectiveBackendUrl(''), kDefaultCloudBackendUrl);
    expect(effectiveBackendUrl('   '), kDefaultCloudBackendUrl);
  });

  test('CLOUD-CFG-03 الرابط المخصص يتقدم على الافتراضي (مع التشذيب)', () {
    expect(effectiveBackendUrl('https://custom.example.com'),
        'https://custom.example.com');
    expect(effectiveBackendUrl('  https://custom.example.com  '),
        'https://custom.example.com');
    // الشرطة النهائية تُطبَّع — تمنع // المزدوجة في مسارات SSE (كانت 404).
    expect(effectiveBackendUrl('https://custom.example.com/'),
        'https://custom.example.com');
  });

  test('CLOUD-CFG-05 معرف المساحة الفريد: WS- + 8 خانات آمنة وبلا تكرار', () {
    final seen = <String>{};
    for (var i = 0; i < 200; i++) {
      final id = generateWorkspaceId();
      expect(RegExp(r'^WS-[A-HJ-KM-NP-Z2-9]{8}$').hasMatch(id), isTrue,
          reason: 'صيغة غير صالحة: $id');
      seen.add(id);
    }
    expect(seen.length, 200); // لا تصادم في 200 توليدة.
    expect(isLegacyWorkspaceId('default'), isTrue);
    expect(isLegacyWorkspaceId(''), isTrue);
    expect(isLegacyWorkspaceId(generateWorkspaceId()), isFalse);
  });

  test('CLOUD-CFG-04 تجاوز الاختبارات يحاكي «لا سحابة» ثم يعود طبيعياً', () {
    debugDefaultBackendUrlOverride = '';
    expect(effectiveBackendUrl(null), '');
    expect(effectiveBackendUrl('https://x.example.com'),
        'https://x.example.com'); // المخصص لا يتأثر بالتجاوز.
    debugDefaultBackendUrlOverride = null;
    expect(effectiveBackendUrl(null), kDefaultCloudBackendUrl);
  });
}
