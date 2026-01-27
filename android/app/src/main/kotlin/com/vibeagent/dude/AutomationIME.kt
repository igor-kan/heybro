package com.vibeagent.dude

import android.inputmethodservice.InputMethodService
import android.util.Log
import android.view.View
import android.view.inputmethod.EditorInfo
import android.view.inputmethod.InputConnection
import android.content.BroadcastReceiver
import android.content.Intent
import android.content.IntentFilter
import android.content.Context
import com.vibeagent.dude.KeyboardController

/**
 * AutomationIME - Custom Input Method Editor for direct text injection
 * 
 * This IME service allows programmatic text input without clipboard or focus validation.
 * It uses InputConnection.commitText() to inject text directly into any active input field.
 * 
 * Key advantages:
 * - No clipboard pollution
 * - Works without explicit field focusing
 * - Bypasses accessibility limitations
 * - Most reliable method for text injection
 */
class AutomationIME : InputMethodService() {

    companion object {
        private const val TAG = "AutomationIME"
        
        // Singleton instance for external access
        @Volatile
        private var instance: AutomationIME? = null
        
        fun getInstance(): AutomationIME? = instance
        
        /**
         * Inject text from any context (e.g., from AccessibilityService)
         * @param text The text to inject
         * @return Boolean indicating success
         */
        fun injectText(text: String): Boolean {
            val ime = instance
            if (ime == null) {
                Log.e(TAG, "❌ IME instance not available")
                return false
            }
            
            return ime.commitTextToCurrentInput(text)
        }
        
        /**
         * Check if IME is currently available and active
         */
        fun isAvailable(): Boolean {
            return instance != null
        }
    }

    override fun onCreate() {
        super.onCreate()
        instance = this
        Log.d(TAG, "✅ AutomationIME created")
        
        // Register receiver for automation state
        val filter = IntentFilter("com.vibeagent.dude.ACTION_AUTOMATION_STATE")
        if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.O) {
            registerReceiver(automationStateReceiver, filter, Context.RECEIVER_EXPORTED)
        } else {
            registerReceiver(automationStateReceiver, filter)
        }
    }

    private val automationStateReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            val isAutomating = intent?.getBooleanExtra("is_automating", false) ?: false
            Log.d(TAG, "🤖 AutomationIME received state update: $isAutomating")
            keyboardController?.setAutomationMode(isAutomating)
        }
    }

    override fun onDestroy() {
        super.onDestroy()
        instance = null
        unregisterReceiver(automationStateReceiver)
        Log.d(TAG, "❌ AutomationIME destroyed")
    }

    private var keyboardController: KeyboardController? = null

    override fun onCreateInputView(): View? {
        Log.d(TAG, "⌨️ Creating Pro Keyboard View")
        keyboardController = KeyboardController(this, this)
        return keyboardController?.createInputView()
    }
    
    // Removed old setupKeyboardListeners and setKeyListener methods as they are now handled by controller

    override fun onStartInput(attribute: EditorInfo?, restarting: Boolean) {
        super.onStartInput(attribute, restarting)
        Log.d(TAG, "📝 Input started: inputType=${attribute?.inputType}, restarting=$restarting")
    }

    override fun onFinishInput() {
        super.onFinishInput()
        Log.d(TAG, "✅ Input finished")
    }

    /**
     * Core method: Commit text to the currently active input field
     * 
     * @param text The text to commit
     * @return Boolean indicating success
     */
    fun commitTextToCurrentInput(text: String): Boolean {
        return try {
            val ic: InputConnection? = currentInputConnection
            
            if (ic == null) {
                Log.e(TAG, "❌ No input connection available")
                return false
            }
            
            // Begin batch edit for better performance with long text
            ic.beginBatchEdit()
            
            try {
                // Commit the text at cursor position
                val success = ic.commitText(text, 1)
                
                if (success) {
                    Log.d(TAG, "✅ Text committed successfully: '${text.take(30)}${if (text.length > 30) "..." else ""}'")
                } else {
                    Log.w(TAG, "⚠️ commitText returned false")
                }
                
                return success
                
            } finally {
                // Always end batch edit
                ic.endBatchEdit()
            }
            
        } catch (e: Exception) {
            Log.e(TAG, "❌ Error committing text: ${e.message}", e)
            false
        }
    }

    /**
     * Alternative method: Set text directly (replaces existing content)
     * Useful for clearing and replacing field content
     * 
     * @param text The text to set
     * @return Boolean indicating success
     */
    fun setTextDirectly(text: String): Boolean {
        return try {
            val ic: InputConnection? = currentInputConnection
            
            if (ic == null) {
                Log.e(TAG, "❌ No input connection for setTextDirectly")
                return false
            }
            
            ic.beginBatchEdit()
            
            try {
                // Select all existing text
                ic.performContextMenuAction(android.R.id.selectAll)
                
                // Commit new text (replaces selection)
                val success = ic.commitText(text, 1)
                
                if (success) {
                    Log.d(TAG, "✅ Text set directly: '${text.take(30)}${if (text.length > 30) "..." else ""}'")
                } else {
                    Log.w(TAG, "⚠️ setTextDirectly returned false")
                }
                
                return success
                
            } finally {
                ic.endBatchEdit()
            }
            
        } catch (e: Exception) {
            Log.e(TAG, "❌ Error setting text directly: ${e.message}", e)
            false
        }
    }

    /**
     * Clear the current input field
     */
    fun clearCurrentInput(): Boolean {
        return try {
            val ic: InputConnection? = currentInputConnection
            
            if (ic == null) {
                Log.e(TAG, "❌ No input connection for clearCurrentInput")
                return false
            }
            
            ic.beginBatchEdit()
            
            try {
                // Select all and delete
                ic.performContextMenuAction(android.R.id.selectAll)
                ic.commitText("", 0)
                
                Log.d(TAG, "✅ Input cleared")
                true
                
            } finally {
                ic.endBatchEdit()
            }
            
        } catch (e: Exception) {
            Log.e(TAG, "❌ Error clearing input: ${e.message}", e)
            false
        }
    }

    /**
     * Get current input field information
     */
    fun getInputInfo(): Map<String, Any?> {
        return try {
            val ic: InputConnection? = currentInputConnection
            
            if (ic == null) {
                return mapOf("available" to false)
            }
            
            // Get text before and after cursor
            val textBefore = ic.getTextBeforeCursor(100, 0)
            val textAfter = ic.getTextAfterCursor(100, 0)
            
            mapOf(
                "available" to true,
                "textBefore" to textBefore?.toString(),
                "textAfter" to textAfter?.toString(),
                "hasInput" to (!textBefore.isNullOrEmpty() || !textAfter.isNullOrEmpty())
            )
            
        } catch (e: Exception) {
            Log.e(TAG, "❌ Error getting input info: ${e.message}", e)
            mapOf("available" to false, "error" to e.message)
        }
    }
}
