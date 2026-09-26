// 解析与工具：HTML 表格硬解析、文本解析、时间/里程/正晚点格式化
part of '../../pages/train_search_page.dart';


/// 「共有符合条件的记录 1360 条」
int? _pasTotal(String body) {
  final m = RegExp(r'共有符合条件的记录\s*(\d+)\s*条').firstMatch(body);
  if (m != null) return int.tryParse(m.group(1) ?? '');
  return null;
}

/// 分页栏里的当前页码：形如「首页 上一页 下一页 尾页 (2/15)」→ 2
///
/// 用来判断服务端到底有没有生效 pagenum：请求第 2 页却回来说自己在第 1 页，
/// 那就是翻页没生效（会被风控 / 参数名变了 / 服务端把请求打回首页），
/// 这时候直接把话说清楚，别让用户在「加载更多」上反复点。
int? _pasCurrentPage(String body) {
  final m = RegExp(r'\((\d+)\s*/\s*(\d+)\)').firstMatch(body);
  if (m == null) return null;
  return int.tryParse(m.group(1) ?? '');
}

/// 从页面里抠出「下一页」那个 <a> 的真实 href。
///
/// 真实页面长这样（车厢站实测）：
///   <a href="https://cr400bf.passearch.info/index.php?type=model&amp;keyword=YW25G&amp;pagenum=2">下一页</a>
///
/// ⚠️ 为什么要用它，而不是自己拼 URL：
///    自己拼 = 赌参数名（pagenum）+ 赌参数顺序 + 赌关键字的编码方式。
///    三样里错一样，服务端就当没传 pagenum，静默返回第 1 页——
///    界面上的表现正是「翻页参数不生效 / 点了加载更多没变化」。
///    服务端自己吐出来的链接不存在这些问题，所以翻下一页时优先请求它。
///
/// [base] 用来把相对路径补成绝对 URL。
String? _pasNextPageUrl(String body, String base) {
  final m = RegExp(
          r'<a[^>]*href=["' r"']([^" r"']+)[" r"'][^>]*>\s*下一页\s*</a>",
          caseSensitive: false)
      .firstMatch(body);
  var href = m?.group(1);
  if (href == null || href.isEmpty) return null;

  // HTML 实体：&amp; 必须还原成 &，否则 pagenum 会被当成 type 值的一部分，
  // 解析出来是「?type=model&amp;keyword=YW25G&amp;pagenum=2」→ 服务端读不到 pagenum
  href = href
      .replaceAll('&amp;', '&')
      .replaceAll('&quot;', '"')
      .replaceAll('&#39;', "'")
      .trim();
  if (href.startsWith('//')) return 'https:$href';
  if (href.startsWith('http://') || href.startsWith('https://')) return href;
  if (href.startsWith('/')) return '$base$href';
  return '$base/$href';
}

/// 自己拼翻页 URL（拿不到「下一页」链接时的回退）。
///
/// 参数顺序按服务端自己生成的链接来：type → keyword → pagenum。
/// 顺序本身 PHP 无所谓，但保持和站内链接逐字一致，能排除
/// 「WAF/CDN 按 URL 字面量做缓存键、拼法不同就命中不了」这类玄学问题。
Uri _pasPageUri(String base, String kw, String type, int page) {
  final q = <String>[
    'type=${Uri.encodeQueryComponent(type)}',
    'keyword=${Uri.encodeQueryComponent(kw)}',
    'pagenum=$page',
  ].join('&');
  return Uri.parse('$base/index.php?$q');
}

/// 翻页「打滑」时的备选 URL 写法。
///
/// 已经确认服务端分页本身是对的（实测机车 HXD3D：
/// pagenum=1 → HXD3D0001…0050，pagenum=2 → HXD3D0051…0100，零重叠）。
/// 所以一旦出现「新页内容全部重复」，只可能是**这一侧**拿到的响应不对：
///   · 中间有缓存/CDN 只按 path 做键，忽略了 query → 加时间戳 _= 穿透；
///   · 参数顺序不同导致命中不了缓存键 → 换回 keyword 在前的旧顺序；
///   · 站点改了参数名 → 试 page=。
/// 逐个试，谁先拿到新数据就用谁。
List<String> _pasPageUrlVariants(
  String base,
  String kw,
  String type,
  int page,
) {
  final ts = DateTime.now().millisecondsSinceEpoch;
  final t = Uri.encodeQueryComponent(type);
  final k = Uri.encodeQueryComponent(kw);
  return <String>[
    '$base/index.php?type=$t&keyword=$k&pagenum=$page&_=$ts', // 标准 + 穿透
    '$base/index.php?keyword=$k&type=$t&pagenum=$page&_=$ts', // 旧顺序 + 穿透
    '$base/index.php?type=$t&keyword=$k&page=$page&_=$ts', // 参数名换成 page
  ];
}

/// 机车车号。
///
/// ⚠️ 按型号查（type=model）时，实测表格把「型号」和「编号」拆成了两格：
///    行内容形如 ['HXD3D', '0001', '沈局沈段', '大连', '']，
///    单看第 0 列只有型号 HXD3D——既当不了车号，也当不了去重键。
///    所以按下面顺序挑，能拼就拼：
///      ① 单格已是完整车号（HXD3D0001）→ 直接用
///      ② 字母格 + 紧邻的纯数字格（HXD3D | 0001）→ 拼接
///      ③ 表头里真有「车号」列 → 用它
///      ④ 都没有 → 第一个非空格
String _psLocoNoOf(List<String> row, Map<String, int> header) {
  for (final t in row) {
    if (RegExp(r'^[A-Za-z][A-Za-z0-9\-]*\d{3,}$').hasMatch(t)) return t;
  }
  for (var i = 0; i + 1 < row.length; i++) {
    final a = row[i];
    final b = row[i + 1];
    if (RegExp(r'^[A-Za-z][A-Za-z0-9\-]*$').hasMatch(a) &&
        RegExp(r'^\d{2,}$').hasMatch(b)) {
      return '$a$b';
    }
  }
  final idx = header['车号'];
  if (idx != null && idx < row.length && row[idx].isNotEmpty) return row[idx];
  for (final t in row) {
    if (t.isNotEmpty) return t;
  }
  return '';
}

/// 配属（局/段）：从行里挑含「局」或「段」的那一格，不赌列序。
///
/// 列定位一旦错位（机车页合并格、缺列很常见），写死 index 会显示成车号或厂家，
/// 按内容特征挑更稳。
String _psDepotOf(List<String> row, Map<String, int> header) {
  // ① 按内容特征挑，放在**最前面**。
  //    ⚠️ 实测踩坑：loco 站表头声明 4 列（车号|配属机务段|厂家|备注），
  //    但按型号查时数据行是 5 格（HXD3D|0001|沈局沈段|空|空）——
  //    列数对不上，表头索引 1 取到的是编号「0001」而不是配属。
  //    配属一定含「局」或「段」，而车号/编号不会，按内容挑零歧义。
  for (final t in row) {
    if (t.isEmpty) continue;
    if (t.contains('局') || t.contains('段')) return t;
  }
  // ② 表头索引兜底，且必须校验取到的格子确实像配属，否则宁可留空
  final idx = header['配属机务段'] ?? header['配属'];
  if (idx != null && idx < row.length) {
    final v = row[idx];
    if (v.isNotEmpty && (v.contains('局') || v.contains('段'))) return v;
  }
  return '';
}

/// 把 URL 缩成能一眼看懂的样子：去掉域名，只留 query
/// （诊断信息里要并列 4~5 个候选 URL，全打出来太占地方）
String _psShortUrl(String url) {
  final i = url.indexOf('?');
  if (i < 0) return url;
  final q = url.substring(i + 1);
  return q.length > 90 ? '${q.substring(0, 90)}…' : q;
}

/// 校验：确认「下一页」链接里的页码确实比当前页大。
/// 服务端偶尔会把「下一页」也指向当前页（比如末页），这里提前识别出来。
bool _pasNextUrlLooksValid(String? nextUrl, int currentPage) {
  if (nextUrl == null) return false;
  final m = RegExp(r'[?&]pagenum=(\d+)').firstMatch(nextUrl);
  if (m == null) return false;
  final p = int.tryParse(m.group(1) ?? '');
  if (p == null) return false;
  return p > currentPage;
}

/// 查不到东西时，把原因说清楚——别只丢一句「无记录」
///
/// 这两个站在「查不到」和「不支持」上的表现完全不同，混在一起根本没法排查：
///   · 参数不对  → 页面出现「参数错误」
///   · 参数对但没数据 → 返回首页模板，没有「共有符合条件的记录」这行
///   · 真有数据但解析不出来 → 有「共有符合条件的记录 N 条」却没解析到行
/// 另外机车站按型号查时输完整车号（HXD3D0001）会静默返回 0 条，
/// 这里单独点出来，否则用户只会看到「无记录」干瞪眼。
String _psEmptyReason(String body, int? declared, String what, String type) {
  final trCount = RegExp(r'<tr', caseSensitive: false).allMatches(body).length;

  if (declared == 0) {
    return '服务端返回 0 条：换个关键字或换个维度试试。${_psKeywordTip(what, type)}';
  }
  if (declared != null) {
    return '页面写着「共有 $declared 条」，但表格没解析出数据行'
        '（共扫到 $trCount 个 <tr>）。\n'
        '请确认实际 URL：…/index.php?keyword=…&type=$type&pagenum=1\n'
        '前几行实际内容：\n${_psTableDebug(body)}';
  }
  final noResult = body.contains('共有符合条件的记录');
  if (noResult) {
    return '页面有结果统计但解析为空（共扫到 $trCount 个 <tr>）。\n'
        '前几行实际内容：\n${_psTableDebug(body)}';
  }
  // 服务端既没报错也没给结果统计：通常是关键字写法不对，页面被静默打回
  // 首页模板（机车 number 维度输完整车号 HXD3D0047 实测就是这个表现），
  // 光说「暂无数据」等于让用户干瞪眼，把正确写法一起给出来。
  final tip = _psKeywordTip(what, type);
  return tip.isEmpty ? '「$what」暂无数据' : '「$what」暂无数据。$tip';
}

/// 机车各维度的输入注意点，显示在输入框下方（随所选维度变化）。
///
/// ⚠️ 型号和车号两个维度栽在同一个地方：用户会本能地输完整车号 HXD3D0047。
///    实测两者都返回 0 条——但正确输入各不相同（型号要 HXD3D，车号要 0047），
///    所以提示必须跟着维度变，写死一句「别输完整车号」解决不了问题。
String _psLocoTypeNote(String type) {
  switch (type) {
    case 'model':
      return '　⚠️ 输型号本身（HXD3D），输完整车号 HXD3D0047 会返回 0 条';
    case 'number':
      return '　⚠️ 输车号里的编号（0047），输完整车号 HXD3D0047 会返回 0 条';
    default:
      return '';
  }
}

/// 关键字写法的提示：按「站 + 维度」给，只写实测踩过的坑。
///
/// ⚠️ 机车站两个维度栽在同一个地方——用户会本能地输完整车号：
///   · model（型号）：要输 HXD3D，输 HXD3D0047 → 0 条
///   · number（车号）：要输 0047，输 HXD3D0047 → 实测也是 0 条
String _psKeywordTip(String what, String type) {
  if (what != '机车') return '';
  if (type == 'model') {
    return '按型号查请输型号本身（HXD3D），不要输完整车号 HXD3D0047';
  }
  if (type == 'number') {
    return '按车号查请输编号部分（0047），不要输完整车号 HXD3D0047';
  }
  return '';
}

/// 按表头名取单元格；表头识别失败时退回列序 fallback
String _pasCell(
  List<String> row,
  Map<String, int> header,
  List<String> names,
  int fallback,
) {
  // ① 精确匹配
  for (final n in names) {
    final idx = header[n];
    if (idx != null && idx < row.length) return row[idx];
  }
  // ② 包含匹配：机车页实测表头是「配属机务段」这种合并格，
  //    精确找「配属」「机务段」都找不到，只能靠包含关系认出来。
  for (final n in names) {
    for (final e in header.entries) {
      if (e.key.contains(n) || n.contains(e.key)) {
        if (e.value < row.length) return row[e.value];
      }
    }
  }
  return fallback < row.length ? row[fallback] : '';
}

/// 非数据行的特征词。
///
/// ⚠️ 这两个站的表格之外还有一堆行会被 <tr> 扫进来：页脚的
/// 「友情链接: 日本列岛列车大行进 2022 火车wiki在线客里表」、
/// 分页栏「首页 上一页 下一页 尾页 (2/15)」、统计行「共有符合条件的记录 N 条」、
/// 顶部导航「查询方式: 车号 型号 …」、版本行「p@ssearch 3.5 Build 37276」。
///
/// ⚠️ 注意：光靠这张词表挡不住页脚。页脚那个「友情链接」是独立的 <table>，
///    「友情链接」四个字在 <p> 里（不在任何 <tr> 内），所以它的 **行文本**
///    是「日本列岛列车大行进 2022 / 火车wiki在线客里表」，压根不含 junk 词。
///    真正的解法是 _parseHtmlTable 里按 <table> 块隔离（页脚块根本不参与解析），
///    下面这两个新词 + _isLinkOnlyRow 只是万一有漏网之鱼时的二次保险。
bool _isPaSSearchJunkRow(String t) {
  const junk = <String>[
    '共有符合条件的记录',
    '首页',
    '尾页',
    '上一页',
    '下一页',
    '友情链接',
    '查询方式',
    '查询关键字',
    'Contact us',
    'Build',
    '主页面',
    '动车组配属查询',
    '数据反馈',
    '备用站',
    '返回',
    '提交',
    // ↓ 页脚友情链接 / 统计脚本的实际文案（车厢站实测）
    '日本列岛',
    '火车wiki',
    '在线客里表',
    'bilibili',
    'kelibiao',
    'gdrailfans',
    '51.la',
  ];
  for (final k in junk) {
    if (t.contains(k)) return true;
  }
  return false;
}

/// 整行都是外链：页脚友情链接那张表的典型形态
/// （「日本列岛列车大行进 2022」+「火车wiki在线客里表」两格都是超链接文字）。
/// 数据行不会长这样——车号/型号/配属段里不会出现网址。
bool _isLinkOnlyRow(List<String> cells) {
  final filled = cells.where((t) => t.isNotEmpty).toList();
  if (filled.isEmpty) return false;
  for (final t in filled) {
    final isLink = t.startsWith('http') ||
        t.contains('.com') ||
        t.contains('.net') ||
        t.contains('.cn/') ||
        t.contains('.org');
    if (!isLink) return false;
  }
  return true;
}

/// 数据行至少要有一个「像车号/型号」的单元格：字母开头、混着数字
/// （YW25T / 683046 / HXD3D0001 / RZ25B110389 都符合，纯中文的页脚不符合）
bool _looksLikeStockRow(List<String> cells) {
  for (final t in cells) {
    if (RegExp(r'^[A-Za-z]{1,}[A-Za-z0-9\-]*\d{2,}').hasMatch(t)) return true;
    if (RegExp(r'^\d{4,}').hasMatch(t)) return true; // 纯数字车号（6 位）
  }
  return false;
}

/// 极简 HTML 表格解析：表头列名 → 列索引 + 数据行（保留空单元格）
class _HtmlTable {
  final Map<String, int> header;
  final List<List<String>> rows;

  const _HtmlTable({this.header = const <String, int>{}, this.rows = const []});
}

/// 一行是否够格当数据行。
/// [strict] = false 时放宽「必须长得像车号」这道过滤（只留 junk 过滤）。
///
/// ⚠️ 为什么要放宽：机车页实测表头是 4 格「车号 | 配属机务段 | 厂家 | 备注」，
///    数据行形如「HXD3D0001 | 沈局沈段 | 大连 | …」，
///    一旦车号列的写法超出 _looksLikeStockRow 的正则（比如带空格、纯中文局段在前），
///    整页 200 多条会被一刀切光，页面却仍写着「共有 210 条」。
///    所以服务端声明了 N>0 条时，宁可信它，放宽过滤。
/// 把 HTML 里的表格切成「行 → 单元格」。
///
/// ⚠️ 关键：这两个站的数据行**没有写 `</tr>`**（实测页面 `<tr` 出现 53 次、
///    带 `</tr>` 的只有 3 个）。浏览器容错能正常渲染，但
///    `<tr[^>]*>(.*?)</tr>` 这种成对正则只会匹配到 3 行 —— 结果就是
///    「页面写着 210 条，却解析出 0 行」，而且报错信息看着像页面结构变了。
///
/// 所以这里改成**按位置切分**，完全不依赖闭合标签：
///   1. 扫出所有 `<tr`、`<td`/`<th`、`</table` 的起始下标；
///   2. 第 i 行的区间 = [第 i 个 `<tr`, 第 i+1 个 `<tr`)，遇到 `</table` 提前截断；
///   3. 落在该区间内的 `<td`/`<th` 就是这一行的单元格，
///      每个单元格的文本 = 从它的 `<td` 到下一个 `<td`（或区间末尾），去标签。
/// 这样闭合与否都能正确解析，列也不会错位。
///
/// 注意 `<t[dh](?![a-z])` 的负向预查：否则 `<thead>` 会被当成 `<th`。
/// [start] / [end]：只解析落在这个区间内的行（用来把某张 <table> 单独拎出来）。
/// 默认全文，行为与旧版一致。
List<List<String>> _htmlRows(String body, {int start = 0, int? end}) {
  final hi = end ?? body.length;
  final rowStarts = <int>[];
  final cellStarts = <int>[];
  final tableEnds = <int>[];
  for (final m in RegExp(r'<tr(?![a-z])', caseSensitive: false)
      .allMatches(body)) {
    if (m.start >= start && m.start < hi) rowStarts.add(m.start);
  }
  for (final m in RegExp(r'<t[dh](?![a-z])', caseSensitive: false)
      .allMatches(body)) {
    cellStarts.add(m.start);
  }
  for (final m in RegExp(r'</table', caseSensitive: false).allMatches(body)) {
    tableEnds.add(m.start);
  }

  final out = <List<String>>[];
  for (var i = 0; i < rowStarts.length; i++) {
    final rs = rowStarts[i];
    var end = i + 1 < rowStarts.length ? rowStarts[i + 1] : body.length;
    for (final te in tableEnds) {
      if (te > rs && te < end) {
        end = te;
        break;
      }
    }
    final mine = <int>[];
    for (final cs in cellStarts) {
      if (cs >= rs && cs < end) mine.add(cs);
    }
    if (mine.isEmpty) continue;
    final cells = <String>[];
    for (var j = 0; j < mine.length; j++) {
      final ce = j + 1 < mine.length ? mine[j + 1] : end;
      cells.add(_htmlText(body.substring(mine[j], ce > body.length ? body.length : ce)));
    }
    out.add(cells);
  }
  return out;
}

/// 一个 `<table> … </table>` 的字节区间
class _HtmlSpan {
  final int start;
  final int end;
  const _HtmlSpan(this.start, this.end);
}

/// 把页面按 <table> 切成若干块。
///
/// ⚠️ 这是「页脚混进结果」的根治手段：这两个站的页面上有 3 张表——
///    ① 顶部查询表单、② 数据结果表、③ 页脚友情链接表。
///    旧版 _htmlRows 是**整页**扫 <tr>，三张表的行混在一个列表里，
///    于是页脚那条「日本列岛列车大行进 2022 / 火车wiki在线客里表」
///    也会被当成一行数据渲染出来（而且它不含任何 junk 关键词，词表拦不住）。
///    现在只认「含表头的那一张表」，其余表里的行永远不进结果。
///
/// 嵌套表（table 里套 table）直接并入外层，不单独成块。
List<_HtmlSpan> _htmlTableSpans(String body) {
  final starts = <int>[];
  for (final m in RegExp(r'<table(?![a-z])', caseSensitive: false)
      .allMatches(body)) {
    starts.add(m.start);
  }
  final ends = <int>[];
  for (final m in RegExp(r'</table', caseSensitive: false).allMatches(body)) {
    ends.add(m.start);
  }
  final out = <_HtmlSpan>[];
  for (final s in starts) {
    var e = body.length;
    for (final x in ends) {
      if (x > s) {
        e = x;
        break;
      }
    }
    if (out.isNotEmpty && s < out.last.end) continue; // 嵌套：并入外层
    out.add(_HtmlSpan(s, e));
  }
  return out;
}

bool _psIsDataRow(
  List<String> cells, {
  bool strict = true,
  int headerCols = 0,
}) {
  if (cells.where((t) => t.isNotEmpty).length < 2) return false;
  if (cells.any(_isPaSSearchJunkRow)) return false;
  if (_isLinkOnlyRow(cells)) return false;
  // 列数明显不够（比如 7 列的表头下冒出一条 2 列的页脚行）也判为非数据行。
  // 留 2 列余量：这两个站大量行尾部是空单元格。
  if (headerCols >= 3 && cells.length < headerCols - 2) return false;
  return strict ? _looksLikeStockRow(cells) : true;
}

_HtmlTable _parseHtmlTable(String body, {int? declared}) {
  // 服务端声明了 N>0 条时放宽过滤：它说有数据，我们就别把数据筛没了
  final strict = declared == null || declared <= 0;

  // ── 按 <table> 分块，只在「含表头的那一块」里取行 ──────────────────────
  const headKeys = <String>['配属', '转向架', '定员', '机务段', '备注', '厂家'];
  final spans = _htmlTableSpans(body);

  var headIdx = -1;
  var bestScore = -1;
  List<List<String>>? blockRows;

  for (final sp in spans) {
    final rows = _htmlRows(body, start: sp.start, end: sp.end);
    for (var i = 0; i < rows.length; i++) {
      final c = rows[i];
      if (!c.any((t) => t.contains('车号'))) continue;
      if (!c.any((t) => headKeys.any((k) => t.contains(k)))) continue;
      if (c.any(_isPaSSearchJunkRow)) continue; // 查询表单行也算 junk
      var score = 0;
      for (var j = i + 1; j < rows.length; j++) {
        if (_psIsDataRow(rows[j], strict: false, headerCols: c.length)) {
          score++;
        } else if (score > 0 && rows[j].any((t) => t.contains('车号'))) {
          break; // 撞上下一个表头就停
        }
      }
      if (score > bestScore) {
        bestScore = score;
        headIdx = i;
        blockRows = rows;
      }
    }
  }

  // ── 兜底：页面结构变了（连一个 <table> 都没有）时退回整页扫描 ──────────
  if (blockRows == null) {
    final all = _htmlRows(body);
    for (var i = 0; i < all.length; i++) {
      final c = all[i];
      if (!c.any((t) => t.contains('车号'))) continue;
      if (!c.any((t) => headKeys.any((k) => t.contains(k)))) continue;
      if (c.any(_isPaSSearchJunkRow)) continue;
      var score = 0;
      for (var j = i + 1; j < all.length; j++) {
        if (_psIsDataRow(all[j], strict: false, headerCols: c.length)) {
          score++;
        } else if (score > 0 && all[j].any((t) => t.contains('车号'))) {
          break;
        }
      }
      if (score > bestScore) {
        bestScore = score;
        headIdx = i;
        blockRows = all;
      }
    }
  }

  final header = <String, int>{};
  if (headIdx >= 0 && blockRows != null) {
    final hc = blockRows[headIdx];
    for (var i = 0; i < hc.length; i++) {
      if (hc[i].isEmpty) continue;
      header.putIfAbsent(hc[i], () => i);
    }
  }

  final rows = <List<String>>[];
  if (headIdx >= 0 && blockRows != null) {
    // ⚠️ 只扫到 blockRows.length（本张表结束）为止，
    //    不再像旧版那样一直扫到整页末尾——页脚那张表的行根本不在这里面。
    for (var i = headIdx + 1; i < blockRows.length; i++) {
      if (_psIsDataRow(blockRows[i],
          strict: strict, headerCols: header.length)) {
        rows.add(blockRows[i]);
      }
    }
  }

  // ── 最后兜底：本表没解出任何行时，才在整页范围放宽扫一遍 ──────────────
  // 宁可多扫几行，也不要在「页面明明写着 N 条」时返回 0 行。
  // 此时 junk 词表 + _isLinkOnlyRow 仍然生效，页脚友情链接进不来。
  if (rows.isEmpty) {
    final all = _htmlRows(body);
    for (var i = 0; i < all.length; i++) {
      if (i == headIdx && identical(all, blockRows)) continue;
      if (_psIsDataRow(all[i], strict: false)) rows.add(all[i]);
    }
  }
  return _HtmlTable(header: header, rows: rows);
}

/// 解析失败时给用户的现场证据：前若干行 + 最后几行的单元格内容
/// （用同一套 _htmlRows 切分，保证打出来的就是解析器实际看到的东西）
String _psTableDebug(String body) {
  final all = _htmlRows(body);
  final sb = StringBuffer();
  for (var i = 0; i < all.length && i < 8; i++) {
    sb.writeln('第${i + 1}行[${all[i].length}格]: ${all[i].join(' | ')}');
  }
  if (all.length > 8) {
    sb.writeln('（共 ${all.length} 行，以下为最后 2 行）');
    for (var i = all.length - 2; i < all.length; i++) {
      if (i < 8) continue;
      sb.writeln('第${i + 1}行[${all[i].length}格]: ${all[i].join(' | ')}');
    }
  }
  return sb.toString();
}

/// 单元格纯文本：去标签、去实体
String _htmlText(String raw) {
  var s = raw.replaceAll(RegExp(r'<[^>]*>'), '');
  s = s
      .replaceAll(RegExp(r'&nbsp;?|&#160;?'), ' ')
      .replaceAll('&amp;', '&')
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&quot;', '"');
  return s.replaceAll(RegExp(r'\s+'), ' ').trim();
}

String _cleanErr(Object e) =>
    e.toString().replaceFirst(RegExp(r'^Exception:\s*'), '');

String _fmtDash(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-'
    '${d.month.toString().padLeft(2, '0')}-'
    '${d.day.toString().padLeft(2, '0')}';

String _fmtCompact(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}'
    '${d.month.toString().padLeft(2, '0')}'
    '${d.day.toString().padLeft(2, '0')}';

String _fmtCn(DateTime d) =>
    '${d.month}月${d.day}日 ${_weekdayCn(d.weekday)}';

String _weekdayCn(int w) {
  const names = ['周一', '周二', '周三', '周四', '周五', '周六', '周日'];
  return names[((w - 1).clamp(0, 6)).toInt()];
}

/// 今天的零点（日期比较/预售期边界统一用它）
DateTime _today() {
  final n = DateTime.now();
  return DateTime(n.year, n.month, n.day);
}

/// 秒级 Unix 时间戳 → 上海时间（数据源一律按 UTC+8 出）
DateTime _tsCst(int? sec) {
  if (sec == null || sec <= 0) {
    return DateTime.fromMillisecondsSinceEpoch(0);
  }
  return DateTime.fromMillisecondsSinceEpoch(sec * 1000, isUtc: true)
      .add(const Duration(hours: 8));
}

/// 秒级 Unix 时间戳 → HH:mm，非法值返回空串
String _hhmm(int? sec) {
  if (sec == null || sec <= 0) return '';
  final t = _tsCst(sec);
  return '${t.hour.toString().padLeft(2, '0')}:'
      '${t.minute.toString().padLeft(2, '0')}';
}

/// OpenCRHTracker 的 serviceDay：按上海时间自 1970-01-01 起的天数
/// （文档示例：2026-08-14 → 20679，已验证一致）
DateTime _serviceDayToDate(int day) =>
    DateTime.fromMillisecondsSinceEpoch(day * 86400000, isUtc: true)
        .add(const Duration(hours: 8));

/// {prefix: 'G', number: 9418} → G9418
String _joinTrainCode(dynamic tc) {
  if (tc is Map) {
    final p = (tc['prefix'] ?? '').toString();
    final n = (tc['number'] ?? '').toString();
    final code = '$p$n';
    if (code.trim().isNotEmpty && code != p) return code;
  }
  return tc?.toString() ?? '';
}

bool _isSameDay(DateTime a, DateTime b) =>
    a.year == b.year && a.month == b.month && a.day == b.day;

/// 站名归一化（去空格、去“站”字，用于里程/正晚点的站名配对）
String _normStation(String name) {
  var s = name.trim().replaceAll(RegExp(r'\s+'), '');
  if (s.length > 1 && s.endsWith('站')) s = s.substring(0, s.length - 1);
  return s;
}

/// 从 12306 经停记录里挖电报码（不同版本字段名不一致，多做几个候选）
String? _pickTelecode(Map e) {
  for (final k in <String>[
    'station_telecode',
    'station_tele_code',
    'telecode',
    'station_code',
    'stationCode',
    'stationTelecode',
  ]) {
    final v = e[k];
    if (v == null) continue;
    final s = v.toString().trim().toUpperCase();
    if (RegExp(r'^[A-Z]{3}$').hasMatch(s)) return s;
  }
  return null;
}

/// 从 12306 检索结果里挖车型（普速主要靠它，字段同样不稳定）
String _pickTrainModel(Map e) {
  for (final k in <String>[
    'train_type',
    'trainType',
    'train_type_name',
    'crh_type',
    'emu_type',
    'model',
    'type',
  ]) {
    final v = e[k];
    if (v == null) continue;
    final s = v.toString().trim();
    if (s.isEmpty || s == 'null') continue;
    // 排除明显不是车型的枚举值
    if (RegExp(r'^\d+$').hasMatch(s)) continue;
    return s;
  }
  return '';
}

/// 里程解析：先按 JSON 找「站名 + 里程」字段，失败再按 HTML 表格抓
Map<String, double> _parseMileage(String body) {
  final out = <String, double>{};
  if (body.trim().isEmpty) return out;

  // ── JSON 分支 ────────────────────────────────────────────────────────────
  try {
    final root = jsonDecode(body);
    final list = (root is List)
        ? root
        : (root is Map
            ? ((root['data'] is List)
                ? root['data'] as List
                : ((root['data'] is Map)
                    ? ((root['data']['list'] ?? root['data']['items']) as List?)
                    : null))
            : null);
    if (list != null) {
      for (final e in list) {
        if (e is! Map) continue;
        final name = (e['station'] ?? e['station_name'] ?? e['name'] ?? '')
            .toString()
            .trim();
        final raw = (e['mileage'] ?? e['km'] ?? e['distance'] ?? e['licheng'])
            ?.toString();
        final km = _toKm(raw);
        if (name.isNotEmpty && km != null) out[_normStation(name)] = km;
      }
      if (out.isNotEmpty) return out;
    }
  } catch (_) {
    // 不是 JSON，走 HTML 分支
  }

  // ── HTML 表格分支 ────────────────────────────────────────────────────────
  final rows = RegExp(
    r'<tr[^>]*>(.*?)</tr>',
    caseSensitive: false,
    dotAll: true,
  ).allMatches(body);

  int? mileCol; // 表头里「里程」所在列
  int? nameCol; // 表头里「站名」所在列

  for (final row in rows) {
    final cells = RegExp(
      r'<t[dh][^>]*>(.*?)</t[dh]>',
      caseSensitive: false,
      dotAll: true,
    ).allMatches(row.group(1) ?? '');

    final texts = cells
        .map(
          (m) => (m.group(1) ?? '')
              .replaceAll(RegExp(r'<[^>]*>'), '')
              .replaceAll(RegExp(r'&nbsp;?'), ' ')
              .trim(),
        )
        .where((t) => t.isNotEmpty)
        .toList();
    if (texts.length < 2) continue;

    // 表头行：记住列位置，不产出数据
    final headIdx = texts.indexWhere((t) => t.contains('里程'));
    if (headIdx >= 0) {
      mileCol = headIdx;
      final nIdx = texts.indexWhere(
        (t) => t.contains('站名') || t.contains('车站'),
      );
      nameCol = nIdx >= 0 ? nIdx : null;
      continue;
    }

    // 站名：优先用表头定位的列，否则取第一个含中文、非纯数字的单元格
    var nameIdx = nameCol ?? -1;
    if (nameIdx < 0 || nameIdx >= texts.length) {
      nameIdx = texts.indexWhere(
        (t) => RegExp(r'[\u4e00-\u9fa5]').hasMatch(t) &&
            !RegExp(r'^\d+(\.\d+)?$').hasMatch(t),
      );
    }
    if (nameIdx < 0 || nameIdx >= texts.length) continue;

    // 里程：优先按表头列取，否则取站名之后第一个形如 123 / 123.4 / 123km 的格
    double? km;
    if (mileCol != null && mileCol < texts.length) {
      km = _toKm(texts[mileCol]);
    }
    if (km == null) {
      for (var i = nameIdx + 1; i < texts.length; i++) {
        km = _toKm(texts[i]);
        if (km != null) break;
      }
    }
    if (km == null) continue;
    out[_normStation(texts[nameIdx])] = km;
  }
  return out;
}

/// HH:mm → 当日分钟数，解析失败返回 null
int? _parseHm(String v) {
  final m = RegExp(r'(\d{1,2}):(\d{2})').firstMatch(v.trim());
  if (m == null) return null;
  final h = int.tryParse(m.group(1)!);
  final mm = int.tryParse(m.group(2)!);
  if (h == null || mm == null) return null;
  return h * 60 + mm;
}

double? _toKm(String? raw) {
  if (raw == null) return null;
  final s = raw.trim().toLowerCase().replaceAll(RegExp(r'[,，\s]'), '');
  final m = RegExp(r'(\d+(?:\.\d+)?)').firstMatch(s.replaceAll('km', ''));
  if (m == null) return null;
  return double.tryParse(m.group(1)!);
}

/// 正晚点解析：JSON 取 data/message 文本，HTML 去标签，再抓「晚点 X 分 / 正点」
_LateInfo? _parseLate(String body) {
  if (body.trim().isEmpty) return null;

  String text;
  try {
    final root = jsonDecode(body);
    if (root is Map) {
      var buf = '';
      for (final k in <String>['data', 'message', 'msg', 'result']) {
        final v = root[k];
        if (v is String) {
          buf += ' $v';
        } else if (v is Map) {
          for (final kk in <String>['msg', 'message', 'text', 'status']) {
            final vv = v[kk];
            if (vv is String) buf += ' $vv';
          }
        }
      }
      text = buf.isNotEmpty ? buf : root.toString();
    } else {
      text = root.toString();
    }
  } catch (_) {
    text = body.replaceAll(RegExp(r'<[^>]*>', dotAll: true), ' ');
  }

  final t = text.replaceAll(RegExp(r'\s+'), ' ');

  final late = RegExp(r'晚点\s*(\d+)\s*分').firstMatch(t);
  if (late != null) {
    return _LateInfo(lateMin: int.tryParse(late.group(1)!) ?? 0);
  }
  final early = RegExp(r'早点\s*(\d+)\s*分').firstMatch(t);
  if (early != null) {
    return _LateInfo(lateMin: -(int.tryParse(early.group(1)!) ?? 0));
  }
  if (t.contains('正点')) return const _LateInfo(lateMin: 0);

  final tm = RegExp(r'(\d{1,2}:\d{2})').firstMatch(t);
  if (tm != null) return _LateInfo(realTime: tm.group(1)!);

  return null;
}

/// 车组号写法的候选列表，按命中概率排序：
///   CR400BF-5033 → [CR400BF-5033, CR400BF5033]
///   CR400BF5033  → [CR400BF5033, CR400BF-5033]
/// 两个数据源对横杠的容忍度不一致，两边都拿候选列表去试最稳。
List<String> _emuNoVariants(String raw) {
  final s = raw.trim();
  if (s.isEmpty) return const <String>[];
  final out = <String>[s];
  if (s.contains('-')) {
    final noDash = s.replaceAll('-', '');
    if (noDash.isNotEmpty) out.add(noDash);
  } else {
    final dashed = _prettyEmuNo(s);
    if (dashed != s) out.add(dashed);
  }
  return out;
}

/// rail.re 的车组号是 CR400AF2031（无横杠），补成 CR400AF-2031
String _prettyEmuNo(String raw) {
  final s = raw.trim();
  if (s.isEmpty) return s;
  if (s.contains('-')) return s;
  final m = RegExp(r'^([A-Za-z]+[A-Za-z0-9]*?)(\d{3,5})$').firstMatch(s);
  if (m != null) return '${m.group(1)}-${m.group(2)}';
  return s;
}
