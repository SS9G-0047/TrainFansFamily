import 'package:flutter/services.dart';

class NativeGalleryImage {
  final String id;
  final String uri;
  final String path;
  final String name;
  final int dateAdded;
  final int size;
  final int width;
  final int height;

  const NativeGalleryImage({
    required this.id,
    required this.uri,
    required this.path,
    required this.name,
    required this.dateAdded,
    required this.size,
    required this.width,
    required this.height,
  });

  factory NativeGalleryImage.fromMap(Map<dynamic, dynamic> map) {
    return NativeGalleryImage(
      id: map['id']?.toString() ?? '',
      uri: map['uri']?.toString() ?? '',
      path: map['path']?.toString() ?? '',
      name: map['name']?.toString() ?? '',
      dateAdded: int.tryParse(map['dateAdded']?.toString() ?? '') ?? 0,
      size: int.tryParse(map['size']?.toString() ?? '') ?? 0,
      width: int.tryParse(map['width']?.toString() ?? '') ?? 0,
      height: int.tryParse(map['height']?.toString() ?? '') ?? 0,
    );
  }
}

class NativeImageService {
  NativeImageService._();

  static final NativeImageService instance = NativeImageService._();
  static const MethodChannel _channel = MethodChannel(
    'com.example.warningapplication_1/native_images',
  );

  Future<bool> requestImagePermission() async {
    final result = await _channel.invokeMethod<bool>('requestImagePermission');
    return result ?? false;
  }

  Future<bool> requestCameraPermission() async {
    final result = await _channel.invokeMethod<bool>('requestCameraPermission');
    return result ?? false;
  }

  Future<List<NativeGalleryImage>> listGalleryImages({
    int limit = 500,
    int offset = 0,
  }) async {
    final result = await _channel.invokeMethod<List<dynamic>>(
      'listGalleryImages',
      {'limit': limit, 'offset': offset},
    );
    return (result ?? [])
        .whereType<Map<dynamic, dynamic>>()
        .map(NativeGalleryImage.fromMap)
        .toList();
  }

  Future<String?> copyImageToAppData(String uri) async {
    final result = await _channel.invokeMethod<String>(
      'copyImageToAppData',
      {'uri': uri},
    );
    return result?.trim().isEmpty == true ? null : result;
  }

  Future<String?> takePhotoToAppData() async {
    final result = await _channel.invokeMethod<String>('takePhotoToAppData');
    return result?.trim().isEmpty == true ? null : result;
  }

  Future<String?> getThumbnailPath(String uri) async {
    final result = await _channel.invokeMethod<String>(
      'getThumbnailPath',
      {'uri': uri},
    );
    return result?.trim().isEmpty == true ? null : result;
  }
}
