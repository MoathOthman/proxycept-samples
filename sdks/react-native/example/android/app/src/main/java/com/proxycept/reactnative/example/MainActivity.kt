package com.proxycept.reactnative.example

import android.os.Bundle
import com.facebook.react.ReactActivity
import com.facebook.react.ReactActivityDelegate
import com.facebook.react.defaults.DefaultReactActivityDelegate
import com.facebook.react.defaults.DefaultNewArchitectureEntryPoint.fabricEnabled

class MainActivity : ReactActivity() {
    override fun getMainComponentName() = "ProxyceptRNExample"
    override fun createReactActivityDelegate(): ReactActivityDelegate =
        object : DefaultReactActivityDelegate(this, mainComponentName, fabricEnabled) {
            override fun getLaunchOptions(): Bundle = Bundle().apply {
                // Nonsecret URL only; the same JS entry fetches the ephemeral key.
                putString("configURL", intent.getStringExtra("PROXYCEPT_TEST_CONFIG_URL")
                    ?: "http://127.0.0.1:18881/sdk-test-config")
            }
        }
}
