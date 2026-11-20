# Flutter and the plugins register themselves by reflection.
-keep class io.flutter.** { *; }
-keep class io.flutter.plugins.** { *; }
-keep class com.google.firebase.** { *; }
-keep class com.pravera.flutter_foreground_task.** { *; }
-dontwarn io.flutter.embedding.**
