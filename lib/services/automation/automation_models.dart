import 'dart:convert';

/// Represents a single action taken by the automation agent
class ActionRecord {
  final int timestamp;
  final String action;
  final Map<String, dynamic> parameters;
  final String result;
  final int screenHash; // Simple hash of the screen context to detect state changes

  ActionRecord({
    required this.timestamp,
    required this.action,
    required this.parameters,
    required this.result,
    required this.screenHash,
  });

  Map<String, dynamic> toJson() => {
        'timestamp': timestamp,
        'action': action,
        'parameters': parameters,
        'result': result,
        'screenHash': screenHash,
      };
}

/// Manages the session state for an automation task
class AutomationSession {
  final String task;
  List<ActionRecord> _actionHistory = [];
  List<String> milestones = [];
  String currentPhase = "initial";
  
  // Maximum number of recent actions to keep in the "last actions" window
  // Maximum number of recent actions to keep in the "last actions" window
  static const int MAX_HISTORY_WINDOW = 5;

  String summary = ''; // Narrative summary of the session so far
  String lastVisualState = ''; // Agent's description of what it sees (current state)
  String nextSteps = ''; // Agent's plan for immediate next steps

  AutomationSession({required this.task});

  List<ActionRecord> get actionHistory => List.unmodifiable(_actionHistory);
  
  /// Get the recent history window (last N actions)
  List<ActionRecord> get recentActions {
    if (_actionHistory.length <= MAX_HISTORY_WINDOW) {
      return _actionHistory;
    }
    return _actionHistory.sublist(_actionHistory.length - MAX_HISTORY_WINDOW);
  }

  void addAction(String action, Map<String, dynamic> parameters, String result, int screenHash) {
    _actionHistory.add(ActionRecord(
      timestamp: DateTime.now().millisecondsSinceEpoch,
      action: action,
      parameters: parameters,
      result: result,
      screenHash: screenHash,
    ));
    
    // We keep the full history in memory for now, but the prompt will only see recentActions.
    // If memory becomes an issue, we can trim _actionHistory here.
  }

  void updatePhase(String newPhase) {
    currentPhase = newPhase;
  }
  
  void updateSummary(String newSummary) {
    if (newSummary.isNotEmpty) {
      summary = newSummary;
    }
  }

  void updateVisualState(String state) {
    if (state.isNotEmpty) {
      lastVisualState = state;
    }
  }

  void updateNextSteps(String steps) {
    if (steps.isNotEmpty) {
      nextSteps = steps;
    }
  }

  void addMilestone(String milestone) {
    if (!milestones.contains(milestone)) {
      milestones.add(milestone);
    }
  }

  Map<String, dynamic> getSummary() {
    return {
      'task': task,
      'current_phase': currentPhase,
      'milestones': milestones,
      'narrative_summary': summary,
      'last_visual_state': lastVisualState,
      'next_steps': nextSteps,
    };
  }
}

/// Helper to detect loops in the action history with enhanced semantic comparison
class LoopDetection {
  // Thresholds for similarity detection
  static const double COORDINATE_THRESHOLD = 50.0; // pixels
  static const double OCR_SIMILARITY_THRESHOLD = 0.8; // 80% match
  
  static LoopResult check(List<ActionRecord> history) {
    if (history.length < 2) return LoopResult(isLoop: false);
    
    // Check last 3 actions for loops (if we have that many)
    final checkSize = history.length >= 3 ? 3 : 2;
    final recentActions = history.sublist(history.length - checkSize);
    
    // Level 1: Exact loop detection (original behavior)
    final exactLoop = _checkExactLoop(recentActions);
    if (exactLoop.isLoop) return exactLoop;
    
    // Level 2: Semantic loop detection (NEW - catches similar actions)
    final semanticLoop = _checkSemanticLoop(recentActions);
    if (semanticLoop.isLoop) return semanticLoop;
    
    // Level 3: Progress stall detection (screen hash unchanged)
    final progressStall = _checkProgressStall(recentActions);
    if (progressStall.isLoop) return progressStall;
    
    return LoopResult(isLoop: false);
  }

  /// Check for exact action/parameter match (original logic)
  static LoopResult _checkExactLoop(List<ActionRecord> actions) {
    if (actions.length < 3) return LoopResult(isLoop: false);
    
    final first = actions[0];
    final isExactLoop = actions.every((r) => 
      r.action == first.action && 
      r.screenHash == first.screenHash &&
      _areParamsEqual(r.parameters, first.parameters)
    );

    if (isExactLoop) {
      return LoopResult(
        isLoop: true,
        loopType: 'exact',
        suggestion: "Exact action repeated ${actions.length}x with same parameters. Screen state unchanged. Try a completely different approach (e.g., Vision Mode, scroll, or go back).",
        failedActions: actions.map((a) => '${a.action}(${a.parameters})').toList(),
      );
    }
    
    return LoopResult(isLoop: false);
  }

  /// Check for semantically similar actions (NEW)
  static LoopResult _checkSemanticLoop(List<ActionRecord> actions) {
    if (actions.length < 2) return LoopResult(isLoop: false);
    
    final first = actions[0];
    int similarCount = 1; // First action counts as 1
    
    for (int i = 1; i < actions.length; i++) {
      if (_areActionsSemanticallyimilar(first, actions[i])) {
        similarCount++;
      }
    }
    
    // Trigger if 2+ out of last 3 actions are semantically similar
    final threshold = actions.length >= 3 ? 2 : 2;
    if (similarCount >= threshold) {
      return LoopResult(
        isLoop: true,
        loopType: 'semantic',
        suggestion: "Similar actions detected (${similarCount}x): tapping same UI element with slightly different coordinates or parameters. The screen may not be responding. Try: scroll to reveal more elements, use vision mode for precise targeting, or navigate back.",
        failedActions: actions.where((a) => _areActionsSemanticallyimilar(first, a))
            .map((a) => '${a.action}(${a.parameters})').toList(),
      );
    }
    
    return LoopResult(isLoop: false);
  }

  /// Check if screen state is stalled (no progress)
  static LoopResult _checkProgressStall(List<ActionRecord> actions) {
    if (actions.length < 3) return LoopResult(isLoop: false);
    
    final firstHash = actions[0].screenHash;
    final allSameHash = actions.every((a) => a.screenHash == firstHash);
    
    if (allSameHash) {
      // Screen hasn't changed across multiple different actions
      final uniqueActions = actions.map((a) => a.action).toSet();
      if (uniqueActions.length >= 2) {
        return LoopResult(
          isLoop: true,
          loopType: 'stall',
          suggestion: "Screen state unchanged despite trying ${uniqueActions.length} different actions. The UI may be frozen or unresponsive. Suggested: perform_back, perform_home, or stop task.",
          failedActions: actions.map((a) => a.action).toList(),
        );
      }
    }
    
    return LoopResult(isLoop: false);
  }

  /// Check if two actions are semantically similar
  static bool _areActionsSemanticallyimilar(ActionRecord a, ActionRecord b) {
    // Must be the same action type
    if (a.action != b.action) return false;
    
    // CRITICAL FIX: If the screen state CHANGED (hashes differ), it is NOT a loop.
    // The user might be paginating, clicking 'Next' repeatedly, or adjusting a value.
    if (a.screenHash != b.screenHash) return false;

    // For tap actions, check if targeting same element
    if (a.action.contains('tap') || a.action == 'perform_tap') {
      return _isSameTarget(a.parameters, b.parameters);
    }
    
    // For other actions, consider them similar if screen state is same
    return a.screenHash == b.screenHash;
  }

  /// Check if two sets of parameters target the same UI element
  static bool _isSameTarget(Map<String, dynamic> paramsA, Map<String, dynamic> paramsB) {
    // Check if tapping same OCR text
    if (paramsA['text'] != null && paramsB['text'] != null) {
      final textA = paramsA['text'].toString().toLowerCase().trim();
      final textB = paramsB['text'].toString().toLowerCase().trim();
      if (textA == textB && textA.isNotEmpty) return true;
    }
    
    // Check if tapping same or adjacent index
    if (paramsA['index'] != null && paramsB['index'] != null) {
      final indexA = paramsA['index'] as int;
      final indexB = paramsB['index'] as int;
      if ((indexA - indexB).abs() <= 1) return true; // Same or adjacent
    }
    
    // Check if coordinates are very close (within threshold)
    final coordSimilarity = _calculateCoordinateSimilarity(paramsA, paramsB);
    if (coordSimilarity > 0.0 && coordSimilarity < COORDINATE_THRESHOLD) {
      return true;
    }
    
    return false;
  }

  /// Calculate distance between two coordinate sets
  static double _calculateCoordinateSimilarity(Map<String, dynamic> a, Map<String, dynamic> b) {
    final ax = a['x'] as num?;
    final ay = a['y'] as num?;
    final bx = b['x'] as num?;
    final by = b['y'] as num?;
    
    if (ax == null || ay == null || bx == null || by == null) return -1.0;
    
    // Euclidean distance
    final dx = (ax - bx).toDouble();
    final dy = (ay - by).toDouble();
    return (dx * dx + dy * dy).abs().toDouble();
  }

  static bool _areParamsEqual(Map<String, dynamic> a, Map<String, dynamic> b) {
    // Simple comparison for JSON-like maps
    return jsonEncode(a) == jsonEncode(b);
  }
}

class LoopResult {
  final bool isLoop;
  final String? suggestion;
  final String? loopType; // 'exact', 'semantic', 'stall'
  final List<String>? failedActions; // List of actions that were part of the loop

  LoopResult({
    required this.isLoop, 
    this.suggestion,
    this.loopType,
    this.failedActions,
  });
  
  /// Get a detailed description for logging
  String get debugDescription {
    if (!isLoop) return 'No loop detected';
    return 'Loop Type: ${loopType ?? 'unknown'}, Failed Actions: ${failedActions?.join(', ') ?? 'none'}';
  }
}
