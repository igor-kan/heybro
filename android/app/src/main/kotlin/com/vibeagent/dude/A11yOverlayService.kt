package com.vibeagent.dude

import android.app.Service
import android.content.Context
import android.content.Intent
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.PixelFormat
import android.graphics.Rect
import android.os.Binder
import android.os.Build
import android.os.IBinder
import android.provider.Settings
import android.util.Log
import android.view.Gravity
import android.view.View
import android.view.WindowManager
import android.view.ViewGroup

class A11yOverlayService : Service() {

    companion object {
        private const val TAG = "A11yOverlayService"
    }

    inner class LocalBinder : Binder() {
        fun getService(): A11yOverlayService = this@A11yOverlayService
    }

    private val binder = LocalBinder()
    private var windowManager: WindowManager? = null
    private var overlayView: OverlayView? = null
    private val elementsToDraw = mutableListOf<ElementInfo>()

    data class ElementInfo(
        val rect: Rect,
        val index: Int
    )

    // Custom View for drawing
    private inner class OverlayView(context: Context) : View(context) {
        private val paintBox = Paint().apply {
            color = Color.RED
            style = Paint.Style.STROKE
            strokeWidth = 3f // Very thin box
        }

        private val paintTextBg = Paint().apply {
            color = Color.parseColor("#80000000") // Semi-transparent black
            style = Paint.Style.FILL
        }

        private val paintText = Paint().apply {
            color = Color.WHITE
            textSize = 30f
            textAlign = Paint.Align.CENTER
            isFakeBoldText = true
        }

        override fun onDraw(canvas: Canvas) {
            super.onDraw(canvas)
            // Synchronize to avoid concurrent modification exceptions if updated from another thread
            synchronized(elementsToDraw) {
                for (element in elementsToDraw) {
                    // Draw Box
                    canvas.drawRect(element.rect, paintBox)

                    // Draw Index Number
                    // Center X, Top Y (or slightly above/inside if at top edge)
                    val textX = element.rect.centerX().toFloat()
                    val textY = element.rect.top.toFloat()
                    
                    // Background for text visibility
                    val textBound = Rect()
                    val text = element.index.toString()
                    paintText.getTextBounds(text, 0, text.length, textBound)
                    
                    // Padding around text
                    val pad = 8
                    val bgRect = Rect(
                        (textX - textBound.width() / 2 - pad).toInt(),
                        (textY - textBound.height() - pad).toInt(),
                        (textX + textBound.width() / 2 + pad).toInt(),
                        (textY + pad).toInt()
                    )
                    
                    canvas.drawRect(bgRect, paintTextBg)
                    canvas.drawText(text, textX, textY, paintText)
                }
            }
        }
    }

    override fun onCreate() {
        super.onCreate()
        windowManager = getSystemService(Context.WINDOW_SERVICE) as WindowManager
        Log.d(TAG, "A11yOverlayService created")
    }

    override fun onBind(intent: Intent?): IBinder {
        return binder
    }

    fun updateElements(newElements: List<Map<String, Any>>) {
        if (!hasOverlayPermission()) {
            Log.w(TAG, "Cannot update overlay: Permission denied")
            return
        }

        synchronized(elementsToDraw) {
            elementsToDraw.clear()
            for (el in newElements) {
                try {
                    val bounds = el["bounds"] as? Map<String, Any>
                    val index = el["index"] as? Int
                    
                    if (bounds != null && index != null) {
                        val x = (bounds["x"] as? Number)?.toInt() ?: 0
                        val y = (bounds["y"] as? Number)?.toInt() ?: 0
                        val w = (bounds["width"] as? Number)?.toInt() ?: 0
                        val h = (bounds["height"] as? Number)?.toInt() ?: 0
                        
                        elementsToDraw.add(ElementInfo(Rect(x, y, x + w, y + h), index))
                    }
                } catch (e: Exception) {
                    Log.e(TAG, "Error parsing element for overlay: $e")
                }
            }
        }

        if (overlayView == null) {
            addOverlayView()
        } else {
            // Force redraw on the UI thread
            overlayView?.post { overlayView?.invalidate() }
        }
    }

    fun clearOverlay() {
        synchronized(elementsToDraw) {
            elementsToDraw.clear()
        }
        overlayView?.post { overlayView?.invalidate() }
        removeOverlayView()
    }

    private fun addOverlayView() {
        if (overlayView != null) return

        val params = WindowManager.LayoutParams(
            WindowManager.LayoutParams.MATCH_PARENT,
            WindowManager.LayoutParams.MATCH_PARENT,
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O)
                WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY
            else
                WindowManager.LayoutParams.TYPE_PHONE,
            WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or
                    WindowManager.LayoutParams.FLAG_NOT_TOUCHABLE or
                    WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN or
                    WindowManager.LayoutParams.FLAG_LAYOUT_NO_LIMITS,
            PixelFormat.TRANSLUCENT
        )
        params.gravity = Gravity.TOP or Gravity.START

        overlayView = OverlayView(this)
        try {
            windowManager?.addView(overlayView, params)
            Log.d(TAG, "Overlay view added")
        } catch (e: Exception) {
            Log.e(TAG, "Error adding overlay view: $e")
        }
    }

    private fun removeOverlayView() {
        if (overlayView != null) {
            try {
                windowManager?.removeView(overlayView)
                overlayView = null
                Log.d(TAG, "Overlay view removed")
            } catch (e: Exception) {
                Log.e(TAG, "Error removing overlay view: $e")
            }
        }
    }

    private fun hasOverlayPermission(): Boolean {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            Settings.canDrawOverlays(this)
        } else {
            true
        }
    }
}
