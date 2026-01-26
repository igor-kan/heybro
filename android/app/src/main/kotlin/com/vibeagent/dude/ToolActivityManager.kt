package com.vibeagent.dude

import android.content.Context
import android.util.Log
import android.util.Base64
import java.io.ByteArrayOutputStream
import kotlinx.coroutines.*

class ToolActivityManager(private val context: Context) {
    companion object {
        private const val TAG = "ToolActivityManager"
    }

    // Activity instances
    private val tapActivity = TapActivity()
    private val swipeActivity = SwipeActivity()
    private val appManagementActivity = AppManagementActivity()
    private val screenCaptureActivity = ScreenCaptureActivity()
    private val navigationActivity = NavigationActivity()
    private val textInputActivity = TextInputActivity()

    init {
        Log.d(TAG, "🔧 ToolActivityManager initialized")
    }

    // ==================== TAP OPERATIONS ====================

    suspend fun performTap(x: Float, y: Float): Boolean {
        return try {
            Log.d(TAG, "🖱️ Delegating tap to TapActivity: ($x, $y)")

            // Clamp coordinates to safe screen insets to avoid edge rejections
            val dims = getScreenDimensions()
            val screenW = (dims["width"] as? Int) ?: 0
            val screenH = (dims["height"] as? Int) ?: 0
            val inset = 4f
            val clampedX = when {
                screenW <= 0 -> x
                x < inset -> inset
                x > screenW - inset -> screenW - inset
                else -> x
            }
            val clampedY = when {
                screenH <= 0 -> y
                y < inset -> inset
                y > screenH - inset -> screenH - inset
                else -> y
            }

            // Validate coordinates
            if (!validateCoordinates(clampedX, clampedY)) {
                Log.e(TAG, "❌ Invalid tap coordinates after clamping: ($clampedX, $clampedY)")
                return false
            }

            if (!tapActivity.isServiceAvailable()) {
                Log.e(TAG, "❌ TapActivity service not available")
                return false
            }

            val result = tapActivity.performTap(clampedX, clampedY)
            Log.d(TAG, if (result) "✅ Tap successful" else "❌ Tap failed")
            result
        } catch (e: Exception) {
            Log.e(TAG, "❌ Exception in performTap: ${e.message}", e)
            false
        }
    }

    suspend fun performGroupedTaps(taps: List<Map<String, Float>>): Boolean {
        return try {
            Log.d(TAG, "🖱️ Performing grouped taps: ${taps.size} taps")
            
            if (!tapActivity.isServiceAvailable()) {
                Log.e(TAG, "❌ TapActivity service not available for grouped taps")
                return false
            }

            var successCount = 0
            for (tap in taps) {
                val x = tap["x"] ?: continue
                val y = tap["y"] ?: continue
                
                // Use existing performTap logic (direct call to tapActivity to avoid excessive logging/checks if trusted, 
                // but let's use performTap for safety/clamping if it's not too slow. 
                // actually calling performTap ensures clamping validation.)
                // Given we want speed, maybe direct? But clamping is safer. 
                // Let's call performTap but maybe we suppress logs? No, logs are fine.
                
                if (performTap(x, y)) {
                    successCount++
                }
                // Small delay between taps to ensure registration
                kotlinx.coroutines.delay(200)
            }
            
            Log.d(TAG, "✅ Grouped taps complete: $successCount/${taps.size} successful")
            successCount > 0
        } catch (e: Exception) {
            Log.e(TAG, "❌ Exception in performGroupedTaps: ${e.message}", e)
            false
        }
    }

    suspend fun performLongPress(x: Float, y: Float, duration: Long = 500L): Boolean {
        return try {
            Log.d(TAG, "🖱️ Delegating long press to TapActivity: ($x, $y) duration: ${duration}ms")

            val dims = getScreenDimensions()
            val screenW = (dims["width"] as? Int) ?: 0
            val screenH = (dims["height"] as? Int) ?: 0
            val inset = 4f
            val clampedX = when {
                screenW <= 0 -> x
                x < inset -> inset
                x > screenW - inset -> screenW - inset
                else -> x
            }
            val clampedY = when {
                screenH <= 0 -> y
                y < inset -> inset
                y > screenH - inset -> screenH - inset
                else -> y
            }

            if (!validateCoordinates(clampedX, clampedY)) {
                Log.e(TAG, "❌ Invalid long press coordinates after clamping: ($clampedX, $clampedY)")
                return false
            }

            if (!tapActivity.isServiceAvailable()) {
                Log.e(TAG, "❌ TapActivity service not available for long press")
                return false
            }

            val result = tapActivity.performLongPress(clampedX, clampedY, duration)
            Log.d(TAG, if (result) "✅ Long press successful" else "❌ Long press failed")
            result
        } catch (e: Exception) {
            Log.e(TAG, "❌ Exception in performLongPress: ${e.message}", e)
            false
        }
    }

    suspend fun performDoubleClick(x: Float, y: Float): Boolean {
        Log.d(TAG, "🖱️ Delegating double click to TapActivity: ($x, $y)")
        val dims = getScreenDimensions()
        val screenW = (dims["width"] as? Int) ?: 0
        val screenH = (dims["height"] as? Int) ?: 0
        val inset = 4f
        val clampedX = when {
            screenW <= 0 -> x
            x < inset -> inset
            x > screenW - inset -> screenW - inset
            else -> x
        }
        val clampedY = when {
            screenH <= 0 -> y
            y < inset -> inset
            y > screenH - inset -> screenH - inset
            else -> y
        }
        return tapActivity.performDoubleClick(clampedX, clampedY)
    }

    // ==================== SWIPE OPERATIONS ====================

    suspend fun performSwipe(
            startX: Float,
            startY: Float,
            endX: Float,
            endY: Float,
            duration: Long = 300L
    ): Boolean {
        Log.d(TAG, "🔄 Delegating swipe to SwipeActivity")
        return swipeActivity.performSwipe(startX, startY, endX, endY, duration)
    }

    suspend fun performScroll(direction: String): Boolean {
        Log.d(TAG, "📜 Delegating scroll to SwipeActivity: $direction")
        return swipeActivity.performScroll(direction)
    }

    suspend fun performDirectionalSwipe(direction: String): Boolean {
        Log.d(TAG, "🔄 Delegating directional swipe to SwipeActivity: $direction")
        return swipeActivity.performDirectionalSwipe(direction)
    }

    suspend fun performPinch(
            centerX: Float,
            centerY: Float,
            scale: Float,
            duration: Long = 500L
    ): Boolean {
        Log.d(TAG, "🤏 Delegating pinch to SwipeActivity")
        return swipeActivity.performPinch(centerX, centerY, scale, duration)
    }

    suspend fun performZoomIn(): Boolean {
        Log.d(TAG, "🔍 Delegating zoom in to SwipeActivity")
        return swipeActivity.performZoomIn()
    }

    suspend fun performZoomOut(): Boolean {
        Log.d(TAG, "🔍 Delegating zoom out to SwipeActivity")
        return swipeActivity.performZoomOut()
    }

    // ==================== APP MANAGEMENT OPERATIONS ====================

    fun openApp(packageName: String): Boolean {
        return try {
            Log.d(TAG, "📱 Delegating app opening to AppManagementActivity: $packageName")

            if (packageName.isBlank()) {
                Log.e(TAG, "❌ Package name is blank or empty")
                return false
            }

            val result = appManagementActivity.openApp(packageName, context)
            Log.d(
                    TAG,
                    if (result) "✅ App opened successfully: $packageName"
                    else "❌ Failed to open app: $packageName"
            )
            result
        } catch (e: Exception) {
            Log.e(TAG, "❌ Exception opening app $packageName: ${e.message}", e)
            false
        }
    }

    fun openAppByName(appName: String): Boolean {
        return try {
            Log.d(TAG, "📱 Delegating app opening by name to AppManagementActivity: $appName")

            if (appName.isBlank()) {
                Log.e(TAG, "❌ App name is blank or empty")
                return false
            }

            val result = appManagementActivity.openAppByName(appName, context)
            Log.d(
                    TAG,
                    if (result) "✅ App opened by name successfully: $appName"
                    else "❌ Failed to open app by name: $appName"
            )
            result
        } catch (e: Exception) {
            Log.e(TAG, "❌ Exception opening app by name $appName: ${e.message}", e)
            false
        }
    }

    fun getInstalledApps(): List<Map<String, String>> {
        return try {
            Log.d(TAG, "📱 Delegating app listing to AppManagementActivity")
            val result = appManagementActivity.getInstalledApps(context)
            Log.d(TAG, "✅ Retrieved ${result.size} installed apps")
            result
        } catch (e: Exception) {
            Log.e(TAG, "❌ Exception getting installed apps: ${e.message}", e)
            emptyList()
        }
    }

    fun getUserInstalledApps(): List<Map<String, String>> {
        Log.d(TAG, "📱 Delegating user app listing to AppManagementActivity")
        return appManagementActivity.getUserInstalledApps(context)
    }

    fun getLaunchableApps(): List<Map<String, String>> {
        Log.d(TAG, "📱 Delegating launchable app listing to AppManagementActivity")
        return appManagementActivity.getLaunchableApps(context)
    }

    fun findMatchingApps(appName: String): List<Map<String, String>> {
        Log.d(TAG, "🔍 Delegating app search to AppManagementActivity: $appName")
        return appManagementActivity.findMatchingApps(appName, context)
    }

    fun searchApps(keyword: String): List<Map<String, String>> {
        Log.d(TAG, "🔍 Delegating app keyword search to AppManagementActivity: $keyword")
        return appManagementActivity.searchApps(keyword, context)
    }

    fun getAppInfo(packageName: String): Map<String, String>? {
        Log.d(TAG, "ℹ️ Delegating app info to AppManagementActivity: $packageName")
        return appManagementActivity.getAppInfo(packageName, context)
    }

    fun isAppInstalled(packageName: String): Boolean {
        Log.d(TAG, "❓ Delegating app installation check to AppManagementActivity: $packageName")
        return appManagementActivity.isAppInstalled(packageName, context)
    }

    suspend fun getBestMatchingApp(appName: String): Map<String, String>? {
        Log.d(TAG, "🎯 Delegating best app match to AppManagementActivity: $appName")
        return appManagementActivity.getBestMatchingApp(appName, context)
    }

    fun getRecentApps(): List<Map<String, String>> {
        Log.d(TAG, "📋 Delegating recent apps to AppManagementActivity")
        return appManagementActivity.getRecentApps(context)
    }

    suspend fun clearAppData(packageName: String): Boolean {
        return try {
            Log.d(TAG, "🧹 Delegating app data clearing to AppManagementActivity: $packageName")
            appManagementActivity.clearAppData(packageName, context)
        } catch (e: Exception) {
            Log.e(TAG, "❌ Clear app data failed: ${e.message}", e)
            false
        }
    }

    suspend fun forceStopApp(packageName: String): Boolean {
        return try {
            Log.d(TAG, "🛑 Delegating app force stop to AppManagementActivity: $packageName")
            appManagementActivity.forceStopApp(packageName, context)
        } catch (e: Exception) {
            Log.e(TAG, "❌ Force stop app failed: ${e.message}", e)
            false
        }
    }

    // ==================== SCREEN CAPTURE OPERATIONS ====================

    suspend fun takeScreenshot(lowQuality: Boolean = false): String? {
        return try {
            Log.d(TAG, "📸 Delegating screenshot to ScreenCaptureActivity")

            if (!screenCaptureActivity.isScreenshotCapable()) {
                Log.e(TAG, "❌ Screenshot capability not available")
                return null
            }

            val result = screenCaptureActivity.takeScreenshot(lowQuality)
            Log.d(
                    TAG,
                    if (result != null) "✅ Screenshot taken successfully (${result.length} chars)"
                    else "❌ Screenshot failed"
            )
            result
        } catch (e: Exception) {
            Log.e(TAG, "❌ Exception taking screenshot: ${e.message}", e)
            null
        }
    }

    suspend fun takeRealScreenshot(): String? {
        Log.d(TAG, "📸 Delegating real screenshot to ScreenCaptureActivity")
        return screenCaptureActivity.takeRealScreenshot()
    }

    suspend fun getScreenElements(): List<Map<String, Any>> {
        Log.d(TAG, "🔍 Delegating screen elements to ScreenCaptureActivity")
        return screenCaptureActivity.getScreenElements()
    }

    suspend fun analyzeScreen(): Map<String, Any> {
        Log.d(TAG, "🔬 Delegating screen analysis to ScreenCaptureActivity")
        return screenCaptureActivity.analyzeScreen()
    }

    fun getScreenDimensions(): Map<String, Any> {
        Log.d(TAG, "📐 Delegating screen dimensions to ScreenCaptureActivity")
        return screenCaptureActivity.getScreenDimensions()
    }

    fun validateScreenshot(base64Screenshot: String?): Boolean {
        Log.d(TAG, "✅ Delegating screenshot validation to ScreenCaptureActivity")
        return screenCaptureActivity.validateScreenshot(base64Screenshot)
    }

    // ==================== NAVIGATION OPERATIONS ====================

    suspend fun performBack(): Boolean {
        return try {
            Log.d(TAG, "🔙 Delegating back navigation to NavigationActivity")

            if (!navigationActivity.isServiceAvailable()) {
                Log.e(TAG, "❌ Navigation service not available for back action")
                return false
            }

            val result = navigationActivity.performBack()
            Log.d(TAG, if (result) "✅ Back navigation successful" else "❌ Back navigation failed")
            result
        } catch (e: Exception) {
            Log.e(TAG, "❌ Exception performing back navigation: ${e.message}", e)
            false
        }
    }

    suspend fun performHome(): Boolean {
        Log.d(TAG, "🏠 Delegating home navigation to NavigationActivity")
        return navigationActivity.performHome()
    }

    suspend fun performRecents(): Boolean {
        Log.d(TAG, "📱 Delegating recents navigation to NavigationActivity")
        return navigationActivity.performRecents()
    }

    suspend fun openNotifications(): Boolean {
        Log.d(TAG, "🔔 Delegating notifications to NavigationActivity")
        return navigationActivity.openNotifications()
    }

    suspend fun openQuickSettings(): Boolean {
        Log.d(TAG, "⚙️ Delegating quick settings to NavigationActivity")
        return navigationActivity.openQuickSettings()
    }

    suspend fun openPowerDialog(): Boolean {
        Log.d(TAG, "⚡ Delegating power dialog to NavigationActivity")
        return navigationActivity.openPowerDialog()
    }

    fun openAccessibilitySettings(): Boolean {
        Log.d(TAG, "♿ Delegating accessibility settings to NavigationActivity")
        return navigationActivity.openAccessibilitySettings(context)
    }

    fun openSettings(): Boolean {
        Log.d(TAG, "⚙️ Delegating device settings to NavigationActivity")
        return navigationActivity.openSettings(context)
    }

    suspend fun openWifiSettings(): Boolean {
        Log.d(TAG, "📶 Delegating WiFi settings to NavigationActivity")
        return navigationActivity.openWifiSettings(context)
    }

    suspend fun openBluetoothSettings(): Boolean {
        Log.d(TAG, "🔵 Delegating Bluetooth settings to NavigationActivity")
        return navigationActivity.openBluetoothSettings(context)
    }

    suspend fun openAppSettings(packageName: String): Boolean {
        Log.d(TAG, "⚙️ Delegating app settings to NavigationActivity: $packageName")
        return navigationActivity.openAppSettings(packageName, context)
    }

    suspend fun navigateUp(): Boolean {
        Log.d(TAG, "⬆️ Delegating navigate up to NavigationActivity")
        return navigationActivity.performNavigationAction("up")
    }

    suspend fun navigateDown(): Boolean {
        Log.d(TAG, "⬇️ Delegating navigate down to NavigationActivity")
        return navigationActivity.performNavigationAction("down")
    }

    suspend fun navigateLeft(): Boolean {
        Log.d(TAG, "⬅️ Delegating navigate left to NavigationActivity")
        return navigationActivity.performNavigationAction("left")
    }

    suspend fun navigateRight(): Boolean {
        Log.d(TAG, "➡️ Delegating navigate right to NavigationActivity")
        return navigationActivity.performNavigationAction("right")
    }

    suspend fun performNavigationAction(direction: String): Boolean {
        Log.d(TAG, "🧭 Delegating navigation action to NavigationActivity: $direction")
        return navigationActivity.performNavigationAction(direction)
    }

    // ==================== TEXT INPUT OPERATIONS ====================

    suspend fun performAdvancedType(text: String, ocrBounds: Map<String, Any>? = null, expectedText: String? = null): Boolean {
        return try {
            Log.d(
                    TAG,
                    "⌨️ Delegating text typing to TextInputActivity: '${text.take(50)}${if (text.length > 50) "..." else ""}'")

            // Simple, direct approach - only use focused input detection
            val result = textInputActivity.performAdvancedType(text)
            
            Log.d(TAG, if (result) "✅ Text typed successfully" else "❌ Text typing failed")
            result
        } catch (e: Exception) {
            Log.e(TAG, "❌ Exception typing text: ${e.message}", e)
            false
        }
    }

    suspend fun clearTextField(): Boolean {
        Log.d(TAG, "🧹 Clear text field not implemented")
        return false
    }

    suspend fun selectAllText(): Boolean {
        Log.d(TAG, "🔤 Select all text not implemented in TextInputActivity")
        return false
    }

    suspend fun copyText(): Boolean {
        return try {
            Log.d(TAG, "📋 Delegating copy text to AccessibilityService")
            val service = MyAccessibilityService.instance
            if (service != null) {
                service.performCopy()
            } else {
                Log.e(TAG, "❌ Accessibility service not available for copy")
                false
            }
        } catch (e: Exception) {
            Log.e(TAG, "❌ Copy error: ${e.message}", e)
            false
        }
    }

    suspend fun pasteText(): Boolean {
        return try {
            Log.d(TAG, "📋 Delegating paste text to AccessibilityService")
            val service = MyAccessibilityService.instance
            if (service != null) {
                service.performPaste()
            } else {
                Log.e(TAG, "❌ Accessibility service not available for paste")
                false
            }
        } catch (e: Exception) {
            Log.e(TAG, "❌ Paste error: ${e.message}", e)
            false
        }
    }

    suspend fun cutText(): Boolean {
        return try {
            Log.d(TAG, "✂️ Delegating cut text to AccessibilityService")
            val service = MyAccessibilityService.instance
            if (service != null) {
                service.performCut()
            } else {
                Log.e(TAG, "❌ Accessibility service not available for cut")
                false
            }
        } catch (e: Exception) {
            Log.e(TAG, "❌ Cut error: ${e.message}", e)
            false
        }
    }

    suspend fun performBackspace(): Boolean {
        Log.d(TAG, "⌫ Backspace not implemented in TextInputActivity")
        return false
    }

    suspend fun performEnter(): Boolean {
        Log.d(TAG, "↵ Enter not implemented in TextInputActivity")
        return false
    }

    suspend fun replaceText(newText: String): Boolean {
        Log.d(TAG, "🔄 Replace text not implemented")
        return false
    }

    suspend fun typeTextSlowly(text: String, delayMs: Long = 50L): Boolean {
        Log.d(TAG, "🐌 Delegating text typing to TextInputActivity")
        return textInputActivity.performAdvancedType(text)
    }

    suspend fun sendKeyEvent(keyCode: Int): Boolean {
        return try {
            Log.d(TAG, "⌨️ Delegating key event to TextInputActivity: keyCode=$keyCode")
            val service = MyAccessibilityService.instance
            if (service != null) {
                service.sendKeyEvent(keyCode)
                true
            } else {
                Log.e(TAG, "❌ Accessibility service not available for key event")
                false
            }
        } catch (e: Exception) {
            Log.e(TAG, "❌ Key event error: ${e.message}", e)
            false
        }
    }

    suspend fun detectCursorLocation(): Map<String, Any?> {
        Log.d(TAG, "🎯 Cursor detection not implemented")
        return mapOf("error" to "Not implemented")
    }

    suspend fun validateInputFieldPosition(ocrBounds: Map<String, Any>?, expectedText: String?): Boolean {
        Log.d(TAG, "✅ Input field validation not implemented")
        return false
    }

    suspend fun focusInputField(text: String): Boolean {
        Log.d(TAG, "🎯 Focus input field not implemented")
        return false
    }

    // ==================== UTILITY METHODS ====================

    fun areServicesAvailable(): Map<String, Boolean> {
        return try {
            val services =
                    mapOf(
                            "tap" to tapActivity.isServiceAvailable(),
                            "swipe" to swipeActivity.isServiceAvailable(),
                            "screenCapture" to screenCaptureActivity.isScreenshotCapable(),
                            "navigation" to navigationActivity.isServiceAvailable(),
                            "textInput" to false
                    )

            Log.d(TAG, "🔍 Service availability check:")
            services.forEach { (service, available) ->
                Log.d(TAG, "  - $service: ${if (available) "✅ Available" else "❌ Not Available"}")
            }

            services
        } catch (e: Exception) {
            Log.e(TAG, "❌ Exception checking service availability: ${e.message}", e)
            mapOf(
                    "tap" to false,
                    "swipe" to false,
                    "screenCapture" to false,
                    "navigation" to false,
                    "textInput" to false
            )
        }
    }

    fun getSystemStatus(): Map<String, Any> {
        val serviceStatus = areServicesAvailable()
        val screenDimensions = getScreenDimensions()

        return mapOf(
                "timestamp" to System.currentTimeMillis(),
                "services" to serviceStatus,
                "screen" to screenDimensions,
                "accessibilityService" to (MyAccessibilityService.instance != null)
        )
    }

    fun validateCoordinates(x: Float, y: Float): Boolean {
        return try {
            val dimensions = getScreenDimensions()
            val screenWidth = dimensions["width"] as? Int ?: 1080
            val screenHeight = dimensions["height"] as? Int ?: 1920

            val isValid = tapActivity.validateCoordinates(x, y, screenWidth, screenHeight)

            if (!isValid) {
                Log.w(
                        TAG,
                        "⚠️ Invalid coordinates: ($x, $y) for screen ${screenWidth}x${screenHeight}"
                )
            }

            isValid
        } catch (e: Exception) {
            Log.e(TAG, "❌ Exception validating coordinates: ${e.message}", e)
            false
        }
    }

    fun validateSwipeCoordinates(startX: Float, startY: Float, endX: Float, endY: Float): Boolean {
        val dimensions = getScreenDimensions()
        val screenWidth = dimensions["width"] as? Int ?: 1080
        val screenHeight = dimensions["height"] as? Int ?: 1920

        return swipeActivity.validateSwipeCoordinates(
                startX,
                startY,
                endX,
                endY,
                screenWidth,
                screenHeight
        )
    }

    fun calculateSwipeDistance(startX: Float, startY: Float, endX: Float, endY: Float): Float {
        return swipeActivity.calculateSwipeDistance(startX, startY, endX, endY)
    }

    fun getAvailableCapabilities(): Map<String, List<String>> {
        return mapOf(
                "navigation" to navigationActivity.getAvailableNavigationActions(),
                "textInput" to emptyList<String>()
        )
    }

    fun cleanup() {
        try {
            Log.d(TAG, "🧹 Performing cleanup operations")

            // Clear screen capture cache
            screenCaptureActivity.clearCache()
            Log.d(TAG, "✅ Screen capture cache cleared")

            // Log final status
            val finalStatus = areServicesAvailable()
            Log.d(TAG, "📊 Final service status: $finalStatus")

            Log.d(TAG, "✅ Cleanup completed successfully")
        } catch (e: Exception) {
            Log.e(TAG, "❌ Error during cleanup: ${e.message}", e)
        }
    }

    fun getActivityStatus(): Map<String, Any> {
        try {
            return mapOf(
                    "timestamp" to System.currentTimeMillis(),
                    "services" to areServicesAvailable(),
                    "capabilities" to getAvailableCapabilities(),
                    "screen" to getScreenDimensions(),
                    "systemStatus" to getSystemStatus(),
                    "accessibilityConnected" to (MyAccessibilityService.instance != null)
            )
        } catch (e: Exception) {
            Log.e(TAG, "❌ Error getting activity status: ${e.message}", e)
            return mapOf(
                    "error" to (e.message ?: "Unknown error"),
                    "timestamp" to System.currentTimeMillis()
            )
        }
    }

    // Input Chip Handler Methods

    fun resizeImage(base64Image: String, targetWidth: Int = 480, quality: Int = 50): String? {
        return try {
            if (base64Image.isEmpty()) return null

            // Decode
            val decodedBytes = Base64.decode(base64Image, Base64.NO_WRAP)
            var bitmap = android.graphics.BitmapFactory.decodeByteArray(decodedBytes, 0, decodedBytes.size)

            if (bitmap == null) return null

            // Resize
            val width = bitmap.width
            val height = bitmap.height
            
            if (width > targetWidth) {
                val scale = targetWidth.toFloat() / width
                val targetHeight = (height * scale).toInt()
                val resized = android.graphics.Bitmap.createScaledBitmap(bitmap, targetWidth, targetHeight, true)
                if (resized != bitmap) {
                    bitmap.recycle()
                    bitmap = resized
                }
            }

            // Compress
            val outputStream = java.io.ByteArrayOutputStream()
            bitmap.compress(android.graphics.Bitmap.CompressFormat.JPEG, quality, outputStream)
            val result = Base64.encodeToString(outputStream.toByteArray(), Base64.NO_WRAP)

            // Cleanup
            bitmap.recycle()
            
            result
        } catch (e: Exception) {
            Log.e(TAG, "❌ Error resizing image: ${e.message}", e)
            null
        }
    }

}
