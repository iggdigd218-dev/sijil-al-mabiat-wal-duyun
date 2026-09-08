package com.nexora.eradata

import android.content.ClipData
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

/**
 * FlutterFragmentActivity وليس FlutterActivity: مكتبة البصمة (local_auth)
 * تتطلّب FragmentActivity لعرض نافذة المصادقة، وبدونها لا تعمل البصمة.
 */
class MainActivity : FlutterFragmentActivity() {
    private val waChannel = "nexora/whatsapp"
    private val updateChannel = "nexora/updates"
    private val sfxChannel = "nexora/sfx"
    private val waPackages = listOf("com.whatsapp", "com.whatsapp.w4b")
    private var mediaPlayer: android.media.MediaPlayer? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        // قناة الأصوات المخصصة/الاهتزاز الطويل/الإشعارات الخارجية بصوت مميز.
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, sfxChannel)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    // تشغيل ملف صوت من res/raw باسمه (بدون امتداد).
                    "play" -> {
                        val name = call.argument<String>("name") ?: ""
                        result.success(playRaw(name))
                    }
                    // اهتزاز بمدة محددة بالمللي ثانية (1000-2000 عند إنشاء عملية).
                    "vibrate" -> {
                        val ms = (call.argument<Int>("ms") ?: 300).coerceIn(10, 3000)
                        vibrateMs(ms.toLong())
                        result.success(true)
                    }
                    // إشعار نظام خارجي بصوت مخصص مختلف عن صوت النظام الافتراضي.
                    "notify" -> {
                        val title = call.argument<String>("title") ?: ""
                        val body = call.argument<String>("body") ?: ""
                        val sound = call.argument<String>("sound") ?: "nexora_alert"
                        result.success(showNotification(title, body, sound))
                    }
                    else -> result.notImplemented()
                }
            }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, waChannel)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "installed" -> result.success(installedPackages())
                    "send" -> {
                        val phone = call.argument<String>("phone") ?: ""
                        val text = call.argument<String>("text") ?: ""
                        val path = call.argument<String>("path")
                        val pkg = call.argument<String>("package")
                        result.success(send(phone, text, path, pkg))
                    }
                    else -> result.notImplemented()
                }
            }

        // قناة التحديث بنقرة واحدة: تفتح شاشة تثبيت النظام لملف APK منزَّل.
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, updateChannel)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    // هل سمح المستخدم لهذا التطبيق بتثبيت الحزم؟ (أندرويد 8+)
                    "canInstall" -> result.success(
                        if (android.os.Build.VERSION.SDK_INT >= 26)
                            packageManager.canRequestPackageInstalls()
                        else true
                    )
                    // يفتح إعدادات «تثبيت التطبيقات غير المعروفة» لهذا التطبيق.
                    "openInstallSettings" -> {
                        result.success(
                            if (android.os.Build.VERSION.SDK_INT >= 26) {
                                launch(
                                    Intent(
                                        android.provider.Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                                        Uri.parse("package:$packageName"),
                                    ).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                                )
                            } else true
                        )
                    }
                    // يطلق شاشة تثبيت النظام لملف الـ APK المحدد.
                    "installApk" -> {
                        val path = call.argument<String>("path") ?: ""
                        result.success(installApk(path))
                    }
                    else -> result.notImplemented()
                }
            }
    }

    /** يشغّل ملف صوت من res/raw فوق أي صوت آخر (بدون مقاطعة الموسيقى طويلاً). */
    private fun playRaw(name: String): Boolean = try {
        val resId = resources.getIdentifier(name, "raw", packageName)
        if (resId == 0) false else {
            mediaPlayer?.release()
            mediaPlayer = android.media.MediaPlayer.create(this, resId)?.apply {
                setAudioAttributes(
                    android.media.AudioAttributes.Builder()
                        .setUsage(android.media.AudioAttributes.USAGE_NOTIFICATION_EVENT)
                        .setContentType(android.media.AudioAttributes.CONTENT_TYPE_SONIFICATION)
                        .build()
                )
                setOnCompletionListener { it.release() }
                start()
            }
            mediaPlayer != null
        }
    } catch (e: Exception) { false }

    /** اهتزاز بمدة محددة (يدعم أندرويد الحديث والقديم). */
    private fun vibrateMs(ms: Long) {
        try {
            val vibrator = if (android.os.Build.VERSION.SDK_INT >= 31) {
                val vm = getSystemService(android.content.Context.VIBRATOR_MANAGER_SERVICE)
                    as android.os.VibratorManager
                vm.defaultVibrator
            } else {
                @Suppress("DEPRECATION")
                getSystemService(android.content.Context.VIBRATOR_SERVICE)
                    as android.os.Vibrator
            }
            if (android.os.Build.VERSION.SDK_INT >= 26) {
                vibrator.vibrate(
                    android.os.VibrationEffect.createOneShot(
                        ms, android.os.VibrationEffect.DEFAULT_AMPLITUDE
                    )
                )
            } else {
                @Suppress("DEPRECATION")
                vibrator.vibrate(ms)
            }
        } catch (e: Exception) { /* الاهتزاز كمالي */ }
    }

    /**
     * إشعار نظام خارجي بصوت مخصص من res/raw — قناة مستقلة لكل صوت لأن
     * صوت القناة لا يتغير بعد إنشائها في أندرويد 8+.
     */
    private fun showNotification(title: String, body: String, sound: String): Boolean = try {
        val nm = getSystemService(android.content.Context.NOTIFICATION_SERVICE)
            as android.app.NotificationManager
        val channelId = "nexora_$sound"
        val soundUri = Uri.parse("android.resource://$packageName/raw/$sound")
        if (android.os.Build.VERSION.SDK_INT >= 26) {
            val ch = android.app.NotificationChannel(
                channelId,
                "تنبيهات نكسورا",
                android.app.NotificationManager.IMPORTANCE_HIGH
            ).apply {
                description = "إشعارات مهمة بصوت مميز"
                enableVibration(true)
                vibrationPattern = longArrayOf(0, 350, 150, 350)
                setSound(
                    soundUri,
                    android.media.AudioAttributes.Builder()
                        .setUsage(android.media.AudioAttributes.USAGE_NOTIFICATION)
                        .setContentType(android.media.AudioAttributes.CONTENT_TYPE_SONIFICATION)
                        .build()
                )
            }
            nm.createNotificationChannel(ch)
        }
        val launch = packageManager.getLaunchIntentForPackage(packageName)
        val pi = android.app.PendingIntent.getActivity(
            this, 0, launch,
            android.app.PendingIntent.FLAG_UPDATE_CURRENT or
                android.app.PendingIntent.FLAG_IMMUTABLE
        )
        val builder = if (android.os.Build.VERSION.SDK_INT >= 26) {
            android.app.Notification.Builder(this, channelId)
        } else {
            @Suppress("DEPRECATION")
            android.app.Notification.Builder(this)
                .setSound(soundUri)
                .setVibrate(longArrayOf(0, 350, 150, 350))
        }
        val notification = builder
            .setContentTitle(title)
            .setContentText(body)
            .setSmallIcon(applicationInfo.icon)
            .setContentIntent(pi)
            .setAutoCancel(true)
            .build()
        nm.notify((System.currentTimeMillis() % 100000).toInt(), notification)
        true
    } catch (e: Exception) { false }

    /** يفتح شاشة تثبيت النظام لملف APK عبر FileProvider (لا تثبيت صامت). */
    private fun installApk(path: String): String {
        val file = File(path)
        if (!file.exists() || file.length() == 0L) return "file_missing"
        val uri: Uri = try {
            FileProvider.getUriForFile(this, "$packageName.fileprovider", file)
        } catch (e: Exception) {
            return "uri_failed"
        }
        val intent = Intent(Intent.ACTION_VIEW).apply {
            setDataAndType(uri, "application/vnd.android.package-archive")
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        }
        return if (launch(intent)) "ok" else "launch_failed"
    }

    private fun installedPackages(): List<String> =
        waPackages.filter { p ->
            try { packageManager.getPackageInfo(p, 0); true }
            catch (e: PackageManager.NameNotFoundException) { false }
        }

    /**
     * يفتح محادثة الرقم مباشرة داخل واتساب مع الصورة والنص دون تكرار أو نوافذ اختيار متعددة.
     */
    private fun send(phone: String, text: String, path: String?, pkg: String?): String {
        val digits = phone.filter { it.isDigit() }
        if (digits.length < 8) return "bad_phone"

        val target = pkg?.takeIf { it in installedPackages() }
            ?: installedPackages().firstOrNull()
            ?: return "no_whatsapp"

        val file = path?.let { File(it) }
            ?.takeIf { it.exists() && it.length() > 0L }
            ?.let { src -> copyToShared(src) }

        if (file != null) {
            val uri: Uri = try {
                FileProvider.getUriForFile(this, "$packageName.fileprovider", file)
            } catch (e: Exception) {
                return "image_failed"
            }

            val jid = "$digits@s.whatsapp.net"
            grantUriPermission(target, uri, Intent.FLAG_GRANT_READ_URI_PERMISSION)

            // 1. فتح واتساب المحدد مباشرة مع رقم المحادثة والمرفق
            val withJid = imageIntent(target, uri, text, jid, includeJid = true)
            if (launch(withJid)) return "ok"

            // 2. محاولة عبر ContactPicker للحزمة المحددة
            val direct = imageIntent(target, uri, text, jid, includeJid = true).apply {
                setClassName(target, "com.whatsapp.ContactPicker")
            }
            if (launch(direct)) return "ok"

            // 3. مشاركة الصورة والنص داخل الحزمة المحددة فقط دون تعميم
            val plain = imageIntent(target, uri, text, jid, includeJid = false)
            if (launch(plain)) return "ok"

            return "image_failed"
        }

        return sendTextOnly(digits, text, target)
    }

    /** يبني Intent صورة مع النص المرافق، مع منح واتساب صلاحية قراءة الملف. */
    private fun imageIntent(
        target: String?,
        uri: Uri,
        text: String,
        jid: String,
        includeJid: Boolean,
    ): Intent = Intent(Intent.ACTION_SEND).apply {
        target?.let { setPackage(it) }
        type = "image/*"
        putExtra(Intent.EXTRA_STREAM, uri)
        putExtra(Intent.EXTRA_TEXT, text)
        putExtra(Intent.EXTRA_TITLE, "سند العملية")
        if (includeJid) putExtra("jid", jid)
        clipData = ClipData.newUri(contentResolver, "voucher", uri)
        addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
    }

    private fun sendTextOnly(digits: String, text: String, target: String): String {
        val encoded = Uri.encode(text)
        
        // 1. الرابط المباشر للواجهة البرمجية لواتساب بالحزمة المحددة
        val directApi = Intent(Intent.ACTION_VIEW, Uri.parse("https://api.whatsapp.com/send?phone=$digits&text=$encoded")).apply {
            setPackage(target)
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        }
        if (launch(directApi)) return "ok"

        // 2. المخطط المباشر whatsapp:// بالحزمة المحددة
        val schemeIntent = Intent(Intent.ACTION_VIEW, Uri.parse("whatsapp://send?phone=$digits&text=$encoded")).apply {
            setPackage(target)
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        }
        if (launch(schemeIntent)) return "ok"

        // 3. رابط wa.me المباشر
        val viaLink = Intent(Intent.ACTION_VIEW, Uri.parse("https://wa.me/$digits?text=$encoded")).apply {
            setPackage(target)
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        }
        if (launch(viaLink)) return "ok"

        return "error:تعذّر فتح المحادثة"
    }

    private fun launch(intent: Intent): Boolean = try {
        startActivity(intent); true
    } catch (e: Exception) { false }

    /** FileProvider يتطلّب مسارًا معلنًا في file_paths.xml. */
    private fun copyToShared(src: File): File = try {
        val dir = File(cacheDir, "shared").apply { mkdirs() }
        val dst = File(dir, src.name)
        src.copyTo(dst, overwrite = true)
        dst
    } catch (e: Exception) { src }
}
