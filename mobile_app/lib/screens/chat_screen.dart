import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:file_picker/file_picker.dart';
import 'package:image_picker/image_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:url_launcher/url_launcher.dart';
import '../services/ws_client.dart';
import '../services/api_client.dart';
import '../repositories/build_repository.dart';
import '../models/event.dart';
import '../widgets/app_sidebar.dart';
import '../widgets/overview_drawer.dart';

import '../providers/file_provider.dart';

class PendingAttachment {
  final String localPath;
  final String fileName;
  final Uint8List bytes;
  bool isUploading;
  String? uploadedRelativePath;
  String? uploadedAbsolutePath;
  String? error;

  PendingAttachment({
    required this.localPath,
    required this.fileName,
    required this.bytes,
    this.isUploading = false,
    this.uploadedRelativePath,
    this.uploadedAbsolutePath,
    this.error,
  });
}

class ProcessGroup {
  final List<TranscriptEvent> events;
  final bool isCompleted;
  ProcessGroup({required this.events, required this.isCompleted});
}

class ChatScreen extends ConsumerStatefulWidget {
  final String? initialConversationId;
  final String? initialWorkspace;

  const ChatScreen({super.key, this.initialConversationId, this.initialWorkspace});

  @override
  ConsumerState<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends ConsumerState<ChatScreen> {
  final TextEditingController _messageController = TextEditingController();
  final ScrollController _scrollController = ScrollController();

  String? _conversationId;
  String? _workspace;
  String? _mentionQuery;
  List<Map<String, dynamic>> _conversationArtifacts = [];
  bool _isLoading = false;
  String? _errorMsg;
  bool _isSending = false;
  bool _isInterrupting = false;
  final List<PendingAttachment> _pendingAttachments = [];
  bool _showScrollToBottom = false;
  
  bool _isLoadingHistory = false;
  bool _hasMoreHistory = true;

  List<Map<String, dynamic>> _workspaces = [];
  bool _isLoadingWorkspaces = false;

  final List<TranscriptEvent> _events = [];
  bool _displayItemsDirty = true;
  List<dynamic> _cachedDisplayItems = [];
  StreamSubscription<TranscriptEvent>? _eventSub;
  StreamSubscription<WsConnectionState>? _stateSub;

  // Track which stepIndex values we've already shown to avoid duplicates
  final Set<int> _seenStepIndices = {};

  // Model selection state
  String _selectedModel = 'gemini-3.8-flash-high';
  String? _pendingModelChangeFrom;
  String? _pendingModelChangeTo;

  String _getFriendlyModelName(String modelKey) {
    switch (modelKey) {
      case 'gemini-3.8-flash-high':
      case 'gemini_3.8_flash_high':
      case 'gemini_3.5_flash_high_fast':
        return 'Gemini 3.8 Flash (High)';
      case 'gemini-3.8-flash-medium':
      case 'gemini_3.8_flash_medium':
      case 'gemini_3.5_flash_medium':
        return 'Gemini 3.8 Flash (Medium)';
      case 'gemini-3.8-flash-low':
      case 'gemini_3.8_flash_low':
      case 'gemini_3.5_flash_low':
        return 'Gemini 3.8 Flash (Low)';
      case 'claude-sonnet-4-6':
      case 'claude_sonnet_4.6_thinking':
        return 'Claude Sonnet 4.6 (Thinking)';
      case 'claude-opus-4-6-thinking':
      case 'claude_opus_4.6_thinking':
        return 'Claude Opus 4.6 (Thinking)';
      case 'gpt-oss-120b-medium':
      case 'gpt_oss_120b_medium':
        return 'GPT-OSS 120B (Medium)';
      default:
        return 'Gemini 3.8 Flash (High)';
    }
  }

  String _getCliModel(String modelKey) {
    if (modelKey.contains('claude') || modelKey.contains('opus') || modelKey.contains('sonnet')) {
      return 'pro';
    }
    if (modelKey.contains('low') || modelKey.contains('lite')) {
      return 'flash_lite';
    }
    return 'flash';
  }

  @override
  void initState() {
    super.initState();
    _workspace = widget.initialWorkspace;
    if (widget.initialConversationId != null) {
      _conversationId = widget.initialConversationId;
      _loadConversation(widget.initialConversationId!);
    } else {
      _fetchWorkspaces();
    }

    _messageController.addListener(() {
      final text = _messageController.text;
      final selection = _messageController.selection;
      
      if (selection.isValid && selection.isCollapsed) {
        final pos = selection.baseOffset;
        int atIndex = -1;
        for (int i = pos - 1; i >= 0; i--) {
          if (text[i] == ' ') break;
          if (text[i] == '@') {
            atIndex = i;
            break;
          }
        }
        
        if (atIndex != -1) {
          final query = text.substring(atIndex + 1, pos);
          setState(() {
            _mentionQuery = query;
          });
        } else {
          if (_mentionQuery != null) {
            setState(() {
              _mentionQuery = null;
            });
          }
        }
      }
    });

    WidgetsBinding.instance.addPostFrameCallback((_) {
      _loadArtifacts();
    });
    _setupWsListeners();
    _scrollController.addListener(() {
      if (!_scrollController.hasClients) return;
      final show = _scrollController.position.pixels < _scrollController.position.maxScrollExtent - 100;
      if (show != _showScrollToBottom) {
        setState(() => _showScrollToBottom = show);
      }
      
      // Fetch more history when scrolled near the top
      if (_scrollController.position.pixels <= 100) {
        _fetchHistory();
      }
    });
  }



  void _loadConversation(String id) {
    final ws = ref.read(wsClientProvider);
    if (_conversationId != null) {
      ws.unsubscribe(_conversationId!);
    }
    setState(() {
      _conversationId = id;
      _events.clear();
      _displayItemsDirty = true;
      _seenStepIndices.clear();
      _errorMsg = null;
      _hasMoreHistory = true;
      _isLoadingHistory = false;
    });
    ws.subscribe(id);
    
    // Fetch conversation metadata to get workspace path
    ref.read(apiClientProvider).getConversationMetadata(id).then((meta) {
      if (!mounted || _conversationId != id) return;
      final workspace = meta['workspace'] as String?;
      if (workspace != null && workspace.isNotEmpty) {
        ref.read(activeWorkspaceProvider.notifier).setWorkspace(workspace);
      }
    }).catchError((_) {});
    
    // Preload overview data
    ref.read(overviewDataProvider(id).future);
    
    // Fetch initial history chunk
    _fetchHistory(initial: true);

    // Load artifacts for this conversation
    _loadArtifacts();
  }

  Future<void> _loadArtifacts() async {
    if (!mounted || _conversationId == null) return;
    try {
      final client = ref.read(apiClientProvider);
      final artifacts = await client.getArtifacts(_conversationId!);
      if (mounted) setState(() => _conversationArtifacts = artifacts);
    } catch (e) {
      debugPrint('Error loading artifacts: $e');
    }
  }

  Future<void> _fetchHistory({bool initial = false}) async {
    if (_isLoadingHistory || !_hasMoreHistory || _conversationId == null) return;
    setState(() {
      _isLoadingHistory = true;
    });
    
    try {
      final client = ref.read(apiClientProvider);
      final beforeIndex = initial || _events.isEmpty ? null : _events.first.stepIndex;
      
      final historyData = await client.getHistory(_conversationId!, limit: 20, beforeIndex: beforeIndex);
      final newEvents = historyData.map((e) => TranscriptEvent.fromJson(e as Map<String, dynamic>)).toList();
      
      if (!mounted) return;
      
      setState(() {
        if (newEvents.length < 20) {
          _hasMoreHistory = false;
        }
        for (final e in newEvents) {
          if (!_seenStepIndices.contains(e.stepIndex)) {
            _seenStepIndices.add(e.stepIndex);
            _events.add(e);
          }
        }
        _events.sort((a, b) => a.stepIndex.compareTo(b.stepIndex));
        _displayItemsDirty = true;
        _isLoadingHistory = false;
      });
      
      if (initial) {
        WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToBottom());
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isLoadingHistory = false;
        });
      }
    }
  }

  void _startNewConversation() {
    final ws = ref.read(wsClientProvider);
    if (_conversationId != null) {
      ws.unsubscribe(_conversationId!);
    }
    setState(() {
      _conversationId = null;
      _events.clear();
      _displayItemsDirty = true;
      _seenStepIndices.clear();
      _errorMsg = null;
    });
    _fetchWorkspaces();
  }

  Future<void> _fetchWorkspaces() async {
    setState(() => _isLoadingWorkspaces = true);
    try {
      final client = ref.read(apiClientProvider);
      final list = await client.getWorkspaces();
      if (mounted) {
        setState(() {
          _workspaces = list;
          // Set default workspace to General if it exists and nothing is selected
          if (_workspace == null || !_workspaces.any((w) => w['workspace'] == _workspace)) {
            final general = _workspaces.where((w) => w['name'] == 'General').firstOrNull;
            _workspace = general?['workspace'] as String? ?? (_workspaces.isNotEmpty ? _workspaces.first['workspace'] as String? : null);
          }
        });
      }
    } finally {
      if (mounted) setState(() => _isLoadingWorkspaces = false);
    }
  }

  void _setupWsListeners() {
    final ws = ref.read(wsClientProvider);

    // Listen for real-time transcript events
    _eventSub = ws.transcriptStream.listen((event) {
      if (!mounted) return;
      if (event.conversationId != _conversationId) return;
      
      setState(() {
        if (_seenStepIndices.contains(event.stepIndex)) {
          final index = _events.indexWhere((e) => e.stepIndex == event.stepIndex);
          if (index != -1) {
            _events[index] = event;
          }
        } else {
          _seenStepIndices.add(event.stepIndex);
          int low = 0;
          int high = _events.length - 1;
          while (low <= high) {
            int mid = low + ((high - low) >> 1);
            if (_events[mid].stepIndex < event.stepIndex) {
              low = mid + 1;
            } else {
              high = mid - 1;
            }
          }
          _events.insert(low, event);
        }
        _displayItemsDirty = true;
      });
      WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToBottom());

      // Invalidate overview cache on stream completion of a step
      if (event.status == 'DONE') {
        ref.invalidate(overviewDataProvider(_conversationId!));
      }
    });

    // If WS is disconnected, trigger connection
    if (ws.connectionState == WsConnectionState.disconnected) {
      ws.connect();
    }
  }

  void _scrollToBottom() {
    if (_scrollController.hasClients) {
      _scrollController.animateTo(
        _scrollController.position.maxScrollExtent,
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeOut,
      );
    }
  }

  bool get _isAgentActive {
    if (_isSending || _isInterrupting) return true;
    if (_conversationId == null) return false;
    if (_events.isEmpty) return false;

    for (int i = _events.length - 1; i >= 0; i--) {
      final ev = _events[i];
      if (ev.category == 'user_message') {
        return true;
      }
      if (ev.category == 'tool_invocation') {
        return true;
      }
      if (ev.category == 'agent_response') {
        return ev.status.toLowerCase() != 'done';
      }
    }
    return false;
  }

  Future<void> _stopAgent() async {
    if (_conversationId == null || _isInterrupting) return;
    setState(() => _isInterrupting = true);
    try {
      final client = ref.read(apiClientProvider);
      await client.cancelConversation(_conversationId!);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Agent turn interrupted successfully'),
            backgroundColor: Colors.orange,
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to stop agent: $e'),
            backgroundColor: Colors.red,
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _isInterrupting = false);
      }
    }
  }

  void _showAttachmentSheet() {
    showModalBottomSheet(
      context: context,
      backgroundColor: Theme.of(context).colorScheme.surfaceContainerHigh,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 16.0, horizontal: 8.0),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 40,
                  height: 4,
                  margin: const EdgeInsets.only(bottom: 16),
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.outlineVariant,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                ListTile(
                  leading: const CircleAvatar(
                    backgroundColor: Color(0xFF2E7D32),
                    child: Icon(Icons.camera_alt, color: Colors.white, size: 20),
                  ),
                  title: const Text('Take Photo', style: TextStyle(fontWeight: FontWeight.w600)),
                  subtitle: const Text('Capture photo with camera'),
                  onTap: () {
                    Navigator.pop(ctx);
                    _pickImage(ImageSource.camera);
                  },
                ),
                ListTile(
                  leading: const CircleAvatar(
                    backgroundColor: Color(0xFF1976D2),
                    child: Icon(Icons.photo_library, color: Colors.white, size: 20),
                  ),
                  title: const Text('Photo Gallery', style: TextStyle(fontWeight: FontWeight.w600)),
                  subtitle: const Text('Choose image from photos'),
                  onTap: () {
                    Navigator.pop(ctx);
                    _pickImage(ImageSource.gallery);
                  },
                ),
                ListTile(
                  leading: const CircleAvatar(
                    backgroundColor: Color(0xFF7B1FA2),
                    child: Icon(Icons.attach_file, color: Colors.white, size: 20),
                  ),
                  title: const Text('Upload Document', style: TextStyle(fontWeight: FontWeight.w600)),
                  subtitle: const Text('Pick any file or document'),
                  onTap: () {
                    Navigator.pop(ctx);
                    _pickFileDocument();
                  },
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Future<void> _pickImage(ImageSource source) async {
    try {
      final picker = ImagePicker();
      final picked = await picker.pickImage(
        source: source,
        maxWidth: 1920,
        maxHeight: 1080,
        imageQuality: 85,
      );
      if (picked == null) return;

      final bytes = await picked.readAsBytes();
      final rawName = picked.name.isNotEmpty ? picked.name : 'IMG_${DateTime.now().millisecondsSinceEpoch}.jpg';
      final safeName = rawName.replaceAll(RegExp(r'\s+'), '_');

      final att = PendingAttachment(
        localPath: picked.path,
        fileName: safeName,
        bytes: bytes,
        isUploading: true,
      );

      setState(() {
        _pendingAttachments.add(att);
      });

      _uploadAttachment(att);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to pick photo: $e')),
        );
      }
    }
  }

  Future<void> _uploadAttachment(PendingAttachment att) async {
    try {
      final uploadPath = '.system_generated/artifacts/scratch/${att.fileName}';
      final base64Content = base64Encode(att.bytes);
      final apiClient = ref.read(apiClientProvider);

      final res = await apiClient.createFileOrFolder(
        path: uploadPath,
        type: 'file',
        content: base64Content,
        base64Encoded: true,
        workspace: _workspace,
      );

      if (mounted) {
        setState(() {
          att.isUploading = false;
          att.uploadedRelativePath = uploadPath;
          att.uploadedAbsolutePath = res['absolutePath'] as String?;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          att.isUploading = false;
          att.error = e.toString();
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to upload ${att.fileName}: $e')),
        );
      }
    }
  }

  Future<void> _pickFileDocument() async {
    try {
      FilePickerResult? result = await FilePicker.platform.pickFiles(
        withData: true,
      );
      if (result != null && result.files.isNotEmpty) {
        final file = result.files.first;
        if (file.bytes != null) {
          final isImage = ['.png', '.jpg', '.jpeg', '.gif', '.webp'].any(
            (ext) => file.name.toLowerCase().endsWith(ext),
          );

          if (isImage) {
            final rawName = file.name;
            final safeName = rawName.replaceAll(RegExp(r'\s+'), '_');
            final att = PendingAttachment(
              localPath: file.path ?? '',
              fileName: safeName,
              bytes: file.bytes!,
              isUploading: true,
            );
            setState(() {
              _pendingAttachments.add(att);
            });
            _uploadAttachment(att);
          } else {
            final base64Content = base64Encode(file.bytes!);
            final fileName = file.name.replaceAll(RegExp(r'\s+'), '_');
            final uploadPath = '.system_generated/artifacts/scratch/$fileName';
            final apiClient = ref.read(apiClientProvider);
            final res = await apiClient.createFileOrFolder(
              path: uploadPath,
              type: 'file',
              content: base64Content,
              base64Encoded: true,
              workspace: _workspace,
            );
            final absPath = res['absolutePath'] as String?;
            final link = absPath != null
                ? '[$fileName](file:///$absPath) '
                : '[$fileName]($uploadPath) ';

            final text = _messageController.text;
            final selection = _messageController.selection;
            if (selection.isValid && selection.start >= 0) {
              _messageController.value = TextEditingValue(
                text: text.replaceRange(selection.start, selection.end, link),
                selection: TextSelection.collapsed(offset: selection.start + link.length),
              );
            } else {
              _messageController.text = text + link;
            }
          }
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to pick document: $e')),
        );
      }
    }
  }

  Future<void> _sendMessage() async {
    final text = _messageController.text.trim();
    if (text.isEmpty && _pendingAttachments.isEmpty) return;
    if (_isSending) return;

    if (_pendingAttachments.any((a) => a.isUploading)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Uploading photo... please wait a moment.')),
      );
      return;
    }

    String fullContent = text;
    if (_pendingAttachments.isNotEmpty) {
      final attachmentText = _pendingAttachments.map((att) {
        final path = att.uploadedAbsolutePath != null ? 'file:///${att.uploadedAbsolutePath}' : (att.uploadedRelativePath ?? att.fileName);
        return '![Image: ${att.fileName}]($path)';
      }).join('\n');

      fullContent = fullContent.isEmpty ? attachmentText : '$attachmentText\n\n$fullContent';
    }

    _messageController.clear();
    setState(() {
      _pendingAttachments.clear();
      _isSending = true;
    });

    try {
      final client = ref.read(apiClientProvider);
      
      // Construct model change payload if there is a pending selection
      Map<String, String>? modelChangeMap;
      if (_pendingModelChangeFrom != null && _pendingModelChangeTo != null) {
        modelChangeMap = {
          'from': _pendingModelChangeFrom!,
          'to': _pendingModelChangeTo!,
        };
      }
      
      if (_conversationId == null) {
        // Send initial model change from "None" if first model selection is configured
        final firstModelChange = _selectedModel != 'gemini-3.8-flash-high' 
            ? {'from': 'None', 'to': _getFriendlyModelName(_selectedModel)} 
            : null;

        // Create conversation using the user's actual prompt and mapped CLI model
        final id = await client.createConversation(
          fullContent, 
          model: _getCliModel(_selectedModel),
          selectedModel: _selectedModel,
          modelChange: modelChangeMap ?? firstModelChange,
          workspace: _workspace,
        );
        if (!mounted) return;
        
        setState(() {
          _conversationId = id;
        });
        
        // Subscribe to WS stream
        ref.read(wsClientProvider).subscribe(id);
      } else {
        await client.sendMessage(
          _conversationId!, 
          fullContent,
          model: _selectedModel,
          modelChange: modelChangeMap,
        );
      }
      
      // Clear pending model change after successful transmission
      _pendingModelChangeFrom = null;
      _pendingModelChangeTo = null;
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to send: $e'),
            backgroundColor: Theme.of(context).colorScheme.error,
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _isSending = false);
    }
  }

  @override
  void dispose() {
    _eventSub?.cancel();
    _stateSub?.cancel();
    _messageController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Theme.of(context).colorScheme.surface,
      drawer: AppSidebar(
        onConversationSelected: _loadConversation,
        onNewConversation: _startNewConversation,
      ),
      endDrawer: _conversationId != null 
          ? OverviewDrawer(
              conversationId: _conversationId!,
              onConversationSelected: _loadConversation,
            ) 
          : null,
      body: Stack(
        children: [
          // Main Body
          Positioned.fill(
            child: _buildBody(),
          ),

          // Top Header Background Cover (prevents chat content from drawing under system status bar / camera cutout)
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            height: MediaQuery.paddingOf(context).top,
            child: Container(
              color: Theme.of(context).colorScheme.surface,
            ),
          ),
          
          // Floating Menu Button
          Positioned(
            top: MediaQuery.paddingOf(context).top + 16,
            left: 16,
            child: Builder(
              builder: (ctx) => GestureDetector(
                onTap: () => Scaffold.of(ctx).openDrawer(),
                child: Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.surfaceContainerHigh,
                    shape: BoxShape.circle,
                    border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
                    boxShadow: [
                      BoxShadow(
                        color: Theme.of(context).colorScheme.shadow.withValues(alpha: 0.4),
                        blurRadius: 12,
                        offset: const Offset(0, 4),
                      ),
                    ],
                  ),
                  alignment: Alignment.center,
                  child: Icon(
                    Icons.menu,
                    color: Theme.of(context).colorScheme.onSurface,
                    size: 20,
                  ),
                ),
              ),
            ),
          ),

          // Floating Stop Agent Button (when agent is actively working)
          if (_conversationId != null && _isAgentActive)
            Positioned(
              top: MediaQuery.paddingOf(context).top + 16,
              right: 68,
              child: GestureDetector(
                onTap: _isInterrupting ? null : _stopAgent,
                child: Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    color: const Color(0xFFC62828),
                    shape: BoxShape.circle,
                    border: Border.all(color: const Color(0xFFFF5252), width: 1.5),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.red.withValues(alpha: 0.5),
                        blurRadius: 12,
                        offset: const Offset(0, 4),
                      ),
                    ],
                  ),
                  alignment: Alignment.center,
                  child: _isInterrupting
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white,
                          ),
                        )
                      : const Icon(
                          Icons.stop_rounded,
                          color: Colors.white,
                          size: 24,
                        ),
                ),
              ),
            ),

          // Floating Connection Indicator
          Positioned(
            top: MediaQuery.paddingOf(context).top + 24,
            right: (_conversationId != null && _isAgentActive) ? 122 : 76,
            child: _buildConnectionDot(),
          ),

          // Floating Overview Button
          if (_conversationId != null)
            Positioned(
              top: MediaQuery.paddingOf(context).top + 16,
              right: 16,
              child: Builder(
                builder: (ctx) => GestureDetector(
                  onTap: () => Scaffold.of(ctx).openEndDrawer(),
                  child: Container(
                    width: 44,
                    height: 44,
                    decoration: BoxDecoration(
                      color: Theme.of(context).colorScheme.surfaceContainerHigh,
                      shape: BoxShape.circle,
                      border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
                      boxShadow: [
                        BoxShadow(
                          color: Theme.of(context).colorScheme.shadow.withValues(alpha: 0.4),
                          blurRadius: 12,
                          offset: const Offset(0, 4),
                        ),
                      ],
                    ),
                    alignment: Alignment.center,
                    child: Icon(
                      Icons.info_outline,
                      color: Theme.of(context).colorScheme.onSurface,
                      size: 20,
                    ),
                  ),
                ),
              ),
            ),

          // Input Area (Fixed Bottom)
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: _buildInputArea(),
          ),
        ],
      ),
    );
  }

  Widget _buildConnectionDot() {
    return Consumer(
      builder: (context, ref, _) {
        final ws = ref.watch(wsClientProvider);
        final isConnected = ws.connectionState == WsConnectionState.connected;
        return Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: isConnected ? Theme.of(context).colorScheme.primary : Theme.of(context).colorScheme.error,
            boxShadow: [
              BoxShadow(
                color: (isConnected ? Theme.of(context).colorScheme.primary : Theme.of(context).colorScheme.error)
                    .withValues(alpha: 0.4),
                blurRadius: 8,
              ),
            ],
          ),
        );
      },
    );
  }

  List<dynamic> _buildDisplayItems() {
    if (!_displayItemsDirty) return _cachedDisplayItems;

    final List<dynamic> items = [];
    final List<TranscriptEvent> currentGroup = [];

    for (int i = 0; i < _events.length; i++) {
      final event = _events[i];
      final cat = event.category.toLowerCase();
      final source = event.source.toUpperCase();

      if ((cat == 'user_message' && (source == 'USER' || source == 'USER_EXPLICIT')) || cat == 'agent_response') {
        if (currentGroup.isNotEmpty) {
          items.add(ProcessGroup(
            events: currentGroup.toList(),
            isCompleted: true,
          ));
          currentGroup.clear();
        }
        items.add(event);
      } else {
        currentGroup.add(event);
      }
    }

    if (currentGroup.isNotEmpty) {
      items.add(ProcessGroup(
        events: currentGroup.toList(),
        isCompleted: false,
      ));
    }

    _cachedDisplayItems = items;
    _displayItemsDirty = false;
    return items;
  }

  Widget _buildBody() {
    if (_isLoading) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircularProgressIndicator(color: Theme.of(context).colorScheme.primary),
            SizedBox(height: 16),
            Text(
              'Connecting to Relay-X...',
              style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant),
            ),
          ],
        ),
      );
    }

    if (_errorMsg != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.error_outline, color: Theme.of(context).colorScheme.error, size: 48),
              const SizedBox(height: 16),
              Text(
                _errorMsg!,
                textAlign: TextAlign.center,
                style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant),
              ),
              const SizedBox(height: 24),
              ElevatedButton(
                onPressed: () {
                  setState(() {
                    _errorMsg = null;
                    _isLoading = true;
                    _conversationId = null;
                  });
                  _setupWsListeners();
                },
                child: const Text('Retry'),
              ),
            ],
          ),
        ),
      );
    }

    final displayItems = _buildDisplayItems();

    return displayItems.isEmpty && !_isLoadingHistory
        ? _buildEmptyState()
        : ListView.separated(
            controller: _scrollController,
            padding: EdgeInsets.only(
              left: 16.0,
              right: 16.0,
              top: MediaQuery.paddingOf(context).top + 76.0,
              bottom: MediaQuery.paddingOf(context).bottom + 220.0,
            ),
            itemCount: displayItems.length + (_hasMoreHistory ? 1 : 0),
            separatorBuilder: (_, _) => const SizedBox(height: 24),
            itemBuilder: (context, index) {
              if (_hasMoreHistory && index == 0) {
                return Padding(
                  padding: EdgeInsets.all(16.0),
                  child: Center(
                    child: CircularProgressIndicator(color: Theme.of(context).colorScheme.primary),
                  ),
                );
              }
              final eventIndex = _hasMoreHistory ? index - 1 : index;
              final item = displayItems[eventIndex];
              if (item is ProcessGroup) {
                return _buildProcessGroupWidget(item);
              } else if (item is TranscriptEvent) {
                return _buildEventItem(item);
              }
              return const SizedBox.shrink();
            },
          );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 64,
            height: 64,
            decoration: BoxDecoration(
              border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
              borderRadius: BorderRadius.circular(16),
            ),
            alignment: Alignment.center,
            child: Text(
              'AG',
              style: TextStyle(
                color: Theme.of(context).colorScheme.primary,
                fontWeight: FontWeight.bold,
                fontSize: 22,
              ),
            ),
          ),
          const SizedBox(height: 24),
          Text(
            'Session initialized.',
            style: TextStyle(
              color: Theme.of(context).colorScheme.onSurface,
              fontSize: 18,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Send a message to begin.',
            style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant),
          ),
        ],
      ),
    );
  }

  Widget _buildProcessGroupWidget(ProcessGroup group) {
    return ProcessGroupCard(
      group: group,
      eventBuilder: (event) => _buildEventItem(event),
    );
  }

  Widget _buildEventItem(TranscriptEvent event) {
    final cat = event.category.toLowerCase();
    if (cat == 'user_message') {
      final parsedTime = DateTime.tryParse(event.timestamp);
      return UserMessageBubble(text: event.content ?? event.summary, timestamp: parsedTime);
    } else if (cat == 'agent_response') {
      return AgentMessageBubble(text: event.content ?? event.summary, event: event);
    } else if (cat == 'tool_invocation') {
      final isDone = event.status.toLowerCase() == 'done';
      return _buildToolCallCard(event, isProcessing: !isDone);
    } else if (cat == 'tool_result') {
      return _buildToolCallCard(event, isProcessing: false);
    } else {
      return const SizedBox.shrink();
    }
  }



  Widget _buildToolCallCard(TranscriptEvent event, {required bool isProcessing}) {
    final toolName = event.toolCalls?.first.summary ?? event.summary;
    final content = event.content ?? '';

    return Container(
      margin: const EdgeInsets.symmetric(vertical: 8.0),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainer.withValues(alpha: 0.3),
        border: Border(
          left: BorderSide(color: Theme.of(context).colorScheme.primary, width: 2.0),
        ),
        borderRadius: const BorderRadius.only(
          topRight: Radius.circular(12.0),
          bottomRight: Radius.circular(12.0),
        ),
      ),
      padding: const EdgeInsets.all(16.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Expanded(
                child: Row(
                  children: [
                    Icon(
                      Icons.terminal,
                      color: Theme.of(context).colorScheme.primary,
                      size: 18,
                    ),
                    const SizedBox(width: 8),
                    Flexible(
                      child: Text(
                        toolName.toUpperCase(),
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          fontWeight: FontWeight.bold,
                          fontSize: 11,
                          letterSpacing: 1.2,
                          color: Theme.of(context).colorScheme.onSurface,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Text(
                isProcessing ? 'PROCESSING' : 'COMPLETED',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  fontWeight: FontWeight.bold,
                  fontSize: 10,
                  letterSpacing: 1.2,
                  color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.8),
                ),
              ),
            ],
          ),
          if (content.isNotEmpty) ...[
            const SizedBox(height: 12),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12.0),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surfaceContainerLow.withValues(alpha: 0.5),
                borderRadius: BorderRadius.circular(6.0),
                border: Border.all(color: Theme.of(context).colorScheme.outlineVariant.withValues(alpha: 0.3)),
              ),
              child: Text(
                content,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  fontSize: 12,
                  color: Theme.of(context).colorScheme.onSurfaceVariant.withValues(alpha: 0.8),
                  height: 1.4,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildInputArea() {
    final activeModelDisplay = _getFriendlyModelName(_selectedModel);

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        if (_mentionQuery != null)
          Padding(
            padding: const EdgeInsets.only(left: 16, right: 16, bottom: 8),
            child: _buildMentionAutocomplete(),
          ),
        if (_showScrollToBottom)
          Padding(
            padding: const EdgeInsets.only(right: 16.0, bottom: 8.0),
            child: Container(
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                boxShadow: [
                  BoxShadow(
                    color: Theme.of(context).colorScheme.shadow.withValues(alpha: 0.2),
                    blurRadius: 8,
                    offset: const Offset(0, 4),
                  ),
                ],
              ),
              child: IconButton(
                icon: Icon(Icons.arrow_downward, color: Theme.of(context).colorScheme.onSurface, size: 20),
                onPressed: _scrollToBottom,
                style: IconButton.styleFrom(
                  backgroundColor: Theme.of(context).colorScheme.surfaceContainerHigh,
                  shape: const CircleBorder(),
                  padding: const EdgeInsets.all(8),
                  minimumSize: const Size(36, 36),
                ),
              ),
            ),
          ),
        Container(
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surface,
            border: Border(
              top: BorderSide(color: Theme.of(context).colorScheme.outlineVariant),
            ),
          ),
          padding: EdgeInsets.only(
            left: 16.0,
            right: 16.0,
            top: 12.0,
            bottom: MediaQuery.paddingOf(context).bottom + 16.0,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (_conversationId == null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 12.0),
                  child: Row(
                    children: [
                      Text(
                        'Workspace: ',
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                          fontSize: 13,
                        ),
                      ),
                      const SizedBox(width: 8),
                      if (_isLoadingWorkspaces)
                        const SizedBox(
                          height: 16,
                          width: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      else if (_workspaces.isNotEmpty)
                        Expanded(
                          child: Container(
                            height: 32,
                            padding: const EdgeInsets.symmetric(horizontal: 12),
                            decoration: BoxDecoration(
                              color: Theme.of(context).colorScheme.surfaceContainerHigh,
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
                            ),
                            child: DropdownButtonHideUnderline(
                              child: DropdownButton<String>(
                                isExpanded: true,
                                value: _workspace,
                                hint: Text('Select Workspace', style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant, fontSize: 13)),
                                icon: Icon(Icons.arrow_drop_down, color: Theme.of(context).colorScheme.onSurfaceVariant, size: 20),
                                dropdownColor: Theme.of(context).colorScheme.surfaceContainerHigh,
                                style: TextStyle(color: Theme.of(context).colorScheme.onSurface, fontSize: 13),
                                items: _workspaces.map((w) {
                                  return DropdownMenuItem<String>(
                                    value: w['workspace'] as String,
                                    child: Text(
                                      w['name'] as String,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  );
                                }).toList(),
                                onChanged: (val) {
                                  setState(() {
                                    _workspace = val;
                                  });
                                },
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              // Attachment Preview Chips
              if (_pendingAttachments.isNotEmpty)
                _buildAttachmentPreviewBar(),

              // Text area container
          Container(
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.surfaceContainerHighest.withValues(alpha: 0.2),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Expanded(
                  child: TextField(
                    controller: _messageController,
                    minLines: 1,
                    maxLines: 5,
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: Theme.of(context).colorScheme.onSurface,
                    ),
                    decoration: const InputDecoration(
                      filled: false,
                      hintText: 'Ask anything, @ to mention, / for actions',
                      hintStyle: TextStyle(color: Color(0xFF666666)),
                      border: InputBorder.none,
                      enabledBorder: InputBorder.none,
                      focusedBorder: InputBorder.none,
                      contentPadding: EdgeInsets.all(16),
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.only(right: 12.0, bottom: 12.0),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 200),
                    height: 32,
                    width: 32,
                    decoration: BoxDecoration(
                      color: _isInterrupting
                          ? const Color(0xFFB71C1C)
                          : (_isAgentActive && _conversationId != null)
                              ? const Color(0xFFC62828)
                              : _isSending
                                  ? Theme.of(context).colorScheme.surfaceContainerHigh
                                  : Theme.of(context).colorScheme.primary,
                      borderRadius: BorderRadius.circular(8.0),
                    ),
                    child: IconButton(
                      padding: EdgeInsets.zero,
                      tooltip: (_isAgentActive && _conversationId != null) ? 'Stop Agent' : 'Send',
                      icon: _isInterrupting
                          ? const SizedBox(
                              width: 14,
                              height: 14,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Colors.white,
                              ),
                            )
                          : (_isAgentActive && _conversationId != null)
                              ? const Icon(Icons.stop_rounded, color: Colors.white, size: 20)
                              : _isSending
                                  ? const SizedBox(
                                      width: 14,
                                      height: 14,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                        color: Colors.white,
                                      ),
                                    )
                                  : const Icon(Icons.arrow_upward, color: Colors.black, size: 18),
                      onPressed: _isInterrupting
                          ? null
                          : (_isAgentActive && _conversationId != null)
                              ? _stopAgent
                              : _isSending
                                  ? null
                                  : _sendMessage,
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          // Tool buttons & Model Indicator
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Row(
                children: [
                  IconButton(
                    icon: const Icon(Icons.add, color: Color(0xFF999999), size: 22),
                    tooltip: 'Attach Photo / File',
                    onPressed: _showAttachmentSheet,
                    constraints: const BoxConstraints(),
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                  ),
                  IconButton(
                    icon: const Icon(Icons.mic, color: Color(0xFF999999), size: 22),
                    onPressed: () {},
                    constraints: const BoxConstraints(),
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                  ),
                  IconButton(
                    icon: const Icon(Icons.alternate_email, color: Color(0xFF999999), size: 22),
                    onPressed: () {
                      final text = _messageController.text;
                      final selection = _messageController.selection;
                      if (selection.isValid) {
                        _messageController.value = TextEditingValue(
                          text: text.replaceRange(selection.start, selection.end, '@'),
                          selection: TextSelection.collapsed(offset: selection.start + 1),
                        );
                      } else {
                        _messageController.text = '$text@';
                        _messageController.selection = TextSelection.collapsed(offset: _messageController.text.length);
                      }
                    },
                    constraints: const BoxConstraints(),
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                  ),
                ],
              ),
              GestureDetector(
                onTap: _showModelPicker,
                child: Row(
                  children: [
                    Text(
                      activeModelDisplay,
                      style: Theme.of(context).textTheme.labelSmall?.copyWith(
                        fontSize: 11,
                        color: Theme.of(context).colorScheme.onSurfaceVariant.withValues(alpha: 0.6),
                      ),
                    ),
                    const SizedBox(width: 4),
                    const Icon(
                      Icons.expand_less,
                      size: 14,
                      color: Color(0xFF666666),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
    ),
      ],
    );
  }

  Widget _buildAttachmentPreviewBar() {
    return Container(
      height: 68,
      margin: const EdgeInsets.only(bottom: 8),
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: _pendingAttachments.length,
        separatorBuilder: (_, _) => const SizedBox(width: 8),
        itemBuilder: (context, index) {
          final att = _pendingAttachments[index];
          return Stack(
            children: [
              Container(
                width: 64,
                height: 64,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(
                    color: att.error != null ? Colors.red : Theme.of(context).colorScheme.outlineVariant,
                    width: 1.5,
                  ),
                ),
                clipBehavior: Clip.antiAlias,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    Image.memory(
                      att.bytes,
                      fit: BoxFit.cover,
                      errorBuilder: (_, _, _) => Center(
                        child: Icon(Icons.description, color: Theme.of(context).colorScheme.onSurfaceVariant),
                      ),
                    ),
                    if (att.isUploading)
                      Container(
                        color: Colors.black54,
                        alignment: Alignment.center,
                        child: const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                        ),
                      ),
                  ],
                ),
              ),
              Positioned(
                top: 2,
                right: 2,
                child: GestureDetector(
                  onTap: () {
                    setState(() {
                      _pendingAttachments.removeAt(index);
                    });
                  },
                  child: Container(
                    padding: const EdgeInsets.all(3),
                    decoration: const BoxDecoration(
                      color: Colors.black87,
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(Icons.close, size: 12, color: Colors.white),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  void _showModelPicker() {
    showModalBottomSheet(
      context: context,
      backgroundColor: Theme.of(context).colorScheme.surfaceContainerLow,
      isScrollControlled: true,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
        side: BorderSide(color: Theme.of(context).colorScheme.outline),
      ),
      builder: (context) {
        return DraggableScrollableSheet(
          initialChildSize: 0.6,
          minChildSize: 0.3,
          maxChildSize: 0.8,
          expand: false,
          builder: (context, scrollController) {
            return Column(
              children: [
                const SizedBox(height: 8),
                Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.outline,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                const SizedBox(height: 16),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16.0),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      'SELECT MODEL',
                      style: Theme.of(context).textTheme.labelSmall?.copyWith(
                        fontWeight: FontWeight.bold,
                        letterSpacing: 1.5,
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                Expanded(
                  child: ListView(
                    controller: scrollController,
                    children: [
                      _buildModelTile('gemini-3.8-flash-high', 'Gemini 3.8 Flash (High)'),
                      _buildModelTile('gemini-3.8-flash-medium', 'Gemini 3.8 Flash (Medium)'),
                      _buildModelTile('gemini-3.8-flash-low', 'Gemini 3.8 Flash (Low)'),
                      _buildModelTile('claude-sonnet-4-6', 'Claude Sonnet 4.6 (Thinking)'),
                      _buildModelTile('claude-opus-4-6-thinking', 'Claude Opus 4.6 (Thinking)'),
                      _buildModelTile('gpt-oss-120b-medium', 'GPT-OSS 120B (Medium)'),
                    ],
                  ),
                ),
              ],
            );
          }
        );
      },
    );
  }

  Widget _buildModelTile(String modelKey, String displayName) {
    final isSelected = _selectedModel == modelKey;
    return ListTile(
      title: Text(
        displayName,
        style: GoogleFonts.jetBrainsMono(
          color: isSelected ? Theme.of(context).colorScheme.primary : Theme.of(context).colorScheme.onSurface,
          fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
        ),
      ),
      trailing: isSelected
          ? Icon(Icons.check, color: Theme.of(context).colorScheme.primary)
          : null,
      onTap: () {
        final oldModelKey = _selectedModel;
        if (oldModelKey != modelKey) {
          setState(() {
            _selectedModel = modelKey;
            _pendingModelChangeFrom = _getFriendlyModelName(oldModelKey);
            _pendingModelChangeTo = _getFriendlyModelName(modelKey);
          });
        }
        Navigator.pop(context);
      },
    );
  }

  Widget _buildMentionAutocomplete() {
    if (_mentionQuery == null) return const SizedBox.shrink();
    final query = _mentionQuery!.toLowerCase();
    final matches = _conversationArtifacts.where((a) => (a['filename'] as String).toLowerCase().contains(query)).take(50).toList();
    if (matches.isEmpty) return const SizedBox.shrink();

    return Container(
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
        boxShadow: [BoxShadow(color: Theme.of(context).colorScheme.shadow.withValues(alpha: 0.5), blurRadius: 16, offset: const Offset(0, 4))],
      ),
      constraints: const BoxConstraints(maxHeight: 250),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Row(
              children: [
                Icon(Icons.chat_bubble_outline, size: 14, color: Theme.of(context).colorScheme.onSurfaceVariant),
                SizedBox(width: 6),
                Text('Conversation', style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant, fontSize: 12, fontWeight: FontWeight.w500)),
              ],
            ),
          ),
          Divider(height: 1, color: Theme.of(context).colorScheme.outlineVariant),
          Flexible(
            child: ListView.separated(
              shrinkWrap: true,
              padding: EdgeInsets.zero,
              itemCount: matches.length,
              separatorBuilder: (context, index) => Divider(height: 1, color: Theme.of(context).colorScheme.outline.withValues(alpha: 0.1)),
              itemBuilder: (context, index) {
                final artifact = matches[index];
                final filename = artifact['filename'] as String;
                final isMedia = artifact['isMedia'] as bool;
                final absolutePath = artifact['absolutePath'] as String;
                
                String displayName = filename;
                if (filename.endsWith('.md')) {
                  displayName = filename.replaceAll('_', ' ').replaceAll('.md', '');
                  displayName = displayName.split(' ').map((w) => w.isEmpty ? '' : w[0].toUpperCase() + w.substring(1)).join(' ');
                } else if (isMedia) {
                  displayName = 'Media (Artifact)';
                }

                return ListTile(
                  dense: true,
                  leading: Icon(isMedia ? Icons.image_outlined : Icons.description_outlined, color: Theme.of(context).colorScheme.secondary, size: 18),
                  title: Text(displayName, style: TextStyle(color: Theme.of(context).colorScheme.onSurface, fontSize: 13)),
                  subtitle: Text(filename, style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant, fontSize: 11), maxLines: 1, overflow: TextOverflow.ellipsis),
                  onTap: () {
                    final link = isMedia ? '![$displayName](file:///$absolutePath) ' : '[$displayName](file:///$absolutePath) ';
                    final currentText = _messageController.text;
                    final currentSel = _messageController.selection;
                    if (currentSel.isValid) {
                      final newText = currentText.replaceRange(currentSel.start, currentSel.end, link);
                      _messageController.value = TextEditingValue(
                        text: newText,
                        selection: TextSelection.collapsed(offset: currentSel.start + link.length),
                      );
                    } else {
                      _messageController.text += link;
                    }
                    setState(() => _mentionQuery = null);
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class ProcessGroupCard extends StatefulWidget {
  final ProcessGroup group;
  final Widget Function(TranscriptEvent) eventBuilder;

  const ProcessGroupCard({
    super.key,
    required this.group,
    required this.eventBuilder,
  });

  @override
  State<ProcessGroupCard> createState() => _ProcessGroupCardState();
}

class _ProcessGroupCardState extends State<ProcessGroupCard> {
  late bool _isExpanded;

  @override
  void initState() {
    super.initState();
    _isExpanded = !widget.group.isCompleted;
  }

  @override
  void didUpdateWidget(ProcessGroupCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.group.isCompleted != widget.group.isCompleted) {
      if (widget.group.isCompleted) {
        _isExpanded = false;
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final group = widget.group;
    
    int toolCalls = group.events.where((e) => e.category.toLowerCase() == 'tool_invocation').length;
    bool hasThinking = group.events.any((e) => e.hasThinking);
    
    String titleText = "Processing...";
    if (group.isCompleted) {
      if (toolCalls > 0) {
        titleText = "Ran $toolCalls tool${toolCalls > 1 ? 's' : ''}";
        if (hasThinking) titleText += " and reasoned";
      } else if (hasThinking) {
        titleText = "Reasoned internally";
      } else {
        titleText = "System processes";
      }
    }

    return Card(
      elevation: 0,
      color: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: Theme.of(context).colorScheme.outlineVariant.withValues(alpha: 0.5)),
      ),
      margin: EdgeInsets.zero,
      child: Theme(
        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          initiallyExpanded: _isExpanded,
          onExpansionChanged: (expanded) {
            setState(() {
              _isExpanded = expanded;
            });
          },
          tilePadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 0),
          leading: Icon(
            group.isCompleted ? Icons.check_circle_outline : Icons.sync,
            color: group.isCompleted ? Theme.of(context).colorScheme.primary : Theme.of(context).colorScheme.secondary,
            size: 20,
          ),
          title: Text(
            titleText,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w500,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
          childrenPadding: const EdgeInsets.only(left: 16, right: 16, bottom: 16, top: 8),
          children: [
            for (int i = 0; i < group.events.length; i++) ...[
              if (i > 0) const SizedBox(height: 12),
              widget.eventBuilder(group.events[i]),
            ],
          ],
        ),
      ),
    );
  }
}

class UserMessageBubble extends StatelessWidget {
  final String text;
  final DateTime? timestamp;

  const UserMessageBubble({super.key, required this.text, this.timestamp});

  @override
  Widget build(BuildContext context) {
    final timeStr = timestamp != null
        ? "${timestamp!.hour.toString().padLeft(2, '0')}:${timestamp!.minute.toString().padLeft(2, '0')}"
        : "";

    return Align(
      alignment: Alignment.centerRight,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Container(
            constraints: BoxConstraints(maxWidth: MediaQuery.sizeOf(context).width * 0.85),
            padding: const EdgeInsets.symmetric(horizontal: 20.0, vertical: 14.0),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.surfaceContainerHigh,
              border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
              borderRadius: const BorderRadius.only(
                topLeft: Radius.circular(16.0),
                bottomLeft: Radius.circular(16.0),
                bottomRight: Radius.circular(16.0),
                topRight: Radius.zero,
              ),
              boxShadow: [
                BoxShadow(
                  color: Theme.of(context).colorScheme.shadow.withValues(alpha: 0.15),
                  blurRadius: 4,
                  offset: const Offset(0, 2),
                ),
              ],
            ),
            child: Text(
              text,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: Theme.of(context).colorScheme.onSurface,
                fontWeight: FontWeight.w500,
                height: 1.3,
              ),
            ),
          ),
          if (timeStr.isNotEmpty) ...[
            const SizedBox(height: 4),
            Padding(
              padding: const EdgeInsets.only(right: 4.0),
              child: Text(
                timeStr,
                style: Theme.of(context).textTheme.labelSmall?.copyWith(
                  fontSize: 10,
                  color: Theme.of(context).colorScheme.onSurfaceVariant.withValues(alpha: 0.5),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class AgentMessageBubble extends ConsumerWidget {
  final String text;
  final TranscriptEvent event;

  const AgentMessageBubble({super.key, required this.text, required this.event});

  void _handleLinkTap(BuildContext context, WidgetRef ref, String? href) async {
    if (href == null || href.isEmpty) return;
    final cleanHref = href.trim();
    final lower = cleanHref.toLowerCase();
    final isApk = lower.contains('.apk') || lower.contains('/api/builds');

    if (isApk) {
      String fileName = 'app-release.apk';
      try {
        final uri = Uri.parse(cleanHref);
        final segments = uri.pathSegments.where((s) => s.isNotEmpty).toList();
        if (segments.isNotEmpty) {
          fileName = Uri.decodeComponent(segments.last);
        }
      } catch (_) {
        final parts = cleanHref.split(RegExp(r'[/\\]'));
        if (parts.isNotEmpty) {
          fileName = parts.last.split('?').first;
        }
      }

      final confirmed = await showDialog<bool>(
        context: context,
        builder: (dialogContext) {
          final theme = Theme.of(dialogContext);
          return AlertDialog(
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            title: Row(
              children: [
                Icon(Icons.android, color: theme.colorScheme.primary),
                const SizedBox(width: 8),
                const Text('Install APK Build'),
              ],
            ),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Do you want to download and install this build directly on your device?',
                  style: theme.textTheme.bodyMedium,
                ),
                const SizedBox(height: 12),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: theme.colorScheme.outlineVariant),
                  ),
                  child: Row(
                    children: [
                      Icon(Icons.inventory_2_outlined, size: 20, color: theme.colorScheme.primary),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          fileName,
                          style: TextStyle(
                            fontFamily: 'monospace',
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                            color: theme.colorScheme.onSurface,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(dialogContext).pop(false),
                child: const Text('Cancel'),
              ),
              FilledButton.icon(
                onPressed: () => Navigator.of(dialogContext).pop(true),
                icon: const Icon(Icons.download, size: 18),
                label: const Text('Download & Install'),
              ),
            ],
          );
        },
      );

      if (confirmed == true && context.mounted) {
        showDialog(
          context: context,
          barrierDismissible: false,
          builder: (dialogContext) => _ApkDownloadDialog(
            rawPath: cleanHref,
            fileName: fileName,
            ref: ref,
          ),
        );
      }
      return;
    }

    if (cleanHref.startsWith('http://') || cleanHref.startsWith('https://')) {
      final uri = Uri.tryParse(cleanHref);
      if (uri != null) {
        await launchUrl(uri, mode: LaunchMode.externalApplication);
      }
      return;
    }

    if (cleanHref.startsWith('file://')) {
      final fileName = cleanHref.split(RegExp(r'[/\\]')).last.split('?').first;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('File link: $fileName'),
          duration: const Duration(seconds: 2),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        constraints: BoxConstraints(maxWidth: MediaQuery.sizeOf(context).width * 0.95),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            MarkdownBody(
              data: text.isEmpty ? '...' : text,
              onTapLink: (text, href, title) => _handleLinkTap(context, ref, href),
              styleSheet: MarkdownStyleSheet(
                p: Theme.of(context).textTheme.bodyLarge?.copyWith(
                  fontSize: 17,
                  color: Theme.of(context).colorScheme.onSurface,
                  height: 1.5,
                  fontWeight: FontWeight.normal,
                ),
                a: TextStyle(
                  color: Theme.of(context).colorScheme.primary,
                  decoration: TextDecoration.underline,
                  decorationColor: Theme.of(context).colorScheme.primary,
                  fontWeight: FontWeight.w600,
                ),
                code: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.secondary,
                  backgroundColor: Colors.transparent,
                ),
                codeblockDecoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.surfaceContainerLowest,
                  borderRadius: BorderRadius.circular(8.0),
                  border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
                ),
                codeblockPadding: const EdgeInsets.all(16.0),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ApkDownloadDialog extends StatefulWidget {
  final String rawPath;
  final String fileName;
  final WidgetRef ref;

  const _ApkDownloadDialog({
    required this.rawPath,
    required this.fileName,
    required this.ref,
  });

  @override
  State<_ApkDownloadDialog> createState() => _ApkDownloadDialogState();
}

class _ApkDownloadDialogState extends State<_ApkDownloadDialog> {
  double _progress = 0.0;
  String _status = 'Starting download...';
  String? _error;

  @override
  void initState() {
    super.initState();
    _start();
  }

  Future<void> _start() async {
    try {
      await widget.ref.read(buildRepositoryProvider).downloadAndInstallFromPath(
        widget.rawPath,
        widget.fileName,
        onProgress: (received, total) {
          if (total > 0 && mounted) {
            setState(() {
              _progress = received / total;
              final recMb = (received / 1024 / 1024).toStringAsFixed(1);
              final totMb = (total / 1024 / 1024).toStringAsFixed(1);
              _status = 'Downloading: $recMb / $totMb MB (${(_progress * 100).toInt()}%)';
            });
          }
        },
      );
      if (mounted) {
        Navigator.of(context).pop();
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = e.toString().replaceFirst('Exception: ', '');
          _status = 'Download failed';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      title: Row(
        children: [
          Icon(
            _error != null ? Icons.error_outline : Icons.cloud_download_outlined,
            color: _error != null ? theme.colorScheme.error : theme.colorScheme.primary,
          ),
          const SizedBox(width: 8),
          Text(_error != null ? 'Download Failed' : 'Downloading Build'),
        ],
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            widget.fileName,
            style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: 16),
          if (_error != null) ...[
            Text(_error!, style: TextStyle(color: theme.colorScheme.error, fontSize: 13)),
          ] else ...[
            LinearProgressIndicator(
              value: _progress > 0 ? _progress : null,
              backgroundColor: theme.colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(4),
            ),
            const SizedBox(height: 12),
            Text(
              _status,
              style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
          ],
        ],
      ),
      actions: [
        if (_error != null)
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Close'),
          ),
      ],
    );
  }
}
