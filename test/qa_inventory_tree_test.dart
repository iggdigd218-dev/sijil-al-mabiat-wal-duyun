// QA — (2026-09-22) شجرة فئات الأصناف + نموذج الفئة
//  TREE : فئة رئيسية ← فئات فرعية (parent_id) مع استعلام جذور/أبناء.
//  MODEL: ItemCategory يحمل parentId والأبناء، ويُدار بلا فقدان بيانات.
//  DEL  : حذف فئة رئيسية يُرقّي أبناءها للجذر بدل محوهم.
//  SYNC : تعديل الفئة يُسجَّل عبر SyncRecorder بـ EntityKind.itemCategory.
import 'package:flutter_test/flutter_test.dart';
import 'package:nexora_app/core/database.dart';
import 'package:nexora_app/core/models.dart';
import 'package:nexora_app/data/repository.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  late Repo repo;
  setUp(() async {
    final db = await databaseFactory.openDatabase(inMemoryDatabasePath,
        options: OpenDatabaseOptions(
            onConfigure: (d) => d.execute('PRAGMA foreign_keys = ON')));
    await AppDatabase.createSchema(db);
    await AppDatabase.migrateToV23(db); // عمود parent_id + فهرسه
    // القاعدة في الذاكرة تُشارَك بين الاختبارات في العملية نفسها — نبدأ
    // كل اختبار من صفحة بيضاء لئلا تتسرب بيانات اختبار إلى آخر.
    await db.delete('item_categories');
    await db.delete('items');
    await db.delete('operations');
    repo = Repo(databaseProvider: () async => db);
    await repo.initSyncInfra();
  });

  ItemCategory cat(String name, {int? parentId}) => ItemCategory(
        name: name,
        parentId: parentId,
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      );

  test('TREE-01 عمود parent_id موجود ومُفهرس بعد الترقية', () async {
    final db = await repo.database;
    final cols = await db.rawQuery('PRAGMA table_info(item_categories)');
    final names = cols.map((c) => '${c['name']}').toSet();
    expect(names.contains('parent_id'), isTrue);
    final idx = await db.rawQuery("PRAGMA index_list('item_categories')");
    expect(
      idx.map((r) => '${r['name']}').toSet().contains('idx_item_cat_parent'),
      isTrue,
    );
  });

  test('TREE-02 الشجرة: جذور وأبناء، والجذر بلا أب', () async {
    final rootId = await repo.saveItemCategory(cat('مواد غذائية'));
    final subId = await repo.saveItemCategory(cat('ألبان', parentId: rootId));
    await repo.saveItemCategory(cat('معلبات', parentId: rootId));
    await repo.saveItemCategory(cat('أجهزة')); // جذر ثانٍ

    final roots = await repo.itemCategories(rootsOnly: true);
    expect(roots.map((c) => c.name).toList(), contains('مواد غذائية'));
    expect(roots.any((c) => c.name == 'ألبان'), isFalse,
        reason: 'الابن ليس جذراً');

    final children = await repo.itemCategories(parentId: rootId);
    expect(children.map((c) => c.name).toSet(), {'ألبان', 'معلبات'});
    expect(children.first.parentId, rootId);

    final tree = await repo.itemCategoryTree();
    final food = tree.firstWhere((c) => c.id == rootId);
    expect(food.children.length, 2, reason: 'الأبناء مُجمَّعون في الشجرة');
    expect(tree.any((c) => c.name == 'ألبان'), isFalse);
    expect(subId, isNotNull);
  });

  test('TREE-03 الفئة القديمة بلا أب تُعدّ جذراً (لا فقدان بيانات)', () async {
    final id = await repo.saveItemCategory(cat('قديمة'));
    final all = await repo.itemCategories();
    final c = all.firstWhere((e) => e.id == id);
    expect(c.parentId, isNull);
    expect(c.isRoot, isTrue);
    expect((await repo.itemCategories(rootsOnly: true)).length,
        all.length,
        reason: 'كل الفئات القديمة جذور');
  });

  test('TREE-04 منع الدوران: الفئة لا تكون أباً لنفسها ولا لفرعها', () async {
    final a = await repo.saveItemCategory(cat('أ'));
    final b = await repo.saveItemCategory(cat('ب', parentId: a));

    final all = await repo.itemCategories();
    final catA = all.firstWhere((c) => c.id == a);
    expect(
      () => repo.saveItemCategory(catA.copyWith(parentId: a)),
      throwsA(isA<StateError>()),
      reason: 'الفئة لا تكون أباً لنفسها',
    );
    expect(
      () => repo.saveItemCategory(catA.copyWith(parentId: b)),
      throwsA(isA<StateError>()),
      reason: 'الأب لا يصبح فرعاً لابنه',
    );
  });

  test('TREE-05 حذف فئة رئيسية يُرقّي أبناءها للجذر', () async {
    final rootId = await repo.saveItemCategory(cat('رئيسية'));
    final subId = await repo.saveItemCategory(cat('فرعية', parentId: rootId));
    await repo.deleteItemCategory(rootId);

    final sub = (await repo.itemCategories()).firstWhere((c) => c.id == subId);
    expect(sub.parentId, isNull, reason: 'الابن بقي ولم يُمحَ (صار جذراً)');
    expect(await repo.itemCategories(rootsOnly: true), isNotEmpty);
  });

  test('TREE-06 تعديل الفئة يُسجَّل للمزامنة بـ EntityKind.itemCategory',
      () async {
    final id = await repo.saveItemCategory(cat('فئة للمزامنة'));
    final db = await repo.database;
    final ops = await db.query('operations',
        where: 'entity_type = ? AND entity_id = ?',
        whereArgs: ['itemCategory', '$id']);
    expect(ops, isNotEmpty, reason: 'عملية إنشاء مسجلة عبر SyncRecorder');

    await repo.saveItemCategory(
      (await repo.itemCategories())
          .firstWhere((c) => c.id == id)
          .copyWith(name: 'فئة معدّلة'),
    );
    final after = await db.query('operations',
        where: 'entity_type = ? AND entity_id = ?',
        whereArgs: ['itemCategory', '$id']);
    expect(after.length, greaterThan(ops.length),
        reason: 'عملية تعديل ثانية مسجلة');
  });

  test('TREE-07 النموذج: parentId يكتمل في toMap/fromMap', () {
    final now = DateTime.now();
    final c = ItemCategory(
        id: 5, name: 'ابن', parentId: 2, createdAt: now, updatedAt: now);
    final map = c.toMap();
    expect(map['parent_id'], 2);
    final back = ItemCategory.fromMap(map);
    expect(back.parentId, 2);
    expect(back.name, 'ابن');
    // clearParentId يعيدها جذراً
    expect(c.copyWith(clearParentId: true).parentId, isNull);
  });
}
