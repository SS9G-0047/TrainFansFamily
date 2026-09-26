// 网络层：全部数据源的请求封装（12306 / rail.re / OpenCRHTracker /
//        黄河铁路网 / 普速配属两个 PHP 站）
part of '../../pages/train_search_page.dart';


// ───────────────────────────────────────────────────────────────────────────
// 12306 接口封装
// ───────────────────────────────────────────────────────────────────────────

class _RailwayApi {
  _RailwayApi._();
  static final _RailwayApi instance = _RailwayApi._();

  final http.Client _client = http.Client();
  final Map<String, String> _cookies = <String, String>{};
  bool _cookieLoading = false;

  List<_Station> _stations = <_Station>[];
  final Map<String, String> _codeToName = <String, String>{};
  final Map<String, String> _nameToCode = <String, String>{};
  bool _stationsLoaded = false;

  /// 大屏分页风格探测结果：探明一次后全局复用，避免每换一个站都重探一遍
  _BoardPageStyle? _boardStyleLocked;
  final Set<_BoardPageStyle> _boardStyleDead = <_BoardPageStyle>{};

  List<_Station> get stations => _stations;

  // ── 基础请求 ────────────────────────────────────────────────────────────

  Future<void> _ensureCookie() async {
    if (_cookies.isNotEmpty || _cookieLoading) return;
    _cookieLoading = true;
    try {
      final res = await _client
          .get(
            Uri.parse('$_kKyfwBase/otn/leftTicket/init'),
            headers: <String, String>{'User-Agent': _kUserAgent},
          )
          .timeout(const Duration(seconds: 15));
      final raw = res.headers['set-cookie'];
      if (raw != null) _mergeCookies(raw);
    } catch (_) {
      // 拿不到 cookie 也继续尝试，某些反代不需要
    }
    _cookieLoading = false;
  }

  void _mergeCookies(String raw) {
    for (final m in RegExp(r'([^=;\s]+)=([^;]*)').allMatches(raw)) {
      final k = m.group(1)?.trim() ?? '';
      final v = m.group(2)?.trim() ?? '';
      if (k.isEmpty) continue;
      final lk = k.toLowerCase();
      if (lk == 'path' ||
          lk == 'domain' ||
          lk == 'expires' ||
          lk == 'max-age' ||
          lk == 'secure' ||
          lk == 'httponly' ||
          lk == 'samesite') {
        continue;
      }
      _cookies[k] = v;
    }
  }

  String get _cookieHeader =>
      _cookies.entries.map((e) => '${e.key}=${e.value}').join('; ');

  Future<http.Response> _get(
    Uri uri, {
    String? referer,
    String? origin,
  }) async {
    await _ensureCookie();
    final headers = <String, String>{
      'User-Agent': _kUserAgent,
      'Accept': '*/*',
      'Accept-Language': 'zh-CN,zh;q=0.9',
      if (referer != null) 'Referer': referer,
      if (origin != null) 'Origin': origin,
      if (_cookies.isNotEmpty) 'Cookie': _cookieHeader,
    };
    final res = await _client
        .get(uri, headers: headers)
        .timeout(const Duration(seconds: 20));
    final raw = res.headers['set-cookie'];
    if (raw != null) _mergeCookies(raw);
    return res;
  }

  /// 第三方数据源专用：不领 12306 cookie、不带其凭证，避免多余请求
  Future<http.Response> _getPlain(
    Uri uri, {
    String? referer,
  }) {
    return _client
        .get(
          uri,
          headers: <String, String>{
            'User-Agent': _kUserAgent,
            'Accept': 'application/json, text/plain, */*',
            'Accept-Language': 'zh-CN,zh;q=0.9',
            if (referer != null) 'Referer': referer,
          },
        )
        .timeout(const Duration(seconds: 20));
  }

  /// 抓 HTML 页面专用：Accept 必须带 text/html。
  ///
  /// ⚠️ _getPlain 的 Accept 是 `application/json, text/plain, */*`，
  ///    拿它去要一个 PHP 生成的 HTML 页面，等于告诉服务端「我不接受 HTML」。
  ///    虽然 `*/*` 理论上兜底，但这两个站前面挂了 WAF/CDN 时，
  ///    内容协商会据此返回错误内容——实测表现就是「翻页参数不生效」：
  ///    请求第 2 页，拿回来的始终是首页那一份（页码标注永远是 1/N）。
  ///    这里单独开一个方法，只给两个普速站用，不动其他 JSON 接口。
  /// 极简 cookie 罐：http.Client 默认不保存 Cookie，
  /// 而这两个站是 PHP 站，分页结果有可能挂在 session 上。
  /// 不带上同一份 Cookie，服务端每次都当新会话，可能又把第 1 页发回来。

  void _absorbCookies(http.Response res) {
    final raw = res.headers['set-cookie'];
    if (raw == null || raw.isEmpty) return;
    for (final one in raw.split(RegExp(r',(?=[^;=]+=[^;]*)'))) {
      final kv = one.split(';').first.trim();
      final i = kv.indexOf('=');
      if (i <= 0) continue;
      _cookies[kv.substring(0, i).trim()] = kv.substring(i + 1).trim();
    }
  }

  Future<http.Response> _getHtml(
    Uri uri, {
    required String referer,
  }) async {
    final res = await _client
        .get(
          uri,
          headers: <String, String>{
            'User-Agent': _kUserAgent,
            'Accept':
                'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
            'Accept-Language': 'zh-CN,zh;q=0.9',
            'Referer': referer,
            'Cache-Control': 'no-cache, no-store, must-revalidate',
            'Pragma': 'no-cache',
            if (_cookies.isNotEmpty) 'Cookie': _cookieHeader,
          },
        )
        .timeout(const Duration(seconds: 20));
    _absorbCookies(res);
    return res;
  }

  // ── 车站字典 ────────────────────────────────────────────────────────────

  Future<List<_Station>> loadStations({bool force = false}) async {
    if (_stationsLoaded && !force) return _stations;

    final cached = force
        ? null
        : _JsonCache.instance.get('stationDict', _kTtlStationDict);
    if (cached is List<_Station>) {
      _stations = cached;
      for (final s in _stations) {
        _codeToName[s.code] = s.name;
        _nameToCode[s.name] = s.code;
      }
      _stationsLoaded = true;
      return _stations;
    }

    final res = await _get(
      Uri.parse('$_kKyfwBase/otn/resources/js/framework/station_name.js'),
      referer: '$_kKyfwBase/otn/leftTicket/init',
      origin: _kKyfwBase,
    );
    if (res.statusCode != 200) {
      throw Exception('车站字典加载失败：HTTP ${res.statusCode}');
    }
    final body = res.body;
    final m = RegExp(r"'([^']*)'", dotAll: true).firstMatch(body);
    final raw = m?.group(1) ?? body;

    final list = <_Station>[];
    for (final part in raw.split('@')) {
      final p = part.trim();
      if (p.isEmpty) continue;
      final f = p.split('|');
      if (f.length < 4) continue;
      final name = f[1].trim();
      final code = f[2].trim();
      if (name.isEmpty || code.isEmpty) continue;
      list.add(
        _Station(
          name: name,
          code: code,
          pinyin: f[3].trim(),
          initials: f[0].trim(),
        ),
      );
      _codeToName[code] = name;
      _nameToCode[name] = code;
    }
    if (list.isEmpty) throw Exception('车站字典为空，可能已被拦截');
    _JsonCache.instance.set('stationDict', list);
    _stations = list;
    _stationsLoaded = true;
    return list;
  }

  /// 站名 / 电报码 / 拼音 / 首字母 → 车站
  _Station? findStation(String keyword) {
    final q = keyword.trim();
    if (q.isEmpty) return null;
    final upper = q.toUpperCase();
    // 字典没加载成功时的兜底：允许直接填电报码
    if (_stations.isEmpty && RegExp(r'^[A-Z]{3}$').hasMatch(upper)) {
      return _Station(name: upper, code: upper, pinyin: '', initials: '');
    }
    for (final s in _stations) {
      if (s.name == q) return s;
    }
    for (final s in _stations) {
      if (s.code == upper) return s;
    }
    for (final s in _stations) {
      if (s.name.contains(q)) return s;
    }
    final lower = q.toLowerCase();
    for (final s in _stations) {
      if (s.initials.toLowerCase() == lower ||
          s.pinyin.toLowerCase() == lower) {
        return s;
      }
    }
    return null;
  }

  String nameOfCode(String code) => _codeToName[code] ?? code;

  /// 站名 → 电报码（经停表里补电报码用；字典未加载时返回空串）
  String codeOfName(String name) => _nameToCode[name.trim()] ?? '';

  // ── 1. 站-站查询 ────────────────────────────────────────────────────────

  Future<List<_TrainRun>> queryByStationPair(
    String fromCode,
    String toCode,
    DateTime date, {
    bool forceRefresh = false,
  }) async {
    final key = 'leftTicket|$fromCode|$toCode|${_fmtDash(date)}';
    final cached = forceRefresh
        ? null
        : _JsonCache.instance.get(key, _kTtlLeftTicket);
    if (cached is List<_TrainRun>) return cached;

    final uri = Uri.parse('$_kKyfwBase/otn/leftTicket/query').replace(
      queryParameters: <String, String>{
        'leftTicketDTO.train_date': _fmtDash(date),
        'leftTicketDTO.from_station': fromCode,
        'leftTicketDTO.to_station': toCode,
        'purpose_codes': 'ADULT',
      },
    );
    final res = await _get(
      uri,
      referer: '$_kKyfwBase/otn/leftTicket/init',
      origin: _kKyfwBase,
    );
    if (res.statusCode != 200) {
      throw Exception('查询失败：HTTP ${res.statusCode}');
    }
    final root = jsonDecode(res.body);
    if (root is! Map<String, dynamic>) throw Exception('返回格式异常');
    final data = root['data'];
    if (data is! Map<String, dynamic>) {
      final msg = root['messages'];
      throw Exception(
          (msg is List && msg.isNotEmpty) ? msg.first.toString() : '未查询到数据');
    }

    // map: {BJP: 北京南, SHH: 上海虹桥...}
    final map = <String, String>{};
    final rawMap = data['map'];
    if (rawMap is Map) {
      rawMap.forEach((k, v) => map[k.toString()] = v.toString());
    }
    final result = (data['result'] as List?)?.cast<String>() ?? <String>[];

    final runs = <_TrainRun>[];
    for (final row in result) {
      final f = row.split('|');
      if (f.length < 33) continue;
      final fCode = f[6];
      final tCode = f[7];
      final seats = <_Seat>[];
      for (final idx in _kSeatIndex.keys) {
        if (idx >= f.length) continue;
        final v = f[idx].trim();
        // 空串 / "--" 表示该车次不提供此席别
        if (v.isEmpty || v == '--') continue;
        seats.add(_Seat(_kSeatIndex[idx]!, v));
      }
      runs.add(
        _TrainRun(
          trainCode: f[3],
          trainNo: f[2],
          fromStation: map[fCode] ?? fCode,
          toStation: map[tCode] ?? tCode,
          departTime: f[8],
          arriveTime: f[9],
          duration: f[10],
          date: f[13],
          seats: seats,
        ),
      );
    }
    runs.sort((a, b) => a.departTime.compareTo(b.departTime));
    _JsonCache.instance.set(key, runs);
    return runs;
  }

  // ── 2. 车次查询 ─────────────────────────────────────────────────────────

  Future<_TrainDetail> queryByTrainNo(
    String trainCode,
    DateTime date, {
    bool forceRefresh = false,
  }) async {
    final key = 'trainInfo|$trainCode|${_fmtDash(date)}';
    final cached =
        forceRefresh ? null : _JsonCache.instance.get(key, _kTtlTrainInfo);
    if (cached is _TrainDetail) return cached;

    // 第一步：车次号 → 内部 train_no
    final sUri = Uri.parse('$_kSearchBase/search/v1/train/search').replace(
      queryParameters: <String, String>{
        'keyword': trainCode,
        'date': _fmtCompact(date),
      },
    );
    final sRes = await _get(sUri, referer: '$_kSearchBase/');
    if (sRes.statusCode != 200) {
      throw Exception('车次检索失败：HTTP ${sRes.statusCode}');
    }
    final sRoot = jsonDecode(sRes.body);
    final sList = (sRoot is Map<String, dynamic>)
        ? (sRoot['data'] as List?)?.cast<dynamic>() ?? <dynamic>[]
        : <dynamic>[];
    if (sList.isEmpty) {
      final err = (sRoot is Map) ? sRoot['errorMsg'] : null;
      throw Exception(err?.toString() ?? '未查询到该车次');
    }

    Map<String, dynamic>? hit;
    final target = trainCode.trim().toUpperCase();
    for (final e in sList) {
      if (e is Map) {
        final code = (e['station_train_code'] ?? '').toString().toUpperCase();
        if (code == target) {
          hit = e.cast<String, dynamic>();
          break;
        }
      }
    }
    hit ??= (sList.first as Map).cast<String, dynamic>();

    final realNo = (hit['train_no'] ?? '').toString();
    if (realNo.isEmpty) throw Exception('未获取到列车编号');
    final startName = (hit['from_station'] ?? hit['start_station'] ?? '')
        .toString();
    final endName =
        (hit['to_station'] ?? hit['end_station'] ?? '').toString();
    // 检索接口偶尔带车型字段（普速主要靠它）
    final searchModel = _pickTrainModel(hit);

    // 第二步：train_no → 经停时刻表
    final detail = await _fetchStops(
      trainNo: realNo,
      trainCode: trainCode,
      date: date,
      startStation: startName,
      endStation: endName,
      searchModel: searchModel,
    );
    // 第三步：补里程 / 担当车组 / 正晚点
    final full = await _enrichDetail(detail);
    _JsonCache.instance.set(key, full);
    return full;
  }

  /// 已知内部 train_no（站-站结果里自带），直接拉经停表，省一次检索请求
  Future<_TrainDetail> queryDetailByTrainNo({
    required String trainNo,
    required String trainCode,
    required DateTime date,
    bool forceRefresh = false,
  }) async {
    final key = 'trainInfo|$trainCode|${_fmtDash(date)}';
    final cached =
        forceRefresh ? null : _JsonCache.instance.get(key, _kTtlTrainInfo);
    if (cached is _TrainDetail) return cached;

    final detail = await _fetchStops(
      trainNo: trainNo,
      trainCode: trainCode,
      date: date,
    );
    final full = await _enrichDetail(detail);
    _JsonCache.instance.set(key, full);
    return full;
  }

  /// 纯网络请求：train_no → 经停时刻表
  Future<_TrainDetail> _fetchStops({
    required String trainNo,
    required String trainCode,
    required DateTime date,
    String startStation = '',
    String endStation = '',
    String searchModel = '',
  }) async {
    final uri = Uri.parse('$_kKyfwBase/otn/queryTrainInfo/query').replace(
      queryParameters: <String, String>{
        'leftTicketDTO.train_no': trainNo,
        'leftTicketDTO.train_date': _fmtDash(date),
        'rand_code': '',
      },
    );
    final res = await _get(
      uri,
      referer: '$_kKyfwBase/otn/queryTrainInfo/init',
      origin: _kKyfwBase,
    );
    if (res.statusCode != 200) {
      throw Exception('时刻表查询失败：HTTP ${res.statusCode}');
    }
    final root = jsonDecode(res.body);
    final dataList = (root is Map<String, dynamic>)
        ? ((root['data'] as Map?)?['data'] as List?)?.cast<dynamic>() ??
            <dynamic>[]
        : <dynamic>[];

    final stops = <_Stop>[];
    var i = 1;
    for (final e in dataList) {
      if (e is! Map) continue;
      final name = (e['station_name'] ?? '').toString();
      stops.add(
        _Stop(
          index: i++,
          stationName: name,
          // 电报码：接口带就直接用，否则用车站字典反查
          stationCode: _pickTelecode(e) ?? codeOfName(name),
          arriveTime: (e['arrive_time'] ?? '').toString(),
          departTime: (e['start_time'] ?? '').toString(),
          stopover: (e['stopover_time'] ?? '').toString(),
          // 少数版本的经停接口自带里程，能拿到就先用
          mileage: _toKm(
            (e['mileage'] ?? e['distance'] ?? e['licheng'])?.toString(),
          ),
        ),
      );
    }
    if (stops.isEmpty) {
      throw Exception('未获取到经停信息，可能已超出预售期或被风控拦截');
    }
    final hasMileage = stops.any((s) => s.mileage != null);
    return _TrainDetail(
      trainCode: trainCode,
      trainNo: trainNo,
      date: date,
      startStation:
          startStation.isNotEmpty ? startStation : stops.first.stationName,
      endStation: endStation.isNotEmpty ? endStation : stops.last.stationName,
      stops: stops,
      hasMileage: hasMileage,
      mileageSource: hasMileage ? '12306' : '',
      // 普速车型先填 12306 检索到的，动车会在 _enrichDetail 里换成车组号列表
      consists: searchModel.isEmpty
          ? const <_TrainConsist>[]
          : <_TrainConsist>[_TrainConsist(model: searchModel, source: '12306')],
    );
  }

  // ══ 车次增强数据：里程 / 担当车组 / 正晚点 ═══════════════════════════════

  /// 把里程、担当车组、正晚点并到时刻表上；任一项失败都不影响主流程
  Future<_TrainDetail> _enrichDetail(_TrainDetail d) async {
    final stops = d.stops;
    if (stops.isEmpty) return d;

    // ① 里程（黄河铁路网）
    var mileage = <String, double>{};
    var mileageSource = '';
    if (_kHuangheEnabled) {
      final m = await _mileageOf(d.trainCode);
      if (m.isNotEmpty) {
        mileage = m;
        mileageSource = '黄河铁路网';
      }
    }

    // ② 担当车组 / 车型（动车返回最近所有担当车组）
    final consists = await _consistsOf(d);

    // ③ 正晚点（仅当天）
    var lateMap = <String, _LateInfo>{};
    if (_kLateEnabled && _isSameDay(d.date, DateTime.now())) {
      lateMap = await _lateOf(d);
    }

    final newStops = <_Stop>[];
    for (final s in stops) {
      final km = mileage[_normStation(s.stationName)];
      newStops.add(
        s.copyWith(
          // 黄河铁路网拿不到时保留接口自带的里程
          mileage: km ?? s.mileage,
          late: lateMap[_normStation(s.stationName)],
        ),
      );
    }

    final hasMileage = mileage.isNotEmpty || d.hasMileage;
    return d.copyWith(
      stops: newStops,
      consists: consists.isEmpty ? d.consists : consists,
      mileageSource: mileage.isNotEmpty ? mileageSource : d.mileageSource,
      hasMileage: hasMileage,
    );
  }

  /// 里程：站名（归一化后）→ 累计公里
  Future<Map<String, double>> _mileageOf(String trainCode) async {
    final key = 'mileage|${trainCode.toUpperCase()}';
    final cached = _JsonCache.instance.get(key, _kTtlMileage);
    if (cached is Map) return Map<String, double>.from(cached);

    final res = await _mileageFromHuanghe(trainCode);
    if (res.isNotEmpty) _JsonCache.instance.set(key, res);
    return res;
  }

  /// 黄河铁路网里程页：JSON 优先，HTML 表格兜底
  Future<Map<String, double>> _mileageFromHuanghe(String trainCode) async {
    try {
      final path =
          _kHuangheMileagePath.replaceAll('{train}', Uri.encodeComponent(trainCode));
      final res = await _getPlain(
        Uri.parse('$_kHuangheBase$path'),
        referer: '$_kHuangheBase/',
      ).timeout(const Duration(seconds: 15));
      if (res.statusCode != 200) return <String, double>{};
      return _parseMileage(res.body);
    } catch (_) {
      return <String, double>{};
    }
  }

  /// 最近担当的动车组（动车走 rail.re /train/{车次}，返回近期全部车组），
  /// 普速只有车型时返回 12306 检索到的那一条；都没有则返回空列表。
  Future<List<_TrainConsist>> _consistsOf(_TrainDetail d) async {
    final key = 'consist|${d.trainCode.toUpperCase()}|${_fmtDash(d.date)}';
    final cached = _JsonCache.instance.get(key, _kTtlConsist);
    if (cached is List<_TrainConsist>) return cached;

    final out = <_TrainConsist>[];

    if (d.isEmu && _kRailReEnabled) {
      final recs = await _railReByTrain(d.trainCode);
      recs.sort((a, b) => b.date.compareTo(a.date)); // 最近担当排最前

      // 同一车组会被多天重复收录：按车组号去重，保留最近一次
      final seen = <String>{};
      final uniq = <_EmuRecord>[];
      for (final r in recs) {
        if (seen.add(r.emuNo)) uniq.add(r);
      }

      final top = uniq.take(_kConsistMax).toList();

      // 只给前几组补车型，避免把 OpenCRHTracker 配额打满
      final models = <String, String>{};
      if (_kCrhEnabled) {
        final jobs = top
            .take(_kConsistProfileMax)
            .map((r) => _emuProfileFromCrh(r.emuNo));
        final profiles = await Future.wait(jobs);
        for (var i = 0; i < profiles.length && i < top.length; i++) {
          final p = profiles[i];
          if (p != null && p.model.isNotEmpty) {
            models[top[i].emuNo] = p.model;
          }
        }
      }

      for (final r in top) {
        out.add(
          _TrainConsist(
            emuNo: r.emuNo,
            model: models[r.emuNo] ?? '',
            note: r.date.isEmpty ? 'rail.re' : '担当 ${r.date}',
            source: 'rail.re',
            date: r.date,
          ),
        );
      }
    }

    // 兜底：动车没查到车组 / 普速，用 12306 检索接口给的车型
    if (out.isEmpty) out.addAll(d.consists);

    if (out.isNotEmpty) _JsonCache.instance.set(key, out);
    return out;
  }

  /// rail.re：GET /train/{车次} → 该车次近期担当车组（供车次详情页用）
  Future<List<_EmuRecord>> _railReByTrain(String trainCode) async {
    final part = await _railRePartByTrain(trainCode);
    return part.records
        .where((r) => r.emuNo.isNotEmpty)
        .toList();
  }

  /// 正晚点：仅当天有效，按站并发（并发上限 _kLateConcurrency）
  /// 官方接口只覆盖过去 1 小时 ~ 未来 3 小时，站数多时只查当前时刻附近的站
  Future<Map<String, _LateInfo>> _lateOf(_TrainDetail d) async {
    final out = <String, _LateInfo>{};
    final names = _lateTargetStations(d);
    if (names.isEmpty) return out;
    for (var i = 0; i < names.length; i += _kLateConcurrency) {
      final end = (i + _kLateConcurrency) < names.length
          ? i + _kLateConcurrency
          : names.length;
      final batch = <Future<_LateInfo?>>[];
      for (var j = i; j < end; j++) {
        batch.add(_queryLate(d.trainCode, names[j], d.date));
      }
      final res = await Future.wait(batch);
      for (var k = 0; k < res.length; k++) {
        final info = res[k];
        if (info != null && info.known) {
          out[_normStation(names[i + k])] = info;
        }
      }
    }
    return out;
  }

  /// 需要查正晚点的站：站少就全查，站多就取当前时刻附近的 _kLateMaxStations 站
  List<String> _lateTargetStations(_TrainDetail d) {
    final all = d.stops.map((s) => s.stationName).toList();
    if (all.length <= _kLateMaxStations) return all;

    final now = DateTime.now();
    final nowMin = now.hour * 60 + now.minute;
    var idx = 0;
    var best = 1 << 30;
    for (var i = 0; i < d.stops.length; i++) {
      final s = d.stops[i];
      final min = _parseHm(
        s.departTime.isNotEmpty ? s.departTime : s.arriveTime,
      );
      if (min == null) continue;
      final diff = (min - nowMin).abs();
      if (diff < best) {
        best = diff;
        idx = i;
      }
    }
    final half = _kLateMaxStations ~/ 2;
    var start = (idx - half).clamp(0, d.stops.length).toInt();
    var end = (start + _kLateMaxStations).clamp(0, d.stops.length).toInt();
    start = (end - _kLateMaxStations).clamp(0, d.stops.length).toInt();
    return all.sublist(start, end);
  }

  /// 单站正晚点：12306 官方 zwdch（接口未公开，仅当天、前后 3 小时内有效）
  Future<_LateInfo?> _queryLate(
    String trainCode,
    String stationName,
    DateTime date,
  ) async {
    final key = 'late|${trainCode.toUpperCase()}|$stationName';
    final cached = _JsonCache.instance.get(key, _kTtlLate);
    if (cached is _LateInfo) return cached;

    try {
      final res = await _client
          .post(
            Uri.parse('$_kLateBase$_kLatePath'),
            headers: <String, String>{
              'User-Agent': _kUserAgent,
              'Accept': 'application/json, text/plain, */*',
              'Accept-Language': 'zh-CN,zh;q=0.9',
              'Referer': '$_kLateBase/init',
              'X-Requested-With': 'XMLHttpRequest',
            },
            body: <String, String>{
              'cz': stationName,
              'cc': trainCode,
              'cxlx': '0', // 0 到达 / 1 出发
              'rq': _fmtDash(date),
            },
          )
          .timeout(const Duration(seconds: 10));
      if (res.statusCode != 200) return null;
      final info = _parseLate(res.body);
      if (info != null) _JsonCache.instance.set(key, info);
      return info;
    } catch (_) {
      return null;
    }
  }

  // ── 4. 车站查询 ─────────────────────────────────────────────────────────

  Future<List<_StationTrain>> queryByStation(
    String stationCode,
    DateTime date, {
    bool forceRefresh = false,
  }) async {
    final key = 'station|$stationCode|${_fmtDash(date)}';
    final cached = forceRefresh
        ? null
        : _JsonCache.instance.get(key, _kTtlLeftTicket);
    if (cached is List<_StationTrain>) return cached;

    final uri = Uri.parse('$_kKyfwBase/otn/czxx/query').replace(
      queryParameters: <String, String>{
        'train_start_date': _fmtDash(date),
        'train_station_code': stationCode,
      },
    );
    final res = await _get(
      uri,
      referer: '$_kKyfwBase/otn/czxx/init',
      origin: _kKyfwBase,
    );
    if (res.statusCode != 200) {
      throw Exception('车站查询失败：HTTP ${res.statusCode}');
    }
    final root = jsonDecode(res.body);
    final dataList = (root is Map<String, dynamic>)
        ? ((root['data'] as Map?)?['data'] as List?)?.cast<dynamic>() ??
            <dynamic>[]
        : <dynamic>[];

    final out = <_StationTrain>[];
    for (final e in dataList) {
      if (e is! Map) continue;
      out.add(
        _StationTrain(
          trainCode: (e['station_train_code'] ?? e['train_code'] ?? '')
              .toString(),
          startStation: (e['start_station_name'] ?? e['from_station'] ?? '')
              .toString(),
          endStation:
              (e['end_station_name'] ?? e['to_station'] ?? '').toString(),
          arriveTime: (e['arrive_time'] ?? '').toString(),
          departTime: (e['start_time'] ?? e['depart_time'] ?? '').toString(),
        ),
      );
    }
    if (out.isEmpty) throw Exception('该站当日无查询数据，可能被拦截或超出预售期');
    _JsonCache.instance.set(key, out);
    return out;
  }

  // ══ 3. 车组号 / 车次查询（多源聚合）══════════════════════════════════════

  /// 关键词既可以是车组号（CR400AF-2031 / CRH2A-2001），也可以是车次（G83）。
  ///
  /// ⚠️ rail.re 两个方向的接口是不同的路径：
  ///   GET /emu/{车组号}  → 该车组近期担当的车次
  ///   GET /train/{车次}  → 该车次近期使用过的车组
  /// 之前只打 /emu/，所以输入车次必然「未收录」。这里先判定关键词类型，
  /// 再选对应路径；判不出来就两条都打。
  ///
  /// 车次路线拿到车组号后，会再并发补 OpenCRHTracker 的历史与配属，
  /// 因此查一次 G83 能看到「近期用过的所有车组 + 各自的配属档案」。
  Future<_EmuResult> queryEmu(
    String keyword, {
    bool forceRefresh = false,
  }) async {
    final q = keyword.trim();
    final key = 'emu|${q.toUpperCase()}';
    final cached = forceRefresh
        ? null
        : _JsonCache.instance.get(key, _kTtlEmu);
    if (cached is _EmuResult) return cached;

    if (!_kRailReEnabled && !_kCrhEnabled) {
      throw Exception('未启用任何车组号数据源，请检查文件顶部开关');
    }

    final kind = _classifyEmuKeyword(q);

    // ① 先按类型打 rail.re
    final parts = <_EmuPart>[];
    final errors = <String>[];

    Future<_EmuPart> railReBy(_EmuQueryKind k) {
      switch (k) {
        case _EmuQueryKind.train:
          return _railRePartByTrain(q);
        case _EmuQueryKind.emu:
          return _emuFromRailRe(q);
        case _EmuQueryKind.unknown:
          return _railReByKeyword(q); // 内部两条都试，取先成功的
      }
    }

    if (_kRailReEnabled) parts.add(await railReBy(kind));

    // ② 车组号路线：直接打 OpenCRHTracker
    if (_kCrhEnabled && kind == _EmuQueryKind.emu) {
      parts.add(await _emuFromCrh(q));
    }

    // ③ 车次路线：把 rail.re 给的车组号展开，补 OpenCRHTracker
    if (_kCrhEnabled && kind == _EmuQueryKind.train) {
      final emuNos = <String>[];
      final seen = <String>{};
      for (final p in parts) {
        for (final r in p.records) {
          if (r.emuNo.isNotEmpty && seen.add(r.emuNo)) emuNos.add(r.emuNo);
        }
      }
      final expand = emuNos.take(_kEmuTrainExpandMax).toList();
      if (expand.isNotEmpty) {
        final expanded = await Future.wait(expand.map(_emuFromCrh));
        parts.addAll(expanded);
      } else {
        // 一个车组号都没拿到，退一步按车组号再试一次（比如关键词其实是车组号）
        parts.add(await _emuFromCrh(q));
      }
    }

    if (_kCrhEnabled && kind == _EmuQueryKind.unknown) {
      parts.add(await _emuFromCrh(q));
    }

    // ③-b 兜底：按车组号一路查下来 rail.re 一条都没有，
    // 再按车次路径试一次（仅此一次，常态不会多打请求）
    if (_kRailReEnabled &&
        kind == _EmuQueryKind.emu &&
        !parts.any((p) => p.records.isNotEmpty)) {
      final asTrain = await _railRePartByTrain(q);
      if (asTrain.records.isNotEmpty) parts.add(asTrain);
    }

    // ④ 汇总
    final records = <_EmuRecord>[];
    final recSeen = <String>{};
    final profiles = <_EmuProfile>[];
    final proSeen = <String>{};

    final errCount = <String, int>{};
    for (final p in parts) {
      if (p.error != null && p.sourceName.isNotEmpty) {
        final msg = '${p.sourceName}：${p.error}';
        errCount[msg] = (errCount[msg] ?? 0) + 1;
      }
      for (final r in p.records) {
        final sig = '${r.emuNo}|${r.trainCode}|${r.date}';
        if (recSeen.add(sig)) records.add(r);
      }
      for (final f in p.profiles) {
        if (proSeen.add(f.emuNo)) profiles.add(f);
      }
    }

    // 多个车组号展开查询时，同一类错误会重复出现，合并成「×N」
    for (final e in errCount.entries) {
      errors.add(e.value > 1 ? '${e.key}（×${e.value}）' : e.key);
    }

    // 按日期倒序：最近担当排最前
    records.sort((a, b) => b.date.compareTo(a.date));

    // 车次查询时把配属档案按「该车组最近担当日期」排序，方便对照
    if (kind == _EmuQueryKind.train && profiles.length > 1) {
      final rank = <String, int>{};
      for (var i = 0; i < records.length; i++) {
        rank.putIfAbsent(records[i].emuNo, () => i);
      }
      profiles.sort(
        (a, b) => (rank[a.emuNo] ?? 999).compareTo(rank[b.emuNo] ?? 999),
      );
    }

    if (records.isEmpty && profiles.isEmpty) {
      throw Exception(
        errors.isEmpty ? '各数据源均未收录「$q」' : '各数据源均无结果\n${errors.join('\n')}',
      );
    }

    final result = _EmuResult(
      keyword: q,
      kind: kind,
      records: records,
      profiles: profiles,
      errors: errors,
    );
    _JsonCache.instance.set(key, result);
    return result;
  }

  /// 判定关键词类型：车次（G83 / 1234）还是车组号（CR400AF-2031 / CRH2A-2001）
  _EmuQueryKind _classifyEmuKeyword(String q) {
    final s = q.trim().toUpperCase();
    if (s.isEmpty) return _EmuQueryKind.unknown;

    // 车组号特征：CR / CRH 前缀，或「字母+数字-数字」结构
    if (s.startsWith('CR')) return _EmuQueryKind.emu;
    if (RegExp(r'^[A-Z]+\d*[A-Z]*-\d{2,5}$').hasMatch(s)) {
      return _EmuQueryKind.emu;
    }
    // 车次特征：单个字母字头 + 纯数字，或纯数字
    if (RegExp(r'^[GDCZTKYLSPAY]\d{1,5}$').hasMatch(s)) {
      return _EmuQueryKind.train;
    }
    if (RegExp(r'^\d{1,5}$').hasMatch(s)) return _EmuQueryKind.train;
    return _EmuQueryKind.unknown;
  }

  /// 判不出类型时：/train/ 与 /emu/ 都打一遍，取先有数据的那个
  Future<_EmuPart> _railReByKeyword(String q) async {
    final trainPart = await _railRePartByTrain(q);
    if (trainPart.records.isNotEmpty) return trainPart;
    final emuPart = await _emuFromRailRe(q);
    if (emuPart.records.isNotEmpty) return emuPart;
    return trainPart.error == null ? trainPart : emuPart;
  }

  /// ①-a rail.re：GET /emu/{车组号} → [ {emu_no, train_no, date}, ... ]
  ///     只接受车组号，传车次会「未收录」
  ///
  /// ⚠️ 车组号写法不统一：库里存的是 CR400BF5033（无横杠），
  /// 但用户习惯输入 CR400BF-5033。带错写法请求会返回空数组（不是报错），
  /// 之前只试一种写法，遇到写法不一致就静默「未收录」。
  /// 这里按 _emuNoVariants 依次尝试，命中即用。
  Future<_EmuPart> _emuFromRailRe(String q) async {
    const name = 'rail.re';
    final tried = <String>[];
    String? lastErr;

    for (final v in _emuNoVariants(q)) {
      if (tried.contains(v)) continue;
      tried.add(v);
      try {
        final res = await _getPlain(
          Uri.parse('$_kRailReBase/emu/${Uri.encodeComponent(v)}'),
          referer: 'https://rail.re/',
        ).timeout(const Duration(seconds: 15));

        if (res.statusCode == 404) {
          lastErr = 'HTTP 404';
          continue; // 换下一种写法再试
        }
        if (res.statusCode != 200) {
          return _EmuPart.error(name, 'HTTP ${res.statusCode}');
        }
        final root = jsonDecode(res.body);
        if (root is! List) return _EmuPart.error(name, '返回格式异常');

        final out = _parseRailReList(root, fallbackEmu: q);
        if (out.isNotEmpty) return _EmuPart(records: out, sourceName: name);
        lastErr = '空结果';
      } catch (e) {
        lastErr = _cleanErr(e);
      }
    }
    return _EmuPart.error(
      name,
      '未收录（已试 ${tried.join(' / ')}）${lastErr == null ? '' : '：$lastErr'}',
    );
  }

  /// ①-b rail.re：GET /train/{车次} → 该车次近期使用过的所有车组
  ///     与 /emu/ 是两个不同的路径，查车次必须走这条
  Future<_EmuPart> _railRePartByTrain(String trainCode) async {
    const name = 'rail.re';
    final code = trainCode.trim().toUpperCase();
    try {
      final res = await _getPlain(
        Uri.parse('$_kRailReBase/train/${Uri.encodeComponent(code)}'),
        referer: 'https://rail.re/',
      ).timeout(const Duration(seconds: 15));
      if (res.statusCode != 200) {
        return _EmuPart.error(name, 'HTTP ${res.statusCode}');
      }
      final root = jsonDecode(res.body);
      if (root is! List) return _EmuPart.error(name, '返回格式异常');

      final out = _parseRailReList(root, fallbackTrain: code);
      if (out.isEmpty) return _EmuPart.error(name, '未收录该车次');
      return _EmuPart(records: out, sourceName: name);
    } catch (e) {
      return _EmuPart.error(name, _cleanErr(e));
    }
  }

  /// rail.re 两种接口返回结构一致，共用解析：
  /// [ {emu_no, train_no, date}, ... ] → [_EmuRecord]
  ///
  /// 字段名做多候选：接口改版 / 不同分支的字段命名不一致时（emuNo / train /
  /// serviceDay …），只认死一个名字就会整页解析成空、显示「未收录」。
  List<_EmuRecord> _parseRailReList(
    List root, {
    String fallbackEmu = '',
    String fallbackTrain = '',
  }) {
    String pick(Map e, List<String> keys) {
      for (final k in keys) {
        final v = e[k];
        if (v == null) continue;
        final s = v.toString().trim();
        if (s.isNotEmpty && s != 'null') return s;
      }
      return '';
    }

    final out = <_EmuRecord>[];
    for (final e in root) {
      if (e is! Map) continue;
      final emuNo = _prettyEmuNo(
        pick(e, const <String>['emu_no', 'emuNo', 'emu', 'trainset', 'trainset_no']),
      );
      // train_no 可能是 "G83/G86" 这类复合写法，只取首段
      final trainNo = pick(
        e,
        const <String>['train_no', 'trainNo', 'train_code', 'trainCode', 'train'],
      ).split('/').first.trim();
      final date = pick(
        e,
        const <String>['date', 'run_date', 'service_day', 'serviceDay', 'day'],
      );
      final short = date.length >= 16 ? date.substring(0, 16) : date;
      final emu = emuNo.isNotEmpty ? emuNo : fallbackEmu;
      final train = trainNo.isNotEmpty ? trainNo : fallbackTrain;
      if (emu.isEmpty && train.isEmpty) continue;
      out.add(_EmuRecord(
        emuNo: emu,
        trainCode: train,
        date: short.length >= 10 ? short.substring(0, 10) : short,
        source: _EmuSource.railRe,
      ));
    }
    return out;
  }

  /// ② OpenCRHTracker：历史担当 + 配属档案
  ///    车组号同样按 _emuNoVariants 逐个试，避免写法不一致导致空结果
  Future<_EmuPart> _emuFromCrh(String q) async {
    const name = 'OpenCRHTracker';
    try {
      final records = <_EmuRecord>[];
      String? histErr;
      String? hitVariant;

      for (final v in _emuNoVariants(q)) {
        final hist = await _getPlain(
          Uri.parse('$_kCrhBase/history/emu/${Uri.encodeComponent(v)}')
              .replace(queryParameters: <String, String>{'limit': '60'}),
          referer: 'https://crh.lihugang.top/',
        ).timeout(const Duration(seconds: 15));

        final parsed = <_EmuRecord>[];

        if (hist.statusCode == 200) {
          final root = jsonDecode(hist.body);
          final data = (root is Map) ? root['data'] : null;
          final items = (data is Map) ? (data['items'] as List?) : null;
          if (items != null) {
            for (final e in items) {
              if (e is! Map) continue;
              final code = _joinTrainCode(e['trainCode']);
              final day = e['serviceDay'];
              final date = (day is int)
                  ? _fmtDash(_serviceDayToDate(day))
                  : '';
              parsed.add(_EmuRecord(
                emuNo: _prettyEmuNo(q),
                trainCode: code,
                date: date,
                source: _EmuSource.crhTracker,
              ));
            }
          }
          if (root is Map && root['ok'] == false) {
            histErr = (root['error'] ?? '查询失败').toString();
          }
        } else if (hist.statusCode == 404) {
          histErr = '未收录';
        } else if (hist.statusCode == 429) {
          histErr = '触发限频，稍后再试';
          break; // 继续试只是浪费配额
        } else {
          histErr = 'HTTP ${hist.statusCode}';
        }

        if (parsed.isNotEmpty) {
          records.addAll(parsed);
          hitVariant = v;
          histErr = null;
          break;
        }
      }

      // 配属档案失败不影响交路展示；同样按变体逐个试
      final profile = await _emuProfileFromCrhAny(hitVariant ?? q);

      if (records.isEmpty && profile == null) {
        return _EmuPart.error(name, histErr ?? '未收录');
      }
      return _EmuPart(
        records: records,
        profiles: profile == null
            ? const <_EmuProfile>[]
            : <_EmuProfile>[profile],
        sourceName: name,
      );
    } catch (e) {
      return _EmuPart.error(name, _cleanErr(e));
    }
  }

  /// 配属档案按车组号写法逐个尝试，任一命中即返回
  Future<_EmuProfile?> _emuProfileFromCrhAny(String q) async {
    for (final v in _emuNoVariants(q)) {
      final p = await _emuProfileFromCrh(v);
      if (p != null) return p;
    }
    return null;
  }

  /// 配属档案：GET /api/v2/allocation/emu/{q}
  Future<_EmuProfile?> _emuProfileFromCrh(String q) async {
    try {
      final res = await _getPlain(
        Uri.parse('$_kCrhBase/allocation/emu/${Uri.encodeComponent(q)}'),
        referer: 'https://crh.lihugang.top/',
      ).timeout(const Duration(seconds: 15));
      if (res.statusCode != 200) return null;
      final root = jsonDecode(res.body);
      final data = (root is Map) ? root['data'] : null;
      if (data is! Map) return null;

      final tags = <String>[];
      final rawTags = data['tags'];
      if (rawTags is List) {
        for (final t in rawTags) {
          final s = t.toString().trim();
          if (s.isNotEmpty) tags.add(s);
        }
      }

      final p = _EmuProfile(
        emuNo: _prettyEmuNo(q),
        model: (data['model'] ?? '').toString(),
        bureau: (data['bureau'] ?? '').toString(),
        trainDepot: (data['trainDepot'] ?? '').toString(),
        depot: (data['depot'] ?? '').toString(),
        manufacturer: (data['trainsetManufacturer'] ?? '').toString(),
        manufactureMonth: (data['manufactureMonth'] ?? '').toString(),
        designMaxSpeed: (data['designMaxSpeed'] is num)
            ? (data['designMaxSpeed'] as num).toInt()
            : null,
        tags: tags,
      );
      return p.isEmpty ? null : p;
    } catch (_) {
      return null;
    }
  }

  // ══ 4. 车站大屏 ═══════════════════════════════════════════════════════════

  /// 分页风格探测顺序：offset → page → cursor → 时间戳切片
  static const List<_BoardPageStyle> _styleOrder = <_BoardPageStyle>[
    _BoardPageStyle.offset,
    _BoardPageStyle.page,
    _BoardPageStyle.cursor,
    _BoardPageStyle.timestamp,
  ];

  /// 车站大屏：走 OpenCRHTracker 车站时刻表，失败则由上层回退 12306 原接口。
  ///
  /// 数据源单次上限 $_kBoardPageSize 条，大站必然截断，所以这里：
  ///   首屏自动翻满 _kBoardAutoPages 页，剩下的交给 loadMore 继续追加。
  Future<_BoardResult> queryStationBoard(
    String stationName, {
    bool forceRefresh = false,
    bool loadMore = false,
    int morePages = _kBoardMorePages,
    _BoardResult? previous,
  }) async {
    final name = stationName.trim();
    final key = 'board|$name';

    // ── 加载更多：在已有结果上继续翻页 ──
    if (loadMore) {
      final cached =
          forceRefresh ? null : _JsonCache.instance.get(key, _kTtlBoard);
      final base = previous ?? (cached is _BoardResult ? cached : null);
      if (base == null) throw Exception('请先查询「$name」的车站大屏');
      if (!base.hasMore) return base;

      final more = await _boardCollect(base, morePages);
      _JsonCache.instance.set(key, more);
      return more;
    }

    final cached =
        forceRefresh ? null : _JsonCache.instance.get(key, _kTtlBoard);
    if (cached is _BoardResult) return cached;

    if (!_kCrhEnabled) {
      throw Exception('大屏数据源已关闭（_kCrhEnabled = false）');
    }

    final first = await _boardFetchPage(name, null, _BoardPageStyle.none);
    if (first.items.isEmpty) throw Exception('该站当日无数据');

    var result = _BoardResult(
      station: name,
      items: first.items,
      notes: const <String>[],
      total: first.total,
      fetched: first.items.length,
      pages: 1,
      hasMore: first.hasMore ?? (first.items.length >= _kBoardPageSize),
      truncated: (first.total ?? first.items.length) > first.items.length,
      nextCursor: first.nextCursor,
    );

    if (result.hasMore) {
      result = await _boardCollect(result, _kBoardAutoPages - 1);
    }
    _JsonCache.instance.set(key, result);
    return result;
  }

  /// 从 [start] 继续翻页，最多再翻 [maxPages] 页。
  /// 探测失败 / 请求失败都不会丢掉已拿到的数据，只是把 hasMore 关掉。
  Future<_BoardResult> _boardCollect(_BoardResult start, int maxPages) async {
    var cur = start;
    if (maxPages <= 0) return cur;

    final seen = <String>{for (final e in cur.items) e.dedupKey};

    var loaded = 0; // 成功追加的页数
    var guard = 0; // 总请求次数（含探测失败），防止无效风格把预算耗光

    while (loaded < maxPages && cur.hasMore && guard < maxPages + 4) {
      guard++;
      var style = cur.style;
      final probing = style == _BoardPageStyle.none;

      if (probing) {
        final next = _nextBoardStyle(cur);
        if (next == null) {
          // 四种风格全试过都拿不到新东西：停在现有数据并如实标注
          return cur.copyWith(
            hasMore: false,
            truncated: true,
            notes: <String>[
              ...cur.notes,
              '数据源单次最多返回 $_kBoardPageSize 条且未支持分页，'
                  '仅取到前 ${cur.items.length} 趟；可切换时段查看其余车次',
            ],
          );
        }
        style = next;
      }

      _BoardPage page;
      try {
        page = await _boardFetchPage(cur.station, cur, style);
      } catch (e) {
        cur = cur.copyWith(
          tried: <_BoardPageStyle>[...cur.tried, style],
          notes: <String>[...cur.notes, '继续加载失败：${_cleanErr(e)}'],
        );
        if (!probing) return cur.copyWith(hasMore: false);
        _boardStyleDead.add(style);
        continue;
      }

      if (page.items.isEmpty) {
        cur = probing
            ? cur.copyWith(tried: <_BoardPageStyle>[...cur.tried, style])
            : cur.copyWith(hasMore: false);
        if (!probing) break;
        _boardStyleDead.add(style);
        continue;
      }

      final fresh = <_BoardItem>[];
      for (final it in page.items) {
        if (seen.add(it.dedupKey)) fresh.add(it);
      }

      if (fresh.isEmpty) {
        // 整页都与已有数据重复 → 服务端根本不认这个参数，换下一种
        cur = cur.copyWith(tried: <_BoardPageStyle>[...cur.tried, style]);
        if (!probing) return cur.copyWith(hasMore: false);
        _boardStyleDead.add(style);
        continue;
      }

      cur = cur.append(page, fresh).copyWith(style: style);
      _boardStyleLocked ??= style;
      loaded++;
      if (page.items.length < _kBoardPageSize) {
        cur = cur.copyWith(hasMore: false);
      }
    }
    return cur;
  }

  /// 下一个还没试过、且当前可用的分页风格
  _BoardPageStyle? _nextBoardStyle(_BoardResult cur) {
    // 同一数据源对所有车站行为一致：探明一次就全局复用，别每次换站都重试
    final locked = _boardStyleLocked;
    if (locked != null) {
      return _styleUsable(locked, cur) ? locked : null;
    }
    for (final s in _styleOrder) {
      if (cur.tried.contains(s) || _boardStyleDead.contains(s)) continue;
      if (!_styleUsable(s, cur)) continue;
      return s;
    }
    return null;
  }

  bool _styleUsable(_BoardPageStyle s, _BoardResult cur) {
    if (s == _BoardPageStyle.cursor) return cur.nextCursor.isNotEmpty;
    if (s == _BoardPageStyle.timestamp) return _lastBoardTs(cur) > 0;
    return true;
  }

  /// 时间戳切片用的游标：已取数据里最后一条的发车时间戳
  int _lastBoardTs(_BoardResult cur) {
    for (var i = cur.items.length - 1; i >= 0; i--) {
      final t = cur.items[i].departAt;
      if (t > 0) return t;
    }
    return 0;
  }

  /// OpenCRHTracker 车站时刻表：GET /api/v2/timetable/station/{站名}
  /// [style] 为 none 时表示首页，不带任何翻页参数。
  Future<_BoardPage> _boardFetchPage(
    String station,
    _BoardResult? cur,
    _BoardPageStyle style,
  ) async {
    final qp = <String, String>{'limit': '$_kBoardPageSize'};
    switch (style) {
      case _BoardPageStyle.none:
        break;
      case _BoardPageStyle.offset:
        qp[_kBoardOffsetKey] = '${cur?.fetched ?? 0}';
        break;
      case _BoardPageStyle.page:
        qp[_kBoardPageKey] = '${(cur?.pages ?? 0) + 1}';
        break;
      case _BoardPageStyle.cursor:
        qp[_kBoardCursorKey] = cur?.nextCursor ?? '';
        break;
      case _BoardPageStyle.timestamp:
        qp[_kBoardAfterTsKey] = cur == null ? '0' : '${_lastBoardTs(cur)}';
        break;
    }

    final res = await _getPlain(
      Uri.parse(
        '$_kCrhBase/timetable/station/${Uri.encodeComponent(station)}',
      ).replace(queryParameters: qp),
      referer: 'https://crh.lihugang.top/',
    ).timeout(const Duration(seconds: 15));

    if (res.statusCode == 404) throw Exception('未收录该站');
    if (res.statusCode == 429) throw Exception('触发限频，稍后再试');
    if (res.statusCode != 200) throw Exception('HTTP ${res.statusCode}');

    final root = jsonDecode(res.body);
    if (root is Map && root['ok'] == false) {
      throw Exception((root['error'] ?? '查询失败').toString());
    }
    final data = (root is Map) ? root['data'] : null;
    final items = (data is Map) ? (data['items'] as List?) : null;
    if (items == null || items.isEmpty) {
      return const _BoardPage(items: <_BoardItem>[]);
    }

    final out = <_BoardItem>[];
    for (final e in items) {
      if (e is! Map) continue;

      // allCodes 里取主车次，兼容跨天/复用车次号
      String code = '';
      final all = e['allCodes'];
      if (all is List && all.isNotEmpty) {
        code = _joinTrainCode(all.first);
      }
      if (code.isEmpty) code = _joinTrainCode(e['trainCode']);

      final models = <String>[];
      final rm = e['referenceModels'];
      if (rm is List) {
        for (final m in rm) {
          if (m is Map) {
            final s = (m['model'] ?? '').toString().trim();
            if (s.isNotEmpty) models.add(s);
          } else {
            final s = m.toString().trim();
            if (s.isNotEmpty) models.add(s);
          }
        }
      }

      final plat = e['platformNo'];
      final aTs = (e['arriveAt'] is int) ? e['arriveAt'] as int : 0;
      final dTs = (e['departAt'] is int) ? e['departAt'] as int : 0;
      out.add(_BoardItem(
        trainCode: code,
        startStation: (e['startStation'] ?? '').toString(),
        endStation: (e['endStation'] ?? '').toString(),
        arriveTime: _hhmm(aTs > 0 ? aTs : null),
        departTime: _hhmm(dTs > 0 ? dTs : null),
        platform: (plat is int && plat > 0) ? '$plat' : '',
        models: models,
        source: _EmuSource.crhTracker,
        arriveAt: aTs,
        departAt: dTs,
      ));
    }

    return _BoardPage(
      items: out,
      total: _readBoardTotal(root, data),
      hasMore: _readBoardHasMore(root, data),
      nextCursor: _readBoardCursor(root, data),
    );
  }

  /// 服务端自报总条数（字段名各家不一，多试几个；读不到返回 null）
  int? _readBoardTotal(dynamic root, dynamic data) {
    for (final k in <String>['total', 'totalCount', 'count', 'total_count']) {
      final v = (data is Map ? data[k] : null) ?? (root is Map ? root[k] : null);
      if (v is int) return v;
      if (v is num) return v.toInt();
      if (v is String) {
        final n = int.tryParse(v);
        if (n != null) return n;
      }
    }
    return null;
  }

  bool? _readBoardHasMore(dynamic root, dynamic data) {
    for (final k in <String>['hasMore', 'hasNext', 'has_next', 'more']) {
      final v = (data is Map ? data[k] : null) ?? (root is Map ? root[k] : null);
      if (v is bool) return v;
    }
    return null;
  }

  String _readBoardCursor(dynamic root, dynamic data) {
    for (final k in <String>['nextCursor', 'next_cursor', 'pageToken', 'next']) {
      final v = (data is Map ? data[k] : null) ?? (root is Map ? root[k] : null);
      if (v is String && v.isNotEmpty) return v;
      if (v is num) return v.toString();
    }
    return '';
  }

  // ══ 5. 普速配属查询（车厢 / 机车，两个完全独立的源）══════════════════════

  /// 车厢配属查询（cr400bf.passearch.info）
  ///
  /// 两个站都只有 HTML 表格，靠 _parseHtmlTable 硬解析。
  /// 按哪个维度（type）、查什么关键词，全部由用户在界面上选，代码不做猜测与回退。
  Future<_CarPart> queryCarStock(
    String keyword,
    String type, {
    bool forceRefresh = false,
    bool loadMore = false,
    _CarPart? previous,
  }) async {
    if (!_kPasCarEnabled) throw Exception('车厢数据源已关闭，检查文件顶部开关');
    final kw = keyword.trim();
    if (kw.isEmpty) throw Exception('请输入查询关键字');
    final key = _psCacheKey('car', kw, type);

    if (loadMore) {
      final base = previous ??
          (forceRefresh
              ? null
              : _JsonCache.instance.get(key, _kTtlPas) as _CarPart?);
      if (base == null) throw Exception('请先查询「$kw」');
      if (!base.hasMore) return base;
      final next =
          await _psCarMore(base, kw, base.type, _kPasMorePages);
      _JsonCache.instance.set(key, next);
      return next;
    }

    final cached =
        forceRefresh ? null : _JsonCache.instance.get(key, _kTtlPas);
    if (cached is _CarPart) return cached;

    final part = await _psFetchCars(kw, 1, type);
    if (part.items.isEmpty) {
      throw Exception(part.error ?? '没有查到「$kw」的车厢记录');
    }
    _JsonCache.instance.set(key, part);
    return part;
  }

  /// 机车配属查询（loco.passearch.info）
  Future<_LocoPart> queryLocoStock(
    String keyword,
    String type, {
    bool forceRefresh = false,
    bool loadMore = false,
    _LocoPart? previous,
  }) async {
    if (!_kPasLocoEnabled) throw Exception('机车数据源已关闭，检查文件顶部开关');
    final kw = keyword.trim();
    if (kw.isEmpty) throw Exception('请输入查询关键字');
    final key = _psCacheKey('loco', kw, type);

    if (loadMore) {
      final base = previous ??
          (forceRefresh
              ? null
              : _JsonCache.instance.get(key, _kTtlPas) as _LocoPart?);
      if (base == null) throw Exception('请先查询「$kw」');
      if (!base.hasMore) return base;
      final next =
          await _psLocoMore(base, kw, base.type, _kPasMorePages);
      _JsonCache.instance.set(key, next);
      return next;
    }

    final cached =
        forceRefresh ? null : _JsonCache.instance.get(key, _kTtlPas);
    if (cached is _LocoPart) return cached;

    final part = await _psFetchLocos(kw, 1, type);
    if (part.items.isEmpty) {
      throw Exception(part.error ?? '没有查到「$kw」的机车记录');
    }
    _JsonCache.instance.set(key, part);
    return part;
  }

  String _psCacheKey(String kind, String kw, String type) =>
      'ps|$kind|${kw.toUpperCase()}|$type';

  /// 车厢「加载更多」：与 _psLocoMore 同一套铁律——没拿到新数据就必须说话。
  Future<_CarPart> _psCarMore(
    _CarPart cur,
    String kw,
    String type,
    int maxPages,
  ) async {
    var next = cur;
    final seen = <String>{for (final e in cur.items) e.dedupKey};
    for (var i = 0; i < maxPages && next.hasMore; i++) {
      final wantPage = next.pages + 1;
      final tries = <String>[];
      final follow = _pasNextUrlLooksValid(next.nextUrl, next.pages)
          ? next.nextUrl
          : null;
      if (follow != null) tries.add(follow!);
      tries.add(_pasPageUri(_kPasCarBase, kw, type, wantPage).toString());
      tries.addAll(_pasPageUrlVariants(_kPasCarBase, kw, type, wantPage));

      final log = <String>[];
      var got = false;
      for (final url in tries) {
        final p = await _psFetchCars(kw, wantPage, type, nextUrl: url);
        final trial = <String>{...seen};
        final rf = <_CarStock>[];
        for (final it in p.items) {
          if (trial.add(it.dedupKey)) rf.add(it);
        }
        log.add('· ${_psShortUrl(url)}\n'
            '　${p.error ?? 'OK'}'
            '　标注第 ${p.serverPage ?? '-'} 页'
            '　${p.items.length} 条'
            '　首末 ${p.firstKey ?? '-'}→${p.lastKey ?? '-'}'
            '　新增 ${rf.length}');
        if (p.error == null && rf.isNotEmpty) {
          for (final it in rf) {
            seen.add(it.dedupKey);
          }
          next = next.copyWith(
            items: <_CarStock>[...next.items, ...rf],
            total: p.total ?? next.total,
            pages: wantPage,
            hasMore: _psHasMore(
                next.items.length + rf.length, p.total, p.items.length),
            clearMoreError: true,
            nextUrl: p.nextUrl,
            requestedUrl: p.requestedUrl,
            serverPage: p.serverPage,
            firstKey: p.firstKey,
            lastKey: p.lastKey,
          );
          got = true;
          break;
        }
      }
      if (!got) {
        return next.copyWith(
          hasMore: false,
          moreError: '第 $wantPage 页没拿到任何新数据（已加载 ${next.items.length} 条）。'
              '试了 ${tries.length} 种写法：\n${log.join('\n')}\n'
              '已加载首/末：${next.firstKey ?? '-'} → ${next.lastKey ?? '-'}',
        );
      }
    }
    return next;
  }

  Future<_LocoPart> _psLocoMore(
    _LocoPart cur,
    String kw,
    String type,
    int maxPages,
  ) async {
    var next = cur;
    final seen = <String>{for (final e in cur.items) e.dedupKey};
    for (var i = 0; i < maxPages && next.hasMore; i++) {
      final wantPage = next.pages + 1;
      final tries = <String>[];
      final follow = _pasNextUrlLooksValid(next.nextUrl, next.pages)
          ? next.nextUrl
          : null;
      if (follow != null) tries.add(follow!);
      tries.add(_pasPageUri(_kPasLocoBase, kw, type, wantPage).toString());
      tries.addAll(_pasPageUrlVariants(_kPasLocoBase, kw, type, wantPage));

      final log = <String>[];
      var got = false;
      for (final url in tries) {
        final p = await _psFetchLocos(kw, wantPage, type, nextUrl: url);
        // 用副本试算：失败的尝试不能污染 seen，否则会误判后来的真实新数据
        final trial = <String>{...seen};
        final rf = <_LocoItem>[];
        for (final it in p.items) {
          if (trial.add(it.dedupKey)) rf.add(it);
        }
        log.add('· ${_psShortUrl(url)}\n'
            '　${p.error ?? 'OK'}'
            '　标注第 ${p.serverPage ?? '-'} 页'
            '　${p.items.length} 条'
            '　首末 ${p.firstKey ?? '-'}→${p.lastKey ?? '-'}'
            '　新增 ${rf.length}');
        if (p.error == null && rf.isNotEmpty) {
          for (final it in rf) {
            seen.add(it.dedupKey);
          }
          next = next.copyWith(
            items: <_LocoItem>[...next.items, ...rf],
            total: p.total ?? next.total,
            pages: wantPage,
            hasMore: _psHasMore(
                next.items.length + rf.length, p.total, p.items.length),
            clearMoreError: true,
            nextUrl: p.nextUrl,
            requestedUrl: p.requestedUrl,
            serverPage: p.serverPage,
            firstKey: p.firstKey,
            lastKey: p.lastKey,
          );
          got = true;
          break;
        }
      }
      if (!got) {
        return next.copyWith(
          hasMore: false,
          moreError: '第 $wantPage 页没拿到任何新数据（已加载 ${next.items.length} 条）。'
              '试了 ${tries.length} 种写法：\n${log.join('\n')}\n'
              '已加载首/末：${next.firstKey ?? '-'} → ${next.lastKey ?? '-'}',
        );
      }
    }
    return next;
  }

  /// 车厢：GET {base}/index.php?type={type}&keyword={kw}&pagenum={page}
  ///
  /// [nextUrl] 非空时直接请求它（服务端上页给的「下一页」链接），
  /// 否则按 _pasPageUri 自己拼。翻页一律优先走 nextUrl。
  Future<_CarPart> _psFetchCars(
    String kw,
    int page,
    String type, {
    String? nextUrl,
  }) async {
    final uri = nextUrl != null && nextUrl.isNotEmpty
        ? Uri.parse(nextUrl)
        : _pasPageUri(_kPasCarBase, kw, type, page);
    String body;
    try {
      final res = await _getHtml(uri, referer: '$_kPasCarBase/')
          .timeout(const Duration(seconds: 20));
      if (res.statusCode != 200) {
        return _CarPart(type: type, error: 'HTTP ${res.statusCode}');
      }
      body = utf8.decode(res.bodyBytes, allowMalformed: true);
    } catch (e) {
      return _CarPart(type: type, error: _cleanErr(e));
    }
    if (body.contains('参数错误')) {
      return _CarPart(type: type, error: '参数错误（该维度不被支持）');
    }

    final total = _pasTotal(body);
    // 翻页自检：请求第 N 页，页面自己却标注在第 M 页 → 翻压根没生效
    final shown = _pasCurrentPage(body);
    if (shown != null && page > 1 && shown != page) {
      return _CarPart(
        type: type,
        total: total,
        error: '请求第 $page 页，但服务端返回的页面标注为第 $shown 页'
            '（pagenum 未生效，可能被打回首页或触发了风控）',
      );
    }
    // 先把服务端声明的条数传进解析器：它说有 N>0 条时放宽行过滤
    final table = _parseHtmlTable(body, declared: total);
    if (table.rows.isEmpty) {
      return _CarPart(
        type: type,
        total: total,
        error: _psEmptyReason(body, total, '车厢', type),
      );
    }

    final items = <_CarStock>[];
    for (final row in table.rows) {
      final s = _CarStock(
        model: _pasCell(row, table.header, const <String>['型号'], 0),
        carNo: _pasCell(row, table.header, const <String>['车号'], 1),
        depot: _pasCell(row, table.header, const <String>['现配属', '配属'], 2),
        capacity: _pasCell(row, table.header, const <String>['定员'], 3),
        trainCode: _pasCell(
          row,
          table.header,
          const <String>['运用车次', '运用车次(仅供参考)', '车次'],
          4,
        ),
        factory: _pasCell(row, table.header, const <String>['制造厂', '厂家'], 5),
        bogie: _pasCell(row, table.header, const <String>['转向架'], 6),
      );
      if (s.isEmpty) continue;
      items.add(s);
    }
    final kept = items.where((e) => !e.isEmpty).toList();
    return _CarPart(
      items: kept,
      total: total,
      pages: page,
      hasMore: _psHasMore(kept.length, total, table.rows.length),
      type: type,
      // 把服务端给的「下一页」原样存下来，下次翻页直接请求它
      nextUrl: _pasNextPageUrl(body, _kPasCarBase),
      requestedUrl: uri.toString(),
      serverPage: shown,
      firstKey: kept.isEmpty ? null : kept.first.dedupKey,
      lastKey: kept.isEmpty ? null : kept.last.dedupKey,
    );
  }

  /// 机车：GET {base}/index.php?type={type}&keyword={kw}&pagenum={page}
  ///
  /// [nextUrl] 同 _psFetchCars：优先请求服务端给的「下一页」链接。
  Future<_LocoPart> _psFetchLocos(
    String kw,
    int page,
    String type, {
    String? nextUrl,
  }) async {
    final uri = nextUrl != null && nextUrl.isNotEmpty
        ? Uri.parse(nextUrl)
        : _pasPageUri(_kPasLocoBase, kw, type, page);
    String body;
    try {
      final res = await _getHtml(uri, referer: '$_kPasLocoBase/')
          .timeout(const Duration(seconds: 20));
      if (res.statusCode != 200) {
        return _LocoPart(type: type, error: 'HTTP ${res.statusCode}');
      }
      body = utf8.decode(res.bodyBytes, allowMalformed: true);
    } catch (e) {
      return _LocoPart(type: type, error: _cleanErr(e));
    }
    if (body.contains('参数错误')) {
      return _LocoPart(type: type, error: '参数错误（该维度不被支持）');
    }

    final total = _pasTotal(body);
    final shown = _pasCurrentPage(body);
    if (shown != null && page > 1 && shown != page) {
      return _LocoPart(
        type: type,
        total: total,
        error: '请求第 $page 页，但服务端返回的页面标注为第 $shown 页'
            '（pagenum 未生效，可能被打回首页或触发了风控）',
      );
    }
    final table = _parseHtmlTable(body, declared: total);
    if (table.rows.isEmpty) {
      return _LocoPart(
        type: type,
        total: total,
        error: _psEmptyReason(body, total, '机车', type),
      );
    }

    final items = <_LocoItem>[];
    for (final row in table.rows) {
      // ⚠️ 别再赌列序了。机车页按型号查时实测是
      //    ['HXD3D', '0001', '沈局沈段', '大连', '']——型号和编号分列，
      //    第 0 列只有型号。车号/配属一律按内容特征从行里挑（见 _psLocoNoOf）。
      final locoNo = _psLocoNoOf(row, table.header);
      final depot = _psDepotOf(row, table.header);
      // 厂家：配属之外的第一个中文短格
      var factory = '';
      for (final t in row) {
        if (t.isEmpty || t == depot || t == locoNo) continue;
        if (RegExp(r'^[\u4e00-\u9fa5]{2,6}$').hasMatch(t)) {
          factory = t;
          break;
        }
      }
      items.add(
        _LocoItem(
          locoNo: locoNo,
          bureau: '',
          depot: depot,
          factory: factory,
          note: '',
          // 整行指纹 → 去重主力，避免 50 条同型号被误判成同一条
          rawKey: row.join('|'),
        ),
      );
    }
    final kept = items.where((e) => !e.isEmpty).toList();
    return _LocoPart(
      items: kept,
      total: total,
      pages: page,
      hasMore: _psHasMore(kept.length, total, table.rows.length),
      type: type,
      nextUrl: _pasNextPageUrl(body, _kPasLocoBase),
      requestedUrl: uri.toString(),
      serverPage: shown,
      firstKey: kept.isEmpty ? null : kept.first.dedupKey,
      lastKey: kept.isEmpty ? null : kept.last.dedupKey,
    );
  }

  /// 还能不能翻：优先看服务端给的总数，读不到就看本页是否拿满
  bool _psHasMore(int loaded, int? total, int rowsThisPage) {
    if (total != null) return loaded < total;
    return rowsThisPage >= _kPasPageSize;
  }
}
