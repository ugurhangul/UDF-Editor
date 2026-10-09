package com.ugurhangul.udftor

import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterFragmentActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        // Register USB OTG MethodChannel
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "com.udftor.usb_otg"
        ).setMethodCallHandler(UsbOtgChannelHandler(this))
    }
}
