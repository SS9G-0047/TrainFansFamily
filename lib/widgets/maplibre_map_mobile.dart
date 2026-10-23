import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:latlong2/latlong.dart';
// Android 使用 GeckoView (Firefox 引擎)，Windows 使用 webview_all
import 'package:webview_flutter/webview_flutter.dart' as wv_flutter;
import 'package:webview_flutter_geckoview/webview_flutter_geckoview.dart';
import 'package:webview_all/webview_all.dart' as wv_all;

import 'maplibre_map.dart';
import '../config/app_endpoints.dart';

State<MapLibreMapWidget> createMapLibreState() => _MapLibreMapMobileState();

void _runWebViewJavaScript(_WebViewAdapter? controller, String code) {
  if (controller == null) return;
  unawaited(
    controller.runJavaScript(code).catchError((Object error) {
      debugPrint('[MapLibre] WebView JavaScript execution failed: $error');
    }),
  );
}

abstract class _WebViewAdapter {
  Future<void> setJavaScriptMode(bool unrestricted);
  Future<void> addJavaScriptChannel(
    String name, {
    required void Function(String) onMessageReceived,
  });
  Future<void> setOnConsoleMessage(void Function(dynamic) callback);
  Future<void> loadHtmlString(String html, {String? baseUrl});
  Future<void> runJavaScript(String code);
  Future<void> clearCache();
  Widget buildWidget();
  void dispose();
}

class _WebViewFlutterAdapter implements _WebViewAdapter {
  final wv_flutter.WebViewController controller;
  HttpServer? _htmlServer;
  final Map<String, void Function(String)> _channelCallbacks = {};
  bool _urlBridgeInitialized = false;
  void Function(dynamic)? _userConsoleCallback;
  int _cmdSeq = 0;
  Timer? _msgPollingTimer;
  bool _msgPollingStarted = false;

  // 命令队列：防止并发调用导致 cmdId 重复，以及 hash 变化太快导致事件丢失
  final List<String> _cmdQueue = [];
  bool _cmdQueueProcessing = false;

  _WebViewFlutterAdapter() : controller = wv_flutter.WebViewController();

  @override
  Future<void> setJavaScriptMode(bool unrestricted) async {
    await controller.setJavaScriptMode(
      unrestricted
          ? wv_flutter.JavaScriptMode.unrestricted
          : wv_flutter.JavaScriptMode.disabled,
    );
  }

  Future<void> _ensureUrlBridge() async {
    if (_urlBridgeInitialized) return;
    _urlBridgeInitialized = true;
    final delegate = wv_flutter.NavigationDelegate(
      onNavigationRequest: (request) async {
        final uri = Uri.tryParse(request.url);
        if (uri != null && uri.scheme == 'jsbridge') {
          // 格式：jsbridge://channelName/message  (message 是 base64 编码)
          final channel = uri.host;
          final payloadBase64 = uri.path.replaceFirst('/', '');
          try {
            final payload = utf8.decode(base64Decode(payloadBase64));
            final cb = _channelCallbacks[channel];
            if (cb != null) {
              cb(payload);
            }
          } catch (_) {}
          return wv_flutter.NavigationDecision.prevent;
        }
        return wv_flutter.NavigationDecision.navigate;
      },
      onPageFinished: (url) {
        // 页面加载完成后再启动轮询，避免干扰页面加载
        debugPrint('[MapLibre-bridge] Page finished loading: $url');
        _startMsgPolling();
      },
    );
    await controller.setNavigationDelegate(delegate);
  }

  @override
  Future<void> addJavaScriptChannel(
    String name, {
    required void Function(String) onMessageReceived,
  }) async {
    _channelCallbacks[name] = onMessageReceived;
    await _ensureUrlBridge();
    // 注意：不调用 controller.addJavaScriptChannel()
    // GeckoView 的 channel 在 content script 上下文，页面访问不到，
    // 我们用自定义 URL scheme (jsbridge://) 做桥接
  }

  @override
  Future<void> setOnConsoleMessage(void Function(dynamic) callback) async {
    try {
      await controller.setOnConsoleMessage((msg) => callback(msg));
    } on UnimplementedError {
      // GeckoView 未实现 setOnConsoleMessage，忽略
      _userConsoleCallback = callback;
    }
  }

  @override
  Future<void> loadHtmlString(String html, {String? baseUrl}) async {
    // 在 </head> 前注入 jsbridge URL 桥接代码，确保页面 JS 一开始就能用
    final bridgeScript = _buildBridgeScript();
    final modifiedHtml = html.replaceFirst(
      '</head>',
      '$bridgeScript</head>',
    );
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _htmlServer = server;
    server.listen((request) async {
      request.response.headers.contentType = ContentType.html;
      request.response.headers.set(HttpHeaders.cacheControlHeader, 'no-store');
      request.response.write(modifiedHtml);
      await request.response.close();
    });
    await controller.loadRequest(
      Uri(scheme: 'http', host: '127.0.0.1', port: server.port, path: '/'),
    );
  }

  String _buildBridgeScript() {
    if (_channelCallbacks.isEmpty) return '';
    final channelList = _channelCallbacks.keys.toList();
    final channelsJs = jsonEncode(channelList);
    return '''
<script>
(function() {
  var channels = $channelsJs;
  // === 页面 → Dart 消息队列 ===
  window.__outgoingMsgQueue = [];
  function enqueueMsg(chName, msg) {
    window.__outgoingMsgQueue.push({ ch: chName, msg: String(msg) });
    // 尝试用 iframe 方式（更快，如果 NavigationDelegate 支持的话）
    try {
      var encoded = btoa(unescape(encodeURIComponent(String(msg))));
      var iframe = document.getElementById('__jsbridge_iframe__');
      if (!iframe) {
        iframe = document.createElement('iframe');
        iframe.id = '__jsbridge_iframe__';
        iframe.style.display = 'none';
        document.documentElement.appendChild(iframe);
      }
      iframe.src = 'jsbridge://' + chName + '/' + encoded;
    } catch(e) {}
  }

  channels.forEach(function(chName) {
    // 如果原生 channel 已存在（标准 WebView），包装一下
    if (window[chName] && typeof window[chName].postMessage === 'function') {
      var origPost = window[chName].postMessage.bind(window[chName]);
      window[chName].postMessage = function(msg) {
        enqueueMsg(chName, msg);
        try { origPost(msg); } catch(e) {}
      };
      return;
    }
    // 否则创建我们的 channel 对象
    window[chName] = {
      postMessage: function(msg) {
        enqueueMsg(chName, msg);
      }
    };
  });

  // === Dart → 页面：监听 hash 变化执行命令 ===
  var _lastProcessedCmdId = '';
  
  function decodeB64(str) {
    try {
      return decodeURIComponent(escape(atob(str)));
    } catch(e) {
      console.error('base64 decode failed:', e);
      return '';
    }
  }

  function checkHashCmd() {
    var hash = window.location.hash;
    var prefix = '#cmd:';
    if (hash.indexOf(prefix) !== 0) return;
    var payload = hash.substring(prefix.length);
    // 格式: seq:base64code
    var sepIdx = payload.indexOf(':');
    if (sepIdx < 0) return;
    var cmdId = payload.substring(0, sepIdx);
    if (cmdId === _lastProcessedCmdId) return; // 避免重复执行
    _lastProcessedCmdId = cmdId;
    var b64 = payload.substring(sepIdx + 1);
    var code = decodeB64(b64);
    if (!code) return;
    try {
      // 在页面上下文中执行代码
      var s = document.createElement('script');
      s.textContent = code;
      document.documentElement.appendChild(s);
      s.remove();
    } catch(e) {
      console.error('hash cmd exec failed:', e);
    }
    // 执行完命令后，把待发送消息 flush 到 hash 中，供 Dart 端读取
    setTimeout(flushMsgsToHash, 0);
  }

  // 把消息队列中的消息编码到 hash 中（用 replaceState，不触发 hashchange）
  var __msgBatchId = 0;
  function flushMsgsToHash() {
    var q = window.__outgoingMsgQueue;
    if (!q || q.length === 0) return;
    try {
      __msgBatchId++;
      var jsonStr = JSON.stringify(q);
      var encoded = btoa(unescape(encodeURIComponent(jsonStr)));
      q.length = 0;
      // 使用 replaceState 修改 hash，不触发 hashchange
      // 格式: #msgs:batchId:base64json
      var newHash = '#msgs:' + __msgBatchId + ':' + encoded;
      history.replaceState(null, '', newHash);
    } catch(e) {
      console.error('flush msgs failed:', e);
    }
  }
  window.__flushMsgsToHash = flushMsgsToHash;

  window.addEventListener('hashchange', checkHashCmd);
  // 页面加载后也检查一次
  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', checkHashCmd);
  } else {
    checkHashCmd();
  }
})();
</script>
''';
  }

  @override
  Future<void> runJavaScript(String code) async {
    // 加入命令队列，串行执行（避免并发导致 cmdId 重复和 hash 事件合并丢失）
    _cmdQueue.add(code);
    if (!_cmdQueueProcessing) {
      _processCmdQueue();
    }
  }

  Future<void> _processCmdQueue() async {
    if (_cmdQueueProcessing) return;
    _cmdQueueProcessing = true;
    try {
      while (_cmdQueue.isNotEmpty) {
        // 取出队列中所有命令，合并成一个 batch 执行（减少 hash 变化次数）
        final batch = _cmdQueue.toList();
        _cmdQueue.clear();
        final combinedCode = batch.join('\n');
        debugPrint('[MapLibre-js-batch] ${batch.length} commands, first: ${combinedCode.substring(0, combinedCode.length > 120 ? 120 : combinedCode.length)}...');
        await _executeJsViaHash(combinedCode);
        // 执行完后留一点时间让页面处理和消息回传
        await Future<void>.delayed(const Duration(milliseconds: 80));
        await _drainMessagesFromHash();
      }
    } finally {
      _cmdQueueProcessing = false;
      // 处理过程中可能又有新命令入队，再检查一次
      if (_cmdQueue.isNotEmpty) {
        _processCmdQueue();
      }
    }
  }

  Future<void> _executeJsViaHash(String code) async {
    // 同步递增序号（在任何 await 之前），确保每个命令有唯一 ID
    _cmdSeq++;
    final cmdId = _cmdSeq;
    final codeBytes = utf8.encode(code);
    final codeB64 = base64Encode(codeBytes);
    try {
      final currentUrl = await controller.currentUrl();
      if (currentUrl != null && currentUrl.isNotEmpty) {
        final uri = Uri.parse(currentUrl);
        final newFragment = 'cmd:$cmdId:$codeB64';
        final newUri = uri.replace(fragment: newFragment);
        await controller.loadRequest(newUri);
        debugPrint('[MapLibre-js-hash] cmd#$cmdId sent, b64len=${codeB64.length}');
      }
    } catch (e) {
      debugPrint('[MapLibre-js-hash-error] $e');
    }
    
    // 同时也用 script 注入方式尝试（双保险）
    try {
      final codeJson = jsonEncode(code);
      final wrapped = '''
(function() {
  var s = document.createElement('script');
  s.textContent = $codeJson;
  (document.head || document.documentElement).appendChild(s);
  s.remove();
})();
''';
      await controller.runJavaScript(wrapped);
    } catch (e) {
      // script 注入可能在 GeckoView 中不工作，忽略
    }
  }

  String _lastProcessedBatchId = '';

  Future<void> _drainMessagesFromHash() async {
    try {
      final currentUrl = await controller.currentUrl();
      if (currentUrl == null || currentUrl.isEmpty) return;
      final uri = Uri.parse(currentUrl);
      final fragment = uri.fragment;
      const prefix = 'msgs:';
      if (!fragment.startsWith(prefix)) return;
      final payload = fragment.substring(prefix.length);
      // 格式: batchId:base64json
      final sepIdx = payload.indexOf(':');
      if (sepIdx < 0) return;
      final batchId = payload.substring(0, sepIdx);
      if (batchId == _lastProcessedBatchId) return; // 已处理过
      _lastProcessedBatchId = batchId;
      
      final msgB64 = payload.substring(sepIdx + 1);
      final msgJson = utf8.decode(base64Decode(msgB64));
      final List<dynamic> messages = jsonDecode(msgJson);
      debugPrint('[MapLibre-hash-msg] batch=$batchId, count=${messages.length}');
      for (final item in messages) {
        if (item is! Map<String, dynamic>) continue;
        final ch = item['ch'] as String?;
        final msg = item['msg'] as String?;
        if (ch == null || msg == null) continue;
        final cb = _channelCallbacks[ch];
        if (cb != null) cb(msg);
      }
    } catch (e) {
      debugPrint('[MapLibre-hash-drain-error] $e');
    }
  }

  void _startMsgPolling() {
    if (_msgPollingStarted) return;
    _msgPollingStarted = true;
    debugPrint('[MapLibre-bridge] Starting hash-based message polling');
    _msgPollingTimer = Timer.periodic(const Duration(milliseconds: 800), (_) {
      _pollMessages();
    });
  }

  Future<void> _pollMessages() async {
    // 发送 flush 命令，让页面把待发送消息写到 hash 中
    try {
      final currentUrl = await controller.currentUrl();
      if (currentUrl == null || currentUrl.isEmpty) return;
      final uri = Uri.parse(currentUrl);
      // 如果命令队列正在处理中，跳过（避免冲突）
      if (_cmdQueueProcessing) return;
      // 如果队列中已经有命令在等待，也跳过（队列处理完会自动 drain）
      if (_cmdQueue.isNotEmpty) return;
      // 如果当前 hash 已经是 cmd: 开头，说明之前的命令还没处理
      if (uri.fragment.startsWith('cmd:')) return;
      
      _cmdSeq++;
      final cmdId = _cmdSeq;
      const flushCode = 'window.__flushMsgsToHash && window.__flushMsgsToHash();';
      final codeBytes = utf8.encode(flushCode);
      final codeB64 = base64Encode(codeBytes);
      final newFragment = 'cmd:$cmdId:$codeB64';
      final newUri = uri.replace(fragment: newFragment);
      await controller.loadRequest(newUri);
      
      // 等页面执行并修改 hash
      await Future<void>.delayed(const Duration(milliseconds: 200));
      await _drainMessagesFromHash();
    } catch (e) {
      // 静默失败
    }
  }

  @override
  Future<void> clearCache() async {
    await controller.clearCache();
  }

  @override
  Widget buildWidget() => wv_flutter.WebViewWidget(controller: controller);

  @override
  void dispose() {
    _msgPollingTimer?.cancel();
    _msgPollingTimer = null;
    final server = _htmlServer;
    _htmlServer = null;
    if (server != null) unawaited(server.close(force: true));
  }
}

class _WebViewAllAdapter implements _WebViewAdapter {
  final wv_all.WebViewController controller;

  _WebViewAllAdapter() : controller = wv_all.WebViewController();

  @override
  Future<void> setJavaScriptMode(bool unrestricted) async {
    await controller.setJavaScriptMode(
      unrestricted
          ? wv_all.JavaScriptMode.unrestricted
          : wv_all.JavaScriptMode.disabled,
    );
  }

  @override
  Future<void> addJavaScriptChannel(
    String name, {
    required void Function(String) onMessageReceived,
  }) async {
    await controller.addJavaScriptChannel(
      name,
      onMessageReceived: (msg) => onMessageReceived(msg.message),
    );
  }

  @override
  Future<void> setOnConsoleMessage(void Function(dynamic) callback) async {
    await controller.setOnConsoleMessage(callback);
  }

  @override
  Future<void> loadHtmlString(String html, {String? baseUrl}) async {
    await controller.loadHtmlString(html, baseUrl: baseUrl);
  }

  @override
  Future<void> runJavaScript(String code) async {
    await controller.runJavaScript(code);
  }

  @override
  Future<void> clearCache() async {
    try {
      await controller.clearCache();
    } catch (_) {}
  }

  @override
  Widget buildWidget() => wv_all.WebViewWidget(controller: controller);

  @override
  void dispose() {}
}

class _MapLibreMapMobileState extends State<MapLibreMapWidget> {
  _WebViewAdapter? _webController;
  bool _mapReady = false;
  String? _initError;
  late final _MobileControllerImpl _ctrlImpl;

  // Android only: CORS tile proxy state
  final Map<int, _TileRequest> _tileRequests = {};
  http.Client? _tileClient;

  bool get _isAndroid => defaultTargetPlatform == TargetPlatform.android;

  @override
  void initState() {
    super.initState();
    _ctrlImpl = _MobileControllerImpl(widget.initialZoom, {
      'lat': widget.initialCenter.latitude,
      'lng': widget.initialCenter.longitude,
    });
    _init();
  }

  Future<void> _init() async {
    try {
      final styleJson = resolveMapStyle(
        await rootBundle.loadString(maplibreStyleAssetPath),
      );
      final maplibreJs = await rootBundle.loadString(maplibreJsAssetPath);
      final maplibreCss = await rootBundle.loadString(maplibreCssAssetPath);
      final viewId = 'maplibre-${identityHashCode(this)}';

      // Android 端注册 GeckoView (Firefox 引擎)，替换系统 WebView
      if (_isAndroid) {
        GeckoWebViewPlatform.registerWith();
      }
      // Android 用 GeckoView，Windows 用 webview_all
      final controller = _isAndroid
          ? _WebViewFlutterAdapter()
          : _WebViewAllAdapter();

      await controller.setJavaScriptMode(true);
      await controller.addJavaScriptChannel(
        'flutterMapEvent',
        onMessageReceived: (m) => _handleEvent(m),
      );

      // Only register tile proxy channel on Android
      if (_isAndroid) {
        await controller.addJavaScriptChannel(
          'flutterTileProxy',
          onMessageReceived: (m) => _handleTileRequest(m),
        );
        // 清除 WebView 缓存，避免瓦片被缓存导致不请求新数据
        await controller.clearCache();
      }

      try {
        await controller.setOnConsoleMessage((msg) {
          debugPrint('[MapLibre] ${msg.message}');
        });
      } on UnimplementedError {
        debugPrint('[MapLibre] Console message listener is not supported by this WebView.');
      }

      _webController = controller;
      _ctrlImpl._webView = controller;
      if (mounted) setState(() {});

      await controller.loadHtmlString(
        _buildHtml(styleJson, maplibreJs, maplibreCss, viewId),
        baseUrl: _isAndroid ? null : 'https://maplibre.local/',
      );

      // Don't attach controller yet — wait for JS 'ready' event
      // so that move() calls work when the map is actually loaded.
    } catch (e) {
      debugPrint('MapLibre init failed: $e');
      if (mounted) setState(() => _initError = e.toString());
    }
  }

  String _buildHtml(
    String styleJson,
    String maplibreJs,
    String maplibreCss,
    String viewId,
  ) {
    final styleLiteral = jsonEncode(styleJson);
    final cdnListJson = jsonEncode(AppEndpoints.maplibreCdnJsdelivr);
    const useProxy = 'false';
    final isAndroid = _isAndroid ? 'true' : 'false';
    final centerLng = widget.initialCenter.longitude;
    final centerLat = widget.initialCenter.latitude;
    final initZoom = widget.initialZoom;

    return '''
<!DOCTYPE html>
<html>
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1, user-scalable=no">
  <style>
    $maplibreCss
    * { box-sizing: border-box; margin: 0; padding: 0; }
    html, body { width: 100%; height: 100%; overflow: hidden; background: #f5f5f5; }
    #map { position: absolute; top: 0; left: 0; width: 100%; height: 100%; }
    .maplibregl-ctrl-attribution { display: none !important; }
  </style>
</head>
<body>
  <div id="map"></div>
  <script>
    // === 全局错误捕获：打印完整堆栈 ===
    window.addEventListener('error', function(e) {
      var err = e.error || {};
      console.error('[GLOBAL-ERROR] ' + e.message +
        '\n  filename=' + e.filename +
        '\n  lineno=' + e.lineno +
        '\n  colno=' + e.colno +
        '\n  stack=' + (err.stack || '(no stack)'));
    });
  </script>
  <script>
    $maplibreJs
  </script>
  <script>
    $kMapControllerJs

    var _useProxy = $useProxy;

    function _initMap() {
      if (typeof maplibregl === 'undefined') {
        console.error('maplibre-gl not available');
        return;
      }
      try {
        console.log('init map, useProxy=' + _useProxy);

        var _isAndroid = $isAndroid;
        var style = JSON.parse($styleLiteral);

        // --- Android: replace railway tiles with tileproxy:// to bypass CORS ---
        if (_useProxy && style.sources && style.sources.railway) {
          if (window.flutterTileProxy && typeof maplibregl.addProtocol === 'function') {
            _setupTileProxy();
            var tiles = style.sources.railway.tiles;
            style.sources.railway.tiles = tiles.map(function(u) {
              return 'tileproxy://' + u.substring(8);
            });
            console.log('railway tiles using tileproxy');
          } else {
            console.warn('flutterTileProxy or addProtocol not available, railway tiles may fail CORS');
          }
        }

        var mapOpts = {
          container: 'map',
          style: style,
          center: [$centerLng, $centerLat],
          zoom: $initZoom,
          minZoom: $maplibreMinZoom,
          maxZoom: $maplibreMaxZoom,
          dragRotate: false,
          touchPitch: false,
          attributionControl: false,
          antialias: false
        };

        if (_isAndroid) {
          mapOpts = {
            container: 'map',
            style: style,
            pixelRatio: 1,
            antialias: false,
            fadeDuration: 0,
            center: [$centerLng, $centerLat],
            zoom: $initZoom,
            minZoom: $maplibreMinZoom,
            maxZoom: $maplibreMaxZoom,
            dragRotate: false,
            touchPitch: false,
            attributionControl: false,
            antialias: false,
            transformRequest: function(url, resourceType) {
              if (resourceType === 'Tile' && url.indexOf('.pbf') > -1) {
                var sep = url.indexOf('?') > -1 ? '&' : '?';
                return { url: url + sep + 't=' + Date.now() };
              }
              return null;
            }
          };
        }

        var map = new maplibregl.Map(mapOpts);

        map.on('load', function() {
          console.log('map loaded');
          _forceResize(map);
        });

        map.on('styledata', function() {
          console.log('style data loaded');
          _forceResize(map);
        });

        map.on('error', function(e) {
          var msg = '';
          if (e && e.error) {
            msg = e.error.message || String(e.error);
          } else {
            msg = e ? (e.message || 'unknown') : 'unknown';
          }
          if (e && e.sourceId) msg += ' [source=' + e.sourceId + ']';
          console.error('map error: ' + msg);
        });

        map.on('tileerror', function(e) {
          var src = e && e.sourceId ? e.sourceId : '?';
          var url = e && e.tile ? (e.tile.url || '') : '';
          console.warn('tile error [' + src + ']: ' + url);
        });

        // === 调试：瓦片加载成功检测 ===
        var _loadedTiles = {};
        map.on('tileload', function(e) {
          var src = e && e.sourceId ? e.sourceId : '?';
          var tile = e.tile;
          var tid = tile && tile.tileID ? tile.tileID.z + '/' + tile.tileID.x + '/' + tile.tileID.y : '?';
          var key = src + ':' + tid;
          if (!_loadedTiles[key]) {
            _loadedTiles[key] = true;
            console.log('[tileload] source=' + src + ' tile=' + tid + ' state=' + (tile && tile.state));
            // 如果是 railway source，延迟检查要素
            if (src === 'railway') {
              setTimeout(function() {
                try {
                  var feats = map.querySourceFeatures('railway', { sourceLayer: 'rail_gcj_2' }) || [];
                  console.log('[debug] railway features in rail_gcj_2: ' + feats.length);
                  if (feats.length > 0) {
                    var f0 = feats[0];
                    console.log('[debug] first feature: layer=' + (f0.sourceLayer || '?') +
                      ' type=' + (f0.geometry && f0.geometry.type || '?') +
                      ' props=' + JSON.stringify(f0.properties || {}).substring(0, 200));
                  }
                  // 也检查一下其他可能的 sourceLayer
                  var allLayers = map.getStyle() && map.getStyle().layers || [];
                  var railLayers = allLayers.filter(function(l) { return l.source === 'railway'; });
                  console.log('[debug] railway layers count: ' + railLayers.length);
                  railLayers.slice(0, 5).forEach(function(l) {
                    console.log('[debug]   layer: id=' + l.id + ' type=' + l.type +
                      ' source-layer=' + (l['source-layer'] || '?') +
                      ' minzoom=' + (l.minzoom || 'none') +
                      ' visible=' + (l.layout && l.layout.visibility !== 'none'));
                  });
                } catch(err) {
                  console.error('[debug] query error: ' + err.message);
                }
              }, 500);
            }
          }
        });

        // === 调试：WebGL 检测 ===
        if (_isAndroid) {
          try {
            var canvas = document.createElement('canvas');
            var gl = canvas.getContext('webgl') || canvas.getContext('experimental-webgl');
            console.log('[debug] WebGL available: ' + !!gl);
            if (gl) {
              console.log('[debug] WebGL vendor: ' + gl.getParameter(gl.VENDOR) +
                ', renderer: ' + gl.getParameter(gl.RENDERER));
            }
          } catch(e) {
            console.error('[debug] WebGL check error: ' + e.message);
          }
        }

        // Resize handling
        var resizeTimer = null;
        window.addEventListener('resize', function() {
          clearTimeout(resizeTimer);
          resizeTimer = setTimeout(function() { map.resize(); }, 100);
        });
        window.__mapResize = function() { map.resize(); };

        window.__mapCtrl = window.createMapController(map, '$viewId');
      } catch (e) {
        console.error('map init error: ' + e.message + '\\n' + e.stack);
      }
    }

    function _forceResize(map) {
      setTimeout(function() { map.resize(); }, 30);
      setTimeout(function() { map.resize(); }, 100);
      setTimeout(function() { map.resize(); }, 300);
      setTimeout(function() { map.resize(); }, 800);
      setTimeout(function() { map.resize(); }, 1500);
    }

    function _setupAndroidRailLabels(map, minZooms) {
      var labels = {};
      minZooms = minZooms || {};
      var minLineZoom = minZooms['rw-label-line-main'] || 7;
      var minMetroLineZoom = minZooms['rw-label-line-metro'] || 10;
      var minStationZoom = minZooms['rw-label-station-main'] || 7;
      var minMetroStationZoom = minZooms['rw-label-station-metro'] || 10;
      var mapRoot = document.getElementById('map');
      if (!mapRoot) return;
      mapRoot.style.position = 'relative';
      mapRoot.style.overflow = 'hidden';
      var labelContainer = document.createElement('div');
      labelContainer.style.cssText = 'position:absolute;left:0;top:0;width:100%;height:100%;pointer-events:none;overflow:hidden;z-index:20;display:block;transform:translateZ(0);';
      mapRoot.appendChild(labelContainer);

      function toText(value) {
        if (value === undefined || value === null) return '';
        var text = String(value).trim();
        if (!text || text === 'null' || text === 'undefined') return '';
        return text;
      }

      function pickLabel(properties, isStation) {
        var props = properties || {};
        return toText(props.station_name) || toText(props['name:zh']) ||
          toText(props.name_zh) || toText(props.name) || toText(props.station) || '';
      }

      function midpointFromLine(geometry) {
        if (!geometry || !geometry.coordinates) return null;
        var coords = geometry.coordinates;
        if (geometry.type === 'MultiLineString') {
          coords = coords.reduce(function(longest, part) {
            return part.length > longest.length ? part : longest;
          }, []);
        }
        if (!Array.isArray(coords) || coords.length === 0) return null;
        var point = coords[Math.floor(coords.length / 2)];
        if (!Array.isArray(point) || typeof point[0] !== 'number') return null;
        return point;
      }

      function anchorFromGeometry(geometry) {
        if (!geometry || !geometry.coordinates) return null;
        var coords = geometry.coordinates;
        if (geometry.type === 'Point') return coords;
        if (geometry.type === 'MultiPoint') return coords[0] || null;
        if (geometry.type === 'LineString' || geometry.type === 'MultiLineString') {
          return midpointFromLine(geometry);
        }
        if (geometry.type === 'Polygon' || geometry.type === 'MultiPolygon') {
          var rings = geometry.type === 'Polygon' ? coords : (coords[0] || []);
          var ring = rings[0] || [];
          if (!ring.length) return null;
          var totalLng = 0;
          var totalLat = 0;
          var count = ring.length > 1 ? ring.length - 1 : ring.length;
          for (var i = 0; i < count; i++) {
            totalLng += ring[i][0];
            totalLat += ring[i][1];
          }
          return [totalLng / count, totalLat / count];
        }
        return null;
      }

      function labelCandidate(feature, zoom) {
        var props = feature.properties || {};
        var geometry = feature.geometry;
        var railway = toText(props.railway).toLowerCase();
        var publicTransport = toText(props.public_transport).toLowerCase();
        var building = toText(props.building).toLowerCase();
        var metroTypes = ['subway', 'light_rail', 'tram', 'monorail'];
        var isMetro = metroTypes.indexOf(railway) !== -1 ||
          metroTypes.indexOf(toText(props.station).toLowerCase()) !== -1 ||
          metroTypes.indexOf(toText(props.network).toLowerCase()) !== -1;
        var stationTypes = ['station', 'halt', 'stop', 'tram_stop', 'subway_entrance'];
        var isStation = stationTypes.indexOf(railway) !== -1 ||
          ['station', 'stop_position', 'platform'].indexOf(publicTransport) !== -1 ||
          railway === 'platform' ||
          ['train_station', 'station'].indexOf(building) !== -1;
        if (isStation) {
          var stationMinZoom = isMetro ? minMetroStationZoom : minStationZoom;
          if (zoom < stationMinZoom) return null;
          var stationText = pickLabel(props);
          var coordinate = anchorFromGeometry(geometry);
          if (!stationText || !coordinate) return null;
          return {
            text: stationText,
            coordinate: coordinate,
            priority: 1,
            layer: Number(props.layer) || 0,
            key: 'station:' + stationText + ':' + (Number(props.layer) || 0) + ':' +
              coordinate[0].toFixed(4) + ':' + coordinate[1].toFixed(4)
          };
        }
        return null;
      }

      function getRailLayerIds() {
        if (!map || !map.getStyle || typeof map.getStyle !== 'function') return [];
        try {
          var style = map.getStyle();
          if (!style || !style.layers) return [];
          var ids = [];
          style.layers.forEach(function(layer) {
            if (!layer || layer.source !== 'railway') return;
            if (layer.type === 'line' || layer.type === 'symbol') ids.push(layer.id);
          });
          return ids;
        } catch (e) {
          console.warn('getRailLayerIds failed: ' + e.message);
          return [];
        }
      }

      function queryRailFeatures() {
        var combined = [];
        var railLayerIds = getRailLayerIds();

        if (map && typeof map.queryRenderedFeatures === 'function' && railLayerIds.length) {
          try {
            var rendered = map.queryRenderedFeatures({ layers: railLayerIds }) || [];
            combined = combined.concat(rendered);
          } catch (e) {
            console.warn('queryRenderedFeatures failed: ' + e.message);
          }
        }

        if (map && typeof map.querySourceFeatures === 'function') {
          try {
            var direct = map.querySourceFeatures('railway') || [];
            combined = combined.concat(direct);
          } catch (e) {
            console.warn('railway querySourceFeatures failed: ' + e.message);
          }
          try {
            var layerSpecific = map.querySourceFeatures('railway', { sourceLayer: 'rail_gcj_2' }) || [];
            combined = combined.concat(layerSpecific);
          } catch (e) {
            console.warn('layerSpecific railway querySourceFeatures failed: ' + e.message);
          }
        }

        var unique = [];
        var seen = {};
        combined.forEach(function(feature) {
          if (!feature || !feature.properties) return;
          var sig = (feature.id || '') + ':' + (feature.sourceLayer || '') + ':' +
            (feature.properties.name || '') + ':' + (feature.properties.ref || '') + ':' +
            (feature.properties.operator || '') + ':' + (feature.properties.railway || '');
          if (!sig || seen[sig]) return;
          seen[sig] = true;
          unique.push(feature);
        });
        return unique;
      }

      function refreshLabels() {
        try {
          var zoom = map.getZoom();
          var features = queryRailFeatures();
          var candidates = {};
          features.forEach(function(feature) {
            if (!feature || !feature.properties) return;
            var candidate = labelCandidate(feature, zoom);
            if (!candidate || !candidate.coordinate) return;
            if (!candidates[candidate.key] || candidate.priority < candidates[candidate.key].priority) {
              candidates[candidate.key] = candidate;
            }
          });

          var placed = [];
          var nextLabels = {};
          Object.keys(candidates).map(function(key) {
            candidates[key].key = key;
            return candidates[key];
          }).sort(function(a, b) {
            return b.layer - a.layer || a.priority - b.priority;
          }).forEach(function(item) {
            var point = map.project(item.coordinate);
            if (!isFinite(point.x) || !isFinite(point.y) || point.x < 0 || point.y < 0 ||
                point.x > mapRoot.clientWidth || point.y > mapRoot.clientHeight) return;
            var width = Math.max(24, item.text.length * 7 + 10);
            var box = { left: point.x - width / 2, right: point.x + width / 2,
              top: point.y - 9, bottom: point.y + 9 };
            var collides = placed.some(function(other) {
              return box.left < other.right && box.right > other.left &&
                box.top < other.bottom && box.bottom > other.top;
            });
            if (collides) return;

            var label = labels[item.key];
            if (!label) {
              label = document.createElement('div');
              label.style.cssText = 'position:absolute;transform:translate(-50%,-50%);padding:1px 4px;color:#26384d;background:rgba(255,255,255,0.82);border:1px solid rgba(70,80,90,0.35);border-radius:2px;font:11px sans-serif;white-space:nowrap;line-height:1.2;text-shadow:0 1px #fff;';
              label.textContent = item.text;
              labelContainer.appendChild(label);
            }
            label.style.left = point.x + 'px';
            label.style.top = point.y + 'px';
            nextLabels[item.key] = label;
            placed.push(box);
          });

          Object.keys(labels).forEach(function(key) {
            if (!nextLabels[key] && labels[key]) labels[key].remove();
          });
          labels = nextLabels;
        } catch (e) {
          console.warn('Android label refresh failed: ' + e.message);
        }
      }

      map.on('render', refreshLabels);
      map.on('idle', refreshLabels);
      map.on('move', refreshLabels);
      map.on('zoom', refreshLabels);
      map.on('styledata', refreshLabels);
      setTimeout(refreshLabels, 200);
      setTimeout(refreshLabels, 700);
      setTimeout(refreshLabels, 1400);
    }

    // --- Android tile proxy (Promise style per MapLibre v3 API) ---
    function _setupTileProxy() {
      var _pending = {};
      var _seq = 0;

      window.flutterTileProxyResponse = function(reqId, b64) {
        var req = _pending[reqId];
        if (!req) return;
        delete _pending[reqId];
        try {
          var bin = atob(b64);
          var len = bin.length;
          if (len === 0) {
            req.resolve({ data: new ArrayBuffer(0) });
            return;
          }
          var u8 = new Uint8Array(len);
          for (var i = 0; i < len; i++) u8[i] = bin.charCodeAt(i);
          req.resolve({ data: u8.buffer });
        } catch (e) {
          console.error('tile decode error: ' + e.message);
          req.reject(e);
        }
      };

      window.flutterTileProxyError = function(reqId, msg) {
        var req = _pending[reqId];
        if (!req) return;
        delete _pending[reqId];
        req.reject(new Error(msg || 'tile error'));
      };

      maplibregl.addProtocol('tileproxy', function(params, abortController) {
        return new Promise(function(resolve, reject) {
          var id = ++_seq;
          _pending[id] = { resolve: resolve, reject: reject };
            var url = params.url.indexOf('tileproxy://') == 0
              ? 'https://' + params.url.substring(12)
              : params.url;
            if (url.indexOf('https://') != 0) {
            delete _pending[id];
            reject(new Error('invalid tile URL: ' + params.url));
            return;
          }
          try {
            window.flutterTileProxy.postMessage(
              JSON.stringify({ reqId: id, url: url })
            );
          } catch (e) {
            delete _pending[id];
            reject(e);
          }
          if (abortController && abortController.signal) {
            abortController.signal.addEventListener('abort', function() {
              delete _pending[id];
              reject(new Error('aborted'));
            });
          }
        });
      });
      console.log('tileproxy protocol registered (promise mode)');
    }

    // --- The bundled MapLibre build is used first; CDN is only a fallback. ---
    var _cdnList = $cdnListJson;
    var _cdnIdx = 0;

    function _loadMapLibre() {
      if (typeof maplibregl !== 'undefined') {
        console.log('maplibre loaded from bundled asset');
        _initMap();
        return;
      }
      var s = document.createElement('script');
      s.src = _cdnList[_cdnIdx];
      s.onload = function() {
        console.log('maplibre loaded: ' + s.src);
        _initMap();
      };
      s.onerror = function() {
        console.warn('maplibre cdn failed: ' + s.src);
        if (++_cdnIdx < _cdnList.length) {
          _loadMapLibre();
        } else {
          console.error('all maplibre CDNs failed');
        }
      };
      document.head.appendChild(s);
    }

    if (document.readyState === 'loading') {
      document.addEventListener('DOMContentLoaded', _loadMapLibre);
    } else {
      _loadMapLibre();
    }
  </script>
</body>
</html>
''';
  }

  void _handleEvent(String jsonStr) {
    if (!mounted || jsonStr.trim().isEmpty) return;
    debugPrint('[MapLibre-event] $jsonStr');
    try {
      final event = jsonDecode(jsonStr) as Map<String, dynamic>;
      final type = event['type'] as String;
      final data = event['data'] as Map<String, dynamic>? ?? {};
      switch (type) {
        case 'ready':
          _mapReady = true;
          widget.controller?.attach(_ctrlImpl);
          _updateAll();
          break;
        case 'tap':
          widget.onMapTap?.call(
            LatLng(
              (data['lat'] as num).toDouble(),
              (data['lng'] as num).toDouble(),
            ),
          );
          break;
        case 'move':
          if (data.containsKey('zoom')) {
            _ctrlImpl._zoom = (data['zoom'] as num).toDouble();
          }
          if (data.containsKey('lat') && data.containsKey('lng')) {
            _ctrlImpl._center = {
              'lat': (data['lat'] as num).toDouble(),
              'lng': (data['lng'] as num).toDouble(),
            };
          }
          widget.onPositionChanged?.call(data['hasGesture'] == true);
          break;
        case 'markerClick':
          final id = data['id'] as String;
          for (final m in widget.markers) {
            if (m.id == id) {
              m.onTap?.call();
              break;
            }
          }
          break;
      }
    } catch (e) {
      debugPrint('MapLibre event error: $e');
    }
  }

  void _handleTileRequest(String message) {
    try {
      final data = jsonDecode(message) as Map<String, dynamic>;
      final reqId = data['reqId'] as int;
      final url = data['url'] as String;

      _tileRequests[reqId] = _TileRequest(url);

      _fetchTile(url)
          .then((resp) {
            _tileRequests.remove(reqId);
            if (resp.statusCode == 200 || resp.statusCode == 204) {
              final b64 = base64Encode(resp.bodyBytes);
              _runJs(
                "window.flutterTileProxyResponse && "
                "window.flutterTileProxyResponse($reqId, ${jsonEncode(b64)});",
              );
            } else {
              final msg = 'HTTP ${resp.statusCode} for $url';
              debugPrint('Tile request failed: $msg');
              _runJs(
                "window.flutterTileProxyError && "
                "window.flutterTileProxyError($reqId, ${jsonEncode(msg)});",
              );
            }
          })
          .catchError((e) {
            _tileRequests.remove(reqId);
            final msg = e.toString();
            debugPrint('Tile fetch error: $msg');
            _runJs(
              "window.flutterTileProxyError && "
              "window.flutterTileProxyError($reqId, ${jsonEncode(msg)});",
            );
          });
    } catch (e) {
      debugPrint('Tile proxy error: $e');
    }
  }

  Future<http.Response> _fetchTile(String url) async {
    final uri = Uri.parse(url);
    Object? lastError;
    for (var attempt = 0; attempt < 2; attempt++) {
      try {
        final response = await _tileHttpClient
            .get(
              uri,
              headers: {
                'Accept': 'application/x-protobuf,application/octet-stream',
                'Referer': 'https://maplibre.local/',
              },
            )
            .timeout(const Duration(seconds: 15));
        if (!_shouldRetryStatus(response.statusCode) || attempt == 1) {
          return response;
        }
      } catch (error) {
        lastError = error;
        if (attempt == 1) rethrow;
      }
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
    throw lastError ?? StateError('Tile request failed: $url');
  }

  bool _shouldRetryStatus(int statusCode) {
    return statusCode == 408 ||
        statusCode == 429 ||
        statusCode == 500 ||
        statusCode == 502 ||
        statusCode == 503 ||
        statusCode == 504;
  }

  http.Client get _tileHttpClient {
    if (_tileClient != null) return _tileClient!;
    if (!_isAndroid) return _tileClient = http.Client();

    final httpClient = HttpClient()
      ..connectionTimeout = const Duration(seconds: 10)
      ..idleTimeout = const Duration(seconds: 20)
      ..maxConnectionsPerHost = 6
      ..userAgent =
          'Mozilla/5.0 (Linux; Android) AppleWebKit/537.36 '
          '(KHTML, like Gecko) Chrome/120 Mobile Safari/537.36';
    return _tileClient = IOClient(httpClient);
  }

  void _runJs(String code) {
    _runWebViewJavaScript(_webController, code);
  }

  void _updateAll() {
    _updateMarkers();
    _updatePolylines();
    _updateCircles();
    _updateStationLabels();
  }

  void _updateMarkers() {
    if (!_mapReady) return;
    final json = jsonEncode(widget.markers.map((m) => m.toJson()).toList());
    _runJs(
      "window.__mapCtrl && window.__mapCtrl.setMarkers(${jsonEncode(json)});",
    );
  }

  void _updatePolylines() {
    if (!_mapReady) return;
    final json = jsonEncode(widget.polylines.map((p) => p.toJson()).toList());
    _runJs(
      "window.__mapCtrl && window.__mapCtrl.setPolylines(${jsonEncode(json)});",
    );
  }

  void _updateCircles() {
    if (!_mapReady) return;
    final json = jsonEncode(widget.circles.map((c) => c.toJson()).toList());
    _runJs(
      "window.__mapCtrl && window.__mapCtrl.setCircles(${jsonEncode(json)});",
    );
  }

  void _updateStationLabels() {
    if (!_mapReady) return;
    final json =
        jsonEncode(widget.stationLabels.map((s) => s.toJson()).toList());
    _runJs(
      "window.__mapCtrl && window.__mapCtrl.setStationLabels(${jsonEncode(json)});",
    );
  }

  @override
  void didUpdateWidget(MapLibreMapWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    _updateAll();
  }

  @override
  Widget build(BuildContext context) {
    if (_initError != null) {
      return ColoredBox(
        color: const Color(0xFFe5e5e5),
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Text(
              '地图加载失败: $_initError',
              style: const TextStyle(fontSize: 12, color: Colors.red),
            ),
          ),
        ),
      );
    }
    if (_webController == null) {
      return const ColoredBox(
        color: Color(0xFFe5e5e5),
        child: Center(
          child: SizedBox(
            width: 24,
            height: 24,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
      );
    }
    return SizedBox.expand(child: _webController!.buildWidget());
  }

  @override
  void dispose() {
    _webController?.dispose();
    widget.controller?.detach();
    _tileRequests.clear();
    _tileClient?.close();
    _tileClient = null;
    super.dispose();
  }
}

class _TileRequest {
  final String url;
  _TileRequest(this.url);
}

class _MobileControllerImpl {
  _WebViewAdapter? _webView;
  double _zoom;
  Map<String, double> _center;

  _MobileControllerImpl(this._zoom, this._center);

  void move(double lat, double lng, double zoom) {
    _center = {'lat': lat, 'lng': lng};
    _zoom = zoom;
    _runWebViewJavaScript(
      _webView,
      "window.__mapCtrl && window.__mapCtrl.moveTo($lat, $lng, $zoom);",
    );
  }

  double get zoom => _zoom;
  Map<String, double> get center => _center;
}
