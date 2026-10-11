import 'dart:async';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexhub/core/update/update_manager.dart';

/// 可编程 Dio 适配器：模拟镜像测速会遇到的各类网络怪相
/// （黑洞连接、忽略 Range 整包回流、4xx 拒绝等）。
class _FakeMirrorAdapter implements HttpClientAdapter {
  final Future<ResponseBody> Function(
    RequestOptions options,
    Future<void>? cancelFuture,
  ) handler;

  _FakeMirrorAdapter(this.handler);

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) =>
      handler(options, cancelFuture);

  @override
  void close({bool force = false}) {}
}

/// 真实安装包下载路径（含 `/releases/download/`，走严格状态码校验）。
const String _probeFileUrl =
    'https://github.com/nexhub-app/nexhub/releases/download/v9.9.9/nexhub-setup.exe';

/// 模拟「连接成功但永远不回包」的黑洞镜像。
Future<ResponseBody> _blackHole(
  RequestOptions options,
  Future<void>? cancelFuture,
) =>
    Completer<ResponseBody>().future;

void main() {
  group('UpdateManager.isNewer（SemVer 含预发布段）', () {
    test('核心版本号比较（原有行为保持）', () {
      final m = UpdateManager.instance;
      expect(m.isNewer('v1.2.0', '1.1.0'), isTrue);
      expect(m.isNewer('v1.2.0', '1.2.0'), isFalse);
      expect(m.isNewer('v1.1.0', '1.2.0'), isFalse);
      expect(m.isNewer('v2.0.0-beta.1', '1.2.0'), isTrue);
    });

    test('同核心版本的预发布迭代可被检测到（修复点）', () {
      final m = UpdateManager.instance;
      // 测试版通道：beta.1 → beta.2 旧实现会被判为「已是最新」。
      expect(m.isNewer('v2.0.0-beta.2', '2.0.0-beta.1'), isTrue);
      expect(m.isNewer('v2.0.0-beta.2', '2.0.0-beta.2'), isFalse);
      expect(m.isNewer('v2.0.0-beta.1', '2.0.0-beta.2'), isFalse);
      expect(m.isNewer('v2.0.0-beta.10', '2.0.0-beta.9'), isTrue);
    });

    test('正式版高于同核心版本预发布', () {
      final m = UpdateManager.instance;
      expect(m.isNewer('v2.0.0', '2.0.0-beta.2'), isTrue);
      expect(m.isNewer('v2.0.0-beta.2', '2.0.0'), isFalse);
    });

    test('忽略 build 元数据与前后空白', () {
      final m = UpdateManager.instance;
      expect(m.isNewer('2.0.0-beta.2', '2.0.0-beta.1+30'), isTrue);
      expect(m.isNewer('v2.0.0-beta.1', '2.0.0-beta.1+30'), isFalse);
      expect(m.isNewer(' 2.0.1 ', '2.0.0'), isTrue);
    });

    test('多段预发布标识符（SemVer 规则）', () {
      final m = UpdateManager.instance;
      expect(m.isNewer('1.0.0-alpha.beta.1', '1.0.0-alpha'), isTrue);
      expect(m.isNewer('1.0.0-alpha', '1.0.0-alpha.1'), isFalse);
      expect(m.isNewer('1.0.0-alpha.beta', '1.0.0-beta'), isFalse);
      expect(m.isNewer('1.0.0-rc.1', '1.0.0-beta.11'), isTrue);
    });
  });

  group('UpdateManager.isPrereleaseVersion（alpha/beta/rc 识别）', () {
    test('alpha / beta / rc 均识别为测试版', () {
      expect(UpdateManager.isPrereleaseVersion('v2.1.0-alpha.1'), isTrue);
      expect(UpdateManager.isPrereleaseVersion('v2.1.0-beta.2'), isTrue);
      expect(UpdateManager.isPrereleaseVersion('v2.1.0-rc.1'), isTrue);
      expect(UpdateManager.isPrereleaseVersion('2.1.0-rc.1+30'), isTrue);
    });

    test('正式版与 build 元数据不算测试版', () {
      expect(UpdateManager.isPrereleaseVersion('v2.1.0'), isFalse);
      expect(UpdateManager.isPrereleaseVersion('2.1.0+30'), isFalse);
    });

    test('预发布阶段排序 alpha < beta < rc', () {
      final m = UpdateManager.instance;
      expect(m.isNewer('v2.1.0-rc.1', '2.1.0-alpha.9'), isTrue);
      expect(m.isNewer('v2.1.0-rc.1', '2.1.0-beta.9'), isTrue);
      expect(m.isNewer('v2.1.0-alpha.1', '2.1.0-rc.1'), isFalse);
      // rc 之后到正式版仍可升级。
      expect(m.isNewer('v2.1.0', '2.1.0-rc.1'), isTrue);
    });
  });

  group('镜像测速健壮性（测速时无法下载新版本的修复点）', () {
    test('黑洞镜像有硬性总时限，不再无限挂起测速与下载前探测', () async {
      final m = UpdateManager.instance;
      m.adapterForTest = _FakeMirrorAdapter(_blackHole);
      final sw = Stopwatch()..start();
      await expectLater(
        m.probeMirror(
          'https://ghfast.top/',
          testUrl: _probeFileUrl,
          timeoutMs: 200,
        ),
        throwsException,
      );
      // HEAD + GET 两次尝试 × 200ms 硬时限；修复前对无响应连接会永远挂起
      // （receiveTimeout 只管数据间隔，连接建好却不回包时不触发）。
      expect(sw.elapsed, lessThan(const Duration(seconds: 5)));
    });

    test('镜像忽略 Range 整包回流时收到 1KB 即取消并判可达', () async {
      final m = UpdateManager.instance;
      m.adapterForTest = _FakeMirrorAdapter((options, cancelFuture) async {
        if (options.method == 'HEAD') {
          // 拒绝 HEAD，逼降级 Range GET。
          throw DioException(
            requestOptions: options,
            type: DioExceptionType.connectionError,
            error: 'head rejected',
          );
        }
        // 忽略 Range 头：200 + 1GB 假装整包回流（每 20ms 一块 64KB）。
        final controller = StreamController<Uint8List>();
        final timer = Timer.periodic(const Duration(milliseconds: 20), (_) {
          controller.add(Uint8List(64 * 1024));
        });
        unawaited(cancelFuture?.whenComplete(() {
          timer.cancel();
          controller.close();
        }));
        return ResponseBody(
          controller.stream,
          200,
          headers: <String, List<String>>{
            Headers.contentLengthHeader: <String>['1073741824'],
          },
        );
      });
      final sw = Stopwatch()..start();
      final int ms = await m.probeMirror(
        'https://ghfast.top/',
        testUrl: _probeFileUrl,
      );
      // 修复前：receiveTimeout 只管数据间隔（每 20ms 一块永不触发），
      // 探测会把 1GB「安装包」整包拉完才返回，测速与下载前的镜像选择
      // 全部被拖死。修复后收到 >1KB 即自卫取消。
      expect(sw.elapsed, lessThan(const Duration(seconds: 5)));
      expect(ms, greaterThanOrEqualTo(0));
    });

    test('HEAD 可达即返回延迟；安装包路径 4xx 判不可达（既有行为保持）', () async {
      final m = UpdateManager.instance;
      final List<String> requests = <String>[];
      m.adapterForTest = _FakeMirrorAdapter((options, cancelFuture) async {
        requests.add('${options.method} ${options.uri.host}');
        final int code = options.uri.host == 'bad.example.com' ? 403 : 200;
        return ResponseBody(const Stream<Uint8List>.empty(), code);
      });
      final int ms = await m.probeMirror(
        'https://good.example.com/',
        testUrl: _probeFileUrl,
      );
      expect(ms, greaterThanOrEqualTo(0));
      // HEAD 一步成功，不应再发 GET。
      expect(requests.where((r) => r.startsWith('GET')), isEmpty);

      // 安装包路径走严格校验：HEAD 403 → 降级 GET 403 → 不可达。
      await expectLater(
        m.probeMirror('https://bad.example.com/', testUrl: _probeFileUrl),
        throwsException,
      );
      expect(
        requests.where((r) => r == 'GET bad.example.com'),
        isNotEmpty,
      );
    });

    test('下载前自动选镜像：分批限流探测选最快者', () async {
      final m = UpdateManager.instance;
      m.adapterForTest = _FakeMirrorAdapter((options, cancelFuture) async {
        if (options.uri.host == 'ghfast.top') {
          return ResponseBody(const Stream<Uint8List>.empty(), 200);
        }
        // 其余镜像立即拒连（快失败，模拟不可达）。
        throw DioException(
          requestOptions: options,
          type: DioExceptionType.connectionError,
          error: 'refused',
        );
      });
      final picked = await m.pickFastestMirrorForTest(_probeFileUrl);
      expect(picked?.name, 'ghfast.top');
      expect(picked?.prefix, 'https://ghfast.top/https://github.com/');
    });

    test('下载前自动选镜像：总预算耗尽即开下，不让下载卡在测速', () async {
      final m = UpdateManager.instance;
      m.adapterForTest = _FakeMirrorAdapter((options, cancelFuture) async {
        // 每个响应拖 300ms：预算 100ms 时第 1 波测完就应停止继续测。
        await Future<void>.delayed(const Duration(milliseconds: 300));
        return ResponseBody(const Stream<Uint8List>.empty(), 200);
      });
      final sw = Stopwatch()..start();
      final picked = await m.pickFastestMirrorForTest(
        _probeFileUrl,
        budget: const Duration(milliseconds: 100),
      );
      // 第 1 波不因预算中断（已有结果），但不会继续测剩余 5 波
      // （45 镜像 × 300ms 全测完约 1.8s+，预算拦截后远小于此）。
      expect(picked, isNotNull);
      expect(sw.elapsed, lessThan(const Duration(milliseconds: 1200)));
    });
  });
}
