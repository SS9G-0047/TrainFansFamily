import 'dart:convert';
import 'dart:js' as js;
import 'dart:js_interop';
import 'dart:html' as html;
import 'dart:async';
import 'dart:ui_web' as ui_web;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:latlong2/latlong.dart';

import 'maplibre_map.dart';

State<MapLibreMapWidget> createMapLibreState() => _MapLibreMapWebState();

class _MapLibreMapWebState extends State<MapLibreMapWidget> {
  String? _viewType;
  bool _ready = false;
  String? _styleJson;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    _styleJson = await rootBundle.loadString(maplibreStyleAssetPath);
    _viewType = 'maplibre-${identityHashCode(this)}';

    _ensureControllerScript();

    if (js.context['__mapEventCallbacks'] == null) {
      js.context['__mapEventCallbacks'] = js.JsObject(js.context['Object']);
    }
    js.context['__retryInitMap'] = ((String divId, String viewType) {
      if (viewType == _viewType) _initMap(divId);
    }).toJS;
    (js.context['__mapEventCallbacks'] as js.JsObject)[_viewType!] =
      _handleJsEvent.toJS;

    ui_web.platformViewRegistry.registerViewFactory(_viewType!, (int viewId) {
      final div = html.DivElement()
        ..id = 'maplibre-div-$_viewType'
        ..style.width = '100%'
        ..style.height = '100%';
      Timer(const Duration(milliseconds: 50), () => _initMap(div.id));
      return div;
    });

    if (mounted) setState(() => _ready = true);
  }

  void _ensureControllerScript() {
    if (js.context['__mapControllerInjected'] == true) return;
    final script = html.ScriptElement()..text = kMapControllerJs;
    html.document.head!.append(script);
    js.context['__mapControllerInjected'] = true;
  }

  void _initMap(String divId) {
    js.context['__mapStyle_$_viewType'] = _styleJson;

    final code = """
      (function() {
        var container = document.getElementById('$divId');
        if (!container || typeof maplibregl === 'undefined') {
          setTimeout(function() { window.__retryInitMap && window.__retryInitMap('$divId', '$_viewType'); }, 50);
          return;
        }
        var style = JSON.parse(window['__mapStyle_$_viewType']);
        var map = new maplibregl.Map({
          container: container,
          style: style,
          center: [${widget.initialCenter.longitude}, ${widget.initialCenter.latitude}],
          zoom: ${widget.initialZoom},
          minZoom: 4,
          maxZoom: 19,
          dragRotate: false,
          touchPitch: false,
          attributionControl: false
        });
        window.__mapControllers = window.__mapControllers || {};
        window.__mapControllers['$_viewType'] = window.createMapController(map, '$_viewType');
      })();
    """;
    js.context.callMethod('eval', [code]);

    widget.controller?.attach(_WebControllerImpl(_viewType!));
  }

  js.JsObject? _getController() {
    final controllers = js.context['__mapControllers'];
    if (controllers == null) return null;
    final ctrl = (controllers as js.JsObject)[_viewType!];
    return ctrl as js.JsObject?;
  }

  void _handleJsEvent(String jsonStr) {
    if (!mounted) return;
    final event = jsonDecode(jsonStr) as Map<String, dynamic>;
    final type = event['type'] as String;
    final data = event['data'] as Map<String, dynamic>? ?? {};

    switch (type) {
      case 'ready':
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

  void _updateAll() {
    _updateMarkers();
    _updatePolylines();
    _updateCircles();
  }

  void _updateMarkers() {
    final ctrl = _getController();
    if (ctrl == null) return;
    final json = jsonEncode(widget.markers.map((m) => m.toJson()).toList());
    ctrl.callMethod('setMarkers', [json]);
  }

  void _updatePolylines() {
    final ctrl = _getController();
    if (ctrl == null) return;
    final json = jsonEncode(widget.polylines.map((p) => p.toJson()).toList());
    ctrl.callMethod('setPolylines', [json]);
  }

  void _updateCircles() {
    final ctrl = _getController();
    if (ctrl == null) return;
    final json = jsonEncode(widget.circles.map((c) => c.toJson()).toList());
    ctrl.callMethod('setCircles', [json]);
  }

  @override
  void didUpdateWidget(MapLibreMapWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    _updateAll();
  }

  @override
  Widget build(BuildContext context) {
    if (!_ready) return const ColoredBox(color: Color(0xFF1a0000));
    return HtmlElementView(viewType: _viewType!);
  }

  @override
  void dispose() {
    final ctrl = _getController();
    ctrl?.callMethod('destroy', []);
    widget.controller?.detach();
    final callbacks = js.context['__mapEventCallbacks'] as js.JsObject?;
    callbacks?.deleteProperty(_viewType!);
    super.dispose();
  }
}

class _WebControllerImpl {
  final String _viewType;
  _WebControllerImpl(this._viewType);

  js.JsObject? _get() {
    final controllers = js.context['__mapControllers'];
    if (controllers == null) return null;
    return (controllers as js.JsObject)[_viewType] as js.JsObject?;
  }

  void move(double lat, double lng, double zoom) {
    _get()?.callMethod('moveTo', [lat, lng, zoom]);
  }

  double get zoom {
    final result = _get()?.callMethod('getZoom');
    if (result is num) return result.toDouble();
    return 0.0;
  }

  Map<String, double> get center {
    final result = _get()?.callMethod('getCenter');
    if (result is js.JsObject) {
      return {
        'lat': (result['lat'] as num).toDouble(),
        'lng': (result['lng'] as num).toDouble(),
      };
    }
    return {'lat': 0.0, 'lng': 0.0};
  }
}
