import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:firebase_core/firebase_core.dart';
import 'firebase_options.dart';
import 'services/auth_service.dart';
import 'services/database_factory_setup.dart';
import 'theme.dart';
import 'screens/game_list_screen.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  setUpDatabaseFactory();
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
  await AuthService.instance.ensureSignedIn();
  runApp(
    const ProviderScope(
      child: CentipawnApp(),
    ),
  );
}

class CentipawnApp extends StatelessWidget {
  const CentipawnApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Centipawn',
      debugShowCheckedModeBanner: false,
      theme: buildAppTheme(),
      home: const GameListScreen(),
    );
  }
}
