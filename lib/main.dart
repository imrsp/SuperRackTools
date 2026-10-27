import 'package:flutter/material.dart';
import 'screens/home_screen.dart';

void main() => runApp(const SuperRackToolsApp());

class SuperRackToolsApp extends StatefulWidget {
  const SuperRackToolsApp({super.key});

  @override
  State<SuperRackToolsApp> createState() => _SuperRackToolsAppState();
}

class _SuperRackToolsAppState extends State<SuperRackToolsApp> {
  ThemeMode _themeMode = ThemeMode.system;

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'SuperRackTools',
    debugShowCheckedModeBanner: false,
    theme: _buildTheme(Brightness.light),
    darkTheme: _buildTheme(Brightness.dark),
    themeMode: _themeMode,
    home: HomeScreen(
      themeMode: _themeMode,
      onThemeModeChanged: (mode) => setState(() => _themeMode = mode),
    ),
  );

  ThemeData _buildTheme(Brightness brightness) {
    final dark = brightness == Brightness.dark;
    final colorScheme = ColorScheme.fromSeed(
      seedColor: const Color(0xFF57C7F5),
      brightness: brightness,
      surface: dark ? const Color(0xFF171C23) : const Color(0xFFF7F9FB),
    );
    return ThemeData(
      useMaterial3: true,
      brightness: brightness,
      colorScheme: colorScheme,
      scaffoldBackgroundColor: dark
          ? const Color(0xFF101318)
          : const Color(0xFFE8EEF3),
      cardTheme: CardThemeData(
        color: colorScheme.surfaceContainerLow,
        elevation: 0,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22)),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: dark
            ? const Color(0xFF11161D)
            : colorScheme.surfaceContainerHighest,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide.none,
        ),
      ),
    );
  }
}
