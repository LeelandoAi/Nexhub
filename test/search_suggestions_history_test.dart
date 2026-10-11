// 搜索建议面板交互测试：清空全部历史、长按删除单条历史。
// 热词仓库用预置的「上次成功缓存 + 新鲜时间戳」喂给单例，避免测试触网。
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:nexhub/core/models/plugin_config.dart';
import 'package:nexhub/core/search/search_history_store.dart';
import 'package:nexhub/core/widgets/search_suggestions.dart';
import 'package:nexhub/generated/app_localizations.dart';
import 'package:shared_preferences/shared_preferences.dart';

Future<void> _pump(WidgetTester tester, SearchHistoryStore store) async {
  await tester.pumpWidget(MaterialApp(
    locale: const Locale('zh'),
    supportedLocales: AppLocalizations.supportedLocales,
    // 与 lib/app.dart / 既有 widget 测试同款：GlobalMaterialLocalizations
    // 须经 material_ui 分叉导出（fork 的 MaterialLocalizations 类型）。
    localizationsDelegates: const <LocalizationsDelegate<dynamic>>[
      AppLocalizations.delegate,
      ...GlobalMaterialLocalizations.delegates,
    ],
    home: Scaffold(
      body: SearchSuggestions(
        sourceType: SourceType.animeSource,
        historyStore: store,
        onKeywordTap: (_) {},
      ),
    ),
  ));
  await tester.pumpAndSettle();
}

void main() {
  setUp(() async {
    // 预置热词缓存与新鲜时间戳：TTL 内不触发远程刷新（测试零网络）。
    SharedPreferences.setMockInitialValues(<String, Object>{
      'hot_search_keywords_remote_cache_v1':
          jsonEncode(<String, List<String>>{
        'animeSource': <String>['热词样本'],
      }),
      'hot_search_keywords_last_fetch_v1':
          DateTime.now().millisecondsSinceEpoch,
    });
  });

  testWidgets('清空全部搜索历史', (tester) async {
    final store = SearchHistoryStore(SourceType.animeSource);
    await store.add('进击的巨人');
    await store.add('咒术回战');
    await _pump(tester, store);
    expect(find.text('咒术回战'), findsOneWidget);
    expect(find.text('热词样本'), findsOneWidget);

    await tester.tap(find.text('清空历史'));
    await tester.pumpAndSettle();
    expect(find.text('确定清空所有搜索历史？'), findsOneWidget);
    await tester.tap(find.text('确认'));
    await tester.pumpAndSettle();

    expect(await store.load(), isEmpty);
    expect(find.text('暂无搜索历史'), findsOneWidget);
    expect(find.text('咒术回战'), findsNothing);
  });

  testWidgets('长按历史胶囊删除单条', (tester) async {
    final store = SearchHistoryStore(SourceType.animeSource);
    await store.add('进击的巨人');
    await store.add('咒术回战');
    await _pump(tester, store);

    await tester.longPress(find.text('咒术回战'));
    await tester.pumpAndSettle();
    expect(find.text('删除这条搜索历史？'), findsOneWidget);
    await tester.tap(find.text('确认'));
    await tester.pumpAndSettle();

    expect(await store.load(), <String>['进击的巨人']);
    expect(find.text('咒术回战'), findsNothing);
    expect(find.text('进击的巨人'), findsOneWidget);
  });
}
