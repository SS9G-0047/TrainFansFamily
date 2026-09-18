import 'package:flutter/material.dart';
import 'package:flutter_map_vector_tiles/flutter_map_vector_tiles.dart' as vt;

import '../utils/map_config.dart';

class RailwayVectorLayer extends StatefulWidget {
  const RailwayVectorLayer({super.key});

  @override
  State<RailwayVectorLayer> createState() => _RailwayVectorLayerState();
}

class _RailwayVectorLayerState extends State<RailwayVectorLayer> {
  vt.Theme? _theme;

  @override
  void initState() {
    super.initState();
    _loadTheme();
  }

  Future<void> _loadTheme() async {
    final theme = await loadRailwayTheme();
    if (mounted) setState(() => _theme = theme);
  }

  @override
  Widget build(BuildContext context) {
    final theme = _theme;
    if (theme == null) return const SizedBox.shrink();

    return vt.VectorTileLayer(
      theme: theme,
      tileProviders: vt.TileProviders({
        'rail_source': vt.NetworkVectorTileProvider(
          urlTemplate: railwayTileUrlTemplate,
          minimumZoom: 7,
          maximumZoom: 14,
        ),
      }),
      tileOffset: vt.TileOffset.none,
    );
  }
}
