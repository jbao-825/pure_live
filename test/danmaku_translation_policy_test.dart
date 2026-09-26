import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:pure_live/core/translation/danmaku_translator.dart';

void main() {
  group('danmakuNeedsTranslation', () {
    test('skips text that carries no language at all', () {
      expect(danmakuNeedsTranslation('666', targetLang: 'zh-CN'), isFalse);
      expect(danmakuNeedsTranslation('2333', targetLang: 'zh-CN'), isFalse);
      expect(danmakuNeedsTranslation('?!?', targetLang: 'zh-CN'), isFalse);
      expect(danmakuNeedsTranslation('', targetLang: 'zh-CN'), isFalse);
      expect(danmakuNeedsTranslation('   ', targetLang: 'zh-CN'), isFalse);
    });

    test('skips text that is already the target language', () {
      expect(danmakuNeedsTranslation('这把打得真好', targetLang: 'zh-CN'), isFalse);
      expect(danmakuNeedsTranslation('哈哈哈哈', targetLang: 'zh-CN'), isFalse);
      expect(danmakuNeedsTranslation('中文', targetLang: 'zh-CN'), isFalse);
    });

    test('translates latin text when the target is Chinese', () {
      expect(danmakuNeedsTranslation('gg wp', targetLang: 'zh-CN'), isTrue);
      expect(danmakuNeedsTranslation('hello world', targetLang: 'zh-CN'), isTrue);
      expect(danmakuNeedsTranslation('lol', targetLang: 'zh-CN'), isTrue);
    });

    test('treats kana and hangul as languages that still need translation', () {
      expect(danmakuNeedsTranslation('こんにちは', targetLang: 'zh-CN'), isTrue);
      expect(danmakuNeedsTranslation('안녕하세요', targetLang: 'zh-CN'), isTrue);
      // 日文里的汉字不能让它被误判成中文，否则整句会被跳过。
      expect(danmakuNeedsTranslation('今日はいい天気ですね', targetLang: 'zh-CN'), isTrue);
    });

    test('translates mixed text once latin letters dominate han characters', () {
      expect(danmakuNeedsTranslation('这歌good', targetLang: 'zh-CN'), isTrue);
      expect(danmakuNeedsTranslation('好听好听music', targetLang: 'zh-CN'), isTrue);
      // 混排到汉字更少时宁可多翻一次：漏翻会让用户读不懂，多翻一次只是浪费
      // 一条请求，而且还有缓存与去重兜底。
      expect(danmakuNeedsTranslation('哈哈哈xswl', targetLang: 'zh-CN'), isTrue);
    });

    test('always translates when the target is not a CJK language', () {
      expect(danmakuNeedsTranslation('中文弹幕', targetLang: 'en'), isTrue);
      expect(danmakuNeedsTranslation('666', targetLang: 'en'), isFalse);
    });

    test('skips over-long text', () {
      expect(danmakuNeedsTranslation(List<String>.filled(200, 'a').join(), targetLang: 'zh-CN'), isTrue);
      expect(danmakuNeedsTranslation(List<String>.filled(201, 'a').join(), targetLang: 'zh-CN'), isFalse);
    });
  });

  group('GoogleGtxTranslator.parseResponse', () {
    test('concatenates every segment of the first group', () {
      final body = utf8.encode(
        jsonEncode([
          [
            ['你好', 'hello', null, null, 10],
            ['世界', 'world', null, null, 10],
          ],
          null,
          'en',
        ]),
      );
      expect(GoogleGtxTranslator.parseResponse(body), '你好世界');
    });

    test('rejects malformed and empty payloads', () {
      expect(GoogleGtxTranslator.parseResponse(utf8.encode('{}')), isNull);
      expect(GoogleGtxTranslator.parseResponse(utf8.encode('[]')), isNull);
      expect(GoogleGtxTranslator.parseResponse(utf8.encode('[[],null,"en"]')), isNull);
    });
  });

  group('MyMemoryTranslator.parseResponse', () {
    test('reads the translated text', () {
      expect(
        MyMemoryTranslator.parseResponse(jsonEncode({'responseData': {'translatedText': '你好世界'}})),
        '你好世界',
      );
    });

    test('rejects the placeholder text the endpoint returns instead of failing', () {
      expect(
        MyMemoryTranslator.parseResponse(
          jsonEncode({
            'responseData': {'translatedText': 'INVALID LANGUAGE PAIR SPECIFIED. EXAMPLE: LANGPAIR=EN|IT'},
          }),
        ),
        isNull,
      );
      expect(
        MyMemoryTranslator.parseResponse(
          jsonEncode({'responseData': {'translatedText': 'MYMEMORY WARNING: YOU USED ALL AVAILABLE FREE TRANSLATIONS'}}),
        ),
        isNull,
      );
    });

    test('rejects payloads without a usable translation', () {
      expect(MyMemoryTranslator.parseResponse(jsonEncode({'responseData': {}})), isNull);
      expect(MyMemoryTranslator.parseResponse(jsonEncode({})), isNull);
    });
  });

  group('DeepLTranslator.parseResponse', () {
    test('reads translations in request order', () {
      final body = utf8.encode(
        jsonEncode({
          'translations': [
            {'text': '你好'},
            {'text': '世界'},
          ],
        }),
      );
      expect(DeepLTranslator.parseResponse(body, expected: 2), ['你好', '世界']);
    });

    test('fails every entry when the response length does not match', () {
      final body = utf8.encode(
        jsonEncode({
          'translations': [
            {'text': '你好'},
          ],
        }),
      );
      expect(DeepLTranslator.parseResponse(body, expected: 2), [null, null]);
    });

    test('without a key it reports untranslated instead of dialling out', () async {
      final translator = DeepLTranslator(apiKey: '   ');
      expect(await translator.translate(['hello'], sourceLang: 'auto', targetLang: 'zh-CN'), [null]);
    });
  });

  group('resolveEndpoint', () {
    test('appends the path and normalises trailing slashes', () {
      expect(resolveEndpoint('http://localhost:5000', '/translate')?.toString(), 'http://localhost:5000/translate');
      expect(resolveEndpoint('http://localhost:5000/', '/translate')?.toString(), 'http://localhost:5000/translate');
      expect(resolveEndpoint('http://localhost:5000///', '/translate')?.toString(), 'http://localhost:5000/translate');
    });

    test('adds the /v1 segment only when asked and only when it is missing', () {
      expect(
        resolveEndpoint('http://localhost:11434', '/chat/completions', ensureV1: true)?.toString(),
        'http://localhost:11434/v1/chat/completions',
      );
      expect(
        resolveEndpoint('http://localhost:11434/v1', '/chat/completions', ensureV1: true)?.toString(),
        'http://localhost:11434/v1/chat/completions',
      );
      expect(
        resolveEndpoint('http://localhost:11434', '/translate')?.toString(),
        'http://localhost:11434/translate',
      );
    });

    test('refuses an empty or unusable address instead of guessing one', () {
      expect(resolveEndpoint('', '/translate'), isNull);
      expect(resolveEndpoint('   ', '/translate'), isNull);
      expect(resolveEndpoint('not-a-url', '/translate'), isNull);
    });
  });

  group('toLanguageCode', () {
    test('collapses Chinese variants into the codes LibreTranslate uses', () {
      expect(toLanguageCode('zh-CN'), 'zh');
      expect(toLanguageCode('zh'), 'zh');
      expect(toLanguageCode('zh-TW'), 'zh-Hant');
      expect(toLanguageCode('zh-Hant'), 'zh-Hant');
    });

    test('keeps other languages as their base subtag', () {
      expect(toLanguageCode('en'), 'en');
      expect(toLanguageCode('ja-JP'), 'ja');
      expect(toLanguageCode('ko_KR'), 'ko');
    });

    test('maps an empty source to automatic detection', () {
      expect(toLanguageCode(''), danmakuTranslationAutoSource);
    });
  });

  group('LibreTranslateTranslator.parseResponse', () {
    test('reads translatedText', () {
      expect(
        LibreTranslateTranslator.parseResponse(utf8.encode(jsonEncode({'translatedText': '你好'}))),
        '你好',
      );
    });

    test('rejects payloads without a usable translation', () {
      expect(LibreTranslateTranslator.parseResponse(utf8.encode('{}')), isNull);
      expect(LibreTranslateTranslator.parseResponse(utf8.encode(jsonEncode({'translatedText': '   '}))), isNull);
      expect(LibreTranslateTranslator.parseResponse(utf8.encode('[]')), isNull);
    });
  });

  group('OpenAiCompatibleTranslator', () {
    test('reads the first choice message', () {
      final body = utf8.encode(
        jsonEncode({
          'choices': [
            {'message': {'role': 'assistant', 'content': '你好世界'}},
          ],
        }),
      );
      expect(OpenAiCompatibleTranslator.parseResponse(body), '你好世界');
    });

    test('keeps only the first line and strips the wrappers local models add', () {
      expect(OpenAiCompatibleTranslator.sanitize('“你好”\n这是一句解释'), '你好');
      expect(OpenAiCompatibleTranslator.sanitize('译文：你好'), '你好');
      expect(OpenAiCompatibleTranslator.sanitize('  "hello"  '), 'hello');
      expect(OpenAiCompatibleTranslator.sanitize('   '), isNull);
    });

    test('rejects malformed payloads', () {
      expect(OpenAiCompatibleTranslator.parseResponse(utf8.encode('{}')), isNull);
      expect(OpenAiCompatibleTranslator.parseResponse(utf8.encode(jsonEncode({'choices': <Object>[]}))), isNull);
    });
  });

  group('danmakuTranslationNeedsEndpoint', () {
    test('is true only for the two self-hosted backends', () {
      expect(danmakuTranslationNeedsEndpoint(danmakuTranslationServiceLibreTranslate), isTrue);
      expect(danmakuTranslationNeedsEndpoint(danmakuTranslationServiceOpenAiCompatible), isTrue);
      expect(danmakuTranslationNeedsEndpoint(danmakuTranslationServiceGoogle), isFalse);
      expect(danmakuTranslationNeedsEndpoint(danmakuTranslationServiceDeepL), isFalse);
    });
  });

  group('toYoudaoLanguage', () {
    test('maps Chinese variants to the codes this endpoint accepts', () {
      expect(toYoudaoLanguage('zh-CN'), 'zh-CHS');
      expect(toYoudaoLanguage('zh'), 'zh-CHS');
      expect(toYoudaoLanguage('zh-TW'), 'zh-CHT');
      expect(toYoudaoLanguage('zh-Hant'), 'zh-CHT');
    });

    test('upper-cases other languages and defaults to Auto', () {
      expect(toYoudaoLanguage('en'), 'EN');
      expect(toYoudaoLanguage('ja-JP'), 'JA');
      expect(toYoudaoLanguage(''), 'Auto');
      expect(toYoudaoLanguage('auto'), 'Auto');
    });
  });

  group('YoudaoTranslator.parseResponse', () {
    Map<String, dynamic> payload(Object? errorCode, Object? translation) => {
      'errorCode': errorCode,
      'translation': translation,
      'l': 'en2zh-CHS',
    };

    test('reads the first element of the translation array', () {
      expect(
        YoudaoTranslator.parseResponse(utf8.encode(jsonEncode(payload('0', ['你好世界'])))),
        '你好世界',
      );
    });

    test('accepts a numeric zero as well as the string form', () {
      // 实测该端点的 errorCode 是字符串 "0"；对数字宽容一点，免得对方哪天改
      // 类型就变成全线静默失败。
      expect(YoudaoTranslator.parseResponse(utf8.encode(jsonEncode(payload(0, ['你好'])))), '你好');
    });

    test('treats a non-zero errorCode as a failure even when text is present', () {
      // 限流时实测返回 errorCode=411；带着译文的异常码同样不能当成功放行。
      expect(YoudaoTranslator.parseResponse(utf8.encode(jsonEncode(payload('411', ['x'])))), isNull);
      expect(YoudaoTranslator.parseResponse(utf8.encode(jsonEncode(payload('102', null)))), isNull);
    });

    test('rejects unusable payloads', () {
      expect(YoudaoTranslator.parseResponse(utf8.encode('{}')), isNull);
      expect(YoudaoTranslator.parseResponse(utf8.encode(jsonEncode(payload('0', <String>[])))), isNull);
      expect(YoudaoTranslator.parseResponse(utf8.encode(jsonEncode(payload('0', ['   '])))), isNull);
      expect(YoudaoTranslator.parseResponse(utf8.encode('[]')), isNull);
    });
  });

  group('sharedTranslationHttpClient', () {
    test('hands out one shared client so connections get reused', () {
      resetSharedTranslationHttpClient();
      final first = sharedTranslationHttpClient();
      final second = sharedTranslationHttpClient();
      expect(identical(first, second), isTrue);
      resetSharedTranslationHttpClient();
    });

    test('resetting drops the old client so a proxy change is re-evaluated', () {
      resetSharedTranslationHttpClient();
      final first = sharedTranslationHttpClient();
      resetSharedTranslationHttpClient();
      final second = sharedTranslationHttpClient();
      expect(identical(first, second), isFalse);
      resetSharedTranslationHttpClient();
    });
  });

  group('createDanmakuTranslator', () {
    test('builds the configured backend', () {
      expect(
        createDanmakuTranslator(service: danmakuTranslationServiceMyMemory, apiKey: ''),
        isA<MyMemoryTranslator>(),
      );
      expect(
        createDanmakuTranslator(service: danmakuTranslationServiceDeepL, apiKey: 'key'),
        isA<DeepLTranslator>(),
      );
    });

    test('builds the self-hosted backends from the configured address', () {
      expect(
        createDanmakuTranslator(
          service: danmakuTranslationServiceLibreTranslate,
          apiKey: '',
          endpointUrl: 'http://localhost:5000',
        ),
        isA<LibreTranslateTranslator>(),
      );
      expect(
        createDanmakuTranslator(
          service: danmakuTranslationServiceOpenAiCompatible,
          apiKey: '',
          endpointUrl: 'http://localhost:11434/v1',
          modelName: 'qwen2.5:7b',
        ),
        isA<OpenAiCompatibleTranslator>(),
      );
    });

    test('builds the Youdao backend without requiring any configuration', () {
      expect(
        createDanmakuTranslator(service: danmakuTranslationServiceYoudao, apiKey: ''),
        isA<YoudaoTranslator>(),
      );
    });

    test('falls back to the default endpoint for an unknown service id', () {
      expect(createDanmakuTranslator(service: 'nope', apiKey: ''), isA<GoogleGtxTranslator>());
    });
  });
}
