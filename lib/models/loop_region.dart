class LoopRegion {
  String id;
  String name;
  int? pointAMs;
  int? pointBMs;

  LoopRegion({
    required this.id,
    required this.name,
    this.pointAMs,
    this.pointBMs,
  });

  bool get hasA => pointAMs != null;
  bool get hasB => pointBMs != null;
  bool get hasPoints => hasA || hasB;

  LoopRegion copyWith({
    String? name,
    int? Function()? pointAMs,
    int? Function()? pointBMs,
  }) {
    return LoopRegion(
      id: id,
      name: name ?? this.name,
      pointAMs: pointAMs != null ? pointAMs() : this.pointAMs,
      pointBMs: pointBMs != null ? pointBMs() : this.pointBMs,
    );
  }

  Map<String, dynamic> toMap() => {
        'id': id,
        'name': name,
        'pointAMs': pointAMs,
        'pointBMs': pointBMs,
      };

  factory LoopRegion.fromMap(Map map) => LoopRegion(
        id: map['id'] as String,
        name: map['name'] as String,
        pointAMs: map['pointAMs'] as int?,
        pointBMs: map['pointBMs'] as int?,
      );
}
