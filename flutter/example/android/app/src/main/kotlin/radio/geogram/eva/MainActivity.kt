package radio.geogram.eva

import android.app.Activity
import android.app.role.RoleManager
import android.content.Intent
import android.os.Build
import android.os.Bundle
import android.provider.Settings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private var channel: MethodChannel? = null
    private var pendingRoleResult: MethodChannel.Result? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        applyAssistWindowFlags(intent)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val ch = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
        channel = ch
        ch.setMethodCallHandler { call, result ->
            when (call.method) {
                // True (once) if this launch came from the assistant invocation.
                "consumeAssistLaunch" -> {
                    val isAssist = intent?.getBooleanExtra(EXTRA_ASSIST, false) == true
                    intent?.removeExtra(EXTRA_ASSIST)
                    result.success(isAssist)
                }
                "isAssistant" -> result.success(isDefaultAssistant())
                "requestAssistantRole" -> requestAssistantRole(result)
                "openAssistantSettings" -> {
                    openAssistantSettings()
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
    }

    // Power-button/gesture while Eva is already running (singleTop) lands here.
    override fun onNewIntent(newIntent: Intent) {
        super.onNewIntent(newIntent)
        setIntent(newIntent)
        applyAssistWindowFlags(newIntent)
        if (newIntent.getBooleanExtra(EXTRA_ASSIST, false)) {
            newIntent.removeExtra(EXTRA_ASSIST)
            channel?.invokeMethod("onAssist", null)
        }
    }

    /** Show over the keyguard and wake the screen when invoked as the assistant. */
    private fun applyAssistWindowFlags(launchIntent: Intent?) {
        if (launchIntent?.getBooleanExtra(EXTRA_ASSIST, false) != true) return
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O_MR1) {
            setShowWhenLocked(true)
            setTurnScreenOn(true)
        }
    }

    private fun isDefaultAssistant(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) return false
        val rm = getSystemService(RoleManager::class.java) ?: return false
        return rm.isRoleAvailable(RoleManager.ROLE_ASSISTANT) &&
            rm.isRoleHeld(RoleManager.ROLE_ASSISTANT)
    }

    private fun requestAssistantRole(result: MethodChannel.Result) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
            openAssistantSettings()
            result.success(false)
            return
        }
        val rm = getSystemService(RoleManager::class.java)
        if (rm == null || !rm.isRoleAvailable(RoleManager.ROLE_ASSISTANT)) {
            openAssistantSettings()
            result.success(false)
            return
        }
        if (rm.isRoleHeld(RoleManager.ROLE_ASSISTANT)) {
            result.success(true)
            return
        }
        try {
            pendingRoleResult = result
            val roleIntent = rm.createRequestRoleIntent(RoleManager.ROLE_ASSISTANT)
            startActivityForResult(roleIntent, REQ_ASSISTANT_ROLE)
        } catch (_: Throwable) {
            // Some OEMs don't surface an in-app dialog for this role.
            pendingRoleResult = null
            openAssistantSettings()
            result.success(false)
        }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode == REQ_ASSISTANT_ROLE) {
            val granted = resultCode == Activity.RESULT_OK || isDefaultAssistant()
            pendingRoleResult?.success(granted)
            pendingRoleResult = null
        }
    }

    private fun openAssistantSettings() {
        // The assistant picker lives at slightly different places per OEM; the
        // voice-input settings screen is the closest stable public target.
        val actions = listOf(
            Settings.ACTION_VOICE_INPUT_SETTINGS,
            "android.settings.MANAGE_DEFAULT_APPS_SETTINGS",
            Settings.ACTION_SETTINGS,
        )
        for (action in actions) {
            try {
                startActivity(Intent(action).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
                return
            } catch (_: Throwable) {
            }
        }
    }

    companion object {
        private const val CHANNEL = "eva/assistant"
        private const val EXTRA_ASSIST = "eva_assist"
        private const val REQ_ASSISTANT_ROLE = 7011
    }
}
