import 'dart:convert';
import 'dart:typed_data';
import 'package:google_generative_ai/google_generative_ai.dart';
import 'secure_storage.dart';

class GeminiClient {
  // Using gemini-1.5-flash as it is more stable with current SDK version
  static const String _defaultModel = 'gemini-1.5-flash';

  // Singleton pattern
  static final GeminiClient _instance = GeminiClient._internal();
  factory GeminiClient() => _instance;
  GeminiClient._internal();

  // State
  GenerativeModel? _model;
  final SecureStorage _secureStorage = SecureStorage();
  bool _isInitialized = false;
  String _apiKey = '';

  /// Initialize the client with stored configuration
  Future<bool> initialize() async {
    try {
      await _secureStorage.initialize();
      return await _loadConfiguration();
    } catch (e) {
      print('❌ Gemini: Initialization failed: $e');
      return false;
    }
  }

  /// Load configuration from secure storage
  Future<bool> _loadConfiguration() async {
    try {
      final config = await _secureStorage.getApiConfiguration();

      if (config == null) {
        print('⚠️ Gemini: No configuration found');
        return false;
      }
      
      // Try to get API key from config or secure storage directly
      // Assuming we'll migrate the 'serviceAccountJson' field to hold the API key temporarily
      // or check a new field if available.
      // For now, let's look for a key.
      
      // Temporary: Check if serviceAccountJson actually looks like a key (starts with AIza)
      // or if it's a JSON.
      // Or better, let's assume we added getApiKey to SecureStorage.
      
      String? apiKey = await _secureStorage.getApiKey();
      
      if (apiKey == null || apiKey.isEmpty) {
        // Fallback: If user put key in serviceAccountJson field by mistake or convenience
        if (config.serviceAccountJson != null && !config.serviceAccountJson!.trim().startsWith('{')) {
           apiKey = config.serviceAccountJson;
        }
      }

      if (apiKey == null || apiKey.isEmpty) {
        print('⚠️ Gemini: No API Key found');
        return false;
      }

      _apiKey = apiKey;
      
      // Use configured model ID or fallback to default
      final modelId = config.modelId.isNotEmpty ? config.modelId : _defaultModel;
      
      _isInitialized = true;
      _setupModel(modelId);
      print('✅ Gemini: Client initialized with API Key and model: $modelId');
      return true;
    } catch (e) {
      print('❌ Gemini: Failed to load configuration: $e');
      return false;
    }
  }
  
  void _setupModel(String modelId) {
     if (_apiKey.isEmpty) return;
     
     print('🔧 Setting up Gemini model: $modelId');
     
     _model = GenerativeModel(
       model: modelId, 
       apiKey: _apiKey,
       generationConfig: GenerationConfig(
         temperature: 0.1,
         maxOutputTokens: 8192,
       ),
       safetySettings: [
         SafetySetting(HarmCategory.harassment, HarmBlockThreshold.medium),
         SafetySetting(HarmCategory.hateSpeech, HarmBlockThreshold.medium),
         SafetySetting(HarmCategory.sexuallyExplicit, HarmBlockThreshold.medium),
         SafetySetting(HarmCategory.dangerousContent, HarmBlockThreshold.medium),
       ]
     );
  }
  
  /// Update configuration dynamically
  void updateConfiguration(String key, String modelId) {
    _apiKey = key;
    _setupModel(modelId);
    _isInitialized = true;
  }

  /// Generate content with text prompt only
  Future<String?> generateContent(String prompt) async {
    return await _generateContent(prompt, null);
  }

  /// Generate content with text prompt and image
  Future<String?> generateContentWithImage(String prompt, String? base64Image) async {
    return await _generateContent(prompt, base64Image);
  }

  /// Internal method to generate content
  Future<String?> _generateContent(String prompt, String? base64Image) async {
    if (!_isInitialized || _model == null) {
      print('❌ Gemini: Client not initialized');
      return null;
    }

    try {

      final parts = <Part>[TextPart(prompt)];
      
      if (base64Image != null && base64Image.isNotEmpty) {
        try {
          // Decode base64 to bytes
          final imageBytes = base64Decode(base64Image);
          parts.add(DataPart('image/png', imageBytes));
        } catch (e) {
          print('⚠️ Gemini: Failed to decode image: $e');
        }
      }

      // Use Content.multi which automatically handles roles if needed, 
      // though typically for single-turn generateContent it's just content parts.
      // Explicitly setting 'user' role is cleaner for multi-turn but this is compatible.
      final content = [Content.multi(parts)];

      final response = await _model!.generateContent(content);
      return response.text;
    } catch (e) {
      print('❌ Gemini: Error generating content: $e');
      if (e.toString().contains('API_KEY_INVALID')) {
         print('❌ Gemini: Invalid API Key');
      }
      return null;
    }
  }

  /// Test the client connection
  Future<bool> testConnection() async {
    try {
      if (_model == null) return false;
      final response = await _model!.generateContent([Content.text('Hello, respond with "Connection successful"')]);
      return response.text?.toLowerCase().contains('successful') ?? false;
    } catch (e) {
      print('❌ Gemini: Connection test failed: $e');
      return false;
    }
  }
  
  bool get isInitialized => _isInitialized;
}
