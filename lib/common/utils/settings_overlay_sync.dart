import 'dart:async';
import 'dart:convert';
import 'dart:developer';
import 'dart:io';

import 'package:pure_live/common/utils/hive_pref_util.dart';
import 'package:pure_live/common/services/utils/hive_rx.dart';

/// Collects this window's settings changes into a patch file.
///
/// A child window ("open room in a new window") owns an isolated settings box,
/// so a change made in one can never reach the primary window through storage,
/// and its data root is deleted once the window closes. Instead, every write
/// reported by [HivePrefUtil] is buffered here and flushed as a `{key: value}`
/// patch next to the primary data root.
///
/// Only a Windows child window attaches a collector, so the primary window and
/// every other platform keep writing straight to their own storage.
class SettingsOverlayCollector {
  SettingsOverlayCollector(this.file);

  /// Where the patch lands. The primary window merges it via
  /// [SettingsOverlaySync.applyPending].
  final File file;

  /// Long enough to coalesce a slider drag, short enough that a window killed
  /// without a clean shutdown still keeps the change it just made.
  static const Duration _debounce = Duration(milliseconds: 150);

  Timer? _timer;
  final Map<String, dynamic> _patch = <String, dynamic>{};
  bool _attached = false;

  bool get isAttached => _attached;

  void start() {
    if (_attached) return;
    _attached = true;
    HivePrefUtil.watchWrites(onWrite: _record, onFlush: flush);
  }

  /// Detaches and drops anything still buffered. A window that is shutting down
  /// must let [HivePrefUtil.flush] drain first - it calls [flush] for exactly
  /// that reason.
  void stop() {
    if (!_attached) return;
    _attached = false;
    _timer?.cancel();
    _timer = null;
    _patch.clear();
    HivePrefUtil.watchWrites();
  }

  void _record(String key, dynamic value) {
    _patch[key] = value;
    _timer?.cancel();
    _timer = Timer(_debounce, () => unawaited(flush()));
  }

  /// Writes the buffered patch, replacing the file atomically so a reader never
  /// observes a half-written document.
  Future<void> flush() async {
    if (_patch.isEmpty) return;

    final payload = Map<String, dynamic>.from(_patch);
    final temp = File('${file.path}.tmp');
    try {
      await temp.parent.create(recursive: true);
      await temp.writeAsString(jsonEncode(payload), flush: true);
      if (await file.exists()) await file.delete();
      await temp.rename(file.path);
    } catch (error) {
      log('子窗口设置补丁写入失败 (${file.path}): $error');
      return;
    }
    // Only drop what this write actually covered: a key changed while the file
    // was being written stays pending for the next flush.
    payload.forEach((key, value) {
      if (_patch[key] == value) _patch.remove(key);
    });
  }
}

/// Merges collected patches back into the running process.
///
/// Patches are per-window files, so two child windows never write the same file
/// and no cross-process locking is needed. Only the primary window ever calls
/// [applyPending] / [applyPendingFromConfiguredDirectory].
class SettingsOverlaySync {
  SettingsOverlaySync._();

  /// The directory child windows drop their patches into. Configured once
  /// during startup so later callers - the launcher included - do not have to
  /// reach for the path manager.
  static Directory? _directory;

  static void configure(Directory directory) => _directory = directory;

  /// Applies every pending patch that targets the configured directory.
  ///
  /// Returns the number of patches merged, or 0 when nothing is configured.
  static Future<int> applyPendingFromConfiguredDirectory() async {
    final directory = _directory;
    if (directory == null) return 0;
    return applyPending(directory);
  }

  /// Applies every pending patch found in [directory].
  ///
  /// Each patch is removed only after every one of its keys reached storage, so
  /// an interrupted merge is retried on the next call instead of being lost.
  static Future<int> applyPending(Directory directory) async {
    final List<File> patches;
    try {
      if (!await directory.exists()) return 0;
      patches = await directory
          .list()
          .where((entity) => entity is File && entity.path.endsWith('.json'))
          .cast<File>()
          .toList();
    } catch (error) {
      log('子窗口设置补丁目录读取失败 (${directory.path}): $error');
      return 0;
    }
    if (patches.isEmpty) return 0;

    // Deterministic order: when two windows touched the same key, the one that
    // produced the later patch wins.
    patches.sort((a, b) => a.path.compareTo(b.path));

    var merged = 0;
    for (final patch in patches) {
      if (await _applyPatch(patch)) merged++;
    }
    return merged;
  }

  /// Long enough to let a patch be renamed into place, short enough that the
  /// change is already there when the user looks at the page they changed it
  /// from.
  static const Duration _watchDelay = Duration(milliseconds: 120);

  static StreamSubscription<FileSystemEvent>? _directoryWatch;
  static Timer? _watchDebounce;

  /// Merges a patch as soon as a child window writes it.
  ///
  /// The primary window is usually the one being looked at when a change made
  /// in a child window should already be visible, and it would otherwise only
  /// merge at its own startup or right before exporting the next snapshot.
  ///
  /// Best effort by design: this watch is an accelerator, not the guarantee. A
  /// dropped event - or a patch written while this process was not running -
  /// still merges through those two explicit calls.
  static Future<void> watchDirectory(Directory directory) async {
    await stopWatching();
    try {
      if (!await directory.exists()) await directory.create(recursive: true);
      _directoryWatch = directory.watch().listen(
        (event) {
          // `.json.tmp` is the half-written half of the atomic rename; it must
          // never be read, and only the renamed target is worth reacting to.
          if (!event.path.endsWith('.json')) return;
          _watchDebounce?.cancel();
          _watchDebounce = Timer(_watchDelay, () => unawaited(applyPending(directory)));
        },
        onError: (Object error) => log('子窗口设置补丁目录监听失败 (${directory.path}): $error'),
      );
    } catch (error) {
      log('子窗口设置补丁目录监听无法启动 (${directory.path}): $error');
    }
  }

  /// Detaches the watch. Only shutdown and tests need this.
  static Future<void> stopWatching() async {
    _watchDebounce?.cancel();
    _watchDebounce = null;
    await _directoryWatch?.cancel();
    _directoryWatch = null;
  }

  static Future<bool> _applyPatch(File file) async {
    final String raw;
    final Map<String, dynamic> entries;
    try {
      raw = await file.readAsString();
      final decoded = jsonDecode(raw);
      if (decoded is! Map) {
        throw const FormatException('补丁内容必须是 JSON 对象');
      }
      entries = Map<String, dynamic>.from(decoded);
    } catch (error) {
      // Keep the file: a malformed patch is evidence, not garbage, and silently
      // dropping settings is exactly the failure this mechanism replaces.
      log('子窗口设置补丁无法解析，已保留待处理: ${file.path} ($error)');
      return false;
    }

    for (final entry in entries.entries) {
      try {
        await applyExternalPref(entry.key, entry.value);
      } catch (error) {
        log('子窗口设置项合并失败: ${entry.key} ($error)');
        return false;
      }
    }

    try {
      // Remove only the file this merge consumed. A child window can write a
      // newer patch to the same path while these entries are being applied, and
      // deleting that one would drop settings it never got to keep. Leaving a
      // changed file behind costs one redundant re-apply instead.
      if (await file.exists() && await file.readAsString() == raw) await file.delete();
    } catch (error) {
      // Already applied; a leftover file only costs one redundant re-apply.
      log('已合并的设置补丁删除失败: ${file.path} ($error)');
    }
    return true;
  }
}
