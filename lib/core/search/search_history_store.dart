/// Search history persistence (per SourceType module isolation).
///
/// Stores recent search queries as a JSON-encoded List<String> via
/// [PrefsBackend] (backed by shared_preferences), keyed by
/// 'search_history_{sourceType.name}'. Dedupes, keeps newest on top,
/// capped at 15 entries.
library;

import 'dart:convert';

import '../comic/models/reader_preferences.dart';
import '../models/plugin_config.dart';
import '../utils/app_log.dart';

/// Per-module search history store.
///
/// Module isolation is achieved by deriving the storage key from
/// [SourceType], so anime / manga / novel histories do not leak across
/// modules.
class SearchHistoryStore {
  SearchHistoryStore(SourceType sourceType, {PrefsBackend? backend})
      : _backend = backend ?? const SharedPrefsBackend(),
        moduleKey = 'search_history_${sourceType.name}';

  final PrefsBackend _backend;

  /// Full SharedPreferences key, e.g. 'search_history_animeSource'.
  final String moduleKey;

  /// Maximum number of retained entries (newest first).
  static const int maxEntries = 15;

  /// 串行化队列：add/clear/remove 都走读-改-写，fire-and-forget 的 add 若与
  /// 清空交错，会把清空前读到的旧列表整份写回（清空看似成功、重进又回来）。
  /// 入队串行执行后，操作按发起顺序落地，杜绝互相覆盖。
  Future<void> _queue = Future<void>.value();

  Future<T> _serialized<T>(Future<T> Function() task) {
    final Future<T> run = _queue.then((_) => task());
    _queue = run.then<void>((_) {}, onError: (_) {});
    return run;
  }

  /// Loads history (newest first). Returns an empty list on missing or
  /// corrupt data.
  Future<List<String>> load() async {
    final String? raw = await _backend.get(moduleKey);
    if (raw == null || raw.isEmpty) return const <String>[];
    try {
      final Object? decoded = jsonDecode(raw);
      if (decoded is List) {
        return decoded.whereType<String>().toList(growable: false);
      }
    } on Object {
      // Corrupt data: ignore and treat as empty.
    }
    return const <String>[];
  }

  /// Adds [query] to history: trims, dedupes (removes existing), prepends
  /// to the top, and caps the list at [maxEntries].
  Future<void> add(String query) {
    return _serialized(() async {
      final String trimmed = query.trim();
      if (trimmed.isEmpty) return;
      final List<String> current = await load();
      final List<String> updated = <String>[
        trimmed,
        ...current.where((String e) => e != trimmed),
      ].take(maxEntries).toList(growable: false);
      await _backend.set(moduleKey, jsonEncode(updated));
      AppLog.instance.i('[历史] 记录 $moduleKey「$trimmed」（共 ${updated.length} 条）');
    });
  }

  /// Clears all history for this module.
  Future<void> clear() {
    return _serialized(() async {
      await _backend.set(moduleKey, jsonEncode(<String>[]));
      AppLog.instance.i('[历史] 清空 $moduleKey');
    });
  }

  /// Removes a single [query] entry (per-chip long-press delete).
  ///
  /// No-op when the entry does not exist (nothing is written back).
  Future<void> remove(String query) {
    return _serialized(() async {
      final String trimmed = query.trim();
      if (trimmed.isEmpty) return;
      final List<String> current = await load();
      final List<String> updated =
          current.where((String e) => e != trimmed).toList(growable: false);
      if (updated.length == current.length) return;
      await _backend.set(moduleKey, jsonEncode(updated));
      AppLog.instance.i('[历史] 删除 $moduleKey「$trimmed」（剩 ${updated.length} 条）');
    });
  }
}
