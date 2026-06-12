package radio.geogram.eva

import android.os.Bundle
import android.service.voice.VoiceInteractionSession
import android.service.voice.VoiceInteractionSessionService

/** Factory for [EvaVoiceInteractionSession] — one session per assist invocation. */
class EvaVoiceInteractionSessionService : VoiceInteractionSessionService() {
    override fun onNewSession(args: Bundle?): VoiceInteractionSession {
        return EvaVoiceInteractionSession(this)
    }
}
