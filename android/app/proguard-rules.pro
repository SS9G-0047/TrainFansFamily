# Flutter通用规则
-keep class io.flutter.app.** { *; }
-keep class io.flutter.plugin.**  { *; }
-keep class io.flutter.util.**  { *; }
-keep class io.flutter.view.**  { *; }
-keep class io.flutter.**  { *; }
-keep class io.flutter.plugins.**  { *; }
-dontwarn io.flutter.embedding.**

# MapLibre 必须保留，否则release地图闪退
-keep class org.maplibre.android.** { *; }
-dontwarn org.maplibre.android.**
