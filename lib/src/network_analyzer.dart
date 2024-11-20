/*
 * ping_discover_network
 * Created by Andrey Ushakov
 * 
 * See LICENSE for distribution and usage details.
 */

import 'dart:async';
import 'dart:io';

// ignore_for_file: avoid_classes_with_only_static_members

/// [NetworkAnalyzer] class returns instances of [NetworkAddress].
///
/// Found ip addresses will have [exists] == true field.
class NetworkAddress {
  NetworkAddress(this.ip, this.exists);

  bool exists;
  String ip;
}

/// Pings a given subnet (xxx.xxx.xxx) on a given port using [discover] method.
class NetworkAnalyzer {
  // 13: Connection failed (OS Error: Permission denied)
  // 49: Bind failed (OS Error: Can't assign requested address)
  // 51: Network is unreachable
  // 61: OS Error: Connection refused
  // 64: Connection failed (OS Error: Host is down)
  // 65: No route to host
  // 101: Network is unreachable
  // 110: Connection timed out
  // 111: Connection refused
  // 113: No route to host
  // <empty>: SocketException: Connection timed out
  // 104: Connection reset by peer
  static final _errorCodes = [13, 49, 61, 64, 65, 101, 104, 111, 113];

  /// Validates subnet format
  static bool _isValidSubnet(String subnet) {
    final parts = subnet.split('.');
    if (parts.length != 3) return false;

    for (final part in parts) {
      final number = int.tryParse(part);
      if (number == null || number < 0 || number > 255) return false;
    }

    return true;
  }

  /// Improved ping function with better error handling
  static Future<Socket> _ping(String host, int port, Duration timeout) async {
    try {
      final socket = await Socket.connect(host, port, timeout: timeout);
      return socket;
    } on SocketException catch (e) {
      if (e.osError != null && !_errorCodes.contains(e.osError!.errorCode)) {
        print('Network scan error for $host: ${e.message} (Error ${e.osError!.errorCode})');
      }
      rethrow;
    } catch (e) {
      print('Unexpected error while scanning $host: $e');
      rethrow;
    }
  }

  /// Sequential discovery (safer but slower)
  static Stream<NetworkAddress> discover(
    String subnet,
    int port, {
    Duration timeout = const Duration(milliseconds: 400),
  }) async* {
    // Validate inputs
    if (port < 1 || port > 65535) {
      throw ArgumentError('Port must be between 1 and 65535');
    }

    if (!_isValidSubnet(subnet)) {
      throw ArgumentError('Invalid subnet format. Expected format: xxx.xxx.xxx');
    }

    for (int i = 1; i < 256; ++i) {
      final host = '$subnet.$i';
      try {
        final Socket s = await Socket.connect(host, port, timeout: timeout).timeout(timeout, onTimeout: () {
          throw SocketException('Connection timeout');
        });
        await s.close(); // Properly close the socket
        yield NetworkAddress(host, true);
      } on SocketException catch (e) {
        if (e.osError == null || _errorCodes.contains(e.osError!.errorCode)) {
          yield NetworkAddress(host, false);
        } else {
          print('Network error scanning $host: ${e.message}');
          yield NetworkAddress(host, false);
        }
      } catch (e) {
        print('Error scanning $host: $e');
        yield NetworkAddress(host, false);
      }
    }
  }

  /// Parallel discovery (faster but more resource-intensive)
  static Stream<NetworkAddress> discover2(
    String subnet,
    int port, {
    Duration timeout = const Duration(seconds: 5),
  }) {
    // Validate inputs
    if (port < 1 || port > 65535) {
      throw ArgumentError('Port must be between 1 and 65535');
    }

    if (!_isValidSubnet(subnet)) {
      throw ArgumentError('Invalid subnet format. Expected format: xxx.xxx.xxx');
    }

    final out = StreamController<NetworkAddress>();
    final futures = <Future<Socket>>[];
    var activeScans = 0;
    const maxConcurrentScans = 50; // Limit concurrent connections

    void startScan(String host) {
      activeScans++;
      final Future<Socket> f = _ping(host, port, timeout);
      futures.add(f);

      f.then((socket) async {
        try {
          await socket.close(); // Properly close the socket
          out.sink.add(NetworkAddress(host, true));
        } catch (e) {
          print('Error closing socket for $host: $e');
        } finally {
          activeScans--;
        }
      }).catchError((dynamic e) {
        activeScans--;
        if (e is SocketException) {
          if (e.osError == null || _errorCodes.contains(e.osError!.errorCode)) {
            out.sink.add(NetworkAddress(host, false));
          } else {
            print('Socket error scanning $host: ${e.message}');
            out.sink.add(NetworkAddress(host, false));
          }
        } else {
          print('Unexpected error scanning $host: $e');
          out.sink.add(NetworkAddress(host, false));
        }
      });
    }

    // Scan in batches to prevent overwhelming the system
    int i = 1;
    Timer? timer;

    void scheduleNextScan() {
      if (i >= 256) {
        timer?.cancel();
        return;
      }

      if (activeScans < maxConcurrentScans) {
        final host = '$subnet.$i';
        startScan(host);
        i++;
      }
    }

    timer = Timer.periodic(Duration(milliseconds: 50), (_) {
      scheduleNextScan();
    });

    // Close stream when all scans are complete
    Future.wait<Socket>(futures).then<void>((sockets) async {
      timer?.cancel();
      await Future.delayed(Duration(milliseconds: 100)); // Small delay to ensure all callbacks complete
      await out.close();
    }).catchError((dynamic e) async {
      timer?.cancel();
      print('Error during network scan: $e');
      await out.close();
    });

    return out.stream;
  }
}