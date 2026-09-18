import 'package:flutter/material.dart';

import '../services/native_image_service.dart';
import '../utils/cross_file_image.dart';

class NativeImagePickerPage extends StatefulWidget {
  const NativeImagePickerPage({super.key});

  @override
  State<NativeImagePickerPage> createState() => _NativeImagePickerPageState();
}

class _NativeImagePickerPageState extends State<NativeImagePickerPage> {
  final NativeImageService _service = NativeImageService.instance;
  final Map<String, String> _thumbnailCache = {};
  final Set<String> _loadingUris = {};
  List<NativeGalleryImage> _images = [];
  bool _loading = true;
  bool _copying = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadImages();
  }

  Future<void> _loadImages() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final granted = await _service.requestImagePermission();
      if (!granted) {
        setState(() {
          _images = [];
          _error = "没有相册读取权限，请授权后重试。";
          _loading = false;
        });
        return;
      }
      final images = await _service.listGalleryImages();
      if (!mounted) return;
      setState(() {
        _images = images;
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = "读取相册失败：$error";
        _loading = false;
      });
    }
  }

  Future<void> _loadThumbnail(NativeGalleryImage image) async {
    if (_thumbnailCache.containsKey(image.uri) ||
        _loadingUris.contains(image.uri)) {
      return;
    }
    _loadingUris.add(image.uri);
    try {
      final path = await _service.getThumbnailPath(image.uri);
      if (!mounted) return;
      setState(() {
        _thumbnailCache[image.uri] = path ?? '';
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _thumbnailCache[image.uri] = '';
      });
    } finally {
      _loadingUris.remove(image.uri);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text("选择机位图片"),
        actions: [
          IconButton(
            tooltip: "刷新",
            onPressed: _loading || _copying ? null : _loadImages,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: Stack(
        children: [
          _buildBody(),
          if (_copying)
            Container(
              color: Colors.black26,
              child: const Center(
                child: Card(
                  child: Padding(
                    padding: EdgeInsets.all(18),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        CircularProgressIndicator(),
                        SizedBox(height: 12),
                        Text("正在保存到应用数据..."),
                      ],
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildBody() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    final error = _error;
    if (error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.photo_library_outlined, size: 48),
              const SizedBox(height: 12),
              Text(error, textAlign: TextAlign.center),
              const SizedBox(height: 12),
              FilledButton(onPressed: _loadImages, child: const Text("重试")),
            ],
          ),
        ),
      );
    }
    if (_images.isEmpty) {
      return const Center(child: Text("相册中没有可用图片"));
    }
    return GridView.builder(
      padding: const EdgeInsets.all(8),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 3,
        crossAxisSpacing: 6,
        mainAxisSpacing: 6,
      ),
      itemCount: _images.length,
      itemBuilder: (context, index) {
        final image = _images[index];
        return _buildImageTile(image);
      },
    );
  }

  Widget _buildImageTile(NativeGalleryImage image) {
    return InkWell(
      onTap: _copying ? null : () => _selectImage(image),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: Stack(
          fit: StackFit.expand,
          children: [
            _buildThumbnail(image),
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 3),
                color: Colors.black45,
                child: Text(
                  image.name.isEmpty ? "图片" : image.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: Colors.white, fontSize: 11),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildThumbnail(NativeGalleryImage image) {
    final cachedPath = _thumbnailCache[image.uri];

    // 已有缩略图路径且非空
    if (cachedPath != null && cachedPath.isNotEmpty) {
      return crossFileImage(
        cachedPath,
        fit: BoxFit.cover,
        errorBuilder: (_, _, _) => _placeholder(),
      );
    }

    // 已确认无缩略图
    if (cachedPath == '') {
      return _placeholder();
    }

    // 尚未加载，触发异步获取
    _loadThumbnail(image);
    return _placeholder();
  }

  Widget _placeholder() {
    return Container(
      color: Colors.black12,
      child: const Center(
        child: SizedBox(
          width: 20,
          height: 20,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      ),
    );
  }

  Future<void> _selectImage(NativeGalleryImage image) async {
    setState(() => _copying = true);
    try {
      final path = await _service.copyImageToAppData(image.uri);
      if (!mounted) return;
      if (path == null || path.isEmpty) {
        setState(() => _copying = false);
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text("保存图片失败")));
        return;
      }
      Navigator.pop(context, path);
    } catch (error) {
      if (!mounted) return;
      setState(() => _copying = false);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text("保存图片失败：$error")));
    }
  }
}
