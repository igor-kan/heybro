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
  static const int MAX_HISTORY_WINDOW = 5;

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
    };
  }
}

/// Helper to detect loops in the action history
class LoopDetection {
  static LoopResult check(List<ActionRecord> history) {
    if (history.length < 3) return LoopResult(isLoop: false);
    
    final last3 = history.sublist(history.length - 3);
    
    // Check if same action repeated 3 times with same screen state
    final first = last3[0];
    final isLoop = last3.every((r) => 
      r.action == first.action && 
      r.screenHash == first.screenHash &&
      _areParamsEqual(r.parameters, first.parameters)
    );

    if (isLoop) {
      return LoopResult(
        isLoop: true,
        suggestion: "Repeated action detected. The screen state is not changing. Try a different approach (e.g., Vision Fallback or different selector).",
      );
    }
    
    return LoopResult(isLoop: false);
  }

  static bool _areParamsEqual(Map<String, dynamic> a, Map<String, dynamic> b) {
    // Simple comparison for JSON-like maps
    return jsonEncode(a) == jsonEncode(b);
  }
}

class LoopResult {
  final bool isLoop;
  final String? suggestion;

  LoopResult({required this.isLoop, this.suggestion});
}
