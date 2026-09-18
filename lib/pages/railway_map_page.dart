import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../models/camera_position.dart';
import '../services/camera_position_service.dart';
import '../services/native_location_service.dart';
import '../utils/map_config.dart';
import '../widgets/railway_vector_layer.dart';

class RailwayMapPage extends StatefulWidget {
  const RailwayMapPage({super.key});

  @override
  State<RailwayMapPage> createState() => _RailwayMapPageState();
}

class _RailwayMapPageState extends State<RailwayMapPage> {
  final CameraPositionService _cameraService =
      CameraPositionService.instance;
  final MapController _mapController = MapController();

  static const LatLng _initialCenter = LatLng(39.9042, 116.4074);

  LatLng? _myLocation;
  bool _showCameraPositions = false;
  bool _showMyLocation = false;

  late final MapOptions _mapOptions;

  @override
  void initState() {
    super.initState();

    _cameraService.addListener(_onCameraServiceChanged);
    _cameraService.load();

    final gcj02Center =
        wgs84ToGcj02(_initialCenter.latitude, _initialCenter.longitude);

    _mapOptions = MapOptions(
      initialCenter: gcj02Center,
      initialZoom: 12.0,
      minZoom: 4.0,
      maxZoom: 14.0,
      interactionOptions: InteractionOptions(
        flags: InteractiveFlag.all & ~InteractiveFlag.rotate,
      ),
    );
  }

  @override
  void dispose() {
    _cameraService.removeListener(_onCameraServiceChanged);
    _mapController.dispose();
    super.dispose();
  }

  void _onCameraServiceChanged() {
    if (!mounted) return;
    setState(() {});
  }

  List<Marker> _buildCameraMarkers() {
    if (!_showCameraPositions) return [];

    return _cameraService.positions.map((pos) {
      final gcj02 =
          wgs84ToGcj02(pos.latitude, pos.longitude);

      return Marker(
        point: gcj02,
        width: 28,
        height: 28,
        child: GestureDetector(
          onTap: () => _showCameraPositionInfo(pos),
          child: Container(
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: const Color(0xFF673AB7),
              border: Border.all(color: Colors.white, width: 2),
              boxShadow: const [
                BoxShadow(
                  color: Colors.black26,
                  blurRadius: 3,
                ),
              ],
            ),
            child: const Icon(
              Icons.camera_alt,
              color: Colors.white,
              size: 16,
            ),
          ),
        ),
      );
    }).toList();
  }

  List<Marker> _buildMyLocationMarker() {
    if (!_showMyLocation || _myLocation == null) return [];

    final gcj02 =
        wgs84ToGcj02(_myLocation!.latitude, _myLocation!.longitude);

    return [
      Marker(
        point: gcj02,
        width: 32,
        height: 32,
        child: Container(
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: const Color(0xFF2196F3).withValues(alpha: 0.4),
            border: Border.all(
              color: Colors.white,
              width: 3,
            ),
          ),
        ),
      ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('铁路地图浏览'),
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _locate,
        icon: const Icon(Icons.my_location),
        label: const Text('定位'),
      ),
      body: Stack(
        children: [
          FlutterMap(
            mapController: _mapController,
            options: _mapOptions,
            children: [
              TileLayer(
                urlTemplate: amapTileUrlTemplate,
                subdomains: amapSubdomains,
                maxZoom: 18,
                maxNativeZoom: 18,
                tileBuilder: (context, tile, tileImage) =>
                    ColorFiltered(
                  colorFilter:
                      const ColorFilter.matrix(
                    amapGrayscaleMatrix,
                  ),
                  child: tile,
                ),
              ),
              RailwayVectorLayer(),
              MarkerLayer(
                markers: [
                  ..._buildCameraMarkers(),
                  ..._buildMyLocationMarker(),
                ],
              ),
            ],
          ),
          Align(
            alignment: Alignment.topRight,
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: _buildMapControls(),
            ),
          ),
          const MapAttribution(),
        ],
      ),
    );
  }

  Widget _buildMapControls() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: SizedBox(
          width: 190,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SwitchListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                title: const Text('显示机位'),
                value: _showCameraPositions,
                onChanged: (value) {
                  setState(() {
                    _showCameraPositions = value;
                  });
                },
              ),
              SwitchListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                title: const Text('显示自己位置'),
                value: _showMyLocation,
                onChanged: (value) async {
                  if (!value) {
                    setState(() {
                      _showMyLocation = false;
                    });
                    return;
                  }

                  await _updateMyLocation(
                    moveToLocation: false,
                  );
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _locate() async {
    await _updateMyLocation(moveToLocation: true);
  }

  Future<void> _updateMyLocation({
    required bool moveToLocation,
  }) async {
    final location =
        await NativeLocationService.instance.getCurrentLocation();

    if (location == null || !mounted) return;

    final point =
        LatLng(location.latitude, location.longitude);

    setState(() {
      _myLocation = point;
      _showMyLocation = true;
    });

    if (moveToLocation) {
      final currentZoom =
          _mapController.camera.zoom;

      final gcj02 = wgs84ToGcj02(
        point.latitude,
        point.longitude,
      );

      _mapController.move(
        gcj02,
        currentZoom < 15 ? 15 : currentZoom,
      );
    }
  }

  Future<void> _showCameraPositionInfo(
    CameraPosition position,
  ) async {
    final groupName =
        _cameraService.groupDisplayName(position.groupId);

    await showModalBottomSheet<void>(
      context: context,
      builder: (context) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(
              16,
              12,
              16,
              16,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment:
                  CrossAxisAlignment.start,
              children: [
                Text(
                  position.name,
                  style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 8),
                Text('地区组：$groupName'),
                Text(
                  '坐标：'
                  '${position.latitude.toStringAsFixed(6)}, '
                  '${position.longitude.toStringAsFixed(6)}',
                ),
                const SizedBox(height: 12),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    onPressed: () {
                      Navigator.pop(context);
                      _centerOnPosition(position);
                    },
                    icon: const Icon(
                      Icons.center_focus_strong,
                    ),
                    label: const Text('居中显示'),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  void _centerOnPosition(
    CameraPosition position,
  ) {
    final currentZoom =
        _mapController.camera.zoom;

    final gcj02 = wgs84ToGcj02(
      position.latitude,
      position.longitude,
    );

    _mapController.move(
      gcj02,
      currentZoom < 16 ? 16 : currentZoom,
    );
  }
}
