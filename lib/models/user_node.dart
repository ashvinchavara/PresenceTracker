class UserNode {
  final String id;
  final String name;
  final String phone;
  final String email;
  final String department; // dept_name from join
  final int? deptId;       // dept_id (FK)
  final String desig;      // role field from MySQL users table
  final bool canUpload;    // can_upload field from MySQL users table
  final bool isBiometricVerified;

  UserNode({
    required this.id,
    required this.name,
    required this.phone,
    required this.email,
    required this.department,
    this.deptId,
    required this.desig,
    this.canUpload = false,
    this.isBiometricVerified = false,
  });

  /// Maps directly from the MySQL `users` row (with dept_name joined)
  factory UserNode.fromMap(Map<String, dynamic> data) {
    return UserNode(
      id: data['id']?.toString() ?? '',
      name: data['full_name'] ?? data['name'] ?? 'Unknown',
      phone: data['phone'] ?? '',
      email: data['email'] ?? '',
      department: data['dept_name'] ?? data['department'] ?? 'Unknown',
      deptId: data['dept_id'] != null ? int.tryParse(data['dept_id'].toString()) : null,
      desig: data['role'] ?? data['desig'] ?? 'Student',
      canUpload: (data['can_upload'] == 1 || data['can_upload'] == true),
      isBiometricVerified: data['isBiometricVerified'] ?? false,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'full_name': name,
      'phone': phone,
      'email': email,
      'role': desig,
      'dept_id': deptId,
      'dept_name': department,
      'can_upload': canUpload ? 1 : 0,
      'isBiometricVerified': isBiometricVerified,
    };
  }
}
