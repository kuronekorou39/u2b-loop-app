class LoopState {
  final Duration pointA;
  final Duration pointB;
  final bool enabled;
  final double gapSeconds;
  final bool isInGap;
  final double adjustStep;

  const LoopState({
    this.pointA = Duration.zero,
    this.pointB = Duration.zero,
    this.enabled = false,
    this.gapSeconds = 0,
    this.isInGap = false,
    this.adjustStep = 0.1,
  });

  bool get hasPoints => pointA > Duration.zero || pointB > Duration.zero;

  LoopState copyWith({
    Duration? pointA,
    Duration? pointB,
    bool? enabled,
    double? gapSeconds,
    bool? isInGap,
    double? adjustStep,
  }) {
    return LoopState(
      pointA: pointA ?? this.pointA,
      pointB: pointB ?? this.pointB,
      enabled: enabled ?? this.enabled,
      gapSeconds: gapSeconds ?? this.gapSeconds,
      isInGap: isInGap ?? this.isInGap,
      adjustStep: adjustStep ?? this.adjustStep,
    );
  }
}
