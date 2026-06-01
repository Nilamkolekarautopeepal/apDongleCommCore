abstract class IDongleHandler {
  Future<dynamic> dongleReset();

  Future<dynamic> dongleSetProtocol(int protocol);

  Future<dynamic> dongleGetProtocol();

  Future<dynamic> dongleGetFirmwareVersion();
}