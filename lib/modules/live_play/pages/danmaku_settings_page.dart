import 'package:pure_live/common/index.dart';
import 'package:pure_live/common/consts/app_consts.dart';
import 'package:syncfusion_flutter_sliders/sliders.dart';
import 'package:pure_live/common/widgets/count_button.dart';
import 'package:pure_live/modules/settings/pages/pip_danmaku_settings_page.dart';
import 'package:pure_live/modules/live_play/widgets/danmaku/danmaku_viewing_preset.dart';
import 'package:pure_live/modules/live_play/widgets/danmaku/danmaku_settings_binding.dart';
import 'package:pure_live/modules/live_play/widgets/local_interaction/local_interaction_controller.dart';
import 'package:pure_live/core/translation/danmaku_translator.dart';
import 'package:pure_live/common/services/danmaku_translation_service.dart';

class DanmakuSettingsPage extends StatelessWidget {
  const DanmakuSettingsPage({super.key, required this.controller});
  final DanmakuSettingsBinding controller;

  @override
  Widget build(BuildContext context) {
    return Scaffold(body: DanmakuSettingsContent(controller: controller));
  }
}

/// One canonical live-danmaku settings surface.
///
/// Portrait embeds it in the room tab while fullscreen/landscape embeds the
/// same widget in an adaptive side dialog. Both entries therefore share the
/// same controls, ranges, presets and reactive state.
class DanmakuSettingsContent extends StatefulWidget {
  const DanmakuSettingsContent({
    super.key,
    required this.controller,
    this.embedded = false,
    this.includePipSettings = true,
  });

  final DanmakuSettingsBinding controller;
  final bool embedded;
  final bool includePipSettings;

  @override
  State<DanmakuSettingsContent> createState() => _DanmakuSettingsContentState();
}

class _DanmakuSettingsContentState extends State<DanmakuSettingsContent> {
  late final ScrollController _scrollController;
  late final TextEditingController _translateApiKeyController = TextEditingController(
    text: SettingsService.to.danmaku.danmakuTranslateApiKey.v,
  );
  // lazy final：用户没选自建后端时这两行不会被求值，也就不会白建控制器。
  late final TextEditingController _translateEndpointController = TextEditingController(
    text: SettingsService.to.danmaku.danmakuTranslateEndpointUrl.v,
  );
  late final TextEditingController _translateModelController = TextEditingController(
    text: SettingsService.to.danmaku.danmakuTranslateModelName.v,
  );

  DanmakuSettingsBinding get controller => widget.controller;

  @override
  void initState() {
    super.initState();
    _scrollController = createPureLiveScrollController();
  }

  @override
  void dispose() {
    _scrollController.dispose();
    _translateApiKeyController.dispose();
    _translateEndpointController.dispose();
    _translateModelController.dispose();
    super.dispose();
  }

  bool get isEmbedded => widget.embedded;

  ThemeData get theme => Theme.of(context);

  Color get labelColor => isEmbedded ? theme.colorScheme.onSurface : theme.colorScheme.onSurface;

  Color get secondaryColor => isEmbedded ? theme.colorScheme.onSurfaceVariant : theme.colorScheme.onSurfaceVariant;

  Color get primaryColor => theme.colorScheme.primary;

  Color get cardColor =>
      isEmbedded ? theme.colorScheme.surfaceContainerLowest : theme.colorScheme.surfaceContainerHighest;
  Widget reactiveCard(List<Widget> Function() builder) {
    return Obx(() {
      final children = builder();

      if (isEmbedded) {
        return Container(
          width: double.infinity,
          decoration: BoxDecoration(
            color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.55),
            borderRadius: BorderRadius.circular(18),
          ),
          child: Column(children: children),
        );
      }

      return context.buildModernCard(children);
    });
  }

  Widget _buildTemplateSection(ThemeData theme) {
    return Obx(() {
      final activePreset = _matchingPreset();

      final content = Padding(
        padding: EdgeInsets.all(isEmbedded ? 10 : 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Wrap(
              spacing: isEmbedded ? 6 : 8,
              runSpacing: isEmbedded ? 6 : 8,
              children: [
                for (final preset in DanmakuViewingPreset.values)
                  ChoiceChip(
                    key: ValueKey('danmaku-template-${preset.id}'),
                    selected: activePreset?.id == preset.id,
                    showCheckmark: false,
                    backgroundColor: isEmbedded ? theme.colorScheme.surface : theme.colorScheme.surfaceContainerHighest,
                    selectedColor: theme.colorScheme.primary,
                    side: BorderSide(color: theme.colorScheme.outline.withValues(alpha: 0.35)),
                    labelStyle: TextStyle(
                      color: activePreset?.id == preset.id ? theme.colorScheme.onPrimary : theme.colorScheme.onSurface,
                      fontWeight: FontWeight.w600,
                      fontSize: isEmbedded ? 12 : null,
                    ),
                    visualDensity: isEmbedded ? VisualDensity.compact : VisualDensity.standard,
                    materialTapTargetSize: isEmbedded ? MaterialTapTargetSize.shrinkWrap : MaterialTapTargetSize.padded,
                    avatar: SizedBox(
                      width: isEmbedded ? 16 : 18,
                      child: activePreset?.id == preset.id
                          ? Icon(Icons.check_rounded, size: isEmbedded ? 16 : 18, color: theme.colorScheme.onPrimary)
                          : preset.id == 'best'
                          ? Icon(
                              Icons.auto_awesome_rounded,
                              size: isEmbedded ? 16 : 18,
                              color: theme.colorScheme.primary,
                            )
                          : const Opacity(opacity: 0, child: Icon(Icons.check_rounded, size: 18)),
                    ),
                    label: Text(i18n(preset.labelKey)),
                    onSelected: (_) => _applyPreset(preset),
                  ),
                OutlinedButton.icon(
                  onPressed: _saveTemplate,
                  style: OutlinedButton.styleFrom(
                    foregroundColor: theme.colorScheme.primary,
                    side: BorderSide(color: theme.colorScheme.primary.withValues(alpha: 0.45)),
                    visualDensity: isEmbedded ? VisualDensity.compact : VisualDensity.standard,
                    tapTargetSize: isEmbedded ? MaterialTapTargetSize.shrinkWrap : MaterialTapTargetSize.padded,
                    padding: EdgeInsets.symmetric(horizontal: isEmbedded ? 10 : 12),
                  ),
                  icon: Icon(Icons.save_outlined, size: isEmbedded ? 16 : 18),
                  label: Text(i18n('save_current_template'), style: TextStyle(fontSize: isEmbedded ? 12 : null)),
                ),
                OutlinedButton.icon(
                  onPressed: _restoreTemplate,
                  style: OutlinedButton.styleFrom(
                    foregroundColor: theme.colorScheme.primary,
                    side: BorderSide(color: theme.colorScheme.primary.withValues(alpha: 0.45)),
                    visualDensity: isEmbedded ? VisualDensity.compact : VisualDensity.standard,
                    tapTargetSize: isEmbedded ? MaterialTapTargetSize.shrinkWrap : MaterialTapTargetSize.padded,
                    padding: EdgeInsets.symmetric(horizontal: isEmbedded ? 10 : 12),
                  ),
                  icon: Icon(Icons.restore_rounded, size: isEmbedded ? 16 : 18),
                  label: Text(i18n('restore_saved_template'), style: TextStyle(fontSize: isEmbedded ? 12 : null)),
                ),
              ],
            ),
            SizedBox(height: isEmbedded ? 8 : 10),
            Text(
              '${i18n('danmaku_best_preset_desc')}\n'
              '${i18n('danmaku_realtime_hint')}',
              style: theme.textTheme.bodySmall?.copyWith(
                height: 1.45,
                fontSize: isEmbedded ? 11 : null,
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      );

      if (isEmbedded) {
        return Container(
          width: double.infinity,
          decoration: BoxDecoration(
            color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.55),
            borderRadius: BorderRadius.circular(18),
          ),
          child: content,
        );
      }

      return context.buildModernCard([content]);
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final Color labelColor = theme.colorScheme.onSurface;
    final Color digitColor = theme.colorScheme.primary;
    final LocalInteractionController localInteractionController = Get.find<LocalInteractionController>();
    return SingleChildScrollView(
      key: ValueKey(widget.embedded ? 'danmaku-settings-content-embedded' : 'danmaku-settings-content-page'),
      controller: _scrollController,
      physics: const PureLiveScrollPhysics(),
      padding: EdgeInsets.symmetric(horizontal: widget.embedded ? 12 : 16, vertical: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          context.buildModernCard([
            context.buildSwitchTile(
              title: i18n('local_interaction_enable'),
              value: localInteractionController.enabled,
              icon: Icons.auto_awesome_rounded,
              isLong: true,
            ),
          ]),
          const SizedBox(height: 8),
          context.buildGroupTitle(i18n('danmaku_templates')),
          const SizedBox(height: 8),
          _buildTemplateSection(theme),
          const SizedBox(height: 20),
          context.buildGroupTitle(i18n("danmaku_area")),
          const SizedBox(height: 8),
          reactiveCard(
            () => [
              _switch(
                theme,
                title: i18n('danmaku_no_emoji'),
                value: controller.noEmojiMode.value,
                onChanged: (value) => controller.noEmojiMode.value = value,
                labelColor: labelColor,
              ),
              _switch(
                theme,
                title: i18n('danmaku_show_user_remark'),
                value: SettingsService.to.danmaku.showDanmakuUserRemark.v,
                onChanged: (value) => SettingsService.to.danmaku.showDanmakuUserRemark.v = value,
                labelColor: labelColor,
              ),
              _slider(
                theme,
                title: i18n("danmaku_area"),
                value: controller.danmakuArea.value,
                min: 0,
                max: 1,
                display: "${(controller.danmakuArea.value * 100).toInt()}%",
                semanticValueBuilder: (value) => '${(value * 100).toInt()}%',
                onChanged: (v) => controller.danmakuArea.value = v,
                labelColor: labelColor,
                digitColor: digitColor,
              ),
            ],
          ),

          const SizedBox(height: 20),

          context.buildGroupTitle(i18n("position")),
          const SizedBox(height: 8),
          reactiveCard(
            () => [
              _counter(
                theme,
                title: i18n("margin_top"),
                value: controller.danmakuTopArea.value.toInt(),
                max: 300,
                onChanged: (v) => controller.danmakuTopArea.value = v.toDouble(),
                labelColor: labelColor,
                digitColor: digitColor,
              ),
              _counter(
                theme,
                title: i18n("margin_bottom"),
                value: controller.danmakuBottomArea.value.toInt(),
                max: 300,
                onChanged: (v) => controller.danmakuBottomArea.value = v.toDouble(),
                labelColor: labelColor,
                digitColor: digitColor,
              ),
            ],
          ),

          const SizedBox(height: 20),

          context.buildGroupTitle(i18n("style")),
          const SizedBox(height: 8),
          reactiveCard(
            () => [
              _slider(
                theme,
                title: i18n("opacity"),
                value: controller.danmakuOpacity.value,
                min: 0,
                max: 1,
                display: "${(controller.danmakuOpacity.value * 100).toInt()}%",
                semanticValueBuilder: (value) => '${(value * 100).toInt()}%',
                onChanged: (v) => controller.danmakuOpacity.value = v,
                labelColor: labelColor,
                digitColor: digitColor,
              ),
              _slider(
                theme,
                title: i18n("speed"),
                value: controller.danmakuSpeed.value.toDouble(),
                min: 20,
                max: 400,
                display: '${controller.danmakuSpeed.value.toInt()} px/s',
                semanticValueBuilder: (value) => '${value.toInt()} px/s',
                onChanged: (v) => controller.danmakuSpeed.value = v,
                labelColor: labelColor,
                digitColor: digitColor,
              ),
              _slider(
                theme,
                title: i18n("font_size"),
                value: controller.danmakuFontSize.value.toDouble(),
                min: 10,
                max: 30,
                display: '${controller.danmakuFontSize.value.toStringAsFixed(1)} px',
                semanticValueBuilder: (value) => '${value.toStringAsFixed(1)} px',
                onChanged: (v) => controller.danmakuFontSize.value = v,
                labelColor: labelColor,
                digitColor: digitColor,
              ),
              _slider(
                theme,
                title: i18n('font_weight'),
                value: controller.danmakuFontWeight.value.toDouble(),
                min: 100,
                max: 900,
                stepSize: 100,
                display: i18n(AppConsts.fontWeightLabels[controller.danmakuFontWeight.value] ?? 'font_weight_medium'),
                semanticValueBuilder: (value) =>
                    i18n(AppConsts.fontWeightLabels[value.round()] ?? 'font_weight_medium'),
                onChanged: (v) => controller.danmakuFontWeight.value = (v / 100).round() * 100,
                labelColor: labelColor,
                digitColor: digitColor,
              ),
              _switch(
                theme,
                title: i18n("danmaku_stroke"),
                value: controller.enableDanmakuStroke.value,
                onChanged: (v) => controller.enableDanmakuStroke.value = v,
                labelColor: labelColor,
              ),
              _slider(
                theme,
                title: i18n("stroke"),
                value: controller.danmakuFontBorder.value.toDouble(),
                min: 0,
                max: 4,
                display: '${controller.danmakuFontBorder.value.toStringAsFixed(1)} px',
                semanticValueBuilder: (value) => '${value.toStringAsFixed(1)} px',
                onChanged: (v) => controller.danmakuFontBorder.value = v,
                labelColor: labelColor,
                digitColor: digitColor,
              ),
              _switch(
                theme,
                title: '${i18n("danmaku_fps")} · ${i18n("dynamic_follow_display")}',
                subtitle: i18n('danmaku_fps_policy_desc'),
                value: SettingsService.to.danmaku.danmakuAutoFps.v,
                onChanged: (v) => SettingsService.to.danmaku.danmakuAutoFps.v = v,
                labelColor: labelColor,
                subtitleColor: labelColor,
              ),
              if (!SettingsService.to.danmaku.danmakuAutoFps.v)
                _slider(
                  theme,
                  title: i18n("danmaku_fps"),
                  value: controller.danmakuFps.value.toDouble(),
                  min: 30,
                  max: 240,
                  display: "${controller.danmakuFps.value.toInt()} FPS",
                  semanticValueBuilder: (value) => '${value.toInt()} FPS',
                  onChanged: (v) => controller.danmakuFps.value = v.toInt(),
                  labelColor: labelColor,
                  digitColor: digitColor,
                )
              else
                Padding(
                  padding: EdgeInsets.fromLTRB(isEmbedded ? 14 : 16, 0, isEmbedded ? 14 : 16, isEmbedded ? 10 : 12),
                  child: Text(
                    '${SettingsService.to.danmaku.resolvedDanmakuFps(refreshRateMode: SettingsService.to.app.refreshRateMode)} FPS',
                    style: TextStyle(color: digitColor, fontWeight: FontWeight.w600, fontSize: isEmbedded ? 13 : null),
                  ),
                ),
            ],
          ),
          SizedBox(height: widget.embedded ? 16 : 20),
          context.buildGroupTitle(i18n('danmaku_repeat_filter')),
          const SizedBox(height: 8),
          reactiveCard(
            () => [
              _switch(
                theme,
                title: i18n('collapse_repeated_danmaku'),
                subtitle: i18n('collapse_repeated_danmaku_desc'),
                value: SettingsService.to.danmaku.collapseRepeatedDanmaku.v,
                onChanged: (v) => SettingsService.to.danmaku.collapseRepeatedDanmaku.v = v,
                labelColor: labelColor,
                subtitleColor: labelColor,
              ),
              if (SettingsService.to.danmaku.collapseRepeatedDanmaku.v)
                _counter(
                  theme,
                  title: i18n('repeated_danmaku_window'),
                  value: SettingsService.to.danmaku.repeatedDanmakuWindowSeconds.v,
                  min: 1,
                  max: 30,
                  onChanged: (v) => SettingsService.to.danmaku.repeatedDanmakuWindowSeconds.v = v,
                  labelColor: labelColor,
                  digitColor: digitColor,
                ),
            ],
          ),
          const SizedBox(height: 20),
          context.buildGroupTitle(i18n('danmaku_screen_interaction')),
          const SizedBox(height: 8),
          reactiveCard(
            () => [
              _switch(
                theme,
                title: i18n('danmaku_tap_action'),
                value: SettingsService.to.danmaku.enableDanmakuTapInteraction.v,
                onChanged: (v) => SettingsService.to.danmaku.enableDanmakuTapInteraction.v = v,
                labelColor: labelColor,
              ),
              _switch(
                theme,
                title: i18n('danmaku_long_press_action'),
                value: SettingsService.to.danmaku.enableDanmakuLongPressInteraction.v,
                onChanged: (v) => SettingsService.to.danmaku.enableDanmakuLongPressInteraction.v = v,
                labelColor: labelColor,
              ),
            ],
          ),
          const SizedBox(height: 20),
          context.buildGroupTitle(i18n('danmaku_translation')),
          const SizedBox(height: 8),
          reactiveCard(
            () => [
              _switch(
                theme,
                title: i18n('danmaku_auto_translate'),
                subtitle: i18n('danmaku_auto_translate_desc'),
                value: SettingsService.to.danmaku.enableDanmakuAutoTranslate.v,
                onChanged: (v) => SettingsService.to.danmaku.enableDanmakuAutoTranslate.v = v,
                labelColor: labelColor,
                subtitleColor: labelColor,
              ),
              if (SettingsService.to.danmaku.enableDanmakuAutoTranslate.v) ...[
                _choices(
                  theme,
                  title: i18n('danmaku_translate_service'),
                  value: SettingsService.to.danmaku.danmakuTranslateService.v,
                  options: [
                    (value: danmakuTranslationServiceGoogle, label: i18n('danmaku_translate_service_google')),
                    (value: danmakuTranslationServiceMyMemory, label: i18n('danmaku_translate_service_mymemory')),
                    (value: danmakuTranslationServiceDeepL, label: i18n('danmaku_translate_service_deepl')),
                    (value: danmakuTranslationServiceYoudao, label: i18n('danmaku_translate_service_youdao')),
                    (value: danmakuTranslationServiceLibreTranslate, label: i18n('danmaku_translate_service_libre')),
                    (value: danmakuTranslationServiceOpenAiCompatible, label: i18n('danmaku_translate_service_openai')),
                  ],
                  onChanged: (v) => SettingsService.to.danmaku.danmakuTranslateService.v = v,
                  labelColor: labelColor,
                ),
                // 两个自建后端共用"服务地址"。地址留空时服务层直接放行，既不
                // 打无效请求，也不会被误计成服务故障。
                if (danmakuTranslationNeedsEndpoint(SettingsService.to.danmaku.danmakuTranslateService.v))
                  _textField(
                    controller: _translateEndpointController,
                    label: i18n('danmaku_translate_endpoint'),
                    hint:
                        SettingsService.to.danmaku.danmakuTranslateService.v ==
                            danmakuTranslationServiceLibreTranslate
                        ? danmakuTranslationDefaultLibreEndpoint
                        : danmakuTranslationDefaultOpenAiEndpoint,
                    onChanged: (v) => SettingsService.to.danmaku.danmakuTranslateEndpointUrl.v = v.trim(),
                  ),
                // 有道的限流是实测出来的真实约束，先说清楚，别让用户以为功能坏了。
                if (SettingsService.to.danmaku.danmakuTranslateService.v == danmakuTranslationServiceYoudao)
                  _hintText(i18n('danmaku_translate_youdao_hint')),
                // 这两个后端的性格差别很大（一个快但口语不行，一个慢但更懂人话），
                // 把实测结论摆在选项旁边，别等用户翻出一堆怪句子才发现。
                if (danmakuTranslationNeedsEndpoint(SettingsService.to.danmaku.danmakuTranslateService.v))
                  _hintText(
                    SettingsService.to.danmaku.danmakuTranslateService.v ==
                            danmakuTranslationServiceLibreTranslate
                        ? i18n('danmaku_translate_libre_hint')
                        : i18n('danmaku_translate_openai_hint'),
                  ),
                if (SettingsService.to.danmaku.danmakuTranslateService.v ==
                    danmakuTranslationServiceOpenAiCompatible)
                  _textField(
                    controller: _translateModelController,
                    label: i18n('danmaku_translate_model'),
                    hint: i18n('danmaku_translate_model_hint'),
                    onChanged: (v) => SettingsService.to.danmaku.danmakuTranslateModelName.v = v.trim(),
                  ),
                // DeepL 必需、自建实例可选（本地服务通常不需要密钥）。
                if (SettingsService.to.danmaku.danmakuTranslateService.v != danmakuTranslationServiceGoogle &&
                    SettingsService.to.danmaku.danmakuTranslateService.v != danmakuTranslationServiceMyMemory)
                  _textField(
                    controller: _translateApiKeyController,
                    label: i18n('danmaku_translate_api_key'),
                    hint: i18n('danmaku_translate_api_key_hint'),
                    obscure: true,
                    onChanged: (v) => SettingsService.to.danmaku.danmakuTranslateApiKey.v = v.trim(),
                  ),
                _choices(
                  theme,
                  title: i18n('danmaku_translate_target'),
                  value: SettingsService.to.danmaku.danmakuTranslateTargetLang.v,
                  options: [
                    (value: 'zh-CN', label: i18n('danmaku_translate_target_zh_cn')),
                    (value: 'zh-TW', label: i18n('danmaku_translate_target_zh_tw')),
                    (value: 'en', label: i18n('danmaku_translate_target_en')),
                    (value: 'ja', label: i18n('danmaku_translate_target_ja')),
                  ],
                  onChanged: (v) => SettingsService.to.danmaku.danmakuTranslateTargetLang.v = v,
                  labelColor: labelColor,
                ),
                _switch(
                  theme,
                  title: i18n('danmaku_translate_keep_original'),
                  subtitle: i18n('danmaku_translate_keep_original_desc'),
                  value: SettingsService.to.danmaku.danmakuTranslateShowOriginal.v,
                  onChanged: (v) => SettingsService.to.danmaku.danmakuTranslateShowOriginal.v = v,
                  labelColor: labelColor,
                  subtitleColor: labelColor,
                ),
                _translationStatus(),
              ],
            ],
          ),
          const SizedBox(height: 20),

          if (widget.includePipSettings) ...[
            const PipDanmakuSettingsSection(),
            const SizedBox(height: 24),
          ] else
            const SizedBox(height: 12),
        ],
      ),
    );
  }

  DanmakuViewingPreset? _matchingPreset() {
    for (final preset in DanmakuViewingPreset.values) {
      if (preset.matches(
        area: controller.danmakuArea.v,
        top: controller.danmakuTopArea.v,
        bottom: controller.danmakuBottomArea.v,
        speed: controller.danmakuSpeed.v,
        fontSize: controller.danmakuFontSize.v,
        fontWeight: controller.danmakuFontWeight.v,
        fontBorder: controller.danmakuFontBorder.v,
        opacity: controller.danmakuOpacity.v,
        stroke: controller.enableDanmakuStroke.v,
        autoFps: SettingsService.to.danmaku.danmakuAutoFps.v,
      )) {
        return preset;
      }
    }
    return null;
  }

  void _applyPreset(DanmakuViewingPreset preset) {
    controller.danmakuArea.v = preset.area;
    controller.danmakuTopArea.v = preset.top;
    controller.danmakuBottomArea.v = preset.bottom;
    controller.danmakuSpeed.v = preset.speed;
    controller.danmakuFontSize.v = preset.fontSize;
    controller.danmakuFontWeight.v = preset.fontWeight;
    controller.danmakuFontBorder.v = preset.fontBorder;
    controller.danmakuOpacity.v = preset.opacity;
    controller.enableDanmakuStroke.v = preset.stroke;
    SettingsService.to.danmaku.danmakuAutoFps.v = true;
    setState(() {});
    ToastUtil.show(i18n('danmaku_template_applied'));
  }

  void _saveTemplate() {
    final settings = SettingsService.to.danmaku;
    settings.savedDanmakuTemplate.v = DanmakuViewingTemplate(
      noEmojiMode: controller.noEmojiMode.v,
      area: controller.danmakuArea.v,
      top: controller.danmakuTopArea.v,
      bottom: controller.danmakuBottomArea.v,
      speed: controller.danmakuSpeed.v,
      fontSize: controller.danmakuFontSize.v,
      fontWeight: controller.danmakuFontWeight.v,
      fontBorder: controller.danmakuFontBorder.v,
      opacity: controller.danmakuOpacity.v,
      stroke: controller.enableDanmakuStroke.v,
      fps: controller.danmakuFps.v,
      autoFps: settings.danmakuAutoFps.v,
    ).encode();
    ToastUtil.show(i18n('danmaku_template_saved'));
  }

  void _restoreTemplate() {
    final raw = SettingsService.to.danmaku.savedDanmakuTemplate.v;
    if (raw.isEmpty) {
      ToastUtil.show(i18n('danmaku_template_empty'));
      return;
    }
    final settings = SettingsService.to.danmaku;
    final template = DanmakuViewingTemplate.tryDecode(
      raw,
      fallbackNoEmojiMode: controller.noEmojiMode.v,
      fallbackFontWeight: controller.danmakuFontWeight.v,
      fallbackStroke: controller.enableDanmakuStroke.v,
      fallbackFps: controller.danmakuFps.v,
      fallbackAutoFps: settings.danmakuAutoFps.v,
    );
    if (template == null) {
      ToastUtil.show(i18n('danmaku_template_invalid'));
      return;
    }
    controller.noEmojiMode.v = template.noEmojiMode;
    controller.danmakuArea.v = template.area;
    controller.danmakuTopArea.v = template.top;
    controller.danmakuBottomArea.v = template.bottom;
    controller.danmakuSpeed.v = template.speed;
    controller.danmakuFontSize.v = template.fontSize;
    controller.danmakuFontWeight.v = template.fontWeight;
    controller.danmakuFontBorder.v = template.fontBorder;
    controller.danmakuOpacity.v = template.opacity;
    controller.enableDanmakuStroke.v = template.stroke;
    controller.danmakuFps.v = template.fps;
    settings.danmakuAutoFps.v = template.autoFps;
    ToastUtil.show(i18n('danmaku_template_applied'));
  }

  Widget _slider(
    ThemeData theme, {
    required String title,
    required double value,
    required double min,
    required double max,
    required String display,
    required String Function(double value) semanticValueBuilder,
    required ValueChanged<double> onChanged,
    required Color labelColor,
    required Color digitColor,
    double? stepSize,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Expanded(
                child: Text(
                  title,
                  style: AppTextStyles.t15.copyWith(fontWeight: FontWeight.w600, color: labelColor),
                ),
              ),
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: theme.colorScheme.primary.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text(
                  display,
                  style: AppTextStyles.t12.copyWith(fontWeight: FontWeight.bold, color: digitColor),
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Transform.translate(
            offset: const Offset(-8, 0),
            child: SizedBox(
              width: double.infinity,
              child: SfSlider(
                min: min,
                max: max,
                value: value,
                stepSize: stepSize,
                activeColor: theme.colorScheme.primary,
                inactiveColor: theme.colorScheme.primary.withValues(alpha: 0.15),
                semanticFormatterCallback: (dynamic semanticValue) =>
                    '$title, ${semanticValueBuilder((semanticValue as num).toDouble())}',
                onChanged: (dynamic v) => onChanged(v as double),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _counter(
    ThemeData theme, {
    required String title,
    required int value,
    int min = 0,
    required int max,
    required ValueChanged<int> onChanged,
    required Color labelColor,
    required Color digitColor,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Expanded(
            child: Text(
              title,
              style: AppTextStyles.t15.copyWith(fontWeight: FontWeight.w600, color: labelColor),
            ),
          ),
          const SizedBox(width: 8),
          CountButton(
            maxValue: max,
            minValue: min,
            selectedValue: value,
            semanticLabel: title,
            decrementSemanticLabel: i18n('decrease_value', args: {'label': title}),
            incrementSemanticLabel: i18n('increase_value', args: {'label': title}),
            onChanged: onChanged,
            textStyle: TextStyle(color: digitColor, fontSize: 14, fontWeight: FontWeight.bold),
          ),
        ],
      ),
    );
  }

  Widget _switch(
    ThemeData theme, {
    required String title,
    String? subtitle,
    required bool value,
    required ValueChanged<bool> onChanged,
    required Color labelColor,
    Color? subtitleColor,
  }) {
    return Material(
      type: MaterialType.transparency,
      child: SwitchListTile(
        contentPadding: EdgeInsets.symmetric(horizontal: isEmbedded ? 14 : 16),
        dense: isEmbedded,
        visualDensity: isEmbedded ? VisualDensity.compact : VisualDensity.standard,
        title: Text(
          title,
          style: AppTextStyles.t15.copyWith(fontWeight: FontWeight.w600, color: labelColor),
        ),
        subtitle: subtitle == null
            ? null
            : Text(
                subtitle,
                style: subtitleColor != null
                    ? Theme.of(context).textTheme.bodySmall?.copyWith(color: subtitleColor)
                    : Theme.of(context).textTheme.bodySmall,
              ),
        value: value,
        activeThumbColor: theme.colorScheme.primary,
        onChanged: onChanged,
      ),
    );
  }

  /// 一组互斥选项。沿用模板区已有的 ChoiceChip 观感，避免引入第二套选择控件。
  Widget _choices(
    ThemeData theme, {
    required String title,
    required String value,
    required List<({String value, String label})> options,
    required ValueChanged<String> onChanged,
    required Color labelColor,
  }) {
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: isEmbedded ? 14 : 16, vertical: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: AppTextStyles.t15.copyWith(fontWeight: FontWeight.w600, color: labelColor)),
          const SizedBox(height: 8),
          Wrap(
            spacing: isEmbedded ? 6 : 8,
            runSpacing: isEmbedded ? 6 : 8,
            children: [
              for (final option in options)
                ChoiceChip(
                  selected: option.value == value,
                  showCheckmark: false,
                  backgroundColor: isEmbedded
                      ? theme.colorScheme.surface
                      : theme.colorScheme.surfaceContainerHighest,
                  selectedColor: theme.colorScheme.primary,
                  side: BorderSide(color: theme.colorScheme.outline.withValues(alpha: 0.35)),
                  visualDensity: isEmbedded ? VisualDensity.compact : VisualDensity.standard,
                  materialTapTargetSize: isEmbedded
                      ? MaterialTapTargetSize.shrinkWrap
                      : MaterialTapTargetSize.padded,
                  labelStyle: TextStyle(
                    fontSize: isEmbedded ? 12 : 13,
                    fontWeight: FontWeight.w600,
                    color: option.value == value ? theme.colorScheme.onPrimary : theme.colorScheme.onSurface,
                  ),
                  label: Text(option.label),
                  onSelected: (_) => onChanged(option.value),
                ),
            ],
          ),
        ],
      ),
    );
  }

  /// 一行文本配置。自建地址、模型名、API key 共用同一种呈现。
  Widget _textField({
    required TextEditingController controller,
    required String label,
    String? hint,
    bool obscure = false,
    required ValueChanged<String> onChanged,
  }) {
    return Padding(
      padding: EdgeInsets.fromLTRB(isEmbedded ? 14 : 16, 4, isEmbedded ? 14 : 16, 10),
      child: TextField(
        controller: controller,
        obscureText: obscure,
        decoration: InputDecoration(
          isDense: true,
          border: const OutlineInputBorder(),
          labelText: label,
          hintText: hint,
        ),
        // 直接落库：这些都是填一次的配置，不需要额外的保存按钮。
        onChanged: onChanged,
      ),
    );
  }

  /// 一段说明文字。用来把实测出来的能力边界直接摆在选项旁边，而不是等用户
  /// 用了之后自己发现翻译质量不对劲。
  Widget _hintText(String text) {
    return Padding(
      padding: EdgeInsets.fromLTRB(isEmbedded ? 14 : 16, 0, isEmbedded ? 14 : 16, 10),
      child: Text(
        text,
        style: theme.textTheme.bodySmall?.copyWith(height: 1.4, color: theme.colorScheme.onSurfaceVariant),
      ),
    );
  }

  /// 翻译连续失败时的可见提示。
  ///
  /// 翻译服务失效时弹幕会安静地退回原文，如果不给出提示，用户只会认为"这个
  /// 功能没生效"，所以熔断状态必须能被看见。
  Widget _translationStatus() {
    final slot = DanmakuTranslationService.errorSlotOrNull();
    if (slot == null) return const SizedBox.shrink();
    return Obx(() {
      if (slot.value.isEmpty) return const SizedBox.shrink();
      return Padding(
        padding: EdgeInsets.fromLTRB(isEmbedded ? 14 : 16, 2, isEmbedded ? 14 : 16, 12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.error_outline_rounded, size: 16, color: theme.colorScheme.error),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                i18n('danmaku_translate_unavailable', args: {'seconds': '${DanmakuTranslationService.circuitCooldown.inSeconds}'}),
                style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.error),
              ),
            ),
          ],
        ),
      );
    });
  }
}
