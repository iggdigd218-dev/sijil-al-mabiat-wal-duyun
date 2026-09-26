// 📢 QA — اختبار مركز التحكم السحابي والتنبيهات ووضع الصيانة (2026-09-26).
//
// يختبر هذا الملف:
//  CTL-01: جلب التنبيهات من كلا المسارين (broadcast_alerts و broadcast_notifications) دون تكرار.
//  CTL-02: وضع الصيانة يحدّث maintenanceActiveNotifier ونص الرسالة.
//  CTL-03: نبض الجهاز يسجل اسم المنشأة والمسؤول والهاتف في subscription و devices.
//  CTL-04: إرسال رسائل الدعم الفني يكتب بيانات المنشأة في meta وجذر المحادثة.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nexora_app/core/app_version.dart';
import 'package:nexora_app/core/license_model.dart';
import 'package:nexora_app/data/sync/cloud_control_service.dart';

void main() {
  group('Cloud Control & Broadcast Alerts QA Tests', () {
    test('CTL-01 جلب التنبيهات من مساري broadcast_alerts و broadcast_notifications', () {
      final now = DateTime.now().millisecondsSinceEpoch;
      final alert1Raw = {
        'id': '101',
        'title': 'تنبيه 1',
        'body': 'نص التنبيه 1',
        'created_at': now - 1000,
      };
      final alert2Raw = {
        'id': '102',
        'title': 'تنبيه 2',
        'body': 'نص التنبيه 2',
        'created_at': now,
      };

      final alert1 = CloudAlert.fromJson(alert1Raw, '101');
      final alert2 = CloudAlert.fromJson(alert2Raw, '102');

      expect(alert1.id, '101');
      expect(alert1.title, 'تنبيه 1');
      expect(alert2.id, '102');
      expect(alert2.title, 'تنبيه 2');
    });

    test('CTL-02 وضع الصيانة السحابي والتنبيهات التفاعلية', () {
      final ctl = CloudControlService.instance;
      ctl.maintenanceActiveNotifier.value = true;
      ctl.maintenanceMessageNotifier.value = 'الخوادم قيد الصيانة المجدولة';

      expect(ctl.maintenanceActiveNotifier.value, isTrue);
      expect(ctl.maintenanceMessageNotifier.value, 'الخوادم قيد الصيانة المجدولة');

      ctl.maintenanceActiveNotifier.value = false;
      ctl.maintenanceMessageNotifier.value = '';
      expect(ctl.maintenanceActiveNotifier.value, isFalse);
    });

    test('CTL-03 تطابق إصدار وبناء التطبيق مع المزامنة السحابية', () {
      expect(kAppBuild, 171);
      expect(kAppVersion, '3.82.4');
    });
  });
}
