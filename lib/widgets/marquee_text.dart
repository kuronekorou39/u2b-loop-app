import 'package:flutter/material.dart';

/// テキストが親幅を超える場合にのみ横スクロールするマーキー
class MarqueeText extends StatefulWidget {
  final String text;
  final TextStyle? style;

  const MarqueeText({super.key, required this.text, this.style});

  @override
  State<MarqueeText> createState() => _MarqueeTextState();
}

class _MarqueeTextState extends State<MarqueeText>
    with SingleTickerProviderStateMixin {
  late final ScrollController _scrollController;
  AnimationController? _animController;

  @override
  void initState() {
    super.initState();
    _scrollController = ScrollController();
    WidgetsBinding.instance.addPostFrameCallback((_) => _checkOverflow());
  }

  @override
  void didUpdateWidget(MarqueeText old) {
    super.didUpdateWidget(old);
    if (old.text != widget.text) {
      _animController?.dispose();
      _animController = null;
      _scrollController.jumpTo(0);
      WidgetsBinding.instance.addPostFrameCallback((_) => _checkOverflow());
    }
  }

  void _checkOverflow() {
    if (!mounted) return;
    final maxScroll = _scrollController.position.maxScrollExtent;
    if (maxScroll > 0) {
      _startAnimation(maxScroll);
    }
  }

  void _startAnimation(double maxScroll) {
    _animController?.dispose();
    // スクロール速度: 30px/秒
    final durationMs = (maxScroll / 30 * 1000).round().clamp(2000, 15000);
    _animController = AnimationController(
      vsync: this,
      duration: Duration(milliseconds: durationMs),
    );
    _animController!.addListener(() {
      if (_scrollController.hasClients) {
        _scrollController.jumpTo(_animController!.value * maxScroll);
      }
    });
    // 2秒待ってからスクロール開始、端で2秒待って逆戻り
    Future.delayed(const Duration(seconds: 2), () {
      if (!mounted) return;
      _animController?.repeat(reverse: true);
    });
  }

  @override
  void dispose() {
    _animController?.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      controller: _scrollController,
      scrollDirection: Axis.horizontal,
      physics: const NeverScrollableScrollPhysics(),
      child: Text(
        widget.text,
        style: widget.style,
        maxLines: 1,
        softWrap: false,
      ),
    );
  }
}
