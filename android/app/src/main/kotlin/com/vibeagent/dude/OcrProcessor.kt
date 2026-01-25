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
                    
                    for (element in line.elements) {
                        elements.add(mapOf(
                            "text" to element.text,
                            "boundingBox" to mapBounds(element.boundingBox),
                            "cornerPoints" to mapCornerPoints(element.cornerPoints),
                            "confidence" to (element.confidence ?: 0f)
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