import 'dart:async';
import 'dart:io';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:camera/camera.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:intl/intl.dart';
import 'package:flutter_ringtone_player/flutter_ringtone_player.dart';

// アラーム情報を保持するためのクラス
class Alarm {
  final int id;
  TimeOfDay time;
  bool isEnabled;

  Alarm({required this.id, required this.time, this.isEnabled = true});
}

// main関数：アプリの起動点
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await initializeDateFormatting('ja_JP', null);
  final cameras = await availableCameras();
  runApp(MyApp(camera: cameras.first));
}

// アプリケーションのルートウィジェット
class MyApp extends StatelessWidget {
  final CameraDescription camera;
  const MyApp({super.key, required this.camera});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '多機能アプリ',
      theme: ThemeData.dark().copyWith(
        cupertinoOverrideTheme: const CupertinoThemeData(
          brightness: Brightness.dark,
          primaryColor: Colors.orange,
        ),
      ),
      home: MainScreen(camera: camera),
    );
  }
}

// ボトムナビゲーションバーを持つメイン画面
class MainScreen extends StatefulWidget {
  final CameraDescription camera;
  const MainScreen({super.key, required this.camera});

  @override
  State<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends State<MainScreen> {
  int _selectedIndex = 0;
  final GlobalKey<_AlarmClockPageState> _alarmPageKey = GlobalKey();
  // ★★★ カメラページを外部から操作するためのキーを追加 ★★★
  final GlobalKey<_PeriodicCameraScreenState> _cameraPageKey = GlobalKey();
  late final List<Widget> _pages;

  @override
  void initState() {
    super.initState();
    _pages = [
      // ★★★ カメラページにキーを設定 ★★★
      PeriodicCameraScreen(key: _cameraPageKey, camera: widget.camera),
      // ★★★ アラームページに「撮影開始」の指令を出す関数を渡す ★★★
      AlarmClockPage(
        key: _alarmPageKey,
        onAlarmRing: _startPeriodicPhotoCapture,
      ),
    ];
  }

  // ★★★ カメラ撮影を開始させるための関数 ★★★
  void _startPeriodicPhotoCapture() {
    // 他のページからカメラページのメソッドを呼び出す
    _cameraPageKey.currentState?.startPeriodicCapture();
    // カメラページに切り替える
    _onItemTapped(0);
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
        title: Text(_selectedIndex == 0 ? '定期撮影カメラ' : '時計・アラーム'),
        actions: _selectedIndex == 1
            ? [
                IconButton(
                  icon: const Icon(Icons.add),
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

// --- カメラページ ---
class PeriodicCameraScreen extends StatefulWidget {
  const PeriodicCameraScreen({super.key, required this.camera});
  final CameraDescription camera;
  @override
  State<PeriodicCameraScreen> createState() => _PeriodicCameraScreenState();
}

class _PeriodicCameraScreenState extends State<PeriodicCameraScreen> {
  CameraController? _controller;
  Timer? _timer;
  bool _isPermissionGranted = false;
  // ★★★ 撮影中かどうかを管理する状態を追加 ★★★
  bool _isCapturing = false;

  @override
  void initState() {
    super.initState();
    _initializeCamera();
  }

  Future<void> _initializeCamera() async {
    final status = await Permission.camera.request();
    if (status.isGranted) {
      if (!mounted) return;
      setState(() => _isPermissionGranted = true);
      _controller = CameraController(widget.camera, ResolutionPreset.high);
      await _controller!.initialize();
      if (mounted) {
        setState(() {});
        // ★★★ 初期化時の自動撮影開始を削除 ★★★
        // startPeriodicCapture();
      }
    } else {
      if (!mounted) return;
      setState(() => _isPermissionGranted = false);
    }
  }

  // ★★★ 撮影開始のロジック ★★★
  void startPeriodicCapture() {
    // すでに撮影中の場合は何もしない
    if (_isCapturing) return;

    setState(() {
      _isCapturing = true;
    });

    _timer = Timer.periodic(const Duration(seconds: 10), (timer) async {
      if (_controller == null || !_controller!.value.isInitialized) return;
      try {
        final image = await _controller!.takePicture();
        if (mounted) {
          showDialog(
            context: context,
            builder: (BuildContext context) {
              return AlertDialog(
                content: Image.file(File(image.path), fit: BoxFit.contain),
                actions: <Widget>[
                  TextButton(
                    child: const Text('閉じる'),
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ],
              );
            },
          );
        }
      } catch (e) {
        print('写真撮影中にエラーが発生しました: $e');
      }
    });
  }

  // ★★★ 撮影停止のロジックを追加 ★★★
  void stopPeriodicCapture() {
    _timer?.cancel();
    setState(() {
      _isCapturing = false;
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_isPermissionGranted) {
      return const Center(
        child: Text('カメラの権限が許可されていません。', style: TextStyle(fontSize: 18)),
      );
    }
    if (_controller == null || !_controller!.value.isInitialized) {
      return const Center(child: CircularProgressIndicator());
    }
    // ★★★ UIの構造を変更 ★★★
    return Stack(
      alignment: Alignment.center,
      children: [
        // カメラプレビュー
        CameraPreview(_controller!),
        // 撮影状態に応じて表示を切り替え
        if (_isCapturing)
          // 撮影中の表示
          Positioned(
            bottom: 20,
            child: ElevatedButton.icon(
              icon: const Icon(Icons.stop_circle),
              label: const Text('撮影停止'),
              onPressed: stopPeriodicCapture,
              style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
            ),
          )
        else
          // 待機中の表示
          Container(
            color: Colors.black54,
            child: const Center(
              child: Text(
                'アラーム待機中...',
                style: TextStyle(fontSize: 24, color: Colors.white),
              ),
            ),
          ),
      ],
    );
  }
}

// --- 時計・アラームページ ---
class AlarmClockPage extends StatefulWidget {
  // ★★★ 親ウィジェットから関数を受け取るための変数を追加 ★★★
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
      if (mounted) {
        setState(() => _currentTime = DateTime.now());
      }
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
        // ★★★ アラームが鳴った時に親から渡された関数を呼び出す ★★★
        widget.onAlarmRing();

        final player = FlutterRingtonePlayer();
        player.playAlarm(looping: true);
        showDialog(
          context: context,
          barrierDismissible: false,
          builder: (context) => AlertDialog(
            title: const Text('アラーム'),
            content: Text('${alarm.time.format(context)}の時間です。'),
            actions: [
              TextButton(
                onPressed: () {
                  player.stop();
                  Navigator.pop(context);
                },
                child: const Text('停止'),
              ),
            ],
          ),
        );
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
              ? const Center(child: Text('アラームがありません'))
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
                          color: alarm.isEnabled ? Colors.white : Colors.grey,
                        ),
                      ),
                      trailing: CupertinoSwitch(
                        value: alarm.isEnabled,
                        onChanged: (bool value) {
                          setState(() {
                            alarm.isEnabled = value;
                          });
                        },
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }
}
