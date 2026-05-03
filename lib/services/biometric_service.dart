import 'package:local_auth/local_auth.dart';

class BiometricService {
  final LocalAuthentication auth = LocalAuthentication();

  Future<bool> isBiometricAvailable() async {
    final bool canAuthenticateWithBiometrics = await auth.canCheckBiometrics;
    final bool canAuthenticate =
        canAuthenticateWithBiometrics || await auth.isDeviceSupported();
    return canAuthenticate;
  }

  Future<bool> authenticateUser(String reason) async {
    try {
      final bool didAuthenticate = await auth.authenticate(
        localizedReason: reason,
        biometricOnly: true,
      );
      return didAuthenticate;
    } catch (e) {
      print('Error using biometrics: $e');
      return false;
    }
  }
}
