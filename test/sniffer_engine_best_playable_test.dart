// 嗅探候选排序选优（bestPlayable）单测：防无扩展名广告占位/中转壳冒充解析结果。
//
// 背景（2026-10-11 233 源嗅探增强）：233 精品线的播放器页对疑似机器人下发
// TikTok 广告 mp4（URL 无媒体扩展名），可能抢在真直链之前被捕获——排序规则
// 让播放列表/整片 > 分片 > 无扩展名 MIME 视频 > 其它。
import 'package:flutter_test/flutter_test.dart';
import 'package:nexhub/core/sniffer/sniffer_engine.dart';
import 'package:nexhub/core/sniffer/sniffer_models.dart';

SniffedMedia _m(String url, {String? mime, String? kind}) => SniffedMedia(
      url: url,
      kind: SniffedMedia.inferKind(url, mime),
      typeLabel: SniffedMedia.inferTypeLabel(url, mime),
      sourceTag: kind,
      seenAt: DateTime.now(),
    );

void main() {
  group('SnifferEngine.bestPlayable', () {
    test('空候选返回 null', () {
      expect(SnifferEngine.bestPlayable(const []), isNull);
    });

    test('全 blob 候选返回 null（无法外部播放）', () {
      final best = SnifferEngine.bestPlayable(<SniffedMedia>[
        _m('blob:https://art.v2player.top/abc'),
        _m('mediasource:video/mp4;codecs=avc1'),
      ]);
      expect(best, isNull);
    });

    test('播放列表 m3u8 优先于 ts 分片', () {
      final best = SnifferEngine.bestPlayable(<SniffedMedia>[
        _m('https://cdn.example.com/seg-001.ts?hash=a'),
        _m('https://cdn.example.com/index.m3u8'),
      ]);
      expect(best!.url, 'https://cdn.example.com/index.m3u8');
    });

    test('带扩展名整片优先于无扩展名视频（广告占位形态）', () {
      // TikTok 广告直链：URL 无媒体扩展名（扩展名藏在 mime_type=video_mp4 查询参数里）
      final ad = _m('https://v16-tiktokcdn-com.akamaized.net/x/video/tos/a/?a=1&mime_type=video_mp4');
      expect(ad.kind, MediaKind.other, reason: '无扩展名无 MIME 不应被判为视频');
      final best = SnifferEngine.bestPlayable(<SniffedMedia>[
        ad,
        _m('https://cdn.example.com/v.mp4'),
      ]);
      expect(best!.url, 'https://cdn.example.com/v.mp4');
    });

    test('无扩展名但 MIME 为视频的串流优先于 other（真媒体不丢）', () {
      // other 在前、MIME 视频在后：检验排序而非插入序
      final best = SnifferEngine.bestPlayable(<SniffedMedia>[
        _m('https://cdn.example.com/pixel?id=1'),
        _m('https://cdn.example.com/get?u=1', mime: 'video/mp4'),
      ]);
      expect(best!.url, 'https://cdn.example.com/get?u=1');
    });

    test('同分保持先捕获者优先（不因后到的高同分项改选）', () {
      final best = SnifferEngine.bestPlayable(<SniffedMedia>[
        _m('https://a.example.com/1.m3u8'),
        _m('https://b.example.com/2.mp4'),
      ]);
      expect(best!.url, 'https://a.example.com/1.m3u8');
    });

    test('mp4 整片优先于 mp3 音频', () {
      final best = SnifferEngine.bestPlayable(<SniffedMedia>[
        _m('https://cdn.example.com/audio.mp3'),
        _m('https://cdn.example.com/video.mp4'),
      ]);
      expect(best!.url, 'https://cdn.example.com/video.mp4');
    });
  });

  group('SnifferEngine.add 媒体元素无扩展名直链提权', () {
    test('kind=media 的无扩展名 http 直链提升为 video（233 精品线真链形态）', () async {
      final engine = SnifferEngine();
      final ok = await engine.add(
        'https://cdn.example.com/video/tos/alisg/oICbAA/?a=1&mime_type=video_mp4',
        kind: 'media',
      );
      expect(ok, isTrue);
      expect(engine.count, 1);
      expect(engine.items.single.kind, MediaKind.video,
          reason: '媒体元素正在播放的无扩展名直链就是视频，漏判会让嗅探永不命中');
    });

    test('kind=fetch 的无扩展名 http 地址被规则过滤（不入库，不提权）', () async {
      final engine = SnifferEngine();
      final ok = await engine.add('https://api.example.com/get?u=1', kind: 'fetch');
      expect(ok, isFalse, reason: '无扩展名且非媒体来源的地址按噪声规则过滤');
      expect(engine.items, isEmpty);
    });

    test('提权后 bestPlayable 可选中无扩展名媒体直链', () async {
      final engine = SnifferEngine();
      await engine.add(
        'https://cdn.example.com/video/tos/alisg/oICbAA/?a=1',
        kind: 'media',
      );
      final best = SnifferEngine.bestPlayable(engine.filtered(SniffFilter.video));
      expect(best, isNotNull);
      expect(best!.url, 'https://cdn.example.com/video/tos/alisg/oICbAA/?a=1');
    });
  });
}
