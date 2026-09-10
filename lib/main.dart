import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'app_state.dart';
import 'screens/home_screen.dart';
import 'services/foreground_service.dart';
import 'services/pi_connection_settings.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await ForegroundServiceController.init();

  final settings = await PiConnectionSettings.load();
  runApp(BabyMonitorApp(settings: settings));
}

class BabyMonitorApp extends StatelessWidget {
  final PiConnectionSettings settings;

  const BabyMonitorApp({super.key, required this.settings});

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider(
      create: (_) => AppState(settings),
      child: MaterialApp(
        title: 'Baby Monitor',
        theme: ThemeData(
          colorSchemeSeed: Colors.teal,
          useMaterial3: true,
        ),
        darkTheme: ThemeData(
          colorSchemeSeed: Colors.teal,
          brightness: Brightness.dark,
          useMaterial3: true,
        ),
        home: const HomeScreen(),
      ),
    );
  }
}
