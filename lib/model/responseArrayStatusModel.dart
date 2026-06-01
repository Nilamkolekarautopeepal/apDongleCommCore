import 'dart:typed_data';

class ResponseArrayStatus {
  String? ecuResponseStatus;
  Uint8List? ecuResponse;
  Uint8List? actualDataBytes;
  Uint8List? sentBytes;

  ResponseArrayStatus({
    this.ecuResponseStatus,
    this.ecuResponse,
    this.actualDataBytes,
    this.sentBytes,
  });

  Map<String, dynamic> toJson() {
    return {
      "ecuResponseStatus": ecuResponseStatus,
      "ecuResponse": ecuResponse?.map((e) => e.toRadixString(16).padLeft(2, '0')).join(),
      "actualDataBytes": actualDataBytes?.map((e) => e.toRadixString(16).padLeft(2, '0')).join(),
      "sentBytes": sentBytes?.map((e) => e.toRadixString(16).padLeft(2, '0')).join(),
    };
  }
}

class IvnResponseArrayStatus {
  String? frame;
  String? ecuResponseStatus;
  Uint8List? ecuResponse;
  Uint8List? actualDataBytes;

  IvnResponseArrayStatus({
    this.frame,
    this.ecuResponseStatus,
    this.ecuResponse,
    this.actualDataBytes,
  });
}

// Note the lowercase 'i' here to match your C# namespace call
class ResponseArrayStatusIvn {
  String? ecuResponseStatus;
  Uint8List? actualFrameBytes;

  ResponseArrayStatusIvn({
    this.ecuResponseStatus,
    this.actualFrameBytes,
  });
}