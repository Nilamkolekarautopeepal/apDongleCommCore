import 'package:ap_dongle_commcore/model/responseArrayStatusModel.dart';

abstract class ICANCommands {
  Future<dynamic> canSetTxHeader(String txHeader);

  Future<dynamic> canSetRxHeaderMask(String txHeaderMask);

  Future<dynamic> canGetRxHeaderMask();

  Future<dynamic> canSetP1Min(String p1min);

  Future<dynamic> canGetP1Min();

  Future<dynamic> canSetP2Max(String p2max);

  Future<dynamic> canGetP2Max();

  Future<dynamic> canStartTp();

  Future<dynamic> canStopTp();

  Future<dynamic> canStartPadding(String padding);

  Future<dynamic> canStopPadding();

  Future<dynamic> canTxData(String txData);

  Future<ResponseArrayStatus> canTxRx(int frameLength, String txData);

  Future<dynamic> setBlkSeqCntr(String blkLen);

  Future<dynamic> getBlkSeqCntr();

  Future<dynamic> setSepTime(String sepTime);

  Future<dynamic> getSepTime();
}