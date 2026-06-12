package radio.geogram.eva

import android.service.voice.VoiceInteractionService

/**
 * The always-available service that makes Eva selectable as the device's
 * "Digital assistant app" (ROLE_ASSISTANT). The system binds this when Eva is
 * the chosen assistant; the actual per-invocation logic lives in
 * [EvaVoiceInteractionSession], created by [EvaVoiceInteractionSessionService].
 */
class EvaVoiceInteractionService : VoiceInteractionService()
