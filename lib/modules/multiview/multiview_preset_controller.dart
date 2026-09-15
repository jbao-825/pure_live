import 'package:pure_live/common/index.dart';
import 'package:pure_live/modules/multiview/models/multiview_preset.dart';

/// 多画面「场景预设」的持久化与增删改。
///
/// 存储沿用项目既有姿势（`hiveObject` + JSON 字符串），与 [HistoryController]
/// 同构：赋值即落盘（见 `HiveRxExtension.hiveObject`），无需显式保存。
/// 本类不接触播放器，快照的生成与应用都在 [MultiviewController] 上。
class MultiviewPresetController extends GetxController {
  static MultiviewPresetController get to => Get.find();

  static const String storageKey = 'multiviewPresets';

  /// 预设数量上限。
  ///
  /// 多画面场景是低频配置，十条足以覆盖常见组合，也避免面板无限增长。
  /// 达上限时新增被拒绝，由 UI 提示用户先删。
  static const int maxPresets = 10;

  /// 已保存的预设，列表首位为最近保存的一条。
  final Rx<List<MultiviewPreset>> presets = hiveObject(
    storageKey,
    <MultiviewPreset>[],
    fromJson: (json) {
      final list = json['list'];
      if (list is! List) return <MultiviewPreset>[];

      // 逐条容错：单条损坏不影响其余预设。
      final parsed = <MultiviewPreset>[];
      for (final entry in list) {
        final preset = MultiviewPreset.fromJson(entry);
        if (preset != null) parsed.add(preset);
      }
      return parsed;
    },
    toJson: (list) => <String, dynamic>{
      'list': <Map<String, dynamic>>[for (final preset in list) preset.toJson()],
    },
  );

  /// 当前预设列表（UI 只读消费）。
  List<MultiviewPreset> get list => presets.v;

  bool get canAdd => presets.v.length < maxPresets;

  bool get isEmpty => presets.v.isEmpty;

  MultiviewPreset? findById(String id) {
    for (final preset in presets.v) {
      if (preset.id == id) return preset;
    }
    return null;
  }

  /// 新增一份预设并置于列表首位；已达 [maxPresets] 上限时返回 false。
  bool add(MultiviewPreset preset) {
    if (!canAdd) return false;
    presets.v = <MultiviewPreset>[preset, ...presets.v];
    return true;
  }

  void rename(String id, String name) {
    presets.v = <MultiviewPreset>[
      for (final preset in presets.v) preset.id == id ? preset.copyWith(name: name) : preset,
    ];
  }

  void removeById(String id) {
    presets.v = <MultiviewPreset>[
      for (final preset in presets.v)
        if (preset.id != id) preset,
    ];
  }

  /// 用新快照覆盖指定预设，保留其 id 与名称（"更新为当前画面"语义）。
  void overwrite(String id, MultiviewPreset snapshot) {
    presets.v = <MultiviewPreset>[
      for (final preset in presets.v) preset.id == id ? preset.overwrittenBy(snapshot) : preset,
    ];
  }
}
