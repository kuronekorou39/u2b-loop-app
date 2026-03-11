class LoopRegion {
  String id;
  String name;
  int pointAMs;
  int pointBMs;

  LoopRegion({
    required this.id,
    required this.name,
    this.pointAMs = 0,
    this.pointBMs = 0,
  });

  LoopRegion copyWith({String? name, int? pointAMs, int? pointBMs}) {
    return LoopRegion(
      id: id,
      name: name ?? this.name,
      pointAMs: pointAMs ?? this.pointAMs,
      pointBMs: pointBMs ?? this.pointBMs,
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
        pointAMs: map['pointAMs'] as int? ?? 0,
        pointBMs: map['pointBMs'] as int? ?? 0,
      );
}
