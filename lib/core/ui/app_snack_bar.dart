import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// 画面の下に出す短い通知（アプリ独自。Flutter の SnackBar は使わない）。
///
/// v1.130.0 まで SnackBar だったが、(1) 「元に戻す」付きは今の Flutter では自動で消えず出っぱなし、
/// (2) 既定の白地に黒文字でアプリの色と合わない、(3) 画面に「＋」ボタンがあるとその上まで持ち上がって
/// 一覧を隠し、ミニプレイヤーの有無で形も変わっていた。
/// いまは App の builder に置いた [AppToastHost] が、どの画面でもミニプレイヤーのすぐ上の同じ位置に
/// 同じ形で出す。時間が来たら必ず消え、タップでもすぐ消える。
///
/// 呼び方: `AppToast.instance.show(AppSnackBar.success('保存しました'))`。
/// 種類（[AppSnackBar.success] など）で表示時間とアイコンが決まる
class AppSnackBar {
  AppSnackBar._();

  /// 完了通知。読まなくても困らないので短く消す
  static const successDuration = Duration(seconds: 2);

  /// 案内・注意。ひと呼吸読む時間が要る
  static const infoDuration = Duration(seconds: 3);

  /// エラー。原因が書いてあるので長め
  static const errorDuration = Duration(seconds: 5);

  /// ボタン付き（元に戻す等）。押す間があるように少し長め
  static const actionDuration = Duration(seconds: 5);

  /// 進行中。完了時に `hide()` で消す前提の長さ
  static const progressDuration = Duration(seconds: 30);

  /// 処理が終わったことを伝える
  static AppToastMessage success(String message, {Duration? duration}) =>
      AppToastMessage(message, kind: ToastKind.success, duration: duration ?? successDuration);

  /// 操作できない理由や補足を伝える
  static AppToastMessage info(String message, {Duration? duration}) =>
      AppToastMessage(message, kind: ToastKind.info, duration: duration ?? infoDuration);

  /// 失敗を伝える
  static AppToastMessage error(String message, {Duration? duration}) =>
      AppToastMessage(message, kind: ToastKind.error, duration: duration ?? errorDuration);

  /// 処理中を出しっぱなしにする。呼び出し側が `hide()` で消すこと
  static AppToastMessage progress(String message) =>
      AppToastMessage(message, kind: ToastKind.progress, duration: progressDuration);

  /// ボタン付き（キャンセル・元に戻す等）。時間が来たら消える
  static AppToastMessage action(
    String message, {
    required String label,
    required VoidCallback onPressed,
    Duration? duration,
  }) =>
      AppToastMessage(message,
          kind: ToastKind.info,
          duration: duration ?? actionDuration,
          actionLabel: label,
          onAction: onPressed);
}

enum ToastKind { success, info, error, progress }

/// 通知 1 つ
class AppToastMessage {
  AppToastMessage(
    this.message, {
    required this.kind,
    required this.duration,
    this.actionLabel,
    this.onAction,
  });

  final String message;
  final ToastKind kind;
  final Duration duration;
  final String? actionLabel;
  final VoidCallback? onAction;
}

/// 通知を出す・消す。どの画面からでも、画面を閉じた後に終わる裏の処理からでも使える
/// （出す場所はアプリに 1 つ）
class AppToast {
  AppToast._();

  static final instance = AppToast._();

  /// いま出ている通知（null = 出ていない）
  final current = ValueNotifier<AppToastMessage?>(null);

  /// 通知の右端を画面の右からどれだけ空けるか（[ToastObstacle] を避ける分）
  final rightInset = ValueNotifier<double>(0);
  Timer? _timer;

  /// [message] を出す（出ていたものは置き換える）
  void show(AppToastMessage message) {
    _timer?.cancel();
    rightInset.value = ToastObstacle.rightInset();
    current.value = message;
    _timer = Timer(message.duration, () {
      if (identical(current.value, message)) current.value = null;
    });
  }

  /// 出ている通知を消す
  void hide() {
    _timer?.cancel();
    current.value = null;
  }
}

/// 通知が重なってはいけない部品（画面右下の + ボタン）を包む。
/// 今いる画面のものだけ避けるので、下に隠れた画面のボタンのぶんは詰めない
class ToastObstacle extends StatefulWidget {
  const ToastObstacle({super.key, required this.child});

  final Widget child;

  static final _mounted = <_ToastObstacleState>{};

  /// 通知の右端を画面の右から空ける長さ（避けるものが無ければ 0）
  static double rightInset() {
    var inset = 0.0;
    for (final o in _mounted) {
      final box = o.context.findRenderObject();
      if (box is! RenderBox || !box.hasSize || !box.attached) continue;
      if (ModalRoute.of(o.context)?.isCurrent == false) continue;
      final screen = MediaQuery.sizeOf(o.context).width;
      final left = box.localToGlobal(Offset.zero).dx;
      inset = max(inset, screen - left + AppSpacing.sm);
    }
    return inset;
  }

  @override
  State<ToastObstacle> createState() => _ToastObstacleState();
}

class _ToastObstacleState extends State<ToastObstacle> {
  @override
  void initState() {
    super.initState();
    ToastObstacle._mounted.add(this);
  }

  @override
  void dispose() {
    ToastObstacle._mounted.remove(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// 通知を出す場所。App の builder の Stack に 1 つ置く。[bottom] は画面の下からの位置
/// （ミニプレイヤーとシステムのナビゲーションの上）
class AppToastHost extends StatelessWidget {
  const AppToastHost({super.key, required this.bottom});

  final double bottom;

  /// 横幅の上限（タブレットや横画面で横に伸びすぎないように）
  static const maxWidth = 480.0;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<AppToastMessage?>(
      valueListenable: AppToast.instance.current,
      builder: (context, message, _) {
        return Positioned(
          left: AppSpacing.lg,
          right: max(AppSpacing.lg, AppToast.instance.rightInset.value),
          bottom: bottom + AppSpacing.md,
          child: Align(
            alignment: Alignment.bottomCenter,
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 180),
              transitionBuilder: (child, anim) => FadeTransition(
                opacity: anim,
                child: SlideTransition(
                  position: Tween(begin: const Offset(0, 0.3), end: Offset.zero)
                      .animate(anim),
                  child: child,
                ),
              ),
              child: message == null
                  ? const SizedBox.shrink()
                  : ConstrainedBox(
                      key: ObjectKey(message),
                      constraints: const BoxConstraints(maxWidth: maxWidth),
                      child: _ToastCard(message: message),
                    ),
            ),
          ),
        );
      },
    );
  }
}

class _ToastCard extends StatelessWidget {
  const _ToastCard({required this.message});

  final AppToastMessage message;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dark = theme.brightness == Brightness.dark;
    final fg = dark ? Colors.white : const Color(0xFF1A1A2E);
    final Widget icon = switch (message.kind) {
      ToastKind.success =>
        const Icon(Icons.check_circle, size: AppIconSizes.sm, color: AppTheme.accentGreen),
      ToastKind.info =>
        Icon(Icons.info_outline, size: AppIconSizes.sm, color: fg.withValues(alpha: 0.7)),
      ToastKind.error =>
        const Icon(Icons.error_outline, size: AppIconSizes.sm, color: AppTheme.accentRed),
      ToastKind.progress => const SizedBox(
          width: AppIconSizes.sm,
          height: AppIconSizes.sm,
          child: CircularProgressIndicator(strokeWidth: 2, color: AppTheme.accentGreen),
        ),
    };
    return Material(
      color: dark ? const Color(0xF2232845) : const Color(0xF2FFFFFF),
      elevation: 6,
      shadowColor: Colors.black54,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(
          color: message.kind == ToastKind.error
              ? AppTheme.accentRed.withValues(alpha: 0.6)
              : fg.withValues(alpha: 0.12),
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        // タップで消す（ボタンは別）
        onTap: AppToast.instance.hide,
        child: Padding(
          padding: EdgeInsets.fromLTRB(AppSpacing.lg, AppSpacing.md,
              message.actionLabel == null ? AppSpacing.lg : AppSpacing.sm, AppSpacing.md),
          child: Row(
            children: [
              icon,
              const SizedBox(width: AppSpacing.md),
              Expanded(
                child: Text(
                  message.message,
                  style: theme.textTheme.bodyMedium?.copyWith(color: fg),
                ),
              ),
              if (message.actionLabel != null) ...[
                const SizedBox(width: AppSpacing.sm),
                TextButton(
                  onPressed: () {
                    AppToast.instance.hide();
                    message.onAction?.call();
                  },
                  style: TextButton.styleFrom(
                    foregroundColor: AppTheme.accentGreen,
                    visualDensity: VisualDensity.compact,
                  ),
                  child: Text(message.actionLabel!,
                      style: const TextStyle(fontWeight: FontWeight.bold)),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
