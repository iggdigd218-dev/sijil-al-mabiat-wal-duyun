package com.nexora.eradata;

import android.content.ClipData;
import android.content.Intent;
import android.content.pm.PackageManager;
import android.net.Uri;
import android.util.Base64;

import androidx.activity.result.ActivityResult;
import androidx.core.content.FileProvider;

import com.getcapacitor.Plugin;
import com.getcapacitor.PluginCall;
import com.getcapacitor.PluginMethod;
import com.getcapacitor.annotation.ActivityCallback;
import com.getcapacitor.annotation.CapacitorPlugin;

import java.io.File;
import java.io.FileOutputStream;
import java.nio.charset.StandardCharsets;

/**
 * Native Android bridge for sending a generated receipt image and its text to
 * WhatsApp. The web implementation remains available for browsers and for
 * devices where WhatsApp is not installed.
 */
@CapacitorPlugin(name = "WhatsAppShare")
public class WhatsAppSharePlugin extends Plugin {

    @PluginMethod
    public void shareReceipt(PluginCall call) {
        final String dataUrl = call.getString("dataUrl", "");
        final String text = call.getString("text", "");
        final String phone = normalizePhone(call.getString("phone", ""));
        try {
            Uri imageUri = null;
            String mime = "image/png";
            if (!dataUrl.isEmpty()) {
                final int comma = dataUrl.indexOf(',');
                if (comma < 0) { call.reject("Invalid receipt image"); return; }
                final String metadata = dataUrl.substring(0, comma);
                final String payload = dataUrl.substring(comma + 1);
                final byte[] bytes = metadata.contains(";base64")
                        ? Base64.decode(payload, Base64.DEFAULT)
                        : Uri.decode(payload).getBytes(StandardCharsets.UTF_8);
                mime = metadata.startsWith("data:") ? metadata.substring(5).split("[;,]", 2)[0] : mime;
                final File imageFile = new File(getContext().getCacheDir(), "nexora-receipt-" + System.currentTimeMillis() + ".png");
                try (FileOutputStream output = new FileOutputStream(imageFile)) { output.write(bytes); }
                imageUri = FileProvider.getUriForFile(getContext(), getContext().getPackageName() + ".fileprovider", imageFile);
            }

            final PackageManager packageManager = getContext().getPackageManager();
            final String waPackage = isPackageInstalled("com.whatsapp", packageManager) ? "com.whatsapp"
                    : (isPackageInstalled("com.whatsapp.w4b", packageManager) ? "com.whatsapp.w4b" : "");
            if (waPackage.isEmpty()) { call.reject("واتساب غير مثبت على هذا الجهاز"); return; }

            final Intent intent = new Intent(Intent.ACTION_SEND);
            intent.setType(imageUri == null ? "text/plain" : (mime.isEmpty() ? "image/png" : mime));
            if (imageUri != null) intent.putExtra(Intent.EXTRA_STREAM, imageUri);
            intent.putExtra(Intent.EXTRA_TEXT, text);
            intent.putExtra(Intent.EXTRA_TITLE, "سند العملية");
            if (imageUri != null) intent.setClipData(ClipData.newRawUri("receipt", imageUri));
            if (!phone.isEmpty()) {
                intent.putExtra("jid", phone + "@s.whatsapp.net");
                intent.putExtra("address", phone);
            }
            intent.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION | Intent.FLAG_ACTIVITY_NEW_TASK);
            intent.setPackage(waPackage);
            if (imageUri != null) getContext().grantUriPermission(waPackage, imageUri, Intent.FLAG_GRANT_READ_URI_PERMISSION);
            if (intent.resolveActivity(packageManager) != null) { startActivityForResult(call, intent, "shareReceiptResult"); return; }

            // لا نعرض Sharesheet فارغة: افتح المحادثة المحددة مباشرة كحل Android موثوق.
            if (!phone.isEmpty()) {
                Intent chat = new Intent(Intent.ACTION_VIEW, Uri.parse("https://wa.me/" + phone));
                chat.setPackage(waPackage);
                chat.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
                getContext().startActivity(chat);
                call.resolve();
            } else call.reject("تعذر فتح واتساب لهذا الرقم");
        } catch (Exception error) {
            call.reject("Unable to prepare WhatsApp receipt", error);
        }
    }

    private boolean isPackageInstalled(String packageName, PackageManager packageManager) {
        try {
            packageManager.getPackageInfo(packageName, 0);
            return true;
        } catch (Exception e) {
            return false;
        }
    }

    @ActivityCallback
    private void shareReceiptResult(PluginCall call, ActivityResult result) {
        // WhatsApp often returns RESULT_CANCELED even after the user completes an
        // ACTION_SEND share. Resolving here prevents a second, duplicate share sheet.
        if (call != null) call.resolve();
    }

    private String normalizePhone(String raw) {
        String phone = raw == null ? "" : raw.replaceAll("\\D", "");
        if (phone.startsWith("00")) phone = phone.substring(2);
        // Local Yemen numbers are commonly stored as 07xxxxxxxx; WhatsApp JIDs need 967.
        if (phone.startsWith("0") && phone.length() >= 9) phone = "967" + phone.substring(1);
        return phone;
    }
}
