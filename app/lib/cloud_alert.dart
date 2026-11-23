// Cloud alert service for the Fall Detector app.
//
// Sends the fall alert to a Telegram group over the internet, so family
// members receive it on their own phones wherever they are -- they do NOT
// need to be on the same WiFi or near the wearable. Telegram is used because
// it is free, needs no server of our own, and delivers real push
// notifications to everyone in the group.
//
// If the phone has no internet at the moment of the fall, the alert is saved
// in a queue on the phone and retried every few seconds until it goes
// through, so it is delayed rather than lost.
//
// The bot token and group chat ID are typed into the app once and stored on
// the phone (SharedPreferences). They are deliberately NOT written in source
// code, so they never end up in the GitHub repository.

import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

enum SendResult {
  sent, // delivered to Telegram
  queued, // no internet / Telegram unreachable, will retry automatically
  notConfigured, // bot token / chat ID not entered yet
  rejected, // Telegram answered with an error (wrong token or chat ID)
}

class CloudAlertService {
  static const _kToken = 'tg_bot_token';
  static const _kChatId = 'tg_chat_id';
  static const _kPending = 'pending_alerts';

  final void Function(String message) onLog;

  String? _botToken;
  String? _chatId;
  Timer? _retryTimer;
  bool _retrying = false;

  CloudAlertService({required this.onLog});

  bool get isConfigured =>
      (_botToken ?? '').isNotEmpty && (_chatId ?? '').isNotEmpty;

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    _botToken = prefs.getString(_kToken);
    _chatId = prefs.getString(_kChatId);
    // Check the queue every 20 seconds; cheap when it is empty.
    _retryTimer?.cancel();
    _retryTimer = Timer.periodic(const Duration(seconds: 20), (_) => retryPending());
  }

  Future<void> saveConfig(String botToken, String chatId) async {
    final prefs = await SharedPreferences.getInstance();
    _botToken = botToken.trim();
    _chatId = chatId.trim();
    await prefs.setString(_kToken, _botToken!);
    await prefs.setString(_kChatId, _chatId!);
  }

  String get savedChatId => _chatId ?? '';
  String get savedToken => _botToken ?? '';

  /// Sends [text] to the family group. Never throws.
  Future<SendResult> sendAlert(String text) async {
    if (!isConfigured) return SendResult.notConfigured;

    final outcome = await _post(text);
    if (outcome == _PostOutcome.ok) return SendResult.sent;
    if (outcome == _PostOutcome.rejected) return SendResult.rejected;

    // Network problem: keep the alert and keep trying.
    await _enqueue(text);
    return SendResult.queued;
  }

  Future<_PostOutcome> _post(String text) async {
    try {
      final uri = Uri.https('api.telegram.org', '/bot$_botToken/sendMessage');
      final res = await http
          .post(uri, body: {'chat_id': _chatId!, 'text': text})
          .timeout(const Duration(seconds: 10));
      if (res.statusCode == 200) return _PostOutcome.ok;
      // 400/401/403/404 mean the request itself is wrong (bad token, bot not
      // in the group, wrong chat ID). Retrying will not fix that.
      if (res.statusCode >= 400 && res.statusCode < 500 && res.statusCode != 429) {
        onLog('Telegram rejected the alert (HTTP ${res.statusCode}): ${res.body}');
        return _PostOutcome.rejected;
      }
      return _PostOutcome.networkError; // 429 / 5xx: try again later
    } catch (_) {
      // SocketException, timeout, no route to host, etc.
      return _PostOutcome.networkError;
    }
  }

  Future<void> _enqueue(String text) async {
    final prefs = await SharedPreferences.getInstance();
    final list = prefs.getStringList(_kPending) ?? <String>[];
    list.add(jsonEncode({'text': text, 'queuedAt': DateTime.now().toIso8601String()}));
    await prefs.setStringList(_kPending, list);
  }

  Future<int> pendingCount() async {
    final prefs = await SharedPreferences.getInstance();
    return (prefs.getStringList(_kPending) ?? <String>[]).length;
  }

  /// Tries to deliver every queued alert. Called automatically on a timer.
  Future<void> retryPending() async {
    if (_retrying || !isConfigured) return;
    _retrying = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      final list = prefs.getStringList(_kPending) ?? <String>[];
      if (list.isEmpty) return;

      final remaining = <String>[];
      for (final item in list) {
        final data = jsonDecode(item) as Map<String, dynamic>;
        final queuedAt = DateTime.tryParse(data['queuedAt'] as String? ?? '');
        final lateNote = queuedAt == null
            ? ''
            : '\n(Delayed: phone had no internet since ${_hhmm(queuedAt)}.)';
        final outcome = await _post('${data['text']}$lateNote');
        if (outcome == _PostOutcome.ok) {
          onLog('Queued alert delivered');
        } else if (outcome == _PostOutcome.networkError) {
          remaining.add(item); // still offline, keep it
        }
        // rejected: drop it, retrying forever would never succeed
      }
      await prefs.setStringList(_kPending, remaining);
    } finally {
      _retrying = false;
    }
  }

  static String _hhmm(DateTime t) =>
      '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

  void dispose() => _retryTimer?.cancel();
}

enum _PostOutcome { ok, rejected, networkError }
