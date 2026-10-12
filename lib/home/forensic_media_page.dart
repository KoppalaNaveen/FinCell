import 'dart:async';
import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:url_launcher/url_launcher.dart';

import '../services/storage_quota_service.dart';
import '../services/environment_scanner_service.dart';

class ForensicMediaPage extends StatefulWidget {
  final String? initialDeviceCode;

  const ForensicMediaPage({super.key, this.initialDeviceCode});

  @override
  State<ForensicMediaPage> createState() => _ForensicMediaPageState();
}

class _ForensicMediaPageState extends State<ForensicMediaPage>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;
  String? _selectedDeviceCode;

  // Audio Player State
  final AudioPlayer _audioPlayer = AudioPlayer();
  String? _activeAudioUrl;
  PlayerState _playerState = PlayerState.stopped;
  Duration _audioPosition = Duration.zero;
  Duration _audioDuration = const Duration(seconds: 30);

  StreamSubscription<PlayerState>? _stateSubscription;
  StreamSubscription<Duration>? _positionSubscription;
  StreamSubscription<Duration>? _durationSubscription;
  StreamSubscription<void>? _completeSubscription;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
    _selectedDeviceCode = widget.initialDeviceCode;

    _initAudioPlayer();
  }

  void _initAudioPlayer() {
    _stateSubscription = _audioPlayer.onPlayerStateChanged.listen((state) {
      if (mounted) setState(() => _playerState = state);
    });

    _positionSubscription = _audioPlayer.onPositionChanged.listen((pos) {
      if (mounted) setState(() => _audioPosition = pos);
    });

    _durationSubscription = _audioPlayer.onDurationChanged.listen((dur) {
      if (mounted && dur.inSeconds > 0) setState(() => _audioDuration = dur);
    });

    _completeSubscription = _audioPlayer.onPlayerComplete.listen((_) {
      if (mounted) {
        setState(() {
          _playerState = PlayerState.stopped;
          _audioPosition = Duration.zero;
          _activeAudioUrl = null;
        });
      }
    });
  }

  @override
  void dispose() {
    _tabController.dispose();
    _stateSubscription?.cancel();
    _positionSubscription?.cancel();
    _durationSubscription?.cancel();
    _completeSubscription?.cancel();
    _audioPlayer.stop();
    _audioPlayer.dispose();
    super.dispose();
  }

  Future<void> _toggleAudioPlay(String audioUrl) async {
    try {
      if (_activeAudioUrl == audioUrl &&
          _playerState == PlayerState.playing) {
        await _audioPlayer.pause();
      } else if (_activeAudioUrl == audioUrl &&
          _playerState == PlayerState.paused) {
        await _audioPlayer.resume();
      } else {
        await _audioPlayer.stop();
        setState(() {
          _activeAudioUrl = audioUrl;
          _audioPosition = Duration.zero;
        });
        await _audioPlayer.play(UrlSource(audioUrl));
      }
    } catch (e) {
      _showMsg("Unable to play audio: $e");
    }
  }

  void _showMsg(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), behavior: SnackBarBehavior.floating),
    );
  }

  String _formatTimestamp(dynamic timestamp) {
    if (timestamp == null) return "Unknown date";
    DateTime date;
    if (timestamp is Timestamp) {
      date = timestamp.toDate();
    } else if (timestamp is DateTime) {
      date = timestamp;
    } else {
      return "Unknown date";
    }
    const months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];
    final month = months[date.month - 1];
    final day = date.day.toString().padLeft(2, '0');
    final year = date.year;
    final hour = date.hour == 0 ? 12 : (date.hour > 12 ? date.hour - 12 : date.hour);
    final minute = date.minute.toString().padLeft(2, '0');
    final period = date.hour >= 12 ? "PM" : "AM";
    return "$month $day, $year • $hour:$minute $period";
  }

  String _formatDuration(Duration d) {
    final minutes = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final seconds = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return "$minutes:$seconds";
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final uid = FirebaseAuth.instance.currentUser?.uid;

    if (uid == null) {
      return Scaffold(
        appBar: AppBar(title: const Text("Forensic Media")),
        body: const Center(child: Text("Please login to view captured media")),
      );
    }

    return Scaffold(
      backgroundColor: isDark ? const Color(0xff121212) : const Color(0xffF4F6FA),
      appBar: AppBar(
        title: const Text(
          "Lost Device Media",
          style: TextStyle(fontWeight: FontWeight.bold, color: Colors.white),
        ),
        backgroundColor: const Color(0xff1A56DB),
        elevation: 0,
        centerTitle: true,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: Colors.white),
          onPressed: () => Navigator.pop(context),
        ),
        bottom: TabBar(
          controller: _tabController,
          indicatorColor: Colors.white,
          indicatorWeight: 3,
          labelColor: Colors.white,
          unselectedLabelColor: Colors.white70,
          labelStyle: const TextStyle(fontWeight: FontWeight.bold),
          tabs: const [
            Tab(icon: Icon(Icons.photo_library), text: "Images"),
            Tab(icon: Icon(Icons.audiotrack), text: "Audio (30s)"),
          ],
        ),
      ),
      body: StreamBuilder<DocumentSnapshot>(
        stream: FirebaseFirestore.instance.collection('users').doc(uid).snapshots(),
        builder: (context, userSnapshot) {
          final userData = userSnapshot.data?.data() as Map<String, dynamic>?;
          final userCode = userData?['uniqueCode']?.toString().toUpperCase();

          return StreamBuilder<QuerySnapshot>(
            stream: FirebaseFirestore.instance
                .collection('device_codes')
                .where('ownerUid', isEqualTo: uid)
                .snapshots(),
            builder: (context, devicesSnapshot) {
              final deviceCodes = <String>{};
              if (userCode != null && userCode.isNotEmpty) {
                deviceCodes.add(userCode);
              }
              if (devicesSnapshot.hasData) {
                for (var doc in devicesSnapshot.data!.docs) {
                  deviceCodes.add(doc.id.toUpperCase());
                }
              }

              return Column(
                children: [
                  _buildQuotaBanner(isDark, userData),
                  if (deviceCodes.isNotEmpty)
                    _buildDeviceFilterChips(isDark, deviceCodes.toList()),
                  Expanded(
                    child: TabBarView(
                      controller: _tabController,
                      children: [
                        _buildImagesTab(isDark, uid, deviceCodes.toList()),
                        _buildAudioTab(isDark, uid, deviceCodes.toList()),
                      ],
                    ),
                  ),
                ],
              );
            },
          );
        },
      ),
    );
  }

  Widget _buildQuotaBanner(bool isDark, Map<String, dynamic>? userData) {
    final quota = (userData?['storageQuotaBytes'] as num?)?.toInt() ??
        StorageQuotaService.quota15GbBytes;
    final used = (userData?['storageUsedBytes'] as num?)?.toInt() ?? 0;
    final remaining = StorageQuotaService.calculateRemainingBytes(quota, used);
    final percent = StorageQuotaService.calculateUsagePercentage(quota, used);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xff1E1E1E) : Colors.white,
        border: Border(
          bottom: BorderSide(color: Colors.grey.withValues(alpha: 0.15)),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Row(
                children: [
                  const Icon(Icons.cloud_done, color: Color(0xff1A56DB), size: 18),
                  const SizedBox(width: 6),
                  Text(
                    "Cloud Forensic Quota (15 GB)",
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 12,
                      color: isDark ? Colors.white : Colors.black87,
                    ),
                  ),
                ],
              ),
              Text(
                "${StorageQuotaService.formatBytes(used)} / ${StorageQuotaService.formatBytes(quota)}",
                style: const TextStyle(fontSize: 11, color: Colors.grey),
              ),
            ],
          ),
          const SizedBox(height: 6),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: percent,
              minHeight: 4,
              backgroundColor: isDark ? Colors.grey[800] : Colors.grey[200],
              valueColor: AlwaysStoppedAnimation<Color>(
                percent > 0.9 ? Colors.red : const Color(0xff1A56DB),
              ),
            ),
          ),
          const SizedBox(height: 4),
          Text(
            "${StorageQuotaService.formatBytes(remaining)} remaining for forensic captures",
            style: TextStyle(fontSize: 10, color: isDark ? Colors.white60 : Colors.black54),
          ),
        ],
      ),
    );
  }

  Widget _buildDeviceFilterChips(bool isDark, List<String> deviceCodes) {
    return Container(
      height: 48,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xff1A1A1A) : const Color(0xffFAFAFA),
        border: Border(
          bottom: BorderSide(color: Colors.grey.withValues(alpha: 0.1)),
        ),
      ),
      child: ListView(
        scrollDirection: Axis.horizontal,
        children: [
          Padding(
            padding: const EdgeInsets.only(right: 8, top: 6, bottom: 6),
            child: ChoiceChip(
              label: const Text("All Devices", style: TextStyle(fontSize: 12)),
              selected: _selectedDeviceCode == null,
              selectedColor: const Color(0xff1A56DB),
              labelStyle: TextStyle(
                color: _selectedDeviceCode == null ? Colors.white : (isDark ? Colors.white70 : Colors.black87),
              ),
              onSelected: (_) => setState(() => _selectedDeviceCode = null),
            ),
          ),
          ...deviceCodes.map((code) {
            final isSelected = _selectedDeviceCode == code;
            return Padding(
              padding: const EdgeInsets.only(right: 8, top: 6, bottom: 6),
              child: ChoiceChip(
                label: Text(code, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
                selected: isSelected,
                selectedColor: const Color(0xff1A56DB),
                labelStyle: TextStyle(
                  color: isSelected ? Colors.white : (isDark ? Colors.white70 : Colors.black87),
                ),
                onSelected: (_) => setState(() => _selectedDeviceCode = code),
              ),
            );
          }),
        ],
      ),
    );
  }

  // ================= IMAGES TAB =================

  Widget _buildImagesTab(bool isDark, String uid, List<String> userDeviceCodes) {
    final targetCodes = _selectedDeviceCode != null
        ? [_selectedDeviceCode!]
        : userDeviceCodes;

    if (targetCodes.isEmpty) {
      return _buildEmptyState(
        isDark,
        Icons.photo_library_outlined,
        "No Registered Devices",
        "Capture front-camera photos by tracing a device with its Unique Code.",
      );
    }

    if (targetCodes.length == 1) {
      final code = targetCodes.first;
      return StreamBuilder<QuerySnapshot>(
        stream: FirebaseFirestore.instance
            .collection('device_images')
            .doc(code)
            .collection('photos')
            .orderBy('timestamp', descending: true)
            .snapshots(),
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting && !snapshot.hasData) {
            return const Center(child: CircularProgressIndicator());
          }

          final docs = snapshot.data?.docs ?? [];
          if (docs.isEmpty) {
            return _buildEmptyState(
              isDark,
              Icons.no_photography_outlined,
              "No Captured Photos Yet",
              "When you request a front-camera snapshot for device $code, it will appear here.",
            );
          }

          return _buildImagesGrid(isDark, docs, code);
        },
      );
    }

    return StreamBuilder<QuerySnapshot>(
      stream: FirebaseFirestore.instance
          .collectionGroup('photos')
          .where('ownerUid', isEqualTo: uid)
          .orderBy('timestamp', descending: true)
          .snapshots(),
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return _buildMergedDeviceImages(isDark, userDeviceCodes);
        }

        if (snapshot.connectionState == ConnectionState.waiting && !snapshot.hasData) {
          return const Center(child: CircularProgressIndicator());
        }

        final docs = snapshot.data?.docs ?? [];
        if (docs.isEmpty) {
          return _buildMergedDeviceImages(isDark, userDeviceCodes);
        }

        return _buildImagesGrid(isDark, docs, null);
      },
    );
  }

  Widget _buildMergedDeviceImages(bool isDark, List<String> codes) {
    return FutureBuilder<List<Map<String, dynamic>>>(
      future: _fetchMergedMedia(codes, 'device_images', 'photos'),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting && !snapshot.hasData) {
          return const Center(child: CircularProgressIndicator());
        }

        final items = snapshot.data ?? [];
        if (items.isEmpty) {
          return _buildEmptyState(
            isDark,
            Icons.no_photography_outlined,
            "No Captured Photos Yet",
            "When front-camera photos are captured from your devices, they will appear here.",
          );
        }

        return GridView.builder(
          padding: const EdgeInsets.all(12),
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 2,
            crossAxisSpacing: 10,
            mainAxisSpacing: 10,
            childAspectRatio: 0.8,
          ),
          itemCount: items.length,
          itemBuilder: (context, index) {
            final item = items[index];
            return _buildImageCard(
              isDark,
              item['data'] as Map<String, dynamic>,
              item['docId'] as String,
              item['code'] as String,
            );
          },
        );
      },
    );
  }

  Widget _buildImagesGrid(bool isDark, List<DocumentSnapshot> docs, String? defaultCode) {
    return GridView.builder(
      padding: const EdgeInsets.all(12),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 2,
        crossAxisSpacing: 10,
        mainAxisSpacing: 10,
        childAspectRatio: 0.8,
      ),
      itemCount: docs.length,
      itemBuilder: (context, index) {
        final doc = docs[index];
        final data = doc.data() as Map<String, dynamic>;
        final code = data['deviceCode']?.toString().toUpperCase() ?? defaultCode ?? "";
        return _buildImageCard(isDark, data, doc.id, code);
      },
    );
  }

  Widget _buildImageCard(bool isDark, Map<String, dynamic> data, String docId, String code) {
    final imageUrl = data['imageUrl']?.toString() ?? '';
    final fileSize = (data['fileSize'] as num?)?.toInt() ??
        (data['fileSizeBytes'] as num?)?.toInt() ??
        0;
    final timestamp = data['timestamp'];
    final battery = data['battery'];

    return GestureDetector(
      onTap: () => _openImageDetail(imageUrl, data, docId, code),
      child: Container(
        decoration: BoxDecoration(
          color: isDark ? const Color(0xff1E1E1E) : Colors.white,
          borderRadius: BorderRadius.circular(16),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.05),
              blurRadius: 8,
              offset: const Offset(0, 3),
            ),
          ],
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Stack(
                fit: StackFit.expand,
                children: [
                  Image.network(
                    imageUrl,
                    fit: BoxFit.cover,
                    loadingBuilder: (context, child, progress) {
                      if (progress == null) return child;
                      return const Center(
                        child: CircularProgressIndicator(strokeWidth: 2),
                      );
                    },
                    errorBuilder: (context, error, stackTrace) => Container(
                      color: isDark ? Colors.grey[900] : Colors.grey[200],
                      child: const Icon(Icons.broken_image, color: Colors.grey),
                    ),
                  ),
                  if (code.isNotEmpty)
                    Positioned(
                      top: 8,
                      left: 8,
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: 0.65),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Text(
                          code,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 10,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    ),
                  if (fileSize > 0)
                    Positioned(
                      bottom: 8,
                      right: 8,
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(
                          color: const Color(0xff1A56DB).withValues(alpha: 0.85),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Text(
                          StorageQuotaService.formatBytes(fileSize),
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 9,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    _formatTimestamp(timestamp),
                    style: TextStyle(
                      fontSize: 10,
                      fontWeight: FontWeight.w500,
                      color: isDark ? Colors.white70 : Colors.black87,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  if (battery != null) ...[
                    const SizedBox(height: 2),
                    Row(
                      children: [
                        const Icon(Icons.battery_std, size: 12, color: Colors.green),
                        const SizedBox(width: 2),
                        Text(
                          "$battery%",
                          style: const TextStyle(fontSize: 10, color: Colors.grey),
                        ),
                      ],
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _openImageDetail(String imageUrl, Map<String, dynamic> data, String docId, String code) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final fileSize = (data['fileSize'] as num?)?.toInt() ??
        (data['fileSizeBytes'] as num?)?.toInt() ??
        0;
    final timestamp = data['timestamp'];

    showDialog(
      context: context,
      builder: (ctx) {
        return Dialog(
          backgroundColor: isDark ? const Color(0xff1E1E1E) : Colors.white,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ClipRRect(
                borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
                child: SizedBox(
                  height: 280,
                  width: double.infinity,
                  child: InteractiveViewer(
                    child: Image.network(
                      imageUrl,
                      fit: BoxFit.contain,
                      errorBuilder: (context, error, stackTrace) => const Center(
                        child: Icon(Icons.broken_image, size: 50, color: Colors.grey),
                      ),
                    ),
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          code.isNotEmpty ? "Device: $code" : "Captured Photo",
                          style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
                        ),
                        if (fileSize > 0)
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                            decoration: BoxDecoration(
                              color: const Color(0xff1A56DB).withValues(alpha: 0.15),
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: Text(
                              StorageQuotaService.formatBytes(fileSize),
                              style: const TextStyle(
                                color: Color(0xff1A56DB),
                                fontWeight: FontWeight.bold,
                                fontSize: 11,
                              ),
                            ),
                          ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    Text(
                      _formatTimestamp(timestamp),
                      style: const TextStyle(color: Colors.grey, fontSize: 12),
                    ),
                    const SizedBox(height: 16),
                    Row(
                      children: [
                        Expanded(
                          child: ElevatedButton.icon(
                            onPressed: () async {
                              final uri = Uri.parse(imageUrl);
                              if (await canLaunchUrl(uri)) {
                                await launchUrl(uri, mode: LaunchMode.externalApplication);
                              }
                            },
                            icon: const Icon(Icons.open_in_new, size: 16, color: Colors.white),
                            label: const Text("Open Full Image", style: TextStyle(color: Colors.white)),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: const Color(0xff1A56DB),
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                            ),
                          ),
                        ),
                        const SizedBox(width: 10),
                        OutlinedButton.icon(
                          onPressed: () async {
                            Navigator.pop(ctx);
                            await EnvironmentScannerService.deletePhoto(code, docId);
                            _showMsg("Photo deleted and storage released");
                          },
                          icon: const Icon(Icons.delete_outline, size: 16, color: Colors.red),
                          label: const Text("Delete", style: TextStyle(color: Colors.red)),
                          style: OutlinedButton.styleFrom(
                            side: const BorderSide(color: Colors.red),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  // ================= AUDIO TAB =================

  Widget _buildAudioTab(bool isDark, String uid, List<String> userDeviceCodes) {
    final targetCodes = _selectedDeviceCode != null
        ? [_selectedDeviceCode!]
        : userDeviceCodes;

    if (targetCodes.isEmpty) {
      return _buildEmptyState(
        isDark,
        Icons.audiotrack,
        "No Registered Devices",
        "Record 30-second ambient audio by tracing a device with its Unique Code.",
      );
    }

    if (targetCodes.length == 1) {
      final code = targetCodes.first;
      return StreamBuilder<QuerySnapshot>(
        stream: FirebaseFirestore.instance
            .collection('device_audio')
            .doc(code)
            .collection('records')
            .orderBy('timestamp', descending: true)
            .snapshots(),
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting && !snapshot.hasData) {
            return const Center(child: CircularProgressIndicator());
          }

          final docs = snapshot.data?.docs ?? [];
          if (docs.isEmpty) {
            return _buildEmptyState(
              isDark,
              Icons.mic_off_outlined,
              "No Audio Recordings Yet",
              "When you request a 30-second audio recording for device $code, it will appear here.",
            );
          }

          return _buildAudioList(isDark, docs, code);
        },
      );
    }

    return StreamBuilder<QuerySnapshot>(
      stream: FirebaseFirestore.instance
          .collectionGroup('records')
          .where('ownerUid', isEqualTo: uid)
          .orderBy('timestamp', descending: true)
          .snapshots(),
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return _buildMergedDeviceAudio(isDark, userDeviceCodes);
        }

        if (snapshot.connectionState == ConnectionState.waiting && !snapshot.hasData) {
          return const Center(child: CircularProgressIndicator());
        }

        final docs = snapshot.data?.docs ?? [];
        if (docs.isEmpty) {
          return _buildMergedDeviceAudio(isDark, userDeviceCodes);
        }

        return _buildAudioList(isDark, docs, null);
      },
    );
  }

  Widget _buildMergedDeviceAudio(bool isDark, List<String> codes) {
    return FutureBuilder<List<Map<String, dynamic>>>(
      future: _fetchMergedMedia(codes, 'device_audio', 'records'),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting && !snapshot.hasData) {
          return const Center(child: CircularProgressIndicator());
        }

        final items = snapshot.data ?? [];
        if (items.isEmpty) {
          return _buildEmptyState(
            isDark,
            Icons.mic_off_outlined,
            "No Audio Recordings Yet",
            "When 30-second audio recordings are created on your lost devices, they will appear here.",
          );
        }

        return ListView.builder(
          padding: const EdgeInsets.all(12),
          itemCount: items.length,
          itemBuilder: (context, index) {
            final item = items[index];
            return _buildAudioCard(
              isDark,
              item['data'] as Map<String, dynamic>,
              item['docId'] as String,
              item['code'] as String,
            );
          },
        );
      },
    );
  }

  Widget _buildAudioList(bool isDark, List<DocumentSnapshot> docs, String? defaultCode) {
    return ListView.builder(
      padding: const EdgeInsets.all(12),
      itemCount: docs.length,
      itemBuilder: (context, index) {
        final doc = docs[index];
        final data = doc.data() as Map<String, dynamic>;
        final code = data['deviceCode']?.toString().toUpperCase() ?? defaultCode ?? "";
        return _buildAudioCard(isDark, data, doc.id, code);
      },
    );
  }

  Widget _buildAudioCard(bool isDark, Map<String, dynamic> data, String docId, String code) {
    final audioUrl = data['audioUrl']?.toString() ?? '';
    final fileSize = (data['fileSize'] as num?)?.toInt() ??
        (data['fileSizeBytes'] as num?)?.toInt() ??
        0;
    final timestamp = data['timestamp'];
    final durationSeconds = (data['duration'] as num?)?.toInt() ?? 30;

    final isPlayingThis = _activeAudioUrl == audioUrl && _playerState == PlayerState.playing;
    final isActive = _activeAudioUrl == audioUrl;

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xff1E1E1E) : Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: isActive ? Colors.deepPurple.withValues(alpha: 0.5) : Colors.transparent,
          width: 1.5,
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.04),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              // Play/Pause circular button
              InkWell(
                onTap: audioUrl.isNotEmpty ? () => _toggleAudioPlay(audioUrl) : null,
                borderRadius: BorderRadius.circular(25),
                child: Container(
                  width: 46,
                  height: 46,
                  decoration: BoxDecoration(
                    color: Colors.deepPurple,
                    shape: BoxShape.circle,
                    boxShadow: [
                      BoxShadow(
                        color: Colors.deepPurple.withValues(alpha: 0.3),
                        blurRadius: 6,
                        offset: const Offset(0, 2),
                      ),
                    ],
                  ),
                  child: Icon(
                    isPlayingThis ? Icons.pause : Icons.play_arrow,
                    color: Colors.white,
                    size: 24,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        if (code.isNotEmpty)
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                            decoration: BoxDecoration(
                              color: isDark ? Colors.grey[800] : const Color(0xffEBF3FF),
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: Text(
                              code,
                              style: TextStyle(
                                color: isDark ? Colors.white : const Color(0xff1A56DB),
                                fontWeight: FontWeight.bold,
                                fontSize: 11,
                              ),
                            ),
                          ),
                        if (fileSize > 0)
                          Text(
                            StorageQuotaService.formatBytes(fileSize),
                            style: const TextStyle(color: Colors.grey, fontSize: 11),
                          ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(
                      _formatTimestamp(timestamp),
                      style: TextStyle(
                        fontSize: 11,
                        color: isDark ? Colors.white70 : Colors.black87,
                      ),
                    ),
                  ],
                ),
              ),
              IconButton(
                icon: const Icon(Icons.delete_outline, color: Colors.red, size: 20),
                onPressed: () async {
                  if (isPlayingThis) {
                    await _audioPlayer.stop();
                  }
                  await EnvironmentScannerService.deleteAudio(code, docId);
                  _showMsg("Audio recording deleted");
                },
              ),
            ],
          ),
          if (isActive) ...[
            const SizedBox(height: 8),
            Row(
              children: [
                Text(
                  _formatDuration(_audioPosition),
                  style: const TextStyle(fontSize: 10, color: Colors.deepPurple),
                ),
                Expanded(
                  child: Slider(
                    value: _audioPosition.inMilliseconds
                        .clamp(0, _audioDuration.inMilliseconds)
                        .toDouble(),
                    max: _audioDuration.inMilliseconds > 0
                        ? _audioDuration.inMilliseconds.toDouble()
                        : 30000.0,
                    activeColor: Colors.deepPurple,
                    inactiveColor: Colors.grey.withValues(alpha: 0.3),
                    onChanged: (val) {
                      _audioPlayer.seek(Duration(milliseconds: val.toInt()));
                    },
                  ),
                ),
                Text(
                  _formatDuration(_audioDuration),
                  style: const TextStyle(fontSize: 10, color: Colors.grey),
                ),
              ],
            ),
          ] else ...[
            const SizedBox(height: 4),
            Row(
              children: [
                const Icon(Icons.access_time, size: 12, color: Colors.grey),
                const SizedBox(width: 4),
                Text(
                  "${durationSeconds}s Duration",
                  style: const TextStyle(fontSize: 10, color: Colors.grey),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  // ================= HELPERS =================

  Future<List<Map<String, dynamic>>> _fetchMergedMedia(
    List<String> codes,
    String parentCollection,
    String subCollection,
  ) async {
    final List<Map<String, dynamic>> results = [];
    for (var code in codes) {
      try {
        final snap = await FirebaseFirestore.instance
            .collection(parentCollection)
            .doc(code)
            .collection(subCollection)
            .orderBy('timestamp', descending: true)
            .get();
        for (var doc in snap.docs) {
          results.add({
            'code': code,
            'docId': doc.id,
            'data': doc.data(),
          });
        }
      } catch (_) {}
    }
    // Sort descending by timestamp
    results.sort((a, b) {
      final aData = a['data'] as Map<String, dynamic>;
      final bData = b['data'] as Map<String, dynamic>;
      final aTs = aData['timestamp'];
      final bTs = bData['timestamp'];
      if (aTs is Timestamp && bTs is Timestamp) {
        return bTs.compareTo(aTs);
      }
      return 0;
    });
    return results;
  }

  Widget _buildEmptyState(
    bool isDark,
    IconData icon,
    String title,
    String subtitle,
  ) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                color: const Color(0xff1A56DB).withValues(alpha: 0.1),
                shape: BoxShape.circle,
              ),
              child: Icon(icon, size: 48, color: const Color(0xff1A56DB)),
            ),
            const SizedBox(height: 16),
            Text(
              title,
              style: TextStyle(
                fontWeight: FontWeight.bold,
                fontSize: 16,
                color: isDark ? Colors.white : Colors.black87,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              subtitle,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 12,
                color: isDark ? Colors.white60 : Colors.black54,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
