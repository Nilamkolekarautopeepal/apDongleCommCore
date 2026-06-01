class SessionLogsModel {
  String? header;
  String? message;
  String? status;

  SessionLogsModel({
    this.header,
    this.message,
    this.status,
  });

  // Factory method to create an instance from a Map (JSON)
  factory SessionLogsModel.fromJson(Map<String, dynamic> json) {
    return SessionLogsModel(
      header: json['header'] as String?,
      message: json['message'] as String?,
      status: json['status'] as String?,
    );
  }

  // Method to convert the object back to a Map (JSON)
  Map<String, dynamic> toJson() {
    return {
      'header': header,
      'message': message,
      'status': status,
    };
  }
}