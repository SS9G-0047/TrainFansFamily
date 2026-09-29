import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:latlong2/latlong.dart';
// Android 使用官方 webview_flutter，Windows 使用 webview_all
import 'package:webview_flutter/webview_flutter.dart' as wv_flutter;
import 'package:webview_all/webview_all.dart' as wv_all;

import 'maplibre_map.dart';

State<MapLibreMapWidget> createMapLibreState() => _MapLibreMapMobileState();

abstract class _WebViewAdapter {
  Future<void> setJavaScriptMode(bool unrestricted);
  Future<void> addJavaScriptChannel(String name, {required void Function(String) onMessageReceived});
  Future<void> setOnConsoleMessage(void Function(dynamic) callback);
  Future<void> loadHtmlString(String html, {String? baseUrl});
  Future<void> runJavaScript(String code);
  Future<void> clearCache();
  Widget buildWidget();
  void dispose();
}

class _WebViewFlutterAdapter implements _WebViewAdapter {
  final wv_flutter.WebViewController controller;

  _WebViewFlutterAdapter() : controller = wv_flutter.WebViewController();

  @override
  Future<void> setJavaScriptMode(bool unrestricted) async {
    await controller.setJavaScriptMode(
      unrestricted ? wv_flutter.JavaScriptMode.unrestricted : wv_flutter.JavaScriptMode.disabled,
    );
  }

  @override
  Future<void> addJavaScriptChannel(String name, {required void Function(String) onMessageReceived}) async {
    await controller.addJavaScriptChannel(
      name,
      onMessageReceived: (msg) => onMessageReceived(msg.message),
    );
  }

  @override
  Future<void> setOnConsoleMessage(void Function(dynamic) callback) async {
    await controller.setOnConsoleMessage((msg) => callback(msg));
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
    await controller.clearCache();
  }

  @override
  Widget buildWidget() => wv_flutter.WebViewWidget(controller: controller);

  @override
  void dispose() {}
}

class _WebViewAllAdapter implements _WebViewAdapter {
  final wv_all.WebViewController controller;

  _WebViewAllAdapter() : controller = wv_all.WebViewController();

  @override
  Future<void> setJavaScriptMode(bool unrestricted) async {
    await controller.setJavaScriptMode(
      unrestricted ? wv_all.JavaScriptMode.unrestricted : wv_all.JavaScriptMode.disabled,
    );
  }

  @override
  Future<void> addJavaScriptChannel(String name, {required void Function(String) onMessageReceived}) async {
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
      final styleJson = await rootBundle.loadString(maplibreStyleAssetPath);
      final maplibreJs = await rootBundle.loadString(maplibreJsAssetPath);
      final maplibreCss = await rootBundle.loadString(maplibreCssAssetPath);
      final viewId = 'maplibre-${identityHashCode(this)}';

      // Android 用 webview_flutter，Windows 用 webview_all
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

      await controller.setOnConsoleMessage((msg) {
        debugPrint('[MapLibre] ${msg.message}');
      });

      await controller.loadHtmlString(
        _buildHtml(styleJson, maplibreJs, maplibreCss, viewId),
        baseUrl: 'https://maplibre.local/',
      );

      _webController = controller;
      _ctrlImpl._webView = controller;
      // Don't attach controller yet — wait for JS 'ready' event
      // so that move() calls work when the map is actually loaded.

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
    // === 全局错误捕获：打印完整堆栈 ===
    window.addEventListener('error', function(e) {
      var err = e.error || {};
      console.error('[GLOBAL-ERROR] ' + e.message +
        '\n  filename=' + e.filename +
        '\n  lineno=' + e.lineno +
        '\n  colno=' + e.colno +
        '\n  stack=' + (err.stack || '(no stack)'));
    });

    // === Android WebView getImageData 兼容补丁 ===
    (function() {
      console.log('[PATCH] Applying getImageData patch...');
      var proto = CanvasRenderingContext2D.prototype;
      var orig = proto.getImageData;
      if (!orig) {
        console.error('[PATCH] getImageData not found on prototype');
        return;
      }
      console.log('[PATCH] Original getImageData: ' + typeof orig);

      proto.getImageData = function(sx, sy, sw, sh) {
        var fx = Math.floor(Number(sx) || 0);
        var fy = Math.floor(Number(sy) || 0);
        var fw = Math.floor(Math.max(1, Number(sw) || 1));
        var fh = Math.floor(Math.max(1, Number(sh) || 1));
        try {
          return orig.call(this, fx, fy, fw, fh);
        } catch(e1) {
          // 如果整数参数也失败，尝试返回空 ImageData
          console.warn('[PATCH] getImageData still failed: ' + e1.message +
            ' args=(' + sx + ',' + sy + ',' + sw + ',' + sh + ')' +
            ' floor=(' + fx + ',' + fy + ',' + fw + ',' + fh + ')');
          try {
            return this.createImageData(fw, fh);
          } catch(e2) {
            return orig.call(this, 0, 0, 1, 1);
          }
        }
      };

      // 同样修补 putImageData
      var origPut = proto.putImageData;
      if (origPut) {
        proto.putImageData = function(imageData, dx, dy) {
          return origPut.call(this, imageData, Math.floor(dx || 0), Math.floor(dy || 0));
        };
      }

      // 测试补丁是否生效
      try {
        var testCanvas = document.createElement('canvas');
        testCanvas.width = 10;
        testCanvas.height = 10;
        var testCtx = testCanvas.getContext('2d');
        var imgData = testCtx.getImageData(0.5, 0.5, 2.7, 2.3);
        console.log('[PATCH] Test getImageData(0.5,0.5,2.7,2.3) -> width=' + imgData.width + ' height=' + imgData.height + ' OK');
      } catch(e) {
        console.error('[PATCH] Test failed: ' + e.message);
      }
    })();
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

        // === Android 二次补丁：确保 getImageData 参数整数化 ===
        if (_isAndroid) {
          (function() {
            console.log('[PATCH-inside] Applying inside _initMap...');
            var proto = CanvasRenderingContext2D.prototype;
            var origGet = proto.getImageData;
            if (origGet && !origGet.__patched) {
              proto.getImageData = function(sx, sy, sw, sh) {
                try {
                  return origGet.call(
                    this,
                    parseInt(sx) || 0,
                    parseInt(sy) || 0,
                    Math.max(1, parseInt(sw) || 1),
                    Math.max(1, parseInt(sh) || 1)
                  );
                } catch(e) {
                  console.warn('[PATCH-inside] getImageData fallback: ' + e.message);
                  try {
                    return this.createImageData(Math.max(1, parseInt(sw) || 1), Math.max(1, parseInt(sh) || 1));
                  } catch(e2) {
                    return origGet.call(this, 0, 0, 1, 1);
                  }
                }
              };
              proto.getImageData.__patched = true;
              console.log('[PATCH-inside] getImageData patched');
            }
            // 也拦截 getContext，确保新 canvas 也有补丁
            var origGetContext = HTMLCanvasElement.prototype.getContext;
            if (origGetContext && !origGetContext.__patched) {
              HTMLCanvasElement.prototype.getContext = function(type, attrs) {
                var ctx = origGetContext.call(this, type, attrs);
                if (ctx && type === '2d' && ctx.getImageData && !ctx.getImageData.__patched) {
                  var orig = ctx.getImageData.bind(ctx);
                  ctx.getImageData = function(sx, sy, sw, sh) {
                    try {
                      return orig(
                        parseInt(sx) || 0,
                        parseInt(sy) || 0,
                        Math.max(1, parseInt(sw) || 1),
                        Math.max(1, parseInt(sh) || 1)
                      );
                    } catch(e) {
                      try { return ctx.createImageData(Math.max(1, parseInt(sw) || 1), Math.max(1, parseInt(sh) || 1)); }
                      catch(e2) { return orig(0, 0, 1, 1); }
                    }
                  };
                  ctx.getImageData.__patched = true;
                }
                return ctx;
              };
              HTMLCanvasElement.prototype.getContext.__patched = true;
              console.log('[PATCH-inside] getContext intercepted');
            }
          })();
        }

        if (_isAndroid && style.layers) {
          // Android 兼容性处理：
          // 1. 移除 glyphs（字形 PBF 在 Android WebView 上导致 mismatched image size 错误）
          delete style.glyphs;
          // 2. 移除所有 symbol 图层，避免触发字形渲染
          style.layers = style.layers.filter(function(layer) {
            return layer.type !== 'symbol';
          });
          // 3. 移除所有图层的 line-sort-key（避免兼容性问题）
          style.layers.forEach(function(layer) {
            if (layer.layout && layer.layout['line-sort-key'] !== undefined) {
              delete layer.layout['line-sort-key'];
            }
          });
          console.log('Android: glyphs and symbol layers removed for compatibility');
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

        // 测试模式：用最简单的 symbol 图层验证沿线文字。
        // 如失败，取消注释恢复 DOM label。
        // if (_isAndroid) {
        //   _setupAndroidRailLabels(map);
        // }

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

    function _setupAndroidRailLabels(map) {
      var labels = {};
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

      function pickLabel(properties) {
        var props = properties || {};
        return toText(props.name) || toText(props['name:zh']) || toText(props['name_zh']) ||
          toText(props['name:en']) || toText(props.ref) || toText(props.operator) ||
          toText(props.route) || toText(props.network) || toText(props.usage) || '';
      }

      function midpointFromGeometry(geometry) {
        if (!geometry || !geometry.coordinates) return null;
        var coords = geometry.coordinates;
        if (geometry.type === 'MultiLineString') {
          var chosen = coords[Math.floor(coords.length / 2)] || [];
          coords = chosen;
        }
        if (!Array.isArray(coords) || coords.length === 0) return null;
        var point = coords[Math.floor(coords.length / 2)];
        if (!Array.isArray(point) || typeof point[0] !== 'number') return null;
        return point;
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
          var features = queryRailFeatures();
          if (!features.length) {
            return;
          }

          var visible = {};
          features.forEach(function(feature) {
            if (!feature || !feature.properties) return;
            var text = pickLabel(feature.properties);
            if (!text) return;
            var coordinate = midpointFromGeometry(feature.geometry);
            if (!coordinate) return;
            var key = text + ':' + coordinate[0].toFixed(4) + ':' + coordinate[1].toFixed(4);
            if (visible[key]) return;
            visible[key] = { text: text, coordinate: coordinate };
          });

          Object.keys(labels).forEach(function(key) {
            if (!visible[key]) {
              if (labels[key]) {
                labels[key].remove();
              }
              delete labels[key];
            }
          });

          Object.keys(visible).slice(0, 200).forEach(function(key) {
            var item = visible[key];
            var point = map.project(item.coordinate);
            var label = labels[key];
            if (!label) {
              label = document.createElement('div');
              label.style.cssText = 'position:absolute;transform:translate(-50%,-50%);padding:1px 4px;color:#26384d;background:rgba(255,255,255,0.82);border:1px solid rgba(70,80,90,0.35);border-radius:2px;font:11px sans-serif;white-space:nowrap;line-height:1.2;text-shadow:0 1px #fff;';
              label.textContent = item.text;
              labelContainer.appendChild(label);
              labels[key] = label;
            }
            label.style.left = point.x + 'px';
            label.style.top = point.y + 'px';
          });
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
          widget.controller?.attach(_ctrlImpl);
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
      child: _webController!.buildWidget(),
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
  _WebViewAdapter? _webView;
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
