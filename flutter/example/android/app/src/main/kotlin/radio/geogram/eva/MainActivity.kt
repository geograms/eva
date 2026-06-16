package radio.geogram.eva

import android.app.Activity
import android.app.role.RoleManager
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.provider.Settings
import androidx.core.content.FileProvider
import com.ryanheise.audioservice.AudioServiceActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

// Extends AudioServiceActivity (itself a FlutterActivity) so the
// just_audio_background foreground service can bind to this activity's engine.
class MainActivity : AudioServiceActivity() {
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

        // ── In-app updater: install a downloaded APK ──────────────────────────
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, INSTALLER_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    // Whether Eva may install APKs (the "Install unknown apps"
                    // toggle). Always true below Android 8, where it's a single
                    // global setting rather than a per-app one.
                    "canInstall" -> result.success(canInstallPackages())
                    // Send the user to the per-app "Install unknown apps" screen.
                    "requestInstallPermission" -> {
                        requestInstallPermission()
                        result.success(null)
                    }
                    // Hand the APK at [path] to the system package installer.
                    "installApk" -> {
                        val path = call.argument<String>("path")
                        if (path == null) {
                            result.error("no_path", "Missing APK path", null)
                        } else {
                            try {
                                installApk(path)
                                result.success(true)
                            } catch (e: Throwable) {
                                result.error("install_failed", e.message, null)
                            }
                        }
                    }
                    else -> result.notImplemented()
                }
            }
    }

    private fun canInstallPackages(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return true
        return packageManager.canRequestPackageInstalls()
    }

    private fun requestInstallPermission() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        try {
            startActivity(
                Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                    Uri.parse("package:$packageName"))
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
        } catch (_: Throwable) {
            // Some OEMs lack the per-app screen — fall back to app details.
            try {
                startActivity(
                    Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                        Uri.parse("package:$packageName"))
                        .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
            } catch (_: Throwable) {
            }
        }
    }

    private fun installApk(path: String) {
        val file = File(path)
        val uri = FileProvider.getUriForFile(this, "$packageName.updateprovider", file)
        val intent = Intent(Intent.ACTION_VIEW).apply {
            setDataAndType(uri, "application/vnd.android.package-archive")
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        }
        startActivity(intent)
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
        private const val INSTALLER_CHANNEL = "eva/installer"
        private const val EXTRA_ASSIST = "eva_assist"
        private const val REQ_ASSISTANT_ROLE = 7011
    }
}
