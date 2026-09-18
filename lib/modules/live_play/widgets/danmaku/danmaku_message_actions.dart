import 'package:flutter/services.dart';
import 'package:pure_live/common/index.dart';
import 'package:pure_live/common/services/settings/favorite_room_controller.dart';
import 'package:pure_live/modules/live_play/controllers/live_play_controller.dart';

class DanmakuMessageActions {
  DanmakuMessageActions._();

  /// Opens the long-press action sheet for one danmaku message.
  ///
  /// [platform] scopes the private remark to the current site, so an identical
  /// display name on another platform stays a different person.
  static Future<void> show(BuildContext context, LiveMessage message, {String platform = ''}) async {
    final favorite = SettingsService.to.fav;
    final userName = message.userName.trim();
    // A locally composed message has no counterpart on the platform, so it can
    // be neither blocked nor labelled.
    final canLabelUser = !message.isLocal && userName.isNotEmpty;
    final remarkKey = FavoriteRoomController.userRemarkKey(platform, userName);

    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      // Editing a remark from this sheet must refresh its own preview line, and
      // nothing else rebuilds the sheet builder.
      builder: (sheetContext) => Obx(() {
        // Subscribing to the whole map keeps the subscription valid even for a
        // locally composed message, where no remark lookup ever happens.
        final remarks = favorite.danmakuUserRemarks.value;
        final remark = canLabelUser ? (remarks[remarkKey] ?? '') : '';
        return SafeArea(
          child: SingleChildScrollView(
            child: Wrap(
              children: [
                ListTile(
                  title: Text('${message.userName}: ${message.message}'),
                  subtitle: message.userLevel.isEmpty ? null : Text('Lv.${message.userLevel}'),
                ),
                if (remark.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(Icons.sell_rounded, size: 16, color: Theme.of(sheetContext).colorScheme.primary),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            i18n('danmaku_remark_current', args: {'remark': remark}),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                  ),
                ListTile(
                  leading: const Icon(Icons.copy_all_rounded),
                  title: Text(i18n('copy')),
                  onTap: () async {
                    Navigator.of(sheetContext).pop();
                    await Clipboard.setData(ClipboardData(text: '${message.userName}: ${message.message}'));
                    ToastUtil.show(i18n('copied_to_clipboard'));
                  },
                ),
                if (canLabelUser)
                  ListTile(
                    leading: const Icon(Icons.edit_note_rounded),
                    title: Text(i18n('danmaku_quick_remark')),
                    subtitle: Text(
                      remark.isEmpty ? userName : remark,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    onTap: () => _editRemark(
                      sheetContext,
                      platform: platform,
                      userName: userName,
                      currentRemark: remark,
                    ),
                  ),
                if (canLabelUser)
                  ListTile(
                    leading: const Icon(Icons.person_off_rounded),
                    title: Text(i18n('block_danmaku_user')),
                    subtitle: Text(message.userName, maxLines: 1, overflow: TextOverflow.ellipsis),
                    onTap: () {
                      SettingsService.to.fav.addBlockedDanmakuUser(message.userName);
                      if (Get.isRegistered<LivePlayController>()) {
                        Get.find<LivePlayController>().removeDanmakuWhere(
                          (item) => item.userName.trim().toLowerCase() == message.userName.trim().toLowerCase(),
                        );
                      }
                      Navigator.of(sheetContext).pop();
                      ToastUtil.show(i18n('danmaku_user_blocked'));
                    },
                  ),
                ListTile(
                  leading: const Icon(Icons.filter_alt_rounded),
                  title: Text(i18n('block_danmaku_keyword')),
                  subtitle: Text(message.message, maxLines: 1, overflow: TextOverflow.ellipsis),
                  onTap: () {
                    Navigator.of(sheetContext).pop();
                    // The originating row may have been evicted while this sheet
                    // was open. The sheet still owns a live navigator context.
                    showKeywordDialog(sheetContext, message.message);
                  },
                ),
              ],
            ),
          ),
        );
      }),
    );
  }

  /// The sheet stays open behind the editor, so cancelling returns the user to
  /// the remaining actions instead of dismissing the whole panel.
  static Future<void> _editRemark(
    BuildContext sheetContext, {
    required String platform,
    required String userName,
    required String currentRemark,
  }) async {
    final edited = await showDialog<String>(
      context: sheetContext,
      builder: (_) => _DanmakuRemarkDialog(userName: userName, initialRemark: currentRemark),
    );
    // A dismissed dialog returns null and must leave the stored remark alone:
    // that is the whole difference between "cancel" and "save an empty remark".
    if (edited == null) return;

    final text = edited.trim();
    SettingsService.to.fav.setUserRemark(platform, userName, text);
    ToastUtil.show(
      text.isEmpty ? i18n('danmaku_remark_deleted') : i18n('danmaku_remark_updated', args: {'remark': text}),
    );
  }

  static Future<void> showKeywordDialog(BuildContext context, String message) async {
    final keyword = await showDialog<String>(
      context: context,
      builder: (_) => _DanmakuKeywordDialog(initialText: message),
    );
    if (keyword == null || keyword.isEmpty) return;
    SettingsService.to.fav.addShieldList(keyword);
    if (Get.isRegistered<LivePlayController>()) {
      Get.find<LivePlayController>().removeDanmakuWhere(
        (item) => item.message.toLowerCase().contains(keyword.toLowerCase()),
      );
    }
    ToastUtil.show(i18n('danmaku_keyword_blocked'));
  }
}

class _DanmakuRemarkDialog extends StatefulWidget {
  const _DanmakuRemarkDialog({required this.userName, required this.initialRemark});

  final String userName;
  final String initialRemark;

  @override
  State<_DanmakuRemarkDialog> createState() => _DanmakuRemarkDialogState();
}

class _DanmakuRemarkDialogState extends State<_DanmakuRemarkDialog> {
  late final TextEditingController _textController;

  @override
  void initState() {
    super.initState();
    _textController = TextEditingController(text: widget.initialRemark);
  }

  @override
  void dispose() {
    // A dialog result completes before its exit transition unmounts TextField.
    // Keep the draft alive for exactly the dialog subtree's lifetime.
    _textController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    scrollable: true,
    title: Text(i18n('danmaku_remark_user')),
    content: TextField(
      controller: _textController,
      autofocus: true,
      // Deliberately uncapped: a remark is private and free-form, and an empty
      // value is the documented way back to "no remark".
      decoration: InputDecoration(labelText: widget.userName, hintText: i18n('danmaku_remark_hint')),
    ),
    actions: [
      TextButton(onPressed: () => Navigator.of(context).pop(), child: Text(i18n('cancel'))),
      FilledButton(
        onPressed: () => Navigator.of(context).pop(_textController.text.trim()),
        child: Text(i18n('confirm')),
      ),
    ],
  );
}

class _DanmakuKeywordDialog extends StatefulWidget {
  const _DanmakuKeywordDialog({required this.initialText});
  final String initialText;

  @override
  State<_DanmakuKeywordDialog> createState() => _DanmakuKeywordDialogState();
}

class _DanmakuKeywordDialogState extends State<_DanmakuKeywordDialog> {
  late final TextEditingController _textController;

  @override
  void initState() {
    super.initState();
    _textController = TextEditingController(text: widget.initialText);
  }

  @override
  void dispose() {
    // A dialog result completes before its exit transition unmounts TextField.
    // Keep the draft alive for exactly the dialog subtree's lifetime.
    _textController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    scrollable: true,
    title: Text(i18n('block_danmaku_keyword')),
    content: TextField(
      controller: _textController,
      autofocus: true,
      maxLength: FavoriteRoomController.maxShieldKeywordLength,
      decoration: InputDecoration(hintText: i18n('please_enter_keyword')),
    ),
    actions: [
      TextButton(onPressed: () => Navigator.of(context).pop(), child: Text(i18n('cancel'))),
      FilledButton(
        onPressed: () => Navigator.of(context).pop(_textController.text.trim()),
        child: Text(i18n('confirm')),
      ),
    ],
  );
}
