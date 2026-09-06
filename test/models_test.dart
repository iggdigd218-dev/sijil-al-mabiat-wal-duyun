import 'package:flutter_test/flutter_test.dart';

import 'package:nexora_app/core/format.dart';
import 'package:nexora_app/core/models.dart';

void main() {
  group('Fmt.phoneDigits', () {
    test('يزيل الرموز ويترك الأرقام فقط', () {
      expect(Fmt.phoneDigits('+967 777-123-456'), '967777123456');
      expect(Fmt.phoneDigits('(777) 123 456'), '777123456');
      expect(Fmt.phoneDigits(''), '');
    });
  });

  group('Tx defaults', () {
    test('syncState افتراضياً synced', () {
      final now = DateTime.now();
      final tx = Tx(
        type: OpType.inflow,
        amount: 1000,
        date: now,
        createdAt: now,
        updatedAt: now,
      );
      expect(tx.syncState, 'synced');
      expect(tx.status, 'done');
    });

    test('copyWith syncState', () {
      final now = DateTime.now();
      final tx = Tx(
        type: OpType.debit,
        amount: 500,
        date: now,
        createdAt: now,
        updatedAt: now,
      );
      final tx2 = tx.copyWith(syncState: 'pending');
      expect(tx2.syncState, 'pending');
      expect(tx2.amount, 500);
    });

    test('toMap/fromMap roundtrip', () {
      final now = DateTime.parse('2026-09-06T02:00:00Z');
      final tx = Tx(
        type: OpType.revenue,
        amount: 15000,
        date: now,
        createdAt: now,
        updatedAt: now,
        reference: '123',
        syncState: 'pending',
        description: 'فاتورة تجريبية',
      );
      final m = tx.toMap();
      expect(m['sync_state'], 'pending');
      final back = Tx.fromMap({...m, 'id': 1});
      expect(back.syncState, 'pending');
      expect(back.amount, 15000);
      expect(back.reference, '123');
    });
  });
}
