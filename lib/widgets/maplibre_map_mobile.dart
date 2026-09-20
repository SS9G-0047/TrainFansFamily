import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:latlong2/latlong.dart';
import 'package:webview_flutter/webview_flutter.dart';

import 'maplibre_map.dart';

State<MapLibreMapWidget> createMapLibreState() => _MapLibreMapMobileState();

class _MapLibreMapMobileState extends State<MapLibreMapWidget> {
  WebViewController? _webController;
  bool _mapReady = false;
  late final _MobileControllerImpl _ctrlImpl;

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
    final styleJson = await rootBundle.loadString(maplibreStyleAssetPath);
    final viewType = 'maplibre-${identityHashCode(this)}';

    final html = _buildHtml(
      styleJson,
      widget.initialCenter.latitude,
      widget.initialCenter.longitude,
      widget.initialZoom,
      viewType,
    );

    final controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..addJavaScriptChannel(
        'flutterMapEvent',
        onMessageReceived: (JavaScriptMessage msg) {
          _handleEvent(msg.message);
        },
      );

    await controller.loadHtmlString(html);

    _webController = controller;
    _ctrlImpl._webView = controller;
    widget.controller?.attach(_ctrlImpl);

    if (mounted) setState(() {});
  }

  String _buildHtml(String styleJson, double lat, double lng, double zoom, String viewType) {
    final styleEncoded = jsonEncode(styleJson);
    return '''
<!DOCTYPE html>
<html>
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1, user-scalable=no">
  <link href="https://unpkg.com/maplibre-gl@4.7.1/dist/maplibre-gl.css" rel="stylesheet">
  <script src="https://unpkg.com/maplibre-gl@4.7.1/dist/maplibre-gl.js"></script>
  <style>
    html, body { margin: 0; padding: 0; overflow: hidden; background: #1a0000; height: 100%; }
    #map { position: absolute; top: 0; bottom: 0; width: 100%; }
    .maplibregl-ctrl-attribution { display: none !important; }
  </style>
</head>
<body>
  <div id="map"></div>
  <script>
    $kMapControllerJs

    window.__mapStyle = JSON.parse($styleEncoded);

    var map = new maplibregl.Map({
      container: 'map',
      style: window.__mapStyle,
      center: [$lng, $lat],
      zoom: $zoom,
      minZoom: 4,
      maxZoom: 19,
      dragRotate: false,
      touchPitch: false,
      attributionControl: false
    });

    window.__mapCtrl = window.createMapController(map, '$viewType');
  </script>
</body>
</html>
''';
  }

  void _handleEvent(String jsonStr) {
    if (!mounted) return;
    final event = jsonDecode(jsonStr) as Map<String, dynamic>;
    final type = event['type'] as String;
    final data = event['data'] as Map<String, dynamic>? ?? {};

    switch (type) {
      case 'ready':
        _mapReady = true;
        _updateAll();
        break;
      case 'tap':
        if (widget.onMapTap != null) {
          widget.onMapTap!(LatLng(
            (data['lat'] as num).toDouble(),
            (data['lng'] as num).toDouble(),
          ));
        }
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
        if (widget.onPositionChanged != null) {
          widget.onPositionChanged!(data['hasGesture'] == true);
        }
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
    if (_webController == null) {
      return const ColoredBox(color: Color(0xFF1a0000));
    }
    return WebViewWidget(controller: _webController!);
  }

  @override
  void dispose() {
    _runJs("window.__mapCtrl && window.__mapCtrl.destroy();");
    widget.controller?.detach();
    super.dispose();
  }
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
