/// Desktop (Windows/Linux) player volume policy and the high-volume gate.
///
/// The desktop player may amplify live audio up to [DesktopVolumePolicy.maxVolume]
/// (150%), but that boosted range is deliberately gated: the first adjustment
/// that reaches the safe 100% cap only warns the user and stays at 100%. Only a
/// **separate** following adjustment may enter 100%-150%, so an ordinary
/// volume tweak can never slip into the boosted range by accident.
///
/// The gate belongs to one room session. Persisted room/global volumes stay
/// clamped to the safe cap, and every room starts unconfirmed again.
///
/// Deciding what "a separate adjustment" means is the caller's job, because the
/// inputs disagree about where one ends:
///
/// - A key press is discrete, so every press is a new adjustment.
/// - A drag gesture has an explicit start, so its first update opens one.
/// - A mouse wheel has neither: it emits a burst of notches and never reports
///   an end. Controls that own a volume HUD use that HUD's own auto-hide as the
///   boundary instead -- while the card is still on screen the notches belong
///   to the same adjustment, and once it has faded the next notch starts a new
///   one. So a single continuous roll parks on the cap, and only stopping,
///   letting the card go, and rolling again reaches the boosted range.
///
/// Callers therefore pass [startsNewAdjustment] rather than an action id: the
/// gate only needs to know whether the adjustment arriving now is a new one.
class DesktopVolumePolicy {
  const DesktopVolumePolicy._();

  /// Safe ceiling shared with every persisted volume path (100%).
  static const double safeVolume = 1.0;

  /// Explicitly confirmed desktop maximum (150%).
  static const double maxVolume = 1.5;

  /// Required adjustment granularity (5%).
  static const double step = 0.05;

  /// Snaps [value] onto the 5% grid and clamps it to `0..maxVolume`.
  ///
  /// The grid is computed in whole percent so that the safe cap and the boosted
  /// maximum compare exactly (e.g. `quantize(1.02) == 1.0`), which the gate
  /// relies on when it tests the 100% boundary.
  static double quantize(double value) {
    if (!value.isFinite) return safeVolume;
    final int stepPercent = (step * 100).round();
    final int maxPercent = (maxVolume * 100).round();
    final int percent = ((value * 100) / stepPercent).round() * stepPercent;
    return (percent.clamp(0, maxPercent) / 100).toDouble();
  }

  /// Clamps [value] to the persisted range `0..safeVolume`.
  static double clampPersisted(double value) {
    if (!value.isFinite) return safeVolume;
    return value.clamp(0.0, safeVolume).toDouble();
  }

  /// Position of [volume] on the `0..maxVolume` control track (`0..1`).
  static double trackRatio(double volume) {
    if (!volume.isFinite) return 0;
    return (volume / maxVolume).clamp(0.0, 1.0).toDouble();
  }
}

/// The volume a control should apply plus whether it must surface the
/// high-volume risk notice.
class DesktopVolumeRequest {
  const DesktopVolumeRequest({required this.applied, required this.riskPrompt, this.heldAtCap = false});

  /// Value to apply, already on the 5% grid and within `0..maxVolume`.
  final double applied;

  /// Whether the caller must surface the high-volume risk notice.
  final bool riskPrompt;

  /// Whether the gate substituted [DesktopVolumePolicy.safeVolume] for a request
  /// that asked to go *above* the cap.
  ///
  /// Controls keep a sub-step accumulator so small movements are not swallowed
  /// by the 5% grid. While such a request is refused, that travel never applies,
  /// so the accumulator has to be parked as well; otherwise a roll that kept
  /// going after the hold would have to be unwound notch by notch before the
  /// volume could move again.
  ///
  /// This is deliberately narrower than "the applied value equals the cap". A
  /// request that merely *rounds onto* the cap is not flagged, so the
  /// accumulator keeps its travel: that is what lets the next notch of a
  /// confirming adjustment cross into the boosted range, and what lets a
  /// downward roll leave the cap instead of being pinned on it.
  final bool heldAtCap;
}

/// Session-scoped gate that keeps 100%-150% reachable only through an explicit
/// second adjustment.
///
/// The gate is deliberately view-only about *when* an adjustment ends: callers
/// tell it whether the adjustment arriving now is a new one, and it answers with
/// the value to apply.
class DesktopVolumeBoostGate {
  bool _unlocked = false;
  bool _prompted = false;

  /// Whether a previous adjustment already reached the cap, so the next one may
  /// confirm the boost.
  bool _armed = false;

  /// Whether the adjustment currently running is allowed past the cap.
  ///
  /// Latched when the adjustment starts rather than decided per resolution,
  /// because one notch is only ~2.45%: the first notch of a confirming roll
  /// still rounds onto 100% and would otherwise consume the permission without
  /// moving anywhere, leaving the rest of its own roll blocked.
  bool _permitted = false;

  /// Whether the user already entered the boosted range in this session.
  bool get isBoostUnlocked => _unlocked;

  /// Whether the gate is waiting for the confirming adjustment.
  bool get isAwaitingConfirmation => !_unlocked && _prompted;

  /// Returns the gate to its initial, unconfirmed state. Used for every new
  /// room session so high volume is confirmed again per room.
  void resetSession() {
    _unlocked = false;
    _prompted = false;
    _armed = false;
    _permitted = false;
  }

  /// Resolves [target] for an adjustment.
  ///
  /// [startsNewAdjustment] must be true only for the first resolution of a new
  /// adjustment -- a fresh key press, the first sample of a drag, or a wheel
  /// notch arriving after the volume card has already faded out. Everything that
  /// follows inside the same adjustment passes false.
  DesktopVolumeRequest request({required bool startsNewAdjustment, required double target}) {
    final desired = DesktopVolumePolicy.quantize(target);

    // The confirmation is spent by *starting* an adjustment, never by the
    // adjustment that armed it. That is what makes a roll which never stops park
    // on the cap while the roll after it stays permitted for all of its notches,
    // including the first one that only rounds onto 100%.
    if (startsNewAdjustment) _permitted = _armed;

    if (_unlocked) {
      return DesktopVolumeRequest(applied: desired, riskPrompt: false);
    }

    if (desired >= DesktopVolumePolicy.safeVolume) {
      if (_permitted) {
        if (desired > DesktopVolumePolicy.safeVolume) {
          _unlocked = true;
          _armed = false;
          _permitted = false;
        }
        return DesktopVolumeRequest(applied: desired, riskPrompt: false);
      }

      // First approach (or a fresh approach after leaving the cap) only warns
      // and holds the safe ceiling until a later adjustment confirms.
      final prompt = !_prompted;
      _prompted = true;
      _armed = true;
      return DesktopVolumeRequest(
        applied: DesktopVolumePolicy.safeVolume,
        riskPrompt: prompt,
        // Only a request that asked to go above the cap is truly held back. One
        // that merely rounds onto the cap applies exactly what it asked for, so
        // its travel must survive in either direction.
        heldAtCap: desired > DesktopVolumePolicy.safeVolume,
      );
    }

    // Moving below the cap without ever confirming the boosted range means the
    // next approach has to ask again.
    _prompted = false;
    _armed = false;
    _permitted = false;
    return DesktopVolumeRequest(applied: desired, riskPrompt: false);
  }
}
