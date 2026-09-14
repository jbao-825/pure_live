import 'dart:async';

import 'package:flutter/material.dart';
import 'package:pure_live/plugins/locale_helper.dart';
import 'package:pure_live/common/global/platform_utils.dart';
import 'package:pure_live/common/services/utils/hive_rx.dart';
import 'package:pure_live/common/services/settings_service.dart';
import 'package:pure_live/player/core/desktop_volume_policy.dart';
import 'package:pure_live/modules/live_play/widgets/video_player/desktop_volume_notice.dart';
import 'package:pure_live/modules/live_play/widgets/video_player/video_controller.dart';

/// Desktop (Windows/Linux) volume control.
///
/// The player may amplify live audio up to 150%, but the boosted range is
/// gated by [DesktopVolumePolicy]: the first approach to the 100% cap only
/// warns about the high-volume risk and holds the cap, and only a **separate**
/// following upward drag may enter 100%-150%. The gate lives in the room's
/// [VideoController], so opening or switching a room always asks again, and the
/// temporary boost is never written to the persisted volume.
class OverlayVolumeControl extends StatefulWidget {
  final VideoController controller;
  const OverlayVolumeControl({super.key, required this.controller});

  @override
  State<OverlayVolumeControl> createState() => _OverlayVolumeControlState();
}

class _OverlayVolumeControlState extends State<OverlayVolumeControl> {
  double _volume = 0.5;
  double _lastVolume = 0.5;
  /// Unquantized accumulator for the running drag: the 5% grid would otherwise
  /// swallow sub-step pointer movement and make the bar feel dead.
  double _dragValue = 0.5;
  /// Whether the next drag sample opens a new adjustment. One drag gesture is
  /// exactly one adjustment, so two gestures can never merge into an accidental
  /// boost.
  bool _startsNewAdjustment = false;
  /// Local mirror used only for the bar hint; the authoritative gate state
  /// stays inside the room's controller.
  bool _awaitingBoostConfirm = false;
  OverlayEntry? _overlayEntry;
  final LayerLink _layerLink = LayerLink();
  bool _isMouseInIcon = false;
  bool _isMouseInBar = false;
  Timer? _hideTimer;
  StreamSubscription? _volumeListener;
  StreamSubscription? _platformVolWorker;
  int _controllerGeneration = 0;
  int _valueRevision = 0;
  StreamSubscription? _controllerVolumeSub;
  static const double _barHeight = 150.0;
  static const double _barWidth = 44.0;

  VideoController get controller => widget.controller;

  @override
  void initState() {
    super.initState();
    _listenGlobalVolume();
    _bindController();
  }

  @override
  void didUpdateWidget(covariant OverlayVolumeControl oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (identical(oldWidget.controller, controller)) return;
    _hideTimer?.cancel();
    _removeOverlay(owner: oldWidget.controller);
    _isMouseInIcon = false;
    _bindController();
  }

  @override
  void dispose() {
    _controllerGeneration++;
    _valueRevision++;
    _hideTimer?.cancel();
    _volumeListener?.cancel();
    _platformVolWorker?.cancel();
    _controllerVolumeSub?.cancel();
    _removeOverlay();
    super.dispose();
  }

  void _listenGlobalVolume() {
    final v = SettingsService.to.vol;
    _volumeListener = v.globalVolumeMute.stream.listen((_) => _updateVolumeFromGlobal());
    final platformDefault = PlatformUtils.isMobile ? v.defaultMobileVolume : v.defaultDesktopVolume;
    _platformVolWorker = platformDefault.stream.listen((_) => _updateVolumeFromGlobal());
  }

  bool _owns(VideoController owner, int generation) =>
      mounted && generation == _controllerGeneration && identical(controller, owner);

  void _bindController() {
    _controllerVolumeSub?.cancel();
    final owner = controller;
    final generation = ++_controllerGeneration;
    _valueRevision++;
    // A fresh controller means a fresh room session, which always starts
    // unconfirmed even when the previous room had reached the boosted range.
    _awaitingBoostConfirm = false;
    final initial = owner.currentVolume.value;
    _volume = _normalized(initial, fallback: 0.5);
    _dragValue = _volume;
    _lastVolume = _volume > 0 ? _volume : 0.5;
    _controllerVolumeSub = owner.currentVolume.stream.listen((value) {
      if (!_owns(owner, generation) || !value.isFinite) return;
      // Even an equal-valued event supersedes a pending initial query.
      _valueRevision++;
      _displayVolume(value);
    });
    unawaited(initVolume(owner, generation));
  }

  static double _normalized(double value, {required double fallback}) {
    if (!value.isFinite) return fallback;
    return value.clamp(0.0, DesktopVolumePolicy.maxVolume).toDouble();
  }

  void _displayVolume(double value) {
    final resolved = _normalized(value, fallback: _volume);
    setState(() {
      _volume = resolved;
      _dragValue = resolved;
      if (resolved > 0) _lastVolume = resolved;
      if (resolved != DesktopVolumePolicy.safeVolume) _awaitingBoostConfirm = false;
    });
    _overlayEntry?.markNeedsBuild();
  }

  void _updateVolumeFromGlobal() {
    if (!mounted) return;
    final v = SettingsService.to.vol;
    final raw = PlatformUtils.isMobile ? v.defaultMobileVolume.v : v.defaultDesktopVolume.v;
    if (!raw.isFinite) return;
    // Global defaults are always the safe 0-100% value; they never carry the
    // session-scoped desktop boost.
    final platformVolume = raw.clamp(0.0, DesktopVolumePolicy.safeVolume).toDouble();
    _valueRevision++;
    setState(() {
      _awaitingBoostConfirm = false;
      if (v.globalVolumeMute.v) {
        if (_volume > 0) _lastVolume = _volume;
        _volume = 0.0;
      } else {
        _volume = platformVolume;
        _lastVolume = _volume;
      }
      _dragValue = _volume;
    });

    controller.setVolume(_volume);
    _overlayEntry?.markNeedsBuild();
  }

  Future<void> initVolume(VideoController owner, int generation) async {
    final revision = _valueRevision;
    try {
      final volume = await owner.volume();
      if (!_owns(owner, generation) || revision != _valueRevision || volume == null || !volume.isFinite) return;
      _displayVolume(volume);
    } catch (error) {
      // Keep the bound controller's current value if its optional query fails.
      debugPrint('Volume overlay initial read failed: $error');
    }
  }

  void _handleToggleMute() {
    _valueRevision++;
    setState(() {
      if (_volume > 0) {
        _lastVolume = _volume;
        _volume = 0;
      } else {
        // Restores the room's actual volume, including a 100%-150% boost.
        _volume = _lastVolume > 0 ? _lastVolume : 0.5;
      }
      _dragValue = _volume;
      if (_volume != DesktopVolumePolicy.safeVolume) _awaitingBoostConfirm = false;
    });
    controller.setVolume(_volume);
    _overlayEntry?.markNeedsBuild();
  }

  void _showVolumeBar() {
    if (_overlayEntry != null || !mounted) return;
    final owner = controller;
    final generation = _controllerGeneration;

    _overlayEntry = OverlayEntry(
      builder: (context) => Positioned(
        width: _barWidth,
        height: _barHeight + 45,
        child: CompositedTransformFollower(
          link: _layerLink,
          showWhenUnlinked: false,
          followerAnchor: Alignment.bottomCenter,
          targetAnchor: Alignment.topCenter,
          offset: const Offset(0, 5),
          child: MouseRegion(
            onEnter: (_) {
              if (!_owns(owner, generation)) return;
              _isMouseInBar = true;
              owner.stopHideController();
            },
            onExit: (_) {
              if (!_owns(owner, generation)) return;
              _isMouseInBar = false;
              owner.enableController();
              _startHideTimer();
            },
            child: _buildVolumeBarUI(),
          ),
        ),
      ),
    );

    Overlay.of(context).insert(_overlayEntry!);
  }

  void _startHideTimer() {
    _hideTimer?.cancel();
    _hideTimer = Timer(const Duration(milliseconds: 150), () {
      if (!_isMouseInIcon && !_isMouseInBar) {
        _removeOverlay();
      }
    });
  }

  void _removeOverlay({VideoController? owner}) {
    _overlayEntry?.remove();
    _overlayEntry?.dispose();
    _overlayEntry = null;
    if (_isMouseInBar) {
      (owner ?? controller).enableController();
      _isMouseInBar = false;
    }
  }

  Widget _buildVolumeBarUI() {
    final bool boosted = _volume > DesktopVolumePolicy.safeVolume;
    final bool awaitingBoost = _awaitingBoostConfirm && !boosted;
    final int percentage = (_volume * 100).round();
    final Color levelColor = boosted ? const Color(0xFFFFB300) : Colors.white;

    return Material(
      color: Colors.transparent,
      child: Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: Container(
          decoration: BoxDecoration(
            color: Colors.black.withAlpha(220),
            borderRadius: BorderRadius.circular(22),
            border: Border.all(color: Colors.white10),
          ),
          child: Column(
            children: [
              const SizedBox(height: 10),
              Text(
                "$percentage%",
                style: TextStyle(color: levelColor, fontSize: 11, fontWeight: FontWeight.bold),
              ),
              if (awaitingBoost)
                const Padding(
                  padding: EdgeInsets.only(top: 2),
                  child: Icon(Icons.warning_amber_rounded, size: 13, color: Color(0xFFFFB300)),
                ),
              Expanded(
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    // The track spans the same 0-150% range as the control, so
                    // the boosted range is visible instead of staying hidden
                    // behind a saturated 100% fill.
                    final double trackHeight = constraints.maxHeight;
                    final double usable = (trackHeight - 30).clamp(0.0, double.infinity).toDouble();
                    final double ratio = DesktopVolumePolicy.trackRatio(_volume);
                    final double safeRatio = DesktopVolumePolicy.trackRatio(DesktopVolumePolicy.safeVolume);
                    return GestureDetector(
                      key: const ValueKey('volume-bar-track'),
                      behavior: HitTestBehavior.opaque,
                      onVerticalDragStart: (_) => _handleVolumeDragStart(),
                      onVerticalDragUpdate: (details) => _handleVolumeDrag(details, usable),
                      child: Stack(
                        alignment: Alignment.bottomCenter,
                        children: [
                          Container(
                            width: 4,
                            margin: const EdgeInsets.only(top: 10, bottom: 20),
                            decoration: BoxDecoration(color: Colors.white24, borderRadius: BorderRadius.circular(2)),
                          ),
                          // 100% reference line: the boundary between normal and
                          // gated high volume.
                          Positioned(
                            bottom: 20 + safeRatio * usable,
                            child: Container(width: 18, height: 1, color: const Color(0x66FFB300)),
                          ),
                          Positioned(
                            bottom: 20,
                            child: Container(
                              width: 4,
                              height: ratio * usable,
                              decoration: BoxDecoration(color: levelColor, borderRadius: BorderRadius.circular(2)),
                            ),
                          ),
                          Positioned(
                            bottom: 20 + ratio * usable - 6,
                            child: Container(
                              width: 12,
                              height: 12,
                              decoration: BoxDecoration(color: levelColor, shape: BoxShape.circle),
                            ),
                          ),
                        ],
                      ),
                    );
                  },
                ),
              ),
              const SizedBox(height: 8),
            ],
          ),
        ),
      ),
    );
  }

  void _handleVolumeDragStart() {
    _startsNewAdjustment = true;
    _dragValue = _volume;
  }

  void _handleVolumeDrag(DragUpdateDetails details, double trackHeight) {
    if (trackHeight <= 0) return;
    // Upward movement increases volume: the track covers the full 0-150% range.
    final double deltaRatio = -details.delta.dy / trackHeight;
    _dragValue = (_dragValue + deltaRatio * DesktopVolumePolicy.maxVolume).clamp(0.0, DesktopVolumePolicy.maxVolume);
    final request = controller.requestDesktopVolume(
      // Only the first sample of the gesture opens a new adjustment; the rest
      // keep the one it started, which is what makes a single long drag stop at
      // 100% instead of walking through the confirmation.
      startsNewAdjustment: _startsNewAdjustment,
      target: _dragValue,
    );
    _startsNewAdjustment = false;
    final double applied = request.applied;
    if (applied == _volume && !request.riskPrompt) return;

    setState(() {
      _volume = applied;
      _dragValue = applied;
      if (applied > 0) _lastVolume = applied;
      if (request.riskPrompt) {
        _awaitingBoostConfirm = true;
      } else if (applied != DesktopVolumePolicy.safeVolume) {
        _awaitingBoostConfirm = false;
      }
    });
    _overlayEntry?.markNeedsBuild();
    controller.setVolume(applied);
    if (request.riskPrompt) showDesktopVolumeRiskNotice(ScaffoldMessenger.maybeOf(context));
  }

  @override
  Widget build(BuildContext context) {
    final bool boosted = _volume > DesktopVolumePolicy.safeVolume;
    final IconData icon = _volume == 0
        ? Icons.volume_off
        : (boosted
              ? Icons.volume_up
              : (_volume < 0.5 ? Icons.volume_down : Icons.volume_up));

    return CompositedTransformTarget(
      link: _layerLink,
      child: MouseRegion(
        onEnter: (_) {
          _isMouseInIcon = true;
          _showVolumeBar();
        },
        onExit: (_) {
          _isMouseInIcon = false;
          _startHideTimer();
        },
        child: IconButton(
          onPressed: _handleToggleMute,
          icon: Icon(icon, color: boosted ? const Color(0xFFFFB300) : Colors.white, size: 24),
          tooltip: _volume == 0 ? i18n('cancel_mute') : i18n('mute'),
        ),
      ),
    );
  }
}
