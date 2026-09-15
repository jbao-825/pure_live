import 'package:pure_live/common/index.dart';
import 'package:pure_live/modules/multiview/models/multiview_models.dart';

/// 多画面「场景预设」的单格内容。
///
/// 承载恢复一格画面所需的最小信息：房间快照本身 + 该格音量。房间存完整
/// [LiveRoom]，使恢复时无需先联网取详情即可渲染标题与封面；是否下播由
/// 后续解析过程（assignRoom）自然纠正。
class MultiviewPresetCell {
  const MultiviewPresetCell({required this.room, required this.volume});

  final LiveRoom room;

  /// 该格音量，量纲与持久化音量一致（0-1.0）。
  final double volume;

  Map<String, dynamic> toJson() => <String, dynamic>{'room': room.toJson(), 'volume': volume};

  /// 解析单格；无法还原为可播放的房间时返回 null（该位按空格处理）。
  ///
  /// 预设是长期保留的用户数据，条目损坏时丢弃该格而不是整条预设——
  /// 与 [LiveRoom.fromJson] 的宽松风格一致。
  static MultiviewPresetCell? fromJson(Object? json) {
    if (json is! Map) return null;
    final roomJson = json['room'];
    if (roomJson is! Map) return null;

    final room = LiveRoom.fromJson(Map<String, dynamic>.from(roomJson));
    final platform = room.platform;
    final roomId = room.roomId;
    if (platform == null || platform.isEmpty || roomId == null || roomId.isEmpty) return null;

    return MultiviewPresetCell(room: room, volume: normalizePresetVolume(json['volume']));
  }
}

/// 归一化预设音量：非法/缺失回落 1.0，并钳制到 0-1.0。
///
/// 多画面每格音量恒定封顶 100%（不启用主播放器的 150% 桌面突破），
/// 故此处上界与播放侧一致，避免恢复出越界值。
double normalizePresetVolume(Object? value) {
  final parsed = value is num ? value.toDouble() : double.tryParse(value?.toString() ?? '');
  if (parsed == null || !parsed.isFinite) return 1.0;
  return parsed.clamp(0.0, 1.0).toDouble();
}

/// 一份多画面场景快照。
///
/// 记录"布局 + 大画面格 + 各格房间与音量 + 两个开关"，用于一键还原。
/// [cells] 按下标排列，`null` 表示该位是空格——保留位次而不压缩，否则
/// 恢复时房间会整体前移，与用户当初的布局不符。
class MultiviewPreset {
  const MultiviewPreset({
    required this.id,
    required this.name,
    required this.layout,
    required this.focusedCellIndex,
    required this.cells,
    required this.smallCellsLowQuality,
    required this.danmakuEnabled,
  });

  final String id;
  final String name;
  final MultiviewLayout layout;

  /// focus 布局下显示为大画面的格子下标；其他布局下无意义但保持合法值。
  final int focusedCellIndex;

  final List<MultiviewPresetCell?> cells;
  final bool smallCellsLowQuality;
  final bool danmakuEnabled;

  /// 快照记录的格子数（含空格位）。
  int get cellCount => cells.length;

  /// 首个已分配房间的格子下标；全空时返回 -1。
  int get firstFilledIndex => cells.indexWhere((cell) => cell != null);

  /// 生成新的预设 id。
  ///
  /// 时间戳基数 36：同一微秒内不会连续创建两条预设，足够唯一且无需引入
  /// 额外的 uuid 生成路径。
  static String newId() => DateTime.now().microsecondsSinceEpoch.toRadixString(36);

  Map<String, dynamic> toJson() => <String, dynamic>{
    'id': id,
    'name': name,
    'layout': layout.name,
    'focusedCellIndex': focusedCellIndex,
    'cells': <Map<String, dynamic>?>[for (final cell in cells) cell?.toJson()],
    'smallCellsLowQuality': smallCellsLowQuality,
    'danmakuEnabled': danmakuEnabled,
  };

  /// 解析一条预设；缺少 id 时返回 null（无法定位的条目没有保留价值）。
  static MultiviewPreset? fromJson(Object? json) {
    if (json is! Map) return null;

    final id = json['id']?.toString();
    if (id == null || id.isEmpty) return null;

    final rawCells = json['cells'];
    return MultiviewPreset(
      id: id,
      name: json['name']?.toString() ?? '',
      layout: layoutFromName(json['layout']),
      focusedCellIndex: nonNegativeIntFromJson(json['focusedCellIndex']),
      cells: rawCells is List
          ? <MultiviewPresetCell?>[for (final entry in rawCells) MultiviewPresetCell.fromJson(entry)]
          : const <MultiviewPresetCell?>[],
      smallCellsLowQuality: json['smallCellsLowQuality'] == true,
      danmakuEnabled: json['danmakuEnabled'] == true,
    );
  }

  MultiviewPreset copyWith({
    String? name,
    MultiviewLayout? layout,
    int? focusedCellIndex,
    List<MultiviewPresetCell?>? cells,
    bool? smallCellsLowQuality,
    bool? danmakuEnabled,
  }) {
    return MultiviewPreset(
      id: id,
      name: name ?? this.name,
      layout: layout ?? this.layout,
      focusedCellIndex: focusedCellIndex ?? this.focusedCellIndex,
      cells: cells ?? this.cells,
      smallCellsLowQuality: smallCellsLowQuality ?? this.smallCellsLowQuality,
      danmakuEnabled: danmakuEnabled ?? this.danmakuEnabled,
    );
  }

  /// 用新的快照内容替换本条预设，保留 [id] 与 [name]（"覆盖"语义）。
  MultiviewPreset overwrittenBy(MultiviewPreset snapshot) {
    return MultiviewPreset(
      id: id,
      name: name,
      layout: snapshot.layout,
      focusedCellIndex: snapshot.focusedCellIndex,
      cells: snapshot.cells,
      smallCellsLowQuality: snapshot.smallCellsLowQuality,
      danmakuEnabled: snapshot.danmakuEnabled,
    );
  }
}

/// 按枚举名解析布局，未知值回落 [MultiviewLayout.quad]（功能的核心形态）。
MultiviewLayout layoutFromName(Object? value) {
  final name = value?.toString();
  for (final layout in MultiviewLayout.values) {
    if (layout.name == name) return layout;
  }
  return MultiviewLayout.quad;
}

/// 解析非负整数，缺失/非法/负数一律回落 0。
int nonNegativeIntFromJson(Object? value) {
  final parsed = value is num ? value.toInt() : int.tryParse(value?.toString() ?? '');
  return parsed == null || parsed < 0 ? 0 : parsed;
}
