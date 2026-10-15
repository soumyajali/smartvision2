package com.example.smart_vision

import android.app.Activity
import android.content.ActivityNotFoundException
import android.content.Intent
import android.graphics.Bitmap
import android.media.MediaMetadataRetriever
import android.speech.RecognizerIntent
import android.speech.SpeechRecognizer
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream
import java.util.concurrent.Executors

class MainActivity : FlutterActivity() {
    private val frameExecutor = Executors.newSingleThreadExecutor()
    private var pendingSpeechResult: MethodChannel.Result? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "com.smartvision/video_frames",
        ).setMethodCallHandler { call, result ->
            if (call.method != "getFrame") {
                result.notImplemented()
                return@setMethodCallHandler
            }

            val path = call.argument<String>("path")
            val timeMs = call.argument<Number>("timeMs")?.toLong()
            val maxWidth = call.argument<Number>("maxWidth")?.toInt() ?: 640
            val quality = call.argument<Number>("quality")?.toInt() ?: 75
            if (path.isNullOrBlank() || timeMs == null || maxWidth <= 0 ||
                quality !in 0..100
            ) {
                result.error("invalid_arguments", "Invalid video frame request.", null)
                return@setMethodCallHandler
            }

            frameExecutor.execute {
                val retriever = MediaMetadataRetriever()
                try {
                    retriever.setDataSource(path)
                    val frame = retriever.getFrameAtTime(
                        timeMs * 1000,
                        MediaMetadataRetriever.OPTION_CLOSEST,
                    )
                    if (frame == null) {
                        runOnUiThread { result.success(null) }
                        return@execute
                    }
                    val resized = resizeFrame(frame, maxWidth)
                    val output = ByteArrayOutputStream()
                    resized.compress(Bitmap.CompressFormat.JPEG, quality, output)
                    if (resized !== frame) resized.recycle()
                    frame.recycle()
                    runOnUiThread { result.success(output.toByteArray()) }
                } catch (error: Exception) {
                    runOnUiThread {
                        result.error(
                            "video_frame_error",
                            "Could not extract video frame: ${error.message}",
                            null,
                        )
                    }
                } finally {
                    retriever.release()
                }
            }
        }

        // Voice Assistant speech-to-text. Uses the system speech recognizer
        // dialog (RecognizerIntent), which records audio itself, so the app
        // does not need to request the microphone permission.
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "com.smartvision/speech",
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "isAvailable" -> result.success(isSpeechRecognitionAvailable())
                "listen" -> {
                    if (pendingSpeechResult != null) {
                        result.error("busy", "Speech recognition is already running.", null)
                        return@setMethodCallHandler
                    }
                    val intent = Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH).apply {
                        putExtra(
                            RecognizerIntent.EXTRA_LANGUAGE_MODEL,
                            RecognizerIntent.LANGUAGE_MODEL_FREE_FORM,
                        )
                        putExtra(
                            RecognizerIntent.EXTRA_PROMPT,
                            call.argument<String>("prompt") ?: "Ask SmartVision",
                        )
                        call.argument<String>("language")?.let {
                            putExtra(RecognizerIntent.EXTRA_LANGUAGE, it)
                        }
                        putExtra(RecognizerIntent.EXTRA_MAX_RESULTS, 1)
                    }
                    try {
                        pendingSpeechResult = result
                        startActivityForResult(intent, SPEECH_REQUEST_CODE)
                    } catch (error: ActivityNotFoundException) {
                        pendingSpeechResult = null
                        result.error(
                            "unavailable",
                            "No speech recognition service is installed on this device.",
                            null,
                        )
                    }
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun isSpeechRecognitionAvailable(): Boolean {
        if (SpeechRecognizer.isRecognitionAvailable(this)) return true
        val intent = Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH)
        return packageManager.queryIntentActivities(intent, 0).isNotEmpty()
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (requestCode == SPEECH_REQUEST_CODE) {
            val pending = pendingSpeechResult
            pendingSpeechResult = null
            if (resultCode == Activity.RESULT_OK) {
                val text = data
                    ?.getStringArrayListExtra(RecognizerIntent.EXTRA_RESULTS)
                    ?.firstOrNull()
                pending?.success(text)
            } else {
                pending?.success(null) // cancelled or nothing recognised
            }
            return
        }
        // Let plugins (image_picker, permission_handler, …) see their results.
        super.onActivityResult(requestCode, resultCode, data)
    }

    private fun resizeFrame(frame: Bitmap, maxWidth: Int): Bitmap {
        if (frame.width <= maxWidth) return frame
        val maxHeight = (frame.height * maxWidth.toFloat() / frame.width).toInt()
        return Bitmap.createScaledBitmap(frame, maxWidth, maxHeight, true)
    }

    override fun onDestroy() {
        frameExecutor.shutdown()
        pendingSpeechResult = null
        super.onDestroy()
    }

    companion object {
        private const val SPEECH_REQUEST_CODE = 0x5356 // "SV"
    }
}
