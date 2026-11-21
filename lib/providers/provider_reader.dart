import 'package:flutter_riverpod/flutter_riverpod.dart';

/// プロバイダーを読む関数（`ref.read` / `WidgetRef.read` をそのまま渡せる）。
/// 画面（WidgetRef）とプロバイダー（Ref）のどちらからでも同じ手順を呼べるように使う
typedef ProviderReader = T Function<T>(ProviderListenable<T> provider);
