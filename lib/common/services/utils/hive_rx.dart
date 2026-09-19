import 'dart:async';
import 'dart:convert';

import 'package:pure_live/get/get.dart';
import 'package:pure_live/common/utils/hive_pref_util.dart';

final _persistCurrentValue = Expando<void Function()>('hive-persist-current');

/// Storage key -> a closure that adopts an externally supplied value.
///
/// Storage alone is not enough when a settings patch arrives from another
/// process: a page that already created the owning controller keeps observing
/// its own Rx, so the patch has to reach that instance as well.
final Map<String, void Function(dynamic)> _prefRxAppliers = <String, void Function(dynamic)>{};

/// Drops every registration. Only independent test fixtures need this.
void resetPrefRxRegistry() => _prefRxAppliers.clear();

/// Adopts [incoming] as type [T] when the JSON round trip changed its shape
/// (`150` for a double, for example). Returns null when the value cannot be
/// expressed as [T]; a `hiveObject` controller persists a JSON string while
/// holding a decoded object, so it decodes its own payload instead of relying
/// on this.
T? _coercePrefValue<T>(dynamic incoming) {
  if (incoming is T) return incoming;
  if (T == double && incoming is num) return incoming.toDouble() as T;
  if (T == int && incoming is num) return incoming.toInt() as T;
  return null;
}

RxBool hiveBool(String key, bool defaultValue) {
  final initialValue = HivePrefUtil.getBool(key) ?? defaultValue;

  return RxBool(initialValue)..hive(key);
}

RxString hiveString(String key, String defaultValue) {
  final initialValue = HivePrefUtil.getString(key) ?? defaultValue;

  return RxString(initialValue)..hive(key);
}

RxInt hiveInt(String key, int defaultValue) {
  final initialValue = HivePrefUtil.getInt(key) ?? defaultValue;

  return RxInt(initialValue)..hive(key);
}

RxDouble hiveDouble(String key, double defaultValue) {
  final initialValue = HivePrefUtil.getDouble(key) ?? defaultValue;

  return RxDouble(initialValue)..hive(key);
}

RxList<String> hiveStringList(String key, List<String> defaultValue) {
  final initialValue = HivePrefUtil.getStringList(key);

  if (initialValue != null) {
    return RxList<String>(List<String>.from(initialValue))..hiveList(key);
  }

  return RxList<String>(List<String>.from(defaultValue))..hiveList(key);
}

Rx<T> hiveObject<T>(
  String key,
  T defaultValue, {
  required T Function(Map<String, dynamic>) fromJson,
  required Map<String, dynamic> Function(T value) toJson,
}) {
  final jsonStr = HivePrefUtil.getString(key);

  T initialValue = defaultValue;

  if (jsonStr != null && jsonStr.isNotEmpty) {
    try {
      initialValue = fromJson(jsonDecode(jsonStr));
    } catch (_) {}
  }

  return Rx<T>(initialValue)..hiveObject(key, fromJson: fromJson, toJson: toJson);
}

extension HiveRxExtension<T> on Rx<T> {
  T get v => value;

  set v(T newValue) {
    value = newValue;
    // A failed disk write may leave this Rx value already equal to a retry's
    // input. Persist it without manufacturing a UI notification in that case.
    if (HivePrefUtil.isCollectingWrites) _persistCurrentValue[this]?.call();
  }

  void hive(String key) {
    _prefRxAppliers[key] = (dynamic incoming) {
      final coerced = _coercePrefValue<T>(incoming);
      if (coerced != null) value = coerced;
    };
    _persistCurrentValue[this] = () => unawaited(HivePrefUtil.setAnyPref(key, value));
    ever<T>(this, (value) {
      if (value is bool) {
        unawaited(HivePrefUtil.setBool(key, value));
      } else if (value is String) {
        unawaited(HivePrefUtil.setString(key, value));
      } else if (value is int) {
        unawaited(HivePrefUtil.setInt(key, value));
      } else if (value is double) {
        unawaited(HivePrefUtil.setDouble(key, value));
      } else {
        unawaited(HivePrefUtil.setAnyPref(key, value));
      }
    });
  }

  void hiveObject(
    String key, {
    required T Function(Map<String, dynamic>) fromJson,
    required Map<String, dynamic> Function(T value) toJson,
  }) {
    // A patch from another process carries this setting in its persisted form -
    // a JSON string - while the controller holds the decoded object. Decoding
    // it here is what lets a controller that is already alive adopt a child
    // window's change; without it the patch reaches storage only, so every open
    // page keeps showing the old value and the next snapshot exports it too.
    _prefRxAppliers[key] = (dynamic incoming) {
      if (incoming is String) {
        try {
          value = fromJson(jsonDecode(incoming));
        } catch (_) {
          // Keep the current value: a malformed payload must not clear it.
        }
        return;
      }
      final coerced = _coercePrefValue<T>(incoming);
      if (coerced != null) value = coerced;
    };
    _persistCurrentValue[this] = () => unawaited(HivePrefUtil.setString(key, jsonEncode(toJson(value))));
    ever<T>(this, (value) {
      try {
        unawaited(HivePrefUtil.setString(key, jsonEncode(toJson(value))));
      } catch (_) {}
    }, condition: () => true);
  }
}

extension HiveRxListExtension on RxList<String> {
  List<String> get v => this;

  set v(List<String> newValue) {
    try {
      assignAll(List<String>.from(newValue));
    } catch (_) {
      value = List<String>.from(newValue);
    }
  }

  void hiveList(String key) {
    _prefRxAppliers[key] = (dynamic incoming) {
      if (incoming is List) {
        assignAll(incoming.map((element) => element.toString()).toList(growable: false));
      }
    };
    ever<List<String>>(this, (value) {
      unawaited(HivePrefUtil.setStringList(key, value));
    });
  }
}

/// Applies a setting that another process changed.
///
/// The persisted value is always written. The in-memory Rx is updated too
/// whenever this process has already created the owning controller, which is
/// what keeps an open page consistent with a patch it just merged. Keys whose
/// controller does not exist yet need no help - they read the new value from
/// storage when they are constructed.
Future<void> applyExternalPref(String key, dynamic value) async {
  final apply = _prefRxAppliers[key];
  if (apply != null) {
    try {
      apply(value);
    } catch (_) {
      // A registration can outlive its disposed controller. Storage stays
      // authoritative and the next construction picks the value up.
    }
  }
  await HivePrefUtil.setAnyPref(key, value);
}
