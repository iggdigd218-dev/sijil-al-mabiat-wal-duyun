package com.nexora.eradata;

import android.content.Intent;
import android.database.Cursor;
import android.net.Uri;
import android.provider.ContactsContract;

import androidx.activity.result.ActivityResult;

import com.getcapacitor.Plugin;
import com.getcapacitor.PluginCall;
import com.getcapacitor.PluginMethod;
import com.getcapacitor.annotation.ActivityCallback;
import com.getcapacitor.annotation.CapacitorPlugin;
import com.getcapacitor.JSObject;

@CapacitorPlugin(name = "ContactsPicker")
public class ContactsPickerPlugin extends Plugin {
    @PluginMethod
    public void pick(PluginCall call) {
        Intent intent = new Intent(Intent.ACTION_PICK, ContactsContract.CommonDataKinds.Phone.CONTENT_URI);
        startActivityForResult(call, intent, "contactsPickerResult");
    }

    @ActivityCallback
    private void contactsPickerResult(PluginCall call, ActivityResult result) {
        if (call == null) return;
        if (result.getResultCode() != android.app.Activity.RESULT_OK || result.getData() == null) {
            call.reject("تم إلغاء اختيار جهة الاتصال");
            return;
        }
        Uri contactUri = result.getData().getData();
        if (contactUri == null) { call.reject("جهة الاتصال غير صالحة"); return; }
        Cursor cursor = getContext().getContentResolver().query(contactUri,
                new String[]{ContactsContract.CommonDataKinds.Phone.DISPLAY_NAME,
                        ContactsContract.CommonDataKinds.Phone.NUMBER}, null, null, null);
        if (cursor == null) { call.reject("تعذر قراءة جهة الاتصال"); return; }
        try {
            if (!cursor.moveToFirst()) { call.reject("جهة الاتصال غير موجودة"); return; }
            JSObject value = new JSObject();
            value.put("name", cursor.getString(0));
            value.put("phone", cursor.getString(1));
            call.resolve(value);
        } finally {
            cursor.close();
        }
    }
}
