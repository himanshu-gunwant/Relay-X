import 'dart:io';
import 'dart:typed_data';

class WakeOnLanService {
  /// Validates whether a given string is a valid 6-byte MAC address.
  static bool isValidMacAddress(String mac) {
    final cleanMac = mac.replaceAll(RegExp(r'[^0-9a-fA-F]'), '');
    return cleanMac.length == 12;
  }

  /// Parses a MAC address string into a 6-byte list.
  /// Throws [FormatException] if MAC address is invalid.
  static Uint8List parseMacAddress(String mac) {
    final cleanMac = mac.replaceAll(RegExp(r'[^0-9a-fA-F]'), '');
    if (cleanMac.length != 12) {
      throw FormatException('Invalid MAC address: $mac (must contain 12 hex digits)');
    }

    final bytes = Uint8List(6);
    for (int i = 0; i < 6; i++) {
      final hexByte = cleanMac.substring(i * 2, (i * 2) + 2);
      bytes[i] = int.parse(hexByte, radix: 16);
    }
    return bytes;
  }

  /// Formats a 12-digit hex string or raw MAC into normalized `AA:BB:CC:DD:EE:FF` format.
  static String formatMacAddress(String mac) {
    try {
      final bytes = parseMacAddress(mac);
      return bytes.map((b) => b.toRadixString(16).padLeft(2, '0').toUpperCase()).join(':');
    } catch (_) {
      return mac;
    }
  }

  /// Builds a 102-byte Magic Packet for Wake-on-LAN:
  /// - 6 bytes of 0xFF
  /// - 16 repetitions of target MAC address (6 bytes * 16 = 96 bytes)
  static Uint8List createMagicPacket(String mac) {
    final macBytes = parseMacAddress(mac);
    final packet = Uint8List(102);

    // First 6 bytes are 0xFF
    for (int i = 0; i < 6; i++) {
      packet[i] = 0xFF;
    }

    // Next 96 bytes are MAC repeated 16 times
    for (int i = 0; i < 16; i++) {
      packet.setRange(6 + (i * 6), 6 + (i * 6) + 6, macBytes);
    }

    return packet;
  }

  /// Derives a subnet broadcast IP from an IP address or URL (e.g., 'http://192.168.1.10:3579' -> '192.168.1.255').
  static String? deriveSubnetBroadcastIp(String hostOrUrl) {
    try {
      final uri = Uri.tryParse(hostOrUrl.contains('://') ? hostOrUrl : 'http://$hostOrUrl');
      final host = uri?.host ?? hostOrUrl;
      final parts = host.split('.');
      if (parts.length == 4 && parts.every((p) => int.tryParse(p) != null)) {
        return '${parts[0]}.${parts[1]}.${parts[2]}.255';
      }
    } catch (_) {}
    return null;
  }

  /// Derives the raw host IP from an IP address or URL (e.g., 'http://192.168.1.10:3579' -> '192.168.1.10').
  static String? deriveHostIp(String hostOrUrl) {
    try {
      final uri = Uri.tryParse(hostOrUrl.contains('://') ? hostOrUrl : 'http://$hostOrUrl');
      final host = uri?.host ?? hostOrUrl;
      final parts = host.split('.');
      if (parts.length == 4 && parts.every((p) => int.tryParse(p) != null)) {
        return host;
      }
    } catch (_) {}
    return null;
  }

  /// Sends WoL Magic Packets over UDP broadcast/unicast to target IPs/subnets across routers.
  static Future<bool> sendWakeOnLan(
    String macAddress, {
    List<String> targetIps = const ['255.255.255.255'],
    List<int> ports = const [9, 7],
  }) async {
    try {
      final packet = createMagicPacket(macAddress);
      final socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
      socket.broadcastEnabled = true;

      // Unique non-empty IPs
      final uniqueTargets = targetIps.map((e) => e.trim()).where((e) => e.isNotEmpty).toSet();

      for (final targetHost in uniqueTargets) {
        try {
          final addresses = await InternetAddress.lookup(targetHost);
          for (final address in addresses) {
            for (final port in ports) {
              socket.send(packet, address, port);
            }
          }
        } catch (_) {
          // Fallback if lookup fails for literal IP
          try {
            final address = InternetAddress(targetHost);
            for (final port in ports) {
              socket.send(packet, address, port);
            }
          } catch (_) {}
        }
      }

      await Future.delayed(const Duration(milliseconds: 100));
      socket.close();
      return true;
    } catch (e) {
      return false;
    }
  }
}
