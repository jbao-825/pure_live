import 'dart:async';
import 'dart:developer' as developer;

import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:remixicon/remixicon.dart';
import 'package:pure_live/common/index.dart';
import 'package:flame_barrage/flame_barrage.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:pure_live/player/utils/fullscreen.dart';
import 'package:pure_live/common/global/platform_utils.dart';
import 'package:pure_live/modules/multiview/multiview_controller.dart';
import 'package:pure_live/modules/multiview/multiview_preset_controller.dart';
import 'package:pure_live/modules/multiview/models/multiview_models.dart';
import 'package:pure_live/modules/multiview/models/multiview_preset.dart';
import 'package:pure_live/modules/live_play/controllers/player_state.dart';
import 'package:pure_live/player/widgets/video_output_viewport_sizer.dart';
import 'package:pure_live/modules/live_play/pages/danmaku_settings_page.dart';
import 'package:pure_live/modules/multiview/widgets/multiview_room_picker.dart';
import 'package:pure_live/modules/live_play/widgets/layout/live_play_back_scope.dart';
import 'package:pure_live/modules/multiview/widgets/multiview_fullscreen_surface.dart';
import 'package:pure_live/modules/multiview/danmaku/multiview_danmaku_settings_binding.dart';

/// 页面显示状态机：normal（完整界面）→ immersive（隐藏工具条与侧板，
/// 留悬浮恢复钮）→ fullscreen（仅保留安全区内的退出钮）。
///
/// 只影响 chrome 显隐，不触碰布局/格子状态；返回手势与 Esc 均沿
/// fullscreen/immersive → normal → 退出页面 的单一路径回退。
enum _DisplayMode { normal, immersive, fullscreen }

/// 场景预设条目的尾部菜单动作。
enum _PresetAction { overwrite, rename, delete }

/// 多画面同看页面。
///
/// 视觉与交互层：按 [MultiviewController] 的布局与格子状态渲染网格，
/// 提供布局切换（1x1/1x2/2x2/一大多小）、每格清晰度选择、大画面弹幕、
/// 选台面板（窄屏底部弹窗、宽屏右侧常驻侧板）、音频焦点标识、单格操作
/// 菜单与沉浸/全屏显示模式。播放资源的创建与释放全部由控制器统一管理，
/// 本页面不持有任何播放器对象。
class MultiviewPage extends StatefulWidget {
  const MultiviewPage({super.key});

  @override
  State<MultiviewPage> createState() => _MultiviewPageState();
}

class _MultiviewPageState extends State<MultiviewPage> {
  /// 与首页一致的宽窄屏分界：超过该宽度时选台面板以右侧常驻侧板呈现。
  static const double _wideBreakpoint = 680;

  /// 宽屏侧板宽度，与桌面端设置类页面的侧栏习惯一致。
  static const double _sidePanelWidth = 320;

  /// 一大多小布局的大格与右侧小列的弹性比。
  static const int _focusBigFlex = 3;

  static const int _focusSmallFlex = 1;

  /// 一大多小小列首屏可见格数：前三格恰好铺满视口（与固定三格时代的
  /// 视觉节奏一致），追加格滚动呈现。
  static const int _focusSmallViewportCells = 3;

  /// 音量步进（滚轮 / 方向键）：5% 一档。
  static const double _volumeStep = 0.05;

  /// 预设名称输入框的长度上限。
  static const int _presetNameMaxLength = 20;

  /// 预设列表在弹层中的最大高度，超出滚动。
  static const double _presetListMaxHeight = 320;

  /// 当前显示模式；仅 chrome 显隐差异，见 [_DisplayMode]。
  _DisplayMode _displayMode = _DisplayMode.normal;

  /// 安全退出进行中标志：防止连按返回/Esc 重复触发退出序列。
  bool _exiting = false;

  /// 每格播放控制条的显隐集合；点击格子切换（对齐 live_play 点按呼出
  /// 控制条的交互），晋升/切布局/换房时复位。
  ///
  /// 逐格模式（Windows）下每格各自独立；非逐格模式仅 focus 大格会用到。
  final Set<int> _controlsVisible = <int>{};

  /// 选台面板当前的目标格下标。
  int _targetCell = 0;

  /// 布局监听：缩容时把选台目标钳制回有效范围，避免向已不存在的格子提交。
  Worker? _layoutWorker;

  /// 每格 GlobalKey：一大多小晋升时格子跨父级移动（大格槽 ⇄ 小格列），
  /// 普通 ValueKey 无法跨父级复用元素；GlobalKey 让格子子树整体搬移，
  /// Video 状态与纹理附着保持不变，切换不闪黑。
  final Map<int, GlobalKey> _cellKeys = {};

  MultiviewController get controller => Get.find<MultiviewController>();

  /// 场景预设的持久化控制器（由 MultiviewBinding 注册）。
  MultiviewPresetController get presetController => Get.find<MultiviewPresetController>();

  GlobalKey _cellKey(int index) => _cellKeys.putIfAbsent(index, () => GlobalKey(debugLabel: 'multiview_cell_$index'));

  @override
  void initState() {
    super.initState();
    _targetCell = _firstAssignableCell();
    _layoutWorker = ever<MultiviewLayout>(controller.layout, (_) => _clampTargetCell());
    // 桌面端 Esc 退沉浸/全屏。用全局键盘钩子而非 Focus 节点：
    // 选台面板搜索框等输入焦点不应抢占 Esc 处理权；
    // 本路由非栈顶（弹层/上层页面打开）时让位，不干扰其按键语义。
    HardwareKeyboard.instance.addHandler(_handleGlobalKeyEvent);
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_handleGlobalKeyEvent);
    _layoutWorker?.dispose();
    // 极端路径防御：页面在全屏态被系统直接销毁（路由被移除/上层 offAndTo）
    // 时恢复系统 UI 与窗口状态。doExitFullScreen 幂等，重复调用安全。
    if (_displayMode == _DisplayMode.fullscreen) {
      // 页面在全屏态被系统直接销毁时，必须复位桌面壳标题栏标志，
      // 否则整个应用壳的自绘标题栏永久消失。
      GlobalPlayerState.to.isFullscreen.value = false;
      unawaited(_restoreSystemFullscreen());
    }
    super.dispose();
  }

  /// 返回意图统一入口：非 normal 先回 normal，normal 走安全退出序列。
  void _handleBackIntent() {
    if (_displayMode != _DisplayMode.normal) {
      unawaited(_changeDisplayMode(_DisplayMode.normal));
      return;
    }
    // normal 态不放行真实 pop：先卸载全部视频外部纹理并等光栅排空，
    // 再执行显式 pop（见 [_exitSafely] 的竞态说明）。
    unawaited(_exitSafely());
  }

  /// 安全退出序列（规避引擎层「外部纹理注销 vs 合成器」竞态）。
  ///
  /// 崩溃机理：pop 动画期间 Video 纹理仍存活，光栅线程继续合成多路
  /// 外部纹理，撞上原生侧纹理注销窗口即空指针。规避时序：
  /// 1. 同步调用 disposeAll——其内部先同步清空全部格状态，
  ///    Video 因 status 变 empty 立即从树中卸载，纹理脱离合成器；
  /// 2. 等待两帧结束，让光栅线程完成一帧不含视频纹理的合成并排空；
  /// 3. 此时树上已无任何外部纹理，才执行真实 pop。
  ///
  /// 控制器 onClose 里对已清空的格再次 disposeAll 是幂等的，无需额外处理。
  Future<void> _exitSafely() async {
    if (_exiting) return;
    _exiting = true;
    unawaited(controller.disposeAll());
    await WidgetsBinding.instance.endOfFrame;
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted) return;
    Navigator.of(context).pop();
  }

  bool _handleGlobalKeyEvent(KeyEvent event) {
    if (event is! KeyDownEvent) return false;
    if (!mounted || ModalRoute.of(context)?.isCurrent != true) return false;

    if (event.logicalKey == LogicalKeyboardKey.escape) {
      if (_displayMode == _DisplayMode.normal) return false;
      unawaited(_changeDisplayMode(_DisplayMode.normal));
      return true;
    }
    // 播放类快捷键仅逐格模式（Windows）提供，且作用于当前选中格。
    if (!controller.perCellMode) return false;
    return _handlePlaybackKey(event);
  }

  /// 桌面播放快捷键：与 live_play 的 VideoKeyboardShortcuts 对齐
  /// （空格播放/暂停、R 刷新、上下键调音量），作用域为当前选中格。
  ///
  /// 输入框持有焦点时一律放行：选台搜索框里的空格/方向键属于文本编辑。
  bool _handlePlaybackKey(KeyEvent event) {
    if (_isTextInputFocused()) return false;
    final index = controller.audioFocusIndex;
    if (index < 0 || index >= controller.cells.length) return false;
    if (controller.cells[index].status != MultiviewCellStatus.playing) return false;

    switch (event.logicalKey) {
      case LogicalKeyboardKey.space:
        unawaited(controller.toggleCellPlayPause(index));
        return true;
      case LogicalKeyboardKey.keyR:
        final room = controller.cells[index].room;
        if (room != null) unawaited(controller.assignRoom(index, room));
        return true;
      case LogicalKeyboardKey.arrowUp:
        unawaited(_stepCellVolume(index, _volumeStep));
        return true;
      case LogicalKeyboardKey.arrowDown:
        unawaited(_stepCellVolume(index, -_volumeStep));
        return true;
      default:
        return false;
    }
  }

  bool _isTextInputFocused() {
    final focusContext = FocusManager.instance.primaryFocus?.context;
    return focusContext != null && focusContext.widget is EditableText;
  }

  /// 把该格音量在当前值上步进 [delta] 并钳制到 0.0-1.0。
  ///
  /// 多画面每格走 mpv 增益且不启用桌面端 100%-150% 突破：多路同时出声时
  /// 额外增益会显著抬高削波风险，故这里恒定封顶 100%。
  Future<void> _stepCellVolume(int index, double delta) {
    final next = (controller.cellVolume(index) + delta).clamp(0.0, 1.0);
    return controller.setCellVolume(index, next);
  }

  /// 切换显示模式，并在 normal↔fullscreen 边界同步系统级全屏。
  ///
  /// 复用播放器既有机制 [WindowService]：移动端 immersiveSticky 隐藏
  /// 状态栏/导航栏，桌面端 windowManager.setFullScreen 无边框占满整屏。
  /// 沉浸模式维持页内隐藏语义，不触碰系统 UI——两档由此形成明确区分。
  Future<void> _changeDisplayMode(_DisplayMode mode) async {
    if (!mounted || _displayMode == mode) return;
    final previous = _displayMode;
    setState(() => _displayMode = mode);

    final enterSystemFullscreen = mode == _DisplayMode.fullscreen && previous != _DisplayMode.fullscreen;
    final exitSystemFullscreen = previous == _DisplayMode.fullscreen && mode != _DisplayMode.fullscreen;
    if (!enterSystemFullscreen && !exitSystemFullscreen) return;

    try {
      if (enterSystemFullscreen) {
        // 桌面壳自绘标题栏由该全局标志控制显隐（DesktopManager.buildWithTitleBar），
        // multiview 全屏必须与 live_play 同步置位，否则标题栏残留。
        GlobalPlayerState.to.isFullscreen.value = true;
        await WindowService().doEnterFullScreen();
        // 手机端进入全屏自动横屏（与普通模式播放的全屏一致）；
        // 退出时 doExitFullScreen 统一解锁方向，无需在此处理。
        if (PlatformUtils.isMobile) {
          await WindowService().landScape();
        }
      } else {
        GlobalPlayerState.to.isFullscreen.value = false;
        await _restoreSystemFullscreen();
      }
    } catch (error, stackTrace) {
      // 系统 UI/窗口管理器调用失败不得让播放页面崩溃；记录后维持页内
      // 状态机，用户仍可经回退链再次尝试恢复。
      developer.log(
        'MultiviewPage: system fullscreen transition failed',
        name: 'MultiviewPage',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  /// 恢复系统 UI / 退出窗口全屏；幂等，供所有退出路径与 dispose 防御复用。
  Future<void> _restoreSystemFullscreen() => WindowService().doExitFullScreen();

  int _firstAssignableCell() {
    for (final cell in controller.cells) {
      if (isMultiviewCellAssignable(cell.status)) return cell.index;
    }
    return 0;
  }

  /// 布局缩容后旧目标格（如 quad 的第 4 格）已不存在，钳制到新容量内。
  void _clampTargetCell() {
    final maxIndex = controller.cells.length - 1;
    if (_targetCell > maxIndex && mounted) {
      setState(() => _targetCell = maxIndex);
    }
  }

  /// 分配成功后把目标推进到下一个空位，连续选台无需反复点击格子。
  void _advanceTarget(int justAssigned) {
    final count = controller.cells.length;
    for (var step = 1; step < count; step++) {
      final index = (justAssigned + step) % count;
      if (isMultiviewCellAssignable(controller.cells[index].status)) {
        setState(() => _targetCell = index);
        return;
      }
    }
  }

  void _pickRoom(LiveRoom room) {
    // 防御性钳制：布局切换与选台回调竞态时，提交下标必须仍在当前容量内。
    final target = _targetCell.clamp(0, controller.cells.length - 1);
    // 换台后收起该格控制条：新房间应回到干净的播放画面。
    _controlsVisible.remove(target);
    unawaited(controller.assignRoom(target, room));
    _advanceTarget(target);
    setState(() {});
  }

  void _openPickerFor(int cellIndex, {required bool isWide}) {
    setState(() => _targetCell = cellIndex);
    // 宽屏侧板常驻，点击空格只切换目标高亮；窄屏弹出底部选台弹窗。
    if (isWide) return;
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.72),
      builder: (sheetContext) => SafeArea(
        child: MultiviewRoomPicker(
          cellIndex: cellIndex,
          onPicked: (room) {
            Navigator.of(sheetContext).pop();
            _pickRoom(room);
          },
        ),
      ),
    );
  }

  void _showCellActions(MultiviewCellState state) {
    // 手机横屏逻辑宽度同样会超过断点，但侧板选台是桌面形态：
    // 移动端一律走底部弹窗选台，避免横屏时网格被压缩。
    final isWide =
        PlatformUtils.isDesktop &&
        MediaQuery.sizeOf(context).width > _wideBreakpoint &&
        _displayMode == _DisplayMode.normal;
    final hasQuality =
        state.status == MultiviewCellStatus.playing && state.qualities.isNotEmpty && state.qualityLoader != null;
    // 逐格模式下点按让位给控制条，晋升改由本菜单提供入口（仅一大多小、
    // 且目标不是当前大画面时可用）。
    final canPromote =
        controller.perCellMode &&
        controller.layout.value == MultiviewLayout.focus &&
        controller.focusedCellIndex.value != state.index &&
        state.status == MultiviewCellStatus.playing;
    showModalBottomSheet<void>(
      context: context,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Remix.tv_2_line),
              title: Text(i18n('multiview_change_room')),
              onTap: () {
                Navigator.of(sheetContext).pop();
                _openPickerFor(state.index, isWide: isWide);
              },
            ),
            if (canPromote)
              ListTile(
                leading: const Icon(Remix.focus_3_line),
                title: Text(i18n('multiview_promote_cell')),
                onTap: () {
                  Navigator.of(sheetContext).pop();
                  _controlsVisible.clear();
                  unawaited(controller.promoteCell(state.index));
                },
              ),
            ListTile(
              leading: const Icon(Remix.equalizer_line),
              title: Text(i18n('select_quality')),
              enabled: hasQuality,
              onTap: hasQuality
                  ? () {
                      Navigator.of(sheetContext).pop();
                      _showQualitySheet(state);
                    }
                  : null,
            ),
            ListTile(
              leading: Icon(Remix.close_circle_line, color: Theme.of(context).colorScheme.error),
              title: Text(i18n('multiview_close_cell')),
              onTap: () {
                Navigator.of(sheetContext).pop();
                controller.removeCell(state.index);
              },
            ),
          ],
        ),
      ),
    );
  }

  /// 场景预设面板：把当前画面存成一组场景，或一键恢复已存场景。
  void _showPresetSheet() {
    showModalBottomSheet<void>(
      context: context,
      builder: (sheetContext) => SafeArea(
        child: Obx(() {
          final presets = presetController.presets.value;
          final canAdd = presetController.canAdd;
          final theme = Theme.of(context);

          return Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: const Icon(Remix.add_line),
                title: Text(i18n('multiview_preset_save_current')),
                subtitle: canAdd ? null : Text(i18n('multiview_preset_limit_reached')),
                enabled: canAdd,
                onTap: canAdd
                    ? () {
                        Navigator.of(sheetContext).pop();
                        unawaited(_saveCurrentAsPreset());
                      }
                    : null,
              ),
              const Divider(height: 1),
              if (presets.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 28),
                  child: Text(
                    i18n('multiview_preset_empty'),
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                  ),
                )
              else
                ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: _presetListMaxHeight),
                  child: ListView.builder(
                    shrinkWrap: true,
                    itemCount: presets.length,
                    itemBuilder: (_, index) => _buildPresetTile(sheetContext, presets[index]),
                  ),
                ),
            ],
          );
        }),
      ),
    );
  }

  /// 单条预设：点击即恢复；尾部菜单提供更新 / 重命名 / 删除。
  Widget _buildPresetTile(BuildContext sheetContext, MultiviewPreset preset) {
    return ListTile(
      leading: const Icon(Remix.layout_grid_line),
      title: Text(
        preset.name.trim().isEmpty ? i18n('multiview_preset_unnamed') : preset.name,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Text(_presetSubtitle(preset), maxLines: 1, overflow: TextOverflow.ellipsis),
      onTap: () {
        Navigator.of(sheetContext).pop();
        unawaited(_applyPreset(preset));
      },
      trailing: PopupMenuButton<_PresetAction>(
        tooltip: '',
        onSelected: (action) {
          switch (action) {
            case _PresetAction.overwrite:
              _overwritePreset(preset);
            case _PresetAction.rename:
              unawaited(_renamePreset(preset));
            case _PresetAction.delete:
              unawaited(_confirmDeletePreset(preset));
          }
        },
        itemBuilder: (_) => <PopupMenuEntry<_PresetAction>>[
          PopupMenuItem<_PresetAction>(value: _PresetAction.overwrite, child: Text(i18n('multiview_preset_overwrite'))),
          PopupMenuItem<_PresetAction>(value: _PresetAction.rename, child: Text(i18n('multiview_preset_rename'))),
          PopupMenuItem<_PresetAction>(value: _PresetAction.delete, child: Text(i18n('multiview_preset_delete'))),
        ],
      ),
    );
  }

  /// 恢复场景：先收起全部控制条（格子下标含义已变），再交给控制器重排。
  Future<void> _applyPreset(MultiviewPreset preset) async {
    if (_controlsVisible.isNotEmpty) setState(_controlsVisible.clear);

    await controller.applyPreset(preset);
    if (!mounted) return;

    ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text(i18n('multiview_preset_applied'))));
  }

  /// 把当前画面存为新预设。
  Future<void> _saveCurrentAsPreset() async {
    final fallbackName = '${i18n('multiview_preset_default_name')} ${presetController.list.length + 1}';
    final name = await _promptPresetName(
      title: i18n('multiview_preset_save_current'),
      confirmLabel: i18n('save'),
      initial: fallbackName,
    );
    if (name == null) return;

    if (presetController.add(controller.createPreset(name))) return;

    // 只有在达到上限时才会走到这里（列表已在面板里挡过一次，此处兜底）。
    if (!mounted) return;
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text(i18n('multiview_preset_limit_reached'))));
  }

  /// 用当前画面覆盖该预设，保留其 id 与名称。
  void _overwritePreset(MultiviewPreset preset) {
    presetController.overwrite(preset.id, controller.createPreset(preset.name));
  }

  Future<void> _renamePreset(MultiviewPreset preset) async {
    final name = await _promptPresetName(
      title: i18n('multiview_preset_rename'),
      confirmLabel: i18n('confirm'),
      initial: preset.name,
    );
    if (name == null) return;
    presetController.rename(preset.id, name);
  }

  Future<void> _confirmDeletePreset(MultiviewPreset preset) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(i18n('multiview_preset_delete')),
        content: Text(i18n('multiview_preset_delete_confirm')),
        actions: [
          TextButton(onPressed: () => Navigator.of(dialogContext).pop(false), child: Text(i18n('cancel'))),
          TextButton(onPressed: () => Navigator.of(dialogContext).pop(true), child: Text(i18n('delete'))),
        ],
      ),
    );
    if (confirmed == true) presetController.removeById(preset.id);
  }

  /// 名称输入框：取消返回 null，留空则沿用 [initial]。
  ///
  /// 留空回落默认名而非拒绝——用户已经点了保存，不该因为没填名字白做一次。
  Future<String?> _promptPresetName({
    required String title,
    required String confirmLabel,
    required String initial,
  }) async {
    final textController = TextEditingController(text: initial);
    final result = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: textController,
          autofocus: true,
          maxLength: _presetNameMaxLength,
          textInputAction: TextInputAction.done,
          decoration: InputDecoration(hintText: i18n('multiview_preset_name_hint')),
          onSubmitted: (value) => Navigator.of(dialogContext).pop(value),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(dialogContext).pop(), child: Text(i18n('cancel'))),
          TextButton(onPressed: () => Navigator.of(dialogContext).pop(textController.text), child: Text(confirmLabel)),
        ],
      ),
    );
    textController.dispose();

    if (result == null) return null;
    final trimmed = result.trim();
    return trimmed.isEmpty ? initial : trimmed;
  }

  /// 副标题：布局 + 各格房间昵称，便于一眼分辨相似场景。
  String _presetSubtitle(MultiviewPreset preset) {
    final names = <String>[];
    for (final cell in preset.cells) {
      final room = cell?.room;
      if (room == null) continue;

      final nick = room.nick?.trim() ?? '';
      final label = nick.isNotEmpty ? nick : (room.title?.trim() ?? '');
      if (label.isNotEmpty) names.add(label);
    }

    final layoutLabel = _presetLayoutLabel(preset.layout);
    return names.isEmpty ? layoutLabel : '$layoutLabel · ${names.join(' / ')}';
  }

  static String _presetLayoutLabel(MultiviewLayout layout) => switch (layout) {
    MultiviewLayout.single => '1×1',
    MultiviewLayout.dual => '1×2',
    MultiviewLayout.quad => '2×2',
    MultiviewLayout.focus => '1+3',
  };

  /// 清晰度列表底部弹窗（长按菜单路径）；点选后换档，当前档打勾。
  void _showQualitySheet(MultiviewCellState state) {
    final qualities = state.qualities;
    showModalBottomSheet<void>(
      context: context,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (var i = 0; i < qualities.length; i++)
              ListTile(
                title: Text(qualities[i].quality),
                trailing: i == state.qualityIndex ? const Icon(Icons.check_rounded) : null,
                onTap: () {
                  Navigator.of(sheetContext).pop();
                  unawaited(controller.setCellQuality(state.index, i));
                },
              ),
          ],
        ),
      ),
    );
  }

  void _retryCell(MultiviewCellState state) {
    final room = state.room;
    if (room == null) {
      _openPickerFor(
        state.index,
        isWide: PlatformUtils.isDesktop && MediaQuery.sizeOf(context).width > _wideBreakpoint,
      );
      return;
    }
    unawaited(controller.assignRoom(state.index, room));
  }

  @override
  Widget build(BuildContext context) {
    return LivePlayBackScope(
      presentationActive: _displayMode != _DisplayMode.normal,
      onExitPresentation: _handleBackIntent,
      child: switch (_displayMode) {
        _DisplayMode.normal => Scaffold(
          appBar: AppBar(
            title: Text(i18n('multiview_title')),
            actions: [
              IconButton(
                tooltip: i18n('multiview_immersive'),
                icon: const Icon(Remix.expand_diagonal_line),
                onPressed: () => unawaited(_changeDisplayMode(_DisplayMode.immersive)),
              ),
              IconButton(
                tooltip: i18n('multiview_fullscreen'),
                icon: const Icon(Remix.fullscreen_line),
                onPressed: () => unawaited(_changeDisplayMode(_DisplayMode.fullscreen)),
              ),
              const SizedBox(width: 4),
            ],
          ),
          body: LayoutBuilder(
            builder: (context, constraints) {
              // 侧板选台是桌面形态；手机横屏保持全宽网格 + 底部弹窗选台。
              final isWide = PlatformUtils.isDesktop && constraints.maxWidth > _wideBreakpoint;
              return Column(
                children: [
                  _buildToolbar(),
                  Expanded(child: _buildContentArea(isWide: isWide)),
                ],
              );
            },
          ),
        ),
        // 沉浸：无工具条/侧板/AppBar，仅右下角一个小恢复钮。
        // 黑底画布让格缝读作视频墙的一部分，与播放器观感一致。
        _DisplayMode.immersive => Scaffold(
          backgroundColor: Colors.black,
          body: Stack(
            children: [
              // 沉浸/全屏下没有可见侧板：空格点击一律走底部选台弹窗。
              _buildContentArea(isWide: false),
              Positioned(
                right: 16,
                bottom: 16,
                child: _ImmersiveRestoreButton(onTap: () => unawaited(_changeDisplayMode(_DisplayMode.normal))),
              ),
            ],
          ),
        ),
        // 全屏：复用 WindowService 真全屏（移动端隐藏系统栏、桌面端无边框
        // 占满整屏），网格保持 edge-to-edge；左上角仅保留避让刘海/挖孔的
        // 显式退出钮。返回手势与 Esc 仍是等价回退路径，格子其余区域的
        // 点击继续只切换音源焦点。
        _DisplayMode.fullscreen => Scaffold(
          backgroundColor: Colors.black,
          body: MultiviewFullscreenSurface(
            exitTooltip: i18n('multiview_fullscreen_exit'),
            onExit: () => unawaited(_changeDisplayMode(_DisplayMode.normal)),
            child: _buildContentArea(isWide: false),
          ),
        ),
      },
    );
  }

  /// 内容区：宽屏且 normal 时为「网格 + 分隔线 + 选台侧板」，否则仅网格。
  ///
  /// [isWide] 由调用方按显示模式折算——沉浸/全屏下传 false，
  /// 保证空格点击仍能唤起选台弹窗而非指向不可见的侧板。
  Widget _buildContentArea({required bool isWide}) {
    if (!isWide) return _buildGrid(isWide: isWide);
    return Row(
      children: [
        Expanded(child: _buildGrid(isWide: isWide)),
        const VerticalDivider(width: 1),
        SizedBox(width: _sidePanelWidth, child: _buildSidePanel()),
      ],
    );
  }

  Widget _buildToolbar() {
    final width = MediaQuery.sizeOf(context).width;
    final compact = width < 680;

    Widget buildLayoutSelector() {
      return Obx(() {
        final layout = controller.layout.value;

        return SegmentedButton<MultiviewLayout>(
          showSelectedIcon: false,
          selected: {layout},
          onSelectionChanged: (selection) {
            controller.setLayout(selection.first);
            // 切布局后复位全部控制条：格子下标含义已改变。
            _controlsVisible.clear();
          },
          segments: const [
            ButtonSegment(value: MultiviewLayout.single, icon: Icon(Remix.aspect_ratio_line), label: Text('1×1')),
            ButtonSegment(value: MultiviewLayout.dual, icon: Icon(Remix.layout_column_line), label: Text('1×2')),
            ButtonSegment(value: MultiviewLayout.quad, icon: Icon(Remix.layout_grid_line), label: Text('2×2')),
            ButtonSegment(value: MultiviewLayout.focus, icon: Icon(Remix.focus_3_line), label: Text('1+3')),
          ],
        );
      });
    }

    Widget buildActions() {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Obx(() {
            final enabled = controller.danmakuEnabled.value;
            final theme = Theme.of(context);

            return IconButton(
              tooltip: i18n('danmaku'),
              icon: Icon(
                CustomIcons.danmaku_open,
                size: 22,
                color: enabled ? theme.colorScheme.primary : theme.colorScheme.onSurfaceVariant,
              ),
              onPressed: () => controller.danmakuEnabled.toggle(),
            );
          }),
          Obx(() {
            final selectedIndex = controller.audioFocusIndexState.value;

            final canAdjust =
                selectedIndex >= 0 &&
                selectedIndex < controller.cells.length &&
                controller.cells[selectedIndex].status == MultiviewCellStatus.playing;

            final muted = controller.allMuted.value;

            return Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  tooltip: i18n('multiview_mute_all'),
                  icon: Icon(muted ? Remix.volume_mute_line : Remix.volume_up_line, size: 22),
                  onPressed: controller.toggleMuteAll,
                ),
                IconButton(
                  tooltip: i18n('multiview_volume'),
                  icon: const Icon(Remix.equalizer_2_line, size: 22),
                  onPressed: canAdjust ? () => _showVolumeSheet(selectedIndex) : null,
                ),
              ],
            );
          }),
          Obx(() {
            final isFocusLayout = controller.layout.value == MultiviewLayout.focus;
            final enabled = controller.smallCellsLowQuality.value;
            final theme = Theme.of(context);

            return IconButton(
              tooltip: i18n('multiview_small_low_quality'),
              icon: Icon(
                Remix.speed_mini_line,
                size: 22,
                color: enabled ? theme.colorScheme.primary : theme.colorScheme.onSurfaceVariant,
              ),
              onPressed: isFocusLayout ? () => controller.smallCellsLowQuality.toggle() : null,
            );
          }),
          IconButton(
            tooltip: i18n('multiview_preset'),
            icon: const Icon(Remix.bookmark_line, size: 22),
            onPressed: _showPresetSheet,
          ),
        ],
      );
    }

    if (compact) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(12, 6, 12, 4),
        child: Column(
          children: [
            Center(
              child: FittedBox(fit: BoxFit.scaleDown, child: buildLayoutSelector()),
            ),
            const SizedBox(height: 2),
            Align(alignment: Alignment.centerRight, child: buildActions()),
          ],
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
      child: Row(
        children: [
          Expanded(child: Center(child: buildLayoutSelector())),
          const SizedBox(width: 8),
          buildActions(),
        ],
      ),
    );
  }

  Widget _buildSidePanel() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: Text(
            i18n('multiview_pick_for_cell', args: {'index': '${_targetCell + 1}'}),
            style: AppTextStyles.t15Bold,
          ),
        ),
        Expanded(
          child: MultiviewRoomPicker(cellIndex: _targetCell, onPicked: _pickRoom),
        ),
      ],
    );
  }

  Widget _buildGrid({required bool isWide}) {
    return Obx(() {
      final layout = controller.layout.value;
      final cells = controller.cells;
      // 在 Obx 内读取以建立订阅：晋升、声音来源与弹幕开关变化即时驱动重绘。
      final focused = controller.focusedCellIndex.value;
      final content = layout == MultiviewLayout.focus
          ? _buildFocusLayout(cells, focused: focused, isWide: isWide)
          : Column(
              children: [
                for (var row = 0; row < layout.rows; row++)
                  Expanded(
                    child: Row(
                      children: [
                        for (var col = 0; col < layout.columns; col++)
                          Expanded(
                            child: Padding(
                              padding: const EdgeInsets.all(3),
                              child: _buildCellAt(
                                cells,
                                row * layout.columns + col,
                                isWide: isWide,
                                showDanmaku: controller.shouldRenderDanmaku(row * layout.columns + col),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
              ],
            );
      return Padding(padding: const EdgeInsets.all(6), child: content);
    });
  }

  /// 一大多小布局：左侧大格（当前聚焦格）+ 右侧可滚动小列。
  ///
  /// 窄屏保持同一形态，不做上下变体。格子子树经 GlobalKey 搬移，
  /// 晋升切换只改变位置，不重建播放画面。小列首屏恰容纳
  /// [_focusSmallViewportCells] 格，追加格滚动呈现，列尾附「添加画面」槽。
  Widget _buildFocusLayout(List<MultiviewCellState> cells, {required int focused, required bool isWide}) {
    // 核心层已在缩容/释放时钳制 focusedCellIndex，此处再钳一次防竞态越界。
    final bigIndex = focused.clamp(0, cells.length - 1);
    final others = [
      for (var i = 0; i < cells.length; i++)
        if (i != bigIndex) i,
    ];
    return Row(
      children: [
        Expanded(
          flex: _focusBigFlex,
          child: Padding(
            padding: const EdgeInsets.all(3),
            child: _buildCellAt(
              cells,
              bigIndex,
              isWide: isWide,
              showDanmaku: controller.shouldRenderDanmaku(bigIndex),
              // 控制条可见时隐藏左下角清晰度 chip：入口已在控制条内。
              showQualityEntry: !_controlsVisible.contains(bigIndex),
            ),
          ),
        ),
        Expanded(
          flex: _focusSmallFlex,
          child: LayoutBuilder(
            builder: (context, boxConstraints) {
              // 固定行高 = 视口高 / 首屏格数：前三格铺满视口，超出滚动。
              final extent = boxConstraints.maxHeight / _focusSmallViewportCells;
              final canAdd = controller.canAddCell;
              // 常驻全部子项（SingleChildScrollView + Column），不做虚拟化：
              // maxCells=9、首屏 3 格的规模下虚拟化是纯负收益——滚动会反复
              // 销毁/重建 Video（Windows 共享渲染线程纹理重附开销大），且把
              // GlobalKey 零重建降级为仅视口内成立。滚动行为不变。
              return SingleChildScrollView(
                child: Column(
                  children: [
                    for (final index in others)
                      SizedBox(
                        height: extent,
                        child: Padding(
                          padding: const EdgeInsets.all(3),
                          child: _buildCellAt(
                            cells,
                            index,
                            isWide: isWide,
                            showDanmaku: controller.shouldRenderDanmaku(index),
                          ),
                        ),
                      ),
                    if (canAdd)
                      SizedBox(
                        height: extent,
                        child: Padding(
                          padding: const EdgeInsets.all(3),
                          child: _AddCellSlot(onTap: () => unawaited(controller.addCell())),
                        ),
                      ),
                  ],
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  /// 单格播放控制条：按钮集对齐 live_play 底部栏——
  /// 播放暂停、刷新、弹幕开关、弹幕设置、清晰度、线路、音量、全屏。
  ///
  /// 逐格模式（Windows）下每格都能呼出（见 [_controlsVisible]）；
  /// 非逐格模式仅 focus 大格会显示。按钮用紧凑密度 + FittedBox 兜底缩放，
  /// 保证一大多小的右侧窄列也不溢出。
  Widget _buildCellControlBar(List<MultiviewCellState> cells, int index) {
    final state = cells[index];
    final iconColor = Colors.white.withValues(alpha: 0.92);
    return FittedBox(
      fit: BoxFit.scaleDown,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
        decoration: BoxDecoration(color: Colors.black.withValues(alpha: 0.55), borderRadius: BorderRadius.circular(10)),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Obx(() {
              final playing = controller.playingFlags[index];
              return _controlBarButton(
                icon: playing ? Remix.pause_line : Remix.play_line,
                tooltip: i18n(playing ? 'multiview_pause' : 'multiview_play'),
                onTap: () => unawaited(controller.toggleCellPlayPause(index)),
              );
            }),
            _controlBarButton(
              icon: Remix.refresh_line,
              tooltip: i18n('multiview_refresh'),
              onTap: () {
                final room = state.room;
                if (room != null) unawaited(controller.assignRoom(index, room));
              },
            ),
            Obx(() {
              final enabled = controller.danmakuEnabled.value;
              return _controlBarButton(
                icon: CustomIcons.danmaku_open,
                tooltip: i18n('danmaku'),
                iconColor: enabled ? Theme.of(context).colorScheme.primary : iconColor,
                // 弹幕为页级总开关：与工具条入口同源，一次操作作用于全部画面。
                onTap: () => controller.danmakuEnabled.toggle(),
              );
            }),
            _controlBarButton(
              icon: Remix.settings_3_line,
              tooltip: i18n('multiview_danmaku_settings'),
              onTap: _showDanmakuSettings,
            ),
            _controlBarButton(
              icon: Remix.hd_line,
              tooltip: i18n('select_quality'),
              onTap: () => _showQualitySheet(state),
            ),
            if (state.lines.length > 1)
              _controlBarButton(
                icon: Remix.route_line,
                tooltip: i18n('multiview_line_selector'),
                onTap: () => _showLineSheet(state),
              ),
            _controlBarButton(
              icon: Remix.volume_down_line,
              tooltip: i18n('multiview_volume'),
              onTap: () => _showVolumeSheet(index),
            ),
            _controlBarButton(
              icon: _displayMode == _DisplayMode.fullscreen ? Remix.fullscreen_exit_line : Remix.fullscreen_line,
              tooltip: i18n('multiview_fullscreen'),
              onTap: () => unawaited(
                _changeDisplayMode(
                  _displayMode == _DisplayMode.fullscreen ? _DisplayMode.normal : _DisplayMode.fullscreen,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 控制条按钮：视频上的白色图标，紧凑密度以适应小格宽度。
  Widget _controlBarButton({
    required IconData icon,
    required String tooltip,
    required VoidCallback onTap,
    Color? iconColor,
  }) {
    return IconButton(
      tooltip: tooltip,
      iconSize: 18,
      visualDensity: VisualDensity.compact,
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints.tightFor(width: 34, height: 34),
      icon: Icon(icon, color: iconColor ?? Colors.white.withValues(alpha: 0.92)),
      onPressed: onTap,
    );
  }

  /// 线路选择弹窗（形态与清晰度弹窗一致）。
  void _showLineSheet(MultiviewCellState state) {
    if (state.lines.isEmpty) return;
    showModalBottomSheet(
      context: context,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (var i = 0; i < state.lines.length; i++)
              ListTile(
                title: Text(i18n('multiview_line', args: {'index': '${i + 1}'})),
                trailing: i == state.lineIndex ? const Icon(Icons.check_rounded) : null,
                onTap: () {
                  Navigator.of(sheetContext).pop();
                  unawaited(controller.setCellLine(state.index, i));
                },
              ),
          ],
        ),
      ),
    );
  }

  /// 音量调节弹窗：拖动即时下发并保存所选房间音量（0.0-1.0）。
  void _showVolumeSheet(int cellIndex) {
    var value = controller.cellVolume(cellIndex);
    final room = controller.cells[cellIndex].room;
    showModalBottomSheet(
      context: context,
      builder: (sheetContext) => StatefulBuilder(
        builder: (sheetContext, setSheetState) => SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        room?.nick?.trim().isNotEmpty == true ? room!.nick! : i18n('multiview_volume'),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(sheetContext).textTheme.titleMedium,
                      ),
                    ),
                    Text('${(value * 100).round()}%'),
                  ],
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    const Icon(Remix.volume_down_line),
                    Expanded(
                      child: Slider(
                        value: value,
                        onChanged: (v) {
                          setSheetState(() => value = v);
                          unawaited(controller.setCellVolume(cellIndex, v));
                        },
                      ),
                    ),
                    const Icon(Remix.volume_up_line),
                  ],
                ),
                Text(
                  i18n('room_volume'),
                  style: Theme.of(sheetContext).textTheme.bodySmall
                      ?.copyWith(color: Theme.of(sheetContext).colorScheme.onSurfaceVariant),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 弹幕设置面板：复用 live_play 官方面板（含位置预设/显示区域），
  /// 经 [MultiviewDanmakuSettingsBinding] 透传全局设置。
  void _showDanmakuSettings() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (sheetContext) => SizedBox(
        height: MediaQuery.of(sheetContext).size.height * 0.72,
        child: DanmakuSettingsContent(controller: MultiviewDanmakuSettingsBinding(), embedded: true),
      ),
    );
  }

  /// 格子点击的统一语义。
  ///
  /// 逐格模式（Windows）：点按呼出/隐藏该格控制条。音频焦点已不再决定
  /// 声源（所有格可同时出声），点按因此让位给控制条入口；晋升改为经
  /// 长按菜单入口。
  /// 非逐格模式：保持既有交互——focus 小格晋升、focus 大格切控制条、
  /// 其余布局切换音频焦点。
  void _handleCellTap(List<MultiviewCellState> cells, int index, {required bool isWide}) {
    switch (cells[index].status) {
      case MultiviewCellStatus.playing:
        if (controller.perCellMode) {
          _toggleCellControls(index);
          return;
        }
        // 一大多小下点击小格 = 晋升为大画面（声源跟随大画面）；
        // 晋升后全部控制条复位收起。
        if (controller.layout.value == MultiviewLayout.focus && controller.focusedCellIndex.value != index) {
          unawaited(controller.promoteCell(index)); // focusedCellIndex 为 Rx，Obx 自行重绘
          _controlsVisible.clear();
          setState(() {});
          return;
        }
        // focus 大格点击 = 切换控制条显隐（对齐 live_play 点按呼出
        // 控制条的交互）；其余布局维持原音频焦点行为。
        if (controller.layout.value == MultiviewLayout.focus) {
          _toggleCellControls(index);
          return;
        }
        unawaited(controller.setAudioFocus(index));
      case MultiviewCellStatus.empty || MultiviewCellStatus.offline || MultiviewCellStatus.error:
        _openPickerFor(index, isWide: isWide);
      case MultiviewCellStatus.resolving:
        break;
    }
  }

  void _toggleCellControls(int index) {
    setState(() {
      if (!_controlsVisible.remove(index)) {
        _controlsVisible.add(index);
      }
    });
  }

  Widget _buildCellAt(
    List<MultiviewCellState> cells,
    int index, {
    required bool isWide,
    bool showDanmaku = false,
    bool showQualityEntry = false,
  }) {
    final state = cells[index];
    final status = state.status;
    final showControls = _controlsVisible.contains(index) && status == MultiviewCellStatus.playing;
    return Listener(
      key: _cellKey(index),
      onPointerSignal: (event) => _handleCellScroll(event, index),
      child: Stack(
        fit: StackFit.expand,
        children: [
          _MultiviewCellView(
            state: state,
            // 逐格模式下所有格都出声，「声音来源」角标不再成立，隐藏以免误导。
            isAudioFocus:
                !controller.perCellMode && controller.audioFocusIndex == index && status == MultiviewCellStatus.playing,
            isPickTarget: _targetCell == index && isMultiviewCellAssignable(status),
            showDanmaku: showDanmaku && status == MultiviewCellStatus.playing && state.videoController != null,
            barrageController: controller.barrageControllerFor(index),
            showQualityEntry: showQualityEntry,
            onSelectQuality: (qualityIndex) => unawaited(controller.setCellQuality(index, qualityIndex)),
            onTap: () => _handleCellTap(cells, index, isWide: isWide),
            onLongPress: status == MultiviewCellStatus.playing ? () => _showCellActions(state) : null,
            onRetry: () => _retryCell(state),
          ),
          if (showControls) Positioned(left: 6, right: 6, bottom: 6, child: _buildCellControlBar(cells, index)),
        ],
      ),
    );
  }

  /// 格子上的滚轮 = 调该格音量（仅逐格模式）。
  ///
  /// 一大多小的小列外层是 SingleChildScrollView：滚动信号由
  /// [PointerSignalResolver] 裁决。本 Listener 位于滚动容器内层，会先于
  /// Scrollable 注册，因此必须显式抢占——否则滚轮会被列表滚动吃掉。
  void _handleCellScroll(PointerSignalEvent event, int index) {
    if (!controller.perCellMode || event is! PointerScrollEvent) return;
    // 缩容与滚轮事件可能交错：越界下标直接放弃，避免异步音量调用抛出。
    if (index < 0 || index >= controller.cells.length) return;
    final dy = event.scrollDelta.dy;
    if (dy == 0) return;
    GestureBinding.instance.pointerSignalResolver.register(event, (_) {
      unawaited(_stepCellVolume(index, dy < 0 ? _volumeStep : -_volumeStep));
    });
  }
}

/// 单格视图：按生命周期状态渲染播放画面、空态、加载与错误占位。
///
/// 「声音来源」角标由页面按音频焦点折算传入——逐格模式（Windows）下
/// 所有格同时出声，该角标不再显示；目标空格以待选描边提示。
/// 弹幕层与清晰度入口同样由页面按格状态与布局折算后传入。
class _MultiviewCellView extends StatelessWidget {
  const _MultiviewCellView({
    required this.state,
    required this.isAudioFocus,
    required this.isPickTarget,
    required this.onTap,
    required this.onLongPress,
    required this.onRetry,
    required this.barrageController,
    required this.onSelectQuality,
    this.showDanmaku = false,
    this.showQualityEntry = false,
  });

  final MultiviewCellState state;
  final bool isAudioFocus;
  final bool isPickTarget;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;
  final VoidCallback onRetry;

  /// 在大画面上层叠弹幕；由页面按 danmakuEnabled 折算后传入。
  final bool showDanmaku;

  /// 该格专属弹幕渲染入口；缩容等瞬态下可能为 null。
  final BarrageController? barrageController;

  /// 是否显示清晰度入口（仅 focus 布局大画面为 true）。
  final bool showQualityEntry;
  final ValueChanged<int> onSelectQuality;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final videoController = state.videoController;
    final showVideo = state.status == MultiviewCellStatus.playing && videoController != null;
    final isDark = theme.brightness == Brightness.dark;

    return AnimatedContainer(
      duration: const Duration(milliseconds: 200),
      curve: Curves.easeOut,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(color: showVideo || isDark ? Colors.black : theme.colorScheme.surfaceContainerLow),
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          onTap: onTap,
          onLongPress: onLongPress,
          onSecondaryTap: onLongPress,
          child: _buildContent(theme),
        ),
      ),
    );
  }

  Widget _buildContent(ThemeData theme) {
    final videoController = state.videoController;
    final barrage = barrageController;
    if (state.status == MultiviewCellStatus.playing && videoController != null) {
      final video = Video(
        controller: videoController,
        controls: NoVideoControls,
        // multiview 页面自持每格生命周期，禁用 Video 内置的后台暂停策略，
        // 与主播放器 LivePlay 的单一生命周期权威原则保持一致。
        pauseUponEnteringBackgroundMode: false,
        resumeUponEnteringForegroundMode: false,
      );
      final videoSurface = PlatformUtils.isWindows
          ? VideoOutputViewportSizer(
              outputIdentity: videoController,
              sourceWidth: videoController.player.stream.width,
              sourceHeight: videoController.player.stream.height,
              onResize: (width, height, force) => videoController.setSize(width: width, height: height, force: force),
              child: video,
            )
          : video;
      return Stack(
        fit: StackFit.expand,
        children: [
          videoSurface,
          // 弹幕层：逐格模式（Windows）下每格各自渲染；IgnorePointer
          // 保证不遮挡格子手势。
          if (showDanmaku && barrage != null)
            Positioned.fill(
              child: IgnorePointer(
                // 独立 Obx：_buildBarrageConfig 在订阅作用域内读取全部弹幕
                // 设置 Rx（字号/速度/透明度/区域/描边/字体/FPS），全局设置
                // 变化即时重绘弹幕层（对照 live_play DanmakuViewer 整段
                // Obx 包裹的做法）。格子子树的 build 不在父级 Obx 作用域内，
                // 不包裹则设置变化永远不会触达这里。
                child: Obx(() {
                  // refreshRateMode 是由该 Rx 派生的普通 getter，
                  // 显式订阅其响应源以覆盖自动帧率模式切换。
                  SettingsService.to.app.refreshRateModeName.v;
                  return FlameBarrageWidget(
                    controller: barrage,
                    enablePointerEvents: false,
                    config: _buildBarrageConfig(),
                    emojiAtlas: EmojiAtlas.instance,
                  );
                }),
              ),
            ),
          Positioned(
            top: 8,
            left: 8,
            right: 8,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                _RoomNameChip(state: state),
                if (isAudioFocus) ...[const SizedBox(width: 6), const _AudioFocusBadge()],
              ],
            ),
          ),
          if (showQualityEntry) Positioned(left: 8, bottom: 8, child: _buildQualityEntry(theme)),
        ],
      );
    }
    return switch (state.status) {
      MultiviewCellStatus.empty => _buildEmptyContent(theme),
      MultiviewCellStatus.resolving => _buildResolvingContent(),
      MultiviewCellStatus.offline => _buildOfflineContent(theme),
      MultiviewCellStatus.error => _buildErrorContent(theme),
      // playing 但渲染控制器尚未就绪的瞬间：黑场等待即可。
      MultiviewCellStatus.playing => const SizedBox.shrink(),
    };
  }

  /// 清晰度是否可选：qualities 为空（解析中/失败/不支持换档）时置灰。
  bool get _qualityAvailable =>
      state.status == MultiviewCellStatus.playing && state.qualities.isNotEmpty && state.qualityLoader != null;

  /// 大画面左下角清晰度入口：形态对齐 live_play 的 ResolutionSelector，
  /// 底色改为视频上的半透明黑以保证可读性。
  Widget _buildQualityEntry(ThemeData theme) {
    if (!_qualityAvailable) return const SizedBox.shrink();
    final currentName = state.qualities[state.qualityIndex.clamp(0, state.qualities.length - 1)].quality;
    return PopupMenuButton<int>(
      tooltip: i18n('select_quality'),
      color: theme.colorScheme.surfaceContainerHighest,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      offset: const Offset(0, 5),
      position: PopupMenuPosition.under,
      onSelected: onSelectQuality,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(color: Colors.black.withValues(alpha: 0.55), borderRadius: BorderRadius.circular(10)),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Remix.equalizer_line, size: 12, color: Colors.white),
            const SizedBox(width: 4),
            Text(
              currentName,
              style: AppTextStyles.t11.copyWith(color: Colors.white, fontWeight: FontWeight.w600),
            ),
          ],
        ),
      ),
      itemBuilder: (context) => [
        for (var i = 0; i < state.qualities.length; i++)
          PopupMenuItem<int>(
            value: i,
            child: Text(
              state.qualities[i].quality,
              style: AppTextStyles.t13.copyWith(
                color: i == state.qualityIndex ? theme.colorScheme.primary : null,
                fontWeight: i == state.qualityIndex ? FontWeight.w700 : null,
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildEmptyContent(ThemeData theme) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 54,
            height: 54,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.6),
            ),
            child: Icon(Remix.add_circle_line, size: 26, color: theme.colorScheme.onSurfaceVariant),
          ),
          const SizedBox(height: 12),
          Text(i18n('multiview_empty_cell_hint'), style: AppTextStyles.t14Medium),
        ],
      ),
    );
  }

  Widget _buildResolvingContent() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const CircularProgressIndicator(strokeWidth: 2.5),
          if ((state.room?.nick ?? '').isNotEmpty) ...[
            const SizedBox(height: 10),
            Text(state.room!.nick!, maxLines: 1, overflow: TextOverflow.ellipsis, style: AppTextStyles.t12Muted),
          ],
        ],
      ),
    );
  }

  Widget _buildOfflineContent(ThemeData theme) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Remix.live_line, size: 30, color: theme.colorScheme.onSurfaceVariant),
          const SizedBox(height: 10),
          Text(i18n('multiview_room_offline'), style: AppTextStyles.t14Bold, textAlign: TextAlign.center),
          if ((state.room?.nick ?? '').isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(state.room!.nick!, maxLines: 1, overflow: TextOverflow.ellipsis, style: AppTextStyles.t12Muted),
          ],
          const SizedBox(height: 6),
          Text(i18n('multiview_room_offline_hint'), style: AppTextStyles.t12Muted, textAlign: TextAlign.center),
        ],
      ),
    );
  }

  Widget _buildErrorContent(ThemeData theme) {
    final kind = state.errorKind;
    final detailMessage = kind == null
        ? ''
        : i18n(
            switch (kind) {
              MultiviewCellErrorKind.resolveFailure => 'multiview_error_resolve',
              MultiviewCellErrorKind.startFailure => 'multiview_error_start',
            },
            args: {'detail': state.errorDetail ?? ''},
          );
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Remix.error_warning_line, size: 30, color: theme.colorScheme.error),
          const SizedBox(height: 10),
          Text(i18n('multiview_play_failed'), style: AppTextStyles.t14Bold, textAlign: TextAlign.center),
          if (detailMessage.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(
              detailMessage,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: AppTextStyles.t12Muted,
            ),
          ],
          const SizedBox(height: 16),
          FilledButton.tonalIcon(
            onPressed: onRetry,
            icon: const Icon(Remix.refresh_line, size: 16),
            label: Text(i18n('retry')),
          ),
        ],
      ),
    );
  }
}

/// 播放中格子左上角的房间名条：平台徽标 + 主播昵称。
class _RoomNameChip extends StatelessWidget {
  const _RoomNameChip({required this.state});

  final MultiviewCellState state;

  @override
  Widget build(BuildContext context) {
    final nick = state.room?.nick ?? '';
    final platform = state.room?.platform?.trim().toLowerCase() ?? '';
    final hasLogo = Sites.isSupported(platform);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(color: Colors.black.withValues(alpha: 0.55), borderRadius: BorderRadius.circular(10)),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (hasLogo) ...[Image.asset(Sites.of(platform).logo, width: 13, height: 13), const SizedBox(width: 5)],
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 120),
            child: Text(
              nick,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: AppTextStyles.t11.copyWith(color: Colors.white, fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
    );
  }
}

/// 音频焦点角标：主色底 + 音量图标，标记当前出声的格子。
class _AudioFocusBadge extends StatelessWidget {
  const _AudioFocusBadge();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(color: Theme.of(context).colorScheme.primary, borderRadius: BorderRadius.circular(10)),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Remix.volume_up_line, size: 13, color: Colors.white),
          const SizedBox(width: 4),
          Text(
            i18n('multiview_audio_focus_badge'),
            style: AppTextStyles.t11.copyWith(color: Colors.white, fontWeight: FontWeight.w700),
          ),
        ],
      ),
    );
  }
}

/// 大画面弹幕配置。
///
/// 结构照抄 live_play 的 DanmakuViewer（video_controller_panel.dart）既有
/// 配置；字号/速度/区域等取全局弹幕设置默认值，池容量沿用同组常量。
BarrageConfig _buildBarrageConfig() {
  final settings = SettingsService.to.danmaku;
  return BarrageConfig(
    emitInterval: 0.05,
    fontSize: settings.danmakuFontSize.v,
    topAreaDistance: settings.danmakuTopArea.v,
    area: settings.danmakuArea.v,
    bottomAreaDistance: settings.danmakuBottomArea.v,
    baseSpeed: settings.danmakuSpeed.v,
    opacity: settings.danmakuOpacity.v,
    fontWeight: FontWeight(settings.danmakuFontWeight.v),
    strokeWidth: settings.danmakuFontBorder.v,
    showStroke: settings.enableDanmakuStroke.v,
    noEmojiMode: settings.noEmojiMode.v,
    fps: settings.danmakuAutoFps.v
        ? settings.resolvedDanmakuFps(refreshRateMode: SettingsService.to.app.refreshRateMode)
        : settings.danmakuFps.v.clamp(30, 240).toInt(),
    maxVisibleCount: 48,
    maxPendingCount: 120,
    maxPendingAge: const Duration(seconds: 5),
    fontFamily: settings.danmakuFontFamilyName.v,
    trackHeight: (settings.danmakuFontSize.v * 1.55).clamp(24.0, 64.0).toDouble(),
    emojiSize: (settings.danmakuFontSize.v * 1.3).clamp(16.0, 48.0).toDouble(),
    pictureCacheMaxSize: 96,
    barragePoolMaxSize: 72,
    textCacheMaxSize: 320,
  );
}

/// 一大多小小列尾部的「添加画面」占位槽。
class _AddCellSlot extends StatelessWidget {
  const _AddCellSlot({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      type: MaterialType.transparency,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: theme.colorScheme.primary.withValues(alpha: 0.35), width: 1.5),
            color: theme.colorScheme.surfaceContainerLow.withValues(alpha: 0.4),
          ),
          child: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Remix.add_circle_line, size: 22, color: theme.colorScheme.primary),
                const SizedBox(height: 6),
                Text(
                  i18n('multiview_add_cell'),
                  style: AppTextStyles.t12.copyWith(color: theme.colorScheme.primary, fontWeight: FontWeight.w600),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 沉浸模式右下角的悬浮恢复钮。
class _ImmersiveRestoreButton extends StatelessWidget {
  const _ImmersiveRestoreButton({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Tooltip(
      message: i18n('multiview_immersive_exit'),
      child: Material(
        color: theme.colorScheme.surfaceContainerHigh.withValues(alpha: 0.92),
        borderRadius: BorderRadius.circular(14),
        elevation: 2,
        shadowColor: Colors.black.withValues(alpha: 0.2),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(14),
          child: Padding(
            padding: const EdgeInsets.all(10),
            child: Icon(Remix.collapse_diagonal_line, size: 20, color: theme.colorScheme.onSurface),
          ),
        ),
      ),
    );
  }
}
