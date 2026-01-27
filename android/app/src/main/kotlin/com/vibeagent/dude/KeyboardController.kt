package com.vibeagent.dude

import android.content.Context
import android.os.Handler
import android.os.Looper
import android.util.Log
import android.view.LayoutInflater
import android.view.MotionEvent
import android.view.View
import android.view.ViewGroup
import android.view.inputmethod.InputConnection
import android.view.inputmethod.EditorInfo
import android.widget.Button
import android.widget.FrameLayout
import android.widget.ImageButton
import android.widget.LinearLayout
import android.widget.PopupWindow
import android.widget.TextView
import android.widget.ProgressBar
import android.graphics.Rect

/**
 * Controller manages the keyboard layouts and logic (Alpha, Symbols, Shift states)
 * implements OnTouchListener for smooth key popups and interaction.
 */
class KeyboardController(
    private val context: Context,
    private val imeService: AutomationIME
) {
    private val TAG = "KeyboardController"
    private var containerView: FrameLayout? = null
    
    // State
    private var isCaps = false
    private var isCapsLocked = false
    private var lastShiftTapTime = 0L
    
    // Layouts
    private var qwertyView: View? = null
    private var symbolsView: View? = null
    private var symbolsShiftView: View? = null
    private var automationInfoView: View? = null
    
    // Popup logic
    private var keyPopup: PopupWindow? = null
    private var keyPopupView: TextView? = null
    private val handler = Handler(Looper.getMainLooper())
    
    enum class LayoutType { QWERTY, SYMBOLS, SYMBOLS_SHIFT, AUTOMATION_INFO }
    private var currentLayout = LayoutType.QWERTY

    fun createInputView(): View {
        val inflater = LayoutInflater.from(context)
        containerView = inflater.inflate(R.layout.keyboard_view_pro, null) as FrameLayout
        
        // Initialize popup
        val popupView = inflater.inflate(R.layout.keyboard_key_preview, null)
        keyPopupView = popupView.findViewById(R.id.popup_text)
        keyPopup = PopupWindow(popupView, 
            ViewGroup.LayoutParams.WRAP_CONTENT, 
            ViewGroup.LayoutParams.WRAP_CONTENT).apply {
                isClippingEnabled = false
                isTouchable = false // Pass touches through to underlying window if needed contextually
                animationStyle = 0 // Immediate show/hide
            }
        
        // Initialize layouts
        qwertyView = inflater.inflate(R.layout.layout_qwerty, containerView, false)
        symbolsView = inflater.inflate(R.layout.layout_symbols, containerView, false)
        symbolsShiftView = inflater.inflate(R.layout.layout_symbols_shift, containerView, false)
        automationInfoView = inflater.inflate(R.layout.layout_automation_info, containerView, false)
        
        // Add all views to container but hide non-active ones
        containerView?.addView(qwertyView)
        containerView?.addView(symbolsView)
        containerView?.addView(symbolsShiftView)
        containerView?.addView(automationInfoView)
        
        setupQwertyListeners(qwertyView!!)
        setupSymbolsListeners(symbolsView!!)
        setupSymbolsListeners(symbolsShiftView!!)
        
        switchToLayout(LayoutType.QWERTY)
        
        return containerView!!
    }

    private fun switchToLayout(type: LayoutType) {
        currentLayout = type
        qwertyView?.visibility = if (type == LayoutType.QWERTY) View.VISIBLE else View.GONE
        symbolsView?.visibility = if (type == LayoutType.SYMBOLS) View.VISIBLE else View.GONE
        symbolsShiftView?.visibility = if (type == LayoutType.SYMBOLS_SHIFT) View.VISIBLE else View.GONE
        automationInfoView?.visibility = if (type == LayoutType.AUTOMATION_INFO) View.VISIBLE else View.GONE
        
        // Reset caps state when switching back to QWERTY unless locked
        if (type == LayoutType.QWERTY && !isCapsLocked) {
            isCaps = false
            updateKeyLabels()
        }
    }

    private fun handleShift() {
        val currentTime = System.currentTimeMillis()
        if (currentTime - lastShiftTapTime < 300) {
            // Double tap -> Caps Lock
            isCapsLocked = !isCapsLocked
            isCaps = isCapsLocked
        } else {
            // Single tap -> Toggle Shift
            if (isCapsLocked) {
                isCapsLocked = false
                isCaps = false
            } else {
                isCaps = !isCaps
            }
        }
        lastShiftTapTime = currentTime
        updateKeyStyles()
        updateKeyLabels()
    }
    
    private fun updateKeyStyles() {
        val shiftKey = qwertyView?.findViewById<ImageButton>(R.id.key_shift)
        if (isCapsLocked) {
            shiftKey?.setColorFilter(0xFF4CAF50.toInt()) // Green tint for locked
        } else if (isCaps) {
            shiftKey?.setColorFilter(0xFFFFFFFF.toInt()) // White for active
        } else {
            shiftKey?.setColorFilter(0xFF90A4AE.toInt()) // Grey for inactive
        }
    }

    private fun updateKeyLabels() {
        val rows = (qwertyView as? ViewGroup)?.childrenRecursiveSequence()?.filterIsInstance<Button>()
        rows?.forEach { button ->
            val text = button.text.toString()
            if (text.length == 1 && text[0].isLetter()) {
                button.text = if (isCaps) text.uppercase() else text.lowercase()
            }
        }
    }
    
    private fun showKeyPreview(anchor: View, text: String) {
        if (keyPopupView == null) return
        
        keyPopupView?.text = text
        
        // Measure to center correctly
        keyPopupView?.measure(View.MeasureSpec.UNSPECIFIED, View.MeasureSpec.UNSPECIFIED)
        val popupWidth = keyPopupView?.measuredWidth ?: 0
        val popupHeight = keyPopupView?.measuredHeight ?: 0
        val anchorWidth = anchor.width
        
        val xOffset = (anchorWidth - popupWidth) / 2
        val yOffset = -popupHeight - 20 // 20px above key
        
        // Show immediately if not showing, otherwise update
        try {
            if (keyPopup?.isShowing == true) {
                keyPopup?.update(anchor, xOffset, yOffset, -1, -1)
            } else {
                keyPopup?.showAsDropDown(anchor, xOffset, yOffset)
            }
        } catch (e: Exception) {
            Log.e(TAG, "Error showing popup: ${e.message}")
        }
    }
    
    private fun dismissKeyPreview() {
        keyPopup?.dismiss()
    }

    // --- Key Binding Logic ---
    
    private fun bindKey(view: View, idName: String, text: String) {
        val id = context.resources.getIdentifier(idName, "id", context.packageName)
        if (id != 0) {
            val button = view.findViewById<View>(id)
            button?.setOnTouchListener(createKeyTouchListener(text))
        }
    }
    
    private fun createKeyTouchListener(text: String): View.OnTouchListener {
        return View.OnTouchListener { v, event ->
            when (event.action) {
                MotionEvent.ACTION_DOWN -> {
                    v.isPressed = true
                    v.performHapticFeedback(android.view.HapticFeedbackConstants.KEYBOARD_TAP)
                    // Determine text case if it's a letter
                    val commitText = if (currentLayout == LayoutType.QWERTY && text.length == 1 && text[0].isLetter()) {
                        if (isCaps) text.uppercase() else text.lowercase()
                    } else {
                        text
                    }
                    showKeyPreview(v, commitText)
                    true
                }
                MotionEvent.ACTION_UP -> {
                    v.isPressed = false
                    dismissKeyPreview()
                    
                    // Commit text
                    val commitText = if (currentLayout == LayoutType.QWERTY && text.length == 1 && text[0].isLetter()) {
                        if (isCaps) text.uppercase() else text.lowercase()
                    } else {
                        text
                    }
                    commitText(commitText)
                    
                    // Auto-release shift
                    if (isCaps && !isCapsLocked && currentLayout == LayoutType.QWERTY) {
                        isCaps = false
                        updateKeyStyles()
                        updateKeyLabels()
                    }
                    
                    v.performClick() // For accessibility/sound
                    true
                }
                MotionEvent.ACTION_CANCEL -> {
                    v.isPressed = false
                    dismissKeyPreview()
                    true
                }
                else -> false
            }
        }
    }

    private fun setupQwertyListeners(view: View) {
        val letters = "qwertyuiopasdfghjklzxcvbnm"
        letters.forEach { char ->
            bindKey(view, "key_$char", char.toString())
        }
        
        view.findViewById<View>(R.id.key_shift)?.setOnClickListener { handleShift() }
        view.findViewById<View>(R.id.key_symbols)?.setOnClickListener { switchToLayout(LayoutType.SYMBOLS) }
        bindCommonKeys(view)
        
        updateKeyStyles()
    }

    private fun setupSymbolsListeners(view: View) {
        for (i in 0..9) {
            bindKey(view, "key_$i", i.toString())
        }
        
        val symbolMap = mapOf(
            "key_at" to "@", "key_hash" to "#", "key_dollar" to "$", "key_percent" to "%",
            "key_amp" to "&", "key_minus" to "-", "key_plus" to "+", "key_lparen" to "(",
            "key_rparen" to ")", "key_slash" to "/", "key_asterisk" to "*", "key_quote" to "\"",
            "key_apos" to "'", "key_colon" to ":", "key_semicolon" to ";", "key_exclaim" to "!",
            "key_question" to "?", "key_tilde" to "~", "key_grave" to "`", "key_pipe" to "|",
            "key_bull" to "•", "key_sqrt" to "√", "key_pi" to "π", "key_div" to "÷",
            "key_mul" to "×", "key_para" to "¶", "key_delta" to "Δ", "key_pound" to "£",
            "key_cen" to "¢", "key_euro" to "€", "key_yen" to "¥", "key_caret" to "^",
            "key_deg" to "°", "key_eq" to "=", "key_lbrace" to "{", "key_rbrace" to "}",
            "key_bslash" to "\\"
        )
        
        symbolMap.forEach { (id, text) -> bindKey(view, id, text) }

        view.findViewById<View>(R.id.key_abc)?.setOnClickListener { switchToLayout(LayoutType.QWERTY) }
        view.findViewById<View>(R.id.key_more_symbols)?.setOnClickListener { switchToLayout(LayoutType.SYMBOLS_SHIFT) }
        view.findViewById<View>(R.id.key_symbols_back)?.setOnClickListener { switchToLayout(LayoutType.SYMBOLS) }
        
        bindCommonKeys(view)
    }

    private fun bindCommonKeys(view: View) {
        // Space - Special handling (no popup, just local feedback)
        val space = view.findViewById<View>(R.id.key_space)
        space?.setOnTouchListener { v, event ->
             when (event.action) {
                MotionEvent.ACTION_DOWN -> { v.isPressed = true; true }
                MotionEvent.ACTION_UP -> { v.isPressed = false; commitText(" "); v.performClick(); true }
                MotionEvent.ACTION_CANCEL -> { v.isPressed = false; true }
                else -> false
            }
        }
        
        // Punctuation
        bindKey(view, "key_period", ".")
        bindKey(view, "key_comma", ",")
        
        // Backspace - Repeat logic
        val backspace = view.findViewById<View>(R.id.key_backspace)
        backspace?.setOnTouchListener { v, event ->
            when (event.action) {
                MotionEvent.ACTION_DOWN -> {
                    v.isPressed = true
                    // Initial delete
                    deleteText(1)
                    // Start repeating
                    handler.postDelayed(object : Runnable {
                        override fun run() {
                            if (v.isPressed) {
                                deleteText(1)
                                handler.postDelayed(this, 100) // Repeat every 100ms
                            }
                        }
                    }, 500) // Initial delay 500ms
                    true
                }
                MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL -> {
                    v.isPressed = false
                    true
                }
                else -> false
            }
        }
        
        // Enter
        val enter = view.findViewById<View>(R.id.key_enter)
        enter?.setOnClickListener {
            val ic = imeService.currentInputConnection
            ic?.performEditorAction(EditorInfo.IME_ACTION_DONE)
        }
    }

    private fun commitText(text: String) {
        val ic = imeService.currentInputConnection
        ic?.commitText(text, 1)
    }
    
    private fun deleteText(length: Int) {
        val ic = imeService.currentInputConnection
        ic?.deleteSurroundingText(length, 0)
    }

    private fun ViewGroup.childrenRecursiveSequence(): Sequence<View> = sequence {
        for (i in 0 until childCount) {
            val child = getChildAt(i)
            yield(child)
            if (child is ViewGroup) {
                yieldAll(child.childrenRecursiveSequence())
            }
        }
    }

    fun setAutomationMode(active: Boolean) {
        handler.post {
            if (active) {
                switchToLayout(LayoutType.AUTOMATION_INFO)
            } else {
                switchToLayout(LayoutType.QWERTY)
            }
        }
    }
}
