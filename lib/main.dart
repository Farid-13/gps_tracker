import 'dart:async';
import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart';
import 'package:intl/intl.dart';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'GPS Tracker to DB',
      theme: ThemeData(primarySwatch: Colors.blue),
      home: const GpsTrackerScreen(),
    );
  }
}

class GpsTrackerScreen extends StatefulWidget {
  const GpsTrackerScreen({super.key});

  @override
  State<GpsTrackerScreen> createState() => _GpsTrackerScreenState();
}

class _GpsTrackerScreenState extends State<GpsTrackerScreen> {
  String _currentCoordinates = "Ожидание запуска...";
  late Database _database;
  Timer? _gpsTimer;
  List<Map<String, dynamic>> _savedLogs = [];

  @override
  void initState() {
    super.initState();
    _initDatabase().then((_) {
      _startTrackingTimer(); // Включаем таймер сразу при старте приложения
    });
  }

  // 1. Инициализация базы данных SQLite
  Future<void> _initDatabase() async {
    final dbPath = await getDatabasesPath();
    final path = join(dbPath, 'gps_tracker.db');

    _database = await openDatabase(
      path,
      version: 1,
      onCreate: (db, version) {
        return db.execute(
          'CREATE TABLE gps_logs(id INTEGER PRIMARY KEY AUTOINCREMENT, timestamp TEXT, latitude REAL, longitude REAL)',
        );
      },
    );
    _loadLogsFromDb();
  }

  // 2. Функция, которая запрашивает GPS и пишет в БД
  Future<void> _getAndSaveLocation() async {
    try {
      // Проверяем разрешения
      LocationPermission permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
        if (permission == LocationPermission.denied) return;
      }

      // Получаем позицию
      Position position = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.high,
      );

      String timeStamp = DateFormat('yyyy-MM-dd HH:mm:ss').format(DateTime.now());

      // Запись в базу данных (аналог INSERT INTO в T-SQL)
      await _database.insert(
        'gps_logs',
        {
          'timestamp': timeStamp,
          'latitude': position.latitude,
          'longitude': position.longitude,
        },
        conflictAlgorithm: ConflictAlgorithm.replace,
      );

      setState(() {
        _currentCoordinates = "Широта: ${position.latitude}\nДолгота: ${position.longitude}\nЗаписано в: $timeStamp";
      });

      _loadLogsFromDb(); // Обновляем список на экране
    } catch (e) {
      setState(() {
        _currentCoordinates = "Ошибка получения GPS: $e";
      });
    }
  }

  // 3. Запуск периодического таймера (каждую минуту)
  void _startTrackingTimer() {
    // Вызываем один раз сразу
    _getAndSaveLocation();
    
    // Запускаем цикл (60 секунд)
    _gpsTimer = Timer.periodic(const Duration(seconds: 60), (timer) {
      _getAndSaveLocation();
    });
  }

  // 4. Вычитка логов из базы для отображения на экране
  Future<void> _loadLogsFromDb() async {
    final List<Map<String, dynamic>> logs = await _database.query('gps_logs', orderBy: 'id DESC', limit: 20);
    setState(() {
      _savedLogs = logs;
    });
  }

  @override
  void dispose() {
    _gpsTimer?.cancel(); // Не забываем тушить таймер при закрытии
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Мой GPS Локатор + БД')),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          children: [
            const SizedBox(height: 20),
            const Icon(Icons.location_on, size: 50, color: Colors.blue),
            const SizedBox(height: 10),
            Text(
              _currentCoordinates,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
            ),
            const Divider(height: 40, thickness: 2),
            const Text("Последние 20 записей в БД:", style: TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 10),
            Expanded(
              child: _savedLogs.isEmpty
                  ? const Center(child: Text("Логи еще не записаны"))
                  : ListView.builder(
                      itemCount: _savedLogs.length,
                      itemBuilder: (context, index) {
                        final log = _savedLogs[index];
                        return Card(
                          child: ListTile(
                            leading: CircleAvatar(child: Text('${log['id']}')),
                            title: Text("Широта: ${log['latitude']}, Долгота: ${log['longitude']}"),
                            subtitle: Text("Время: ${log['timestamp']}"),
                          ),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}