class LoopState {
  final Duration? pointA;
  final Duration? pointB;
  final bool enabled;
  final double gapSeconds;
  final bool isInGap;
  final double adjustStep;

  const LoopState({
    this.pointA,
    this.pointB,
    this.enabled = false,
    this.gapSeconds = 0,
    this.isInGap = false,
    this.adjustStep = 0.1,
  });

  bool get hasA => pointA != null;
  bool get hasB => pointB != null;
  bool get hasPoints => hasA || hasB;
  bool get hasBothPoints => hasA && hasB;

  LoopState copyWith({
    Duration? Function()? pointA,
    Duration? Function()? pointB,
    bool? enabled,
    double? gapSeconds,
    bool? isInGap,
    double? adjustStep,
  }) {
    return LoopState(
      pointA: pointA != null ? pointA() : this.pointA,
      pointB: pointB != null ? pointB() : this.pointB,
      enabled: enabled ?? this.enabled,
      gapSeconds: gapSeconds ?? this.gapSeconds,
      isInGap: isInGap ?? this.isInGap,
      adjustStep: adjustStep ?? this.adjustStep,
    );
  }
}
