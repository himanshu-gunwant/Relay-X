import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/hardware_telemetry.dart';
import '../services/ws_client.dart';

final hardwareTelemetryProvider = StreamProvider<HardwareTelemetry>((ref) {
  final wsClient = ref.watch(wsClientProvider);
  return wsClient.hardwareStream.map((data) => HardwareTelemetry.fromJson(data));
});
