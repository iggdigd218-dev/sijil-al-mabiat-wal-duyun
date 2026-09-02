package com.nexora.eradata;

import com.getcapacitor.BridgeActivity;

public class MainActivity extends BridgeActivity {
    @Override
    public void onCreate(android.os.Bundle savedInstanceState) {
        registerPlugin(WhatsAppSharePlugin.class);
        registerPlugin(ContactsPickerPlugin.class);
        super.onCreate(savedInstanceState);
    }
}
