import 'package:flutter/material.dart';
import 'package:pure_live/plugins/locale_helper.dart';

/// Surfaces the shared high-volume risk notice used by every desktop volume
/// control (hover bar and keyboard keys).
///
/// The caller resolves the messenger before crossing any async gap so the
/// notice is never shown into a disposed context.
void showDesktopVolumeRiskNotice(ScaffoldMessengerState? messenger) {
  if (messenger == null) return;
  messenger
    ..hideCurrentSnackBar()
    ..showSnackBar(
      SnackBar(
        key: const ValueKey('volume-high-risk-notice'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(i18n('desktop_volume_risk_title'), style: const TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 4),
            Text(i18n('desktop_volume_risk_message')),
          ],
        ),
        duration: const Duration(seconds: 5),
      ),
    );
}
