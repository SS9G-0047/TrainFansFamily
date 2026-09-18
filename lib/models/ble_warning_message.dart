class BleWarningMessage {
  final String signalStrength;
  final String trainNo;
  final String direction;
  final String line;
  final String locomotive;
  final String mileage;
  final String speed;
  final String latitude;
  final String longitude;
  final DateTime receivedAt;

  const BleWarningMessage({
    required this.signalStrength,
    required this.trainNo,
    required this.direction,
    required this.line,
    required this.locomotive,
    required this.mileage,
    required this.speed,
    this.latitude = '--',
    this.longitude = '--',
    required this.receivedAt,
  });

  static BleWarningMessage? tryParse(String source) {
    var payload = source.trim();
    if (payload.isEmpty || payload == '#') return null;

    if (payload.startsWith('!')) {
      payload = payload.substring(1);
    } else if (payload.startsWith('W|')) {
      payload = payload.substring(2).replaceAll('|', ',');
    } else {
      return null;
    }

    final fields = payload.split(',').map((item) => item.trim()).toList();
    if (fields.length != 7 && fields.length != 9) return null;

    return BleWarningMessage(
      signalStrength: fields[0].isEmpty ? '--' : fields[0],
      trainNo: _safe(fields, 1),
      direction: _safe(fields, 2),
      line: _safe(fields, 3),
      locomotive: _safe(fields, 4),
      mileage: _safe(fields, 5),
      speed: _safe(fields, 6),
      longitude: _safe(fields, 7),
      latitude: _safe(fields, 8),
      receivedAt: DateTime.now(),
    );
  }

  static String _safe(List<String> fields, int index) {
    if (index >= fields.length || fields[index].isEmpty) return '--';
    return fields[index];
  }

  List<String> toWarningTextList() {
    return [
      '信号强度：$signalStrength',
      '车次：$trainNo',
      '上下行：$direction',
      '线路：$line',
      '机车：$locomotive',
      '里程：$mileage',
      '速度：$speed',
      '纬度：$latitude',
      '经度：$longitude',
    ];
  }
}
