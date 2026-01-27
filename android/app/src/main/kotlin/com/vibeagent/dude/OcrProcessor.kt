package com.vibeagent.dude

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Point
import android.graphics.Rect
import android.util.Base64
import android.util.Log
import com.google.mlkit.vision.common.InputImage
import com.google.mlkit.vision.text.Text
import com.google.mlkit.vision.text.TextRecognition
import com.google.mlkit.vision.text.latin.TextRecognizerOptions
import kotlinx.coroutines.tasks.await

/**
 * Enhanced OCR Processor with 3-level granularity:
 * Block (paragraph) → Line → Element (word)
 * 
 * Each level includes precise bounding boxes for accurate tapping.
 */
class OcrProcessor {
    companion object {
        private const val TAG = "OcrProcessor"
    }

    data class OcrResult(
        val success: Boolean,
        val fullText: String,
        val blocks: List<Map<String, Any>>,
        val imageWidth: Int,
        val imageHeight: Int,
        val error: String?
    )

    suspend fun extractTextFromBase64Screenshot(base64Screenshot: String): OcrResult {
        return try {
            val bitmap = decodeBase64ToBitmap(base64Screenshot)
                ?: return OcrResult(false, "", emptyList(), 0, 0, "Invalid screenshot data")

            val image = InputImage.fromBitmap(bitmap, 0)
            val recognizer = TextRecognition.getClient(TextRecognizerOptions.DEFAULT_OPTIONS)
            val result: Text = recognizer.process(image).await()

            val blocks = mutableListOf<Map<String, Any>>()
            var totalElements = 0
            
            for (block in result.textBlocks) {
                // Extract lines within this block
                val lines = mutableListOf<Map<String, Any>>()
                
                for (line in block.lines) {
                    // Extract elements (words) within this line
                    val elements = mutableListOf<Map<String, Any>>()
                    
                    for (elementIndex in line.elements.indices) {
                        val element = line.elements[elementIndex]
                        val bounds = element.boundingBox
                        
                        // Calculate spatial context
                        val position = calculateSpatialPosition(
                            bounds, 
                            bitmap.width, 
                            bitmap.height
                        )
                        
                        // Get surrounding context (previous and next words in the line)
                        val previousWord = if (elementIndex > 0) {
                            line.elements[elementIndex - 1].text
                        } else null
                        
                        val nextWord = if (elementIndex < line.elements.size - 1) {
                            line.elements[elementIndex + 1].text
                        } else null
                        
                        
                        elements.add(mapOf<String, Any>(
                            "text" to element.text,
                            "boundingBox" to mapBounds(element.boundingBox),
                            "cornerPoints" to mapCornerPoints(element.cornerPoints),
                            "confidence" to (element.confidence ?: 0f),
                            // Add spatial context
                            "position" to position,
                            "previousWord" to (previousWord ?: ""),
                            "nextWord" to (nextWord ?: ""),
                            "lineText" to line.text  // Full line for better context
                        ))
                        totalElements++
                    }
                    
                    lines.add(mapOf(
                        "text" to line.text,
                        "boundingBox" to mapBounds(line.boundingBox),
                        "cornerPoints" to mapCornerPoints(line.cornerPoints),
                        "confidence" to (line.confidence ?: 0f),
                        "elements" to elements
                    ))
                }
                
                blocks.add(mapOf(
                    "text" to block.text,
                    "boundingBox" to mapBounds(block.boundingBox),
                    "cornerPoints" to mapCornerPoints(block.cornerPoints),
                    "lines" to lines
                ))
            }

            val fullText = result.text ?: ""
            Log.d(TAG, "✅ OCR extracted ${fullText.length} chars: ${blocks.size} blocks, $totalElements elements (words)")

            OcrResult(true, fullText, blocks, bitmap.width, bitmap.height, null)
        } catch (e: Exception) {
            Log.e(TAG, "❌ OCR extraction failed: ${e.message}", e)
            OcrResult(false, "", emptyList(), 0, 0, e.message)
        }
    }
    
    /**
     * Map a Rect to a Map with left, top, right, bottom, width, height, centerX, centerY
     * for maximum flexibility in coordinate calculations.
     */
    private fun mapBounds(rect: Rect?): Map<String, Int> {
        if (rect == null) return emptyMap()
        return mapOf(
            "left" to rect.left,
            "top" to rect.top,
            "right" to rect.right,
            "bottom" to rect.bottom,
            "width" to rect.width(),
            "height" to rect.height(),
            "centerX" to rect.centerX(),
            "centerY" to rect.centerY()
        )
    }
    
    /**
     * Map corner points for rotation-aware bounds (tilted text).
     * Returns 4 points: top-left, top-right, bottom-right, bottom-left
     */
    private fun mapCornerPoints(points: Array<Point>?): List<Map<String, Int>> {
        if (points == null) return emptyList()
        return points.map { mapOf("x" to it.x, "y" to it.y) }
    }
    
    /**
     * Calculate spatial position information for a text element
     * @param rect Bounding box of the text element
     * @param screenWidth Total screen width
     * @param screenHeight Total screen height
     * @return Map with position information
     */
    private fun calculateSpatialPosition(rect: Rect?, screenWidth: Int, screenHeight: Int): Map<String, Any> {
        if (rect == null) return emptyMap()
        
        val centerX = rect.centerX()
        val centerY = rect.centerY()
        
        // Calculate quadrant (1-4, like a coordinate plane)
        // 1: top-right, 2: top-left, 3: bottom-left, 4: bottom-right
        val quadrant = when {
            centerY < screenHeight / 2 && centerX >= screenWidth / 2 -> 1
            centerY < screenHeight / 2 && centerX < screenWidth / 2 -> 2
            centerY >= screenHeight / 2 && centerX < screenWidth / 2 -> 3
            else -> 4
        }
        
        // Calculate vertical position descriptor
        val verticalPosition = when {
            centerY < screenHeight / 3 -> "top"
            centerY < (screenHeight * 2 / 3) -> "middle"
            else -> "bottom"
        }
        
        // Calculate horizontal position descriptor
        val horizontalPosition = when {
            centerX < screenWidth / 3 -> "left"
            centerX < (screenWidth * 2 / 3) -> "center"
            else -> "right"
        }
        
        // Calculate normalized position (0.0 to 1.0)
        val normalizedX = centerX.toFloat() / screenWidth
        val normalizedY = centerY.toFloat() / screenHeight
        
        // Distance from screen center (useful for prioritizing central elements)
        val screenCenterX = screenWidth / 2f
        val screenCenterY = screenHeight / 2f
        val distanceFromCenter = kotlin.math.sqrt(
            ((centerX - screenCenterX) * (centerX - screenCenterX) + 
             (centerY - screenCenterY) * (centerY - screenCenterY)).toFloat()
        )
        
        return mapOf(
            "quadrant" to quadrant,
            "vertical" to verticalPosition,
            "horizontal" to horizontalPosition,
            "normalizedX" to normalizedX,
            "normalizedY" to normalizedY,
            "distanceFromCenter" to distanceFromCenter,
            "description" to "$verticalPosition-$horizontalPosition"  // e.g., "top-left"
        )
    }
    
    private fun decodeBase64ToBitmap(base64Str: String): Bitmap? {
        return try {
            val decoded = Base64.decode(base64Str, Base64.NO_WRAP)
            BitmapFactory.decodeByteArray(decoded, 0, decoded.size)
        } catch (e: Exception) {
            Log.e(TAG, "Error decoding base64 image: ${e.message}")
            null
        }
    }
} 