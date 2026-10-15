# Optional ML Kit text recognizers (only Latin is bundled)
-dontwarn com.google.mlkit.vision.text.chinese.**
-dontwarn com.google.mlkit.vision.text.devanagari.**
-dontwarn com.google.mlkit.vision.text.japanese.**
-dontwarn com.google.mlkit.vision.text.korean.**

# tflite_flutter: optional GPU delegate classes
-dontwarn org.tensorflow.lite.gpu.**
-keep class org.tensorflow.lite.** { *; }

# ML Kit classes used via reflection by the Flutter plugins
-keep class com.google.mlkit.** { *; }
-keep class com.google_mlkit_** { *; }
