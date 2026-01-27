import 'dart:convert';
import 'dart:async';
import 'package:flutter/services.dart';
import '../gemini_client.dart';
import '../tools/tools_manager.dart';
import 'automation/automation_models.dart';
import '../secure_storage.dart';

class AutomationService {
  // Singleton pattern
  static final AutomationService _instance = AutomationService._internal();
  factory AutomationService() => _instance;
  AutomationService._internal();
  
  // Method channel for Android communication
  static const MethodChannel _channel = MethodChannel('com.vibeagent.dude/automation');
  
  // Callback functions
  Function(String)? onMessage;
  Function(String)? onError;
  Function()? onComplete;
  Function(bool)? onAutomationStateChanged;
  Function(String type, String content)? onLog;

  // Service state
  bool _isAutomating = false;
  bool _isInitialized = false;
  GeminiClient? _aiClient;
  bool _llmRequestOngoing = false;
  DateTime? _lastLlmRequestedAt;
  Map<String, dynamic>? _lastContext; // latest captured screen context

  // Task state
  String? _currentTask;
  AutomationSession? _session;
  List<String> _installedApps = [];
  int _currentStep = 0;
  
  // Field tracking state - prevent repeated taps on same field
  Set<String> _processedFields = {};
  Map<String, dynamic>? _lastTappedField;
  
  // Replay state - store tap coordinates for replay functionality
  Map<String, dynamic>? _lastTapCoordinates;
  
  // Retry state
  int _stepRetryCount = 0;
  String? _lastError;
  String? _lastFailedAction;
  
  // Persistent Vision Mode - once activated, stays active for entire task
  bool _visionModePersistent = false;
  String? _visionModeReason;

  // Public getters
  bool get isAutomating => _isAutomating;
  bool get isInitialized => _isInitialized;
  Map<String, dynamic>? get lastTapCoordinates => _lastTapCoordinates;

  // Settings
  bool _useVision = true;
  bool _showOverlay = false;
  SecureStorage? _secureStorage;
  ToolsManager _toolsManager = ToolsManager();

  /// Initialize the automation service
  Future<void> initialize() async {
    if (_isInitialized) {
      print('⚠️ AutomationService singleton already initialized');
      return;
    }

    try {
      print('🔧 Initializing AutomationService singleton...');

      // Set up method channel handler to receive calls from Android
      _channel.setMethodCallHandler(_handleMethodCall);
      print('📡 Method channel handler set up for automation service singleton');

      // Initialize AI client
      _aiClient = GeminiClient();
      await _aiClient!.initialize();
      
      _secureStorage = SecureStorage();
      await _secureStorage!.initialize();

      // Skip AI testing - start automation instantly
      _isInitialized = true;
      print('✅ AutomationService singleton initialized successfully and ready for voice commands');
    } catch (e) {
      print('❌ Failed to initialize AutomationService singleton: $e');
      throw e;
    }
  }

  /// Handle method calls from Android
  Future<dynamic> _handleMethodCall(MethodCall call) async {
    print('🤖 Received method call: ${call.method}');
    
    try {
      switch (call.method) {
        case 'executeUserTask':
          final userTask = call.arguments['user_task'] as String?;
          if (userTask != null && userTask.isNotEmpty) {
            print('🎯 Starting automation for task: $userTask');
            // Initialize if not already done
            if (!_isInitialized) {
              await initialize();
            }
            // Start automation
            await startAutomation(userTask);
            return true;
          } else {
            print('❌ Invalid user task provided');
            return false;
          }
        
        case 'isAutomationActive':
          return _isAutomating;
        
        case 'stopAutomation':
          stopAutomation();
          return true;
        
        default:
          print('❌ Unknown method call: ${call.method}');
          return false;
      }
    } catch (e) {
      print('❌ Error handling method call ${call.method}: $e');
      _notifyError('Failed to execute task: $e');
      return false;
    }
  }

  // AI testing removed - automation starts instantly

  /// Start automation with user task
  Future<void> startAutomation(String userMessage) async {
    if (!_isInitialized) {
      throw Exception('AutomationService not initialized');
    }

    if (_isAutomating) {
      throw Exception('Automation already running');
    }

    _currentTask = userMessage;
    _session = AutomationSession(task: userMessage); // Initialize session
    _currentStep = 0;
    _processedFields.clear(); // Reset field tracking for new task
    _lastTappedField = null;
    _visionModePersistent = false; // Reset vision mode for new task
    _visionModeReason = null;
    _isAutomating = true;
    _installedApps.clear(); // Clear previous apps list
    
    // Clear overlay
    try {
       const agentChannel = MethodChannel('com.vibeagent.dude/agent');
       await agentChannel.invokeMethod('clearA11yOverlay');
    } catch (_) {}
    
    // Refresh settings
    try {
      if (_secureStorage != null) {
        final mode = await _secureStorage!.getAutomationMode();
        _useVision = mode == 'vision_a11y';
        _showOverlay = await _secureStorage!.isA11yOverlayEnabled();
        print('⚙️ Automation Settings - Mode: $mode, Overlay: $_showOverlay');
      }
    } catch (e) {
      print('⚠️ Failed to load settings: $e');
    }
    
    // Notify UI that automation state changed to true
    onAutomationStateChanged?.call(true);

    try {
      // Notify Native Layer (Activity -> IME) that automation started
      // This switches the keyboard to "Automation Running" mode
      await _channel.invokeMethod('notifyAutomationState', {'isAutomating': true});
    } catch (_) {}

    try {
      // 1. Fetch Inventory of Installed Apps
      print('📦 Fetching installed apps inventory...');
      try {
        final appsResult = await ToolsManager.executeTool('get_launchable_apps', {});
        if (appsResult['success'] == true && appsResult['data'] is List) {
          final apps = List<dynamic>.from(appsResult['data']);
          // Extract app names, distinct and sorted
          _installedApps = apps
              .map((a) => (a is Map ? a['name']?.toString() ?? '' : '').trim())
              .where((name) => name.isNotEmpty)
              .toSet()
              .toList()
            ..sort();
          
          print('✅ Loaded ${_installedApps.length} installed apps for context');
        } else {
          print('⚠️ Failed to load apps: ${appsResult['error']}');
        }
      } catch (e) {
        print('❌ Error fetching apps: $e');
      }

      // Start the automation loop
      await _executeAutomationLoop();
    } catch (e) {
      _notifyError('Automation failed: $e');
    } finally {
      _isAutomating = false;
      // Notify UI that automation state changed to false
      onAutomationStateChanged?.call(false);
    }
  }

  /// Stop automation
  void stopAutomation() {
    if (_isAutomating) {
      _isAutomating = false;
      // Notify UI that automation state changed to false
      onAutomationStateChanged?.call(false);
      _notifyMessage('🛑 Automation stopped by user');
      
      // Clear overlay
      try {
         const agentChannel = MethodChannel('com.vibeagent.dude/agent');
         agentChannel.invokeMethod('clearA11yOverlay');
      } catch (_) {}
      
      // Notify Android to send broadcast for voice service overlay closing
      _notifyComplete();
    }
  }

  /// Execute automation loop
  Future<void> _executeAutomationLoop() async {
    Map<String, dynamic>? previousContext;
    bool forceContextRefresh = false;

    while (_isAutomating) {
      if (_stepRetryCount == 0) {
        _currentStep++;
        _lastError = null; // Clear error on fresh step
      } else {
        print('🔄 Retry attempt $_stepRetryCount for step $_currentStep');
      }

      // Get current screen context
      final screenContext = await _captureScreenContext();

      // Validate context freshness - ensure screen state has actually changed
      // Skip validation if we need to force refresh (after scroll actions)
      if (!forceContextRefresh && previousContext != null && _isContextIdentical(previousContext, screenContext)) {
        print('⚠️ Screen context unchanged - waiting for UI state change...');
        await Future.delayed(const Duration(milliseconds: 2000));
        continue;
      }

      // Reset force refresh flag
      forceContextRefresh = false;

      // Calculate screen hash for loop detection
      final int screenHash = screenContext.toString().hashCode;
      
      // Check for loops
      final loopResult = _session != null 
          ? LoopDetection.check(_session!.recentActions) 
          : LoopResult(isLoop: false);

      if (loopResult.isLoop) {
        print('🔄 LOOP DETECTED [${loopResult.loopType}]: ${loopResult.suggestion}');
        if (loopResult.failedActions != null && loopResult.failedActions!.isNotEmpty) {
          print('   Failed Actions: ${loopResult.failedActions!.join(' → ')}');
        }
        
        // For severe loops (exact or 3+ semantic matches), consider recovery strategies
        if (loopResult.loopType == 'exact' || loopResult.loopType == 'stall') {
          print('⚠️ Severe loop detected - recovery strategies will be suggested to AI');
          
          // Activate persistent vision mode if not already active
          if (!_visionModePersistent) {
            _visionModePersistent = true;
            _visionModeReason = 'Loop recovery - accessibility may be unreliable';
            print('👁️ Activating persistent Vision Mode for loop recovery');
          }
        }
      }

      // Build AI prompt with visual context and strict validation rules
      final prompt = _buildStepPrompt(screenContext, loopResult: loopResult);

      // Extract image for Vision Fallback if available
      String? visionImage;
      if (screenContext['low_quality_screenshot'] is String) {
        visionImage = screenContext['low_quality_screenshot'];
      }

      // Get AI decision
      final aiResponse = await _getAIDecision(prompt, image: visionImage);
      if (aiResponse == null) {
        _stepRetryCount++;
        _lastError = 'Failed to get AI response';
        print('❌ AI response failed (attempt $_stepRetryCount/3)');
        
        if (_stepRetryCount >= 3) {
          _notifyError('Failed to get AI response after 3 attempts');
          _stepRetryCount = 0;
          break;
        }
        
        // Wait before retry
        await Future.delayed(const Duration(seconds: 2));
        continue;
      }

      // Store current context for next iteration comparison
      previousContext = Map<String, dynamic>.from(screenContext);

      // Execute the AI's decision
      final shouldContinue = await _processAIDecision(aiResponse, screenHash);
      if (!shouldContinue) {
        break;
      }

      // Check if action was a scroll - if so, wait longer for content to settle
      final action = aiResponse['action'] as String?;
      final isScrollAction = action != null && (action.contains('scroll') || action.contains('swipe'));
      
      if (isScrollAction) {
        // Extended wait for scroll actions to allow content loading and UI settling
        print('🔄 Scroll action detected - waiting for content to settle...');
        await Future.delayed(const Duration(milliseconds: 4000));
        // Force fresh context capture on next iteration
        forceContextRefresh = true;
        print('🔄 Forcing fresh context capture after scroll action');
      } else {
        // Standard wait for other actions
        await Future.delayed(const Duration(milliseconds: 2500));
      }
    }

    // No step limit - automation continues until task completion or manual stop
  }

  /// Capture current screen context for AI
  Future<Map<String, dynamic>> _captureScreenContext() async {
    try {
      print('📱 Capturing screen context...');

      // Get current app info
      final currentAppResult = await ToolsManager.executeTool('get_current_app', {});
      print('🔍 currentAppResult: success=${currentAppResult['success']}, data type=${currentAppResult['data']?.runtimeType}, raw data=${currentAppResult['data']}');

      Map<String, dynamic> currentApp;
      try {
        if (currentAppResult['success'] == true && currentAppResult['data'] is Map) {
          currentApp = Map<String, dynamic>.from(currentAppResult['data'] ?? {});
          print('✅ Successfully parsed current app: $currentApp');
        } else {
          currentApp = <String, dynamic>{};
          print('⚠️ Current app result not a map, using empty map');
        }
      } catch (e) {
        print('❌ Error parsing current app: $e');
        currentApp = <String, dynamic>{};
      }

      // Get accessibility tree
      final treeResult = await ToolsManager.executeTool('get_accessibility_tree', {});
      print('🔍 treeResult: success=${treeResult['success']}, data type=${treeResult['data']?.runtimeType}, raw data=${treeResult['data']}');

      List<dynamic> accessibilityTree;
      try {
        if (treeResult['success'] == true && treeResult['data'] is List) {
          accessibilityTree = List.from(treeResult['data'] ?? []);
          print('✅ Successfully parsed accessibility tree: ${accessibilityTree.length} items');
        } else {
          accessibilityTree = <dynamic>[];
          print('⚠️ Accessibility tree result not a list, using empty list. Data: ${treeResult['data']}');
          if (treeResult['data'] != null && treeResult['data'] is! List) {
            print('🚨 CRITICAL: accessibility tree data is ${treeResult['data']?.runtimeType}, expected List');
          }
        }
      } catch (e) {
        print('❌ Error parsing accessibility tree: $e');
        accessibilityTree = <dynamic>[];
      }

      // Detect system dialogs in accessibility tree
      final systemDialogs = _detectSystemDialogs(accessibilityTree, currentApp);
      if (systemDialogs.isNotEmpty) {
        print('🔔 Detected ${systemDialogs.length} system dialog(s)');
      }

      // Derive screen elements from accessibility tree to avoid duplicate extraction
      List<dynamic> screenElements;
      if (accessibilityTree.isNotEmpty) {
        screenElements = List.from(accessibilityTree);
        print('ℹ️ Using accessibility tree for screen elements (${screenElements.length})');
      } else {
        screenElements = <dynamic>[];
      }

      // Try to take screenshot
      Map<String, dynamic> screenshotResult = {'success': false};
      
      // Only take screenshot if vision is enabled
      if (_useVision) {
          screenshotResult = await ToolsManager.executeTool('take_screenshot', {});
      } else {
          print('📷 Vision disabled by settings - skipping screenshot');
      }
      
      final screenshotAvailable = screenshotResult['success'] == true;
      print('🔍 screenshotResult: success=${screenshotResult['success']}, data type=${screenshotResult['data']?.runtimeType}');
      
      // Update Overlay if enabled
      if (_showOverlay && accessibilityTree.isNotEmpty) {
         try {
            // Filter elements that have bounds
            final validElements = screenElements.where((e) => e is Map && e['bounds'] != null).toList();
            if (validElements.isNotEmpty) {
               const agentChannel = MethodChannel('com.vibeagent.dude/agent');
               await agentChannel.invokeMethod('updateA11yOverlay', {'elements': validElements});
            }
         } catch (e) {
           print('⚠️ Error updating overlay: $e');
         }
      }

      // Fallback to OCR/Vision when accessibility tree is empty or likely web content
      String ocrText = '';
      List<dynamic> ocrBlocks = const [];
      String? lowQualityScreenshotBase64;
      
      // Vision state
      bool visionActive = false;
      bool visionRescueMode = false;

      final isA11yEmpty = accessibilityTree.isEmpty;
      
      Map<String, double>? contextDimensions = {};

      // Analyze Vision if enabled by settings
      String? screenshotB64;
      if (_useVision && screenshotAvailable) {
          screenshotB64 = (screenshotResult['data'] as String?);
          if (screenshotB64 != null && screenshotB64.isNotEmpty) {
              // 1. Process Vision Image
              try {
                print('📸 Processing vision image (Compressing for AI)...');
                final lqResult = await ToolsManager.executeTool('resize_image', {
                  'base64Image': screenshotB64,
                  'targetWidth': 3000, 
                  'quality': 40 
                });
                
                if (lqResult['success'] == true && lqResult['data'] is String) {
                  lowQualityScreenshotBase64 = lqResult['data'];
                  visionActive = true;
                  
                  // Only trigger Rescue Mode (Full Vision Prompt) if A11y is completely broken
                  if (isA11yEmpty) {
                    visionRescueMode = true;
                    print('⚠️ Vision Rescue Mode ACTIVE (Reason: Empty Accessibility Tree)');
                  } else {
                    print('👁️ Vision Active (Enhancing Standard Prompt)');
                  }
                  
                } else {
                  print('❌ Vision resize failed: ${lqResult['error']}');
                }
              } catch (e) {
                print('❌ Vision capture failed: $e');
              }
          }
      }

      // 2. OCR (Existing Logic - keep as supplementary)
      // Only run OCR if we have a screenshot
      if (screenshotB64 != null && screenshotB64.isNotEmpty) {
          final ocrResult = await ToolsManager.executeTool('perform_ocr', {
            'screenshot': screenshotB64,
          });
          if (ocrResult['success'] == true && ocrResult['data'] is Map) {
            final data = Map<String, dynamic>.from(ocrResult['data']);
            ocrText = (data['text']?.toString() ?? '').trim();
            ocrBlocks = (data['blocks'] is List)
                ? List.from(data['blocks'])
                : <dynamic>[];
            // Attach OCR image dimensions for coordinate normalization
            if (data['imageWidth'] != null && data['imageHeight'] != null) {
              contextDimensions = {
                'ocrImageWidth': (data['imageWidth'] as num).toDouble(),
                'ocrImageHeight': (data['imageHeight'] as num).toDouble(),
              };
            }
            if (ocrText.isNotEmpty) {
              print(
                  '✅ OCR extracted ${ocrText.length} chars (${ocrBlocks.length} blocks)');
            } else {
              print('⚠️ OCR returned no text');
            }
          } else {
            print('❌ OCR failed: ${ocrResult['error']}');
          }
      }

            // Store vision dimensions if active or image available
          if (lowQualityScreenshotBase64 != null) {
            contextDimensions ??= {};
            contextDimensions!['visionImageWidth'] = contextDimensions['ocrImageWidth'] ?? 0.0;
          }

      print('📊 Context captured - App: ${currentApp['packageName'] ?? 'Unknown'}, Elements: ${screenElements.length}, Tree: ${accessibilityTree.length}');

      final context = {
        'current_app': currentApp,
        'screen_elements': screenElements,
        'accessibility_tree': accessibilityTree,
        'system_dialogs': systemDialogs,
        'screenshot_available': screenshotAvailable,
        'ocr_text': ocrText,
        'ocr_blocks': ocrBlocks,
        'ocr_blocks': ocrBlocks,
        'ocr_image_width': (contextDimensions['ocrImageWidth'] ?? 0.0),
        'ocr_image_height': (contextDimensions['ocrImageHeight'] ?? 0.0),
        'vision_image_width': (contextDimensions['visionImageWidth'] ?? 0.0),
        'low_quality_screenshot': lowQualityScreenshotBase64,
        'vision_active': visionActive,
        'vision_rescue_mode': visionRescueMode,
        'vision_fallback_active': visionRescueMode, // Keep for prompt compatibility (triggers Rescue Prompt)
        'vision_fallback_reason': visionRescueMode ? 'empty_tree' : (visionActive ? 'settings' : null),
        'timestamp': DateTime.now().millisecondsSinceEpoch,
      };

      print('🔍 Final context structure: ${context.runtimeType}');
      print('🔍 Context keys: ${context.keys.toList()}');
      print('🔍 Each field type: current_app=${context['current_app']?.runtimeType}, screen_elements=${context['screen_elements']?.runtimeType}, accessibility_tree=${context['accessibility_tree']?.runtimeType}');
      if ((context['ocr_text'] as String).isNotEmpty) {
        print('🔤 OCR text: ${(context['ocr_text'] as String)}');
      }
      // Check for screen changes and reset field tracking if needed
      if (_hasScreenChanged(context)) {
        _resetFieldTracking();
      }
      
      // Store for downstream helpers
      _lastContext = context;
      return context;
    } catch (e) {
      print('❌ Failed to capture screen context: $e');
      final fallback = {
        'current_app': <String, dynamic>{},
        'screen_elements': <dynamic>[],
        'accessibility_tree': <dynamic>[],
        'system_dialogs': <dynamic>[],
        'screenshot_available': false,
        'ocr_text': '',
        'ocr_blocks': <dynamic>[],
        'ocr_image_width': 0.0,
        'ocr_image_height': 0.0,
        'vision_active': false,
        'vision_rescue_mode': false,
        'error': e.toString(),
      };
      // Reset field tracking on error (likely screen change)
      _resetFieldTracking();
      _lastContext = fallback;
      return fallback;
    }
  }

  List<String> _collectClassHints(List<dynamic> screenElements) {
    final hints = <String>[];
    for (final el in screenElements) {
      try {
        if (el is Map) {
          final map = Map<String, dynamic>.from(el);
          final className = map['className']?.toString() ?? map['type']?.toString() ?? '';
          if (className.isNotEmpty) hints.add(className);
        }
      } catch (_) {}
    }
    return hints;
  }

/// Build AI prompt for next step
/// Validate if screen context has meaningfully changed
bool _isContextIdentical(Map<String, dynamic> prev, Map<String, dynamic> current) {
  try {
    // Always consider context changed after scroll actions to force fresh analysis
    final currentTimestamp = current['timestamp'] as int? ?? 0;
    final prevTimestamp = prev['timestamp'] as int? ?? 0;
    final timeDiff = currentTimestamp - prevTimestamp;
    
    // If timestamps are very close (< 3 seconds), do deeper comparison
    if (timeDiff < 3000) {
      // Compare accessibility tree structure and content
      final prevTree = prev['accessibility_tree'] as List? ?? [];
      final currentTree = current['accessibility_tree'] as List? ?? [];
      if (prevTree.length != currentTree.length) return false;
      
      // Deep compare first few elements for content changes
      for (int i = 0; i < (prevTree.length < 5 ? prevTree.length : 5); i++) {
        if (i < currentTree.length) {
          final prevEl = prevTree[i] is Map ? Map<String, dynamic>.from(prevTree[i]) : {};
          final currentEl = currentTree[i] is Map ? Map<String, dynamic>.from(currentTree[i]) : {};
          if (prevEl['text'] != currentEl['text'] || prevEl['bounds'] != currentEl['bounds']) {
            return false;
          }
        }
      }
      
      // Compare OCR text content
      final prevOcr = prev['ocr_text'] as String? ?? '';
      final currentOcr = current['ocr_text'] as String? ?? '';
      if (prevOcr != currentOcr) return false;
      
      // Compare current app
      final prevApp = prev['current_app'] as Map? ?? {};
      final currentApp = current['current_app'] as Map? ?? {};
      if (prevApp['packageName'] != currentApp['packageName']) return false;
      
      return true;
    }
    
    // If significant time has passed, assume context has changed
    return false;
  } catch (e) {
    return false; // Assume changed if comparison fails
  }
}

String _buildVisionStepPrompt(Map<String, dynamic> context, {LoopResult? loopResult}) {
  // Build detailed history summary from Session
  String historySummary = "No history yet. Starting fresh.";
  String historyText = '';
  
  if (_session != null) {
      if (_session!.summary.isNotEmpty) {
        historySummary = _session!.summary;
      } else if (_session!.recentActions.isNotEmpty) {
        historySummary = "Recent actions: " + _session!.recentActions.map((s) => s.action).join(", ");
      }
      
      // Explicit Recent History List (Last 5)
      if (_session!.recentActions.isNotEmpty) {
        historyText = '\nRECENT HISTORY (Last ${_session!.recentActions.length}):\n';
        for (final step in _session!.recentActions) {
           // Include result to show if previous attempts failed
           historyText += '• ${step.action} - Result: ${step.result}\n';
        }
      }
  }

  // Vision Mode Prompt - Streamlined & Visual-First
  return '''
👁️ VISUAL AUTOMATION AGENT (VISION MODE)
You are an intelligent visual agent operating an Android device. 
Standard accessibility data has FAILED. You must rely on the SCREENSHOT to understand the UI.

🎯 PRIMARY GOAL: $_currentTask
Step: $_currentStep
Phase: ${_session?.currentPhase ?? 'executing'}

📜 NARRATIVE HISTORY:
"$historySummary"
$historyText

🧠 PREVIOUS PLAN CONTEXT:
${_session?.nextSteps.isNotEmpty == true ? 'Last Planned Next Steps: "${_session!.nextSteps}"' : '(No previous plan)'}

${loopResult?.isLoop == true ? '\n⚠️ LOOP WARNING: ${loopResult?.suggestion}\n' : ''}

🖼️ VISUAL INTELLIGENCE
- The provided image is the REAL-TIME screen state.
- x,y coordinates provided by you must be NORMALIZED to a 0-1000 scale.
- (0,0) is top-left, (1000,1000) is bottom-right.
- Ignore "0 accessibility nodes" warnings - they are expected in this mode.

🧠 REASONING PROTOCOL (Vision First)
1. **🕵️ VISUAL VERIFICATION (CRITICAL)**:
   - READ the "RECENT HISTORY" above.
   - Did your LAST action successfully change the screen?
   - **Retry Rule**: You may retry the **same** action ONCE (total 2 attempts) if you think it missed.
   - **STOP Condition**: If you see you have already tapped the exact same coordinate/element **TWICE consecutively** with no result, **STOP**. Do NOT try a 3rd time.
   - **Strategy Change**: If 2 attempts failed, you MUST try a different coordinate, scroll, or use a different action.

2. **Analyze the Image**: Identify buttons, icons, and text visually.
   - Describe the KEY elements you see that are relevant to the goal.

3. **Locate Target**: Find the UI element that moves you closer to the PRIMARY GOAL.
   - Action: 
   - Use `tap_vision` for buttons/icons. 
   - TO TYPE TEXT:
     • **ALWAYS use `robust_text_input`** - This is the ONLY reliable method.
     • Uses IME service for direct text injection.
   - **TO CHANGE DATES/NUMBERS (Pickers/Wheels)**:
     • **DO NOT TAP** the number continuously.
     • **MUST USE `perform_internal_scroll`** to scroll the wheel up/down.
   - Use `perform_scroll` if the target is off-screen and also when loop detected.

🚀 AVAILABLE ACTIONS (Vision Mode)
• tap_vision {"x": 500, "y": 500, "description": "Tap Blue Submit Button"} 
  - PREFERRED for clicking. 
  - x,y must be 0-1000 normalized coordinates.
• robust_text_input {"text": "hello world"}
  - **REQUIRED for ALL text input.** Uses IME for direct injection.
• perform_backspace {}
  - Delete text using IME backspace.

• perform_internal_scroll {"index": 2, "direction": "down"}
  - **REQUIRED for Date/Time Pickers, Wheels, and internal lists.**
  - Scrolls ONLY the specific element. direction="down" usually increments values.
• perform_swipe / perform_scroll 
  - Use for navigation.
• perform_home / perform_back

❌ DO NOT use `tap_element_by_text` unless you are 100% sure the system detected it.
❌ DO NOT REPEAT the exact same action if you have already failed TWICE in a row.

✅ RESPONSE FORMAT
You must return a JSON object with `visual_state`, `next_steps`, and `summary` fields.

Example:
<thought>
Step 1: Visual Verification. Last action was "tap login". 
Current image still shows the Login Screen with valid email.
Conclusion: The previous tap missed the button or wasn't registered.
Step 2: Analysis. I see the "Login" button at x=500, y=1000.
Plan: I will try tapping slightly higher or use a scroll to reset.
</thought>
```json
{
  "action": "tap_vision",
  "parameters": {"x": 500, "y": 950, "description": "Login button (adjusted)"},
  "visual_state": "Login screen with username field filled. Keyboard hidden.",
  "next_steps": "1. Tap login. 2. Verify home screen.",
  "summary": "Previous tap failed. Retrying login button with adjusted coordinates.",
  "description": "Tapping login button",
  "is_complete": false,
  "reasoning": "Visual identification of login button, adjusted for missed tap"
}
```
''';
}

String _buildStepPrompt(Map<String, dynamic> context, {LoopResult? loopResult}) {
  // Dispatch to specialized Vision Mode prompt if active
  if (context['vision_fallback_active'] == true) {
    return _buildVisionStepPrompt(context, loopResult: loopResult);
  }

  final currentApp = context['current_app'] is Map
      ? Map<String, dynamic>.from(context['current_app'])
      : <String, dynamic>{};
  final screenElements = context['screen_elements'] is List
      ? List.from(context['screen_elements'])
      : <dynamic>[];
  final accessibilityTree = context['accessibility_tree'] is List
      ? List.from(context['accessibility_tree'])
      : <dynamic>[];
  final systemDialogs = context['system_dialogs'] is List
      ? (context['system_dialogs'] as List).cast<Map<String, dynamic>>()
      : <Map<String, dynamic>>[];
  final hasScreenshot = context['screenshot_available'] == true;
  final ocrText = context['ocr_text'] is String ? (context['ocr_text'] as String) : '';
  final ocrBlocks = context['ocr_blocks'] is List ? List.from(context['ocr_blocks']) : <dynamic>[];
  final hasOcr = ocrText.isNotEmpty || ocrBlocks.isNotEmpty;
  final visionActive = context['vision_active'] == true || context['vision_fallback_active'] == true;
  final visionRescueMode = context['vision_rescue_mode'] == true;
  
  // Get image dimensions for OCR line formatting
  final ocrImageWidth = (context['ocr_image_width'] as num?)?.toDouble();
  final ocrImageHeight = (context['ocr_image_height'] as num?)?.toDouble();
  
  // Extract simple hints for form inputs from a11y and OCR
  final inputHints = <String>[];
  final a11y = context['accessibility_tree'];
  if (a11y is List) {
    for (final n in a11y) {
      try {
        if (n is Map) {
          final m = Map<String, dynamic>.from(n);
          if (m['editable'] == true) {
            final label = (m['text']?.toString() ??
                    m['contentDescription']?.toString() ??
                    m['className']?.toString() ??
                    '')
                .trim();
            if (label.isNotEmpty) inputHints.add(label);
          }
        }
      } catch (_) {}
    }
  }

  // Build history summary from Session
  String historyText = '';
  if (_session != null && _session!.recentActions.isNotEmpty) {
    historyText = '\nRECENT HISTORY (Last ${_session!.recentActions.length}):\n';
    for (final step in _session!.recentActions) {
      historyText += '• ${step.action} - ${step.result}\n';
    }
  }
  
  // Session Summary
  String sessionSummary = '';
  if (_session != null) {
    sessionSummary = '''
\n📊 SESSION STATUS:
- Phase: ${_session!.currentPhase}
- Milestones: ${_session!.milestones.join(', ')}
''';
  }

  // Build enhanced loop warning section
  String loopWarningSection = '';
  if (loopResult?.isLoop == true) {
    final failedActionsText = loopResult!.failedActions != null && loopResult.failedActions!.isNotEmpty
        ? loopResult.failedActions!.join('\n   ')
        : 'See history above';
    
    loopWarningSection = '''\n
═══════════════════════════════════════════════════════════════
⛔ CRITICAL: LOOP DETECTED - ${loopResult.loopType?.toUpperCase() ?? 'UNKNOWN'} PATTERN
═══════════════════════════════════════════════════════════════

🚨 YOU ARE STUCK IN A REPETITIVE LOOP!

Loop Type: ${loopResult.loopType}
Failed Actions (DO NOT REPEAT):
   $failedActionsText

${loopResult.suggestion}

🔧 MANDATORY RECOVERY ACTIONS:
1. **DO NOT** repeat any of the failed actions above
2. **ANALYZE** why these actions failed (element not responsive, wrong target, etc.)
3. **TRY ALTERNATIVE**:
    ${loopResult.loopType == 'semantic' ? '''
    - Use Vision Mode (tap_vision) with different coordinates
    - Try scrolling to reveal more options
    - Look for alternative UI elements that achieve the same goal''' : loopResult.loopType == 'stall' ? '''
    - Navigate back (perform_back) and try a different path
    - Return to home screen and restart
    - Consider if the task is blocked by a system dialog or permission''' : '''
    - Switch to Vision Mode for visual targeting
    - Try scrolling to find the correct element
    - Consider if you need to navigate differently'''}

❌ FORBIDDEN: Repeating the exact same action or tapping the same text/element again
✅ REQUIRED: Choose a COMPLETELY DIFFERENT approach from the list above

═══════════════════════════════════════════════════════════════
''';
  }

  // ENHANCED HUMAN-LIKE AUTOMATOR AI AGENT PROMPT - CHAIN OF THOUGHT ENABLED
  String prompt = '''
🤖 HUMAN-LIKE MOBILE AUTOMATOR AGENT
You are an intelligent mobile automation agent that mimics human interaction patterns. Your goal is to complete the user's task by navigating the screen, interacting with elements, and managing state effectively.$loopWarningSection

🎯 MISSION BRIEFING
- Primary Task: $_currentTask
- Current Phase: ${_session?.currentPhase ?? 'executing'}
- Recent History: $historyText
$sessionSummary

📱 CURRENT SCREEN INTELLIGENCE
- Interactive Elements: ${screenElements.length} available
- Accessibility Nodes: ${accessibilityTree.length} detected
- System Alerts: ${systemDialogs.length} active
- Text Recognition: $hasOcr
- Input Field Hints: ${inputHints.isEmpty ? 'None detected' : inputHints.join(', ')}

🎮 INTERACTIVE ELEMENTS MAP
${_formatElements(screenElements)}

🌲 ACCESSIBILITY NAVIGATION TREE
${_formatAccessibilityTree(accessibilityTree)}

🚨 SYSTEM NOTIFICATIONS & DIALOGS
${systemDialogs.isNotEmpty ? _formatSystemDialogs(systemDialogs) : '[Clean screen - no system interruptions]'}

👁️ VISUAL TEXT RECOGNITION (OCR) - INDEXED LINES
${hasOcr ? _formatOcrTextWithLineNumbers(ocrBlocks, imageWidth: ocrImageWidth, imageHeight: ocrImageHeight) : '[No readable text detected on screen]'}
💡 TIP: Use [Lx] line numbers with tap_ocr_line to tap specific lines (e.g., tap_ocr_line {"line": 3})
${visionActive ? (visionRescueMode ? '\n⚠️ VISION RESCUE MODE ACTIVE: Accessibility tree is empty or broken. Use the visual screenshot to find elements and perform_tap with coordinates.' : '\n👁️ VISION CONTEXT AVAILABLE: You have access to a real-time screenshot. Use it to verify elements or tap using coordinates if accessibility is incomplete.') : ''}

📦 INSTALLED APPS INVENTORY (Launchable)
${_installedApps.isEmpty ? '[No apps detected]' : _installedApps.join(', ')}

═══════════════════════════════════════════════════════════════

🧠 INTELLIGENT REASONING PROTOCOL (Requires <thought> block)

1. **FIRST STEP - APP SELECTION (CRITICAL)**:
   - If this is the FIRST step (History is empty) or the user asks to use a specific service (Food, Cab, Chat):
     - CHECK the 'INSTALLED APPS INVENTORY' above.
     - MATCH the user's intent to an Installed App (e.g., "Food" -> Zomato/Swiggy, "Cab" -> Uber/Ola).
     - ACTION: IMMEDIATELY use `open_app_by_name` with the best match.
     - DO NOT assume you are already in the correct app. Open it explicitly.

2. **HISTORY ANALYSIS**:
   - READ the "Journey So Far" or "COMPLETED STEPS" carefully.
   - DID THE LAST ACTION FAIL? If you tried to tap something and the screen didn't change (Verify timestamps if possible), DO NOT TRY THE EXACT SAME THING.
   - If you are in a loop (e.g., Tapping "Next" repeatedly), STOP and try a different strategy (e.g., scroll down, dismiss popup, or use a different identifier).

3. **OBSERVATION**:
   - Look at the "CURRENT SCREEN INTELLIGENCE".
   - Is the target element actually visible in `INTERACTIVE ELEMENTS MAP` or `ACCESSIBILITY NAVIGATION TREE`?
   - If NOT visible, do NOT hallucinate it. You MUST scroll to find it.
   - If VISION FALLBACK ACTIVE is indicated below, use the provided visual screenshot to find elements. Use `perform_tap` with estimated {x, y} coordinates.

3. **STRATEGY**:
   - Planning to fill a form? Plan the sequence: Tap Name -> Type Name -> Tap Email -> Type Email.
   - **DATE/TIME PICKERS**: Do NOT tap the same number repeatedly. Use `perform_internal_scroll` on the wheel/column to change values.
   - Do not rely on "Fresh Eyes". Relate the current screen to your goal and past actions.

═══════════════════════════════════════════════════════════════

🚀 AVAILABLE ACTIONS:

📱 INTERACTIONS:
• take_screenshot - Capture current screen state
• tap_element_by_text {"text": "exact_text"} - Tap by visible text
• tap_element_by_index {"index": number} - Tap by accessibility index (MOST RELIABLE)
• tap_element_by_bounds {"left":x,"top":y,"right":x2,"bottom":y2} - Tap by coordinates
• tap_ocr_line {"line": 3} - Tap by OCR line number (BEST for duplicate text)
• tap_ocr_text {"text": "visible_text", "occurrence": 1} - Tap OCR text (use occurrence for duplicates)
• tap_ocr_bounds {"left":x,"top":y,"right":x2,"bottom":y2} - Tap OCR bounds
• perform_tap {"x":x,"y":y} - Direct coordinate tap

🌐 AI VISION TAP (RECOMMENDED when accessibility fails):
• tap_vision {"description": "What to tap", "x": 500, "y": 500}
  - Use this when VISION FALLBACK is active or accessibility tree doesn't have your target.
  - YOU determine the x,y coordinates by looking at the screenshot.
  - x,y are NORMALIZED coordinates (0-1000) relative to image width/height.
  - (0,0) = Top-Left, (1000,1000) = Bottom-Right.

🎮 NAVIGATION:
• perform_swipe {"startX":x1,"startY":y1,"endX":x2,"endY":y2}
• perform_scroll {"direction": "up/down/left/right"}
• perform_back
• perform_home
• perform_enter

⌨️ TEXT INPUT:
• type_text {"text":"your text here"}
  - Primary text input method. Uses IME for direct injection.
• advanced_type_text {"text":"content","clearFirst":true,"delayMs":100}
  - Same as type_text with optional parameters.
• perform_backspace {}
  - Deletes one character (or use loop for more).
• perform_internal_scroll {"index": 5, "direction": "up/down/left/right"}
  - **REQUIRED for pickers (Date/Time), wheels, and inner lists.**
  - Use instead of tapping for scrollable widgets.

🚀 APP MANAGEMENT:
• open_app_by_name {"appName": "App Name"}

═══════════════════════════════════════════════════════════════

✅ RESPONSE FORMAT

You must output your response in TWO parts:
1. A `<thought>` block where you analyze the history, screen state, and plan your move.
2. A JSON block with the final specific action.

Example:
<thought>
I see the "Login" button at index 5.
Looking at history, I just typed the password.
The virtual keyboard is visible.
I will now tap the login button to proceed.
</thought>
```json
{
  "action": "tap_element_by_index",
  "parameters": {"index": 5},
  "description": "Tapping login button",
  "is_complete": false,
  "reasoning": "Submitting credentials after typing password."
}
```

RULES:
- "is_complete": true ONlY when the overarching task is DONE.
- ONE action per JSON.
- DO NOT hallucinate elements. If it's not in the lists, scroll or look harder.

## 🎯 Key Patterns

1. **Always start by checking current state** - Look at history and installed apps
2. **Open the correct app first** - Use `open_app_by_name` based on INSTALLED APPS list
3. **Follow logical interaction flow** - Tap → Type → Submit
4. **Use `is_complete: true`** only when the entire task chain is done
5. **Reference specific indices/elements** from the screen intelligence data
6. **Chain actions across multiple apps** when needed (Swiggy → Messages)
''';

    // If we have a stored error from a retry, inject it prominently
    if (_lastError != null) {
      prompt += '''
\n❌ PREVIOUS ACTION FAILED (Attempt $_stepRetryCount/3)
Error: $_lastError
Action: $_lastFailedAction
⚠️ RECOVERY INSTRUCTIONS: The previous attempt failed. DO NOT REPEAT the exact same action.
1. If "Element not found": Scroll to find it, or use Vision (tap_ocr_text) or Coordinate Tap.
2. If "Text input failed": Try clicking the field first, or use a looser match.
3. If "Stuck": Change strategy completely.
''';
    }

    return prompt;
  }

  /// Get AI decision for next step
  Future<Map<String, dynamic>?> _getAIDecision(String prompt,
      {String? image}) async {
    try {
      // Prevent duplicate concurrent requests
      if (_llmRequestOngoing) {
        print('⚠️ LLM request already in-flight; skipping duplicate');
        return null;
      }

      // Light throttle to avoid back-to-back calls
      final now = DateTime.now();
      if (_lastLlmRequestedAt != null) {
        final since = now.difference(_lastLlmRequestedAt!);
        if (since < const Duration(milliseconds: 800)) {
          final waitMs = 800 - since.inMilliseconds;
          await Future.delayed(Duration(milliseconds: waitMs));
        }
      }

      _llmRequestOngoing = true;
      _lastLlmRequestedAt = DateTime.now();
      _lastLlmRequestedAt = DateTime.now();
      print('🧠 Sending prompt to AI${image != null ? ' (with image)' : ''}...');

      // Log prompt
      onLog?.call('prompt', prompt);

      String? response;
      if (image != null) {
        response = await _aiClient!.generateContentWithImage(prompt, image);
      } else {
        response = await _aiClient!.generateContent(prompt);
      }

      if (response == null || response.isEmpty) {
        onLog?.call('error', 'Empty response from AI');
        print('❌ Empty response from AI');
        return null;
      }
      
      // Log raw response
      onLog?.call('response', response);

      print('🤖 AI Response received');
      print('📄 Raw response: $response');

      // Extract JSON from response
      final jsonResponse = _extractJsonFromResponse(response);
      if (jsonResponse == null) {
        print('❌ Failed to parse JSON from AI response');
        print('📄 Response was: $response');
        return null;
      }

      print('✅ Successfully parsed AI decision');
      return jsonResponse;
    } catch (e) {
      print('❌ Error getting AI decision: $e');
      return null;
    } finally {
      _llmRequestOngoing = false;
      _lastLlmRequestedAt = DateTime.now();
    }
  }

  /// Extract JSON from AI response, robustly handling thought blocks
  Map<String, dynamic>? _extractJsonFromResponse(String response) {
    try {
      String cleanResponse = response.trim();

      // 1. Try to extract from json code block first (most reliable)
      final codeBlockRegex = RegExp(r'```json\s*(\{[\s\S]*?\})\s*```');
      final codeBlockMatch = codeBlockRegex.firstMatch(cleanResponse);
      
      if (codeBlockMatch != null) {
        final jsonStr = codeBlockMatch.group(1);
        if (jsonStr != null) {
          return jsonDecode(jsonStr) as Map<String, dynamic>;
        }
      }

      // 2. Fallback: Find the first/last brace pair that looks like a JSON object
      final startIndex = cleanResponse.indexOf('{');
      final endIndex = cleanResponse.lastIndexOf('}');

      if (startIndex != -1 && endIndex != -1 && startIndex < endIndex) {
        final jsonStr = cleanResponse.substring(startIndex, endIndex + 1);
        return jsonDecode(jsonStr) as Map<String, dynamic>;
      }

      print('❌ No valid JSON found in response');
      return null;
    } catch (e) {
      print('❌ JSON parsing error: $e');
      return null;
    }
  }

  /// Process and execute AI decision
  Future<bool> _processAIDecision(Map<String, dynamic> decision, int screenHash) async {
    try {
      // Extract action details (may still be present even if is_complete=true)
      final isComplete = decision['is_complete'] == true;
      final action = decision['action'] as String?;
      final parameters = decision['parameters'] as Map<String, dynamic>? ?? {};
      final description = decision['description'] as String?;
      final reasoning = decision['reasoning'] as String?;
      final summary = decision['summary'] as String?;
      final visualState = decision['visual_state'] as String?;
      final nextSteps = decision['next_steps'] as String?;

      // Update narrative summary & thinking state if provided
      if (_session != null) {
        if (summary != null) _session!.updateSummary(summary);
        if (visualState != null) _session!.updateVisualState(visualState);
        if (nextSteps != null) _session!.updateNextSteps(nextSteps);
      }

      if (!isComplete && action == null) {
        return false;
      }

      // Validate action sequence to prevent shortcuts
      if (action != null && !_validateActionSequence(action, parameters)) {
        return false;
      }
      
      // STRICT BOUNDARY CHECK: Prevent Agent from Interacting with Itself
      if (_lastContext != null && _lastContext!['current_app'] is Map) {
         final currentFnPkg = (_lastContext!['current_app']['packageName'] as String?) ?? '';
         
         // Using hardcoded package name of our own app
         if (currentFnPkg == 'com.vibeagent.dude') {
             // If we are automating inside "Dude", ONLY allow leaving the app or opening another app
             if (action != 'perform_home' && action != 'perform_back' && action != 'stopAutomation' && action != 'open_app_by_name') {
                 print('🚫 BOUNDARY VIOLATION: Agent attempting to interact with own UI ($action). Forcing Home.');
                 _notifyMessage('⚠️ Safety Boundary: Preventing self-interaction. Returning to Home Screen.');
                 
                 // Override action to perform_home
                 await _executeAction('perform_home', {});
                 await Future.delayed(const Duration(seconds: 1));
                 return true;
             }
         }
      }

      // Send the raw JSON decision to UI instead of descriptive messages
      _notifyMessage(jsonEncode(decision));

      // Execute the action if provided and task is not complete
      bool success = true;
      if (action != null && !isComplete) {
        success = await _executeAction(action, parameters);
      }

      // Record in session
      if (_session != null) {
        _session!.addAction(
          action ?? 'unknown',
          parameters,
          success ? 'Success' : 'Failed',
          screenHash
        );
      }

      // If action failed, treating it as a step failure for retry logic
      if (!success && !isComplete) {
        print('❌ Action failed logically: $action');
        _stepRetryCount++;
        _lastError = 'Action returned failure (false). Check logs for details.';
        _lastFailedAction = action;

        if (_stepRetryCount >= 3) {
           _notifyError('Step continuously failed after 3 retries.');
           _stepRetryCount = 0;
           _lastError = null;
           _lastFailedAction = null;
           return false; // Stop finally
        }
        
        // Wait and RETRY (continue loop)
        await Future.delayed(const Duration(seconds: 2));
        return true; 
      }

      // Reset retry state on successful action
      _stepRetryCount = 0;
      _lastError = null;
      _lastFailedAction = null;

      // If LLM marked complete, validation passed
      if (isComplete) {
        // Task completion - send final status as JSON
        // When LLM marking complete means task succeeded
        final completionStatus = {
          'task_completed': true,
          'success': true, // LLM marking complete means task succeeded
          'task': _currentTask,
          'final_action': action,
          'description': description ?? 'Automation finished'
        };
        _notifyMessage(jsonEncode(completionStatus));
        // Notify Android to send broadcast for voice service overlay closing
        _notifyComplete();
        return false;
      }

      // Reset retry state on successful action
      _stepRetryCount = 0;
      _lastError = null;
      _lastFailedAction = null;

      return success;
    } catch (e) {
      print('❌ Error executing AI decision: $e');
      _stepRetryCount++;
      _lastError = e.toString();
      _lastFailedAction = decision['action'];
      
      if (_stepRetryCount >= 3) {
        _notifyError('Step failed after 3 retries: $e');
        _stepRetryCount = 0;
        _lastError = null; // Clear error after max retries
        _lastFailedAction = null;
        return false; // Stop automation loop
      }
      
      // Wait before retry
      await Future.delayed(const Duration(seconds: 2));
      return true; // Continue automation loop to retry
    }
  }

  /// Validate action sequence to prevent shortcuts
  bool _validateActionSequence(String action, Map<String, dynamic> parameters) {
    // Check for common shortcut patterns
    if (action == 'type_text') {
      // Check if we recently clicked on an input field or search button
      final recentActions = _session != null ? _session!.recentActions : <ActionRecord>[];
      
      final hasRecentInputInteraction = recentActions.any((step) {
        // Simple check based on action name since we lost UI context in ActionRecord for now
        // TODO: Enhance ActionRecord to store interaction type if needed
        return step.action.contains('tap') || step.action.contains('click');
      });

      if (!hasRecentInputInteraction && recentActions.isNotEmpty) {
        _notifyMessage(
            '🚫 SHORTCUT DETECTED: Cannot type text without first clicking an input field or search button');
        return false;
      }
    }

    // Validate search-related actions
    if (action == 'type_text' &&
        (_currentTask?.toLowerCase().contains('search') ?? false)) {
      final text = parameters['text'] as String? ?? '';
      if (text.isNotEmpty) {
        final recentActions = _session != null ? _session!.recentActions : <ActionRecord>[];
        final recentSearchClick = recentActions.any((step) {
          // Simplified check
           return step.action.contains('tap') || step.action.contains('click');
        });

        if (!recentSearchClick) {
          _notifyMessage(
              '🚫 SEARCH SHORTCUT DETECTED: Must click search button/field before typing search query');
          return false;
        }
      }
    }

    return true;
  }

  /// Extract UI context from action
  Map<String, dynamic> _extractUIContext(
      String action, Map<String, dynamic> parameters, String? description) {
    final context = <String, dynamic>{};
    final desc = description?.toLowerCase() ?? '';

    // Detect search-related interactions
    context['is_search_related'] = desc.contains('search') ||
        desc.contains('find') ||
        (action == 'type_text' &&
            (_currentTask?.toLowerCase().contains('search') ?? false));

    // Detect input field interactions
    context['is_input_interaction'] = desc.contains('input') ||
        desc.contains('field') ||
        desc.contains('text') ||
        desc.contains('edit') ||
        action == 'type_text';

    // Detect button/clickable interactions
    context['is_button_click'] = action == 'find_and_click' ||
        action == 'perform_tap' ||
        action.startsWith('tap_element') ||
        action.startsWith('tap_ocr') ||
        desc.contains('button') ||
        desc.contains('click');

    // Extract target element text for clicks
    if (action == 'find_and_click' && parameters.containsKey('text')) {
      context['target_text'] = parameters['text'];
    }

    // Extract typed text
    if (action == 'type_text' && parameters.containsKey('text')) {
      context['typed_text'] = parameters['text'];
    }

    return context;
  }

  /// Classify the type of interaction
  String _classifyInteractionType(
      String action, Map<String, dynamic> parameters, String? description) {
    final desc = description?.toLowerCase() ?? '';

    if (desc.contains('search') && action.contains('click')) {
      return 'search_initiation';
    }

    if (action == 'type_text' &&
        (_currentTask?.toLowerCase().contains('search') ?? false)) {
      return 'search_query_input';
    }

    if (action == 'type_text') {
      return 'text_input';
    }

    if (action == 'find_and_click' || action == 'perform_tap' || action.startsWith('tap_element') || action.startsWith('tap_ocr')) {
      return 'ui_element_click';
    }

    if (action == 'perform_scroll') {
      return 'navigation_scroll';
    }

    if (action == 'open_app_by_name') {
      return 'app_launch';
    }

    return 'general_action';
  }

  /// Calculate Levenshtein distance for fuzzy matching
  int _levenshteinDistance(String s1, String s2) {
    if (s1 == s2) return 0;
    if (s1.isEmpty) return s2.length;
    if (s2.isEmpty) return s1.length;

    List<int> v0 = List<int>.filled(s2.length + 1, 0);
    List<int> v1 = List<int>.filled(s2.length + 1, 0);

    for (int i = 0; i < s2.length + 1; i++) v0[i] = i;

    for (int i = 0; i < s1.length; i++) {
      v1[0] = i + 1;
      for (int j = 0; j < s2.length; j++) {
        int cost = (s1.codeUnitAt(i) == s2.codeUnitAt(j)) ? 0 : 1;
        v1[j + 1] = [v1[j] + 1, v0[j + 1] + 1, v0[j] + cost]
            .reduce((a, b) => a < b ? a : b);
      }
      for (int j = 0; j < s2.length + 1; j++) v0[j] = v1[j];
    }
    return v1[s2.length];
  }

  /// Check if text matches fuzzily
  bool _isFuzzyMatch(String text, String target) {
    final t = text.toLowerCase().trim();
    final tg = target.toLowerCase().trim();
    if (t.contains(tg) || tg.contains(t)) return true;
    
    // Allow for small typos (20% length tolerance)
    final dist = _levenshteinDistance(t, tg);
    final maxLength = t.length > tg.length ? t.length : tg.length;
    if (maxLength == 0) return false;
    
    return dist <= (maxLength * 0.2).ceil();
  }

  /// Format OCR blocks into indexed lines with position hints for disambiguation
  /// Returns formatted string with line indices that can be used with tap_ocr_line action
  String _formatOcrTextWithLineNumbers(List ocrBlocks, {double? imageWidth, double? imageHeight}) {
    if (ocrBlocks.isEmpty) return '[No OCR text detected]';
    
    final lines = <Map<String, dynamic>>[];
    int lineIndex = 1;
    
    // Track text occurrences to mark duplicates
    final textOccurrences = <String, int>{};
    
    // First pass: collect all lines with their info
    for (final block in ocrBlocks) {
      if (block is! Map) continue;
      final blockLines = block['lines'];
      if (blockLines is! List) continue;
      
      for (final line in blockLines) {
        if (line is! Map) continue;
        final text = line['text']?.toString().trim() ?? '';
        if (text.isEmpty) continue;
        
        // Get bounds for position calculation
        final bb = line['boundingBox'];
        String positionHint = '';
        if (bb is Map && imageHeight != null && imageHeight > 0) {
          final centerY = (bb['centerY'] as num?)?.toDouble() ?? 0.0;
          final centerX = (bb['centerX'] as num?)?.toDouble() ?? 0.0;
          
          // Vertical position
          final vPos = centerY < imageHeight / 3 ? 'top' 
              : centerY < (imageHeight * 2 / 3) ? 'mid' 
              : 'bot';
          
          // Horizontal position (if imageWidth available)
          String hPos = '';
          if (imageWidth != null && imageWidth > 0) {
            hPos = centerX < imageWidth / 3 ? '-left'
                : centerX < (imageWidth * 2 / 3) ? '' 
                : '-right';
          }
          
          positionHint = '($vPos$hPos)';
        }
        
        // Track occurrences for duplicate marking
        final textLower = text.toLowerCase();
        textOccurrences[textLower] = (textOccurrences[textLower] ?? 0) + 1;
        
        lines.add({
          'index': lineIndex,
          'text': text,
          'positionHint': positionHint,
          'textLower': textLower,
          'bounds': bb,
        });
        lineIndex++;
      }
    }
    
    if (lines.isEmpty) return '[No OCR lines detected]';
    
    // Second pass: build formatted output with occurrence markers for duplicates
    final occurrenceCounters = <String, int>{};
    final buffer = StringBuffer();
    
    for (final line in lines) {
      final text = line['text'] as String;
      final textLower = line['textLower'] as String;
      final posHint = line['positionHint'] as String;
      final idx = line['index'] as int;
      
      // Track occurrence number for this text
      occurrenceCounters[textLower] = (occurrenceCounters[textLower] ?? 0) + 1;
      final occNum = occurrenceCounters[textLower]!;
      final totalOcc = textOccurrences[textLower] ?? 1;
      
      // Add occurrence marker only if there are duplicates
      String occMarker = '';
      if (totalOcc > 1) {
        occMarker = ' [#$occNum/$totalOcc]';
      }
      
      buffer.writeln('[L$idx] $text $posHint$occMarker');
    }
    
    return buffer.toString().trim();
  }
  
  /// Get a specific OCR line by its index (1-based)
  /// Returns the line map with boundingBox if found
  Map<String, dynamic>? _getOcrLineByIndex(List ocrBlocks, int targetIndex) {
    if (ocrBlocks.isEmpty || targetIndex < 1) return null;
    
    int lineIndex = 1;
    for (final block in ocrBlocks) {
      if (block is! Map) continue;
      final blockLines = block['lines'];
      if (blockLines is! List) continue;
      
      for (final line in blockLines) {
        if (line is! Map) continue;
        final text = line['text']?.toString().trim() ?? '';
        if (text.isEmpty) continue;
        
        if (lineIndex == targetIndex) {
          return Map<String, dynamic>.from(line);
        }
        lineIndex++;
      }
    }
    return null;
  }

  /// Find best matching OCR result with hierarchical search
  /// NEW Priority: Exact LINE match → Element → Contains match → Fuzzy
  /// Supports occurrence parameter to select Nth match and position hints
  /// For duplicate text, use occurrence=2 to get the second instance
  /// Returns a map with 'text', 'boundingBox', and 'level' (element/line/block)
  Map<String, dynamic>? _findBestOcrMatch(List ocrBlocks, String targetText, {int? occurrence, String? position}) {
    if (ocrBlocks.isEmpty) return null;
    
    final target = targetText.trim().toLowerCase();
    final allMatches = <Map<String, dynamic>>[];
    
    // Helper to check position filter
    bool matchesPosition(Map? bounds) {
      if (position == null || bounds == null) return true;
      final ctx = _lastContext;
      final imgHeight = (ctx?['ocr_image_height'] as num?)?.toDouble() ?? 0.0;
      if (imgHeight == 0) return true;
      
      final centerY = (bounds['centerY'] as num?)?.toDouble() ?? 0.0;
      final posLower = position!.toLowerCase();
      
      if (posLower == 'top' && centerY < imgHeight / 3) return true;
      if (posLower == 'middle' || posLower == 'mid') {
        if (centerY >= imgHeight / 3 && centerY < imgHeight * 2 / 3) return true;
      }
      if (posLower == 'bottom' || posLower == 'bot') {
        if (centerY >= imgHeight * 2 / 3) return true;
      }
      return position == null; // No position filter = match all
    }
    
    // PRIORITY 1: Exact LINE match (full line text equals target)
    // This prevents matching "Google Pay" when looking for "Pay via GooglePay"
    for (final block in ocrBlocks) {
      if (block is! Map) continue;
      final lines = block['lines'];
      if (lines is! List) continue;
      
      for (final line in lines) {
        if (line is! Map) continue;
        final text = line['text']?.toString().trim().toLowerCase() ?? '';
        
        if (text == target) {
          final bounds = line['boundingBox'];
          if (matchesPosition(bounds)) {
            allMatches.add({
              ...Map<String, dynamic>.from(line),
              'level': 'line',
              'matchType': 'exact',
              'priority': 1
            });
          }
        }
      }
    }
    
    // If we have exact line matches, return the requested occurrence
    if (allMatches.isNotEmpty) {
      final idx = (occurrence ?? 1) - 1;
      return idx < allMatches.length ? allMatches[idx] : allMatches.first;
    }
    
    // PRIORITY 2: Exact ELEMENT (word) match
    for (final block in ocrBlocks) {
      if (block is! Map) continue;
      final lines = block['lines'];
      if (lines is! List) continue;
      
      for (final line in lines) {
        if (line is! Map) continue;
        final elements = line['elements'];
        if (elements is! List) continue;
        
        for (final element in elements) {
          if (element is! Map) continue;
          final text = element['text']?.toString().trim().toLowerCase() ?? '';
          
          if (text == target) {
            final bounds = element['boundingBox'];
            if (matchesPosition(bounds)) {
              allMatches.add({
                ...Map<String, dynamic>.from(element),
                'level': 'element',
                'matchType': 'exact',
                'priority': 2
              });
            }
          }
        }
      }
    }
    
    if (allMatches.isNotEmpty) {
      final idx = (occurrence ?? 1) - 1;
      return idx < allMatches.length ? allMatches[idx] : allMatches.first;
    }
    
    // PRIORITY 3: LINE contains target (partial match)
    for (final block in ocrBlocks) {
      if (block is! Map) continue;
      final lines = block['lines'];
      if (lines is! List) continue;
      
      for (final line in lines) {
        if (line is! Map) continue;
        final text = line['text']?.toString().trim().toLowerCase() ?? '';
        
        if (text.contains(target)) {
          final bounds = line['boundingBox'];
          if (matchesPosition(bounds)) {
            allMatches.add({
              ...Map<String, dynamic>.from(line),
              'level': 'line',
              'matchType': 'contains',
              'priority': 3
            });
          }
        }
      }
    }
    
    if (allMatches.isNotEmpty) {
      final idx = (occurrence ?? 1) - 1;
      return idx < allMatches.length ? allMatches[idx] : allMatches.first;
    }
    
    // PRIORITY 4: Fuzzy match at LINE level
    for (final block in ocrBlocks) {
      if (block is! Map) continue;
      final lines = block['lines'];
      if (lines is! List) continue;
      
      for (final line in lines) {
        if (line is! Map) continue;
        final text = line['text']?.toString() ?? '';
        
        if (_isFuzzyMatch(text, targetText)) {
          final bounds = line['boundingBox'];
          if (matchesPosition(bounds)) {
            allMatches.add({
              ...Map<String, dynamic>.from(line),
              'level': 'line',
              'matchType': 'fuzzy',
              'priority': 4
            });
          }
        }
      }
    }
    
    if (allMatches.isNotEmpty) {
      final idx = (occurrence ?? 1) - 1;
      return idx < allMatches.length ? allMatches[idx] : allMatches.first;
    }
    
    // PRIORITY 5: Fuzzy at ELEMENT level
    for (final block in ocrBlocks) {
      if (block is! Map) continue;
      final lines = block['lines'];
      if (lines is! List) continue;
      
      for (final line in lines) {
        if (line is! Map) continue;
        final elements = line['elements'];
        if (elements is! List) continue;
        
        for (final element in elements) {
          if (element is! Map) continue;
          final text = element['text']?.toString() ?? '';
          
          if (_isFuzzyMatch(text, targetText)) {
            final bounds = element['boundingBox'];
            if (matchesPosition(bounds)) {
              allMatches.add({
                ...Map<String, dynamic>.from(element),
                'level': 'element',
                'matchType': 'fuzzy',
                'priority': 5
              });
            }
          }
        }
      }
    }
    
    if (allMatches.isNotEmpty) {
      final idx = (occurrence ?? 1) - 1;
      return idx < allMatches.length ? allMatches[idx] : allMatches.first;
    }
    
    // PRIORITY 6: BLOCK level fallback
    for (final block in ocrBlocks) {
      if (block is! Map) continue;
      final text = block['text']?.toString().trim().toLowerCase() ?? '';
      
      if (text == target || text.contains(target) || _isFuzzyMatch(text, targetText)) {
        allMatches.add({
          ...Map<String, dynamic>.from(block),
          'level': 'block',
          'matchType': text == target ? 'exact' : (text.contains(target) ? 'contains' : 'fuzzy'),
          'priority': 6
        });
      }
    }
    
    if (allMatches.isNotEmpty) {
      final idx = (occurrence ?? 1) - 1;
      return idx < allMatches.length ? allMatches[idx] : allMatches.first;
    }

    return null;
  }

  /// Legacy wrapper for backward compatibility
  Map<String, dynamic>? _findBestOcrBlock(List ocrBlocks, String targetText) {
    return _findBestOcrMatch(ocrBlocks, targetText);
  }

  /// Get bounds from OCR result (works for block, line, or element)
  Map<String, dynamic> _getBoundsFromOcrBlock(Map<String, dynamic> block) {
    // New structure: boundingBox is a map with left, top, right, bottom, centerX, centerY
    if (block.containsKey('boundingBox')) {
      final bb = block['boundingBox'];
      if (bb is Map) {
        return {
          'left': (bb['left'] as num?)?.toDouble() ?? 0.0,
          'top': (bb['top'] as num?)?.toDouble() ?? 0.0,
          'right': (bb['right'] as num?)?.toDouble() ?? 0.0,
          'bottom': (bb['bottom'] as num?)?.toDouble() ?? 0.0,
          'width': (bb['width'] as num?)?.toDouble() ?? 0.0,
          'height': (bb['height'] as num?)?.toDouble() ?? 0.0,
          'centerX': (bb['centerX'] as num?)?.toDouble() ?? 0.0,
          'centerY': (bb['centerY'] as num?)?.toDouble() ?? 0.0,
        };
      }
    }
    
    // Legacy structure: rect or frame
    if (block.containsKey('rect')) {
       return Map<String, dynamic>.from(block['rect']);
    }
    if (block.containsKey('frame')) {
       return Map<String, dynamic>.from(block['frame']);
    }
    
    // Flat properties fallback
    return {
       'left': (block['left'] as num?)?.toDouble() ?? 0.0,
       'top': (block['top'] as num?)?.toDouble() ?? 0.0,
       'right': (block['right'] as num?)?.toDouble() ?? 0.0,
       'bottom': (block['bottom'] as num?)?.toDouble() ?? 0.0,
    };
  }

  /// Get center from bounds - now uses centerX/centerY if available
  Map<String, double> _getCenterFromBounds(Map<String, dynamic> bounds) {
      // Use pre-computed center if available (from enhanced OCR)
      if (bounds.containsKey('centerX') && bounds.containsKey('centerY')) {
        final cx = (bounds['centerX'] as num?)?.toDouble();
        final cy = (bounds['centerY'] as num?)?.toDouble();
        if (cx != null && cy != null && cx > 0 && cy > 0) {
          return {'x': cx, 'y': cy};
        }
      }
      
      // Fallback to manual calculation
      final left = (bounds['left'] as num?)?.toDouble() ?? 0.0;
      final top = (bounds['top'] as num?)?.toDouble() ?? 0.0;
      final right = (bounds['right'] as num?)?.toDouble() ?? 0.0;
      final bottom = (bounds['bottom'] as num?)?.toDouble() ?? 0.0;
      
      // If width/height are provided
      final width = (bounds['width'] as num?)?.toDouble() ?? (right - left);
      final height = (bounds['height'] as num?)?.toDouble() ?? (bottom - top);
      
      return {
        'x': left + width / 2,
        'y': top + height / 2,
      };
  }

  Map<String, dynamic>? _findElementByText(List elements, String targetText) {
    // First pass: Exact match (case-insensitive)
    for (int i = 0; i < elements.length; i++) {
      try {
        final element = elements[i];
        if (element is Map) {
          final elementMap = Map<String, dynamic>.from(element);
          final text = elementMap['text']?.toString() ?? '';
          final contentDesc = elementMap['contentDescription']?.toString() ?? '';

          if (text.toLowerCase() == targetText.toLowerCase() ||
              contentDesc.toLowerCase() == targetText.toLowerCase()) {
            return {...elementMap, 'index': i, 'matched_text': text.isNotEmpty ? text : contentDesc};
          }
        }
      } catch (_) {}
    }

    // Second pass: Fuzzy / Contains match
    for (int i = 0; i < elements.length; i++) {
      try {
        final element = elements[i];
        if (element is Map) {
          final elementMap = Map<String, dynamic>.from(element);
          final text = elementMap['text']?.toString() ?? '';
          final contentDesc = elementMap['contentDescription']?.toString() ?? '';

          if (_isFuzzyMatch(text, targetText) || _isFuzzyMatch(contentDesc, targetText)) {
            return {
              ...elementMap,
              'index': i,
              'matched_text': text.isNotEmpty ? text : contentDesc,
            };
          }
        }
      } catch (e) {
        print('Error processing element $i: $e');
        continue;
      }
    }
    return null;
  }

  /// Find element by index
  Map<String, dynamic>? _findElementByIndex(List elements, int index) {
    if (index >= 0 && index < elements.length) {
      try {
        final element = elements[index];
        if (element is Map) {
          final elementMap = Map<String, dynamic>.from(element);
          return {
            ...elementMap,
            'index': index,
          };
        }
      } catch (e) {
        print('Error processing element at index $index: $e');
      }
    }
    return null;
  }

  /// Find element by bounds
  Map<String, dynamic>? _findElementByBounds(List elements, Map<String, dynamic> targetBounds) {
    for (int i = 0; i < elements.length; i++) {
      try {
        final element = elements[i];
        if (element is Map) {
          final elementMap = Map<String, dynamic>.from(element);
          final bounds = elementMap['bounds'];

          if (bounds != null && bounds is Map) {
            final boundsMap = Map<String, dynamic>.from(bounds);
            final left = boundsMap['left']?.toDouble() ?? 0.0;
            final top = boundsMap['top']?.toDouble() ?? 0.0;
            final right = boundsMap['right']?.toDouble() ?? 0.0;
            final bottom = boundsMap['bottom']?.toDouble() ?? 0.0;

            final targetLeft = targetBounds['left']?.toDouble() ?? 0.0;
            final targetTop = targetBounds['top']?.toDouble() ?? 0.0;
            final targetRight = targetBounds['right']?.toDouble() ?? 0.0;
            final targetBottom = targetBounds['bottom']?.toDouble() ?? 0.0;

            // Check if bounds match (with small tolerance)
            if ((left - targetLeft).abs() < 5 &&
                (top - targetTop).abs() < 5 &&
                (right - targetRight).abs() < 5 &&
                (bottom - targetBottom).abs() < 5) {
              return {
                ...elementMap,
                'index': i,
              };
            }
          }
        }
      } catch (e) {
        print('Error processing element $i for bounds matching: $e');
        continue;
      }
    }
    return null;
  }

  /// Get precise tap coordinates from element
  Map<String, double> _getPreciseTapCoordinates(Map<String, dynamic> element) {
    final bounds = element['bounds'];
    if (bounds == null || bounds is! Map) {
      return {'x': 0.0, 'y': 0.0};
    }

    try {
      final boundsMap = Map<String, dynamic>.from(bounds);

      // Get element bounds
      final left = boundsMap['left']?.toDouble() ?? 0.0;
      final top = boundsMap['top']?.toDouble() ?? 0.0;
      final right = boundsMap['right']?.toDouble() ?? 0.0;
      final bottom = boundsMap['bottom']?.toDouble() ?? 0.0;
      final width = boundsMap['width']?.toDouble() ?? (right - left);
      final height = boundsMap['height']?.toDouble() ?? (bottom - top);

      // Calculate center point for optimal clicking
      double tapX = left + (width / 2.0);
      double tapY = top + (height / 2.0);

      // Ensure coordinates are within bounds and not on edges
      final padding = 2.0;
      tapX = tapX.clamp(left + padding, right - padding).toDouble();
      tapY = tapY.clamp(top + padding, bottom - padding).toDouble();

      return {'x': tapX, 'y': tapY};
    } catch (e) {
      print('Error calculating tap coordinates: $e');
      return {'x': 0.0, 'y': 0.0};
    }
  }

  /// Execute precise element tap by text
  Future<bool> _executePreciseElementTap(String targetText, List elements) async {
    final element = _findElementByText(elements, targetText);
    if (element == null) {
      _notifyMessage('❌ Element not found with text: "$targetText"');
      return false;
    }

    final coords = _getPreciseTapCoordinates(element);
    final elementInfo = element['matched_text'] ?? targetText;
    final index = element['index'];

    _notifyMessage('🎯 Found element [$index]: "$elementInfo"');
    _notifyMessage('📍 Precise tap at (${coords['x']!.round()}, ${coords['y']!.round()})');

    // Execute precise tap using ToolsManager
    final result = await ToolsManager.executeTool('perform_tap', {
      'x': coords['x'],
      'y': coords['y'],
    });

    return result['success'] == true;
  }

  /// Execute precise element tap by index
  Future<bool> _executePreciseElementTapByIndex(int index, List elements) async {
    final element = _findElementByIndex(elements, index);
    if (element == null) {
      _notifyMessage('❌ Element not found at index: $index');
      return false;
    }

    final coords = _getPreciseTapCoordinates(element);
    final elementText = element['text']?.toString() ??
                      element['contentDescription']?.toString() ??
                      element['type']?.toString() ?? 'Unknown';

    _notifyMessage('🎯 Tapping element [$index]: "$elementText"');
    _notifyMessage('📍 Precise tap at (${coords['x']!.round()}, ${coords['y']!.round()})');

    // Save tap coordinates for replay functionality
    _lastTapCoordinates = {
      'x': coords['x'],
      'y': coords['y'],
      'element_text': elementText,
      'element_index': index,
    };

    // Execute precise tap using ToolsManager
    final result = await ToolsManager.executeTool('perform_tap', {
      'x': coords['x'],
      'y': coords['y'],
    });

    return result['success'] == true;
  }

  /// Execute precise element tap by bounds
  Future<bool> _executePreciseElementTapByBounds(Map<String, dynamic> targetBounds, List elements) async {
    final element = _findElementByBounds(elements, targetBounds);
    if (element == null) {
      _notifyMessage('❌ Element not found with specified bounds');
      return false;
    }

    final coords = _getPreciseTapCoordinates(element);
    final index = element['index'];
    final elementText = element['text']?.toString() ??
                      element['contentDescription']?.toString() ??
                      element['type']?.toString() ?? 'Unknown';

    _notifyMessage('🎯 Found element [$index]: "$elementText"');
    _notifyMessage('📍 Precise tap at (${coords['x']!.round()}, ${coords['y']!.round()})');

    // Execute precise tap using ToolsManager
    final result = await ToolsManager.executeTool('perform_tap', {
      'x': coords['x'],
      'y': coords['y'],
    });

    return result['success'] == true;
  }

  /// Execute a tap action during replay using saved coordinates
  Future<bool> _executeReplayTap(Map<String, dynamic> actionData) async {
    // Check if we have saved coordinates from the original action
    if (actionData.containsKey('saved_coordinates')) {
      final coords = actionData['saved_coordinates'] as Map<String, dynamic>;
      final x = coords['x'] as double?;
      final y = coords['y'] as double?;
      
      if (x != null && y != null) {
        _notifyMessage('🔄 Replaying tap at saved coordinates (${x.round()}, ${y.round()})');
        
        // Execute tap using saved coordinates
        final result = await ToolsManager.executeTool('perform_tap', {
          'x': x,
          'y': y,
        });
        
        return result['success'] == true;
      }
    }
    
    // Fallback to regular execution if no saved coordinates
    _notifyMessage('⚠️ No saved coordinates found, using regular tap execution');
    final parameters = actionData['parameters'] as Map<String, dynamic>? ?? {};
    return await _executeAction('tap_element_by_index', parameters);
  }

  /// Execute an action directly for replay functionality
  Future<bool> executeActionDirectly(Map<String, dynamic> actionData) async {
    try {
      final action = actionData['action'] as String?;
      final parameters = actionData['parameters'] as Map<String, dynamic>? ?? {};
      
      if (action == null) {
        print('❌ No action specified in action data');
        return false;
      }
      
      // Special handling for tap_element_by_index during replay
      if (action == 'tap_element_by_index') {
        return await _executeReplayTap(actionData);
      }
      
      return await _executeAction(action, parameters);
    } catch (e) {
      print('❌ Error executing action directly: $e');
      return false;
    }
  }

  /// Execute a specific action with enhanced precision tapping
  Future<bool> _executeAction(String action, Map<String, dynamic> parameters) async {
    try {
      print('🔧 Executing: $action with params: $parameters');

      if (action == 'message') {
        final text = parameters['text'] as String?;
        if (text != null) {
          _notifyMessage('💬 $text');
        }
        return true;
      }

      // ===== AI VISION TAP (LLM provides pixel coordinates) =====
      if (action == 'tap_vision') {
        var x = (parameters['x'] as num?)?.toDouble();
        var y = (parameters['y'] as num?)?.toDouble();
        final description = parameters['description'] as String? ?? 'Vision tap';
        
        if (x == null || y == null) {
          _notifyMessage('❌ tap_vision requires x and y coordinates');
          return false;
        }

        // Convert normalized coordinates (0-1000) to device pixels
        // CRITICAL FIX: ocr_image_width might be the RESIZED image width (e.g. 480p).
        // performTap expects ACTUAL DEVICE PIXELS (e.g. 1080p).
        // 0-1000 coordinates are relative to the image content, so mapping them to 0-1000 of Screen Width works.
        // We must normalize against SCREEN RESOLUTION, not image resolution.

        double w = 0.0;
        double h = 0.0;
        
        // Try getting cached screen dims first (if we stored them)
        if (_lastContext != null && _lastContext!.containsKey('screen_width')) {
             w = (_lastContext?['screen_width'] as num?)?.toDouble() ?? 0.0;
             h = (_lastContext?['screen_height'] as num?)?.toDouble() ?? 0.0;
        }

        if (w <= 0 || h <= 0) {
             // Fetch real dimensions from device
             final dims = await ToolsManager.executeTool('get_screen_dimensions', {});
             if (dims['success'] == true && dims['data'] is Map) {
                 final d = dims['data'];
                 w = (d['width'] as num?)?.toDouble() ?? 0.0;
                 h = (d['height'] as num?)?.toDouble() ?? 0.0;
                 
                 // Cache for this session
                 if (_lastContext != null) {
                    _lastContext!['screen_width'] = w;
                    _lastContext!['screen_height'] = h;
                 }
             }
        }
        
        if (w > 0 && h > 0) {
             _notifyMessage('📏 Normalizing vision tap (0-1000) to screen ${w.round()}x${h.round()}');
             x = (x / 1000.0) * w;
             y = (y / 1000.0) * h;
             _notifyMessage('📍 Converted to pixels: (${x!.round()}, ${y!.round()})');
        } else {
             // Use fallback or previous incorrect behavior?
             // If we can't get screen dims, we might default to 1080x1920 or fail?
             // Defaulting to 1080x1920 is safer than 0x0
             _notifyMessage('⚠️ Could not get screen dimensions. Assuming default 1080x1920.');
             w = 1080.0;
             h = 1920.0;
             x = (x / 1000.0) * w;
             y = (y / 1000.0) * h;
        }
        
        _notifyMessage('👁️ Vision tap: "$description" at (${x!.round()}, ${y!.round()})');
        final result = await ToolsManager.executeTool('perform_tap', {'x': x, 'y': y});
        return result['success'] == true;
      }

      if (action.startsWith('tap_element_by_text') || action == 'find_and_click') {
        final context = _lastContext;
        if (context == null) return false;
        
        final elements = context['screen_elements'] as List? ?? [];
        final targetText = parameters['text'] as String? ?? '';
        
        bool success = await _executePreciseElementTap(targetText, elements);
        
        // Automatic Fallback: Vision/OCR
        if (!success) {
           print('⚠️ Accessibility tap failed for "$targetText". Trying OCR/Vision fallback...');
           _notifyMessage('👁️ Accessibility tap failed. Trying Vision match...');
           success = await _executeAction('tap_ocr_text', {'text': targetText});
        }
        
        return success;
      }

      if (action == 'tap_element_by_index') {
        final index = parameters['index'] as int?;
        if (index == null) {
          _notifyMessage('❌ No index specified for element tap');
          return false;
        }

        // Use latest captured elements to avoid duplicate tool calls
        final elements = _getElementsFromLastContext();

        return await _executePreciseElementTapByIndex(index, elements);
      }

      if (action == 'tap_element_by_bounds') {
        final bounds = parameters;
        if (!bounds.containsKey('left') || !bounds.containsKey('top') ||
            !bounds.containsKey('right') || !bounds.containsKey('bottom')) {
          _notifyMessage('❌ Invalid bounds specified for element tap');
          return false;
        }

        // Use latest captured elements to avoid duplicate tool calls
        final elements = _getElementsFromLastContext();

        return await _executePreciseElementTapByBounds(bounds, elements);
      }

      // Ensure input focus before typing - Vision mode uses tap→blind type flow
      if (action == 'type_text' || action == 'advanced_type_text') {
        final isVisionMode = _lastContext?['vision_fallback_active'] == true;
        if (!isVisionMode) {
          // Normal mode: use accessibility-based focus detection
          final textToType = parameters['text']?.toString() ?? '';
          await _ensureInputFocusBeforeTyping(textToType, force: true);
        } else {
          // Vision mode: tap input field via OCR first, then blind type
          _notifyMessage('👁️ Vision mode: Tap input → Blind type');
          await _visionModeTapInputField();
        }
      }

      // OCR-based actions (use when relying on OCR text/regions)
      
      // NEW: Tap by OCR line index - best for duplicate text disambiguation
      if (action == 'tap_ocr_line') {
        final lineNum = parameters['line'] as int?;
        if (lineNum == null || lineNum < 1) {
          _notifyMessage('❌ Invalid line number for OCR tap. Use line >= 1');
          return false;
        }

        // Get OCR blocks from latest context
        final ctx = _lastContext ?? <String, dynamic>{};
        List ocrBlocks = (ctx['ocr_blocks'] is List) ? List.from(ctx['ocr_blocks']) : <dynamic>[];
        
        // Fetch fresh OCR if needed
        if (ocrBlocks.isEmpty && ctx['screenshot_available'] == true) {
          final ss = await ToolsManager.executeTool('take_screenshot', {});
          if (ss['success'] == true && ss['data'] is String) {
            final ocrRes = await ToolsManager.executeTool('perform_ocr', { 'screenshot': ss['data'] });
            if (ocrRes['success'] == true && ocrRes['data'] is Map) {
              final data = Map<String, dynamic>.from(ocrRes['data']);
              _lastContext ??= <String, dynamic>{};
              _lastContext!['ocr_blocks'] = (data['blocks'] is List) ? List.from(data['blocks']) : <dynamic>[];
              ocrBlocks = List.from(_lastContext!['ocr_blocks'] as List);
            }
          }
        }

        if (ocrBlocks.isEmpty) {
          _notifyMessage('❌ No OCR blocks available to tap');
          return false;
        }

        final line = _getOcrLineByIndex(ocrBlocks, lineNum);
        if (line == null) {
          _notifyMessage('❌ OCR line L$lineNum not found');
          return false;
        }

        final text = line['text']?.toString() ?? '';
        final bounds = _getBoundsFromOcrBlock(line);
        final coords = _getCenterFromBounds(bounds);
        _notifyMessage('🎯 OCR line tap [L$lineNum] "$text" at (${coords['x']!.round()}, ${coords['y']!.round()})');
        final result = await ToolsManager.executeTool('perform_tap', { 'x': coords['x'], 'y': coords['y'] });
        return result['success'] == true;
      }
      
      if (action == 'tap_ocr_text') {
        final text = parameters['text'] as String?;
        if (text == null || text.isEmpty) {
          _notifyMessage('❌ No text specified for OCR tap');
          return false;
        }
        
        // Extract occurrence and position parameters for disambiguation
        final occurrence = parameters['occurrence'] as int?;
        final position = parameters['position'] as String?;

        // Prefer OCR from latest context to avoid duplicate runs
        final ctx = _lastContext ?? <String, dynamic>{};
        List ocrBlocks = (ctx['ocr_blocks'] is List) ? List.from(ctx['ocr_blocks']) : <dynamic>[];
        // Only run OCR on-demand if a11y is empty or looks like web AND screenshot is available
        final a11y = ctx['accessibility_tree'];
        final a11yEmpty = !(a11y is List) || a11y.isEmpty;
        final looksWeb = _lastContextLooksLikeWeb();
        final hasScreenshot = ctx['screenshot_available'] == true;
        if (ocrBlocks.isEmpty && hasScreenshot && (a11yEmpty || looksWeb)) {
          final ss = await ToolsManager.executeTool('take_screenshot', {});
          if (ss['success'] == true && ss['data'] is String) {
            final ocrRes = await ToolsManager.executeTool('perform_ocr', { 'screenshot': ss['data'] });
            if (ocrRes['success'] == true && ocrRes['data'] is Map) {
              final data = Map<String, dynamic>.from(ocrRes['data']);
              _lastContext ??= <String, dynamic>{};
              _lastContext!['ocr_text'] = data['text']?.toString() ?? '';
              _lastContext!['ocr_blocks'] = (data['blocks'] is List) ? List.from(data['blocks']) : <dynamic>[];
              ocrBlocks = List.from(_lastContext!['ocr_blocks'] as List);
            }
          }
        }

        if (ocrBlocks.isEmpty) {
          _notifyMessage('❌ No OCR blocks available to tap');
          return false;
        }

        // Use enhanced matching with occurrence/position support
        final block = _findBestOcrMatch(ocrBlocks, text, occurrence: occurrence, position: position);
        if (block == null) {
          _notifyMessage('❌ No matching OCR block for: "$text"${occurrence != null ? " (occurrence $occurrence)" : ""}');
          return false;
        }

        // Log match precision level
        final level = block['level'] ?? 'block';
        final matchType = block['matchType'] ?? 'unknown';
        final matchedText = block['text']?.toString() ?? text;
        
        final bounds = _getBoundsFromOcrBlock(block);
        final coords = _getCenterFromBounds(bounds);
        _notifyMessage('🎯 OCR tap [$level/$matchType] on "$matchedText" at (${coords['x']!.round()}, ${coords['y']!.round()})');
        final result = await ToolsManager.executeTool('perform_tap', { 'x': coords['x'], 'y': coords['y'] });
        return result['success'] == true;

      }

      if (action == 'tap_ocr_bounds') {
        final hasAll = parameters.containsKey('left') && parameters.containsKey('top') && parameters.containsKey('right') && parameters.containsKey('bottom');
        if (!hasAll) {
          _notifyMessage('❌ Invalid OCR bounds');
          return false;
        }
        final coords = _getCenterFromBounds(parameters);
        _notifyMessage('📍 OCR bounds tap at (${coords['x']!.round()}, ${coords['y']!.round()})');
        final result = await ToolsManager.executeTool('perform_tap', { 'x': coords['x'], 'y': coords['y'] });
        return result['success'] == true;
      }

      // Catch perform_swipe with 'direction' parameter (AI hallucination fix)
      if (action == 'perform_swipe' && parameters.containsKey('direction') && !parameters.containsKey('startX')) {
        final direction = parameters['direction']?.toString().toLowerCase() ?? 'left';
        _notifyMessage('🔄 converting directional swipe "$direction" to coordinates');
        
        // Get screen dimensions
        final w = (_lastContext?['ocr_image_width'] as num?)?.toDouble() ?? 
                  (_lastContext?['vision_image_width'] as num?)?.toDouble() ?? 1080.0;
        final h = (_lastContext?['ocr_image_height'] as num?)?.toDouble() ?? 2400.0;
        
        final centerX = w / 2;
        final centerY = h / 2;
        // Swipe distance: 1/3 of the smaller dimension
        final distance = (w < h ? w : h) / 3;
        
        double startX = centerX;
        double startY = centerY;
        double endX = centerX;
        double endY = centerY;
        
        switch (direction) {
          case 'left':
            // Swipe Left: Finger moves Right -> Left (Content moves Right?? No, Swipe Left usually means "Next Page" or "Go Right")
            // Wait, "Swipe Left" generally means dragging finger FROM Right TO Left.
            startX = centerX + distance;
            endX = centerX - distance;
            break;
          case 'right':
            // Swipe Right: Finger moves Left -> Right
            startX = centerX - distance;
            endX = centerX + distance;
            break;
          case 'up':
            // Swipe Up: Finger moves Down -> Up (Scroll Down)
            startY = centerY + distance;
            endY = centerY - distance;
            break;
          case 'down':
            // Swipe Down: Finger moves Up -> Down (Scroll Up)
            startY = centerY - distance;
            endY = centerY + distance;
            break;
        }
        
        parameters['startX'] = startX;
        parameters['startY'] = startY;
        parameters['endX'] = endX;
        parameters['endY'] = endY;
        parameters['duration'] = 300; // Standard swipe duration
      }

      // ===== Perform Backspace =====
      if (action == 'perform_backspace') {
         _notifyMessage('⌫ Backspace');
         // Execute directly via ToolsManager which routes to native IME
         final result = await ToolsManager.executeTool('perform_backspace', {});
         return result['success'] == true;
      }

      // ===== Perform Internal Scroll (Element-centric) =====
      if (action == 'perform_internal_scroll') {
         final direction = parameters['direction']?.toString().toLowerCase() ?? 'down';
         final index = parameters['index'] as int?;
         final text = parameters['text'] as String?;
         
         // Find element target
         Map<String, dynamic>? targetElement;
         final elements = _getElementsFromLastContext();
         
         if (index != null) {
            targetElement = _findElementByIndex(elements, index);
         } else if (text != null) {
            targetElement = _findElementByText(elements, text);
         }
         
         if (targetElement == null) {
            _notifyMessage('❌ Internal scroll failed: Target element not found');
            return false;
         }
         
         final bounds = targetElement['bounds'];
         if (bounds is! Map) {
             _notifyMessage('❌ Internal scroll failed: Element has no bounds');
             return false;
         }
         
         final b = Map<String, dynamic>.from(bounds);
         final left = (b['left'] as num?)?.toDouble() ?? 0.0;
         final top = (b['top'] as num?)?.toDouble() ?? 0.0;
         final right = (b['right'] as num?)?.toDouble() ?? 0.0;
         final bottom = (b['bottom'] as num?)?.toDouble() ?? 0.0;
         final w = (b['width'] as num?)?.toDouble() ?? (right - left);
         final h = (b['height'] as num?)?.toDouble() ?? (bottom - top);
         
         final centerX = left + w / 2;
         final centerY = top + h / 2;
         
         // Calculate swipe coordinates WITHIN the element
         // Use 20% padding to stay safe inside
         final safeW = w * 0.6;
         final safeH = h * 0.6;
         
         double startX = centerX;
         double startY = centerY;
         double endX = centerX;
         double endY = centerY;
         
         // SCROLL SEMANTICS:
         // "down" -> I want to see content below -> Content moves UP -> Finger moves BOTTOM -> TOP
         // "up" -> I want to see content above -> Content moves DOWN -> Finger moves TOP -> BOTTOM
         
         switch (direction) {
             case 'down': // Finger moves Up
                 startY = centerY + (safeH / 2);
                 endY = centerY - (safeH / 2);
                 break;
             case 'up': // Finger moves Down
                 startY = centerY - (safeH / 2);
                 endY = centerY + (safeH / 2);
                 break;
             case 'right': // I want to see right -> Content moves LEFT -> Finger moves RIGHT -> LEFT
                 startX = centerX + (safeW / 2);
                 endX = centerX - (safeW / 2);
                 break;
             case 'left': // I want to see left -> Content moves RIGHT -> Finger moves LEFT -> RIGHT
                 startX = centerX - (safeW / 2);
                 endX = centerX + (safeW / 2);
                 break;
         }
         
         _notifyMessage('🔄 Scroll "$direction" inside element [${targetElement['index']}]');
         _notifyMessage('📍 Swipe: (${startX.round()},${startY.round()}) -> (${endX.round()},${endY.round()})');
         
         final result = await ToolsManager.executeTool('perform_swipe', {
             'startX': startX,
             'startY': startY,
             'endX': endX,
             'endY': endY,
             'duration': 400 // Slightly slower for precision
         });
         
         return result['success'] == true;
      }

      // Check if action is available
      if (!ToolsManager.isToolAvailable(action)) {
        _notifyMessage('❌ Action not available: $action');
        return false;
      }

      // **Vision Mode Text Input**: Use robust_text_input for reliable, self-healing text input
      // This replaces the fragile 3-step process (set clipboard → tap → paste) with a comprehensive
      // solution that validates focus, retries on failure, and uses multiple fallback strategies
      if ((action == 'type_text' || action == 'advanced_type_text') && _useVision) {
        try {
          final textToType = parameters['text']?.toString() ?? '';
          if (textToType.isNotEmpty) {
            _notifyMessage('🎯 Vision mode: Using robust text input');
            
            // Use the new robust_text_input tool which handles the entire flow:
            // 1. Sets clipboard
            // 2. Finds and validates input field focus (with multiple strategies)
            // 3. Attempts paste with fallback to ACTION_SET_TEXT
            // 4. Retries up to 3 times with exponential backoff
            final robustResult = await ToolsManager.executeTool('robust_text_input', {
              'text': textToType,
              'maxRetries': 3,
            });
            
            if (robustResult['success'] == true) {
              _notifyMessage('✅ Robust text input successful');
              return true;
            } else {
              _notifyMessage('⚠️ Robust text input failed, trying fallback...');
              // Fallback: try normal typing if robust method fails
            }
          }
        } catch (e) {
          _notifyMessage('⚠️ Robust text input error: $e, falling back to normal typing');
        }
      }

      // Execute the tool (normal mode or fallback)
      var result = await ToolsManager.executeTool(action, parameters);

      // If typing failed, try to recover by focusing via OCR and retry once
      if ((action == 'type_text' || action == 'advanced_type_text') && result['success'] != true) {
        _notifyMessage('🔁 Retrying ${action} after focusing input via OCR');
        final textToType = parameters['text']?.toString() ?? '';
        await _ensureInputFocusBeforeTyping(textToType, force: true);
        result = await ToolsManager.executeTool(action, parameters);
      }

      return result['success'] == true;
    } catch (e) {
      _notifyError('Tool execution failed: $action - $e');
      return false;
    }
  }

  /// Format screen elements for AI prompt with precise targeting info
  String _formatElements(List elements) {
    if (elements.isEmpty) return 'No interactive elements found.';

    final buffer = StringBuffer();
    buffer.writeln('INTERACTIVE ELEMENTS (use index numbers for tap_element_by_index):');

    for (int i = 0; i < elements.length; i++) {
      try {
        final element = elements[i];
        if (element is Map) {
          try {
            final elementMap = element is Map<String, dynamic>
                ? element
                : Map<String, dynamic>.from(element);
            final text = elementMap['text']?.toString() ?? '';
            final contentDesc = elementMap['contentDescription']?.toString() ?? '';
            final type = elementMap['className']?.toString() ?? elementMap['type']?.toString() ?? 'Unknown';
            final bounds = elementMap['bounds'];
            final clickable = elementMap['clickable'] == true ? '✓ CLICKABLE' : '✗ Not clickable';
            final scrollable = elementMap['scrollable'] == true ? '📜' : '';

            // Format bounds info
            String boundsInfo = 'Unknown bounds';
            if (bounds != null && bounds is Map) {
              final boundsMap = Map<String, dynamic>.from(bounds);
              final x = boundsMap['x'] ?? boundsMap['centerX'] ?? 0;
              final y = boundsMap['y'] ?? boundsMap['centerY'] ?? 0;
              final w = boundsMap['width'] ?? 0;
              final h = boundsMap['height'] ?? 0;
              boundsInfo = 'center($x,$y) size(${w}x$h)';
            }

            // Build display content
            String content;
            if (text.isNotEmpty) {
              content = '"$text"';
            } else if (contentDesc.isNotEmpty) {
              content = '"$contentDesc"';
            } else {
              content = '[No text]';
            }

            buffer.writeln('[$i] $type: $content | $clickable $scrollable | $boundsInfo');
          } catch (e) {
            print('Error processing element $i: $e');
            buffer.writeln('[$i] Error: Could not process element');
          }
        }
      } catch (e) {
        print('Error formatting element $i: $e');
        buffer.writeln('[$i] Error: Could not format element');
      }
    }
    return buffer.toString();
  }

  /// Format accessibility tree for AI prompt with precise targeting info
  String _formatAccessibilityTree(List tree) {
    if (tree.isEmpty) return 'No accessibility tree available.';

    final buffer = StringBuffer();
    buffer.writeln('ACCESSIBILITY TREE (use index numbers for tap_element_by_index):');

    for (int i = 0; i < tree.length; i++) {
      try {
        final node = tree[i];
        if (node is Map) {
          try {
            final nodeMap = node is Map<String, dynamic>
                ? node
                : Map<String, dynamic>.from(node);
            final text = nodeMap['text']?.toString() ?? '';
            final contentDescription = nodeMap['contentDescription']?.toString() ?? '';
            final className = nodeMap['className']?.toString() ?? nodeMap['type']?.toString() ?? 'Node';
            final clickable = nodeMap['clickable'] == true ? '✓ CLICKABLE' : '✗ Not clickable';
            final scrollable = nodeMap['scrollable'] == true ? '��' : '';
            final editable = nodeMap['editable'] == true ? '✏️' : '';
            final bounds = nodeMap['bounds'];

            // Only show elements with meaningful content or interactions
            if (text.isNotEmpty || contentDescription.isNotEmpty ||
                nodeMap['clickable'] == true || nodeMap['scrollable'] == true || nodeMap['editable'] == true) {

              // Format bounds for precise tapping
              String boundsInfo = '';
              if (bounds != null && bounds is Map) {
                final boundsMap = Map<String, dynamic>.from(bounds);
                final left = boundsMap['left'] ?? 0;
                final top = boundsMap['top'] ?? 0;
                final right = boundsMap['right'] ?? 0;
                final bottom = boundsMap['bottom'] ?? 0;
                final centerX = boundsMap['x'] ?? boundsMap['centerX'] ?? ((left + right) / 2).round();
                final centerY = boundsMap['y'] ?? boundsMap['centerY'] ?? ((top + bottom) / 2).round();
                boundsInfo = ' | bounds(L:$left,T:$top,R:$right,B:$bottom) center($centerX,$centerY)';
              }

              // Show content
              String content = '';
              if (text.isNotEmpty && contentDescription.isNotEmpty && text != contentDescription) {
                content = '"$text" / "$contentDescription"';
              } else if (text.isNotEmpty) {
                content = '"$text"';
              } else if (contentDescription.isNotEmpty) {
                content = '"$contentDescription"';
              } else {
                content = '[No text]';
              }

              buffer.writeln('[$i] $className: $content | $clickable $scrollable $editable$boundsInfo');
            }
          } catch (e) {
            print('Error processing tree node $i: $e');
            buffer.writeln('[$i] Error: Could not process tree node');
          }
        }
      } catch (e) {
        print('Error formatting tree node $i: $e');
        // Still show the problematic element for debugging
        buffer.writeln('[$i] Error: Could not format tree node');
      }
    }
    return buffer.toString();
  }




  String _normalizeText(String s) {
    return s.toLowerCase().replaceAll(RegExp(r'\s+'), ' ').trim();
  }

  double _textMatchScore(String text, String target) {
    if (text.contains(target)) return 1.0;
    // token overlap
    final textTokens = text.split(' ').where((t) => t.isNotEmpty).toSet();
    final targetTokens = target.split(' ').where((t) => t.isNotEmpty).toSet();
    if (targetTokens.isEmpty) return 0.0;
    final overlap = textTokens.intersection(targetTokens).length.toDouble();
    final score = overlap / targetTokens.length;
    // also consider prefix similarity
    final prefix = _commonPrefixLength(text, target).toDouble();
    return (score * 0.7) + ((prefix / (target.length == 0 ? 1 : target.length)) * 0.3);
  }

  int _commonPrefixLength(String a, String b) {
    final n = a.length < b.length ? a.length : b.length;
    int i = 0;
    while (i < n && a.codeUnitAt(i) == b.codeUnitAt(i)) {
      i++;
    }
    return i;
  }

  /// Send message to UI
  void _notifyMessage(String message) {
    print('📱 UI Message: $message');
    onMessage?.call(message);
  }

  /// Send error to UI
  void _notifyError(String error) {
    print('❌ UI Error: $error');
    onError?.call(error);
    
    // Notify Android to send broadcast
    _notifyAndroidCompletion(false, error);
  }

  /// Notify task completion
  void _notifyComplete() {
    print('✅ Task automation completed');
    onComplete?.call();
    
    // Notify Android to send broadcast
    _notifyAndroidCompletion(true);
  }

  /// Notify Android of automation completion/failure
  Future<void> _notifyAndroidCompletion(bool success, [String? error]) async {
    try {
      if (success) {
        await _channel.invokeMethod('notifyAutomationComplete');
        print('🔔 Notified Android of automation completion');
      } else {
        await _channel.invokeMethod('notifyAutomationError', {'error': error ?? 'Unknown error'});
        print('🔔 Notified Android of automation error: $error');
      }
    } catch (e) {
      print('❌ Failed to notify Android: $e');
    }
  }

  /// Cleanup resources
  void dispose() {
    _isAutomating = false;
    _isInitialized = false;
    _aiClient = null;
    onMessage = null;
    onError = null;
    onComplete = null;
  }

  /// Ensure an input field is focused before typing by tapping OCR targets like 'search'
  Future<void> _ensureInputFocusBeforeTyping(String intendedText, {bool force = false}) async {
    try {
      // Always tap on input fields before typing to ensure proper focus
      // This prevents typing failures when no focused field is found

      // Use latest context to avoid duplicate capture; capture only if missing
      var context = _lastContext ?? await _captureScreenContext();
      // If we have accessibility elements, try to focus an editable node first
      final a11y = context['accessibility_tree'];
      if (a11y is List && a11y.isNotEmpty) {
        final editableIdx = _findBestUnprocessedEditableIndex(a11y);
        if (editableIdx != -1) {
          final fieldId = 'a11y_$editableIdx';
          // Check if this field was already processed
          if (!_processedFields.contains(fieldId)) {
            _processedFields.add(fieldId);
            _lastTappedField = {'type': 'accessibility', 'index': editableIdx};
            await _executeAction('tap_element_by_index', {'index': editableIdx});
            await Future.delayed(const Duration(milliseconds: 250));
            return;
          }
        }
      }

      List blocks = (context['ocr_blocks'] is List) ? List.from(context['ocr_blocks']) : <dynamic>[];
      if (blocks.isEmpty && context['screenshot_available'] == true && ((a11y is! List) || a11y.isEmpty || _lastContextLooksLikeWeb())) {
        final ss = await ToolsManager.executeTool('take_screenshot', {});
        if (ss['success'] == true && ss['data'] is String) {
          final ocrRes = await ToolsManager.executeTool('perform_ocr', { 'screenshot': ss['data'] });
          if (ocrRes['success'] == true && ocrRes['data'] is Map) {
            final data = Map<String, dynamic>.from(ocrRes['data']);
            _lastContext ??= <String, dynamic>{};
            _lastContext!['ocr_text'] = data['text']?.toString() ?? '';
            _lastContext!['ocr_blocks'] = (data['blocks'] is List) ? List.from(data['blocks']) : <dynamic>[];
            blocks = List.from(_lastContext!['ocr_blocks'] as List);
          }
        }
      }

      if (blocks.isEmpty) return;

      // Target common input/search cues
      final candidates = <String>['search', 'search for', 'type', 'enter', 'find', 'go', 'ok', 'submit'];
      Map<String, dynamic>? best;
      double bestScore = 0.0;
      for (final cue in candidates) {
        final b = _findBestOcrBlock(blocks, cue);
        if (b != null) {
          // Prefer cues close to top areas where search bars usually are
          final bb = _getBoundsFromOcrBlock(b);
          final score = (cue == 'search' || cue == 'search for') ? 1.0 : 0.7;
          final yBonus = (bb['top'] as double) < 400 ? 0.2 : 0.0; // heuristic
          final total = score + yBonus;
          if (total > bestScore) {
            bestScore = total;
            best = b;
          }
        }
      }

      if (best != null) {
        final center = _getCenterFromBounds(_getBoundsFromOcrBlock(best));
        final fieldId = 'ocr_${center['x']!.round()}_${center['y']!.round()}';
        
        // Check if this OCR field was already processed
        if (!_processedFields.contains(fieldId)) {
          _processedFields.add(fieldId);
          _lastTappedField = {'type': 'ocr', 'x': center['x'], 'y': center['y']};
          _notifyMessage('🖱️ Focusing input via OCR at (${center['x']!.round()}, ${center['y']!.round()})');
          await ToolsManager.executeTool('perform_tap', { 'x': center['x'], 'y': center['y'] });
          await Future.delayed(const Duration(milliseconds: 600));
        } else {
          _notifyMessage('⏭️ Skipping already processed OCR field at (${center['x']!.round()}, ${center['y']!.round()})');
        }
      }
    } catch (_) {}
  }

  /// Vision mode: tap on input field using OCR before blind typing
  /// Finds search bars, input fields, or text fields via OCR and taps them
  Future<void> _visionModeTapInputField() async {
    try {
      // Get OCR blocks from last context
      final ctx = _lastContext ?? <String, dynamic>{};
      List blocks = (ctx['ocr_blocks'] is List) ? List.from(ctx['ocr_blocks']) : <dynamic>[];
      
      // If no OCR blocks, try to capture fresh
      if (blocks.isEmpty && ctx['screenshot_available'] == true) {
        final ss = await ToolsManager.executeTool('take_screenshot', {});
        if (ss['success'] == true && ss['data'] is String) {
          final ocrRes = await ToolsManager.executeTool('perform_ocr', { 'screenshot': ss['data'] });
          if (ocrRes['success'] == true && ocrRes['data'] is Map) {
            final data = Map<String, dynamic>.from(ocrRes['data']);
            blocks = (data['blocks'] is List) ? List.from(data['blocks']) : <dynamic>[];
          }
        }
      }
      
      if (blocks.isEmpty) {
        _notifyMessage('⚠️ No OCR data - typing blindly without tap');
        return;
      }
      
      // Search for input field cues in priority order
      final inputCues = <String>['search', 'search for', 'type here', 'enter', 'write', 'message', 'ask', 'input'];
      Map<String, dynamic>? bestMatch;
      
      for (final cue in inputCues) {
        final match = _findBestOcrMatch(blocks, cue);
        if (match != null) {
          bestMatch = match;
          break;
        }
      }
      
      // If no specific cue found, look for text that might be a placeholder
      if (bestMatch == null) {
        // Try to find any element with "..." which often indicates input placeholder
        for (final block in blocks) {
          if (block is! Map) continue;
          final text = block['text']?.toString() ?? '';
          if (text.contains('...') || text.toLowerCase().contains('search') || text.toLowerCase().contains('type')) {
            bestMatch = Map<String, dynamic>.from(block);
            break;
          }
        }
      }
      
      if (bestMatch != null) {
        final bounds = _getBoundsFromOcrBlock(bestMatch);
        final center = _getCenterFromBounds(bounds);
        final level = bestMatch['level'] ?? 'block';
        final matchedText = bestMatch['text']?.toString() ?? '';
        
        _notifyMessage('👆 Vision tap on input: "$matchedText" [$level] at (${center['x']!.round()}, ${center['y']!.round()})');
        await ToolsManager.executeTool('perform_tap', { 'x': center['x'], 'y': center['y'] });
        
        // Wait for keyboard to appear
        await Future.delayed(const Duration(milliseconds: 500));
      } else {
        _notifyMessage('⚠️ No input field found via OCR - typing blindly');
      }
    } catch (e) {
      _notifyMessage('⚠️ Vision tap failed: $e');
    }
  }

  int _findFirstEditableIndex(List a11y) {
    for (int i = 0; i < a11y.length; i++) {
      try {
        final node = a11y[i];
        if (node is Map) {
          final m = Map<String, dynamic>.from(node);
          if (m['editable'] == true || (m['className']?.toString().toLowerCase().contains('edittext') ?? false)) {
            return i;
          }
        }
      } catch (_) {}
    }
    return -1;
  }

  int _findBestUnprocessedEditableIndex(List a11y) {
    for (int i = 0; i < a11y.length; i++) {
      try {
        final node = a11y[i];
        if (node is Map) {
          final m = Map<String, dynamic>.from(node);
          if (m['editable'] == true || (m['className']?.toString().toLowerCase().contains('edittext') ?? false)) {
            final fieldId = 'a11y_$i';
            // Return first unprocessed editable field
            if (!_processedFields.contains(fieldId)) {
              return i;
            }
          }
        }
      } catch (_) {}
    }
    return -1;
  }

  // === Helpers to reuse latest captured context and avoid duplicate tool calls ===
  List<dynamic> _getElementsFromLastContext() {
    final ctx = _lastContext;
    if (ctx == null) return <dynamic>[];
    final a11y = ctx['accessibility_tree'];
    if (a11y is List && a11y.isNotEmpty) {
      return List.from(a11y);
    }
    final screenElements = ctx['screen_elements'];
    if (screenElements is List) return List.from(screenElements);
    return <dynamic>[];
  }

  /// Reset field tracking when screen changes or new form is detected
  void _resetFieldTracking() {
    _processedFields.clear();
    _lastTappedField?.clear();
    _notifyMessage('🔄 Field tracking reset for new screen/form');
  }

  /// Check if screen has changed significantly (new form detected)
  bool _hasScreenChanged(Map<String, dynamic> newContext) {
    if (_lastContext == null) return true;
    
    final oldActivity = _lastContext!['current_activity']?.toString() ?? '';
    final newActivity = newContext['current_activity']?.toString() ?? '';
    
    // Reset tracking if activity changed
    if (oldActivity != newActivity && newActivity.isNotEmpty) {
      return true;
    }
    
    return false;
  }

  /// Detect system dialogs in accessibility tree
  List<Map<String, dynamic>> _detectSystemDialogs(List<dynamic> accessibilityTree, Map<String, dynamic> currentApp) {
    final systemDialogs = <Map<String, dynamic>>[];
    
    try {
      final currentPackage = currentApp['packageName']?.toString() ?? '';
      
      for (int i = 0; i < accessibilityTree.length; i++) {
        final element = accessibilityTree[i];
        if (element is! Map) continue;
        
        final elementMap = Map<String, dynamic>.from(element);
        final className = elementMap['className']?.toString() ?? '';
        final packageName = elementMap['packageName']?.toString() ?? '';
        final text = elementMap['text']?.toString() ?? '';
        final contentDesc = elementMap['contentDescription']?.toString() ?? '';
        
        // Detect system dialogs by various indicators
        bool isSystemDialog = false;
        String dialogType = 'unknown';
        
        // Check for system UI package
        if (packageName == 'com.android.systemui') {
          isSystemDialog = true;
          dialogType = 'system_ui';
        }
        // Check for dialog class names
        else if (className.contains('Dialog') || className.contains('AlertDialog')) {
          isSystemDialog = true;
          dialogType = 'alert_dialog';
        }
        // Check for permission dialogs
        else if (text.toLowerCase().contains('permission') || 
                 contentDesc.toLowerCase().contains('permission') ||
                 text.toLowerCase().contains('allow') ||
                 text.toLowerCase().contains('deny')) {
          isSystemDialog = true;
          dialogType = 'permission_dialog';
        }
        // Check for system settings dialogs
        else if (packageName == 'com.android.settings' && 
                 (className.contains('Dialog') || text.toLowerCase().contains('settings'))) {
          isSystemDialog = true;
          dialogType = 'settings_dialog';
        }
        // Check for notification dialogs
        else if (text.toLowerCase().contains('notification') ||
                 contentDesc.toLowerCase().contains('notification')) {
          isSystemDialog = true;
          dialogType = 'notification_dialog';
        }
        
        if (isSystemDialog) {
          systemDialogs.add({
            'index': i,
            'type': dialogType,
            'className': className,
            'packageName': packageName,
            'text': text,
            'contentDescription': contentDesc,
            'bounds': elementMap['bounds'] ?? {},
            'clickable': elementMap['clickable'] ?? false,
          });
        }
      }
    } catch (e) {
      print('❌ Error detecting system dialogs: $e');
    }
    
    return systemDialogs;
  }
  
  /// Format system dialogs for AI prompt
  String _formatSystemDialogs(List<Map<String, dynamic>> systemDialogs) {
    if (systemDialogs.isEmpty) return '[No system dialogs detected]';
    
    final buffer = StringBuffer();
    buffer.writeln('DETECTED SYSTEM DIALOGS:');
    
    for (final dialog in systemDialogs) {
      final index = dialog['index'] ?? -1;
      final type = dialog['type'] ?? 'unknown';
      final text = dialog['text']?.toString() ?? '';
      final contentDesc = dialog['contentDescription']?.toString() ?? '';
      final packageName = dialog['packageName']?.toString() ?? '';
      final clickable = dialog['clickable'] == true ? 'CLICKABLE' : 'Not clickable';
      
      buffer.writeln('[$index] $type - Package: $packageName');
      if (text.isNotEmpty) buffer.writeln('    Text: "$text"');
      if (contentDesc.isNotEmpty) buffer.writeln('    Description: "$contentDesc"');
      buffer.writeln('    Interaction: $clickable');
      buffer.writeln();
    }
    
    return buffer.toString().trim();
  }
  
  /// Dynamic scroll logic with target condition checking and tree change detection
  Future<bool> performDynamicScroll({
    required String direction,
    required String targetText,
    int maxScrollAttempts = 5,
    int consecutiveIdenticalThreshold = 2,
    Duration scrollWaitDuration = const Duration(milliseconds: 1500),
  }) async {
    try {
      print('🔄 Starting dynamic scroll: direction=$direction, target="$targetText"');
      
      List<String> previousSnapshots = [];
      int consecutiveIdenticalCount = 0;
      bool targetFound = false;
      
      for (int attempt = 1; attempt <= maxScrollAttempts && !targetFound; attempt++) {
        print('📜 Scroll attempt $attempt/$maxScrollAttempts');
        
        // 1. Capture current accessibility tree and OCR snapshot
        final currentContext = await _captureScreenContext();
        final currentSnapshot = _createContextSnapshot(currentContext);
        
        // 2. Check if target condition is satisfied
        targetFound = _checkTargetCondition(currentContext, targetText);
        if (targetFound) {
          print('🎯 Target found before scrolling!');
          return true;
        }
        
        // 3. Check for consecutive identical snapshots
        if (previousSnapshots.isNotEmpty && 
            previousSnapshots.last == currentSnapshot) {
          consecutiveIdenticalCount++;
          print('⚠️ Identical snapshot detected ($consecutiveIdenticalCount/$consecutiveIdenticalThreshold)');
          
          if (consecutiveIdenticalCount >= consecutiveIdenticalThreshold) {
            print('🛑 Reached end of scrollable content in $direction direction');
            
            // Try reverse direction if target not found
            if (attempt < maxScrollAttempts) {
              final reverseDirection = _getReverseDirection(direction);
              print('🔄 Trying reverse direction: $reverseDirection');
              
              return await performDynamicScroll(
                direction: reverseDirection,
                targetText: targetText,
                maxScrollAttempts: maxScrollAttempts - attempt,
                consecutiveIdenticalThreshold: consecutiveIdenticalThreshold,
                scrollWaitDuration: scrollWaitDuration,
              );
            }
            break;
          }
        } else {
          consecutiveIdenticalCount = 0;
        }
        
        // 4. Perform scroll action
        final scrollResult = await ToolsManager.executeTool('perform_scroll', {
          'direction': direction,
        });
        
        if (scrollResult['success'] != true) {
          print('❌ Scroll failed: ${scrollResult['error']}');
          continue;
        }
        
        print('✅ Scroll $direction performed, waiting for UI update...');
        
        // 5. Wait for accessibility tree update or visual change
        await Future.delayed(scrollWaitDuration);
        
        // 6. Capture new accessibility tree and compare
        final newContext = await _captureScreenContext();
        final newSnapshot = _createContextSnapshot(newContext);
        
        // 7. Check target condition after scroll
        targetFound = _checkTargetCondition(newContext, targetText);
        if (targetFound) {
          print('🎯 Target found after scroll!');
          return true;
        }
        
        // Store snapshot for next iteration
        previousSnapshots.add(currentSnapshot);
        
        // Apply fuzzy matching between accessibility and OCR data if needed
        if (!targetFound && newContext['ocr_text'] != null) {
          targetFound = _fuzzyMatchTarget(newContext, targetText);
          if (targetFound) {
            print('🎯 Target found via fuzzy OCR matching!');
            return true;
          }
        }
      }
      
      print('❌ Target "$targetText" not found after $maxScrollAttempts scroll attempts');
      return false;
      
    } catch (e) {
      print('❌ Error in dynamic scroll: $e');
      return false;
    }
  }
  
  /// Create a snapshot of the current context for comparison
  String _createContextSnapshot(Map<String, dynamic> context) {
    try {
      final accessibilityTree = context['accessibility_tree'] as List? ?? [];
      final ocrText = context['ocr_text']?.toString() ?? '';
      
      // Create a hash-like representation of the current state
      final treeTexts = accessibilityTree
          .where((element) => element is Map)
          .map((element) {
            final elementMap = Map<String, dynamic>.from(element);
            final text = elementMap['text']?.toString() ?? '';
            final contentDesc = elementMap['contentDescription']?.toString() ?? '';
            return '$text|$contentDesc';
          })
          .where((text) => text.trim().isNotEmpty)
          .join('\n');
      
      return '$treeTexts\n---OCR---\n$ocrText';
    } catch (e) {
      print('❌ Error creating context snapshot: $e');
      return DateTime.now().millisecondsSinceEpoch.toString();
    }
  }
  
  /// Check if target condition is satisfied in current context
  bool _checkTargetCondition(Map<String, dynamic> context, String targetText) {
    try {
      final accessibilityTree = context['accessibility_tree'] as List? ?? [];
      final ocrText = context['ocr_text']?.toString() ?? '';
      
      // Check accessibility tree for target
      for (final element in accessibilityTree) {
        if (element is! Map) continue;
        
        final elementMap = Map<String, dynamic>.from(element);
        final text = elementMap['text']?.toString() ?? '';
        final contentDesc = elementMap['contentDescription']?.toString() ?? '';
        
        if (text.toLowerCase().contains(targetText.toLowerCase()) ||
            contentDesc.toLowerCase().contains(targetText.toLowerCase())) {
          return true;
        }
      }
      
      // Check OCR text for target
      if (ocrText.toLowerCase().contains(targetText.toLowerCase())) {
        return true;
      }
      
      return false;
    } catch (e) {
      print('❌ Error checking target condition: $e');
      return false;
    }
  }
  
  /// Apply fuzzy matching between accessibility and OCR data
  bool _fuzzyMatchTarget(Map<String, dynamic> context, String targetText) {
    try {
      final ocrText = context['ocr_text']?.toString() ?? '';
      final ocrBlocks = context['ocr_blocks'] as List? ?? [];
      
      // Simple fuzzy matching - check for partial matches
      final targetWords = targetText.toLowerCase().split(' ');
      final ocrWords = ocrText.toLowerCase().split(RegExp(r'\s+'));
      
      int matchedWords = 0;
      for (final targetWord in targetWords) {
        if (targetWord.length < 3) continue; // Skip very short words
        
        for (final ocrWord in ocrWords) {
          if (ocrWord.contains(targetWord) || targetWord.contains(ocrWord)) {
            matchedWords++;
            break;
          }
        }
      }
      
      // Consider it a match if at least 70% of target words are found
      final matchRatio = targetWords.isNotEmpty ? matchedWords / targetWords.length : 0.0;
      return matchRatio >= 0.7;
      
    } catch (e) {
      print('❌ Error in fuzzy matching: $e');
      return false;
    }
  }
  
  /// Get reverse direction for scrolling
  String _getReverseDirection(String direction) {
    switch (direction.toLowerCase()) {
      case 'up': return 'down';
      case 'down': return 'up';
      case 'left': return 'right';
      case 'right': return 'left';
      default: return 'up';
    }
  }

  bool _lastContextLooksLikeWeb() {
    try {
      final ctx = _lastContext;
      if (ctx == null) return false;
      final screenElements = ctx['screen_elements'];
      if (screenElements is! List) return false;
      final hints = _collectClassHints(List.from(screenElements));
      return hints.any((c) => c.contains('WebView') || c.contains('webview') || c.contains('ComposeView'));
    } catch (_) {
      return false;
    }
  }
}