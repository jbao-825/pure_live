import 'dart:async';
import 'dart:convert';
import 'dart:io' as io;

import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:pure_live/common/services/settings_service.dart';
import 'package:pure_live/get/get.dart';

/// 可选的翻译后端标识。持久化的是这些字符串，不是枚举下标，所以顺序可以
/// 调整而不会把用户的旧配置指向另一个服务。
const String danmakuTranslationServiceGoogle = 'google';
const String danmakuTranslationServiceMyMemory = 'mymemory';
const String danmakuTranslationServiceDeepL = 'deepl';
const String danmakuTranslationServiceYoudao = 'youdao';

/// 自建服务：LibreTranslate（本地部署的专用翻译 API）。
const String danmakuTranslationServiceLibreTranslate = 'libretranslate';

/// 自建服务：任何 OpenAI 兼容端点（Ollama / llama.cpp / LM Studio / vLLM）。
const String danmakuTranslationServiceOpenAiCompatible = 'openai-compatible';

/// 两个自建后端都需要用户给出服务地址。
bool danmakuTranslationNeedsEndpoint(String service) =>
    service == danmakuTranslationServiceLibreTranslate || service == danmakuTranslationServiceOpenAiCompatible;

/// 默认地址只是提示值，不会在用户没填时被悄悄使用。
const String danmakuTranslationDefaultLibreEndpoint = 'http://localhost:5000';
const String danmakuTranslationDefaultOpenAiEndpoint = 'http://localhost:11434/v1';

http.Client? _sharedClient;

/// 所有翻译引擎共享的 HTTP 客户端，并且跟随应用的代理裁决。
///
/// 代理是在 `HttpClient.findProxy` 里按域名逐请求评估的（见
/// `core/common/http_client.dart`）。翻译请求必须走同一条路——各引擎自己
/// `new http.Client()` 会绕过整个代理机制，于是用户即便配好了代理，被墙的端点
/// 依然打不通。
///
/// 共享单例而不是每个引擎一个：连接可以复用，而且它的生命周期与进程一致，
/// 重建引擎时不需要销毁，也就没有"该由谁关连接"的所有权问题。`findProxy` 是
/// 逐请求调用的，所以改完代理设置下一次请求就生效，无需重建客户端。
http.Client sharedTranslationHttpClient() {
  return _sharedClient ??= _buildProxiedClient();
}

/// 仅供测试：丢弃共享客户端，让下一次取用时重新评估代理。
void resetSharedTranslationHttpClient() {
  _sharedClient?.close();
  _sharedClient = null;
}

http.Client _buildProxiedClient() {
  final inner = io.HttpClient()..idleTimeout = const Duration(seconds: 30);
  inner.findProxy = (uri) {
    // 服务尚未注册时（例如独立测试夹具）保持直连，绝不能在这里抛。
    if (!Get.isRegistered<SettingsService>()) return 'DIRECT';
    try {
      return SettingsService.to.proxy.directiveForAppRequest(uri);
    } catch (_) {
      return 'DIRECT';
    }
  };
  return IOClient(inner);
}

/// 源语言"自动检测"的占位值。
const String danmakuTranslationAutoSource = 'auto';

/// 单条弹幕超过该字符数就不再翻译。
///
/// 超长文本多为整段粘贴或刷屏，翻译价值低，却会让整批请求一起变慢。
const int danmakuTranslationMaxLength = 200;

/// 翻译结果在内存中的上限。直播弹幕重复率极高，缓存是省流量的主力。
const int danmakuTranslationCacheCapacity = 2000;

/// 目标语言是否使用汉字/假名/谚文。
///
/// 只有以中日韩文字为目标时，"原文是否已经不需要翻译"才成为一个真问题；
/// 目标为拉丁文字时任何含字母的文本都值得翻译。
bool isCjkTargetLanguage(String language) {
  final normalized = language.trim().toLowerCase();
  return normalized.startsWith('zh') || normalized.startsWith('ja') || normalized.startsWith('ko');
}

final RegExp _letterPattern = RegExp(
  r'[A-Za-z\u00C0-\u024F\u0400-\u04FF\u3040-\u30FF\u1100-\u11FF\uAC00-\uD7AF\u4E00-\u9FFF\uF900-\uFAFF]',
);
final RegExp _kanaPattern = RegExp(r'[\u3040-\u30FF]');
final RegExp _hangulPattern = RegExp(r'[\u1100-\u11FF\uAC00-\uD7AF]');
final RegExp _hanPattern = RegExp(r'[\u3400-\u4DBF\u4E00-\u9FFF\uF900-\uFAFF]');
final RegExp _latinPattern = RegExp(r'[A-Za-z\u00C0-\u024F\u0400-\u04FF]');

int _countMatches(RegExp pattern, String text) => pattern.allMatches(text).length;

/// 判断一条弹幕是否需要送去翻译。
///
/// 这是纯启发式判断，不是语言检测器：它唯一的目标是**不把已经读得懂的文本
/// 送去翻译**，从而省下请求量和额度。判断为 false 的文本不会产生任何网络
/// 请求，因此这里宁可保守（放行去翻译），也不要错误地拦下真正的英文弹幕。
bool danmakuNeedsTranslation(
  String text, {
  required String targetLang,
  int maxLength = danmakuTranslationMaxLength,
}) {
  final trimmed = text.trim();
  if (trimmed.isEmpty || trimmed.length > maxLength) return false;
  // 纯数字、纯表情、纯标点（含"666"这类刷屏）没有可翻译的语言内容。
  if (!_letterPattern.hasMatch(trimmed)) return false;
  if (!isCjkTargetLanguage(targetLang)) return true;

  // 中文不写假名和谚文，两者都能把日文/韩文从中文里区分出来。
  if (_kanaPattern.hasMatch(trimmed) || _hangulPattern.hasMatch(trimmed)) return true;

  final han = _countMatches(_hanPattern, trimmed);
  if (han == 0) return true;
  // 汉字多于拉丁字母时按中文看待；混排文本（"这歌good"）仍然放行。
  return _countMatches(_latinPattern, trimmed) > han;
}

/// 翻译后端的统一接口。
///
/// 实现必须自己吞掉网络异常并返回 null 占位，让调用方只面对"这一条没翻成"
/// 而不用区分 200/超时/解析失败。
abstract class DanmakuTranslator {
  const DanmakuTranslator();

  /// 一次请求最多合并多少条。批量能力强的后端调大它可以显著降低请求数。
  int get batchSize;

  /// 返回与 [texts] 等长的列表；无法翻译的位置为 null。
  Future<List<String?>> translate(
    List<String> texts, {
    required String sourceLang,
    required String targetLang,
  });

  /// 释放底层连接。默认无资源可释放。
  void dispose() {}
}

const Map<String, String> _defaultHeaders = <String, String>{
  'User-Agent':
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
  'Accept': 'application/json,text/plain,*/*',
};

/// Google 网页端公开接口。
///
/// 支持 `sl=auto` 自动检测源语言，因此是本功能零配置的默认后端。该端点没有
/// 官方文档也没有配额承诺，属于"能用就用、失败即降级"的定位；实现上把任何
/// 非 200 或解析异常都折算成 null，绝不抛出到弹幕流水线。
class GoogleGtxTranslator extends DanmakuTranslator {
  GoogleGtxTranslator({http.Client? client, this.timeout = const Duration(seconds: 8)}) : _client = client ?? sharedTranslationHttpClient();

  static const String endpoint = 'https://translate.googleapis.com/translate_a/single';

  final http.Client _client;
  final Duration timeout;

  /// 该端点没有稳定的批量语义，靠并发把一次窗口内的多条一起发出去。
  @override
  int get batchSize => 4;

  @override
  Future<List<String?>> translate(
    List<String> texts, {
    required String sourceLang,
    required String targetLang,
  }) {
    return Future.wait(
      texts.map((text) => _translateOne(text, sourceLang: sourceLang, targetLang: targetLang)),
    );
  }

  Future<String?> _translateOne(
    String text, {
    required String sourceLang,
    required String targetLang,
  }) async {
    final uri = Uri.parse(endpoint).replace(
      queryParameters: <String, String>{
        'client': 'gtx',
        'sl': sourceLang,
        'tl': targetLang,
        'dt': 't',
        'q': text,
      },
    );
    try {
      final response = await _client.get(uri, headers: _defaultHeaders).timeout(timeout);
      if (response.statusCode != 200) return null;
      return parseResponse(response.bodyBytes);
    } catch (_) {
      // 超时、DNS、代理、限流一律等同"这一条没翻成"。
      return null;
    }
  }

  /// 解析 `[[["译文","原文",...],...],...]` 并拼接所有分段。
  static String? parseResponse(List<int> bodyBytes) {
    final decoded = jsonDecode(utf8.decode(bodyBytes));
    if (decoded is! List || decoded.isEmpty) return null;
    final segments = decoded.first;
    if (segments is! List) return null;
    final buffer = StringBuffer();
    for (final segment in segments) {
      if (segment is List && segment.isNotEmpty && segment.first is String) {
        buffer.write(segment.first as String);
      }
    }
    final text = buffer.toString().trim();
    return text.isEmpty ? null : text;
  }
}

/// MyMemory 公开接口。
///
/// 实测结论（2026-09-21）：该端点**不接受** `langpair=autodetect|xx`，传上去会
/// 原样返回未翻译的原文，因此这里在源语言为 auto 时回退到 en。这也是它只能
/// 作为备选后端、不能做默认值的原因。
class MyMemoryTranslator extends DanmakuTranslator {
  MyMemoryTranslator({http.Client? client, this.timeout = const Duration(seconds: 8)}) : _client = client ?? sharedTranslationHttpClient();

  static const String endpoint = 'https://api.mymemory.translated.net/get';

  /// 源语言未知时的回退语言：国外直播平台的弹幕以英语为主。
  static const String fallbackSource = 'en';

  final http.Client _client;
  final Duration timeout;

  @override
  int get batchSize => 4;

  @override
  Future<List<String?>> translate(
    List<String> texts, {
    required String sourceLang,
    required String targetLang,
  }) {
    return Future.wait(
      texts.map((text) => _translateOne(text, sourceLang: sourceLang, targetLang: targetLang)),
    );
  }

  Future<String?> _translateOne(
    String text, {
    required String sourceLang,
    required String targetLang,
  }) async {
    final effectiveSource = sourceLang.trim().isEmpty || sourceLang == danmakuTranslationAutoSource
        ? fallbackSource
        : sourceLang;
    final uri = Uri.parse(endpoint).replace(
      queryParameters: <String, String>{
        'q': text,
        'langpair': '$effectiveSource|$targetLang',
      },
    );
    try {
      final response = await _client.get(uri, headers: _defaultHeaders).timeout(timeout);
      if (response.statusCode != 200) return null;
      return parseResponse(response.body);
    } catch (_) {
      return null;
    }
  }

  /// 该端点把错误说明放在 `translatedText` 里而不是用非 200 表达，必须显式
  /// 识别，否则报错文本会被当成译文显示在弹幕上。
  static String? parseResponse(String body) {
    final decoded = jsonDecode(body);
    if (decoded is! Map) return null;
    final responseData = decoded['responseData'];
    if (responseData is! Map) return null;
    final translated = responseData['translatedText'];
    if (translated is! String) return null;
    final trimmed = translated.trim();
    if (trimmed.isEmpty) return null;
    final upper = trimmed.toUpperCase();
    if (upper.startsWith('INVALID LANGUAGE PAIR') ||
        upper.startsWith('QUERY LENGTH LIMIT') ||
        upper.contains('MYMEMORY WARNING')) {
      return null;
    }
    return trimmed;
  }
}

/// DeepL 官方接口（免费版端点）。
///
/// 需要用户自填 API key，因此默认不启用。**未在本机验证过**——没有可用的 key，
/// 请求体与语言代码按官方 REST 文档实现，首次接入时需要用户自测。
class DeepLTranslator extends DanmakuTranslator {
  DeepLTranslator({
    required this.apiKey,
    http.Client? client,
    this.timeout = const Duration(seconds: 10),
    this.useFreeEndpoint = true,
  }) : _client = client ?? sharedTranslationHttpClient();

  static const String freeEndpoint = 'https://api-free.deepl.com/v2/translate';
  static const String proEndpoint = 'https://api.deepl.com/v2/translate';

  final String apiKey;
  final http.Client _client;
  final Duration timeout;
  final bool useFreeEndpoint;

  /// 官方接口原生接受 `text` 数组，一次可送多条。
  @override
  int get batchSize => 8;

  @override
  Future<List<String?>> translate(
    List<String> texts, {
    required String sourceLang,
    required String targetLang,
  }) async {
    if (apiKey.trim().isEmpty) return List<String?>.filled(texts.length, null);
    final body = <String, dynamic>{
      'text': texts,
      'target_lang': _toDeepLTarget(targetLang),
    };
    final source = _toDeepLSource(sourceLang);
    if (source != null) body['source_lang'] = source;
    try {
      final response = await _client
          .post(
            Uri.parse(useFreeEndpoint ? freeEndpoint : proEndpoint),
            headers: <String, String>{
              'Authorization': 'DeepL-Auth-Key ${apiKey.trim()}',
              'Content-Type': 'application/json',
            },
            body: jsonEncode(body),
          )
          .timeout(timeout);
      if (response.statusCode != 200) return List<String?>.filled(texts.length, null);
      return parseResponse(response.bodyBytes, expected: texts.length);
    } catch (_) {
      return List<String?>.filled(texts.length, null);
    }
  }

  static List<String?> parseResponse(List<int> bodyBytes, {required int expected}) {
    final failed = List<String?>.filled(expected, null);
    final decoded = jsonDecode(utf8.decode(bodyBytes));
    if (decoded is! Map) return failed;
    final translations = decoded['translations'];
    if (translations is! List) return failed;
    final result = <String?>[];
    for (final entry in translations) {
      if (entry is Map && entry['text'] is String) {
        final text = (entry['text'] as String).trim();
        result.add(text.isEmpty ? null : text);
      } else {
        result.add(null);
      }
    }
    if (result.length != expected) return failed;
    return result;
  }

  /// DeepL 使用大写语言代码，自动检测时省略 source_lang。
  static String? _toDeepLSource(String sourceLang) {
    final normalized = sourceLang.trim();
    if (normalized.isEmpty || normalized == danmakuTranslationAutoSource) return null;
    return normalized.split(RegExp(r'[-_]')).first.toUpperCase();
  }

  static String _toDeepLTarget(String targetLang) {
    final normalized = targetLang.trim().toLowerCase();
    return normalized.split(RegExp(r'[-_]')).first.toUpperCase();
  }
}

/// 有道翻译的公开体验端点（aidemo），免 key。
///
/// 实测（2026-09-23）：`GET {base}/trans?q=..&from=Auto&to=zh-CHS` 返回
/// `{"translation": ["译文"], "errorCode": "0", "l": "en2zh-CHS", ...}`。
///
/// 两个必须照做的细节，都是实测踩出来的：
/// - `errorCode` 是**字符串** `"0"`，不是数字。按数字判断会把所有成功当失败。
/// - `translation` 是**数组**，要取第一个元素。
///
/// 质量明显好于 Argos 系小模型：同一句 `gg wp, that was a crazy clutch`，
/// Argos 译成"疯狂的离合器"，这里译成"疯狂的关键球"。
///
/// 代价是**有限流**：突发请求会触发 `errorCode=411`，实测约 20 秒后自动恢复。
/// 弹幕链路本就有窗口聚合、去重、缓存和熔断四重削减，正常观看打不满；真触发时
/// 按失败处理即可，熔断会兜住，不会演变成重试风暴。
class YoudaoTranslator extends DanmakuTranslator {
  YoudaoTranslator({
    this.endpointUrl = defaultEndpoint,
    http.Client? client,
    this.timeout = const Duration(seconds: 10),
  }) : _client = client ?? sharedTranslationHttpClient();

  /// 免 key 的公开体验端点。地址写死在引擎里：它无需用户配置，也不该被
  /// "自建端点"那一栏的地址串到——两者是完全不同的后端。
  static const String defaultEndpoint = 'https://aidemo.youdao.com';

  final String endpointUrl;
  final http.Client _client;
  final Duration timeout;

  /// 该端点会限流，一次只送一条，别自己把额度打满。
  @override
  int get batchSize => 1;

  @override
  Future<List<String?>> translate(
    List<String> texts, {
    required String sourceLang,
    required String targetLang,
  }) {
    return Future.wait(texts.map((text) => _translateOne(text, targetLang: targetLang)));
  }

  Future<String?> _translateOne(String text, {required String targetLang}) async {
    final uri = resolveEndpoint(endpointUrl, '/trans')?.replace(
      queryParameters: <String, String>{
        'q': text,
        // 实测 `from=Auto` 可用；具体源语言代码在这个端点上没有验证过，所以
        // 一律交给它自己检测，而不是赌一个没测过的写法。
        'from': 'Auto',
        'to': toYoudaoLanguage(targetLang),
      },
    );
    if (uri == null) return null;
    try {
      final response = await _client
          .get(uri, headers: const <String, String>{'Accept': 'application/json'})
          .timeout(timeout);
      if (response.statusCode != 200) return null;
      return parseResponse(response.bodyBytes);
    } catch (_) {
      return null;
    }
  }

  static String? parseResponse(List<int> bodyBytes) {
    final decoded = jsonDecode(utf8.decode(bodyBytes));
    if (decoded is! Map) return null;
    // 实测是字符串 "0"；对数字 0 也宽容，免得对方哪天改类型就全线失败。
    final errorCode = decoded['errorCode'];
    if (!(errorCode == '0' || errorCode == 0)) return null;
    final translation = decoded['translation'];
    if (translation is! List || translation.isEmpty) return null;
    final first = translation.first;
    if (first is! String) return null;
    final trimmed = first.trim();
    return trimmed.isEmpty ? null : trimmed;
  }
}

/// 有道使用 `Auto` / `zh-CHS` / `zh-CHT` 这套写法，其余语言用大写。
///
/// 实测：`to=zh-CHS` 成功且回显 `l=en2zh-CHS`；`to=zh` 与 `to=zh-CHT` 在本次
/// 测验里返回了 `errorCode=102`，所以简体固定走 `zh-CHS`，不去赌别名。
String toYoudaoLanguage(String language) {
  final normalized = language.trim();
  final lower = normalized.toLowerCase();
  if (lower.isEmpty || lower == danmakuTranslationAutoSource) return 'Auto';
  if (lower == 'zh-tw' || lower == 'zh-hant') return 'zh-CHT';
  if (lower.startsWith('zh')) return 'zh-CHS';
  return normalized.split(RegExp(r'[-_]')).first.toUpperCase();
}

/// 自建 LibreTranslate 实例。
///
/// 契约取自官方文档：`POST {base}/translate`，请求体 `{q, source, target, format}`，
/// 响应 `{"translatedText": "..."}`；`source` 接受 `"auto"` 做自动检测。自托管实例
/// 默认不需要 api_key，但配置了密钥的实例会需要，所以这里可选携带。
///
/// 文档只承诺 `q` 是字符串，因此逐条并发，不依赖未被文档承诺的批量数组形式。
/// 这样即便某些版本支持批量，也只是少省一点请求数，不会产生错误行为。
class LibreTranslateTranslator extends DanmakuTranslator {
  LibreTranslateTranslator({
    required this.endpointUrl,
    this.apiKey = '',
    http.Client? client,
    this.timeout = const Duration(seconds: 10),
  }) : _client = client ?? sharedTranslationHttpClient();

  final String endpointUrl;
  final String apiKey;
  final http.Client _client;
  final Duration timeout;

  @override
  int get batchSize => 4;

  @override
  Future<List<String?>> translate(
    List<String> texts, {
    required String sourceLang,
    required String targetLang,
  }) {
    return Future.wait(
      texts.map((text) => _translateOne(text, sourceLang: sourceLang, targetLang: targetLang)),
    );
  }

  Future<String?> _translateOne(
    String text, {
    required String sourceLang,
    required String targetLang,
  }) async {
    final uri = resolveEndpoint(endpointUrl, '/translate');
    if (uri == null) return null;
    final body = <String, dynamic>{
      'q': text,
      'source': toLanguageCode(sourceLang),
      'target': toLanguageCode(targetLang),
      'format': 'text',
    };
    if (apiKey.trim().isNotEmpty) body['api_key'] = apiKey.trim();
    try {
      final response = await _client
          .post(
            uri,
            headers: const <String, String>{'Content-Type': 'application/json'},
            body: jsonEncode(body),
          )
          .timeout(timeout);
      if (response.statusCode != 200) return null;
      return parseResponse(response.bodyBytes);
    } catch (_) {
      return null;
    }
  }

  static String? parseResponse(List<int> bodyBytes) {
    final decoded = jsonDecode(utf8.decode(bodyBytes));
    if (decoded is! Map) return null;
    final translated = decoded['translatedText'];
    if (translated is! String) return null;
    final trimmed = translated.trim();
    return trimmed.isEmpty ? null : trimmed;
  }
}

/// 任意 OpenAI 兼容的 `/chat/completions` 端点。
///
/// 用它可以把本地大模型接成弹幕后端：Ollama（`http://localhost:11434/v1`）、
/// llama.cpp server、LM Studio、vLLM 都是同一套协议。代价是逐条推理明显慢于
/// 专用翻译服务，所以 batchSize 保持 1，让闸门不要把大批消息压在一条请求上。
class OpenAiCompatibleTranslator extends DanmakuTranslator {
  OpenAiCompatibleTranslator({
    required this.endpointUrl,
    required this.modelName,
    this.apiKey = '',
    http.Client? client,
    this.timeout = const Duration(seconds: 20),
  }) : _client = client ?? sharedTranslationHttpClient();

  final String endpointUrl;
  final String modelName;
  final String apiKey;
  final http.Client _client;
  final Duration timeout;

  static const String systemPrompt =
      'You are a translation engine used for live-stream chat. Translate the user '
      'message into the requested target language and output ONLY the translation: '
      'no quotes, no explanations, no labels, no romanisation, no extra sentences. '
      'Preserve names, numbers, emoticons and laughter as-is.';

  /// 大模型逐条推理成本高，一次只送一条。
  @override
  int get batchSize => 1;

  @override
  Future<List<String?>> translate(
    List<String> texts, {
    required String sourceLang,
    required String targetLang,
  }) {
    return Future.wait(
      texts.map((text) => _translateOne(text, targetLang: targetLang)),
    );
  }

  Future<String?> _translateOne(String text, {required String targetLang}) async {
    final uri = resolveEndpoint(endpointUrl, '/chat/completions', ensureV1: true);
    if (uri == null || modelName.trim().isEmpty) return null;
    final headers = <String, String>{'Content-Type': 'application/json'};
    if (apiKey.trim().isNotEmpty) headers['Authorization'] = 'Bearer ${apiKey.trim()}';
    final body = <String, dynamic>{
      'model': modelName.trim(),
      'temperature': 0,
      'stream': false,
      'messages': <Map<String, String>>[
        {'role': 'system', 'content': '$systemPrompt Target language: $targetLang.'},
        {'role': 'user', 'content': text},
      ],
    };
    try {
      final response = await _client.post(uri, headers: headers, body: jsonEncode(body)).timeout(timeout);
      if (response.statusCode != 200) return null;
      return parseResponse(response.bodyBytes);
    } catch (_) {
      return null;
    }
  }

  static String? parseResponse(List<int> bodyBytes) {
    final decoded = jsonDecode(utf8.decode(bodyBytes));
    if (decoded is! Map) return null;
    final choices = decoded['choices'];
    if (choices is! List || choices.isEmpty) return null;
    final first = choices.first;
    if (first is! Map) return null;
    final message = first['message'];
    if (message is! Map) return null;
    final content = message['content'];
    if (content is! String) return null;
    return sanitize(content);
  }

  /// 本地小模型常带出"翻译："这类前缀、成对引号，或者多写一句解释。弹幕只有
  /// 一行，直接显示原样输出会很难看，所以在入库前清掉这些包装。
  static String? sanitize(String raw) {
    var text = raw.trim();
    final newline = text.indexOf('\n');
    if (newline >= 0) text = text.substring(0, newline).trim();
    const quotePairs = <List<String>>[
      ['"', '"'],
      ['“', '”'],
      ["'", "'"],
    ];
    for (final pair in quotePairs) {
      if (text.length >= 2 && text.startsWith(pair[0]) && text.endsWith(pair[1])) {
        text = text.substring(1, text.length - 1).trim();
      }
    }
    const prefixes = <String>['译文：', '译文:', '翻译：', '翻译:', 'Translation:', 'translation:'];
    for (final prefix in prefixes) {
      if (text.startsWith(prefix)) {
        text = text.substring(prefix.length).trim();
        break;
      }
    }
    return text.isEmpty ? null : text;
  }
}

/// 把用户填的地址补成可用的请求地址。
///
/// 用户可能填 `http://localhost:5000`、结尾带斜杠、或者漏掉 `/v1`（Ollama 的
/// OpenAI 兼容端点），这里统一收敛，避免因为一个斜杠就静默失败。
Uri? resolveEndpoint(String endpointUrl, String path, {bool ensureV1 = false}) {
  var base = endpointUrl.trim();
  if (base.isEmpty) return null;
  while (base.endsWith('/')) {
    base = base.substring(0, base.length - 1);
  }
  if (base.isEmpty) return null;
  if (ensureV1 && !base.endsWith('/v1')) base = '$base/v1';
  final uri = Uri.tryParse('$base$path');
  if (uri == null || uri.host.isEmpty) return null;
  return uri;
}

/// 目标/源语言转换成各后端认识的写法。
///
/// 实测（LibreTranslate 1.9.6 + Argos en/zh/ja 模型）：
/// - `target=zh` 与 `zh-Hans` 都接受；
/// - `zh-CN`、`zh-TW`、`zh-Hant` 一律返回 400。
///
/// 所以简体统一收敛到 `zh`（比 `zh-Hans` 更宽容，老实例也认）。繁体发
/// `zh-Hant`：它要求实例自己装了繁体模型，只装简体的实例会拒绝。这里刻意不把
/// 繁体静默降级成简体——用户选繁体就是要繁体，翻不出来应当暴露，而不是悄悄
/// 给一个他没要的结果。
///
/// OpenAI 兼容端点把代码原样交给模型，不做收敛。
String toLanguageCode(String language) {
  final normalized = language.trim();
  final lower = normalized.toLowerCase();
  if (lower.isEmpty) return danmakuTranslationAutoSource;
  if (lower == 'zh-tw' || lower == 'zh-hant') return 'zh-Hant';
  if (lower.startsWith('zh')) return 'zh';
  return normalized.split(RegExp(r'[-_]')).first;
}

/// 按持久化的服务标识构造后端。未知标识回落到默认的 Google 端点。
DanmakuTranslator createDanmakuTranslator({
  required String service,
  required String apiKey,
  String endpointUrl = '',
  String modelName = '',
  http.Client? client,
}) {
  return switch (service) {
    danmakuTranslationServiceMyMemory => MyMemoryTranslator(client: client),
    danmakuTranslationServiceDeepL => DeepLTranslator(apiKey: apiKey, client: client),
    danmakuTranslationServiceYoudao => YoudaoTranslator(client: client),
    danmakuTranslationServiceLibreTranslate => LibreTranslateTranslator(
      endpointUrl: endpointUrl,
      apiKey: apiKey,
      client: client,
    ),
    danmakuTranslationServiceOpenAiCompatible => OpenAiCompatibleTranslator(
      endpointUrl: endpointUrl,
      modelName: modelName,
      apiKey: apiKey,
      client: client,
    ),
    _ => GoogleGtxTranslator(client: client),
  };
}
