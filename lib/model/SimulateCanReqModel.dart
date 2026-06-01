class SimulateCanReqModel {
  String? request;

  SimulateCanReqModel({
    this.request,
  });

  factory SimulateCanReqModel.fromJson(Map<String, dynamic> json) {
    return SimulateCanReqModel(
      request: json['request'],
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'request': request,
    };
  }
}

class SimulateCanRespModel {
  String? request;
  String? response;
  int? currentCount;
  String? error;

  SimulateCanRespModel({
    this.request,
    this.response,
    this.currentCount,
    this.error,
  });

  factory SimulateCanRespModel.fromJson(Map<String, dynamic> json) {
    return SimulateCanRespModel(
      request: json['request'],
      response: json['response'],
      currentCount: json['current_count'],
      error: json['error'],
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'request': request,
      'response': response,
      'current_count': currentCount,
      'error': error,
    };
  }
}