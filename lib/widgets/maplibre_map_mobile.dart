import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:latlong2/latlong.dart';
import 'package:webview_all/webview_all.dart';

import 'maplibre_map.dart';

State<MapLibreMapWidget> createMapLibreState() => _MapLibreMapMobileState();

class _MapLibreMapMobileState extends State<MapLibreMapWidget> {
  WebViewController? _webController;
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
      final styleJson = await rootBundle.loadString(maplibreStyleAssetPath);
      final maplibreJs = await rootBundle.loadString(maplibreJsAssetPath);
      final maplibreCss = await rootBundle.loadString(maplibreCssAssetPath);
      final viewId = 'maplibre-${identityHashCode(this)}';

      final controller = WebViewController();
      await controller.setJavaScriptMode(JavaScriptMode.unrestricted);
      await controller.addJavaScriptChannel(
        'flutterMapEvent',
        onMessageReceived: (m) => _handleEvent(m.message),
      );

      // Only register tile proxy channel on Android
      if (_isAndroid) {
        await controller.addJavaScriptChannel(
          'flutterTileProxy',
          onMessageReceived: (m) => _handleTileRequest(m.message),
        );
      }

      await controller.setOnConsoleMessage((msg) {
        debugPrint('[MapLibre] ${msg.message}');
      });

      await controller.loadHtmlString(
        _buildHtml(styleJson, maplibreJs, maplibreCss, viewId),
        baseUrl: 'https://maplibre.local/',
      );

      _webController = controller;
      _ctrlImpl._webView = controller;
      widget.controller?.attach(_ctrlImpl);

      if (mounted) setState(() {});
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

        var style = JSON.parse($styleLiteral);
        var _isAndroid = $isAndroid;

        if (_isAndroid && style.layers) {
          style.layers = style.layers.filter(function(layer) {
            return layer.type !== 'symbol';
          });
          console.log('Android WebView: skipped symbol layers');
        }

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
    var _cdnList = [
      'https://cdn.jsdelivr.net/npm/maplibre-gl@$maplibreVersion/dist/maplibre-gl.js',
      'https://fastly.jsdelivr.net/npm/maplibre-gl@$maplibreVersion/dist/maplibre-gl.js'
    ];
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
    try {
      final event = jsonDecode(jsonStr) as Map<String, dynamic>;
      final type = event['type'] as String;
      final data = event['data'] as Map<String, dynamic>? ?? {};
      switch (type) {
        case 'ready':
          _mapReady = true;
          _updateAll();
          break;
        case 'tap':
          widget.onMapTap?.call(LatLng(
            (data['lat'] as num).toDouble(),
            (data['lng'] as num).toDouble(),
          ));
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

      _fetchTile(url).then((resp) {
        _tileRequests.remove(reqId);
        if (resp.statusCode == 200 || resp.statusCode == 204) {
          final b64 = base64Encode(resp.bodyBytes);
          _runJs("window.flutterTileProxyResponse && "
              "window.flutterTileProxyResponse($reqId, ${jsonEncode(b64)});");
        } else {
          final msg = 'HTTP ${resp.statusCode} for $url';
          debugPrint('Tile request failed: $msg');
          _runJs("window.flutterTileProxyError && "
              "window.flutterTileProxyError($reqId, ${jsonEncode(msg)});");
        }
      }).catchError((e) {
        _tileRequests.remove(reqId);
        final msg = e.toString();
        debugPrint('Tile fetch error: $msg');
        _runJs("window.flutterTileProxyError && "
            "window.flutterTileProxyError($reqId, ${jsonEncode(msg)});");
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
        final response = await _tileHttpClient.get(uri, headers: {
          'Accept': 'application/x-protobuf,application/octet-stream',
          'Referer': 'https://maplibre.local/',
        }).timeout(const Duration(seconds: 15));
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
    _webController?.runJavaScript(code);
  }

  void _updateAll() {
    _updateMarkers();
    _updatePolylines();
    _updateCircles();
  }

  void _updateMarkers() {
    if (!_mapReady) return;
    final json = jsonEncode(widget.markers.map((m) => m.toJson()).toList());
    _runJs("window.__mapCtrl && window.__mapCtrl.setMarkers(${jsonEncode(json)});");
  }

  void _updatePolylines() {
    if (!_mapReady) return;
    final json = jsonEncode(widget.polylines.map((p) => p.toJson()).toList());
    _runJs("window.__mapCtrl && window.__mapCtrl.setPolylines(${jsonEncode(json)});");
  }

  void _updateCircles() {
    if (!_mapReady) return;
    final json = jsonEncode(widget.circles.map((c) => c.toJson()).toList());
    _runJs("window.__mapCtrl && window.__mapCtrl.setCircles(${jsonEncode(json)});");
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
            child: Text('地图加载失败: $_initError',
                style: const TextStyle(fontSize: 12, color: Colors.red)),
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
    return SizedBox.expand(
      child: WebViewWidget(controller: _webController!),
    );
  }

  @override
  void dispose() {
    _runJs("window.__mapCtrl && window.__mapCtrl.destroy();");
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
  WebViewController? _webView;
  double _zoom;
  Map<String, double> _center;

  _MobileControllerImpl(this._zoom, this._center);

  void move(double lat, double lng, double zoom) {
    _center = {'lat': lat, 'lng': lng};
    _zoom = zoom;
    _webView?.runJavaScript(
      "window.__mapCtrl && window.__mapCtrl.moveTo($lat, $lng, $zoom);",
    );
  }

  double get zoom => _zoom;
  Map<String, double> get center => _center;
}
