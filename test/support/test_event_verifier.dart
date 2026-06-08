import 'package:ndk/ndk.dart';

class TestEventVerifier implements EventVerifier {
  @override
  Future<bool> verify(Nip01Event event) async => true;
}
