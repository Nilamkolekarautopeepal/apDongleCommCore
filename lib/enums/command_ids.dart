// lib/src/enums/command_ids.dart

enum DWCommandId {
  none(0x00),
  clientConnect(0x01),
  clientDisconnect(0x02),
  sendMessage(0x03),
  readMessage(0x04),
  readVersion(0x05),
  sendCommand(0x06),
  doipSendMessage(0x09),
  doipReadMessage(0x0A);

  final int value;
  const DWCommandId(this.value);

  static DWCommandId fromValue(int val) {
    return DWCommandId.values.firstWhere(
      (e) => e.value == val,
      orElse: () => DWCommandId.none,
    );
  }
}

enum SubCommandId {
  setMsgFilter(0x09),
  setFlowControl(0x22),
  setDeviceIp(0x32),
  setEcuIp(0x33),
  setTesterPresent(0x65),
  stopTesterPresent(0x66);

  final int value;
  const SubCommandId(this.value);
}

enum DoipMsgType {
  routineActivationReq(0x0005),
  routineActivationResp(0x0006),
  diagnosticMsg(0x8001),
  diagnosticMsgAck(0x8002),
  diagnosticMsgNack(0x8003),
  unknown(0x0000);

  final int value;
  const DoipMsgType(this.value);

  static DoipMsgType fromValue(int val) {
    return DoipMsgType.values.firstWhere(
      (e) => e.value == val,
      orElse: () => DoipMsgType.unknown,
    );
  }
}
