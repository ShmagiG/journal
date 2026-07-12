import 'package:flutter/material.dart';

import 'data/database.dart';
import 'screens/entry_list_screen.dart';

void main() {
  final database = AppDatabase();
  runApp(MyApp(database: database));
}

class MyApp extends StatelessWidget {
  const MyApp({super.key, required this.database});

  final AppDatabase database;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Journal',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color.fromARGB(255, 119, 34, 34),
        ),
      ),
      home: EntryListScreen(database: database),
    );
  }
}
