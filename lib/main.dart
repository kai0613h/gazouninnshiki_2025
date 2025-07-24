import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/cupertino.dart';
import 'package:camera/camera.dart';
import 'package:google_generative_ai/google_generative_ai.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:intl/intl.dart';
import 'package:flutter_ringtone_player/flutter_ringtone_player.dart';
import 'package:flutter/foundation.dart'; // <-- Isolate(compute)のために追加

// 警告：開発・テスト目的のみ。本番環境では使用しないでください。
class MyHttpOverrides extends HttpOverrides {
  @override
  HttpClient createHttpClient(SecurityContext? context) {
    return super.createHttpClient(context)
      ..badCertificateCallback =
          (X509Certificate cert, String host, int port) => true;
  }
}

const String geminiApiKey =
    String.fromEnvironment('GEMINI_API_KEY', defaultValue: '');

// ★★★ Isolateで実行されるトップレベル関数 ★★★
// この関数はクラスの外に定義する必要があります。
Future<bool> _analyzeImageInIsolate(Map<String, String> arguments) async {
  final apiKey = arguments['apiKey']!;
  final imagePath = arguments['path']!;

  // Isolate内では、再度必要なものを初期化します。
  HttpOverrides.global = MyHttpOverrides();

  try {
    final bytes = await File(imagePath).readAsBytes();
    final model = GenerativeModel(apiKey: apiKey, model: 'gemini-2.5-flash');
    final promptText = "Given one image, decide (1) whether there is at least one ceiling or wall light fixture and (2) whether it is visibly turned on; output exactly one lowercase word with no quotes or extra text: on if both (1) and (2) are true, otherwise off; if uncertain, answer off.";
    final prompt = [
      Content.multi([
        TextPart(promptText),
        DataPart('image/jpeg', bytes),
      ])
    ];

    final response = await model.generateContent(prompt);
    final text = response.text?.toLowerCase().trim();

    if (text == null || text.isEmpty) {
      print('Isolate: AI analysis returned an empty response.');
      return false;
    }

    print('Isolate AI Response: "$text"');
    return text.contains('on');
  } catch (e) {
    print('Error in Isolate: $e');
    return false; // エラー時はOFFとして扱う
  }
}


class Alarm {
  final int id;
  TimeOfDay time;
  bool isEnabled;

  Alarm({required this.id, required this.time, this.isEnabled = true});
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = MyHttpOverrides();

  if (geminiApiKey.isEmpty) {
    throw StateError('GEMINI_API_KEY が設定されていません。'
        '--dart-define=GEMINI_API_KEY=YOUR_API_KEY を設定して実行してください。');
  }

  await initializeDateFormatting('ja_JP', null);
  final cameras = await availableCameras();
  if (cameras.isEmpty) {
    runApp(const MaterialApp(
      home: Scaffold(
        body: Center(
          child: Text('利用可能なカメラがありません。'),
        ),
      ),
    ));
    return;
  }
  runApp(MyApp(camera: cameras.first));
}

class MyApp extends StatelessWidget {
  final CameraDescription camera;
  const MyApp({super.key, required this.camera});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '二度寝防止アラーム',
      theme: ThemeData.dark().copyWith(
        cupertinoOverrideTheme: const CupertinoThemeData(
          brightness: Brightness.dark,
          primaryColor: Colors.orangeAccent,
        ),
      ),
      home: MainScreen(camera: camera),
      debugShowCheckedModeBanner: false,
    );
  }
}

class MainScreen extends StatefulWidget {
  final CameraDescription camera;
  const MainScreen({super.key, required this.camera});

  @override
  State<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends State<MainScreen> {
  int _selectedIndex = 1;
  final GlobalKey<_AlarmClockPageState> _alarmPageKey = GlobalKey();
  final GlobalKey<_PeriodicCameraScreenState> _cameraPageKey = GlobalKey();
  late final List<Widget> _pages;

  @override
  void initState() {
    super.initState();
    _pages = [
      PeriodicCameraScreen(key: _cameraPageKey, camera: widget.camera),
      AlarmClockPage(
        key: _alarmPageKey,
        onAlarmRing: _handleAlarmRing,
      ),
    ];
  }

  void _handleAlarmRing() {
    _onItemTapped(0);
    _cameraPageKey.currentState?.startCaptureAndAnalysis();
  }

  void _onItemTapped(int index) {
    setState(() {
      _selectedIndex = index;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_selectedIndex == 0 ? '照明を認識中...' : '時計・アラーム'),
        actions: _selectedIndex == 1
            ? [
                IconButton(
                  icon: const Icon(Icons.add_alarm),
                  onPressed: () => _alarmPageKey.currentState?._addAlarm(),
                ),
              ]
            : null,
      ),
      body: IndexedStack(
        index: _selectedIndex,
        children: _pages,
      ),
      bottomNavigationBar: BottomNavigationBar(
        items: const <BottomNavigationBarItem>[
          BottomNavigationBarItem(
            icon: Icon(Icons.camera_alt),
            label: 'カメラ',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.alarm),
            label: 'アラーム',
          ),
        ],
        currentIndex: _selectedIndex,
        onTap: _onItemTapped,
      ),
    );
  }
}

class PeriodicCameraScreen extends StatefulWidget {
  const PeriodicCameraScreen({super.key, required this.camera});
  final CameraDescription camera;
  @override
  State<PeriodicCameraScreen> createState() => _PeriodicCameraScreenState();
}

class _PeriodicCameraScreenState extends State<PeriodicCameraScreen> {
  CameraController? _controller;
  bool _isPermissionGranted = false;
  bool _isCapturingAndProcessing = false;
  final ValueNotifier<String> _statusMessage = ValueNotifier<String>('アラーム待機中...');

  @override
  void initState() {
    super.initState();
    _initializeCamera();
  }

  @override
  void dispose() {
    _isCapturingAndProcessing = false;
    _controller?.dispose();
    _statusMessage.dispose();
    super.dispose();
  }

  Future<void> _initializeCamera() async {
    final status = await Permission.camera.request();
    if (!mounted) return;
    setState(() => _isPermissionGranted = status.isGranted);
    if (!status.isGranted) {
      _statusMessage.value = 'カメラの権限がありません。';
      return;
    }
    try {
      _controller = CameraController(
        widget.camera,
        ResolutionPreset.medium,
        enableAudio: false,
      );
      await _controller!.initialize();
      if (mounted) setState(() {});
    } catch (e) {
      if (mounted) {
        _statusMessage.value = 'カメラの初期化に失敗しました: $e';
      }
    }
  }

  void startCaptureAndAnalysis() {
    if (_isCapturingAndProcessing || !mounted) return;
    setState(() => _isCapturingAndProcessing = true);
    _statusMessage.value = '天井の照明を探しています...';
    _captureAndAnalyzeLoop();
  }

  void stopCaptureAndAnalysis() {
    if (mounted) {
      setState(() => _isCapturingAndProcessing = false);
      _statusMessage.value = 'アラーム待機中...';
    }
  }

  Future<void> _captureAndAnalyzeLoop() async {
    if (!_isCapturingAndProcessing || !mounted || _controller == null || !_controller!.value.isInitialized) {
      return;
    }
    try {
      _statusMessage.value = '撮影しています...';
      final image = await _controller!.takePicture();
      _statusMessage.value = '画像を解析中です...';

      // ★★★ Isolate(compute)を使って重い処理をバックグラウンドで実行 ★★★
      final bool isLightOn = await compute(_analyzeImageInIsolate, {
        'apiKey': geminiApiKey,
        'path': image.path,
      });

      if (!mounted) return;
      if (isLightOn) {
        _statusMessage.value = '照明を認識しました！偉い！💡\nアラームを停止します。';
        await FlutterRingtonePlayer().stop();
        stopCaptureAndAnalysis();
      } else {
        _statusMessage.value = 'まだ照明が消えています。\n起きて電気をつけてください！';
      }
    } catch (e) {
      if (mounted) {
        _statusMessage.value = 'エラーが発生しました。\n10秒後に再試行します。';
      }
      print('Error in capture/analysis loop: $e');
    }
    if (_isCapturingAndProcessing && mounted) {
      Future.delayed(const Duration(seconds: 5), _captureAndAnalyzeLoop);
    }
  }

  // このメソッドはもう使用しませんが、呼び出し部分を compute に置き換えたことを示すために残しておきます。
  // Future<bool> _detectLightStatus(String imagePath) async { ... }

  @override
  Widget build(BuildContext context) {
    if (!_isPermissionGranted) {
      return Center(child: Text(_statusMessage.value));
    }
    if (_controller == null || !_controller!.value.isInitialized) {
      return Center(
          child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const CircularProgressIndicator(),
          const SizedBox(height: 16),
          ValueListenableBuilder<String>(
            valueListenable: _statusMessage,
            builder: (context, message, child) => Text(message),
          ),
        ],
      ));
    }
    return PopScope(
      canPop: !_isCapturingAndProcessing,
      onPopInvoked: (bool didPop) {
        if (didPop) return;
        if (_isCapturingAndProcessing) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('照明をONにするまでアラームは停止できません！'),
              duration: Duration(seconds: 2),
            ),
          );
        }
      },
      child: Stack(
        alignment: Alignment.center,
        children: [
          CameraPreview(_controller!),
          if (_isCapturingAndProcessing)
            Container(
              color: Colors.black.withOpacity(0.7),
              child: Center(
                child: Padding(
                  padding: const EdgeInsets.all(24.0),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const CircularProgressIndicator(color: Colors.white),
                      const SizedBox(height: 20),
                      ValueListenableBuilder<String>(
                        valueListenable: _statusMessage,
                        builder: (context, message, child) {
                          return Text(
                            message,
                            textAlign: TextAlign.center,
                            style: const TextStyle(
                                fontSize: 22,
                                color: Colors.white,
                                fontWeight: FontWeight.bold),
                          );
                        },
                      ),
                    ],
                  ),
                ),
              ),
            ),
          if (!_isCapturingAndProcessing)
            Container(
              color: Colors.black54,
              child: Center(
                child: ValueListenableBuilder<String>(
                  valueListenable: _statusMessage,
                  builder: (context, message, child) {
                    return Text(
                      message,
                      style: const TextStyle(fontSize: 24, color: Colors.white),
                    );
                  },
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class AlarmClockPage extends StatefulWidget {
  final VoidCallback onAlarmRing;
  const AlarmClockPage({super.key, required this.onAlarmRing});

  @override
  State<AlarmClockPage> createState() => _AlarmClockPageState();
}

class _AlarmClockPageState extends State<AlarmClockPage> {
  late Timer _clockTimer;
  late Timer _alarmTimer;
  DateTime _currentTime = DateTime.now();
  final List<Alarm> _alarms = [];

  @override
  void initState() {
    super.initState();
    _clockTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (mounted) setState(() => _currentTime = DateTime.now());
    });
    _alarmTimer = Timer.periodic(const Duration(seconds: 1), _checkAlarms);
  }

  void _checkAlarms(Timer timer) {
    final now = DateTime.now();
    for (var alarm in _alarms) {
      if (alarm.isEnabled &&
          alarm.time.hour == now.hour &&
          alarm.time.minute == now.minute &&
          now.second == 0) {
        FlutterRingtonePlayer().playAlarm(looping: true);
        widget.onAlarmRing();
      }
    }
  }

  void _addAlarm() async {
    final selectedTime = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.now(),
    );
    if (selectedTime != null) {
      setState(() {
        _alarms.add(Alarm(id: DateTime.now().millisecondsSinceEpoch, time: selectedTime));
        _alarms.sort((a, b) {
          final aTime = a.time.hour * 60 + a.time.minute;
          final bTime = b.time.hour * 60 + b.time.minute;
          return aTime.compareTo(bTime);
        });
      });
    }
  }

  @override
  void dispose() {
    _clockTimer.cancel();
    _alarmTimer.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    String formattedDate = DateFormat('yyyy年MM月dd日 (E)', 'ja_JP').format(_currentTime);
    String formattedTime = DateFormat('HH:mm:ss').format(_currentTime);

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 32.0),
          child: Column(
            children: [
              Text(formattedDate, style: Theme.of(context).textTheme.headlineSmall),
              const SizedBox(height: 8),
              Text(formattedTime, style: Theme.of(context).textTheme.displayMedium),
            ],
          ),
        ),
        const Divider(),
        Expanded(
          child: _alarms.isEmpty
              ? const Center(child: Text('アラームが設定されていません'))
              : ListView.builder(
                  itemCount: _alarms.length,
                  itemBuilder: (context, index) {
                    final alarm = _alarms[index];
                    return ListTile(
                      title: Text(
                        alarm.time.format(context),
                        style: TextStyle(
                          fontSize: 28,
                          fontWeight: FontWeight.bold,
                          decoration: alarm.isEnabled ? TextDecoration.none : TextDecoration.lineThrough,
                          color: alarm.isEnabled ? Colors.white : Colors.grey,
                        ),
                      ),
                      trailing: CupertinoSwitch(
                        value: alarm.isEnabled,
                        onChanged: (bool value) {
                          setState(() => alarm.isEnabled = value);
                        },
                      ),
                      onLongPress: () {
                        showDialog(
                          context: context,
                          builder: (context) => AlertDialog(
                            title: const Text('アラームの削除'),
                            content: const Text('このアラームを削除しますか？'),
                            actions: [
                              TextButton(onPressed: () => Navigator.pop(context), child: const Text('キャンセル')),
                              TextButton(
                                onPressed: () {
                                  setState(() => _alarms.removeAt(index));
                                  Navigator.pop(context);
                                },
                                child: const Text('削除'),
                              ),
                            ],
                          ),
                        );
                      },
                    );
                  },
                ),
        ),
      ],
    );
  }
}
