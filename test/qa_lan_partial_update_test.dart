// انحدار: عملية "تعديل" جزئية تصل لجهاز لا يملك الكيان أصلاً.
//
// السيناريو الحقيقي (جهاز مدير + جهاز إدخال): جهاز الإدخال يبيع صنفًا فيرسل
// عملية {تعديل صنف: الكمية فقط}. إن لم يكن الصنف موجودًا لدى المستقبل
// (اقتران قبل نقل اللقطة، أو صنف أُنشئ قبل تفعيل LAN فلا توجد له عملية إنشاء)
// كان الإدراج يكسر قيد NOT NULL (name, created_at غائبة) فيرد المستقبل
// HTTP 500 'internal' وتعلق كل قائمة المزامنة في إعادة محاولة أبدية —
// كما في شاشة «العمليات المتزامنة: Bad state: DEVICE-…: internal».
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nexora_app/core/database.dart';
import 'package:nexora_app/data/repository.dart';
import 'package:nexora_app/data/sync/lan_http_transport.dart';
import 'package:nexora_app/data/sync/operation.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  late Directory tmp;
  late Database recvDb;
  late Repo recvRepo;
  late LanSyncService receiver;
  late int port;
  const senderId = 'DEVICE-QASENDER';
  const recvId = 'DEVICE-QARECV';
  const senderSecret = 'qa-sender-secret';
  final now = DateTime(2026, 9, 8);

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('nexora_partial_');
    recvDb = await databaseFactory.openDatabase('${tmp.path}/recv.db');
    await AppDatabase.createSchema(recvDb);
    recvRepo = Repo(databaseProvider: () async => recvDb);
    await recvRepo.setSetting('sync.deviceId', recvId);
    await recvRepo.initSyncInfra();
    final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    port = socket.port;
    await socket.close();
    await recvDb.insert('devices', {
      'id': senderId,
      'workspace_id': 'default',
      'name': 'sender',
      'auth_secret': senderSecret,
      'is_paired': 1,
      'ip_address': '127.0.0.1',
      'port': port,
      'user_id': 1,
      'created_at': now.toIso8601String(),
      'updated_at': now.toIso8601String(),
    });
    receiver = LanSyncService(
        repo: recvRepo,
        dbProvider: () async => recvDb,
        ourDeviceId: recvId,
        port: port);
    await receiver.startServer();
  });

  tearDown(() async {
    await receiver.stopServer();
    await recvDb.close();
    await tmp.delete(recursive: true);
  });

  Future<(int, Map)> post(SyncOperation op) async {
    final client = HttpClient();
    try {
      final request =
          await client.postUrl(Uri.parse('http://127.0.0.1:$port/ops'));
      request.headers.set('Authorization', 'Bearer $senderSecret');
      request.headers.contentType = ContentType.json;
      request.write(op.toJson());
      final response = await request.close();
      final body = await response.transform(utf8.decoder).join();
      return (response.statusCode, jsonDecode(body) as Map);
    } finally {
      client.close(force: true);
    }
  }

  test('تعديل جزئي لصنف غير موجود يُدرَج بقيم افتراضية بدل فشل internal',
      () async {
    final op = SyncOperation(
      id: 'op-partial-item-1',
      deviceId: senderId,
      workspaceId: 'default',
      userId: 1,
      entityType: EntityKind.item,
      entityId: '77',
      opType: OpKind.update,
      version: 2,
      parentOpId: '',
      payload: {'id': 77, 'quantity': 9.0, 'updated_at': now.toIso8601String()},
      deviceTime: now.toIso8601String(),
      timestamp: now.toIso8601String(),
    );
    final (status, body) = await post(op);
    expect(status, HttpStatus.ok, reason: 'كان يفشل بـ 500 internal: $body');
    expect(body['applied'], 1);
    final rows =
        await recvDb.query('items', where: 'id = ?', whereArgs: [77]);
    expect(rows, hasLength(1));
    expect(rows.first['quantity'], 9.0);
    // الأعمدة الإلزامية استُكملت بقيم آمنة ولم تكسر القيود.
    expect(rows.first['name'], isNotNull);
    expect(rows.first['created_at'], isNotNull);
  });

  test('فشل حقيقي يعيد سبباً واضحاً بدل كلمة internal', () async {
    // عملية بنوع كيان currency تحمل entity_id طويلاً مع payload يخرق قيد
    // الجدول عمداً (code فارغ ليس السبب — نتحقق فقط أن error != internal
    // عند حدوث فشل). أبسط طريق: عملية تعديل إعداد بجدول سليم تنجح — لذلك
    // نتأكد هنا من دالة التنظيف نفسها.
    expect(sanitizeSyncError(StateError('boom')), 'boom');
    expect(
      sanitizeSyncError(Exception('a' * 300)).length,
      lessThanOrEqualTo(140),
    );
    expect(sanitizeSyncError(FormatException('bad json')),
        startsWith('format:'));
  });
}
