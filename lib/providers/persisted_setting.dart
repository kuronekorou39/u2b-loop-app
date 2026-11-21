import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/storage/app_boxes.dart';

/// 設定 box（Hive）に保存する設定 1 つ分。作るときに保存した値を読み、[value] に入れると
/// state を変えて同じ値を保存する（以前は同じ形の Notifier を設定ごとに書いていた）。
///
/// 保存の形が値そのものでないもの（enum は名前で保存する）は [encode] / [decode]。
/// 保存が無ければ（初めての起動）既定値。前の版の設定からの移し替えや、値の丸めが要るものは
/// これを継いで足す
class PersistedSetting<T> extends StateNotifier<T> {
  PersistedSetting(
    this.key,
    T defaultValue, {
    Object? Function(T value)? encode,
    T Function(Object saved)? decode,
  })  : _encode = encode,
        super(defaultValue) {
    final saved = AppBoxes.settings.get(key);
    if (saved != null) state = decode != null ? decode(saved) : saved as T;
  }

  /// 設定 box のキー（[SettingsKeys]）
  final String key;
  final Object? Function(T value)? _encode;

  /// 保存されているか（無ければ既定値のまま。移し替えの判断に使う）
  bool get isSaved => AppBoxes.settings.get(key) != null;

  set value(T v) {
    state = v;
    AppBoxes.settings.put(key, _encode == null ? v : _encode(v));
  }
}

/// オンオフの設定
class PersistedBool extends PersistedSetting<bool> {
  PersistedBool(super.key, super.defaultValue);

  /// オンとオフを入れ替えて保存
  void toggle() => value = !state;
}

/// enum の設定（名前で保存。知らない名前・保存なしは [fromName] が既定値を返す）
class PersistedEnum<T extends Enum> extends PersistedSetting<T> {
  PersistedEnum(super.key, super.defaultValue,
      {required T Function(String? name) fromName})
      : super(encode: (v) => v.name, decode: (saved) => fromName(saved as String));
}
