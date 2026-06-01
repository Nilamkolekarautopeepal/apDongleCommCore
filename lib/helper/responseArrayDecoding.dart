import 'dart:typed_data';
import 'dart:developer' as developer;

class ResponseArrayDecoding {
  // Static variables to maintain state across calls (mimicking C# static fields)
  static bool firstposdongleackreceived = false;
  static String val = "";
  static String halfActualRespons = "";
  static int actualLenth = 0;

  static Map<String, dynamic> checkResponse(
    Uint8List pidBytesResponse,
    Uint8List requestBytes,
  ) {
    Uint8List dataArray = pidBytesResponse;
    String status = "NOERROR";

    try {
      var responseBytes = pidBytesResponse;
      var request = requestBytes;
      String expectedFrame = "";
      String reqType = "";
      int nextPacketIndex = 0;
      bool endOfPacket = false;
      int frameLen = 0;

      // ── Request Parsing ───────────────────────────────────────────────
      if (request[0] == 0x20) {
        reqType = "CONFIGREQUEST";
        switch (request[2]) {
          case 0x01: // Reset Dongle
          case 0x02: // Set Protocol
          case 0x04: // Set Transmit Header
          case 0x06: // Set Receive Header
          case 0x08: // Set Block length
          case 0x0A: // Set separation time
          case 0x0C: // Set Min time
          case 0x0E: // Set Max wait time
          case 0x10: // Periodic tester present
          case 0x11: // Stop periodic tester present
          case 0x12: // Pad transmit
          case 0x13: // Stop padding
          case 0x15: // Bluetooth name change
          case 0x17: // Set multiple filters
            expectedFrame = "DONGLECONFIGACK";
            break;
          case 0x03: // Get Protocol
          case 0x05: // Get Transmit Header
          case 0x07: // Get Receive Header
          case 0x09: // Get Block length
          case 0x0B: // Get separation time
          case 0x0D: // Get Min time
          case 0x0F: // Get Max wait time
          case 0x14: // Get firmware version
            expectedFrame = "DONGLECONFIGRESPONSE";
            break;
        }
      } else if (request[0] == 0x40) {
        reqType = "DATAREQUEST";
        expectedFrame = "DONGLECONFIGACK";
      }

      // ── Parser Loop ───────────────────────────────────────────────────
      nextPacketIndex = 0;
      endOfPacket = false;

      while (!endOfPacket) {
        // ✅ FIX: Range check — prevent index out of bounds
        if (nextPacketIndex >= responseBytes.length) {
          status = "READAGAIN";
          endOfPacket = true;
          break;
        }

        // ── BRANCH A: Dongle Config/ACK frame (0x20) ──────────────────
        if (responseBytes[nextPacketIndex] == 0x20) {
          // ✅ FIX: Bounds check before reading next byte
          if (nextPacketIndex + 1 >= responseBytes.length) {
            status = "READAGAIN";
            endOfPacket = true;
            break;
          }

          frameLen = responseBytes[nextPacketIndex + 1];

          if (reqType == "CONFIGREQUEST") {
            endOfPacket = true;

            if (expectedFrame == "DONGLECONFIGRESPONSE") {
              int length = frameLen - 2;

              // ✅ FIX: Guard negative/zero length
              if (length <= 0) {
                status = "NOERROR";
                dataArray = Uint8List(0);
                break;
              }

              // ✅ FIX: Bounds check before sublist
              int start = nextPacketIndex + 3;
              int end = start + length;
              if (end > responseBytes.length) {
                status = "READAGAIN";
                break;
              }

              Uint8List responseArray = Uint8List(length);
              responseArray.setRange(
                0,
                length,
                responseBytes.sublist(start, end),
              );
              dataArray = responseArray;
            }
            // else DONGLECONFIGACK — no data to extract, status stays NOERROR
          } else if (frameLen == 0x03) {
            // DATAREQUEST — dongle positive ACK (0x20 0x03 ...)

            if (firstposdongleackreceived == true) {
              firstposdongleackreceived = false;
              endOfPacket = true;
              status = "NOERROR";
              developer.log(
                "------ Jugaad - Getting positive dongle ack frame for second time -------",
              );
              break;
            }

            nextPacketIndex += 5;
            firstposdongleackreceived = true;

            if (nextPacketIndex < responseBytes.length) {
              endOfPacket = false; // continue loop to read ECU response
            } else {
              status = "READAGAIN";
              endOfPacket = true;
              break;
            }
          } else {
            // DATAREQUEST — dongle negative ACK
            endOfPacket = true;
            firstposdongleackreceived = false;

            // ✅ FIX: Bounds check before reading error byte
            if (responseBytes.length > 3) {
              switch (responseBytes[3]) {
                case 0x10:
                  status = "DONGLEERROR_COMMANDNOTSUPPORTED";
                  break;
                case 0x12:
                  status = "DONGLEERROR_INPUTNOTSUPPORTED";
                  break;
                case 0x13:
                  status = "DONGLEERROR_INVALIDFORMAT";
                  break;
                case 0x14:
                  status = "DONGLEERROR_INVALIDOPERATION";
                  break;
                case 0x15:
                  status = "DONGLEERROR_CRCFAILURE";
                  break;
                case 0x16:
                  status = "DONGLEERROR_PROTOCOLNOTSET";
                  break;
                case 0x33:
                  status = "DONGLEERROR_SECURITYACCESSDENIED";
                  break;
                default:
                  status = "SENDAGAIN";
                  break;
              }
            } else {
              status = "SENDAGAIN";
            }
          }
        }
        // ── BRANCH B: No ECU response — 0x40xx with length 0x00 or 0x02 ──
        // ✅ FIX: Added 0x00 length check — dongle sends 40 00 FF FF for no ECU response
        else if ((responseBytes[nextPacketIndex] & 0xF0) == 0x40 &&
            (responseBytes.length > nextPacketIndex + 1) &&
            (responseBytes[nextPacketIndex + 1] == 0x02 ||
                responseBytes[nextPacketIndex + 1] == 0x00)) {
          status = "ECUERROR_NORESPONSEFROMECU";
          endOfPacket = true;
          firstposdongleackreceived = false;
          break;
        }
        // ── BRANCH C: ECU Data Response (0x4x with actual length) ────────
        else if ((responseBytes[nextPacketIndex] & 0xF0) == 0x40 ||
            halfActualRespons.isNotEmpty) {
          firstposdongleackreceived = false;

          // ✅ FIX: Bounds check before reading length byte
          if (nextPacketIndex + 1 >= responseBytes.length) {
            status = "READAGAIN";
            endOfPacket = true;
            break;
          }

          var msgLen =
              ((responseBytes[nextPacketIndex] & 0x0F) << 8) +
              responseBytes[nextPacketIndex + 1];
          frameLen = msgLen;

          if (halfActualRespons.isEmpty) {
            actualLenth = msgLen;
          }

          // ✅ FIX: Bounds check before reading payload byte
          if (nextPacketIndex + 2 >= responseBytes.length) {
            status = "READAGAIN";
            endOfPacket = true;
            break;
          }

          // ── ECU Negative Response (7F) ─────────────────────────────
          if (responseBytes[nextPacketIndex + 2] == 0x7F) {
            // ✅ FIX: Bounds check before reading NRC byte
            if (nextPacketIndex + 4 >= responseBytes.length) {
              status = "READAGAIN";
              endOfPacket = true;
              break;
            }

            if (responseBytes[nextPacketIndex + 4] == 0x78) {
              // NRC 0x78: Response pending — read again
              nextPacketIndex += 7;
              endOfPacket = false;

              if (nextPacketIndex > responseBytes.length - 1) {
                status = "READAGAIN";
                endOfPacket = true;
                break;
              }
            } else {
              endOfPacket = true;
              switch (responseBytes[nextPacketIndex + 4]) {
                case 0x10:
                  status = "ECUERROR_GENERALREJECT";
                  break;
                case 0x11:
                  status = "ECUERROR_SERVICENOTSUPPORTED";
                  break;
                case 0x12:
                  status = "ECUERROR_SUBFUNCTIONNOTSUPPORTED";
                  break;
                case 0x13:
                  status = "ECUERROR_INVALIDFORMAT";
                  break;
                case 0x14:
                  status = "ECUERROR_RESPONSETOOLONG";
                  break;
                case 0x21:
                  status = "ECUERROR_BUSYREPEATREQUEST";
                  break;
                case 0x22:
                  status = "ECUERROR_CONDITIONSNOTCORRECT";
                  break;
                case 0x24:
                  status = "ECUERROR_REQUESTSEQUENCEERROR";
                  break;
                case 0x31:
                  status = "ECUERROR_REQUESTOUTOFRANGE";
                  break;
                case 0x33:
                  status = "ECUERROR_SECURITYACCESSDENIED";
                  break;
                case 0x35:
                  status = "ECUERROR_INVALIDKEY";
                  break;
                case 0x36:
                  status = "ECUERROR_EXCEEDEDNUMBEROFATTEMPTS";
                  break;
                case 0x37:
                  status = "ECUERROR_REQUIREDTIMEDELAYNOTEXPIRED";
                  break;
                case 0x70:
                  status = "ECUERROR_UPLOADDOWNLOADNOTACCEPTED";
                  break;
                case 0x71:
                  status = "ECUERROR_TRANSFERDATASUSPENDED";
                  break;
                case 0x72:
                  status = "ECUERROR_GENERALPROGRAMMINGFAILURE";
                  break;
                case 0x73:
                  status = "ECUERROR_WRONGBLOCKSEQCOUNTER";
                  break;
                case 0x7E:
                  status = "ECUERROR_SUBFNNOTSUPPORTEDINACTIVESESSION";
                  break;
                case 0x7F:
                  status = "ECUERROR_SERVICENOTSUPPORTEDINACTIVESESSION";
                  break;
                case 0x81:
                  status = "ECUERROR_RPMTOOHIGH";
                  break;
                case 0x82:
                  status = "ECUERROR_RPMTOOLOW";
                  break;
                case 0x83:
                  status = "ECUERROR_ENGINEISRUNNING";
                  break;
                case 0x84:
                  status = "ECUERROR_ENGINEISNOTRUNNING";
                  break;
                case 0x85:
                  status = "ECUERROR_ENGINERUNTIMETOOLOW";
                  break;
                case 0x86:
                  status = "ECUERROR_TEMPTOOHIGH";
                  break;
                case 0x87:
                  status = "ECUERROR_TEMPTOOLOW";
                  break;
                case 0x88:
                  status = "ECUERROR_VEHSPEEDTOOHIGH";
                  break;
                case 0x89:
                  status = "ECUERROR_VEHSPEEDTOOLOW";
                  break;
                case 0x8A:
                  status = "ECUERROR_THROTTLETOOHIGH";
                  break;
                case 0x8B:
                  status = "ECUERROR_THROTTLETOOLOW";
                  break;
                case 0x8C:
                  status = "ECUERROR_TRANSMISSIONRANGENOTINNEUTRAL";
                  break;
                case 0x8D:
                  status = "ECUERROR_TRANSMISSIONRANGENOTINGEAR";
                  break;
                case 0x8F:
                  status = "ECUERROR_BRKPEDALNOTPRESSED";
                  break;
                case 0x90:
                  status = "ECUERROR_SHIFTERLEVERNOTINPARK";
                  break;
                case 0x91:
                  status = "ECUERROR_TRQCONVERTERCLUTCHLOCKED";
                  break;
                case 0x92:
                  status = "ECUERROR_VOLTAGETOOHIGH";
                  break;
                case 0x93:
                  status = "ECUERROR_VOLTAGETOOLOW";
                  break;
                default:
                  status = "ECUERROR_UNKNOWN";
                  break;
              }
            }
          }
          // ── ECU Positive Response ──────────────────────────────────
          else {
            endOfPacket = true;
            int length = frameLen - 2;

            // ✅ FIX: Guard against negative/zero length (e.g. 40 00 00 FF FF)
            if (length <= 0) {
              status = "ECUERROR_NORESPONSEFROMECU";
              dataArray = Uint8List(0);
              firstposdongleackreceived = false;
              break;
            }

            Uint8List responseArray = Uint8List(length);

            val =
                "${byteArrayToHex(responseBytes)}, ${nextPacketIndex + 2}, "
                "${byteArrayToHex(responseArray)}, 0, ${frameLen - 2}";
            developer.log("Array Copy Detail: $val");

            if (halfActualRespons.isNotEmpty) {
              halfActualRespons += byteArrayToHex(responseBytes);
              responseBytes = hexToUint8List(halfActualRespons);
              frameLen = actualLenth;
            }

            // ✅ FIX: Bounds check before reading responseBytes[1]
            if (responseBytes.length < 2) {
              status = "READAGAIN";
              break;
            }

            if ((responseBytes.length - 2) < responseBytes[1]) {
              status = "READAGAIN";
              halfActualRespons = byteArrayToHex(responseBytes);
            } else {
              if (halfActualRespons.isNotEmpty) {
                halfActualRespons = "";
                actualLenth = 0;
              }
              status = "NOERROR";
              for (int j = 0; j < (frameLen - 2); j++) {
                if (nextPacketIndex + 2 + j < responseBytes.length) {
                  responseArray[j] = responseBytes[nextPacketIndex + 2 + j];
                }
              }
              dataArray = responseArray;
            }
          }
        }
        // ── BRANCH D: Unknown / invalid response ──────────────────────
        else {
          status = "GENERALERROR_INVALIDRESPFROMDONGLE";
          firstposdongleackreceived = false;
          endOfPacket = true;
        }
      } // end while
    } catch (ex, stack) {
      dataArray = Uint8List(0);
      status = "$val\n\n${ex.toString()}\n\n${stack.toString()}";
    }

    return {"dataArray": dataArray, "status": status};
  }
  // --- Static Helper Methods ---

  static String byteArrayToHex(Uint8List ba) {
    return ba
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join('')
        .toUpperCase();
  }

  static Uint8List hexToUint8List(String hex) {
    hex = hex.replaceAll(' ', '');
    if (hex.length % 2 != 0) hex = '0$hex';
    return Uint8List.fromList(
      List.generate(
        hex.length ~/ 2,
        (i) => int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16),
      ),
    );
  }

  static Map<String, dynamic> checkResponseIVN(
    Uint8List pidBytesResponse,
    Uint8List requestBytes,
    String reqType1,
  ) {
    Uint8List? dataArray;
    String status = "NOERROR";

    try {
      var responseBytes = pidBytesResponse;
      var request = requestBytes;
      String expectedFrame = "";
      String reqType = "";
      int nextPacketIndex = 0;
      bool endOfPacket = false;
      int frameLen = 0;

      // 1. Determine Expected Frame based on Config Request (0x20)
      if (request[0] == 0x20) {
        switch (request[2]) {
          case 0x01: // Reset Dongle
          case 0x02: // Set Protocol
          case 0x04: // Set Transmit Header
          case 0x06: // Set Receive Header
          case 0x08: // Set Block length
          case 0x0A: // Set separation time
          case 0x0C: // Set Min time
          case 0x0E: // Set Max wait time
          case 0x10: // Tester Present periodic
          case 0x11: // Stop Tester Present
          case 0x12: // Pad transmit
          case 0x13: // Stop padding
          case 0x15: // BT name change
          case 0x17: // Set filters
            expectedFrame = "DONGLECONFIGACK";
            break;
          case 0x03: // Get Protocol
          case 0x05: // Get Transmit Header
          case 0x07: // Get Receive Header
          case 0x09: // Get Block length
          case 0x0B: // Get separation time
          case 0x0D: // Get Min time
          case 0x0F: // Get Max wait time
          case 0x14: // Get firmware version
            expectedFrame = "DONGLECONFIGRESPONSE";
            break;
        }
      }
      // 2. Data Request (0x40)
      else if (request[0] == 0x40) {
        reqType = "DATAREQUEST";
        expectedFrame = "DONGLECONFIGACK";
      }

      nextPacketIndex = 0;
      endOfPacket = false;

      // 3. Main Parser Loop
      while (!endOfPacket) {
        // Safety range check
        if (nextPacketIndex >= responseBytes.length) {
          endOfPacket = true;
          break;
        }

        // Dongle Response Header (0x20)
        if (responseBytes[nextPacketIndex] == 0x20) {
          frameLen = responseBytes[nextPacketIndex + 1];

          if (reqType == "CONFIGREQUEST") {
            endOfPacket = true;
            if (expectedFrame == "DONGLECONFIGRESPONSE") {
              int length = frameLen - 2;
              dataArray = responseBytes.sublist(
                nextPacketIndex + 3,
                nextPacketIndex + 3 + length,
              );
            }
          }
          // Positive Dongle Ack (0x03)
          else if (responseBytes[nextPacketIndex + 1] == 0x03) {
            if (firstposdongleackreceived == true) {
              firstposdongleackreceived = false;
              endOfPacket = true;
              status = "NOERROR";
              // log: Jugaad - second positive ack
              break;
            }

            nextPacketIndex += 5;
            firstposdongleackreceived = true;

            if (nextPacketIndex < responseBytes.length) {
              endOfPacket = false;
            } else {
              status = "READAGAIN";
              endOfPacket = true;
              break;
            }
          }
          // Negative Dongle Ack
          else {
            endOfPacket = true;
            firstposdongleackreceived = false;
            switch (responseBytes[3]) {
              case 0x10:
                status = "DONGLEERROR_COMMANDNOTSUPPORTED";
                break;
              case 0x12:
                status = "DONGLEERROR_INPUTNOTSUPPORTED";
                break;
              case 0x13:
                status = "DONGLEERROR_INVALIDFORMAT";
                break;
              case 0x14:
                status = "DONGLEERROR_INVALIDOPERATION";
                break;
              case 0x15:
                status = "DONGLEERROR_CRCFAILURE";
                break;
              case 0x16:
                status = "DONGLEERROR_PROTOCOLNOTSET";
                break;
              case 0x33:
                status = "DONGLEERROR_SECURITYACCESSDENIED";
                break;
            }
            status = "SENDAGAIN";
          }
        }
        // ECU Timeout (0x40 0x02)
        else if (((responseBytes[nextPacketIndex] & 0xF0) == 0x40) &&
            (responseBytes[nextPacketIndex + 1] == 0x02)) {
          status = "ECUERROR_NORESPONSEFROMECU";
          endOfPacket = true;
          firstposdongleackreceived = false;
          break;
        }
        // ECU Data Frame (0x4X)
        else if ((responseBytes[nextPacketIndex] & 0xF0) == 0x40) {
          firstposdongleackreceived = false;
          int msgLen =
              ((responseBytes[nextPacketIndex] & 0x0F) << 8) +
              responseBytes[nextPacketIndex + 1];
          frameLen = msgLen;

          // ECU Negative Response (7F)
          if (responseBytes[nextPacketIndex + 2] == 0x7F) {
            if (responseBytes[nextPacketIndex + 4] == 0x78) {
              nextPacketIndex += 7;
              endOfPacket = false;
              if (nextPacketIndex > responseBytes.length - 1) {
                status = "READAGAIN";
                endOfPacket = true;
                break;
              }
            } else {
              endOfPacket = true;
              int nrc = responseBytes[nextPacketIndex + 4];
              // Map ECU NRC codes
              switch (nrc) {
                case 0x10:
                  status = "ECUERROR_GENERALREJECT";
                  break;
                case 0x11:
                  status = "ECUERROR_SERVICENOTSUPPO0RTED";
                  break;
                case 0x12:
                  status = "ECUERROR_SUBFUNCTIONNOTSUPPORTED";
                  break;
                case 0x13:
                  status = "ECUERROR_INVALIDFORMAT";
                  break;
                case 0x14:
                  status = "ECUERROR_RESPONSETOOLONG";
                  break;
                case 0x21:
                  status = "ECUERROR_BUSYREPEATREQUEST";
                  break;
                case 0x22:
                  status = "ECUERROR_CONDITIONSNOTCORRECT";
                  break;
                case 0x24:
                  status = "ECUERROR_REQUESTSEQUENCEERROR";
                  break;
                case 0x31:
                  status = "ECUERROR_REQUESTOUTOFRANGE";
                  break;
                case 0x33:
                  status = "ECUERROR_SECURITYACCESSDENIED";
                  break;
                case 0x35:
                  status = "ECUERROR_INVALIDKEY";
                  break;
                case 0x36:
                  status = "ECUERROR_EXCEEDEDNUMBEROFATTEMPTS";
                  break;
                case 0x37:
                  status = "ECUERROR_REQUIREDTIMEDELAYNOTEXPIRED";
                  break;
                case 0x70:
                  status = "ECUERROR_UPLOADDOWNLOADNOTACCEPTED";
                  break;
                case 0x71:
                  status = "ECUERROR_TRANSFERDATASUSPENDED";
                  break;
                case 0x72:
                  status = "ECUERROR_GENERALPROGRAMMINGFAILURE";
                  break;
                case 0x73:
                  status = "ECUERROR_WRONGBLOCKSEQCOUNTER";
                  break;
                case 0x7E:
                  status = "ECUERROR_SUBFNNOTSUPPORTEDINACTIVESESSION";
                  break;
                case 0x7F:
                  status = "ECUERROR_SERVICENOTSUPPORTEDINACTIVESESSION";
                  break;
                case 0x81:
                  status = "ECUERROR_RPMTOOHIGH";
                  break;
                case 0x82:
                  status = "ECUERROR_RPMTOOLOW";
                  break;
                case 0x83:
                  status = "ECUERROR_ENGINEISRUNNING";
                  break;
                case 0x84:
                  status = "ECUERROR_ENGINEISNOTRUNNING";
                  break;
                case 0x85:
                  status = "ECUERROR_ENGINERUNTIMETOOLOW";
                  break;
                case 0x86:
                  status = "ECUERROR_TEMPTOOHIGH";
                  break;
                case 0x87:
                  status = "ECUERROR_TEMPTOOLOW";
                  break;
                case 0x88:
                  status = "ECUERROR_VEHSPEEDTOOHIGH";
                  break;
                case 0x89:
                  status = "ECUERROR_VEHSPEEDTOOLOW";
                  break;
                case 0x8A:
                  status = "ECUERROR_THROTTLETOOHIGH";
                  break;
                case 0x8B:
                  status = "ECUERROR_THROTTLETOOLOW";
                  break;
                case 0x8C:
                  status = "ECUERROR_TRANSMISSIONRANGENOTINNEUTRAL";
                  break;
                case 0x8D:
                  status = "ECUERROR_TRANSMISSIONRANGENOTINGEAR";
                  break;
                case 0x8F:
                  status = "ECUERROR_BRKPEDALNOTPRESSED";
                  break;
                case 0x90:
                  status = "ECUERROR_SHIFTERLEVERNOTINPARK";
                  break;
                case 0x91:
                  status = "ECUERROR_TRQCONVERTERCLUTCHLOCKED";
                  break;
                case 0x92:
                  status = "ECUERROR_VOLTAGETOOHIGH";
                  break;
                case 0x93:
                  status = "ECUERROR_VOLTAGETOOLOW";
                  break;
              }
            }
          }
          // ECU Positive Response
          else {
            endOfPacket = true;
            int length = frameLen - 2;
            Uint8List responseArray = Uint8List(length);

            // Debug string construction
            val =
                "${byteArrayToHex(responseBytes)}, $nextPacketIndex, ${byteArrayToHex(responseArray)}, $frameLen";

            // Array.Copy(responseBytes, nextPacketIndex + 2, responseArray, 0, framelen - 2);
            responseArray.setRange(
              0,
              length,
              responseBytes.sublist(
                nextPacketIndex + 2,
                nextPacketIndex + 2 + length,
              ),
            );
            dataArray = responseArray;
          }
        } else {
          status = "GENERALERROR_INVALIDRESPFROMDONGLE";
          firstposdongleackreceived = false;
          endOfPacket = true;
        }
      }
    } catch (ex, stack) {
      dataArray = null;
      status = "$val\n\n${ex.toString()}\n\n${stack.toString()}";
    }

    return {"dataArray": dataArray, "status": status};
  }

  static Map<String, dynamic> checkResponseIVNwithChannel(
    Uint8List pidBytesResponse,
    Uint8List requestBytes,
    String reqType1,
  ) {
    Uint8List? dataArray;
    String status = "NOERROR";

    try {
      var responseBytes = pidBytesResponse;
      var request = requestBytes;
      String expectedFrame = "";
      String reqType = "";
      int nextPacketIndex = 0;
      bool endOfPacket = false;
      int frameLen = 0;

      // 1. Determine Expected Frame (Note: checking index [3] for Channel protocol)
      if (request[0] == 0x20) {
        switch (request[3]) {
          case 0x01: // Reset
          case 0x02: // Set Protocol
          case 0x04: // Set Tx Header
          case 0x06: // Set Rx Header
          case 0x08: // Block length
          case 0x0A: // Sep time
          case 0x0C: // Min time
          case 0x0E: // Max wait
          case 0x10: // Tester Present
          case 0x11: // Stop Tester Present
          case 0x12: // Pad
          case 0x13: // Stop Pad
          case 0x15: // BT Change
          case 0x17: // Filters
            expectedFrame = "DONGLECONFIGACK";
            break;
          case 0x03: // Get Protocol
          case 0x05: // Get Tx Header
          case 0x07: // Get Rx Header
          case 0x09: // Get Block Len
          case 0x0B: // Get Sep Time
          case 0x0D: // Get Min Time
          case 0x0F: // Get Max Wait
          case 0x14: // Get Firmware
            expectedFrame = "DONGLECONFIGRESPONSE";
            break;
        }
      } else if (request[0] == 0x40) {
        reqType = "DATAREQUEST";
        expectedFrame = "DONGLECONFIGACK";
      }

      nextPacketIndex = 0;
      endOfPacket = false;

      // 2. Main Parser Loop
      while (!endOfPacket) {
        if (nextPacketIndex >= responseBytes.length) {
          endOfPacket = true;
          break;
        }

        // Dongle Response Header (0x20)
        if (responseBytes[nextPacketIndex] == 0x20) {
          frameLen = responseBytes[nextPacketIndex + 1];

          if (reqType == "CONFIGREQUEST") {
            endOfPacket = true;
            if (expectedFrame == "DONGLECONFIGRESPONSE") {
              // Copy data starting from index 4
              dataArray = responseBytes.sublist(
                nextPacketIndex + 4,
                nextPacketIndex + 4 + frameLen,
              );
            }
          }
          // Positive Dongle Ack (0x01 for Channel variants)
          else if (responseBytes[nextPacketIndex + 1] == 0x01) {
            if (firstposdongleackreceived == true) {
              firstposdongleackreceived = false;
              endOfPacket = true;
              status = "NOERROR";
              break;
            }

            nextPacketIndex += 6; // Offset for channel data
            firstposdongleackreceived = true;

            if (nextPacketIndex < responseBytes.length) {
              endOfPacket = false;
            } else {
              status = "READAGAIN";
              endOfPacket = true;
              break;
            }
          } else {
            // Negative Dongle Ack
            endOfPacket = true;
            firstposdongleackreceived = false;
            switch (responseBytes[4]) {
              case 0x10:
                status = "DONGLEERROR_COMMANDNOTSUPPORTED";
                break;
              case 0x12:
                status = "DONGLEERROR_INPUTNOTSUPPORTED";
                break;
              case 0x13:
                status = "DONGLEERROR_INVALIDFORMAT";
                break;
              case 0x14:
                status = "DONGLEERROR_INVALIDOPERATION";
                break;
              case 0x15:
                status = "DONGLEERROR_CRCFAILURE";
                break;
              case 0x16:
                status = "DONGLEERROR_PROTOCOLNOTSET";
                break;
              case 0x33:
                status = "DONGLEERROR_SECURITYACCESSDENIED";
                break;
            }
            status = "SENDAGAIN";
          }
        }
        // ECU Timeout (0x40 0x00)
        else if (((responseBytes[nextPacketIndex] & 0xF0) == 0x40) &&
            (responseBytes[nextPacketIndex + 1] == 0x00)) {
          status = "ECUERROR_NORESPONSEFROMECU";
          endOfPacket = true;
          firstposdongleackreceived = false;
          break;
        }
        // ECU Data Frame (starts with 4X)
        else if ((responseBytes[nextPacketIndex] & 0xF0) == 0x40) {
          firstposdongleackreceived = false;
          int msgLen =
              ((responseBytes[nextPacketIndex] & 0x0F) << 8) +
              responseBytes[nextPacketIndex + 1];
          frameLen = msgLen;

          // ECU Negative Response (7F at index 3 for Channel logic)
          if (responseBytes[nextPacketIndex + 3] == 0x7F) {
            if (responseBytes[nextPacketIndex + 5] == 0x78) {
              nextPacketIndex += 8; // Skip pending frame
              endOfPacket = false;
              if (nextPacketIndex > responseBytes.length - 1) {
                status = "READAGAIN";
                endOfPacket = true;
                break;
              }
            } else {
              endOfPacket = true;
              int nrc = responseBytes[nextPacketIndex + 5];
              // Map ECU NRC codes
              switch (nrc) {
                case 0x10:
                  status = "ECUERROR_GENERALREJECT";
                  break;
                case 0x11:
                  status = "ECUERROR_SERVICENOTSUPPO0RTED";
                  break;
                case 0x12:
                  status = "ECUERROR_SUBFUNCTIONNOTSUPPORTED";
                  break;
                case 0x13:
                  status = "ECUERROR_INVALIDFORMAT";
                  break;
                case 0x14:
                  status = "ECUERROR_RESPONSETOOLONG";
                  break;
                case 0x21:
                  status = "ECUERROR_BUSYREPEATREQUEST";
                  break;
                case 0x22:
                  status = "ECUERROR_CONDITIONSNOTCORRECT";
                  break;
                case 0x24:
                  status = "ECUERROR_REQUESTSEQUENCEERROR";
                  break;
                case 0x31:
                  status = "ECUERROR_REQUESTOUTOFRANGE";
                  break;
                case 0x33:
                  status = "ECUERROR_SECURITYACCESSDENIED";
                  break;
                case 0x35:
                  status = "ECUERROR_INVALIDKEY";
                  break;
                case 0x36:
                  status = "ECUERROR_EXCEEDEDNUMBEROFATTEMPTS";
                  break;
                case 0x37:
                  status = "ECUERROR_REQUIREDTIMEDELAYNOTEXPIRED";
                  break;
                case 0x70:
                  status = "ECUERROR_UPLOADDOWNLOADNOTACCEPTED";
                  break;
                case 0x71:
                  status = "ECUERROR_TRANSFERDATASUSPENDED";
                  break;
                case 0x72:
                  status = "ECUERROR_GENERALPROGRAMMINGFAILURE";
                  break;
                case 0x73:
                  status = "ECUERROR_WRONGBLOCKSEQCOUNTER";
                  break;
                case 0x7E:
                  status = "ECUERROR_SUBFNNOTSUPPORTEDINACTIVESESSION";
                  break;
                case 0x7F:
                  status = "ECUERROR_SERVICENOTSUPPORTEDINACTIVESESSION";
                  break;
                case 0x81:
                  status = "ECUERROR_RPMTOOHIGH";
                  break;
                case 0x82:
                  status = "ECUERROR_RPMTOOLOW";
                  break;
                case 0x83:
                  status = "ECUERROR_ENGINEISRUNNING";
                  break;
                case 0x84:
                  status = "ECUERROR_ENGINEISNOTRUNNING";
                  break;
                case 0x85:
                  status = "ECUERROR_ENGINERUNTIMETOOLOW";
                  break;
                case 0x86:
                  status = "ECUERROR_TEMPTOOHIGH";
                  break;
                case 0x87:
                  status = "ECUERROR_TEMPTOOLOW";
                  break;
                case 0x88:
                  status = "ECUERROR_VEHSPEEDTOOHIGH";
                  break;
                case 0x89:
                  status = "ECUERROR_VEHSPEEDTOOLOW";
                  break;
                case 0x8A:
                  status = "ECUERROR_THROTTLETOOHIGH";
                  break;
                case 0x8B:
                  status = "ECUERROR_THROTTLETOOLOW";
                  break;
                case 0x8C:
                  status = "ECUERROR_TRANSMISSIONRANGENOTINNEUTRAL";
                  break;
                case 0x8D:
                  status = "ECUERROR_TRANSMISSIONRANGENOTINGEAR";
                  break;
                case 0x8F:
                  status = "ECUERROR_BRKPEDALNOTPRESSED";
                  break;
                case 0x90:
                  status = "ECUERROR_SHIFTERLEVERNOTINPARK";
                  break;
                case 0x91:
                  status = "ECUERROR_TRQCONVERTERCLUTCHLOCKED";
                  break;
                case 0x92:
                  status = "ECUERROR_VOLTAGETOOHIGH";
                  break;
                case 0x93:
                  status = "ECUERROR_VOLTAGETOOLOW";
                  break;
              }
            }
          }
          // ECU Positive Response
          else {
            endOfPacket = true;
            // Build debug string (val)
            val =
                "${byteArrayToHex(responseBytes)}, $nextPacketIndex, ..., $frameLen";

            // Replicate Array.Copy(responeBytes, nextpacketindex + 3, responseArray, 0, framelen);
            dataArray = responseBytes.sublist(
              nextPacketIndex + 3,
              nextPacketIndex + 3 + frameLen,
            );
          }
        } else {
          status = "GENERALERROR_INVALIDRESPFROMDONGLE";
          firstposdongleackreceived = false;
          endOfPacket = true;
        }
      }
    } catch (ex, stack) {
      dataArray = null;
      status = "$val\n\n${ex.toString()}\n\n${stack.toString()}";
    }

    return {"dataArray": dataArray, "status": status};
  }

  static Map<String, dynamic> checkResponseWithChannel(
    Uint8List pidBytesResponse,
    Uint8List requestBytes,
  ) {
    Uint8List? dataArray = pidBytesResponse;
    String status = "NOERROR";

    try {
      var responseBytes = pidBytesResponse;
      var request = requestBytes;
      String expectedFrame = "";
      String reqType = "";
      int nextPacketIndex = 0;
      bool endOfPacket = false;
      int frameLen = 0;

      // 1. Logic for CONFIGREQUEST based on request[3] (Channel offset)
      if (request[0] == 0x20) {
        reqType = "CONFIGREQUEST";
        switch (request[3]) {
          case 0x01: // Reset Dongle
          case 0x02: // Set Protocol
          case 0x04: // Set Transmit Header
          case 0x06: // Set Receive Header
          case 0x08: // Set Block length
          case 0x0A: // Set separation time
          case 0x0C: // Set Min time
          case 0x0E: // Set Max wait time
          case 0x10: // Periodic tester present
          case 0x11: // Stop periodic tester present
          case 0x12: // Pad transmit
          case 0x13: // Stop padding
          case 0x15: // BT name change
          case 0x17: // Set filters
            expectedFrame = "DONGLECONFIGACK";
            break;
          case 0x03: // Get Protocol
          case 0x05: // Get Transmit Header
          case 0x07: // Get Receive Header
          case 0x09: // Get Block length
          case 0x0B: // Get separation time
          case 0x0D: // Get Min time
          case 0x0F: // Get Max wait time
          case 0x14: // Get firmware version
            expectedFrame = "DONGLECONFIGRESPONSE";
            break;
        }
      } else if (request[0] == 0x40) {
        reqType = "DATAREQUEST";
        expectedFrame = "DONGLECONFIGACK";
      }

      nextPacketIndex = 0;
      endOfPacket = false;

      // 2. Main Parser Loop
      while (!endOfPacket) {
        // Range check to prevent out of bounds
        if (nextPacketIndex >= responseBytes.length) {
          endOfPacket = true;
          break;
        }

        // --- Dongle Response Header (0x20) ---
        if (responseBytes[nextPacketIndex] == 0x20) {
          frameLen = responseBytes[nextPacketIndex + 1];

          if (reqType == "CONFIGREQUEST") {
            endOfPacket = true;
            if (expectedFrame == "DONGLECONFIGRESPONSE") {
              // Copy from index 4
              dataArray = responseBytes.sublist(
                nextPacketIndex + 4,
                nextPacketIndex + 4 + frameLen,
              );
            }
          }
          // Positive Ack (0x01 for Channel variants)
          else if (responseBytes[nextPacketIndex + 1] == 0x01) {
            if (firstposdongleackreceived == true) {
              firstposdongleackreceived = false;
              endOfPacket = true;
              status = "NOERROR";
              developer.log(
                "------ Jugaad - Getting positive dongle ack frame second time -------",
              );
              break;
            }

            nextPacketIndex += 6;
            firstposdongleackreceived = true;

            if (nextPacketIndex < responseBytes.length) {
              endOfPacket = false;
            } else {
              status = "READAGAIN";
              endOfPacket = true;
              break;
            }
          }
          // Negative Dongle Ack
          else {
            endOfPacket = true;
            firstposdongleackreceived = false;
            switch (responseBytes[4]) {
              case 0x10:
                status = "DONGLEERROR_COMMANDNOTSUPPORTED";
                break;
              case 0x12:
                status = "DONGLEERROR_INPUTNOTSUPPORTED";
                break;
              case 0x13:
                status = "DONGLEERROR_INVALIDFORMAT";
                break;
              case 0x14:
                status = "DONGLEERROR_INVALIDOPERATION";
                break;
              case 0x15:
                status = "DONGLEERROR_CRCFAILURE";
                break;
              case 0x16:
                status = "DONGLEERROR_PROTOCOLNOTSET";
                break;
              case 0x33:
                status = "DONGLEERROR_SECURITYACCESSDENIED";
                break;
            }
          }
        }
        // --- ECU Timeout (0x40 0x00) ---
        else if (((responseBytes[nextPacketIndex] & 0xF0) == 0x40) &&
            (responseBytes[nextPacketIndex + 1] == 0x00)) {
          status = "ECUERROR_NORESPONSEFROMECU";
          endOfPacket = true;
          firstposdongleackreceived = false;
          break;
        }
        // --- ECU Data Frame (4X) ---
        else if (((responseBytes[nextPacketIndex] & 0xF0) == 0x40) ||
            halfActualRespons.isNotEmpty) {
          firstposdongleackreceived = false;

          // Compute msg length (mask 0x0F shift 8 + next byte)
          int msgLen =
              ((responseBytes[nextPacketIndex] & 0x0F) << 8) +
              responseBytes[nextPacketIndex + 1];
          frameLen = msgLen;

          if (halfActualRespons.isEmpty) {
            actualLenth = msgLen;
          }

          // Check for ECU Negative Response (7F at index 3 for Channel)
          if (responseBytes[nextPacketIndex + 3] == 0x7F) {
            if (responseBytes[nextPacketIndex + 5] == 0x78) {
              nextPacketIndex += 8;
              endOfPacket = false;
              if (nextPacketIndex > responseBytes.length - 1) {
                status = "READAGAIN";
                endOfPacket = true;
                break;
              }
            } else {
              endOfPacket = true;
              int nrc = responseBytes[nextPacketIndex + 5];
              // Map standard UDS NRC codes
              switch (nrc) {
                case 0x10:
                  status = "ECUERROR_GENERALREJECT";
                  break;
                case 0x11:
                  status = "ECUERROR_SERVICENOTSUPPORTED";
                  break;
                case 0x12:
                  status = "ECUERROR_SUBFUNCTIONNOTSUPPORTED";
                  break;
                case 0x13:
                  status = "ECUERROR_INVALIDFORMAT";
                  break;
                case 0x14:
                  status = "ECUERROR_RESPONSETOOLONG";
                  break;
                case 0x21:
                  status = "ECUERROR_BUSYREPEATREQUEST";
                  break;
                case 0x22:
                  status = "ECUERROR_CONDITIONSNOTCORRECT";
                  break;
                case 0x24:
                  status = "ECUERROR_REQUESTSEQUENCEERROR";
                  break;
                case 0x31:
                  status = "ECUERROR_REQUESTOUTOFRANGE";
                  break;
                case 0x33:
                  status = "ECUERROR_SECURITYACCESSDENIED";
                  break;
                case 0x35:
                  status = "ECUERROR_INVALIDKEY";
                  break;
                case 0x36:
                  status = "ECUERROR_EXCEEDEDNUMBEROFATTEMPTS";
                  break;
                case 0x37:
                  status = "ECUERROR_REQUIREDTIMEDELAYNOTEXPIRED";
                  break;
                case 0x70:
                  status = "ECUERROR_UPLOADDOWNLOADNOTACCEPTED";
                  break;
                case 0x71:
                  status = "ECUERROR_TRANSFERDATASUSPENDED";
                  break;
                case 0x72:
                  status = "ECUERROR_GENERALPROGRAMMINGFAILURE";
                  break;
                case 0x73:
                  status = "ECUERROR_WRONGBLOCKSEQCOUNTER";
                  break;
                case 0x7E:
                  status = "ECUERROR_SUBFNNOTSUPPORTEDINACTIVESESSION";
                  break;
                case 0x7F:
                  status = "ECUERROR_SERVICENOTSUPPORTEDINACTIVESESSION";
                  break;
                case 0x81:
                  status = "ECUERROR_RPMTOOHIGH";
                  break;
                case 0x82:
                  status = "ECUERROR_RPMTOOLOW";
                  break;
                case 0x83:
                  status = "ECUERROR_ENGINEISRUNNING";
                  break;
                case 0x84:
                  status = "ECUERROR_ENGINEISNOTRUNNING";
                  break;
                case 0x85:
                  status = "ECUERROR_ENGINERUNTIMETOOLOW";
                  break;
                case 0x86:
                  status = "ECUERROR_TEMPTOOHIGH";
                  break;
                case 0x87:
                  status = "ECUERROR_TEMPTOOLOW";
                  break;
                case 0x88:
                  status = "ECUERROR_VEHSPEEDTOOHIGH";
                  break;
                case 0x89:
                  status = "ECUERROR_VEHSPEEDTOOLOW";
                  break;
                case 0x8A:
                  status = "ECUERROR_THROTTLETOOHIGH";
                  break;
                case 0x8B:
                  status = "ECUERROR_THROTTLETOOLOW";
                  break;
                case 0x8C:
                  status = "ECUERROR_TRANSMISSIONRANGENOTINNEUTRAL";
                  break;
                case 0x8D:
                  status = "ECUERROR_TRANSMISSIONRANGENOTINGEAR";
                  break;
                case 0x8F:
                  status = "ECUERROR_BRKPEDALNOTPRESSED";
                  break;
                case 0x90:
                  status = "ECUERROR_SHIFTERLEVERNOTINPARK";
                  break;
                case 0x91:
                  status = "ECUERROR_TRQCONVERTERCLUTCHLOCKED";
                  break;
                case 0x92:
                  status = "ECUERROR_VOLTAGETOOHIGH";
                  break;
                case 0x93:
                  status = "ECUERROR_VOLTAGETOOLOW";
                  break;
              }
            }
          }
          // --- Positive ECU Response (Data Extraction) ---
          else {
            endOfPacket = true;

            val =
                "${byteArrayToHex(responseBytes)}, ${nextPacketIndex + 3}, ..., $frameLen";
            developer.log("Array Copy Detail: $val");

            if (halfActualRespons.isNotEmpty) {
              halfActualRespons += byteArrayToHex(responseBytes);
              responseBytes = hexToUint8List(halfActualRespons);
              frameLen = actualLenth;
            }

            // Check if buffer is complete (5 bytes header/checksum logic)
            if ((responseBytes.length - 5) < responseBytes[1]) {
              status = "READAGAIN";
              halfActualRespons = byteArrayToHex(responseBytes);
            } else {
              if (halfActualRespons.isNotEmpty) {
                halfActualRespons = "";
                actualLenth = 0;
              }
              status = "NOERROR";
              // Copy data starting from index 3
              dataArray = responseBytes.sublist(
                nextPacketIndex + 3,
                nextPacketIndex + 3 + frameLen,
              );
            }
          }
        } else {
          status = "GENERALERROR_INVALIDRESPFROMDONGLE";
          firstposdongleackreceived = false;
          endOfPacket = true;
        }
      }
    } catch (ex, stack) {
      dataArray = null;
      status = "$val\n\n${ex.toString()}\n\n${stack.toString()}";
    }

    return {"dataArray": dataArray, "status": status};
  }

  static Map<String, dynamic> checkResponseRP1210(
    Uint8List pidBytesResponse,
    Uint8List requestBytes,
  ) {
    Uint8List? dataArray = pidBytesResponse;
    String status = "NOERROR";

    try {
      var responseBytes = pidBytesResponse;
      var request = requestBytes;
      int nextPacketIndex = 0;
      bool endOfPacket = false;

      while (endOfPacket == false) {
        if (responseBytes[nextPacketIndex] == 0x7F) {
          if (responseBytes[nextPacketIndex + 2] == 0x78) {
            // read next packet
            nextPacketIndex += 7;
            endOfPacket = false;

            if (nextPacketIndex > responseBytes.length - 1) {
              status = "READAGAIN";
              endOfPacket = true;
              break;
            }
          } else {
            endOfPacket = true;

            // ECU negative response
            switch (responseBytes[nextPacketIndex + 2]) {
              case 0x10:
                status = "ECUERROR_GENERALREJECT";
                break;
              case 0x11:
                status = "ECUERROR_SERVICENOTSUPPORTED";
                break;
              case 0x12:
                status = "ECUERROR_SUBFUNCTIONNOTSUPPORTED";
                break;
              case 0x13:
                status = "ECUERROR_INVALIDFORMAT";
                break;
              case 0x14:
                status = "ECUERROR_RESPONSETOOLONG";
                break;
              case 0x21:
                status = "ECUERROR_BUSYREPEATREQUEST";
                break;
              case 0x22:
                status = "ECUERROR_CONDITIONSNOTCORRECT";
                break;
              case 0x24:
                status = "ECUERROR_REQUESTSEQUENCEERROR";
                break;
              case 0x31:
                status = "ECUERROR_REQUESTOUTOFRANGE";
                break;
              case 0x33:
                status = "ECUERROR_SECURITYACCESSDENIED";
                break;
              case 0x35:
                status = "ECUERROR_INVALIDKEY";
                break;
              case 0x36:
                status = "ECUERROR_EXCEEDEDNUMBEROFATTEMPTS";
                break;
              case 0x37:
                status = "ECUERROR_REQUIREDTIMEDELAYNOTEXPIRED";
                break;
              case 0x70:
                status = "ECUERROR_UPLOADDOWNLOADNOTACCEPTED";
                break;
              case 0x71:
                status = "ECUERROR_TRANSFERDATASUSPENDED";
                break;
              case 0x72:
                status = "ECUERROR_GENERALPROGRAMMINGFAILURE";
                break;
              case 0x73:
                status = "ECUERROR_WRONGBLOCKSEQCOUNTER";
                break;
              case 0x7E:
                status = "ECUERROR_SUBFNNOTSUPPORTEDINACTIVESESSION";
                break;
              case 0x7F:
                status = "ECUERROR_SERVICENOTSUPPORTEDINACTIVESESSION";
                break;
              case 0x81:
                status = "ECUERROR_RPMTOOHIGH";
                break;
              case 0x82:
                status = "ECUERROR_RPMTOOLOW";
                break;
              case 0x83:
                status = "ECUERROR_ENGINEISRUNNING";
                break;
              case 0x84:
                status = "ECUERROR_ENGINEISNOTRUNNING";
                break;
              case 0x85:
                status = "ECUERROR_ENGINERUNTIMETOOLOW";
                break;
              case 0x86:
                status = "ECUERROR_TEMPTOOHIGH";
                break;
              case 0x87:
                status = "ECUERROR_TEMPTOOLOW";
                break;
              case 0x88:
                status = "ECUERROR_VEHSPEEDTOOHIGH";
                break;
              case 0x89:
                status = "ECUERROR_VEHSPEEDTOOLOW";
                break;
              case 0x8A:
                status = "ECUERROR_THROTTLETOOHIGH";
                break;
              case 0x8B:
                status = "ECUERROR_THROTTLETOOLOW";
                break;
              case 0x8C:
                status = "ECUERROR_TRANSMISSIONRANGENOTINNEUTRAL";
                break;
              case 0x8D:
                status = "ECUERROR_TRANSMISSIONRANGENOTINGEAR";
                break;
              case 0x8F:
                status = "ECUERROR_BRKPEDALNOTPRESSED";
                break;
              case 0x90:
                status = "ECUERROR_SHIFTERLEVERNOTINPARK";
                break;
              case 0x91:
                status = "ECUERROR_TRQCONVERTERCLUTCHLOCKED";
                break;
              case 0x92:
                status = "ECUERROR_VOLTAGETOOHIGH";
                break;
              case 0x93:
                status = "ECUERROR_VOLTAGETOOLOW";
                break;
            }

            // Array.Copy(responeBytes, nextpacketindex, dataArray, 0, 3)
            dataArray = Uint8List(3);
            for (int i = 0; i < 3; i++) {
              dataArray[i] = responseBytes[nextPacketIndex + i];
            }
          }
        } else {
          int respFirstByte = responseBytes[0];
          int reqFirstByte = request[0];

          if (respFirstByte == reqFirstByte + 0x40) {
            status = "NOERROR";
            endOfPacket = true;
          } else {
            if (respFirstByte == 0x01) {
              status = "ECUERROR_NORESPONSEFROMECU";
            } else {
              status = "READAGAIN";
            }
            endOfPacket = true;
          }
        }
      }
    } catch (ex, stack) {
      dataArray = null;
      status = "\n${ex.toString()}\n\n${stack.toString()}";
    }

    return {"dataArray": dataArray, "status": status};
  }
}
