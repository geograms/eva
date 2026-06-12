package radio.geogram.eva

import android.content.Context
import android.content.Intent
import android.os.Bundle
import android.service.voice.VoiceInteractionSession
import android.util.Log

/**
 * Runs when Eva is invoked as the assistant (power-button long-press, assist
 * gesture, lock screen). For Phase 1 it simply brings up the Eva app in
 * "assistant mode" — which auto-starts listening, answers on-device, and speaks
 * the reply — then dismisses its own (empty) session window.
 *
 * Screen-context handling (onHandleAssist / AssistStructure) is intentionally
 * left for a later phase.
 */
class EvaVoiceInteractionSession(context: Context) : VoiceInteractionSession(context) {

    override fun onShow(args: Bundle?, showFlags: Int) {
        super.onShow(args, showFlags)
        Log.i(TAG, "onShow -> launching Eva in assistant mode")
        val intent = Intent(context, MainActivity::class.java).apply {
            addFlags(
                Intent.FLAG_ACTIVITY_NEW_TASK or
                    Intent.FLAG_ACTIVITY_CLEAR_TOP or
                    Intent.FLAG_ACTIVITY_SINGLE_TOP
            )
            putExtra(EXTRA_ASSIST, true)
        }
        // startAssistantActivity (API 23+) keeps the launch inside the assist
        // flow and works over the keyguard; fall back to a plain start.
        try {
            startAssistantActivity(intent)
        } catch (_: Throwable) {
            context.startActivity(intent)
        }
        // We don't render our own assistant UI; hand control to the app.
        hide()
    }

    companion object {
        const val EXTRA_ASSIST = "eva_assist"
        private const val TAG = "EvaAssist"
    }
}
