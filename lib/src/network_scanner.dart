import 'dart:async';
import 'dart:io';

class NetworkAddress {
  NetworkAddress(this.ip, this.exists);

  bool exists;
  String ip;
}

class NetworkScanner {
  NetworkScanner({
    required this.subnet,
    required this.port,
    this.timeout = const Duration(seconds: 5),
  }) : assert(port > 0 && port < 65535, 'Port must be between 1 and 65535') {
    if (!_isValidSubnet(subnet)) {
      throw ArgumentError('Invalid subnet format. Expected format: xxx.xxx.xxx');
    }
  }

  final String subnet;
  final int port;
  final Duration timeout;
  static const _errorCodes = [13, 49, 61, 64, 65, 101, 104, 111, 113];

  bool _isValidSubnet(String subnet) {
    final parts = subnet.split('.');
    if (parts.length != 3) return false;

    for (final part in parts) {
      final number = int.tryParse(part);
      if (number == null || number < 0 || number > 255) return false;
    }

    return true;
  }

  Future<Socket> _ping(String host) async {
    try {
      return await Socket.connect(host, port, timeout: timeout);
    } catch (e) {
      rethrow;
    }
  }

  /// Parallel network discovery
  Stream<NetworkAddress> discover() {
    final controller = StreamController<NetworkAddress>();
    final List<Future<void>> scanFutures = [];

    void scanAddress(int i) {
      final host = '$subnet.$i';
      scanFutures.add(_ping(host).then((socket) {
        socket.destroy();
        controller.add(NetworkAddress(host, true));
      }).catchError((e) {
        if (e is SocketException) {
          if (e.osError == null || _errorCodes.contains(e.osError?.errorCode)) {
            controller.add(NetworkAddress(host, false));
          } else {
            print('Error scanning $host: ${e.message}');
            controller.add(NetworkAddress(host, false));
          }
        } else {
          print('Unknown error scanning $host: $e');
          controller.add(NetworkAddress(host, false));
        }
      }));
    }

    // Start all scans immediately
    for (int i = 1; i < 256; i++) {
      scanAddress(i);
    }

    // Close the controller when all scans are complete
    Future.wait(scanFutures).then((_) {
      controller.close();
    }).catchError((e) {
      print('Error in network scanning: $e');
      controller.close();
    });

    return controller.stream;
  }

  /// Sequential discovery (slower but more reliable)
  Stream<NetworkAddress> discoverSequential({
    Duration? customTimeout,
  }) async* {
    for (int i = 1; i < 256; i++) {
      final host = '$subnet.$i';
      try {
        final Socket s = await Socket.connect(
          host,
          port,
          timeout: customTimeout ?? timeout,
        );
        await s.close();
        yield NetworkAddress(host, true);
      } on SocketException catch (e) {
        if (e.osError == null || _errorCodes.contains(e.osError?.errorCode)) {
          yield NetworkAddress(host, false);
        } else {
          print('Error scanning $host: ${e.message}');
          yield NetworkAddress(host, false);
        }
      } catch (e) {
        print('Unknown error scanning $host: $e');
        yield NetworkAddress(host, false);
      }
    }
  }
}