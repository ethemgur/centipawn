import 'dart:async';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:google_sign_in/google_sign_in.dart';

/// Thin wrapper over FirebaseAuth. Supports anonymous, email/password, and Google sign-in.
class AuthService {
  AuthService._();
  static final AuthService instance = AuthService._();

  final FirebaseAuth _auth = FirebaseAuth.instance;
  bool _googleInitialized = false;

  User? get currentUser => _auth.currentUser;
  bool get isAnonymous => _auth.currentUser?.isAnonymous ?? true;
  String? get userEmail => _auth.currentUser?.email;
  Stream<User?> authStateChanges() => _auth.authStateChanges();

  /// Returns the current user, signing in anonymously if there isn't one.
  Future<User> ensureSignedIn() async {
    final existing = _auth.currentUser;
    if (existing != null) return existing;
    final cred = await _auth.signInAnonymously();
    return cred.user!;
  }

  Future<UserCredential> signInWithEmailAndPassword(
          String email, String password) =>
      _auth.signInWithEmailAndPassword(email: email, password: password);

  Future<UserCredential> createUserWithEmailAndPassword(
          String email, String password) =>
      _auth.createUserWithEmailAndPassword(email: email, password: password);

  Future<UserCredential> signInWithGoogle() async {
    final gsi = GoogleSignIn.instance;

    if (!_googleInitialized) {
      await gsi.initialize();
      _googleInitialized = true;
    }

    if (!gsi.supportsAuthenticate()) {
      throw Exception('Google Sign-In is not supported on this platform');
    }

    // Wait for the sign-in event that follows calling authenticate().
    final completer = Completer<GoogleSignInAccount>();
    final sub = gsi.authenticationEvents.listen((event) {
      if (completer.isCompleted) return;
      if (event is GoogleSignInAuthenticationEventSignIn) {
        completer.complete(event.user);
      }
    }, onError: (Object e) {
      if (!completer.isCompleted) completer.completeError(e);
    });

    try {
      await gsi.authenticate();
      final account = await completer.future;
      final idToken = account.authentication.idToken;
      if (idToken == null) throw Exception('No ID token from Google');
      final credential = GoogleAuthProvider.credential(idToken: idToken);
      return _auth.signInWithCredential(credential);
    } finally {
      sub.cancel();
    }
  }

  Future<void> signOut() => _auth.signOut();
}
