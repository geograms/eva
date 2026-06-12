package radio.geogram.eva

import android.content.Intent
import android.speech.RecognitionService
import android.speech.SpeechRecognizer

/**
 * Minimal RecognitionService so the android.voice_interaction metadata points at
 * a valid component (a complete voice-interaction app declares one). Eva's
 * actual speech-to-text runs in-app via the system recognizer / offline model,
 * so this stub just declines politely rather than implementing recognition here.
 */
class EvaRecognitionService : RecognitionService() {
    override fun onStartListening(recognizerIntent: Intent?, listener: Callback?) {
        try {
            listener?.error(SpeechRecognizer.ERROR_CLIENT)
        } catch (_: Throwable) {
        }
    }

    override fun onCancel(listener: Callback?) {}

    override fun onStopListening(listener: Callback?) {}
}
