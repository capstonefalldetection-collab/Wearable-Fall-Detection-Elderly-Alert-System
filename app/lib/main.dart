// Fall Detector companion app
//
// Flow: wearable (BLE) -> this app -> 30 s "Are you OK?" countdown ->
// Telegram group (internet) -> family members' phones, anywhere.

import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'cloud_alert.dart';

// Must match the UUIDs in the ESP32 firmware exactly.
final Guid serviceUuid = Guid("6b1a1e00-2f6a-4e40-9a6e-2b7d0f7a11a1");
final Guid alertCharUuid = Guid("6b1a1e01-2f6a-4e40-9a6e-2b7d0f7a11a1");
const String targetDeviceName = "FallDetector";

// Seconds the wearer has to tap "I'm OK" before family is alerted.
const int countdownSeconds = 30;
final FlutterLocalNotificationsPlugin notificationsPlugin = FlutterLocalNotificationsPlugin();

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await _initNotifications();
  runApp(const FallDetectorApp());
}

Future<void> _initNotifications() async {
  const androidSettings = AndroidInitializationSettings('@mipmap/ic_launcher');
  const iosSettings = DarwinInitializationSettings();
  await notificationsPlugin.initialize(
    const InitializationSettings(android: androidSettings, iOS: iosSettings),
  );
}

Future<void> _showFallNotification() async {
  const androidDetails = AndroidNotificationDetails(
    'fall_alerts',
    'Fall Alerts',
    channelDescription: 'Alerts when a fall is detected',
    importance: Importance.max,
    priority: Priority.high,
  );
  const details = NotificationDetails(android: androidDetails, iOS: DarwinNotificationDetails());
  await notificationsPlugin.show(
    0,
    'Fall Detected',
    'Open the app and tap "I\'m OK" within $countdownSeconds seconds to cancel the family alert.',
    details,
  );
}

class FallDetectorApp extends StatelessWidget {
  const FallDetectorApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Fall Detector',
      theme: ThemeData(colorSchemeSeed: Colors.indigo, useMaterial3: true),
      home: const HomeScreen(),
    );
  }
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}
class _HomeScreenState extends State<HomeScreen> {
  BluetoothDevice? _device;
  StreamSubscription<List<int>>? _notifySub;
  String _connectionStatus = "Not connected";
  String _lastStatus = "no_fall";
  bool _scanning = false;
  final List<String> _alertLog = [];
  String? _emergencyContact;
  late final CloudAlertService _cloud;
  bool _cloudReady = false;
  int _pendingCount = 0;

  // Countdown state
  Timer? _countdownTimer;
  bool _countingDown = false;
  int _secondsLeft = 0;
  DateTime? _fallTime;

  @override
  void initState() {
    super.initState();
    _cloud = CloudAlertService(onLog: _log);
    _loadSettings();

    // Request battery optimization exemption on launch (Step 4)
    FlutterForegroundTask.isIgnoringBatteryOptimizations.then((isIgnoring) {
      if (!isIgnoring) {
        FlutterForegroundTask.requestIgnoreBatteryOptimization();
      }
    });
  }

  @override
  void dispose() {
    _countdownTimer?.cancel();
    _notifySub?.cancel();
    _cloud.dispose();
    _device?.disconnect();
    
    // Clean up background task notifications cleanly when the app closes
    FlutterForegroundTask.stopService(); 
    super.dispose();
  }

  Future<void> _loadSettings() async {
    await Permission.notification.request();
    final prefs = await SharedPreferences.getInstance();
    await _cloud.load();
    final pending = await _cloud.pendingCount();
    if (!mounted) return;
    setState(() {
      _emergencyContact = prefs.getString('emergency_contact');
      _cloudReady = _cloud.isConfigured;
      _pendingCount = pending;
    });
  }

  void _log(String message) {
    if (!mounted) return;
    setState(() => _alertLog.insert(0, "${_hhmmss(DateTime.now())} $message"));
  }

  static String _hhmmss(DateTime t) =>
      "${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}:${t.second.toString().padLeft(2, '0')}";

  Future<void> _saveContact(String number) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('emergency_contact', number);
    setState(() => _emergencyContact = number);
  }

  // ---------------------------------------------------------------- BLE ---

  Future<void> _scanAndConnect() async {
    setState(() {
      _scanning = true;
      _connectionStatus = "Requesting permissions...";
      _alertLog.insert(0, "-- scan started --");
    });

    try {
      await FlutterBluePlus.stopScan().catchError((_) {});

      final statuses = await [
        Permission.bluetoothScan,
        Permission.bluetoothConnect,
        Permission.locationWhenInUse,
      ].request();

      final denied = statuses.entries.where((e) => !e.value.isGranted).toList();
      if (denied.isNotEmpty) {
        setState(() {
          _scanning = false;
          _connectionStatus =
              "Permission denied: ${denied.map((e) => e.key).join(', ')}. Grant in phone Settings > Apps > Fall Detector.";
        });
        return;
      }

      setState(() => _connectionStatus = "Scanning...");

      var subscription = FlutterBluePlus.onScanResults.listen((results) async {
        for (final r in results) {
          final advName = r.advertisementData.advName;
          final name = r.device.platformName.isNotEmpty ? r.device.platformName : advName;
          if (name.isNotEmpty) {
            _log("Found device: $name");
          }
          if (name == targetDeviceName) {
            await FlutterBluePlus.stopScan();
            await _connect(r.device);
            break;
          }
        }
      }, onError: (e) {
        setState(() {
          _scanning = false;
          _connectionStatus = "Scan error: $e";
        });
      });

      await FlutterBluePlus.startScan(timeout: const Duration(seconds: 8));
      await Future.delayed(const Duration(seconds: 9));
      subscription.cancel();

      if (_device == null && mounted) {
        setState(() {
          _scanning = false;
          _connectionStatus = "Device not found -- check Location Services is ON (Android) and the wearable is powered on and nearby.";
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _scanning = false;
          _connectionStatus = "Scan failed: $e";
        });
      }
    }
  }

  // 1. INITIALIZATION HELPER (No 'const' modifier anywhere here!)
  void _initForegroundTask() {
    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: 'fall_guard',
        channelName: 'Fall protection',
        channelDescription: 'Keeps Fall Guard active in the background',
        channelImportance: NotificationChannelImportance.DEFAULT,
        priority: NotificationPriority.DEFAULT,
      ),
      iosNotificationOptions: const IOSNotificationOptions(),
      foregroundTaskOptions: ForegroundTaskOptions(
        eventAction: ForegroundTaskEventAction.nothing(),
        allowWakeLock: true,
        allowWifiLock: true,
      ),
    );
  }

  // 2. CONNECT LOGIC WITH STABLE BACKGROUND FOREGROUND INITIALIZATIONS
  Future<void> _connect(BluetoothDevice device) async {
    setState(() => _connectionStatus = "Connecting...");
    try {
      await device.connect(timeout: const Duration(seconds: 10));
      final services = await device.discoverServices();

      for (final service in services) {
        if (service.uuid == serviceUuid) {
          for (final c in service.characteristics) {
            if (c.uuid == alertCharUuid) {
              await c.setNotifyValue(true);
              _notifySub = c.lastValueStream.listen(_onAlertValue);
            }
          }
        }
      }

      setState(() {
        _device = device;
        _scanning = false;
        _connectionStatus = "Connected to $targetDeviceName";
      });

      _initForegroundTask();

      if (await FlutterForegroundTask.isRunningService) {
        await FlutterForegroundTask.restartService();
      } else {
        await FlutterForegroundTask.startService(
          notificationTitle: 'Fall Detector is active',
          notificationText: 'Watching the wearable...',
        );
      }
      _log("Foreground service started successfully.");

      // Background reconnection loop logic (Step 5)
      device.connectionState.listen((state) async {
        if (state == BluetoothConnectionState.disconnected && mounted) {
          _log("Device disconnected! Attempting background auto-reconnect...");

          setState(() {
            _connectionStatus = "Disconnected -- trying to reconnect...";
            _lastStatus = "no_fall";
          });

          if (await FlutterForegroundTask.isRunningService) {
            await FlutterForegroundTask.updateService(
              notificationTitle: 'Fall Detector - Link Dropped',
              notificationText: 'Searching for wearable connection...',
            );
          }

          bool reconnected = false;
          while (!reconnected && _device != null) {
            try {
              await device.connect(timeout: const Duration(seconds: 5));
              reconnected = true;

              setState(() {
                _connectionStatus = "Connected to $targetDeviceName";
              });

              await FlutterForegroundTask.updateService(
                notificationTitle: 'Fall Detector is active',
                notificationText: 'Watching the wearable...',
              );
              _log("Successfully reconnected to wearable!");
            } catch (e) {
              _log("Reconnect failed, retrying in 5 seconds...");
              await Future.delayed(const Duration(seconds: 5));
            }
          }
        }
      });

    } catch (e) {
      setState(() {
        _scanning = false;
        _connectionStatus = "Connection failed: $e";
      });
      _log("Error during connection setup: $e");
    }
  }

  void _onAlertValue(List<int> value) {
    if (value.isEmpty) return;

    int statusCode = value.first;
    String status = (statusCode == 1) ? "fall_detected" : "no_fall";

    setState(() => _lastStatus = status);
    _log("Telemetry frame read: $statusCode (Mapped: $status)");

    if (status == "fall_detected") {
      _showFallNotification();
      _startCountdown();
    }
  }
  // ---------------------------------------------------------- Countdown ---

  void _startCountdown() {
    if (_countingDown) return;
    _fallTime = DateTime.now();
    setState(() {
      _countingDown = true;
      _secondsLeft = countdownSeconds;
    });
    _countdownTimer?.cancel();
    _countdownTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) {
        timer.cancel();
        return;
      }
      if (_secondsLeft <= 1) {
        timer.cancel();
        _sendFamilyAlert();
      } else {
        setState(() => _secondsLeft--);
      }
    });
  }

  void _cancelCountdown() {
    _countdownTimer?.cancel();
    setState(() {
      _countingDown = false;
      _lastStatus = "no_fall";
    });
    _log("Wearer confirmed OK -- family alert cancelled");
  }

  Future<void> _sendFamilyAlert() async {
    _countdownTimer?.cancel();
    final when = _fallTime ?? DateTime.now();
    setState(() {
      _countingDown = false;
      _secondsLeft = 0;
    });

    final message = "FALL ALERT: a fall was detected at ${_hhmmss(when)} and the wearer did not confirm they are OK. Please call them now.";
    await _deliver(message);
  }

  Future<void> _sendTest() async {
    await _deliver("Test message from the Fall Detector app. If you can read this, family alerts are working.");
  }

  Future<void> _deliver(String message) async {
    final result = await _cloud.sendAlert(message);
    final pending = await _cloud.pendingCount();
    if (!mounted) return;
    setState(() => _pendingCount = pending);

    switch (result) {
      case SendResult.sent:
        _log("Alert sent to family group");
        break;
      case SendResult.queued:
        _log("No internet -- alert saved, will retry automatically");
        break;
      case SendResult.notConfigured:
        _log("Family alerts not set up yet -- tap 'Set up family alerts'");
        break;
      case SendResult.rejected:
        _log("Telegram rejected the alert -- check bot token and chat ID");
        break;
    }
  }

  // ------------------------------------------------------------ Dialogs ---

  Future<void> _editCloudConfig() async {
    final tokenCtrl = TextEditingController(text: _cloud.savedToken);
    final chatCtrl = TextEditingController(text: _cloud.savedChatId);
    final saved = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text("Family alerts (Telegram)"),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: tokenCtrl,
                decoration: const InputDecoration(labelText: "Bot token (from @BotFather)"),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: chatCtrl,
                keyboardType: TextInputType.text,
                decoration: const InputDecoration(labelText: "Group chat ID (e.g. -1001234567890)"),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text("Cancel")),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text("Save")),
        ],
      ),
    );
    if (saved == true) {
      await _cloud.saveConfig(tokenCtrl.text, chatCtrl.text);
      if (!mounted) return;
      setState(() => _cloudReady = _cloud.isConfigured);
      _log(_cloud.isConfigured ? "Family alerts configured" : "Token or chat ID missing");
    }
  }

  Future<void> _notifyBySms() async {
    if (_emergencyContact == null || _emergencyContact!.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Set an emergency contact number first")),
      );
      return;
    }
    final message = Uri.encodeComponent("Fall alert: a fall was detected on the wearable device. Please check in.");
    final uri = Uri.parse("sms:$_emergencyContact?body=$message");
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri);
    }
  }

  Future<void> _editContact() async {
    final controller = TextEditingController(text: _emergencyContact ?? "");
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text("Emergency contact number"),
        content: TextField(
          controller: controller,
          keyboardType: TextInputType.phone,
          decoration: const InputDecoration(hintText: "+1 555 123 4567"),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text("Cancel")),
          TextButton(
            onPressed: () => Navigator.pop(ctx, controller.text),
            child: const Text("Save"),
          ),
        ],
      ),
    );
    if (result != null && result.isNotEmpty) {
      await _saveContact(result);
    }
  }

  // -------------------------------------------------------------- Build ---

  @override
  Widget build(BuildContext context) {
    final isFall = _lastStatus == "fall_detected";
    return Scaffold(
      appBar: AppBar(title: const Text("Fall Detector")),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            color: isFall ? Colors.red.shade50 : Colors.green.shade50,
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(_connectionStatus, style: Theme.of(context).textTheme.bodyMedium),
                  const SizedBox(height: 12),
                  Text(
                    isFall ? "FALL DETECTED" : "No fall -- all clear",
                    style: TextStyle(
                      fontSize: 24,
                      fontWeight: FontWeight.bold,
                      color: isFall ? Colors.red : Colors.green.shade800,
                    ),
                  ),
                ],
              ),
            ),
          ),
          if (_countingDown) ...[
            const SizedBox(height: 12),
            Card(
              color: Colors.orange.shade100,
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: Column(
                  children: [
                    Text(
                      "Alerting family in $_secondsLeft s",
                      style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
                    ),
                    const SizedBox(height: 4),
                    const Text("Tap \"I'm OK\" if this was a false alarm."),
                    const SizedBox(height: 12),
                    SizedBox(
                      width: double.infinity,
                      child: FilledButton(
                        onPressed: _cancelCountdown,
                        style: FilledButton.styleFrom(
                          backgroundColor: Colors.green.shade700,
                          padding: const EdgeInsets.symmetric(vertical: 18),
                        ),
                        child: const Text("I'm OK", style: TextStyle(fontSize: 20)),
                      ),
                    ),
                    const SizedBox(height: 8),
                    SizedBox(
                      width: double.infinity,
                      child: OutlinedButton(
                        onPressed: _sendFamilyAlert,
                        child: const Text("Send alert now"),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
          if (_pendingCount > 0) ...[
            const SizedBox(height: 12),
            Card(
              color: Colors.amber.shade100,
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Text(
                  "$_pendingCount alert(s) waiting for internet -- retrying automatically.",
                ),
              ),
            ),
          ],
          const SizedBox(height: 16),
          ElevatedButton.icon(
            onPressed: _scanning ? null : _scanAndConnect,
            icon: const Icon(Icons.bluetooth_searching),
            label: Text(_scanning ? "Scanning..." : "Scan & Connect"),
          ),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: _editCloudConfig,
            icon: Icon(_cloudReady ? Icons.cloud_done : Icons.cloud_off),
            label: Text(_cloudReady ? "Family alerts: set up" : "Set up family alerts"),
          ),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: _cloudReady ? _sendTest : null,
            icon: const Icon(Icons.send),
            label: const Text("Send test message to family"),
          ),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: _editContact,
            icon: const Icon(Icons.contact_phone),
            label: Text(_emergencyContact == null
                ? "Set emergency contact (SMS backup)"
                : "SMS contact: $_emergencyContact"),
          ),
          if (isFall && !_countingDown) ...[
            const SizedBox(height: 8),
            ElevatedButton.icon(
              onPressed: _notifyBySms,
              icon: const Icon(Icons.sms),
              label: const Text("Text emergency contact"),
              style: ElevatedButton.styleFrom(backgroundColor: Colors.red, foregroundColor: Colors.white),
            ),
          ],
          const SizedBox(height: 24),
          Text("Activity log", style: Theme.of(context).textTheme.titleMedium),
          ..._alertLog.take(12).map((e) => Text(e, style: const TextStyle(fontSize: 12))),
        ],
      ),
    );
  }
}
