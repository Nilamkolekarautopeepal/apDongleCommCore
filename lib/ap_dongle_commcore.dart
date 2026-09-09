import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:ap_dongle_commcore/enums/connectivity.dart';
import 'package:ap_dongle_commcore/enums/platform.dart';
import 'package:ap_dongle_commcore/helper/crc16_ccitt_kermit.dart';
import 'package:ap_dongle_commcore/helper/responseArrayDecoding.dart';
import 'package:ap_dongle_commcore/iDongleHandlers.dart';
import 'package:ap_dongle_commcore/icanCommands.dart';
import 'package:ap_dongle_commcore/iwifiUsbHandlers.dart';
import 'package:ap_dongle_commcore/model/responseArrayStatusModel.dart';
import 'package:async/async.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:convert/convert.dart';
import 'package:flutter_libserialport/flutter_libserialport.dart';
import 'package:http/http.dart' as http;


/// ---------------- MAIN CLASS ----------------
class DongleCommWin implements ICANCommands, IWIfIUSBHandler, IDongleHandler {
  dynamic responseStructure;
  SerialPort? port;
  int? protocol;
  // Platform specific
  dynamic bluetoothSocket;
  dynamic serialInputOutputManager;
  dynamic usbPort;

  Socket? tcpClient;
  Stream? stream;

  PlatformType platform = PlatformType.none;
  ConnectivityType connectivity = ConnectivityType.none;

  bool isChannel = false;
  String? channelId;
  bool isObdCharger = false;
  String? filePath;

  bool isCanSimulate = false;

  HttpClient? httpClient;

  // Ensure this is inside your class
  DongleCommWin({this.port, this.protocol, this.channelId});

  // ---------------- USB BASIC ----------------
  DongleCommWin.usb(
    this.serialInputOutputManager,
    this.usbPort,
    this.port,
    this.protocol,
    this.channelId,
  ) {
    print("Inside DongleComm USB");
  }

  /// ---------------- INITIALIZE PLATFORM ----------------
  initializePlatform(
    PlatformType platform,
    ConnectivityType connectivityType,
    bool isCanSimulate,
  ) {
    this.platform = platform;
    this.connectivity = connectivityType; // ← no more conflict
    this.isCanSimulate = isCanSimulate;

    httpClient = HttpClient()
      ..badCertificateCallback =
          ((X509Certificate cert, String host, int port) => true)
      ..connectionTimeout = const Duration(seconds: 2);
  }

  /// ---------------- BLUETOOTH (INT PROTOCOL) ----------------
  DongleCommWin.bluetooth(this.bluetoothSocket, int protocolVersion) {
    print("Inside BluetoothSocket CTOR");
  }

  /// ---------------- BLUETOOTH (STRING PROTOCOL) ----------------
  DongleCommWin.bluetoothWithString(this.bluetoothSocket, String protocolStr) {
    print("Inside BluetoothSocket CTOR");
  }

  /// ---------------- TCP ----------------
  DongleCommWin.tcp(
    this.tcpClient,
    this.stream,
    int protocolVersion,
    String filePath,
  ) {
    print("Inside ELM327 TcpClient CTOR");
    isChannel = false;
    this.filePath = filePath;
  }

  DongleCommWin.tcpWithChannel(
    this.tcpClient,
    this.stream,
    int protocolVersion,
    String channelId,
    String filePath,
  ) {
    print("Inside DongleComm TcpClient CTOR with channels");
    isChannel = true;
    this.channelId = channelId;
    this.filePath = filePath;
    _initWifiQueue(); // ← ADD THIS
  }

  /// ---------------- USB WITH PROTOCOL ----------------
  DongleCommWin.usbWithProtocol(
    this.serialInputOutputManager,
    this.usbPort,
    int protocolVersion,
  ) {
    print("Inside ELM327 SimpleTcpClient CTOR");
    isChannel = false;
    isObdCharger = false;
  }

  /// ---------------- USB WITH CHANNEL ----------------
  DongleCommWin.usbWithChannel(
    this.serialInputOutputManager,
    this.usbPort,
    int protocolVersion,
    String channelId,
  ) {
    print("Inside ELM327 SimpleTcpClient CTOR");
    isChannel = true;
    this.channelId = channelId;
    isObdCharger = false;
  }

  Future<Uint8List?> readData() async {
    print("------Read Again Data------");

    try {
      // WINDOWS + USB
      if (connectivity == ConnectivityType.usb) {
        if (isObdCharger ||
            serialInputOutputManager?.isOpen == true ||
            (port != null && port!.isOpen)) {
          var resp = await getUSBCommand();
          return resp != null ? Uint8List.fromList(resp) : null;
        }
      }

      // WINDOWS + WIFI (TCP)
      if (connectivity == ConnectivityType.wiFi) {
        // getWifiCommand now returns Uint8List
        return await getWifiCommand();
      }
    } catch (e) {
      print("Error in readData: $e");
    }

    print("------END Read Again Data------");
    return null;
  }

  Future<dynamic> sendCommand(String randomCommand) async {
    print("------SendCommand------");

    dynamic response;

    String command = randomCommand;

    List<int> sendBytes = hexStringToByteArray(command);

    response = await sendCommandBytes(sendBytes, (obj) {
      writeConsole(command, obj);
    });

    return response;
  }

  String byteArrayToString1(List<int> bytes) {
    return hex.encode(bytes).toUpperCase();
  }

  void Function()? raiseCustomEvent;

  Future<dynamic> sendCommandBytes(
    List<int> command,
    Function(String)? onDataReceived,
  ) async {
    try {
      print("--- [DEBUG] sendCommandBytes Start ---");
      String commandHex = byteArrayToString1(Uint8List.fromList(command));

      if (connectivity == ConnectivityType.usb) {
        print("--- [DEBUG] Connectivity: USB ---");
        print("--- [DEBUG] Raw Hex to Send: $commandHex");

        if (port != null && port!.isOpen) {
          print("--- [DEBUG] Windows Port ${port!.name} is OPEN ---");

          saveLog("${DateTime.now()} Command USB Send = $commandHex\n");

          final bytesToWrite = Uint8List.fromList(command);

          // DO NOT FLUSH HERE
          // port!.flush(SerialPortBuffer.both);

          print("--- [DEBUG] Executing port.write()... ---");

          final bytesWritten = port!.write(bytesToWrite);

          // FULL WRITE CHECK
          if (bytesWritten != bytesToWrite.length) {
            print("--- [ERROR] Partial USB Write ---");
            print("Expected: ${bytesToWrite.length}");
            print("Actual  : $bytesWritten");

            return null;
          }

          print(
            "--- [DEBUG] SUCCESS: Written $bytesWritten/${bytesToWrite.length} bytes ---",
          );

          // More delay for ECU flash response
          await Future.delayed(const Duration(milliseconds: 5));

          print("--- [DEBUG] Calling getUSBCommand()... ---");

          var response = await getUSBCommand();

          if (response != null) {
            print(
              "--- [DEBUG] RESPONSE RECEIVED: ${byteArrayToString(Uint8List.fromList(response))} ---",
            );

            return response;
          }

          print("--- [DEBUG] WARNING: No USB Response ---");

          return null;
        }

        print("--- [DEBUG] ERROR: USB Port Closed ---");

        return null;
      } else if (connectivity == ConnectivityType.wiFi) {
        print("--- [DEBUG] Connectivity: WIFI/TCP ---");
        print("--- [DEBUG] Raw Hex to Send: $commandHex");

        if (tcpClient != null) {
          print("--- [DEBUG] TCP Socket is CONNECTED ---");

          final bytesToSend = Uint8List.fromList(command);

          // Write to Socket
          tcpClient!.add(bytesToSend);
          await tcpClient!.flush();

          print("--- [DEBUG] SUCCESS: Bytes sent to Socket ---");

          // Optional: Wait for response latency
          await Future.delayed(const Duration(milliseconds: 5));

          print("--- [DEBUG] Calling getWifiCommand()... ---");
          var response = await getWifiCommand();

          // --- ADDED PRINTS START ---
          if (response != null && response.isNotEmpty) {
            print("--- [DEBUG] WIFI RESPONSE RECEIVED (Raw Bytes): $response");
            print(
              "--- [DEBUG] WIFI RESPONSE RECEIVED (Hex): ${byteArrayToString(Uint8List.fromList(response))}",
            );
            print("--- [DEBUG] WIFI RESPONSE LENGTH: ${response.length}");

            // Safety check to prevent: RangeError (length): Invalid value: Valid value range is empty: 3
            if (response.length < 4) {
              print(
                "--- [DEBUG] WARNING: Response too short to parse MAC ID correctly ---",
              );
            }
          } else {
            print(
              "--- [DEBUG] WARNING: getWifiCommand returned NULL or EMPTY ---",
            );
          }
          // --- ADDED PRINTS END ---

          return response;
        } else {
          print("--- [DEBUG] ERROR: tcpClient is NULL during WiFi send ---");
        }
      }
      // ... rest of the connectivity types (BT/WiFi) ...
    } catch (e) {
      print("--- [DEBUG] EXCEPTION in sendCommandBytes: $e ---");
    }

    print("--- [DEBUG] sendCommandBytes exiting with NULL ---");
    return null;
  }

  Future<dynamic> sendCommandBytes1(
    List<int> command,
    Function(String)? onDataReceived,
  ) async {
    try {
      print("--- [DEBUG] sendCommandBytes Start ---");
      String commandHex = byteArrayToString1(Uint8List.fromList(command));

      if (connectivity == ConnectivityType.usb) {
        print("--- [DEBUG] Connectivity: USB ---");
        print("--- [DEBUG] Raw Hex to Send: $commandHex");

        if (port != null && port!.isOpen) {
          print("--- [DEBUG] Windows Port ${port!.name} is OPEN ---");

          saveLog("${DateTime.now()} Command USB Send = $commandHex\n");

          final bytesToWrite = Uint8List.fromList(command);

          // DO NOT FLUSH HERE
          // port!.flush(SerialPortBuffer.both);

          print("--- [DEBUG] Executing port.write()... ---");

          final bytesWritten = port!.write(bytesToWrite);

          // FULL WRITE CHECK
          if (bytesWritten != bytesToWrite.length) {
            print("--- [ERROR] Partial USB Write ---");
            print("Expected: ${bytesToWrite.length}");
            print("Actual  : $bytesWritten");

            return null;
          }

          print(
            "--- [DEBUG] SUCCESS: Written $bytesWritten/${bytesToWrite.length} bytes ---",
          );

          // More delay for ECU flash response
          await Future.delayed(const Duration(milliseconds: 5));

          print("--- [DEBUG] Calling getUSBCommand()... ---");

          var response = await getUSBCommand();

          if (response != null) {
            print(
              "--- [DEBUG] RESPONSE RECEIVED: ${byteArrayToString(Uint8List.fromList(response))} ---",
            );

            return response;
          }

          print("--- [DEBUG] WARNING: No USB Response ---");

          return null;
        }

        print("--- [DEBUG] ERROR: USB Port Closed ---");

        return null;
      } else if (connectivity == ConnectivityType.wiFi) {
        print("--- [DEBUG] Connectivity: WIFI/TCP ---");
        print("--- [DEBUG] Raw Hex to Send: $commandHex");

        if (tcpClient != null) {
          print("--- [DEBUG] TCP Socket is CONNECTED ---");

          if (_wifiQueue != null) {
            int discarded = 0;
            while (true) {
              final hasNext = await _wifiQueue!.hasNext.timeout(
                const Duration(milliseconds: 20),
                onTimeout: () => false,
              );
              if (!hasNext) break;
              final stale = await _wifiQueue!.next;
              discarded++;
              print(
                "🧹 [sendCommandBytes] Discarding stale WiFi frame before send: "
                "${byteArrayToString(stale)}",
              );
            }
            if (discarded > 0) {
              print(
                "🧹 [sendCommandBytes] Discarded $discarded stale frame(s) before sending new command",
              );
            }
          }

          final bytesToSend = Uint8List.fromList(command);

          // Write to Socket
          tcpClient!.add(bytesToSend);
          await tcpClient!.flush();

          print("--- [DEBUG] SUCCESS: Bytes sent to Socket ---");

          // Optional: Wait for response latency
          await Future.delayed(const Duration(milliseconds: 5));

          print("--- [DEBUG] Calling getWifiCommand()... ---");
          var response = await getWifiCommand();

          // --- ADDED PRINTS START ---
          if (response.isNotEmpty) {
            print("--- [DEBUG] WIFI RESPONSE RECEIVED (Raw Bytes): $response");
            print(
              "--- [DEBUG] WIFI RESPONSE RECEIVED (Hex): ${byteArrayToString(Uint8List.fromList(response))}",
            );
            print("--- [DEBUG] WIFI RESPONSE LENGTH: ${response.length}");

            // Safety check to prevent: RangeError (length): Invalid value: Valid value range is empty: 3
            if (response.length < 4) {
              print(
                "--- [DEBUG] WARNING: Response too short to parse MAC ID correctly ---",
              );
            }
          } else {
            print(
              "--- [DEBUG] WARNING: getWifiCommand returned NULL or EMPTY ---",
            );
          }
          // --- ADDED PRINTS END ---

          return response;
        } else {
          print("--- [DEBUG] ERROR: tcpClient is NULL during WiFi send ---");
        }
      }
      // ... rest of the connectivity types (BT/WiFi) ...
    } catch (e) {
      print("--- [DEBUG] EXCEPTION in sendCommandBytes: $e ---");
    }

    print("--- [DEBUG] sendCommandBytes exiting with NULL ---");
    return null;
  }

  Future<bool> checkTcpConnection() async {
    return tcpClient != null;
  }

  void _initWifiQueue() {
    _wifiQueue?.cancel();
    _wifiQueue = StreamQueue<Uint8List>(
      tcpClient!.map((data) => Uint8List.fromList(data)),
    );
  }

  StreamQueue<Uint8List>? _wifiQueue;

  Future<Uint8List> getWifiCommand() async {
    try {
      if (_wifiQueue == null) {
        print("--------- ERROR: WiFi queue not initialized -------");
        return Uint8List(0);
      }

      while (true) {
        print("---------INSIDE READ DATA (Loop)------- ${DateTime.now()}");

        final Uint8List retArray = await _wifiQueue!.next.timeout(
          const Duration(seconds: 10),
          onTimeout: () => Uint8List(0),
        );

        if (retArray.isEmpty) {
          print("--------- READ TIMEOUT OR EMPTY -------");
          return Uint8List(0);
        }

        print("--------- RAW RESPONSE ------- ${byteArrayToString(retArray)}");

        // ✅ NRC 0x78: ECU busy — but real response may be appended in same packet
        if (retArray.length >= 6 &&
            retArray[3] == 0x7F &&
            retArray[5] == 0x78) {
          // NRC 0x78 frame is exactly 8 bytes: [40 03 00 7F 19 78 XX XX]
          const int nrcFrameSize = 8;

          if (retArray.length > nrcFrameSize) {
            // ✅ Real response is appended right after the NRC frame in the same packet
            final Uint8List actualResponse = retArray.sublist(nrcFrameSize);
            print(
              "⚠️ NRC 0x78 detected — actual response appended in same packet",
            );
            print(
              "--------- STRIPPED NRC, ACTUAL DATA ------- ${byteArrayToString(actualResponse)}",
            );
            saveLog(
              "${DateTime.now()} WIFI Receive = ${byteArrayToString(actualResponse)}\n",
            );
            return actualResponse;
          }

          // NRC 0x78 only — wait for the real response in the next packet
          print("⚠️ NRC 0x78: ECU pending, reading again...");
          continue;
        }

        // Normal response
        final BytesBuilder builder = BytesBuilder();
        builder.add(retArray);
        final Uint8List finalBytes = builder.takeBytes();

        print(
          "--------- FINAL DATA RESPONSE ------- ${byteArrayToString(finalBytes)}",
        );
        saveLog(
          "${DateTime.now()} WIFI Receive = ${byteArrayToString(finalBytes)}\n",
        );

        return finalBytes;
      }
    } catch (ex) {
      print("--------- ERROR EXCEPTION ------- $ex");
      return Uint8List(0);
    }
  }

  Future<List<int>?> getBTCommand() async {
    try {
      List<int> rbuffer = List.filled(4500, 0);
      List<int> retArray = [];
      int readByte = 0;
      int packetSize = 0;

      print("--------- BT INSIDE READ DATA ------- ${DateTime.now()}");

      // Ensure stream is readable (Flutter handles differently)
      if (bluetoothSocket == null) return null;

      Stream<List<int>> inputStream = bluetoothSocket!.inputStream;

      while (true) {
        try {
          List<int> data = await inputStream.first;

          readByte += data.length;

          // Copy into buffer
          for (int i = 0; i < data.length; i++) {
            if ((readByte - data.length + i) < rbuffer.length) {
              rbuffer[readByte - data.length + i] = data[i];
            }
          }

          // print(
          //   "--------- Response Byte $readByte ------- ${byteArrayToString(retArray)} -- READ TIME -- ${DateTime.now()}",
          // );

          // ---------------- VALIDATION LOGIC ----------------
          if (readByte < 2) {
            continue;
          }

          packetSize = ((rbuffer[0] & 0x0f) << 8) + rbuffer[1];

          if (readByte < packetSize + 2) {
            continue;
          }

          break;
        } catch (e) {
          print("BT READ ERROR: $e");
          continue;
        }
      }

      retArray = rbuffer.sublist(0, readByte);

      print("--------- BT READ DATA RESPONSE ------- ${byteArrayToString}");

      saveLog("${DateTime.now()} BT Receive = ${byteArrayToString}\n");

      return retArray;
    } catch (e) {
      print("BT EXCEPTION: $e");
      return null;
    }
  }

  Future<List<int>?> getUSBCommand() async {
    try {
      print("--------- USB READ START ------- ${DateTime.now()}");

      // 🔍 CHECK 1: Is the port even valid?
      if (port == null) {
        print("❌ DEBUG: 'port' object is NULL");
      } else if (!port!.isOpen) {
        print("❌ DEBUG: Port is NOT OPEN. Status: ${port!.isOpen}");
      }

      // ── WINDOWS: read via SerialPort.read() directly ─────────────
      if (port != null && port!.isOpen) {
        List<int> receivedBytes = [];
        final deadline = DateTime.now().add(const Duration(seconds: 1));

        print("⏳ DEBUG: Entering Windows Read Loop (5s deadline)...");

        while (DateTime.now().isBefore(deadline)) {
          // Read available bytes (non-blocking)
          final chunk = port!.read(4096, timeout: 5);

          if (chunk != null && chunk.isNotEmpty) {
            receivedBytes.addAll(chunk);
            print(
              "📥 DEBUG: Raw Chunk Received: ${byteArrayToString(Uint8List.fromList(chunk))}",
            );
            print("📊 DEBUG: Total Buffer Size: ${receivedBytes.length}");

            // 🔍 CHECK 2: Is the Header Logic valid?
            if (receivedBytes.length >= 2) {
              int byte0 = receivedBytes[0];
              int byte1 = receivedBytes[1];
              int expectedLen = ((byte0 & 0x0F) << 8) + byte1 + 4;

              print("📦 DEBUG: Header Parsed -> Byte0: $byte0, Byte1: $byte1");
              print(
                "📦 DEBUG: Expected Total: $expectedLen | Currently Have: ${receivedBytes.length}",
              );

              if (receivedBytes.length >= expectedLen) {
                print("✅ DEBUG: Success! Packet complete.");
                break;
              }
            }
          } else {
            // 🔍 CHECK 3: Are we just looping with no data?
            // print("... waiting for data ..."); // Uncomment if you want to see every poll attempt
            await Future.delayed(const Duration(milliseconds: 5));
          }
        }

        if (receivedBytes.isNotEmpty) {
          return Uint8List.fromList(receivedBytes);
        }

        print(
          "⏱️ DEBUG: Windows Loop exited - No bytes ever arrived at hardware buffer.",
        );
        return null;
      }

      // ── ANDROID ─────────────────────────────────
      print("🤖 DEBUG: Attempting Android Read...");
      List<int> rbuffer = List.filled(4096, 0);
      int len = 0;

      if (isObdCharger) {
        print("ℹ️ DEBUG: isObdCharger is TRUE - custom driver logic expected.");
      } else {
        if (usbPort == null) print("❌ DEBUG: Android usbPort is NULL");
        len = await usbPort?.read(rbuffer, 0) ?? 0;
      }

      print("📊 DEBUG: Android Read Length: $len");

      if (len > 0) {
        final retArray = rbuffer.sublist(0, len);
        return retArray;
      }

      print("--------- Could Not Read USB Data -------");
      return null;
    } catch (e) {
      print("💥 DEBUG FATAL ERROR: $e");
      return null;
    }
  }

  Future<List<int>?> getUSBCommand1() async {
    try {
      print("--------- USB READ START ------- ${DateTime.now()}");

      // 🔍 CHECK 1: Is the port even valid?
      if (port == null) {
        print("❌ DEBUG: 'port' object is NULL");
      } else if (!port!.isOpen) {
        print("❌ DEBUG: Port is NOT OPEN. Status: ${port!.isOpen}");
      }

      // ── WINDOWS: read via SerialPort.read() directly ─────────────
      if (port != null && port!.isOpen) {
        List<int> receivedBytes = [];
        // Bumped from 1s to 2s — larger routine-test payloads (e.g. Dosing
        // Quantity Test) can take longer to fully arrive than the old 1s
        // deadline allowed for.
        final deadline = DateTime.now().add(const Duration(seconds: 2));
        int expectedLen = 0;

        print("⏳ DEBUG: Entering Windows Read Loop (2s deadline)...");

        while (DateTime.now().isBefore(deadline)) {
          // Read available bytes (non-blocking)
          final chunk = port!.read(4096, timeout: 5);

          if (chunk.isNotEmpty) {
            receivedBytes.addAll(chunk);
            print(
              "📥 DEBUG: Raw Chunk Received: ${byteArrayToString(Uint8List.fromList(chunk))}",
            );
            print("📊 DEBUG: Total Buffer Size: ${receivedBytes.length}");

            // 🔍 CHECK 2: Is the Header Logic valid?
            if (receivedBytes.length >= 2) {
              int byte0 = receivedBytes[0];
              int byte1 = receivedBytes[1];
              expectedLen = ((byte0 & 0x0F) << 8) + byte1 + 4;

              print("📦 DEBUG: Header Parsed -> Byte0: $byte0, Byte1: $byte1");
              print(
                "📦 DEBUG: Expected Total: $expectedLen | Currently Have: ${receivedBytes.length}",
              );

              if (receivedBytes.length >= expectedLen) {
                print("✅ DEBUG: Success! Packet complete.");
                break;
              }
            }
          } else {
            // print("... waiting for data ...");
            await Future.delayed(const Duration(milliseconds: 5));
          }
        }

        // ✅ FIX: only return a packet we know is COMPLETE per its own header.
        // Previously this returned whatever partial bytes had arrived by the
        // deadline, even if receivedBytes.length < expectedLen — a truncated
        // frame that the diagnostic library would then reject as
        // GENERALERROR_INVALIDRESPFROMDONGLE (e.g. on Dosing Quantity Test,
        // which has a larger multi-byte payload more likely to straddle the
        // old 1s deadline on a slower USB link).
        if (expectedLen > 0 && receivedBytes.length >= expectedLen) {
          print(
            "✅ DEBUG: Returning complete packet (${receivedBytes.length}/$expectedLen bytes)",
          );
          return Uint8List.fromList(receivedBytes);
        }

        if (receivedBytes.isEmpty) {
          print(
            "⏱️ DEBUG: Windows Loop exited - No bytes ever arrived at hardware buffer.",
          );
        } else {
          print(
            "⏱️ DEBUG: Windows Loop exited with an INCOMPLETE packet — "
            "got ${receivedBytes.length} bytes, expected $expectedLen. "
            "Discarding rather than returning a truncated frame.",
          );
        }
        return null;
      }

      // ── ANDROID ─────────────────────────────────
      print("🤖 DEBUG: Attempting Android Read...");
      List<int> rbuffer = List.filled(4096, 0);
      int len = 0;

      if (isObdCharger) {
        print("ℹ️ DEBUG: isObdCharger is TRUE - custom driver logic expected.");
      } else {
        if (usbPort == null) print("❌ DEBUG: Android usbPort is NULL");
        len = await usbPort?.read(rbuffer, 0) ?? 0;
      }

      print("📊 DEBUG: Android Read Length: $len");

      if (len > 0) {
        final retArray = rbuffer.sublist(0, len);
        return retArray;
      }

      print("--------- Could Not Read USB Data -------");
      return null;
    } catch (e) {
      print("💥 DEBUG FATAL ERROR: $e");
      return null;
    }
  }

  final StreamController<List<String>> _logController =
      StreamController<List<String>>.broadcast();

  Stream<List<String>> get onLog => _logController.stream;

  void saveLog(String command) {
    _logController.add([filePath ?? "", command]);
  }

  void dispose() {
    _logController.close();
  }

  bool usbDisconnect() {
    try {
      if (port != null) {
        try {
          if (port!.isOpen) {
            port!.flush(SerialPortBuffer.both);
            port!.close();
          }
        } finally {
          port!.dispose();
        }
      }
      port = null;
      return true;
    } catch (e) {
      print("USB Disconnect Error: $e");
      return false;
    }
  }

  bool wifiDisconnect() {
    try {
      tcpClient?.destroy(); // or close()
      tcpClient = null;
      return true;
    } catch (e) {
      print("WiFi Disconnect Error: $e");
      return false;
    }
  }

  // Future<ResponseArrayStatusIvn> canIvnRxFrame(String frameId) async {
  //   ResponseArrayStatusIvn frameResponse = ResponseArrayStatusIvn();

  //   try {
  //     // 1. filter frame id - Get command bytes for hardware mask
  //     Uint8List sendBytes = await canSetHardRxHeaderMask(frameId);

  //     // 2. Send Command and await response
  //     var response = await sendCommandBytes(sendBytes, (obj) {
  //       writeConsole(
  //         byteArrayToString(sendBytes),
  //         byteArrayToString(obj as Uint8List),
  //       );
  //     });

  //     Uint8List ecuResponseBytes = response as Uint8List;
  //     String dataStatus = "";
  //     Uint8List? actualDataBytes;

  //     // 3. Check response based on Channel mode
  //     if (isChannel) {
  //       var result = ResponseArrayDecoding.checkResponseIVNwithChannel(
  //         ecuResponseBytes,
  //         sendBytes,
  //         "",
  //       );
  //       actualDataBytes = result['actualData'];
  //       dataStatus = result['status'];
  //     } else {
  //       var result = ResponseArrayDecoding.checkResponseIVN(
  //         ecuResponseBytes,
  //         sendBytes,
  //         "",
  //       );
  //       actualDataBytes = result['actualData'];
  //       dataStatus = result['status'];
  //     }

  //     // 4. Handle READAGAIN logic
  //     if (dataStatus == "READAGAIN") {
  //       while (dataStatus == "READAGAIN") {
  //         var responseReadAgain = await readData();
  //         Uint8List ecuResponseReadBytes = responseReadAgain as Uint8List;

  //         Uint8List? actualReadBytes;
  //         String dataReadStatus = "";

  //         if (isChannel) {
  //           var result = ResponseArrayDecoding.checkResponseWithChannel(
  //             ecuResponseReadBytes,
  //             sendBytes,
  //           );
  //           actualDataBytes = result['actualData'];
  //           dataStatus = result['status'];
  //         } else {
  //           var result = ResponseArrayDecoding.checkResponse(
  //             ecuResponseReadBytes,
  //             sendBytes,
  //           );
  //           actualDataBytes = result['actualData'];
  //           dataStatus = result['status'];
  //         }

  //         dataStatus = dataReadStatus;

  //         frameResponse = ResponseArrayStatusIvn(
  //           ecuResponseStatus: dataReadStatus,
  //           actualFrameBytes: actualReadBytes,
  //         );

  //         print("------EXTRA READ DATA START ------");
  //         if (frameResponse.actualFrameBytes != null) {
  //           print(
  //             "------ECUResponse ------ ${byteArrayToString(ecuResponseReadBytes)}",
  //           );
  //           print(
  //             "------ActualDataBytes ------ ${byteArrayToString(frameResponse.actualFrameBytes!)}",
  //           );
  //         }
  //         print(
  //           "------ECUResponseStatus ------ ${frameResponse.ecuResponseStatus}",
  //         );
  //         print("------EXTRA READ DATA END ------");

  //         if (frameResponse.actualFrameBytes == null) {
  //           print("Command BT ACTUAL RESPONSE = NULL");
  //         } else {
  //           print(
  //             "Command BT ACTUAL RESPONSE = ${byteArrayToString(frameResponse.actualFrameBytes!)}",
  //           );
  //         }
  //       }
  //     } else {
  //       // 5. Standard Response
  //       frameResponse = ResponseArrayStatusIvn(
  //         ecuResponseStatus: dataStatus,
  //         actualFrameBytes: actualDataBytes,
  //       );

  //       if (frameResponse.actualFrameBytes == null) {
  //         print("Command BT ACTUAL RESPONSE = NULL");
  //       } else {
  //         print(
  //           "Command BT ACTUAL RESPONSE = ${byteArrayToString(frameResponse.actualFrameBytes!)}",
  //         );
  //       }
  //     }

  //     return frameResponse;
  //   } catch (e, stacktrace) {
  //     print("Exception in canIvnRxFrame: $e \n $stacktrace");
  //     return ResponseArrayStatusIvn(
  //       ecuResponseStatus: "NULL_ERROR",
  //       actualFrameBytes: null,
  //     );
  //   }
  // }

  Future<Uint8List> canSetHardRxHeaderMask(String rxHdrMsk) async {
    print("------CAN_SetHardRxHeaderMask------");

    String command = "";
    String crc;

    if (isChannel) {
      if (rxHdrMsk.length == 8) {
        command =
            "2005$channelId"
            "20$rxHdrMsk";
        Uint8List bytesCommand = hexStringToByteArray(command);
        // Computing checksum using bytes 3, 4, 5, 6, 7
        int checksum = Crc16CcittKermit.computeChecksum([
          bytesCommand[3],
          bytesCommand[4],
          bytesCommand[5],
          bytesCommand[6],
          bytesCommand[7],
        ]);
        crc = checksum.toRadixString(16);
      } else {
        command =
            "2003$channelId"
            "20$rxHdrMsk";
        Uint8List bytesCommand = hexStringToByteArray(command);
        // Computing checksum using bytes 3, 4, 5
        int checksum = Crc16CcittKermit.computeChecksum([
          bytesCommand[3],
          bytesCommand[4],
          bytesCommand[5],
        ]);
        crc = checksum.toRadixString(16);
      }
    } else {
      if (rxHdrMsk.length == 8) {
        command = "200720$rxHdrMsk";
        Uint8List bytesCommand = hexStringToByteArray(command);
        // Computing checksum using bytes 2, 3, 4, 5, 6
        int checksum = Crc16CcittKermit.computeChecksum([
          bytesCommand[2],
          bytesCommand[3],
          bytesCommand[4],
          bytesCommand[5],
          bytesCommand[6],
        ]);
        crc = checksum.toRadixString(16);
      } else {
        command = "200520$rxHdrMsk";
        Uint8List bytesCommand = hexStringToByteArray(command);
        // Computing checksum using bytes 2, 3, 4
        int checksum = Crc16CcittKermit.computeChecksum([
          bytesCommand[2],
          bytesCommand[3],
          bytesCommand[4],
        ]);
        crc = checksum.toRadixString(16);
      }
    }

    // Ensure CRC is at least 4 hex characters (matching C# "x2" logic for a 16-bit CRC)
    // The C# code checks for length 3 and prepends "0", effectively ensuring length 4.
    if (crc.length == 3) {
      crc = "0$crc";
    } else if (crc.length < 3) {
      crc = crc.padLeft(4, '0');
    }

    Uint8List sendBytes = hexStringToByteArray(command + crc);

    return sendBytes;
  }

  // Future<List<IvnResponseArrayStatus>?> setIvnFrame(
  //   List<String> frameIDC,
  // ) async {
  //   List<IvnResponseArrayStatus> responseList = [];

  //   try {
  //     // iterating through the list of frames
  //     for (var frame in List.from(frameIDC)) {
  //       print("------SET_IVN FRAME------");

  //       String command = "";
  //       String crc = "";

  //       if (isChannel) {
  //         if (frame.length == 8) {
  //           // Format: 20 + Length(05) + ChannelId + ID(20) + Frame
  //           command =
  //               "2005$channelId"
  //               "20$frame";
  //           Uint8List bytesCommand = hexStringToByteArray(command);

  //           // CRC on indices 3, 4, 5, 6, 7
  //           int checksum = Crc16CcittKermit.computeChecksum([
  //             bytesCommand[3],
  //             bytesCommand[4],
  //             bytesCommand[5],
  //             bytesCommand[6],
  //             bytesCommand[7],
  //           ]);
  //           crc = checksum.toRadixString(16).padLeft(4, '0');
  //         } else {
  //           // Format: 20 + Length(03) + ChannelId + ID(20) + Frame
  //           command =
  //               "2003$channelId"
  //               "20$frame";
  //           Uint8List bytesCommand = hexStringToByteArray(command);

  //           // CRC on indices 3, 4, 5
  //           int checksum = Crc16CcittKermit.computeChecksum([
  //             bytesCommand[3],
  //             bytesCommand[4],
  //             bytesCommand[5],
  //           ]);
  //           crc = checksum.toRadixString(16).padLeft(4, '0');
  //         }
  //       } else {
  //         if (frame.length == 8) {
  //           // Format: 20 + Length(07) + ID(20) + Frame
  //           command = "200720$frame";
  //           Uint8List bytesCommand = hexStringToByteArray(command);

  //           // CRC on indices 2, 3, 4, 5, 6
  //           int checksum = Crc16CcittKermit.computeChecksum([
  //             bytesCommand[2],
  //             bytesCommand[3],
  //             bytesCommand[4],
  //             bytesCommand[5],
  //             bytesCommand[6],
  //           ]);
  //           crc = checksum.toRadixString(16).padLeft(4, '0');
  //         } else {
  //           // Format: 20 + Length(05) + ID(20) + Frame
  //           command = "200520$frame";
  //           Uint8List bytesCommand = hexStringToByteArray(command);

  //           // CRC on indices 2, 3, 4
  //           int checksum = Crc16CcittKermit.computeChecksum([
  //             bytesCommand[2],
  //             bytesCommand[3],
  //             bytesCommand[4],
  //           ]);
  //           crc = checksum.toRadixString(16).padLeft(4, '0');
  //         }
  //       }

  //       Uint8List sendBytes = hexStringToByteArray(command + crc);

  //       // Sending command and awaiting response
  //       var response = await sendCommandBytes(sendBytes, (obj) {
  //         writeConsole(command, byteArrayToString(obj as Uint8List));
  //       });

  //       Uint8List ecuResponseBytes = response as Uint8List;
  //       Uint8List actualDataBytes;
  //       String dataStatus = "";

  //       // Decoding based on channel mode
  //       if (isChannel) {
  //         var result = ResponseArrayDecoding.checkResponseIVNwithChannel(
  //           ecuResponseBytes,
  //           sendBytes,
  //           "",
  //         );
  //         actualDataBytes = result['actualData'];
  //         dataStatus = result['status'];
  //       } else {
  //         var result = ResponseArrayDecoding.checkResponseIVN(
  //           ecuResponseBytes,
  //           sendBytes,
  //           "",
  //         );
  //         actualDataBytes = result['actualData'];
  //         dataStatus = result['status'];
  //       }

  //       // Handle READAGAIN logic
  //       if (dataStatus == "READAGAIN") {
  //         while (dataStatus == "READAGAIN") {
  //           var responseReadAgain = await readData();
  //           Uint8List ecuResponseReadBytes = responseReadAgain as Uint8List;

  //           // Perform the check
  //           var retryResult = ResponseArrayDecoding.checkResponse(
  //             ecuResponseReadBytes,
  //             sendBytes,
  //           );

  //           // 1. Extract status (Cast to String? then fallback to empty string)
  //           String dataReadStatus = (retryResult['status'] as String?) ?? "";

  //           // 2. Extract actual bytes (Cast to Uint8List?)
  //           Uint8List? actualReadBytes =
  //               retryResult['actualData'] as Uint8List?;

  //           // 3. Update the loop controller
  //           dataStatus = dataReadStatus;

  //           var statusObj = IvnResponseArrayStatus(
  //             frame: frame,
  //             ecuResponse: ecuResponseReadBytes,
  //             ecuResponseStatus: dataReadStatus,
  //             actualDataBytes: actualReadBytes,
  //           );

  //           responseList.add(statusObj);
  //           // ... logging ...
  //         }
  //       } else {
  //         var statusObj = IvnResponseArrayStatus(
  //           frame: frame,
  //           ecuResponse: ecuResponseBytes,
  //           ecuResponseStatus: dataStatus,
  //           actualDataBytes: actualDataBytes,
  //         );

  //         responseList.add(statusObj);
  //         print(
  //           "Command BT ACTUAL RESPONSE = ${statusObj.actualDataBytes == null ? "NULL" : byteArrayToString(statusObj.actualDataBytes!)}",
  //         );
  //       }
  //     }

  //     return responseList;
  //   } catch (e) {
  //     print("Error in setIvnFrame: $e");
  //     return null;
  //   }
  // }

  Uint8List hexToBytes(String input) {
    // Create a list with half the length of the string
    final result = Uint8List(input.length ~/ 2);

    for (var i = 0; i < result.length; i++) {
      // Substring takes start and end index (exclusive)
      // radix: 16 tells Dart to parse the string as Hexadecimal
      result[i] = int.parse(input.substring(2 * i, 2 * i + 2), radix: 16);
    }

    return result;
  }

  void writeConsole(String input, String output) {
    print(
      "Command = $input\nOutput = $output",
      // This acts as your DebugTag for filtering in the console
    );
  }

  Uint8List hexStringToByteArray(String hex) {
    // Remove spaces
    String processedHex = hex.replaceAll(" ", "");

    // Handle odd-length strings by prepending a '0'
    if (processedHex.length % 2 != 0) {
      processedHex = "0$processedHex";
    }

    int numberChars = processedHex.length;
    Uint8List bytes = Uint8List(numberChars ~/ 2);

    for (int i = 0; i < numberChars; i += 2) {
      // substring(start, end) where end is exclusive
      String hexPair = processedHex.substring(i, i + 2);
      bytes[i ~/ 2] = int.parse(hexPair, radix: 16);
    }

    return bytes;
  }

  String byteArrayToString(Uint8List ba) {
    // map each byte to a hex string, padding with a leading zero if necessary
    return ba
        .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
        .join('')
        .toUpperCase();
  }

  dynamic wifiGetDevices() {
    throw UnimplementedError("wifiGetDevices is not yet implemented.");
  }

  dynamic wifiWriteSsidPw() {
    throw UnimplementedError("wifiWriteSsidPw is not yet implemented.");
  }

  dynamic wifiConnectStation() {
    throw UnimplementedError("wifiConnectStation is not yet implemented.");
  }

  Future<dynamic> securityAccess() async {
    print("------SecurityAccess------");
    saveLog("------SecurityAccess------\n");

    String command = "";

    if (isChannel) {
      // String interpolation for ChannelId
      command = "500A${channelId}4731303075776C6B7061FAC2";
    } else {
      command = "500C47568AFE56214E238000FFC3";
    }

    // Convert hex string to Uint8List (byte array)
    Uint8List bytesCommand = hexStringToByteArray(command);

    // Send the command and await the response
    // Assuming sendCommand is defined to accept the callback as the second argument
    var response = await sendCommandBytes(bytesCommand, (obj) {
      writeConsole(command, obj);
    });

    return response;
  }

  Future<dynamic> dongleReset() async {
    print("------Inside Dongle_Reset------");

    String command = "";
    String crc = "";

    if (isChannel) {
      command = "2001${channelId}01";
      Uint8List bytesCommand = hexStringToByteArray(command);

      // Computing checksum using byte index 3
      int checksum = Crc16CcittKermit.computeChecksum([bytesCommand[3]]);
      crc = checksum.toRadixString(16);
    } else {
      command = "200301";
      Uint8List bytesCommand = hexStringToByteArray(command);

      // Computing checksum using byte index 2
      int checksum = Crc16CcittKermit.computeChecksum([bytesCommand[2]]);
      crc = checksum.toRadixString(16);
    }

    // Padding CRC logic
    if (crc.length == 3) {
      crc = "0$crc";
    } else if (crc.length < 3) {
      // Standard safety to ensure at least a 2-byte hex string (4 characters)
      // depending on your CRC implementation requirements
      crc = crc.padLeft(4, '0');
    }

    Uint8List sendBytes = hexStringToByteArray(command + crc);

    // Send command and handle the callback conversion from bytes to string
    var response = await sendCommandBytes(sendBytes, (obj) {
      // ignore: unnecessary_null_comparison
      String output = byteArrayToString(obj as Uint8List);
      writeConsole(command, output);
    });

    return response;
  }

  Protocol? get currentProtocol {
    if (protocol == null) return null;
    if (protocol! < 0 || protocol! >= Protocol.values.length) {
      print(
        "⚠️ [currentProtocol] protocol value $protocol out of range (max ${Protocol.values.length - 1})",
      );
      return null;
    }
    return Protocol.values[protocol!];
  }

  Future<dynamic> dongleSetProtocol(int protocolVersion) async {
    print("------Dongle_SetProtocol------");
    saveLog("------Dongle_SetProtocol------\n");

    protocol = protocolVersion;

    String protocolHex = protocolVersion
        .toRadixString(16)
        .padLeft(2, '0')
        .toUpperCase();

    String command = "";
    String crc = "";

    if (isChannel) {
      // 🔥 FIX: Added '02' sub-command ID to match the expected protocol command structure
      // Structure: 20 (Hdr) + 02 (Len) + Channel + 02 (SetProt ID) + ProtocolHex
      command =
          "2002$channelId"
          "02$protocolHex";
      Uint8List bytesCommand = hexStringToByteArray(command);

      // ✅ Defensive Check: Ensure we have enough bytes before accessing index 3 and 4
      if (bytesCommand.length >= 5) {
        int checksum = Crc16CcittKermit.computeChecksum([
          bytesCommand[3],
          bytesCommand[4],
        ]);
        crc = checksum.toRadixString(16).padLeft(4, '0');
      } else {
        print(
          "❌ [dongleSetProtocol] Error: Channel command too short (${bytesCommand.length} bytes)",
        );
        return null;
      }
    } else {
      // Structure: 20 (Hdr) + 04 (Len) + 02 (SetProt ID) + ProtocolHex
      command = "200402$protocolHex";
      Uint8List bytesCommand = hexStringToByteArray(command);

      // ✅ Defensive Check: Ensure we have enough bytes for index 2 and 3
      if (bytesCommand.length >= 4) {
        int checksum = Crc16CcittKermit.computeChecksum([
          bytesCommand[2],
          bytesCommand[3],
        ]);
        crc = checksum.toRadixString(16).padLeft(4, '0');
      } else {
        print(
          "❌ [dongleSetProtocol] Error: Standard command too short (${bytesCommand.length} bytes)",
        );
        return null;
      }
    }

    // Ensure CRC is always 4 characters for hexStringToByteArray to work properly
    crc = crc.toUpperCase().padLeft(4, '0');

    Uint8List sendBytes = hexStringToByteArray(command + crc);

    var response = await sendCommandBytes(sendBytes, (String obj) {
      // obj is now a String, so writeConsole works directly
      writeConsole(command, obj);
    });

    return response;
  }

  Future<dynamic> dongleGetProtocol() async {
    print("------Dongle_GetProtocol------");

    String command = "";
    String crc = "";

    if (isChannel) {
      command = "2001${channelId}03";
      Uint8List bytesCommand = hexStringToByteArray(command);

      // Computing checksum using byte at index 3
      int checksum = Crc16CcittKermit.computeChecksum([bytesCommand[3]]);
      crc = checksum.toRadixString(16);
    } else {
      command = "200303";
      Uint8List bytesCommand = hexStringToByteArray(command);

      // Computing checksum using byte at index 2
      int checksum = Crc16CcittKermit.computeChecksum([bytesCommand[2]]);
      crc = checksum.toRadixString(16);
    }

    // Padding CRC logic
    if (crc.length == 3) {
      crc = "0$crc";
    } else if (crc.length < 3) {
      crc = crc.padLeft(4, '0');
    }

    Uint8List sendBytes = hexStringToByteArray(command + crc);

    // Send command and handle the callback with print logic
    var response = await sendCommandBytes(sendBytes, (obj) {
      // ignore: unnecessary_null_comparison
      String output = byteArrayToString(obj as Uint8List);
      writeConsole(command, output);
    });

    return response;
  }

  Future<dynamic> dongleGetFirmwareVersion() async {
    print("------Dongle_GetFimrwareVersion------");

    String command = "";
    String crc = "";

    if (isChannel) {
      command =
          "2001$channelId"
          "14";
      Uint8List bytesCommand = hexStringToByteArray(command);

      // Computing checksum using byte at index 3
      int checksum = Crc16CcittKermit.computeChecksum([bytesCommand[3]]);
      crc = checksum.toRadixString(16);
    } else {
      command = "200314";
      Uint8List bytesCommand = hexStringToByteArray(command);

      // Computing checksum using byte at index 2
      int checksum = Crc16CcittKermit.computeChecksum([bytesCommand[2]]);
      crc = checksum.toRadixString(16);
    }

    // Padding CRC to 4 hex characters (16-bit)
    if (crc.length == 3) {
      crc = "0$crc";
    } else if (crc.length < 3) {
      crc = crc.padLeft(4, '0');
    }

    Uint8List sendBytes = hexStringToByteArray(command + crc);

    // Using sendCommandBytes and updating the callback to handle byte-to-string conversion
    var response = await sendCommandBytes(sendBytes, (obj) {
      // ignore: unnecessary_null_comparison
      String output = byteArrayToString(obj as Uint8List);
      writeConsole(command, output);
    });

    return response;
  }

  int readByte = 0;

  Future<Object?> canClearSocket() async {
    if (platform == PlatformType.android &&
        ConnectivityType == ConnectivityType.bluetooth) {
      try {
        // In Dart/Flutter, Bluetooth streams are usually handled via Listeners.
        // If using a socket-like stream:

        // Note: Dart's equivalent to IsDataAvailable depends on your specific plugin.
        // This is a logic representation:
        while (bluetoothSocket.inputStream.isDataAvailable) {
          // read_byte = bluetoothSocket.inputStream.readByte();
          readByte = await bluetoothSocket.inputStream.read();
        }

        await bluetoothSocket.inputStream.flush();
      } catch (e) {
        print("Error clearing Bluetooth socket: $e");
      }
    } else if (platform == PlatformType.android &&
        ConnectivityType == ConnectivityType.usb) {
      bool isRead = true;
      Uint8List rBuffer = Uint8List(1024);

      // Using print for logging as per your previous preference
      print("---------Clear Garbage Data-------${DateTime.now()}");

      while (isRead) {
        print("---------Clearing Garbage Data-------${DateTime.now()}");

        // Assuming usbPort.read returns the number of bytes read
        var len = await usbPort.read(rBuffer, timeout: 100);

        print("---------Cleared Garbage Data-------${DateTime.now()}");

        if (len < 1) {
          isRead = false;
        } else {
          // Create a sub-view or copy of the read data
          Uint8List retArray = rBuffer.sublist(0, len);

          print(
            "---------USB READ DATA RESPONSE-------${byteArrayToString(retArray)}",
          );
        }
      }
    }

    return null;
  }

  Future<dynamic> dongleSetFota(String command1) async {
    print("------Start_Fota------");

    // Length calculation: 3 (Header/Control bytes) + command string length
    int length = 3 + command1.length;
    String hexLength = length.toRadixString(16).padLeft(2, '0').toUpperCase();

    // Construct the byte array for CRC calculation
    // vs[0] is the command ID (0x19), followed by the string characters
    Uint8List vs = Uint8List(command1.length + 1);
    vs[0] = 0x19;

    // Fill the rest of the array with the character codes of command1
    List<int> charCodes = command1.codeUnits;
    for (int i = 0; i < charCodes.length; i++) {
      vs[i + 1] = charCodes[i];
    }

    // Compute Checksum
    int checksum = Crc16CcittKermit.computeChecksum(vs);
    String crc = checksum.toRadixString(16);

    // Padding CRC logic
    if (crc.length == 3) {
      crc = "0$crc";
    } else if (crc.length < 3) {
      crc = crc.padLeft(4, '0');
    }

    // Convert the 'vs' byte array back to a hex string to build the final command
    String hexString = byteArrayToString(vs);

    // Final command construction: 20 + Length + HexBody + CRC
    String finalCommandHex = "20$hexLength$hexString$crc";
    Uint8List sendBytes = hexStringToByteArray(finalCommandHex);

    // Sending via sendCommandBytes
    var response = await sendCommandBytes(sendBytes, (obj) {
      // ignore: unnecessary_null_comparison
      String output = byteArrayToString(obj as Uint8List);
      writeConsole(finalCommandHex, output);
    });

    return response;
  }

  Future<dynamic> getWifiMacId() async {
    print("------Start_Get_Mac_Id------");
    saveLog("------Start_Get_Mac_Id------\n");

    String command = "";
    String crc = "";

    if (isChannel) {
      command = "2001${channelId}21";
      Uint8List bytesCommand = hexStringToByteArray(command);

      // Computing checksum using byte index 3
      int checksum = Crc16CcittKermit.computeChecksum([bytesCommand[3]]);
      crc = checksum.toRadixString(16);
    } else {
      command = "200321";
      Uint8List bytesCommand = hexStringToByteArray(command);

      // Computing checksum using byte index 2
      int checksum = Crc16CcittKermit.computeChecksum([bytesCommand[2]]);
      crc = checksum.toRadixString(16);
    }

    // Padding CRC to 4 hex characters
    if (crc.length == 3) {
      crc = "0$crc";
    } else if (crc.length < 3) {
      crc = crc.padLeft(4, '0');
    }

    Uint8List sendBytes = hexStringToByteArray(command + crc);

    // Using sendCommandBytes and updating callback for print and type safety
    var response = await sendCommandBytes(sendBytes, (obj) {
      String output = byteArrayToString(obj as Uint8List);
      writeConsole(command, output);
    });

    return response;
  }

  Future<dynamic> canSetTxHeader(String txHeader) async {
    print("------CAN_SetTxHeader------");
    saveLog("------CAN_SetTxHeader------\n");

    if (txHeader.isEmpty) {
      print("------CAN_SetTxHeader: SKIPPED (empty header)------");
      return null;
    }

    // ✅ FIX: Use currentProtocol (Protocol enum) not protocol (int)
    final Protocol? currentProto = currentProtocol;
    print("🔧 [canSetTxHeader] protocol=$protocol, currentProto=$currentProto");

    if (currentProto == null) {
      print("------CAN_SetTxHeader: SKIPPED (protocol is null)------");
      return null;
    }

    String command = "";
    String crc = "";
    Uint8List? sendBytes;

    bool is11Bit = [
      Protocol.ISO15765_250KB_11BIT_CAN,
      Protocol.ISO15765_500KB_11BIT_CAN,
      Protocol.ISO15765_1MB_11BIT_CAN,
      Protocol.I250KB_11BIT_CAN,
      Protocol.I500KB_11BIT_CAN,
      Protocol.I1MB_11BIT_CAN,
      Protocol.OE_IVN_250KBPS_11BIT_CAN,
      Protocol.OE_IVN_500KBPS_11BIT_CAN,
      Protocol.OE_IVN_1MBPS_11BIT_CAN,
      Protocol.CANOPEN_125KBPS_11BIT_CAN,
      Protocol.CANOPEN_500KBPS_11BIT_CAN,
      Protocol.XMODEM_125KBPS_11BIT_CAN,
      Protocol.XMODEM_500KBPS_11BIT_CAN,
    ].contains(currentProto); // ✅ currentProto not protocol

    bool is29Bit = [
      Protocol.ISO15765_250Kb_29BIT_CAN,
      Protocol.ISO15765_500KB_29BIT_CAN,
      Protocol.ISO15765_1MB_29BIT_CAN,
      Protocol.I250KB_29BIT_CAN,
      Protocol.I500KB_29BIT_CAN,
      Protocol.I1MB_29BIT_CAN,
      Protocol.OE_IVN_250KBPS_29BIT_CAN,
      Protocol.OE_IVN_500KBPS_29BIT_CAN,
      Protocol.OE_IVN_1MBPS_29BIT_CAN,
      Protocol.XMODEM_500KBPS_29BIT_CAN,
      Protocol.XMODEM_125KBPS_29BIT_CAN,
    ].contains(currentProto); // ✅ currentProto not protocol

    print("🔧 [canSetTxHeader] is11Bit=$is11Bit, is29Bit=$is29Bit");

    if (is11Bit) {
      if (isChannel) {
        command = "2003${channelId}04$txHeader";
        Uint8List bytesCommand = hexStringToByteArray(command);
        int checksum = Crc16CcittKermit.computeChecksum([
          bytesCommand[3],
          bytesCommand[4],
          bytesCommand[5],
        ]);
        crc = checksum.toRadixString(16).padLeft(4, '0');
      } else {
        command = "200504$txHeader";
        Uint8List bytesCommand = hexStringToByteArray(command);
        int checksum = Crc16CcittKermit.computeChecksum([
          bytesCommand[2],
          bytesCommand[3],
          bytesCommand[4],
        ]);
        crc = checksum.toRadixString(16).padLeft(4, '0');
      }
    } else if (is29Bit) {
      if (isChannel) {
        command = "2005${channelId}04$txHeader";
        Uint8List bytesCommand = hexStringToByteArray(command);
        int checksum = Crc16CcittKermit.computeChecksum([
          bytesCommand[3],
          bytesCommand[4],
          bytesCommand[5],
          bytesCommand[6],
          bytesCommand[7],
        ]);
        crc = checksum.toRadixString(16).padLeft(4, '0');
      } else {
        command = "200704$txHeader";
        Uint8List bytesCommand = hexStringToByteArray(command);
        int checksum = Crc16CcittKermit.computeChecksum([
          bytesCommand[2],
          bytesCommand[3],
          bytesCommand[4],
          bytesCommand[5],
          bytesCommand[6],
        ]);
        crc = checksum.toRadixString(16).padLeft(4, '0');
      }
    } else {
      print(
        "------CAN_SetTxHeader: SKIPPED (protocol $currentProto not 11bit or 29bit)------",
      );
      return null;
    }

    sendBytes = hexStringToByteArray(command + crc);
    print("🔧 [canSetTxHeader] sending: $command$crc");

    var response = await sendCommandBytes(sendBytes, (obj) {
      String output = byteArrayToString(obj as Uint8List);
      writeConsole(command, output);
    });

    return response;
  }

  Future<dynamic> canSetRxHeaderMask(String rxHdrMsk) async {
    print("------CAN_SetRxHeaderMask------");
    saveLog("------CAN_SetRxHeaderMask------\n");

    if (rxHdrMsk.isEmpty) {
      print("------CAN_SetRxHeaderMask: SKIPPED (empty mask)------");
      return null;
    }

    // ✅ FIX: Use currentProtocol (Protocol enum) not protocol (int)
    final Protocol? currentProto = currentProtocol;
    print(
      "🔧 [canSetRxHeaderMask] protocol=$protocol, currentProto=$currentProto",
    );

    if (currentProto == null) {
      print("------CAN_SetRxHeaderMask: SKIPPED (protocol is null)------");
      return null;
    }

    dynamic response;
    String command = "";
    String crc = "";
    Uint8List? sendBytes;

    bool is11Bit = [
      Protocol.ISO15765_250KB_11BIT_CAN,
      Protocol.ISO15765_500KB_11BIT_CAN,
      Protocol.ISO15765_1MB_11BIT_CAN,
      Protocol.I250KB_11BIT_CAN,
      Protocol.I500KB_11BIT_CAN,
      Protocol.I1MB_11BIT_CAN,
      Protocol.OE_IVN_250KBPS_11BIT_CAN,
      Protocol.OE_IVN_500KBPS_11BIT_CAN,
      Protocol.OE_IVN_1MBPS_11BIT_CAN,
      Protocol.CANOPEN_125KBPS_11BIT_CAN,
      Protocol.CANOPEN_500KBPS_11BIT_CAN,
      Protocol.XMODEM_125KBPS_11BIT_CAN,
      Protocol.XMODEM_500KBPS_11BIT_CAN,
    ].contains(currentProto); // ✅ currentProto not protocol

    bool is29Bit = [
      Protocol.ISO15765_250Kb_29BIT_CAN,
      Protocol.ISO15765_500KB_29BIT_CAN,
      Protocol.ISO15765_1MB_29BIT_CAN,
      Protocol.I250KB_29BIT_CAN,
      Protocol.I500KB_29BIT_CAN,
      Protocol.I1MB_29BIT_CAN,
      Protocol.OE_IVN_250KBPS_29BIT_CAN,
      Protocol.OE_IVN_500KBPS_29BIT_CAN,
      Protocol.OE_IVN_1MBPS_29BIT_CAN,
      Protocol.XMODEM_500KBPS_29BIT_CAN,
      Protocol.XMODEM_125KBPS_29BIT_CAN,
    ].contains(currentProto); // ✅ currentProto not protocol

    print("🔧 [canSetRxHeaderMask] is11Bit=$is11Bit, is29Bit=$is29Bit");

    if (is11Bit) {
      if (isChannel) {
        command = "2003${channelId}06$rxHdrMsk";
        Uint8List bytesCommand = hexStringToByteArray(command);
        int checksum = Crc16CcittKermit.computeChecksum([
          bytesCommand[3],
          bytesCommand[4],
          bytesCommand[5],
        ]);
        crc = checksum.toRadixString(16).padLeft(4, '0');
      } else {
        command = "200506$rxHdrMsk";
        Uint8List bytesCommand = hexStringToByteArray(command);
        int checksum = Crc16CcittKermit.computeChecksum([
          bytesCommand[2],
          bytesCommand[3],
          bytesCommand[4],
        ]);
        crc = checksum.toRadixString(16).padLeft(4, '0');
      }
    } else if (is29Bit) {
      if (isChannel) {
        command = "2005${channelId}06$rxHdrMsk";
        Uint8List bytesCommand = hexStringToByteArray(command);
        int checksum = Crc16CcittKermit.computeChecksum([
          bytesCommand[3],
          bytesCommand[4],
          bytesCommand[5],
          bytesCommand[6],
          bytesCommand[7],
        ]);
        crc = checksum.toRadixString(16).padLeft(4, '0');
      } else {
        command = "200706$rxHdrMsk";
        Uint8List bytesCommand = hexStringToByteArray(command);
        int checksum = Crc16CcittKermit.computeChecksum([
          bytesCommand[2],
          bytesCommand[3],
          bytesCommand[4],
          bytesCommand[5],
          bytesCommand[6],
        ]);
        crc = checksum.toRadixString(16).padLeft(4, '0');
      }
    } else {
      print(
        "------CAN_SetRxHeaderMask: SKIPPED (protocol $currentProto not 11bit or 29bit)------",
      );
      return null;
    }

    print("🔧 [canSetRxHeaderMask] sending: $command$crc");
    sendBytes = hexStringToByteArray(command + crc.toUpperCase());

    response = await sendCommandBytes(sendBytes, (obj) {
      String output = byteArrayToString(obj as Uint8List);
      writeConsole(command, output);
    });

    return response;
  }

  Future<dynamic> canGetRxHeaderMask() async {
    print("------CAN_GetRxHeaderMask------");
    saveLog("------CAN_GetRxHeaderMask------\n");

    String command = "";
    String crc = "";

    if (isChannel) {
      command = "2001${channelId}07";
      Uint8List bytesCommand = hexStringToByteArray(command);

      // Computing checksum using byte at index 3
      int checksum = Crc16CcittKermit.computeChecksum([bytesCommand[3]]);
      crc = checksum.toRadixString(16);
    } else {
      command = "200307";
      Uint8List bytesCommand = hexStringToByteArray(command);

      // Computing checksum using byte at index 2
      int checksum = Crc16CcittKermit.computeChecksum([bytesCommand[2]]);
      crc = checksum.toRadixString(16);
    }

    // Padding CRC to 4 characters (16-bit hex)
    if (crc.length == 3) {
      crc = "0$crc";
    } else if (crc.length < 3) {
      crc = crc.padLeft(4, '0');
    }

    Uint8List sendBytes = hexStringToByteArray(command + crc);

    // Using sendCommandBytes and updating the callback to handle byte-to-string conversion
    var response = await sendCommandBytes(sendBytes, (obj) {
      String output = byteArrayToString(obj as Uint8List);
      writeConsole(command, output);
    });

    return response;
  }

  Future<dynamic> canSetP1Min(String p1min) async {
    print("------CAN_SetP1Min------");
    saveLog("------CAN_SetP1Min------\n");

    String command = "";
    String crc = "";

    if (isChannel) {
      // Format: 20 + length(02) + ChannelId + ID(0c) + value
      command =
          "2002$channelId"
          "0c$p1min";
      Uint8List bytesCommand = hexStringToByteArray(command);

      // Computing checksum using bytes at indices 3 and 4
      int checksum = Crc16CcittKermit.computeChecksum([
        bytesCommand[3],
        bytesCommand[4],
      ]);
      crc = checksum.toRadixString(16);
    } else {
      // Format: 20 + length(04) + ID(0c) + value
      command = "20040c$p1min";
      Uint8List bytesCommand = hexStringToByteArray(command);

      // Computing checksum using bytes at indices 2 and 3
      int checksum = Crc16CcittKermit.computeChecksum([
        bytesCommand[2],
        bytesCommand[3],
      ]);
      crc = checksum.toRadixString(16);
    }

    // Padding CRC to 4 characters (16-bit hex)
    if (crc.length == 3) {
      crc = "0$crc";
    } else if (crc.length < 3) {
      crc = crc.padLeft(4, '0');
    }

    Uint8List sendBytes = hexStringToByteArray(command + crc);

    // Using sendCommandBytes with print-based logging in the callback
    var response = await sendCommandBytes(sendBytes, (obj) {
      String output = byteArrayToString(obj as Uint8List);
      writeConsole(command, output);
    });

    return response;
  }

  Future<dynamic> canGetP1Min() async {
    print("------CAN_GetP1Min------");
    saveLog("------CAN_GetP1Min------\n");

    String command = "";
    String crc = "";

    if (isChannel) {
      // Format: 20 + Length(01) + ChannelId + ID(0d)
      command = "2001${channelId}0d";
      Uint8List bytesCommand = hexStringToByteArray(command);

      // Computing checksum using byte at index 3
      int checksum = Crc16CcittKermit.computeChecksum([bytesCommand[3]]);
      crc = checksum.toRadixString(16);
    } else {
      // Format: 20 + Length(03) + ID(0d)
      command = "20030d";
      Uint8List bytesCommand = hexStringToByteArray(command);

      // Computing checksum using byte at index 2
      int checksum = Crc16CcittKermit.computeChecksum([bytesCommand[2]]);
      crc = checksum.toRadixString(16);
    }

    // Padding CRC logic
    if (crc.length == 3) {
      crc = "0$crc";
    } else if (crc.length < 3) {
      crc = crc.padLeft(4, '0');
    }

    Uint8List sendBytes = hexStringToByteArray(command + crc);

    // Using sendCommandBytes and updating callback for print-based logging
    var response = await sendCommandBytes(sendBytes, (obj) {
      String output = byteArrayToString(obj as Uint8List);
      writeConsole(command, output);
    });

    return response;
  }

  Future<dynamic> canSetP2Max(String p2max) async {
    print("------CAN_SetP2Max------");
    saveLog("------CAN_SetP2Max------\n");

    String command = "";
    String crc = "";

    if (isChannel) {
      // Format: 20 + length(03) + ChannelId + ID(0e) + value
      command =
          "2003$channelId"
          "0e$p2max";
      Uint8List bytesCommand = hexStringToByteArray(command);

      // Computing checksum using bytes at indices 3, 4, and 5
      int checksum = Crc16CcittKermit.computeChecksum([
        bytesCommand[3],
        bytesCommand[4],
        bytesCommand[5],
      ]);
      crc = checksum.toRadixString(16);
    } else {
      // Format: 20 + length(05) + ID(0e) + value
      command = "20050e$p2max";
      Uint8List bytesCommand = hexStringToByteArray(command);

      // Computing checksum using bytes at indices 2, 3, and 4
      int checksum = Crc16CcittKermit.computeChecksum([
        bytesCommand[2],
        bytesCommand[3],
        bytesCommand[4],
      ]);
      crc = checksum.toRadixString(16);
    }

    // Padding CRC logic
    if (crc.length == 3) {
      crc = "0$crc";
    } else if (crc.length < 3) {
      crc = crc.padLeft(4, '0');
    }

    Uint8List sendBytes = hexStringToByteArray(command + crc);

    // Using sendCommandBytes with print-based logging in the callback
    var response = await sendCommandBytes(sendBytes, (obj) {
      String output = byteArrayToString(obj as Uint8List);
      writeConsole(command, output);
    });

    return response;
  }

  Future<dynamic> canGetP2Max() async {
    print("------CAN_GetP2Max------");
    saveLog("------CAN_GetP2Max------\n");

    String command = "";
    String crc = "";

    if (isChannel) {
      // Format: 20 + Length(01) + ChannelId + ID(0f)
      command = "2001${channelId}0f";
      Uint8List bytesCommand = hexStringToByteArray(command);

      // Computing checksum using byte at index 3
      int checksum = Crc16CcittKermit.computeChecksum([bytesCommand[3]]);
      crc = checksum.toRadixString(16);
    } else {
      // Format: 20 + Length(03) + ID(0f)
      command = "20030f";
      Uint8List bytesCommand = hexStringToByteArray(command);

      // Computing checksum using byte at index 2
      int checksum = Crc16CcittKermit.computeChecksum([bytesCommand[2]]);
      crc = checksum.toRadixString(16);
    }

    // Padding CRC logic
    if (crc.length == 3) {
      crc = "0$crc";
    } else if (crc.length < 3) {
      crc = crc.padLeft(4, '0');
    }

    Uint8List sendBytes = hexStringToByteArray(command + crc);

    // Using sendCommandBytes with standard print logging in the callback
    var response = await sendCommandBytes(sendBytes, (obj) {
      String output = byteArrayToString(obj as Uint8List);
      writeConsole(command, output);
    });

    return response;
  }

  Future<dynamic> canStartTp() async {
    print("------CAN_StartTP------");
    saveLog("------CAN_StartTP------\n");

    String command = "";
    String crc = "";

    if (isChannel) {
      // Format: 20 + Length(01) + ChannelId + ID(10)
      command = "2001${channelId}10";
      Uint8List bytesCommand = hexStringToByteArray(command);

      // Computing checksum using byte at index 3
      int checksum = Crc16CcittKermit.computeChecksum([bytesCommand[3]]);
      crc = checksum.toRadixString(16);
    } else {
      // Format: 20 + Length(03) + ID(10)
      command = "200310";
      Uint8List bytesCommand = hexStringToByteArray(command);

      // Computing checksum using byte at index 2
      int checksum = Crc16CcittKermit.computeChecksum([bytesCommand[2]]);
      crc = checksum.toRadixString(16);
    }

    // Padding CRC logic
    if (crc.length == 3) {
      crc = "0$crc";
    } else if (crc.length < 3) {
      crc = crc.padLeft(4, '0');
    }

    Uint8List sendBytes = hexStringToByteArray(command + crc);

    // Using sendCommandBytes with standard print logging in the callback
    var response = await sendCommandBytes(sendBytes, (obj) {
      String output = byteArrayToString(obj as Uint8List);
      writeConsole(command, output);
    });

    return response;
  }

  Future<dynamic> canStopTp() async {
    print("------CAN_StopTP------");
    saveLog("------CAN_StopTP------\n");

    String command = "";
    String crc = "";

    if (isChannel) {
      // Format: 20 + Length(01) + ChannelId + ID(11)
      command = "2001${channelId}11";
      Uint8List bytesCommand = hexStringToByteArray(command);

      // Computing checksum using byte at index 3
      int checksum = Crc16CcittKermit.computeChecksum([bytesCommand[3]]);
      crc = checksum.toRadixString(16);
    } else {
      // Format: 20 + Length(03) + ID(11)
      command = "200311";
      Uint8List bytesCommand = hexStringToByteArray(command);

      // Computing checksum using byte at index 2
      int checksum = Crc16CcittKermit.computeChecksum([bytesCommand[2]]);
      crc = checksum.toRadixString(16);
    }

    // Padding CRC logic
    if (crc.length == 3) {
      crc = "0$crc";
    } else if (crc.length < 3) {
      crc = crc.padLeft(4, '0');
    }

    Uint8List sendBytes = hexStringToByteArray(command + crc);

    // Using sendCommandBytes with standard print logging in the callback
    var response = await sendCommandBytes(sendBytes, (obj) {
      String output = byteArrayToString(obj as Uint8List);
      writeConsole(command, output);
    });

    return response;
  }

  Future<dynamic> setTesterPresent(String comm) async {
    print("------SetTesterPresent------");
    saveLog("------SetTesterPresent------\n");

    String command = "";
    String crc = "";

    if (isChannel) {
      // Note: Your C# code used ID '0c' for Channel mode but '12' for non-channel.
      // I preserved that logic here.
      command =
          "2002$channelId"
          "0c$comm";
      Uint8List bytesCommand = hexStringToByteArray(command);

      // Computing checksum using bytes at indices 3 and 4
      int checksum = Crc16CcittKermit.computeChecksum([
        bytesCommand[3],
        bytesCommand[4],
      ]);
      crc = checksum.toRadixString(16);
    } else {
      // Standard Format: 20 + Length(04) + ID(12) + Value
      command = "200412$comm";
      Uint8List bytesCommand = hexStringToByteArray(command);

      // Computing checksum using bytes at indices 2 and 3
      int checksum = Crc16CcittKermit.computeChecksum([
        bytesCommand[2],
        bytesCommand[3],
      ]);
      crc = checksum.toRadixString(16);
    }

    // Padding CRC to 4 characters (16-bit hex)
    if (crc.length == 3) {
      crc = "0$crc";
    } else if (crc.length < 3) {
      crc = crc.padLeft(4, '0');
    }

    Uint8List sendBytes = hexStringToByteArray(command + crc);

    // Using sendCommandBytes with the standard print-based callback conversion
    var response = await sendCommandBytes(sendBytes, (obj) {
      String output = byteArrayToString(obj as Uint8List);
      writeConsole(command, output);
    });

    return response;
  }

  Future<dynamic> canStartPadding(String paddingByte) async {
    print("------CAN_StartPadding------");
    saveLog("------CAN_StartPadding------\n");

    String command = "";
    String crc = "";

    if (isChannel) {
      // Format: 20 + length(02) + ChannelId + ID(12) + paddingByte
      command =
          "2002$channelId"
          "12$paddingByte";
      Uint8List bytesCommand = hexStringToByteArray(command);

      // Computing checksum using bytes at indices 3 and 4
      int checksum = Crc16CcittKermit.computeChecksum([
        bytesCommand[3],
        bytesCommand[4],
      ]);
      crc = checksum.toRadixString(16);
    } else {
      // Format: 20 + length(04) + ID(12) + paddingByte
      command = "200412$paddingByte";
      Uint8List bytesCommand = hexStringToByteArray(command);

      // Computing checksum using bytes at indices 2 and 3
      int checksum = Crc16CcittKermit.computeChecksum([
        bytesCommand[2],
        bytesCommand[3],
      ]);
      crc = checksum.toRadixString(16);
    }

    // Padding CRC logic
    if (crc.length == 3) {
      crc = "0$crc";
    } else if (crc.length < 3) {
      crc = crc.padLeft(4, '0');
    }

    Uint8List sendBytes = hexStringToByteArray(command + crc);

    // Using sendCommandBytes with standard print logging in the callback
    var response = await sendCommandBytes(sendBytes, (obj) {
      String output = byteArrayToString(obj as Uint8List);
      writeConsole(command, output);
    });

    return response;
  }

  Future<dynamic> canStopPadding() async {
    print("------CAN_StopPadding------");
    saveLog("------CAN_StopPadding------\n");

    String command = "";
    String crc = "";

    if (isChannel) {
      // Format: 20 + Length(01) + ChannelId + ID(13)
      command = "2001${channelId}13";
      Uint8List bytesCommand = hexStringToByteArray(command);

      // Computing checksum using byte at index 3
      int checksum = Crc16CcittKermit.computeChecksum([bytesCommand[3]]);
      crc = checksum.toRadixString(16);
    } else {
      // Format: 20 + Length(03) + ID(13)
      command = "200313";
      Uint8List bytesCommand = hexStringToByteArray(command);

      // Computing checksum using byte at index 2
      int checksum = Crc16CcittKermit.computeChecksum([bytesCommand[2]]);
      crc = checksum.toRadixString(16);
    }

    // Padding CRC to 4 characters (16-bit hex)
    if (crc.length == 3) {
      crc = "0$crc";
    } else if (crc.length < 3) {
      crc = crc.padLeft(4, '0');
    }

    Uint8List sendBytes = hexStringToByteArray(command + crc);

    // Using sendCommandBytes with print-based logging in the callback
    var response = await sendCommandBytes(sendBytes, (obj) {
      String output = byteArrayToString(obj as Uint8List);
      writeConsole(command, output);
    });

    return response;
  }

  Future<dynamic> canTxData(String txData) async {
    print("------CAN_TxData------");

    // Logic: "40" + the transaction data hex string
    String command = "40$txData";

    // For CRC calculation, we use only the payload (txData) as per your C# logic
    Uint8List crcBytesComputation = hexStringToByteArray(txData);
    int checksum = Crc16CcittKermit.computeChecksum(crcBytesComputation);
    String crc = checksum.toRadixString(16);

    // Padding CRC to 4 hex characters (16-bit)
    if (crc.length == 3) {
      crc = "0$crc";
    } else if (crc.length < 3) {
      crc = crc.padLeft(4, '0');
    }

    // Combine command and CRC, then convert to bytes
    Uint8List sendBytes = hexStringToByteArray(command + crc);

    // Using sendCommandBytes with the standard callback logic
    var response = await sendCommandBytes(sendBytes, (obj) {
      String output = byteArrayToString(obj as Uint8List);
      writeConsole(command, output);
    });

    return response;
  }

 // static final _lock = Lock();

  @override
  Future<ResponseArrayStatus> canTxRx(int frameLength, String txData) async {
   // return await _lock.synchronized(() async {
      print("------ Start CAN_TxRx ------");
      print("📤 [canTxRx] frameLength: $frameLength");
      print("📤 [canTxRx] txData: $txData");

      try {
        // 1. Prepare Command String
        int dataLength = frameLength + 2; // +2 for CRC bytes
        print("📤 [canTxRx] dataLength (frameLength+2): $dataLength");

        String commandHeader = "";

        if (isChannel) {
          int firstByte = 0x40 | ((frameLength >> 8) & 0x0F);
          int secondByte = frameLength & 0xFF;
          commandHeader =
              firstByte.toRadixString(16).padLeft(2, '0').toUpperCase() +
              secondByte.toRadixString(16).padLeft(2, '0').toUpperCase() +
              (channelId ?? "00");
          print("📤 [canTxRx] mode: CHANNEL | channelId: $channelId");
        } else {
          int firstByte = 0x40 | ((dataLength >> 8) & 0x0F);
          int secondByte = dataLength & 0xFF;
          commandHeader =
              firstByte.toRadixString(16).padLeft(2, '0').toUpperCase() +
              secondByte.toRadixString(16).padLeft(2, '0').toUpperCase();
          print("📤 [canTxRx] mode: NO-CHANNEL");
          print(
            "📤 [canTxRx] firstByte: 0x${firstByte.toRadixString(16).toUpperCase()}",
          );
          print(
            "📤 [canTxRx] secondByte: 0x${secondByte.toRadixString(16).toUpperCase()}",
          );
        }

        print("📤 [canTxRx] commandHeader: $commandHeader");

        Uint8List crcBytesComputation = hexStringToByteArray(txData);
        int checksum = Crc16CcittKermit.computeChecksum(crcBytesComputation);
        String crcStr = checksum
            .toRadixString(16)
            .padLeft(4, '0')
            .toUpperCase();

        print(
          "📤 [canTxRx] CRC input (txData bytes): ${byteArrayToString(crcBytesComputation)}",
        );
        print("📤 [canTxRx] checksum int: $checksum");
        print("📤 [canTxRx] crcStr: $crcStr");

        String fullCommandHex = commandHeader + txData + crcStr;
        Uint8List sendBytes = hexStringToByteArray(fullCommandHex);

        print("📤 [canTxRx] fullCommandHex: $fullCommandHex");
        print("📤 [canTxRx] sendBytes.length: ${sendBytes.length}");
        print("📤 [canTxRx] sendBytes hex: ${byteArrayToString(sendBytes)}");
        print("TX Hex: $fullCommandHex | CRC: $crcStr");

        int retryCount = 0;
        const int maxRetries = 5;

        while (retryCount <= maxRetries) {
          print("🔄 [canTxRx] attempt: $retryCount / $maxRetries");

          dynamic rawResponse;

          if (isCanSimulate) {
            print("🔄 [canTxRx] path: SIMULATE");
            rawResponse = await simulateViaApi(txData);
          } else if (platform == PlatformType.android &&
              ConnectivityType == ConnectivityType.rp1210) {
            // RP1210 sends raw txData bytes (no header/CRC wrapper).
            print("🔄 [canTxRx] path: RP1210");
            rawResponse = await sendCommandBytes(crcBytesComputation, (obj) {
              writeConsole(fullCommandHex, byteArrayToString(obj as Uint8List));
            });
          } else {
            print("🔄 [canTxRx] path: NORMAL USB/WIFI");
            rawResponse = await sendCommandBytes(sendBytes, (obj) {
              writeConsole(fullCommandHex, byteArrayToString(obj as Uint8List));
            });
          }

          print("📥 [canTxRx] rawResponse type: ${rawResponse?.runtimeType}");

          // 3. Handle null / invalid response
          if (rawResponse == null || rawResponse is! Uint8List) {
            print("❌ [canTxRx] null or invalid response — retry $retryCount");
            if (++retryCount > maxRetries) {
              print(
                "❌ [canTxRx] max retries exceeded — returning Communication Error",
              );
              return ResponseArrayStatus(
                ecuResponse: null,
                ecuResponseStatus: "Communication Error",
                actualDataBytes: null,
              );
            }
            await Future.delayed(const Duration(milliseconds: 5));
            continue;
          }

          Uint8List ecuResponseBytes = rawResponse;
          print(
            "📥 [canTxRx] ecuResponseBytes: ${byteArrayToString(ecuResponseBytes)}",
          );
          print(
            "📥 [canTxRx] ecuResponseBytes.length: ${ecuResponseBytes.length}",
          );

          // 4. Strip known junk prefix that can appear on some WiFi dongles.
          // This mirrors the C# dhcps string-replacement logic.
          ecuResponseBytes = _stripDhcpsJunk(ecuResponseBytes);

          // 5. Check for dongle disconnect string
          String strResponse = utf8.decode(
            ecuResponseBytes,
            allowMalformed: true,
          );
          if (strResponse.contains("Dongle disconnected")) {
            print("❌ [canTxRx] Dongle disconnected detected");
            return ResponseArrayStatus(
              ecuResponseStatus: "Communication Error",
            );
          }

          // 6. Decode response
          print("🔍 [canTxRx] decoding response...");
          print("🔍 [canTxRx] isChannel: $isChannel");

          Map<String, dynamic> decodeResult;
          if (platform == PlatformType.android &&
              ConnectivityType == ConnectivityType.rp1210) {
            print("🔍 [canTxRx] decode path: RP1210");
            decodeResult = ResponseArrayDecoding.checkResponseRP1210(
              ecuResponseBytes,
              sendBytes,
            );
          } else if (isChannel) {
            print("🔍 [canTxRx] decode path: WITH CHANNEL");
            decodeResult = ResponseArrayDecoding.checkResponseWithChannel(
              ecuResponseBytes,
              sendBytes,
            );
          } else {
            print("🔍 [canTxRx] decode path: STANDARD");
            decodeResult = ResponseArrayDecoding.checkResponse(
              ecuResponseBytes,
              sendBytes,
            );
          }

          String status = (decodeResult['status'] as String?) ?? "ERROR";
          Uint8List actualData =
              (decodeResult['dataArray'] as Uint8List?) ?? Uint8List(0);

          print("🔍 [canTxRx] decoded status: $status");
          print(
            "🔍 [canTxRx] decoded actualData: ${byteArrayToString(actualData)}",
          );

          // 7. SENDAGAIN — re-transmit the full command
          if (status == "SENDAGAIN") {
            print("🔄 [canTxRx] SENDAGAIN — retry $retryCount");
            if (++retryCount > maxRetries) {
              print("❌ [canTxRx] SENDAGAIN threshold crossed");
              return ResponseArrayStatus(
                ecuResponse: ecuResponseBytes,
                ecuResponseStatus: "DONGLEERROR_SENDAGAINTHRESHOLDCROSSED",
                actualDataBytes: actualData,
              );
            }
            await Future.delayed(const Duration(milliseconds: 5));
            continue;
          }

          // 8. READAGAIN — response came back partial; keep reading
          if (status == "READAGAIN") {
            print("🔄 [canTxRx] READAGAIN — delegating to _handleReadAgain");
            return await _handleReadAgain(sendBytes);
          }

          // 9. Success path
          print("✅ [canTxRx] Final Status: $status");
          print("------ECU RESPONSE START------");
          print(
            "------ECUResponse ------ ${byteArrayToString(ecuResponseBytes)}",
          );
          print(
            "------ActualDataBytes ------ ${byteArrayToString(actualData)}",
          );
          print("------ECUResponseStatus ------ $status");
          print("------ECU RESPONSE END------");

          return ResponseArrayStatus(
            ecuResponse: ecuResponseBytes,
            ecuResponseStatus: status,
            actualDataBytes: actualData,
          );
        }

        // Should not reach here, but guard just in case
        print("❌ [canTxRx] Exited retry loop unexpectedly");
        return ResponseArrayStatus(
          ecuResponse: null,
          ecuResponseStatus: "Communication Error",
          actualDataBytes: null,
        );
      } on ArgumentError catch (e) {
        print("🔥 [canTxRx] ArgumentError: $e");
        return ResponseArrayStatus(
          ecuResponse: null,
          ecuResponseStatus: "Communication Error",
          actualDataBytes: null,
        );
      } on TimeoutException catch (e) {
        print("🔥 [canTxRx] TimeoutException: $e");
        return ResponseArrayStatus(
          ecuResponse: null,
          ecuResponseStatus: "Communication Error",
          actualDataBytes: null,
        );
      } catch (e) {
        print("🔥 [canTxRx] Fatal Exception: $e");
        return ResponseArrayStatus(
          ecuResponse: null,
          ecuResponseStatus: "Communication Error",
          actualDataBytes: null,
        );
      }
    }
    //);
 // }

  Uint8List _stripDhcpsJunk(Uint8List input) {
    const String junk = "dhcps: send_offer>>udp_sendto result 0";
    String decoded = utf8.decode(input, allowMalformed: true);
    if (decoded.contains(junk)) {
      print("⚠️  [_stripDhcpsJunk] stripping junk prefix from response");
      String cleaned = decoded.replaceAll(junk, "");
      return Uint8List.fromList(utf8.encode(cleaned));
    }
    return input;
  }

  Future<ResponseArrayStatus> _handleReadAgain(Uint8List sendBytes) async {
    print("------ _handleReadAgain START ------");
    print("📤 [_handleReadAgain] sendBytes: ${byteArrayToString(sendBytes)}");
    final int? requestSid = sendBytes.length > 3 ? sendBytes[3] : null;
    print(
      "📤 [_handleReadAgain] requestSid: "
      "${requestSid != null ? '0x${requestSid.toRadixString(16).padLeft(2, '0').toUpperCase()}' : 'unknown'}",
    );

    String currentStatus = "READAGAIN";
    ResponseArrayStatus finalStruct = ResponseArrayStatus(
      ecuResponseStatus: "READAGAIN",
    );

    const int maxReads = 20;
    int readCount = 0;

    while (currentStatus == "READAGAIN" && readCount < maxReads) {
      readCount++;
      print("🔄 [_handleReadAgain] read attempt: $readCount / $maxReads");

      saveLog("------Read Again------\n");

      await Future.delayed(const Duration(milliseconds: 5));

      dynamic raw = await readData();

      if (raw == null) {
        print("❌ [_handleReadAgain] readData returned null — skipping");
        continue;
      }

      Uint8List readBytes = raw as Uint8List;

      // Strip junk prefix before any further processing
      readBytes = _stripDhcpsJunk(readBytes);

      print("📥 [_handleReadAgain] readBytes: ${byteArrayToString(readBytes)}");
      print("📥 [_handleReadAgain] readBytes.length: ${readBytes.length}");

      // Check for dongle disconnect on every read iteration (fix applied)
      String strRead = utf8.decode(readBytes, allowMalformed: true);
      if (strRead.contains("Dongle disconnected")) {
        print("❌ [_handleReadAgain] Dongle disconnected detected");
        return ResponseArrayStatus(ecuResponseStatus: "Communication Error");
      }
      Map<String, dynamic> retryResult = isChannel
          ? ResponseArrayDecoding.checkResponseWithChannel(readBytes, sendBytes)
          : ResponseArrayDecoding.checkResponse(readBytes, sendBytes);

      String decodedStatus = (retryResult['status'] as String?) ?? "ERROR";
      Uint8List actualData =
          (retryResult['dataArray'] as Uint8List?) ?? Uint8List(0);

      print("🔍 [_handleReadAgain] decoded status: $decodedStatus");
      print(
        "🔍 [_handleReadAgain] decoded actualData: ${byteArrayToString(actualData)}",
      );

      if (requestSid != null &&
          decodedStatus != "READAGAIN" &&
          decodedStatus != "Communication Error" &&
          actualData.isNotEmpty) {
        final Uint8List sidCheckData = decodedStatus == "NOERROR"
            ? actualData
            : _extractUdsPayloadForSidCheck(actualData);

        final int respFirstByte = sidCheckData[0];
        final bool isPositiveMatch = respFirstByte == (requestSid + 0x40);
        final bool isNegativeMatch =
            respFirstByte == 0x7F &&
            sidCheckData.length > 1 &&
            sidCheckData[1] == requestSid;

        if (!isPositiveMatch && !isNegativeMatch) {
          print(
            "⚠️ [_handleReadAgain] SID MISMATCH — expected response for SID "
            "0x${requestSid.toRadixString(16).padLeft(2, '0').toUpperCase()} "
            "but got frame starting with "
            "0x${respFirstByte.toRadixString(16).padLeft(2, '0').toUpperCase()}"
            "${actualData.length > 1 ? ' 0x${actualData[1].toRadixString(16).padLeft(2, '0').toUpperCase()}' : ''} "
            "— treating as stale, discarding and reading again",
          );
          currentStatus = "READAGAIN";
          continue;
        }
      }

      currentStatus = decodedStatus;

      finalStruct = ResponseArrayStatus(
        ecuResponse: readBytes,
        ecuResponseStatus: currentStatus,
        actualDataBytes: actualData,
      );

      print("------EXTRA READ DATA START------");
      print("------ECUResponse ------ ${byteArrayToString(readBytes)}");
      print("------ActualDataBytes ------ ${byteArrayToString(actualData)}");
      print("------ECUResponseStatus ------ $currentStatus");
      print("------EXTRA READ DATA END------");
    }

    if (currentStatus == "READAGAIN") {
      print(
        "❌ [_handleReadAgain] max reads ($maxReads) reached — still READAGAIN",
      );
    } else {
      print("✅ [_handleReadAgain] final status: $currentStatus");
    }

    print("------ _handleReadAgain END ------");
    return finalStruct;
  }

  Uint8List _extractUdsPayloadForSidCheck(Uint8List raw) {
    try {
      for (int i = raw.length - 1; i >= 0; i--) {
        if ((raw[i] & 0xF0) != 0x40) continue;
        final headerStart = i;
        if (headerStart + 1 >= raw.length) continue;

        final lengthField =
            ((raw[headerStart] & 0x0F) << 8) | raw[headerStart + 1];

        // isChannel always true in this app — 2 length bytes + 1 channel byte.
        final payloadStart = headerStart + 3;
        final payloadEnd = payloadStart + lengthField;

        if (payloadStart <= raw.length &&
            payloadEnd <= raw.length &&
            payloadEnd >= payloadStart) {
          return raw.sublist(payloadStart, payloadEnd);
        }
      }
    } catch (_) {}
    return raw;
  }

  //=======================================================

  Future<ResponseArrayStatusIvn> canIvnRxFrame(String frameId) async {
    ResponseArrayStatusIvn frameResponse = ResponseArrayStatusIvn();

    try {
      // 1. Get command bytes for hardware mask
      Uint8List sendBytes = await canSetHardRxHeaderMask(frameId);

      // 2. Send Command and await response
      var response = await sendCommandBytes(sendBytes, (obj) {
        writeConsole(
          byteArrayToString(sendBytes),
          byteArrayToString(obj as Uint8List),
        );
      });

      Uint8List ecuResponseBytes = response as Uint8List;
      String dataStatus = "";
      Uint8List? actualDataBytes;

      // 3. Decode response based on channel mode
      if (isChannel) {
        var result = ResponseArrayDecoding.checkResponseIVNwithChannel(
          ecuResponseBytes,
          sendBytes,
          "",
        );
        // ✅ FIX: was 'actualData' — correct key is 'dataArray'
        actualDataBytes = result['dataArray'] as Uint8List?;
        dataStatus = result['status'] as String? ?? "";
      } else {
        var result = ResponseArrayDecoding.checkResponseIVN(
          ecuResponseBytes,
          sendBytes,
          "",
        );
        // ✅ FIX: was 'actualData' — correct key is 'dataArray'
        actualDataBytes = result['dataArray'] as Uint8List?;
        dataStatus = result['status'] as String? ?? "";
      }

      // 4. Handle READAGAIN logic
      if (dataStatus == "READAGAIN") {
        while (dataStatus == "READAGAIN") {
          var responseReadAgain = await readData();
          Uint8List ecuResponseReadBytes = responseReadAgain as Uint8List;

          Uint8List? actualReadBytes;
          String dataReadStatus = "";

          if (isChannel) {
            var result = ResponseArrayDecoding.checkResponseWithChannel(
              ecuResponseReadBytes,
              sendBytes,
            );
            // ✅ FIX: was 'actualData' — correct key is 'dataArray'
            actualReadBytes = result['dataArray'] as Uint8List?;
            dataReadStatus = result['status'] as String? ?? "";
          } else {
            var result = ResponseArrayDecoding.checkResponse(
              ecuResponseReadBytes,
              sendBytes,
            );
            // ✅ FIX: was 'actualData' — correct key is 'dataArray'
            actualReadBytes = result['dataArray'] as Uint8List?;
            dataReadStatus = result['status'] as String? ?? "";
          }

          dataStatus = dataReadStatus;

          frameResponse = ResponseArrayStatusIvn(
            ecuResponseStatus: dataReadStatus,
            actualFrameBytes: actualReadBytes,
          );

          print("------EXTRA READ DATA START ------");
          if (frameResponse.actualFrameBytes != null) {
            print(
              "------ECUResponse ------ ${byteArrayToString(ecuResponseReadBytes)}",
            );
            print(
              "------ActualDataBytes ------ ${byteArrayToString(frameResponse.actualFrameBytes!)}",
            );
          }
          print(
            "------ECUResponseStatus ------ ${frameResponse.ecuResponseStatus}",
          );
          print("------EXTRA READ DATA END ------");

          if (frameResponse.actualFrameBytes == null) {
            print("Command BT ACTUAL RESPONSE = NULL");
          } else {
            print(
              "Command BT ACTUAL RESPONSE = ${byteArrayToString(frameResponse.actualFrameBytes!)}",
            );
          }
        }
      } else {
        // 5. Standard Response
        frameResponse = ResponseArrayStatusIvn(
          ecuResponseStatus: dataStatus,
          actualFrameBytes: actualDataBytes,
        );

        if (frameResponse.actualFrameBytes == null) {
          print("Command BT ACTUAL RESPONSE = NULL");
        } else {
          print(
            "Command BT ACTUAL RESPONSE = ${byteArrayToString(frameResponse.actualFrameBytes!)}",
          );
        }
      }

      return frameResponse;
    } catch (e, stacktrace) {
      print("Exception in canIvnRxFrame: $e \n $stacktrace");
      return ResponseArrayStatusIvn(
        ecuResponseStatus: "NULL_ERROR",
        actualFrameBytes: null,
      );
    }
  }

  // ============================================================

  Future<List<IvnResponseArrayStatus>?> setIvnFrame(
    List<String> frameIDC,
  ) async {
    List<IvnResponseArrayStatus> responseList = [];

    try {
      for (var frame in List.from(frameIDC)) {
        print("------SET_IVN FRAME------");

        String command = "";
        String crc = "";

        if (isChannel) {
          if (frame.length == 8) {
            command =
                "2005$channelId"
                "20$frame";
            Uint8List bytesCommand = hexStringToByteArray(command);
            int checksum = Crc16CcittKermit.computeChecksum([
              bytesCommand[3],
              bytesCommand[4],
              bytesCommand[5],
              bytesCommand[6],
              bytesCommand[7],
            ]);
            crc = checksum.toRadixString(16).padLeft(4, '0');
          } else {
            command =
                "2003$channelId"
                "20$frame";
            Uint8List bytesCommand = hexStringToByteArray(command);
            int checksum = Crc16CcittKermit.computeChecksum([
              bytesCommand[3],
              bytesCommand[4],
              bytesCommand[5],
            ]);
            crc = checksum.toRadixString(16).padLeft(4, '0');
          }
        } else {
          if (frame.length == 8) {
            command = "200720$frame";
            Uint8List bytesCommand = hexStringToByteArray(command);
            int checksum = Crc16CcittKermit.computeChecksum([
              bytesCommand[2],
              bytesCommand[3],
              bytesCommand[4],
              bytesCommand[5],
              bytesCommand[6],
            ]);
            crc = checksum.toRadixString(16).padLeft(4, '0');
          } else {
            command = "200520$frame";
            Uint8List bytesCommand = hexStringToByteArray(command);
            int checksum = Crc16CcittKermit.computeChecksum([
              bytesCommand[2],
              bytesCommand[3],
              bytesCommand[4],
            ]);
            crc = checksum.toRadixString(16).padLeft(4, '0');
          }
        }

        Uint8List sendBytes = hexStringToByteArray(command + crc);

        var response = await sendCommandBytes(sendBytes, (obj) {
          writeConsole(command, byteArrayToString(obj as Uint8List));
        });

        Uint8List ecuResponseBytes = response as Uint8List;
        Uint8List? actualDataBytes;
        String dataStatus = "";

        if (isChannel) {
          var result = ResponseArrayDecoding.checkResponseIVNwithChannel(
            ecuResponseBytes,
            sendBytes,
            "",
          );
          // ✅ FIX: was 'actualData' — correct key is 'dataArray'
          actualDataBytes = result['dataArray'] as Uint8List?;
          dataStatus = result['status'] as String? ?? "";
        } else {
          var result = ResponseArrayDecoding.checkResponseIVN(
            ecuResponseBytes,
            sendBytes,
            "",
          );
          // ✅ FIX: was 'actualData' — correct key is 'dataArray'
          actualDataBytes = result['dataArray'] as Uint8List?;
          dataStatus = result['status'] as String? ?? "";
        }

        // Handle READAGAIN logic
        if (dataStatus == "READAGAIN") {
          while (dataStatus == "READAGAIN") {
            var responseReadAgain = await readData();
            Uint8List ecuResponseReadBytes = responseReadAgain as Uint8List;

            var retryResult = ResponseArrayDecoding.checkResponse(
              ecuResponseReadBytes,
              sendBytes,
            );

            String dataReadStatus = (retryResult['status'] as String?) ?? "";

            // ✅ FIX: was 'actualData' — correct key is 'dataArray'
            Uint8List? actualReadBytes = retryResult['dataArray'] as Uint8List?;

            dataStatus = dataReadStatus;

            var statusObj = IvnResponseArrayStatus(
              frame: frame,
              ecuResponse: ecuResponseReadBytes,
              ecuResponseStatus: dataReadStatus,
              actualDataBytes: actualReadBytes,
            );

            responseList.add(statusObj);
          }
        } else {
          var statusObj = IvnResponseArrayStatus(
            frame: frame,
            ecuResponse: ecuResponseBytes,
            ecuResponseStatus: dataStatus,
            actualDataBytes: actualDataBytes,
          );

          responseList.add(statusObj);
          print(
            "Command BT ACTUAL RESPONSE = ${statusObj.actualDataBytes == null ? "NULL" : byteArrayToString(statusObj.actualDataBytes!)}",
          );
        }
      }

      return responseList;
    } catch (e) {
      print("Error in setIvnFrame: $e");
      return null;
    }
  }

  Future<dynamic> setBlkSeqCntr(String blkLen) async {
    print("------SetBlkSeqCntr------");

    // Format: 20 + Length(04) + ID(08) + blkLen
    String command = "200408$blkLen";
    Uint8List bytesCommand = hexStringToByteArray(command);

    // Computing checksum using bytes at indices 2 and 3 (0x08 and the blkLen byte)
    int checksum = Crc16CcittKermit.computeChecksum([
      bytesCommand[2],
      bytesCommand[3],
    ]);

    String crc = checksum.toRadixString(16);

    // Padding CRC to 4 characters (16-bit hex)
    if (crc.length == 3) {
      crc = "0$crc";
    } else if (crc.length < 3) {
      crc = crc.padLeft(4, '0');
    }

    Uint8List sendBytes = hexStringToByteArray(command + crc);

    // Using sendCommandBytes with the standard callback logic
    var response = await sendCommandBytes(sendBytes, (obj) {
      String output = byteArrayToString(obj as Uint8List);
      writeConsole(command, output);
    });

    return response;
  }

  Future<dynamic> getBlkSeqCntr() async {
    print("------GetBlkSeqCntr------");

    // Format: 20 + Length(03) + ID(09)
    String command = "200309";
    Uint8List bytesCommand = hexStringToByteArray(command);

    // Computing checksum using byte at index 2 (the ID 0x09)
    int checksum = Crc16CcittKermit.computeChecksum([bytesCommand[2]]);
    String crc = checksum.toRadixString(16);

    // Padding CRC to 4 characters (16-bit hex)
    if (crc.length == 3) {
      crc = "0$crc";
    } else if (crc.length < 3) {
      crc = crc.padLeft(4, '0');
    }

    Uint8List sendBytes = hexStringToByteArray(command + crc);

    // Using sendCommandBytes with the standard callback logic
    var response = await sendCommandBytes(sendBytes, (obj) {
      String output = byteArrayToString(obj as Uint8List);
      writeConsole(command, output);
    });

    return response;
  }

  Future<dynamic> setSepTime(String sepTime) async {
    print("------SetSepTime------");

    // Format: 20 + Length(04) + ID(0A) + sepTime
    String command = "20040A$sepTime";
    Uint8List bytesCommand = hexStringToByteArray(command);

    // Computing checksum using bytes at indices 2 and 3 (0x0A and the sepTime byte)
    int checksum = Crc16CcittKermit.computeChecksum([
      bytesCommand[2],
      bytesCommand[3],
    ]);

    String crc = checksum.toRadixString(16);

    // Padding CRC to 4 characters (16-bit hex)
    if (crc.length == 3) {
      crc = "0$crc";
    } else if (crc.length < 3) {
      crc = crc.padLeft(4, '0');
    }

    Uint8List sendBytes = hexStringToByteArray(command + crc);

    // Using sendCommandBytes with the standard callback logic
    var response = await sendCommandBytes(sendBytes, (obj) {
      String output = byteArrayToString(obj as Uint8List);
      writeConsole(command, output);
    });

    return response;
  }

  Future<dynamic> getSepTime() async {
    print("------GetSepTime------");

    // Format: 20 + Length(03) + ID(0B)
    String command = "20030B";
    Uint8List bytesCommand = hexStringToByteArray(command);

    // Computing checksum using byte at index 2 (the ID 0x0B)
    int checksum = Crc16CcittKermit.computeChecksum([bytesCommand[2]]);
    String crc = checksum.toRadixString(16);

    // Padding CRC to 4 characters (16-bit hex)
    if (crc.length == 3) {
      crc = "0$crc";
    } else if (crc.length < 3) {
      crc = crc.padLeft(4, '0');
    }

    Uint8List sendBytes = hexStringToByteArray(command + crc);

    // Using sendCommandBytes with the standard callback logic
    var response = await sendCommandBytes(sendBytes, (obj) {
      String output = byteArrayToString(obj as Uint8List);
      writeConsole(command, output);
    });

    return response;
  }

  Future<dynamic> canGetDefaultSsid() async {
    print("------CAN_Get Default SSID------");

    // Format: 20 (Header) + 04 (Length) + 22 (ID) + 00 (Parameter)
    String command = "20042200";
    Uint8List bytesCommand = hexStringToByteArray(command);

    // Computing checksum using bytes at indices 2 and 3 (0x22 and 0x00)
    int checksum = Crc16CcittKermit.computeChecksum([
      bytesCommand[2],
      bytesCommand[3],
    ]);

    String crc = checksum.toRadixString(16);

    // Padding CRC to 4 characters (16-bit hex)
    if (crc.length == 3) {
      crc = "0$crc";
    } else if (crc.length < 3) {
      crc = crc.padLeft(4, '0');
    }

    Uint8List sendBytes = hexStringToByteArray(command + crc);

    // Using sendCommandBytes with the standard callback logic
    var response = await sendCommandBytes(sendBytes, (obj) {
      String output = byteArrayToString(obj as Uint8List);
      writeConsole(command, output);
    });

    return response;
  }

  Future<dynamic> canGetDefaultPassword() async {
    print("------CAN_Get Default Password------");

    // Format: 20 (Header) + 04 (Length) + 23 (ID) + 00 (Parameter)
    String command = "20042300";
    Uint8List bytesCommand = hexStringToByteArray(command);

    // Computing checksum using bytes at indices 2 and 3 (0x23 and 0x00)
    int checksum = Crc16CcittKermit.computeChecksum([
      bytesCommand[2],
      bytesCommand[3],
    ]);

    String crc = checksum.toRadixString(16);

    // Padding CRC to 4 characters (16-bit hex)
    if (crc.length == 3) {
      crc = "0$crc";
    } else if (crc.length < 3) {
      crc = crc.padLeft(4, '0');
    }

    Uint8List sendBytes = hexStringToByteArray(command + crc);

    // Using sendCommandBytes with the standard callback logic
    var response = await sendCommandBytes(sendBytes, (obj) {
      String output = byteArrayToString(obj as Uint8List);
      writeConsole(command, output);
    });

    return response;
  }

  Future<dynamic> canGetUserSsid() async {
    print("------CAN_Get User SSID------");

    // Format: 20 (Header) + 04 (Length) + 22 (ID) + 01 (Parameter)
    String command = "20042201";
    Uint8List bytesCommand = hexStringToByteArray(command);

    // Computing checksum using bytes at indices 2 and 3 (0x22 and 0x01)
    int checksum = Crc16CcittKermit.computeChecksum([
      bytesCommand[2],
      bytesCommand[3],
    ]);

    String crc = checksum.toRadixString(16);

    // Padding CRC to 4 characters (16-bit hex)
    if (crc.length == 3) {
      crc = "0$crc";
    } else if (crc.length < 3) {
      crc = crc.padLeft(4, '0');
    }

    Uint8List sendBytes = hexStringToByteArray(command + crc);

    // Using sendCommandBytes with the standard callback logic
    var response = await sendCommandBytes(sendBytes, (obj) {
      String output = byteArrayToString(obj as Uint8List);
      writeConsole(command, output);
    });

    return response;
  }

  Future<dynamic> canGetUserPassword() async {
    print("------CAN_Get User Password------");

    // Format: 20 (Header) + 04 (Length) + 23 (ID) + 01 (Parameter)
    String command = "20042301";
    Uint8List bytesCommand = hexStringToByteArray(command);

    // Computing checksum using bytes at indices 2 and 3 (0x23 and 0x01)
    int checksum = Crc16CcittKermit.computeChecksum([
      bytesCommand[2],
      bytesCommand[3],
    ]);

    String crc = checksum.toRadixString(16);

    // Padding CRC to 4 characters (16-bit hex)
    if (crc.length == 3) {
      crc = "0$crc";
    } else if (crc.length < 3) {
      crc = crc.padLeft(4, '0');
    }

    Uint8List sendBytes = hexStringToByteArray(command + crc);

    // Using sendCommandBytes with the standard callback logic
    var response = await sendCommandBytes(sendBytes, (obj) {
      // ignore: unnecessary_null_comparison
      String output = byteArrayToString(obj as Uint8List);
      writeConsole(command, output);
    });

    return response;
  }

  Future<dynamic> wifiWriteSSID(String ssid) async {
    print("------Dongle_WriteSSID------");

    String command = "";

    // Calculate SSID byte length (assuming hex string input)
    int ssidByteLength = ssid.length ~/ 2;

    if (isChannel) {
      // Format: 20 + Total Length + 00 + ChannelID (Assuming 01) + 16 (ID) + 01 (Param) + SSID + 00
      // Based on C#: ((SSID.Length / 2) + 3)
      String hexLen = (ssidByteLength + 3)
          .toRadixString(16)
          .padLeft(2, '0')
          .toUpperCase();
      command = "20${hexLen}001601${ssid}00";
    } else {
      // Format: 20 + Total Length + 16 (ID) + 01 (Param) + SSID + 00
      // Based on C#: ((SSID.Length / 2) + 5)
      String hexLen = (ssidByteLength + 5)
          .toRadixString(16)
          .padLeft(2, '0')
          .toUpperCase();
      command = "20${hexLen}1601${ssid}00";
    }

    Uint8List bytesCommand = hexStringToByteArray(command);

    // C# logic: Create outArray by copying bytes starting from index 3
    // outArray = bytesCommand[3...end]
    Uint8List outArray = bytesCommand.sublist(3);

    // Compute CRC on the sliced array
    int checksum = Crc16CcittKermit.computeChecksum(outArray);
    String crc = checksum.toRadixString(16).padLeft(4, '0');

    Uint8List sendBytes = hexStringToByteArray(command + crc);

    // Using sendCommandBytes with standard callback logging
    var response = await sendCommandBytes(sendBytes, (obj) {
      // ignore: unnecessary_null_comparison
      String output = byteArrayToString(obj as Uint8List);
      writeConsole(command, output);
    });

    return response;
  }

  Future<dynamic> wifiWritePw(String password) async {
    print("------Dongle_WritePassword------");

    String command = "";
    // PASSWORD length / 2 assumes the input string is a Hex string
    int passwordByteLength = password.length ~/ 2;

    if (isChannel) {
      // Format: 20 + Length + 00 + ChannelID (Assuming 01) + 17 (ID) + 01 (Param) + PW + 00
      String hexLen = (passwordByteLength + 3)
          .toRadixString(16)
          .padLeft(2, '0')
          .toUpperCase();
      command = "20${hexLen}001701${password}00";
    } else {
      // Format: 20 + Length + 17 (ID) + 01 (Param) + PW + 00
      String hexLen = (passwordByteLength + 5)
          .toRadixString(16)
          .padLeft(2, '0')
          .toUpperCase();
      command = "20${hexLen}1701${password}00";
    }

    Uint8List bytesCommand = hexStringToByteArray(command);

    // Replicating C# Array.Copy(bytesCommand, 3, outArray, 0, outArray.Length)
    // This takes everything from index 3 to the end of the array for CRC calculation
    Uint8List outArray = bytesCommand.sublist(3);

    int checksum = Crc16CcittKermit.computeChecksum(outArray);

    // Standardizing CRC to 4 characters (16-bit hex)
    String crc = checksum.toRadixString(16).padLeft(4, '0');

    Uint8List sendBytes = hexStringToByteArray(command + crc);

    // Using sendCommandBytes with the standard callback logic
    var response = await sendCommandBytes(sendBytes, (obj) {
      // ignore: unnecessary_null_comparison
      String output = byteArrayToString(obj as Uint8List);
      writeConsole(command, output);
    });

    return response;
  }

  Future<dynamic> updateFirmware(String url) async {
    print("------UpdateFirmware------");

    // url.length / 2 assumes the URL is passed as a hex-encoded string
    int urlByteLength = url.length ~/ 2;

    // Format: 20 + Length + 00 + 19 (ID) + URL + 00
    String hexLen = (urlByteLength + 2)
        .toRadixString(16)
        .padLeft(2, '0')
        .toUpperCase();
    String command = "20${hexLen}0019${url}00";

    Uint8List bytesCommand = hexStringToByteArray(command);

    // Replicating C# Array.Copy(bytesCommand, 3, outArray, 0, outArray.Length)
    // This extracts the payload starting from the 4th byte for CRC calculation
    Uint8List outArray = bytesCommand.sublist(3);

    int checksum = Crc16CcittKermit.computeChecksum(outArray);

    // Standardizing CRC to 4 characters (16-bit hex)
    String crc = checksum.toRadixString(16).padLeft(4, '0');

    Uint8List sendBytes = hexStringToByteArray(command + crc);

    // Using sendCommandBytes with the standard callback logic
    var response = await sendCommandBytes(sendBytes, (obj) {
      // ignore: unnecessary_null_comparison
      String output = byteArrayToString(obj as Uint8List);
      writeConsole(command, output);
    });

    return response;
  }

  Future<Uint8List> simulateViaApi(String requestPayload) async {
    const String url = "http://139.59.62.79/api/v1/models/get-response/";

    // Default error response: [0x40, 0x00, 0x00, 0xFF, 0xFF]
    final Uint8List errorResponse = Uint8List.fromList([
      0x40,
      0x00,
      0x00,
      0xFF,
      0xFF,
    ]);

    try {
      // Check for internet connectivity
      var ConnectivityTypeResult = await Connectivity().checkConnectivity();

      // If the list contains 'none', it means there are no active network interfaces
      if (ConnectivityTypeResult.contains(ConnectivityResult.none)) {
        print("CAN Simulate API: Check internet connection.");
        return errorResponse;
      }

      // Prepare Request Body
      Map<String, String> body = {'request': requestPayload};

      // Execute POST Request
      final response = await http
          .post(
            Uri.parse(url),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode(body),
          )
          .timeout(const Duration(seconds: 8)); // ✅ ONLY FIX: was missing before, so this await could hang forever

      print("CAN Simulate API: CAN REQUEST : $requestPayload");
      print("CAN Simulate API: CAN RESPONSE : ${response.body}");

      if (response.statusCode == 200) {
        final Map<String, dynamic> data = jsonDecode(response.body);

        // Check for error in the response model logic
        if (data['error'] != null && data['error'].toString().isNotEmpty) {
          return errorResponse;
        } else {
          String cleanResponse = data['response'].toString().replaceAll(
            " ",
            "",
          );
          // This assumes getCan2xFormat returns Uint8List
          return getCan2xFormat(cleanResponse);
        }
      } else {
        print("CAN Simulate API: Status Code: ${response.statusCode}");
        return errorResponse;
      }
    } catch (e, stackTrace) {
      print("CAN Simulate API: Exception : $e $stackTrace");
      return errorResponse;
    }
  }

  

  Uint8List getCan2xFormat(String response) {
    try {
      // response.length / 2 assumes the response is a hex string
      int frameLength = response.length ~/ 2;

      // Bitwise manipulation for the CAN2x header
      // firstByte: 0x40 | high 4 bits of length
      // secondByte: lower 8 bits of length
      int firstByte = 0x40 | ((frameLength >> 8) & 0x0F);
      int secondByte = frameLength & 0xFF;

      // Construct the command string: Header + ChannelId + Payload
      String command =
          firstByte.toRadixString(16).padLeft(2, '0').toUpperCase() +
          secondByte.toRadixString(16).padLeft(2, '0').toUpperCase() +
          channelId! +
          response;

      // CRC is computed only on the payload (response) per your C# logic
      Uint8List crcBytesComputation = hexStringToByteArray(response);
      int checksum = Crc16CcittKermit.computeChecksum(crcBytesComputation);

      // Format CRC as 4-character hex (16-bit)
      String crc = checksum.toRadixString(16).padLeft(4, '0').toUpperCase();

      // Final combined byte array
      Uint8List can2xRespBytes = hexStringToByteArray(command + crc);

      print("CAN Simulate API: CAN2x Format Response : $command$crc");

      return can2xRespBytes;
    } catch (e, stackTrace) {
      print("CAN Simulate API: Exception @GetCan2xFormat : $e $stackTrace");

      // Default error response: [0x40, 0x00, 0x00, 0xFF, 0xFF]
      return Uint8List.fromList([0x40, 0x00, 0x00, 0xFF, 0xFF]);
    }
  }
}
