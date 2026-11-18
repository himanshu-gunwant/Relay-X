import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

class ConfigState {
  final String relayUrl;
  final String apiKey;
  final String daemonExecutablePath;
  final String username;
  final String macAddress;
  final String wolBroadcastIp;
  final bool isConfigured;

  ConfigState({
    this.relayUrl = '',
    this.apiKey = '',
    this.daemonExecutablePath = '',
    this.username = '',
    this.macAddress = '',
    this.wolBroadcastIp = '',
    this.isConfigured = false,
  });

  ConfigState copyWith({
    String? relayUrl,
    String? apiKey,
    String? daemonExecutablePath,
    String? username,
    String? macAddress,
    String? wolBroadcastIp,
    bool? isConfigured,
  }) {
    return ConfigState(
      relayUrl: relayUrl ?? this.relayUrl,
      apiKey: apiKey ?? this.apiKey,
      daemonExecutablePath: daemonExecutablePath ?? this.daemonExecutablePath,
      username: username ?? this.username,
      macAddress: macAddress ?? this.macAddress,
      wolBroadcastIp: wolBroadcastIp ?? this.wolBroadcastIp,
      isConfigured: isConfigured ?? this.isConfigured,
    );
  }
}

class ConfigNotifier extends AsyncNotifier<ConfigState> {
  final FlutterSecureStorage _storage = const FlutterSecureStorage();

  @override
  Future<ConfigState> build() async {
    return _loadConfig();
  }

  Future<ConfigState> _loadConfig() async {
    try {
      final relayUrl = await _storage.read(key: 'relayUrl');
      final apiKey = await _storage.read(key: 'apiKey');
      final daemonExecutablePath = await _storage.read(key: 'daemonExecutablePath') ?? '';
      final username = await _storage.read(key: 'username') ?? 'User';
      final macAddress = await _storage.read(key: 'macAddress') ?? '';
      final wolBroadcastIp = await _storage.read(key: 'wolBroadcastIp') ?? '';

      if (relayUrl != null && apiKey != null && relayUrl.isNotEmpty && apiKey.isNotEmpty) {
        return ConfigState(
          relayUrl: relayUrl,
          apiKey: apiKey,
          daemonExecutablePath: daemonExecutablePath,
          username: username,
          macAddress: macAddress,
          wolBroadcastIp: wolBroadcastIp,
          isConfigured: true,
        );
      }
    } catch (e) {
      // Ignore storage errors on load and return unconfigured
    }
    return ConfigState();
  }

  Future<void> saveConfig(
    String relayUrl,
    String apiKey, {
    String? daemonExecutablePath,
    String? username,
    String? macAddress,
    String? wolBroadcastIp,
  }) async {
    state = const AsyncLoading();
    try {
      await _storage.write(key: 'relayUrl', value: relayUrl);
      await _storage.write(key: 'apiKey', value: apiKey);
      if (daemonExecutablePath != null) {
        await _storage.write(key: 'daemonExecutablePath', value: daemonExecutablePath);
      }
      if (username != null) {
        await _storage.write(key: 'username', value: username);
      }
      if (macAddress != null) {
        await _storage.write(key: 'macAddress', value: macAddress);
      }
      if (wolBroadcastIp != null) {
        await _storage.write(key: 'wolBroadcastIp', value: wolBroadcastIp);
      }
      
      final currentDaemonPath = daemonExecutablePath ?? (await _storage.read(key: 'daemonExecutablePath')) ?? '';
      final currentUsername = username ?? (await _storage.read(key: 'username')) ?? 'User';
      final currentMac = macAddress ?? (await _storage.read(key: 'macAddress')) ?? '';
      final currentBroadcastIp = wolBroadcastIp ?? (await _storage.read(key: 'wolBroadcastIp')) ?? '';
      
      state = AsyncData(ConfigState(
        relayUrl: relayUrl,
        apiKey: apiKey,
        daemonExecutablePath: currentDaemonPath,
        username: currentUsername,
        macAddress: currentMac,
        wolBroadcastIp: currentBroadcastIp,
        isConfigured: true,
      ));
    } catch (e, st) {
      state = AsyncError(e, st);
    }
  }

  Future<void> saveMacAddress(String macAddress) async {
    final current = state.value;
    if (current == null) return;
    try {
      await _storage.write(key: 'macAddress', value: macAddress);
      state = AsyncData(current.copyWith(macAddress: macAddress));
    } catch (_) {}
  }

  Future<void> saveWolBroadcastIp(String wolBroadcastIp) async {
    final current = state.value;
    if (current == null) return;
    try {
      await _storage.write(key: 'wolBroadcastIp', value: wolBroadcastIp);
      state = AsyncData(current.copyWith(wolBroadcastIp: wolBroadcastIp));
    } catch (_) {}
  }

  Future<void> clearConfig() async {
    state = const AsyncLoading();
    try {
      await _storage.delete(key: 'relayUrl');
      await _storage.delete(key: 'apiKey');
      await _storage.delete(key: 'daemonExecutablePath');
      await _storage.delete(key: 'username');
      await _storage.delete(key: 'macAddress');
      await _storage.delete(key: 'wolBroadcastIp');
      state = AsyncData(ConfigState());
    } catch (e, st) {
      state = AsyncError(e, st);
    }
  }
}

final configProvider = AsyncNotifierProvider<ConfigNotifier, ConfigState>(() {
  return ConfigNotifier();
});
