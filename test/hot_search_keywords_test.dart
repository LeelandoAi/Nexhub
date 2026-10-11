// 搜索热词解析单测：远程/打包资源共用的 parseKeywordsJson 容错规则，
// 以及 Bangumi 实时热门兜底的词提取与查询阶梯。
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:nexhub/core/models/plugin_config.dart';
import 'package:nexhub/core/search/hot_search_keywords.dart';
import 'package:nexhub/core/services/bangumi/bangumi_models.dart';

BangumiSubject _subject({
  required int id,
  required String name,
  String nameCn = '',
  bool nsfw = false,
}) =>
    BangumiSubject(id: id, name: name, nameCn: nameCn, type: 2, nsfw: nsfw);

void main() {
  group('HotSearchKeywords.parseKeywordsJson', () {
    test('解析标准结构（按模块分组）', () {
      final raw = jsonEncode({
        'animeSource': ['进击的巨人', '咒术回战'],
        'mangaSource': ['海贼王'],
      });
      final parsed = HotSearchKeywords.parseKeywordsJson(raw);
      expect(parsed['animeSource'], ['进击的巨人', '咒术回战']);
      expect(parsed['mangaSource'], ['海贼王']);
    });

    test('过滤空串与非字符串项', () {
      final raw = jsonEncode({
        'animeSource': ['  ', ' valid ', 123, null, 'ok'],
      });
      final parsed = HotSearchKeywords.parseKeywordsJson(raw);
      expect(parsed['animeSource'], ['valid', 'ok']);
    });

    test('去重且保持出现顺序', () {
      final raw = jsonEncode({
        'novelSource': ['诡秘之主', '诡秘之主', ' 遮天 ', '遮天'],
      });
      final parsed = HotSearchKeywords.parseKeywordsJson(raw);
      expect(parsed['novelSource'], ['诡秘之主', '遮天']);
    });

    test('单模块截断到上限', () {
      final raw = jsonEncode({
        'animeSource': List<String>.generate(
          HotSearchKeywords.maxKeywordsPerModule + 10,
          (i) => '词$i',
        ),
      });
      final parsed = HotSearchKeywords.parseKeywordsJson(raw);
      expect(
        parsed['animeSource']!.length,
        HotSearchKeywords.maxKeywordsPerModule,
      );
    });

    test('非法 JSON / 非 Map / 空列表模块返回空表', () {
      expect(HotSearchKeywords.parseKeywordsJson('not json'), isEmpty);
      expect(HotSearchKeywords.parseKeywordsJson('[1,2,3]'), isEmpty);
      expect(
        HotSearchKeywords.parseKeywordsJson(jsonEncode({'animeSource': []})),
        isEmpty,
      );
    });
  });

  group('HotSearchKeywords.subjectsToWords（Bangumi 实时热门兜底）', () {
    test('中文名优先，缺省回退原名', () {
      final words = HotSearchKeywords.subjectsToWords([
        _subject(id: 1, name: 'Frieren', nameCn: '葬送的芙莉莲'),
        _subject(id: 2, name: ' gardeN '), // 无中文名，trim 后取原名
      ]);
      expect(words, ['葬送的芙莉莲', 'gardeN']);
    });

    test('过滤 R18、空名与重复', () {
      final words = HotSearchKeywords.subjectsToWords([
        _subject(id: 1, name: '一般条目', nsfw: true),
        _subject(id: 2, name: '   '),
        _subject(id: 3, name: '咒术回战'),
        _subject(id: 4, name: 'X', nameCn: '咒术回战'),
      ]);
      expect(words, ['咒术回战']);
    });

    test('截断到单模块上限', () {
      final subjects = List<BangumiSubject>.generate(
        HotSearchKeywords.maxKeywordsPerModule + 5,
        (i) => _subject(id: i, name: '条目$i'),
      );
      expect(
        HotSearchKeywords.subjectsToWords(subjects).length,
        HotSearchKeywords.maxKeywordsPerModule,
      );
    });
  });

  group('HotSearchKeywords.bangumiLadderFor（候选阶梯）', () {
    test('动画：先 /anime 注目榜，再近半年新番（heat），最后全站热门', () {
      final steps = HotSearchKeywords.bangumiLadderFor(
        SourceType.animeSource,
        DateTime(2026, 10, 11),
      );
      expect(steps.first.featuredChannel, '/anime');
      final recent = steps[1].query!;
      expect(recent.types, [BangumiSubjectType.anime]);
      expect(recent.airDate, ['>=2026-04-14']);
      expect(steps[2].query!.airDate, isEmpty);
    });

    test('漫画：先 /book 注目榜，再「漫画」标签，最后全站书籍', () {
      final steps = HotSearchKeywords.bangumiLadderFor(
        SourceType.mangaSource,
        DateTime(2026, 10, 11),
      );
      expect(steps.first.featuredChannel, '/book');
      expect(steps[1].query!.tags, ['漫画']);
      expect(steps[1].query!.types, [BangumiSubjectType.book]);
      expect(steps[2].query!.tags, isEmpty);
    });

    test('小说：网络小说 → 轻小说 → /book 注目榜 → 全站书籍', () {
      final steps = HotSearchKeywords.bangumiLadderFor(
        SourceType.novelSource,
        DateTime(2026, 10, 11),
      );
      expect(steps[0].query!.tags, ['网络小说']);
      expect(steps[1].query!.tags, ['轻小说']);
      expect(steps[2].featuredChannel, '/book');
      expect(steps[3].query!.tags, isEmpty);
      expect(
        steps.every((s) => s.query == null ||
            (s.query!.types.length == 1 &&
                s.query!.types[0] == BangumiSubjectType.book)),
        isTrue,
      );
    });
  });

  group('HotSearchKeywords.parseFeaturedSubjects（注目榜网页解析）', () {
    // 真实结构：行内首个 /subject/ 链接即条目（href 含 ID），页面显示名为
    // 日文原名（title 属性或链接文本），中文名由详情接口另行补全。
    const fixture = '''
      <div class="featuredItems">
        <ul>
          <li class="mainItem">
            <a href="/subject/123" title="葬送のフリーレン">
              <span class="image" style="background-image:url('//lain.bgm.tv/pic/cover/a.jpg')"></span>
            </a>
            <span class="grey"> 12345 人收藏 </span>
          </li>
          <li class="mainItem"><a href="/subject/456" title="呪術廻戦"><span class="image"></span></a><h6><a href="/subject/456">呪術廻戦</a></h6></li>
          <li class="mainItem"><a href="/subject/456" title="呪術廻戦">重复 ID 应被去重</a></li>
          <li class="mainItem"><a href="/user/nexhub">非条目链接应跳过</a></li>
          <li class="mainItem"><a href="/subject/789"><span class="image"></span></a><h6><a href="/subject/789">无title取文本</a></h6></li>
        </ul>
      </div>
    ''';

    test('提取条目 ID + 显示名：按 href 取 ID、去重、跳过非条目链接', () {
      expect(
        HotSearchKeywords.parseFeaturedSubjects(fixture),
        <({int id, String name})>[
          (id: 123, name: '葬送のフリーレン'),
          (id: 456, name: '呪術廻戦'),
          (id: 789, name: '无title取文本'),
        ],
      );
    });

    test('无注目区块 / 空文档返回空', () {
      expect(HotSearchKeywords.parseFeaturedSubjects('<html><body>hi</body></html>'), isEmpty);
      expect(HotSearchKeywords.parseFeaturedSubjects(''), isEmpty);
    });
  });
}
