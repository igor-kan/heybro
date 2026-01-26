import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'secure_storage.dart';
import 'gemini_client.dart';

class ApiSettingsScreen extends StatefulWidget {
  const ApiSettingsScreen({super.key});

  @override
  State<ApiSettingsScreen> createState() => _ApiSettingsScreenState();
}

class _ApiSettingsScreenState extends State<ApiSettingsScreen> {
  final _formKey = GlobalKey<FormState>();
  final _apiKeyController = TextEditingController();
  final _customModelController = TextEditingController();

  final SecureStorage _secureStorage = SecureStorage();
  final GeminiClient _geminiClient = GeminiClient();

  bool _isLoading = false;
  bool _isTesting = false;
  String _statusMessage = '';
  Color _statusColor = Colors.grey;
  
  String _selectedModel = 'gemini-2.5-flash';
  bool _isCustomModel = false;
  
  // Automation Settings
  String _automationMode = 'vision_a11y';
  bool _a11yOverlayEnabled = false;
  bool _hasOverlayPermission = false;
  

  
  final List<String> _commonModels = [
    'gemini-2.5-flash',
    'gemini-2.5-pro',
    'gemini-3-pro-preview',
    'gemini-3-flash-preview',
    'Custom'
  ];

  @override
  void initState() {
    super.initState();
    _checkOverlayPermission();
    _initializeStorage();
  }

  Future<void> _checkOverlayPermission() async {
    const channel = MethodChannel('com.vibeagent.dude/agent');
    try {
      final hasPermission = await channel.invokeMethod<bool>('checkOverlayPermission');
      setState(() {
        _hasOverlayPermission = hasPermission ?? false;
      });
    } catch (e) {
      debugPrint('Error checking overlay permission: $e');
    }
  }

  Future<void> _requestOverlayPermission() async {
    const channel = MethodChannel('com.vibeagent.dude/agent');
    try {
      await channel.invokeMethod('requestOverlayPermission');
      // Recheck when coming back? For now just manual recheck
    } catch (e) {
      _setStatus('Error requesting permission: $e', Colors.red);
    }
  }

  Future<void> _initializeStorage() async {
    try {
      await _secureStorage.initialize();
      await _loadExistingConfig();
    } catch (e) {
      _setStatus('Error initializing storage: $e', Colors.red);
    }
  }

  @override
  void dispose() {
    _apiKeyController.dispose();
    _customModelController.dispose();
    super.dispose();
  }

  Future<void> _loadExistingConfig() async {
    setState(() => _isLoading = true);
    try {
      final config = await _secureStorage.getApiConfiguration();
      if (config != null) {
        if (config.apiKey.isNotEmpty) {
           _apiKeyController.text = config.apiKey;
        }

        if (config.modelId.isNotEmpty) {
           if (_commonModels.contains(config.modelId)) {
             _selectedModel = config.modelId;
             _isCustomModel = false;
           } else {
             _selectedModel = 'Custom';
             _isCustomModel = true;
             _customModelController.text = config.modelId;
           }
        }
      }
      
      // Load automation settings
      _automationMode = await _secureStorage.getAutomationMode();
      _a11yOverlayEnabled = await _secureStorage.isA11yOverlayEnabled();
    } catch (e) {
      _setStatus('Error loading configuration: $e', Colors.red);
    } finally {
      setState(() => _isLoading = false);
    }
  }

  void _setStatus(String message, Color color) {
    setState(() {
      _statusMessage = message;
      _statusColor = color;
    });
  }

  String get _effectiveModelId {
    if (_isCustomModel) {
      return _customModelController.text.trim();
    }
    return _selectedModel;
  }

  Future<void> _saveConfiguration() async {
    if (!_formKey.currentState!.validate()) return;
    
    final modelId = _effectiveModelId;
    if (modelId.isEmpty) {
       _setStatus('Please specify a model ID', Colors.orange);
       return;
    }

    setState(() => _isLoading = true);
    _setStatus('Saving configuration...', Colors.blue);

    try {
      await _secureStorage.initialize();
      
      await _secureStorage.saveApiConfiguration(
        projectId: 'gemini-standard',
        region: 'us-central1',
        modelId: modelId, 
        apiKey: _apiKeyController.text.trim(),
        serviceAccountJson: null,
      );

      // Save automation settings
      await _secureStorage.saveAutomationMode(_automationMode);
      await _secureStorage.saveA11yOverlayEnabled(_a11yOverlayEnabled);
      
      // Update client immediately
      _geminiClient.updateConfiguration(_apiKeyController.text.trim(), modelId);
      
      _setStatus('Configuration saved!', const Color(0xFF4CAF50));
    } catch (e) {
      _setStatus('Error saving configuration: $e', Colors.red);
    } finally {
      setState(() => _isLoading = false);
    }
  }

  Future<void> _testConnection() async {
    if (!_formKey.currentState!.validate()) {
      _setStatus('Please enter an API Key', Colors.orange);
      return;
    }
    
    final modelId = _effectiveModelId;
    if (modelId.isEmpty) {
       _setStatus('Please specify a model ID', Colors.orange);
       return;
    }

    setState(() => _isTesting = true);
    _setStatus('Testing connection...', Colors.blue);

    try {
      // Set key and model on client to test
      _geminiClient.updateConfiguration(_apiKeyController.text.trim(), modelId);
      
      final success = await _geminiClient.testConnection();
      if (!success) {
        throw Exception('Connection test failed');
      }
      _setStatus('Test successful!', const Color(0xFF4CAF50));
    } catch (e) {
      _setStatus('Test failed: $e', Colors.red);
    } finally {
      setState(() => _isTesting = false);
    }
  }

  Future<void> _pasteFromClipboard() async {
    try {
      final clipboardData = await Clipboard.getData(Clipboard.kTextPlain);
      if (clipboardData?.text != null) {
        _apiKeyController.text = clipboardData!.text!;
        _setStatus('Pasted from clipboard', const Color(0xFF4CAF50));
      }
    } catch (e) {
      _setStatus('Failed to paste from clipboard', Colors.red);
    }
  }

  void _clearField() {
    _apiKeyController.clear();
    _setStatus('Cleared', Colors.grey);
  }

  Widget _buildPillButton({
    required String text,
    required VoidCallback? onPressed,
    required bool isPrimary,
    bool isLoading = false,
    IconData? icon,
  }) {
    final isTablet = MediaQuery.of(context).size.width > 600;
    
    return Material(
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(isTablet ? 30 : 25),
      child: InkWell(
        onTap: onPressed,
        borderRadius: BorderRadius.circular(isTablet ? 30 : 25),
        splashColor: isPrimary 
            ? Colors.white.withOpacity(0.2)
            : const Color(0xFF4CAF50).withOpacity(0.1),
        highlightColor: isPrimary 
            ? Colors.white.withOpacity(0.1)
            : const Color(0xFF4CAF50).withOpacity(0.05),
        child: Container(
          padding: EdgeInsets.symmetric(
            horizontal: isTablet ? 24 : 20,
            vertical: isTablet ? 16 : 14,
          ),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(isTablet ? 30 : 25),
            gradient: isPrimary
                ? const LinearGradient(
                    colors: [
                      Color(0xFF66BB6A),
                      Color(0xFF4CAF50),
                      Color(0xFF2E7D32),
                    ],
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    stops: [0.0, 0.5, 1.0],
                  )
                : const LinearGradient(
                    colors: [
                      Color(0xFFFFFFFF),
                      Color(0xFFF8F9FA),
                      Color(0xFFE5E7EB),
                    ],
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    stops: [0.0, 0.7, 1.0],
                  ),
            border: isPrimary 
                ? Border.all(
                    color: const Color(0xFF4CAF50).withOpacity(0.3),
                    width: 0.5,
                  )
                : Border.all(
                    color: const Color(0xFF4CAF50),
                    width: 1.5,
                  ),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(0.15),
                offset: const Offset(0, 4),
                blurRadius: 8,
                spreadRadius: 0,
              ),
            ],
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (isLoading)
                SizedBox(
                  width: isTablet ? 20 : 18,
                  height: isTablet ? 20 : 18,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    valueColor: AlwaysStoppedAnimation<Color>(
                      isPrimary ? Colors.white : const Color(0xFF4CAF50),
                    ),
                  ),
                )
              else if (icon != null)
                Icon(
                  icon,
                  color: isPrimary ? Colors.white : const Color(0xFF4CAF50),
                  size: isTablet ? 22 : 20,
                ),
              if ((isLoading || icon != null) && text.isNotEmpty)
                SizedBox(width: isTablet ? 12 : 10),
              if (text.isNotEmpty)
                Flexible(
                  child: Text(
                    text,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: isPrimary ? Colors.white : const Color(0xFF4CAF50),
                      fontWeight: FontWeight.w700,
                      fontSize: isTablet ? 15 : 14,
                      letterSpacing: 0.3,
                      shadows: isPrimary ? [
                        Shadow(
                          color: Colors.black.withOpacity(0.3),
                          offset: const Offset(0, 1),
                          blurRadius: 2,
                        ),
                      ] : null,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isTablet = MediaQuery.of(context).size.width > 600;
    
    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios, color: Color(0xFF2E7D32)),
          onPressed: () => Navigator.of(context).pop(),
        ),
        title: const Text(
          'Gemini API Settings',
          style: TextStyle(
            color: Color(0xFF2E7D32),
            fontWeight: FontWeight.w700,
            fontSize: 24,
          ),
        ),
        centerTitle: true,
      ),
      body: _isLoading
          ? const Center(
              child: CircularProgressIndicator(
                valueColor: AlwaysStoppedAnimation<Color>(Color(0xFF4CAF50)),
              ),
            )
          : SingleChildScrollView(
              padding: EdgeInsets.all(isTablet ? 32 : 24),
              child: Form(
                key: _formKey,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Header
                    Text(
                      'Google Gemini API',
                      style: TextStyle(
                        fontSize: isTablet ? 28 : 24,
                        fontWeight: FontWeight.w700,
                        color: const Color(0xFF1B5E20),
                      ),
                    ),
                    SizedBox(height: isTablet ? 8 : 6),
                    Text(
                      'Configure API key and model',
                      style: TextStyle(
                        fontSize: isTablet ? 16 : 14,
                        color: Colors.grey[600],
                        fontWeight: FontWeight.w400,
                      ),
                    ),
                    SizedBox(height: isTablet ? 40 : 32),

                    // API Key Field
                    Text(
                      'API Key',
                      style: TextStyle(
                        fontSize: isTablet ? 18 : 16,
                        fontWeight: FontWeight.w600,
                        color: const Color(0xFF2E7D32),
                      ),
                    ),
                    SizedBox(height: isTablet ? 12 : 8),
                    TextFormField(
                      controller: _apiKeyController,
                      decoration: InputDecoration(
                        hintText: 'Paste your Gemini API Key here',
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                          borderSide: const BorderSide(color: Color(0xFFE0E0E0)),
                        ),
                        focusedBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                          borderSide: const BorderSide(color: Color(0xFF4CAF50), width: 2),
                        ),
                        contentPadding: EdgeInsets.symmetric(
                          horizontal: isTablet ? 20 : 16,
                          vertical: isTablet ? 20 : 16,
                        ),
                      ),
                      maxLines: 2,
                      validator: (value) {
                         if (value == null || value.trim().isEmpty) {
                           return 'API Key is required';
                         }
                         return null;
                      },
                    ),
                    SizedBox(height: isTablet ? 16 : 12),
                    Row(
                      children: [
                        Expanded(
                          child: _buildPillButton(
                            text: 'Paste',
                            onPressed: _pasteFromClipboard,
                            isPrimary: false,
                            icon: Icons.paste,
                          ),
                        ),
                        SizedBox(width: isTablet ? 16 : 12),
                        Expanded(
                          child: _buildPillButton(
                            text: 'Clear',
                            onPressed: _clearField,
                            isPrimary: false,
                            icon: Icons.clear,
                          ),
                        ),
                      ],
                    ),

                    SizedBox(height: isTablet ? 32 : 24),
                    
                    // Model Selection
                    Text(
                      'Model',
                      style: TextStyle(
                        fontSize: isTablet ? 18 : 16,
                        fontWeight: FontWeight.w600,
                        color: const Color(0xFF2E7D32),
                      ),
                    ),
                    SizedBox(height: isTablet ? 12 : 8),
                    DropdownButtonFormField<String>(
                      // Ensure value is valid to prevent crashes
                      value: _commonModels.contains(_selectedModel) ? _selectedModel : _commonModels.first,
                      decoration: InputDecoration(
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                          borderSide: const BorderSide(color: Color(0xFFE0E0E0)),
                        ),
                        focusedBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                          borderSide: const BorderSide(color: Color(0xFF4CAF50), width: 2),
                        ),
                        contentPadding: EdgeInsets.symmetric(
                          horizontal: isTablet ? 20 : 16,
                          vertical: isTablet ? 20 : 16,
                        ),
                      ),
                      items: _commonModels.map((model) {
                        return DropdownMenuItem(
                          value: model,
                          child: Text(model),
                        );
                      }).toList(),
                      onChanged: (value) {
                         if (value != null) {
                           setState(() {
                             _selectedModel = value;
                             _isCustomModel = value == 'Custom';
                             if (!_isCustomModel) {
                               _customModelController.clear();
                             }
                           });
                         }
                      },
                    ),
                    
                    if (_isCustomModel) ...[
                      SizedBox(height: isTablet ? 16 : 12),
                      Text("Enter Custom Model ID:"),
                      SizedBox(height: 8),
                       TextFormField(
                        controller: _customModelController,
                        decoration: InputDecoration(
                          hintText: 'e.g. gemini-1.5-pro-002',
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                            borderSide: const BorderSide(color: Color(0xFFE0E0E0)),
                          ),
                          focusedBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                            borderSide: const BorderSide(color: Color(0xFF4CAF50), width: 2),
                          ),
                          contentPadding: EdgeInsets.symmetric(
                            horizontal: isTablet ? 20 : 16,
                            vertical: isTablet ? 20 : 16,
                          ),
                        ),
                      ),
                    ],
                    
                    SizedBox(height: isTablet ? 32 : 24),
                    
                    // Automation Settings Section
                    Text(
                      'Automation Settings',
                      style: TextStyle(
                        fontSize: isTablet ? 18 : 16,
                        fontWeight: FontWeight.w600,
                        color: const Color(0xFF2E7D32),
                      ),
                    ),
                    SizedBox(height: isTablet ? 12 : 8),
                    
                    // Automation Mode Dropdown
                    DropdownButtonFormField<String>(
                      value: _automationMode,
                      decoration: InputDecoration(
                        labelText: 'Automation Mode',
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                          borderSide: const BorderSide(color: Color(0xFFE0E0E0)),
                        ),
                        contentPadding: EdgeInsets.symmetric(
                          horizontal: isTablet ? 20 : 16,
                          vertical: isTablet ? 20 : 16,
                        ),
                      ),
                      items: const [
                        DropdownMenuItem(
                          value: 'vision_a11y',
                          child: Text('Vision + Accessibility (Recommended)'),
                        ),
                        DropdownMenuItem(
                          value: 'a11y_only',
                          child: Text('Accessibility Only (Faster, No Vision)'),
                        ),
                      ],
                      onChanged: (value) {
                         if (value != null) {
                           setState(() => _automationMode = value);
                         }
                      },
                    ),
                    SizedBox(height: isTablet ? 16 : 12),
                    
                    // A11y Overlay Toggle
                    Container(
                      decoration: BoxDecoration(
                        border: Border.all(color: const Color(0xFFE0E0E0)),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: SwitchListTile(
                        title: const Text('Show Accessibility Overlay'),
                        subtitle: Text(
                          _hasOverlayPermission 
                              ? 'Draw boxes over detected elements' 
                              : 'Requires "Display over other apps" permission',
                          style: TextStyle(
                            fontSize: 12, 
                            color: _hasOverlayPermission ? null : Colors.orange,
                          ),
                        ),
                        value: _a11yOverlayEnabled,
                        onChanged: (value) {
                          if (value && !_hasOverlayPermission) {
                            // Show dialog or just request permission
                            _requestOverlayPermission();
                          }
                          setState(() => _a11yOverlayEnabled = value);
                        },
                        activeColor: const Color(0xFF4CAF50),
                      ),
                    ),

                    SizedBox(height: isTablet ? 40 : 32),

                    // Status Message
                    if (_statusMessage.isNotEmpty) ...[
                      Text(
                        _statusMessage,
                        style: TextStyle(
                          color: _statusColor,
                          fontWeight: FontWeight.w500,
                          fontSize: isTablet ? 16 : 14,
                        ),
                        textAlign: TextAlign.center,
                      ),
                      SizedBox(height: isTablet ? 24 : 16),
                    ],

                    // Action Buttons
                    Row(
                      children: [
                        Expanded(
                          child: _buildPillButton(
                            text: 'Save',
                            onPressed: _isLoading ? null : _saveConfiguration,
                            isPrimary: true,
                            isLoading: _isLoading,
                            icon: Icons.save,
                          ),
                        ),
                        SizedBox(width: isTablet ? 16 : 12),
                        Expanded(
                          child: _buildPillButton(
                            text: 'Test',
                            onPressed: _isTesting ? null : _testConnection,
                            isPrimary: false,
                            isLoading: _isTesting,
                            icon: Icons.wifi_tethering,
                          ),
                        ),
                      ],
                    ),

                    SizedBox(height: isTablet ? 40 : 32),

                    // Setup Instructions
                    Text(
                      'How to get an API Key',
                      style: TextStyle(
                        fontSize: isTablet ? 20 : 18,
                        fontWeight: FontWeight.w700,
                        color: const Color(0xFF1B5E20),
                      ),
                    ),
                    SizedBox(height: isTablet ? 16 : 12),
                    Text(
                      '1. Go to Google AI Studio\n'
                      '2. Create a new API Key\n'
                      '3. Copy the key and paste it here',
                      style: TextStyle(
                        fontSize: isTablet ? 16 : 14,
                        color: Colors.grey[700],
                        height: 1.6,
                      ),
                    ),
                  ],
                ),
              ),
            ),
    );
  }
}
