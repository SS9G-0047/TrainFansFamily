import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart';

import 'maplibre_map_mobile.dart'
  if (dart.library.html) 'maplibre_map_web.dart'
  as platform;

const String maplibreStyleAssetPath = 'lib/assets/maplibre/map_style.json';
const String maplibreJsAssetPath = 'lib/assets/maplibre/maplibre-gl.js';
const String maplibreCssAssetPath = 'lib/assets/maplibre/maplibre-gl.css';
const String maplibreVersion = '3.6.2';
const String maplibreCdnBase = 'https://unpkg.com/maplibre-gl@$maplibreVersion/dist';
const double maplibreMinZoom = 4;
const double maplibreMaxZoom = 19;

const String kMapControllerJs = r'''
window.createMapController = function(map, viewType) {
  var markers = [];
  var polylineCount = 0;
  var hasGesture = false;
  var ready = false;
  var pendingOps = [];
  var tileCache = window.__mapTileCache = window.__mapTileCache || {};
  // No fallback to neighboring zoom levels for missing tiles; keep blank if requested tile is unavailable.

  function tileKey(tile) {
    if (!tile || !tile.tileID) return null;
    var id = tile.tileID;
    return tile.source + ':' + id.z + ':' + id.x + ':' + id.y;
  }

  map.on('tileload', function(e) {
    var key = tileKey(e.tile);
    if (key) tileCache[key] = Date.now();
  });

  map.on('tileerror', function(e) {
    var key = tileKey(e.tile);
    if (key) delete tileCache[key];
  });

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

  map.on('click', function(e) {
    sendEvent('tap', { lat: e.lngLat.lat, lng: e.lngLat.lng });
  });

  map.on('moveend', function() {
    var c = map.getCenter();
    sendEvent('move', { hasGesture: hasGesture, zoom: map.getZoom(), lat: c.lat, lng: c.lng });
    hasGesture = false;
  });

  function clearMarkers() {
    markers.forEach(function(m) { m.remove(); });
    markers = [];
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
        list.forEach(function(m) {
          var el = document.createElement('div');
          el.style.cssText = 'width:' + m.size + 'px;height:' + m.size + 'px;border-radius:50%;background:' + m.color + ';border:2px solid #fff;box-shadow:0 1px 4px rgba(0,0,0,0.4);cursor:pointer;flex-shrink:0;';
          if (m.icon) {
            el.innerHTML = '<div style="display:flex;align-items:center;justify-content:center;width:100%;height:100%;color:#fff;font-size:' + Math.floor(m.size * 0.55) + 'px;">' + m.icon + '</div>';
          }
          var marker = new maplibregl.Marker(el).setLngLat([m.lng, m.lat]).addTo(map);
          if (m.hasClick) {
            el.addEventListener('click', function(e) {
              e.stopPropagation();
              sendEvent('markerClick', { id: m.id });
            });
          }
          markers.push(marker);
        });
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
    destroy: function() {
      clearMarkers();
      clearPolylines();
      clearCircles();
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

  MapMarker({
    required this.point,
    this.color = const Color(0xFF9C27B0),
    this.size = 28,
    this.icon,
    this.id = '',
    this.hasClick = false,
    this.onTap,
  });

  Map<String, dynamic> toJson() => {
    'lat': point.latitude,
    'lng': point.longitude,
    'color': _colorToHex(color),
    'size': size,
    'icon': icon,
    'id': id,
    'hasClick': hasClick,
  };
}

class MapPolyline {
  final List<LatLng> points;
  final Color color;
  final double width;

  MapPolyline({
    required this.points,
    this.color = Colors.red,
    this.width = 3,
  });

  Map<String, dynamic> toJson() => {
    'points': points.map((p) => {'lat': p.latitude, 'lng': p.longitude}).toList(),
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

String _colorToHex(Color c) {
  final red = (c.r * 255).round().clamp(0, 255).toRadixString(16).padLeft(2, '0');
  final green = (c.g * 255).round().clamp(0, 255).toRadixString(16).padLeft(2, '0');
  final blue = (c.b * 255).round().clamp(0, 255).toRadixString(16).padLeft(2, '0');
  return '#$red$green$blue';
}

class MapLibreController {
  dynamic _impl;
  bool _isReady = false;

  void attach(dynamic impl) {
    _impl = impl;
    _isReady = true;
  }

  void detach() {
    _impl = null;
    _isReady = false;
  }

  bool get isReady => _isReady;

  void move(LatLng center, double zoom) {
    _impl?.move(center.latitude, center.longitude, zoom);
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
    this.onMapTap,
    this.onPositionChanged,
    this.controller,
  });

  @override
  State<MapLibreMapWidget> createState() => platform.createMapLibreState();
}
