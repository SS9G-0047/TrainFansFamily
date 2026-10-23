import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart';
import 'package:train_fans_family/widgets/maplibre_map.dart';

import '../models/camera_position.dart';
import '../services/camera_position_service.dart';
import '../services/native_location_service.dart';
// import '../services/railway_station_service.dart';
import '../utils/map_config.dart';
import 'camera_position_page.dart';

class RailwayMapPage extends StatefulWidget {
  const RailwayMapPage({super.key});

  @override
  State<RailwayMapPage> createState() => _RailwayMapPageState();
}

class _RailwayMapPageState extends State<RailwayMapPage> {
  final CameraPositionService _cameraService = CameraPositionService.instance;
  final MapLibreController _mapController = MapLibreController();

  static const LatLng _initialCenter = LatLng(39.9042, 116.4074);

  LatLng? _myLocation;
  bool _showCameraPositions = false;
  bool _showMyLocation = false;
  bool _isLocating = false;

  // 车站搜索（暂未启用）
  // final TextEditingController _searchController = TextEditingController();
  // List<RailwayStation> _searchResults = [];
  // bool _isSearching = false;
  // List<MapStationLabel> _stationLabels = [];
  // bool _showStationSearch = false;

  @override
  void initState() {
    super.initState();

    _cameraService.addListener(_onCameraServiceChanged);
    _cameraService.load();

    final gcj02Center = wgs84ToGcj02(
      _initialCenter.latitude,
      _initialCenter.longitude,
    );

    _mapController.move(gcj02Center, 12.0);

    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await _updateMyLocation(moveToLocation: true, showError: false);
    });
  }

  @override
  void dispose() {
    _cameraService.removeListener(_onCameraServiceChanged);
    // _searchController.dispose();
    super.dispose();
  }

  void _onCameraServiceChanged() {
    if (!mounted) return;
    setState(() {});
  }

  List<MapMarker> _buildCameraMarkers() {
    if (!_showCameraPositions) return [];

    return _cameraService.positions.map((pos) {
      final gcj02 = wgs84ToGcj02(pos.latitude, pos.longitude);

      return MapMarker(
        point: gcj02,
        color: const Color(0xFF2E7D32),
        size: 24,
        id: pos.id,
        hasClick: true,
        onTap: () => _showCameraPositionInfo(pos),
      );
    }).toList();
  }

  List<MapMarker> _buildMyLocationMarker() {
    if (!_showMyLocation || _myLocation == null) return [];

    final gcj02 = wgs84ToGcj02(_myLocation!.latitude, _myLocation!.longitude);

    return [
      MapMarker(
        point: gcj02,
        color: const Color(0xFF4CAF50),
        size: 36,
        isMyLocation: true,
      ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('铁路地图浏览')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _locate,
        icon: _isLocating
            ? const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: Colors.white,
                ),
              )
            : const Icon(Icons.my_location),
        label: Text(_isLocating ? '定位中' : '定位'),
      ),
      body: Stack(
        children: [
          MapLibreMapWidget(
            initialCenter: wgs84ToGcj02(
              _initialCenter.latitude,
              _initialCenter.longitude,
            ),
            initialZoom: 12,
            markers: [..._buildCameraMarkers(), ..._buildMyLocationMarker()],
            // stationLabels: _stationLabels,
            controller: _mapController,
          ),
          // if (_showStationSearch) _buildStationSearchBar(),
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

                  await _updateMyLocation(moveToLocation: false);
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  // 车站搜索（暂未启用）
  /*
  Widget _buildStationSearchBar() {
    return Positioned(
      top: 0,
      left: 0,
      right: 0,
      child: Material(
        elevation: 4,
        color: Theme.of(context).scaffoldBackgroundColor,
        child: SafeArea(
          bottom: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _searchController,
                        decoration: InputDecoration(
                          hintText: '输入车站名称搜索',
                          prefixIcon: const Icon(Icons.search),
                          suffixIcon: _isSearching
                              ? const Padding(
                                  padding: EdgeInsets.all(10),
                                  child: SizedBox(
                                    width: 18,
                                    height: 18,
                                    child: CircularProgressIndicator(
                                        strokeWidth: 2),
                                  ),
                                )
                              : IconButton(
                                  icon: const Icon(Icons.clear),
                                  onPressed: () {
                                    _searchController.clear();
                                    setState(() {
                                      _searchResults = [];
                                      _stationLabels = [];
                                    });
                                  },
                                ),
                          border: const OutlineInputBorder(),
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 8,
                          ),
                        ),
                        onSubmitted: _searchStation,
                        textInputAction: TextInputAction.search,
                      ),
                    ),
                  ],
                ),
                if (_searchResults.isNotEmpty)
                  const SizedBox(height: 8),
                if (_searchResults.isNotEmpty)
                  SizedBox(
                    height: 120,
                    child: ListView.builder(
                      shrinkWrap: true,
                      itemCount: _searchResults.length,
                      itemBuilder: (context, index) {
                        final station = _searchResults[index];
                        return ListTile(
                          dense: true,
                          title: Text(station.name),
                          subtitle: Text(
                            '${station.latitude.toStringAsFixed(4)}, '
                            '${station.longitude.toStringAsFixed(4)}',
                          ),
                          trailing: const Icon(Icons.zoom_in),
                          onTap: () => _centerOnStation(station),
                        );
                      },
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _searchStation(String name) async {
    if (name.trim().isEmpty) {
      setState(() {
        _searchResults = [];
        _stationLabels = [];
      });
      return;
    }

    setState(() => _isSearching = true);
    try {
      final results = await RailwayStationService.searchByName(
        name.trim(),
        limit: 10,
      );

      if (!mounted) return;

      setState(() {
        _searchResults = results;
        _stationLabels = results
            .map((s) => MapStationLabel(
                  name: s.name,
                  point: s.gcj02,
                ))
            .toList();
      });
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('搜索失败：$e')),
        );
      }
    } finally {
      if (mounted) setState(() => _isSearching = false);
    }
  }

  void _centerOnStation(RailwayStation station) {
    final currentZoom = _mapController.zoom;
    _mapController.move(station.gcj02, currentZoom < 14 ? 14 : currentZoom);
  }
  */

  Future<void> _locate() async {
    await _updateMyLocation(moveToLocation: true, showError: true);
  }

  Future<void> _updateMyLocation({
    required bool moveToLocation,
    bool showError = true,
  }) async {
    if (_isLocating) return;

    setState(() => _isLocating = true);
    try {
      final location = await NativeLocationService.instance
          .getCurrentLocation();

      if (!mounted) return;
      if (location == null) {
        if (showError) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('无法获取当前位置，请授予定位权限并开启系统定位服务后重试。')),
          );
        }
        return;
      }

      final point = LatLng(location.latitude, location.longitude);
      setState(() {
        _myLocation = point;
        _showMyLocation = true;
      });

      if (moveToLocation) {
        final currentZoom = _mapController.zoom;
        final gcj02 = wgs84ToGcj02(point.latitude, point.longitude);
        _mapController.move(gcj02, currentZoom < 15 ? 15 : currentZoom);
      }
    } catch (error) {
      if (mounted && showError) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('定位失败：$error')));
      }
    } finally {
      if (mounted) setState(() => _isLocating = false);
    }
  }

  Future<void> _showCameraPositionInfo(CameraPosition position) async {
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => CameraPositionDetailPage(positionId: position.id),
      ),
    );
  }

  void _centerOnPosition(CameraPosition position) {
    final currentZoom = _mapController.zoom;

    final gcj02 = wgs84ToGcj02(position.latitude, position.longitude);

    _mapController.move(gcj02, currentZoom < 16 ? 16 : currentZoom);
  }
}
