import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart';

import '../config/app_endpoints.dart';

import 'maplibre_map_mobile.dart'
    if (dart.library.html) 'maplibre_map_web.dart'
    as platform;

const String maplibreStyleAssetPath = 'lib/assets/maplibre/map_style.json';
const String maplibreJsAssetPath = 'lib/assets/maplibre/maplibre-gl.js';
const String maplibreCssAssetPath = 'lib/assets/maplibre/maplibre-gl.css';
const String maplibreVersion = AppEndpoints.maplibreVersion;
const String maplibreCdnBase = AppEndpoints.maplibreCdnUnpkg;
const double maplibreMinZoom = 4;
const double maplibreMaxZoom = 18;

/// 把 map_style.json 中的占位符替换为 AppEndpoints 里的真实地址。
/// 瓦片 / 矢量切片 URL 集中在 git 忽略的 app_endpoints.dart 中。
String resolveMapStyle(String rawStyleJson) {
  var out = rawStyleJson;
  final amapTiles = AppEndpoints.amapRasterTiles;
  for (var i = 0; i < amapTiles.length && i < 4; i++) {
    out = out.replaceAll('__AMAP_TILE_${i}__', amapTiles[i]);
  }
  out = out.replaceAll('__RAILWAY_VECTOR_TILE__', AppEndpoints.railwayVectorTile);
  return out;
}

const String kMapControllerJs = r'''
window.createMapController = function(map, viewType) {
  var markers = [];
  var polylineCount = 0;
  var hasGesture = false;
  var ready = false;
  var pendingOps = [];
  function onReady(cb) {
    if (ready) cb();
    else pendingOps.push(cb);
  }

  function flushPending() {
    ready = true;
    var ops = pendingOps.slice();
    pendingOps = [];
    ops.forEach(function(op) { try { op(); } catch(e) { console.error(e); } });
  }

  function sendEvent(type, data) {
    var payload = JSON.stringify({ viewId: viewType, type: type, data: data || {} });
    if (window.flutterMapEvent && window.flutterMapEvent.postMessage) {
      window.flutterMapEvent.postMessage(payload);
    }
    if (window.__mapEventCallbacks && window.__mapEventCallbacks[viewType]) {
      window.__mapEventCallbacks[viewType](payload);
    }
  }

  function announceReady() {
    if (ready) return;
    flushPending();
    sendEvent('ready');
  }

  map.on('styledata', announceReady);
  map.on('load', announceReady);

  map.on('dragstart', function() { hasGesture = true; });
  map.on('zoomstart', function() { hasGesture = true; });
  map.on('pitchstart', function() { hasGesture = true; });

  var clickSerial = 0;
  var touchGesture = null;
  var touchTapTimer = null;
  map.on('click', function(e) {
    clickSerial++;
    if (touchTapTimer) {
      clearTimeout(touchTapTimer);
      touchTapTimer = null;
    }
    sendEvent('tap', { lat: e.lngLat.lat, lng: e.lngLat.lng });
  });

  var canvas = map.getCanvas();
  canvas.addEventListener('touchstart', function(e) {
    if (e.touches.length !== 1) {
      touchGesture = null;
      return;
    }
    var touch = e.touches[0];
    var rect = canvas.getBoundingClientRect();
    touchGesture = {
      x: touch.clientX - rect.left,
      y: touch.clientY - rect.top,
      startedAt: Date.now(),
      clickSerial: clickSerial,
      moved: false,
      multiTouch: false
    };
  }, { passive: true });
  canvas.addEventListener('touchmove', function(e) {
    if (!touchGesture) return;
    if (e.touches.length > 1) {
      touchGesture.multiTouch = true;
      return;
    }
    var touch = e.touches[0];
    var rect = canvas.getBoundingClientRect();
    var dx = touch.clientX - rect.left - touchGesture.x;
    var dy = touch.clientY - rect.top - touchGesture.y;
    if (dx * dx + dy * dy > 144) touchGesture.moved = true;
  }, { passive: true });
  canvas.addEventListener('touchend', function(e) {
    if (!touchGesture) return;
    if (e.touches.length > 0 || e.changedTouches.length !== 1) {
      touchGesture.multiTouch = true;
      return;
    }
    var gesture = touchGesture;
    touchGesture = null;
    if (gesture.moved || gesture.multiTouch || Date.now() - gesture.startedAt > 600) return;

    if (touchTapTimer) clearTimeout(touchTapTimer);
    touchTapTimer = setTimeout(function() {
      touchTapTimer = null;
      if (clickSerial !== gesture.clickSerial) return;
      var lngLat = map.unproject([gesture.x, gesture.y]);
      sendEvent('tap', { lat: lngLat.lat, lng: lngLat.lng });
    }, 200);
  }, { passive: true });
  canvas.addEventListener('touchcancel', function() {
    touchGesture = null;
    if (touchTapTimer) {
      clearTimeout(touchTapTimer);
      touchTapTimer = null;
    }
  }, { passive: true });

  map.on('moveend', function() {
    var c = map.getCenter();
    sendEvent('move', { hasGesture: hasGesture, zoom: map.getZoom(), lat: c.lat, lng: c.lng });
    hasGesture = false;
  });

  function clearMarkers() {
    markers.forEach(function(m) { m.remove(); });
    markers = [];
    var layerId = 'markers-circle-' + viewType;
    var srcId = 'markers-src-' + viewType;
    if (map.getLayer(layerId)) map.removeLayer(layerId);
    if (map.getSource(srcId)) map.removeSource(srcId);
  }

  function clearPolylines() {
    for (var i = 0; i < polylineCount; i++) {
      var sid = 'poly-' + viewType + '-' + i;
      var lid = 'poly-line-' + viewType + '-' + i;
      if (map.getLayer(lid)) map.removeLayer(lid);
      if (map.getSource(sid)) map.removeSource(sid);
    }
    polylineCount = 0;
  }

  function clearCircles() {
    var fillId = 'circles-fill-' + viewType;
    var strokeId = 'circles-stroke-' + viewType;
    var srcId = 'circles-src-' + viewType;
    if (map.getLayer(fillId)) map.removeLayer(fillId);
    if (map.getLayer(strokeId)) map.removeLayer(strokeId);
    if (map.getSource(srcId)) map.removeSource(srcId);
  }

  function clearStationLabels() {
    var dotId = 'station-dot-' + viewType;
    var labelId = 'station-label-' + viewType;
    var srcId = 'station-src-' + viewType;
    if (map.getLayer(labelId)) map.removeLayer(labelId);
    if (map.getLayer(dotId)) map.removeLayer(dotId);
    if (map.getSource(srcId)) map.removeSource(srcId);
  }

  function makeCirclePolygon(lat, lng, radiusMeters, segments) {
    segments = segments || 64;
    var coords = [];
    var latRad = lat * Math.PI / 180;
    for (var i = 0; i <= segments; i++) {
      var angle = (i / segments) * 2 * Math.PI;
      var dLat = (radiusMeters / 111320) * Math.cos(angle);
      var dLng = (radiusMeters / (111320 * Math.cos(latRad))) * Math.sin(angle);
      coords.push([lng + dLng, lat + dLat]);
    }
    return { type: 'Polygon', coordinates: [coords] };
  }

  return {
    moveTo: function(lat, lng, zoom) {
      map.jumpTo({ center: [lng, lat], zoom: zoom });
    },
    getZoom: function() {
      return map.getZoom();
    },
    getCenter: function() {
      var c = map.getCenter();
      return { lat: c.lat, lng: c.lng };
    },
    setMarkers: function(json) {
      onReady(function() {
        clearMarkers();
        var list = JSON.parse(json);
        // 分离普通 marker（用 circle 层）和"我的位置" marker（用 DOM marker）
        var dotMarkers = [];
        list.forEach(function(m, i) {
          if (m.isMyLocation) {
            // 我的位置 marker: DOM 方式，同心圆样式
            var el = document.createElement('div');
            el.style.cssText = 'width:' + m.size + 'px;height:' + m.size + 'px;position:relative;';
            var ring1 = document.createElement('div');
            ring1.style.cssText = 'position:absolute;top:0;left:0;width:100%;height:100%;border-radius:50%;border:3px solid ' + m.color + ';background:transparent;box-sizing:border-box;';
            el.appendChild(ring1);
            var ring2 = document.createElement('div');
            ring2.style.cssText = 'position:absolute;top:25%;left:25%;width:50%;height:50%;border-radius:50%;border:2px solid ' + m.color + ';background:transparent;box-sizing:border-box;opacity:0.8;';
            el.appendChild(ring2);
            var dot = document.createElement('div');
            dot.style.cssText = 'position:absolute;top:50%;left:50%;width:28%;height:28%;border-radius:50%;background:' + m.color + ';border:2px solid #fff;box-shadow:0 1px 4px rgba(0,0,0,0.4);transform:translate(-50%,-50%);';
            el.appendChild(dot);
            var marker = new maplibregl.Marker(el).setLngLat([m.lng, m.lat]).addTo(map);
            markers.push(marker);
          } else {
            dotMarkers.push(m);
          }
        });
        // 普通 marker: GeoJSON circle 层（更可靠）
        if (dotMarkers.length > 0) {
          var features = dotMarkers.map(function(m, i) {
            return {
              type: 'Feature',
              geometry: { type: 'Point', coordinates: [m.lng, m.lat] },
              properties: { color: m.color, size: m.size, index: i, hasClick: m.hasClick ? 1 : 0, id: m.id || '' }
            };
          });
          var srcId = 'markers-src-' + viewType;
          var layerId = 'markers-circle-' + viewType;
          map.addSource(srcId, {
            type: 'geojson',
            data: { type: 'FeatureCollection', features: features }
          });
          map.addLayer({
            id: layerId,
            type: 'circle',
            source: srcId,
            paint: {
              'circle-radius': ['interpolate', ['linear'], ['zoom'],
                8, ['/', ['get', 'size'], 4],
                15, ['/', ['get', 'size'], 2]
              ],
              'circle-color': ['get', 'color'],
              'circle-stroke-color': '#ffffff',
              'circle-stroke-width': 2
            }
          });
          // marker 点击事件
          map.on('click', layerId, function(e) {
            if (e.features && e.features.length > 0) {
              var props = e.features[0].properties;
              if (props.hasClick === 1) {
                sendEvent('markerClick', { id: props.id });
              }
            }
          });
          map.on('mouseenter', layerId, function() {
            map.getCanvas().style.cursor = 'pointer';
          });
          map.on('mouseleave', layerId, function() {
            map.getCanvas().style.cursor = '';
          });
        }
      });
    },
    setPolylines: function(json) {
      onReady(function() {
        clearPolylines();
        var list = JSON.parse(json);
        polylineCount = list.length;
        list.forEach(function(p, i) {
          var sid = 'poly-' + viewType + '-' + i;
          var lid = 'poly-line-' + viewType + '-' + i;
          var coords = p.points.map(function(pt) { return [pt.lng, pt.lat]; });
          map.addSource(sid, {
            type: 'geojson',
            data: { type: 'Feature', geometry: { type: 'LineString', coordinates: coords }, properties: {} }
          });
          map.addLayer({
            id: lid,
            type: 'line',
            source: sid,
            layout: { 'line-join': 'round', 'line-cap': 'round' },
            paint: { 'line-color': p.color, 'line-width': p.width }
          });
        });
      });
    },
    setCircles: function(json) {
      onReady(function() {
        clearCircles();
        var list = JSON.parse(json);
        if (list.length === 0) return;
        var features = list.map(function(c, i) {
          return {
            type: 'Feature',
            geometry: makeCirclePolygon(c.lat, c.lng, c.radius),
            properties: { color: c.color, fillColor: c.fillColor, index: i }
          };
        });
        var srcId = 'circles-src-' + viewType;
        var fillId = 'circles-fill-' + viewType;
        var strokeId = 'circles-stroke-' + viewType;
        map.addSource(srcId, {
          type: 'geojson',
          data: { type: 'FeatureCollection', features: features }
        });
        map.addLayer({
          id: fillId,
          type: 'fill',
          source: srcId,
          paint: {
            'fill-color': ['get', 'fillColor'],
            'fill-opacity': 0.25
          }
        });
        map.addLayer({
          id: strokeId,
          type: 'line',
          source: srcId,
          paint: {
            'line-color': ['get', 'color'],
            'line-width': 2,
            'line-opacity': 0.8
          }
        });
      });
    },
    setStationLabels: function(json) {
      onReady(function() {
        clearStationLabels();
        var list = JSON.parse(json);
        if (list.length === 0) return;
        var features = list.map(function(s, i) {
          return {
            type: 'Feature',
            geometry: { type: 'Point', coordinates: [s.lng, s.lat] },
            properties: { name: s.name, index: i }
          };
        });
        var srcId = 'station-src-' + viewType;
        var dotId = 'station-dot-' + viewType;
        var labelId = 'station-label-' + viewType;
        map.addSource(srcId, {
          type: 'geojson',
          data: { type: 'FeatureCollection', features: features }
        });
        map.addLayer({
          id: dotId,
          type: 'circle',
          source: srcId,
          paint: {
            'circle-radius': 5,
            'circle-color': '#C62828',
            'circle-stroke-color': '#ffffff',
            'circle-stroke-width': 2
          }
        });
        map.addLayer({
          id: labelId,
          type: 'symbol',
          source: srcId,
          layout: {
            'text-field': ['get', 'name'],
            'text-font': ['Open Sans Regular', 'Arial Unicode MS Regular'],
            'text-size': 14,
            'text-offset': [0, -1.2],
            'text-anchor': 'bottom',
            'text-allow-overlap': true,
            'text-ignore-placement': true,
            'text-keep-upright': true
          },
          paint: {
            'text-color': '#C62828',
            'text-halo-color': 'rgba(255,255,255,0.95)',
            'text-halo-width': 2.5
          }
        });
      });
    },
    destroy: function() {
      if (touchTapTimer) clearTimeout(touchTapTimer);
      clearMarkers();
      clearPolylines();
      clearCircles();
      clearStationLabels();
      map.remove();
    }
  };
};
''';

class MapMarker {
  final LatLng point;
  final Color color;
  final double size;
  final String? icon;
  final String id;
  final bool hasClick;
  final VoidCallback? onTap;
  final bool isMyLocation;

  MapMarker({
    required this.point,
    this.color = const Color(0xFF9C27B0),
    this.size = 28,
    this.icon,
    this.id = '',
    this.hasClick = false,
    this.onTap,
    this.isMyLocation = false,
  });

  Map<String, dynamic> toJson() => {
    'lat': point.latitude,
    'lng': point.longitude,
    'color': _colorToHex(color),
    'size': size,
    'icon': icon,
    'id': id,
    'hasClick': hasClick,
    'isMyLocation': isMyLocation,
  };
}

class MapPolyline {
  final List<LatLng> points;
  final Color color;
  final double width;

  MapPolyline({required this.points, this.color = Colors.red, this.width = 3});

  Map<String, dynamic> toJson() => {
    'points': points
        .map((p) => {'lat': p.latitude, 'lng': p.longitude})
        .toList(),
    'color': _colorToHex(color),
    'width': width,
  };
}

class MapCircle {
  final LatLng point;
  final double radius;
  final Color color;
  final Color fillColor;

  MapCircle({
    required this.point,
    required this.radius,
    this.color = Colors.red,
    this.fillColor = const Color(0x33FF0000),
  });

  Map<String, dynamic> toJson() => {
    'lat': point.latitude,
    'lng': point.longitude,
    'radius': radius,
    'color': _colorToHex(color),
    'fillColor': _colorToHex(fillColor),
  };
}

class MapStationLabel {
  final String name;
  final LatLng point;

  MapStationLabel({required this.name, required this.point});

  Map<String, dynamic> toJson() => {
    'name': name,
    'lat': point.latitude,
    'lng': point.longitude,
  };
}

String _colorToHex(Color c) {
  final red = (c.r * 255)
      .round()
      .clamp(0, 255)
      .toRadixString(16)
      .padLeft(2, '0');
  final green = (c.g * 255)
      .round()
      .clamp(0, 255)
      .toRadixString(16)
      .padLeft(2, '0');
  final blue = (c.b * 255)
      .round()
      .clamp(0, 255)
      .toRadixString(16)
      .padLeft(2, '0');
  return '#$red$green$blue';
}

class _QueuedMapMove {
  final LatLng center;
  final double zoom;

  const _QueuedMapMove(this.center, this.zoom);
}

class MapLibreController {
  dynamic _impl;
  bool _isReady = false;
  final List<_QueuedMapMove> _pendingMoves = [];

  void attach(dynamic impl) {
    _impl = impl;
    _isReady = true;
    _flushPendingMoves();
  }

  void detach() {
    _impl = null;
    _isReady = false;
  }

  bool get isReady => _isReady;

  void move(LatLng center, double zoom) {
    final move = _QueuedMapMove(center, zoom);
    if (!_isReady || _impl == null) {
      _pendingMoves.add(move);
      return;
    }
    _impl.move(center.latitude, center.longitude, zoom);
  }

  void _flushPendingMoves() {
    if (!_isReady || _impl == null || _pendingMoves.isEmpty) return;
    final pending = List<_QueuedMapMove>.from(_pendingMoves);
    _pendingMoves.clear();
    for (final move in pending) {
      _impl.move(move.center.latitude, move.center.longitude, move.zoom);
    }
  }

  double get zoom {
    final z = _impl?.zoom;
    return z is double ? z : (z is int ? z.toDouble() : 0.0);
  }

  LatLng get center {
    final c = _impl?.center;
    if (c == null) return LatLng(0, 0);
    return LatLng(c['lat'] as double, c['lng'] as double);
  }
}

typedef MapTapCallback = void Function(LatLng point);
typedef MapMoveCallback = void Function(bool hasGesture);

class MapLibreMapWidget extends StatefulWidget {
  final LatLng initialCenter;
  final double initialZoom;
  final List<MapMarker> markers;
  final List<MapPolyline> polylines;
  final List<MapCircle> circles;
  final List<MapStationLabel> stationLabels;
  final MapTapCallback? onMapTap;
  final MapMoveCallback? onPositionChanged;
  final MapLibreController? controller;

  const MapLibreMapWidget({
    super.key,
    required this.initialCenter,
    required this.initialZoom,
    this.markers = const [],
    this.polylines = const [],
    this.circles = const [],
    this.stationLabels = const [],
    this.onMapTap,
    this.onPositionChanged,
    this.controller,
  });

  @override
  State<MapLibreMapWidget> createState() => platform.createMapLibreState();
}
