import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:geolocator/geolocator.dart';
import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart' as p; // Переименовали в p для безопасности путей
import 'package:intl/intl.dart';
import 'package:http/http.dart' as http;
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart' as ll;

const bool debugMode = true;

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  
  SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    statusBarIconBrightness: Brightness.dark,
  ));

  await _checkLocationPermissions();
  await initializeBackgroundService();
  runApp(const MyApp());
}

Future<void> _checkLocationPermissions() async {
  bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
  if (!serviceEnabled) return;

  LocationPermission permission = await Geolocator.checkPermission();
  if (permission == LocationPermission.denied) {
    permission = await Geolocator.requestPermission();
    if (permission == LocationPermission.denied) return;
  }
  if (permission == LocationPermission.deniedForever) return;
}

Future<void> initializeBackgroundService() async {
  final service = FlutterBackgroundService();
  const AndroidNotificationChannel channel = AndroidNotificationChannel(
    'gps_tracker_channel', 
    'Enterprise GPS Service',
    description: 'Этот канал используется для постоянного сбора геоданных в фоне',
    importance: Importance.high, // Повышаем важность до High для стабильности логов
  );

  final FlutterLocalNotificationsPlugin flutterLocalNotificationsPlugin = FlutterLocalNotificationsPlugin();
  await flutterLocalNotificationsPlugin
      .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()
      ?.createNotificationChannel(channel);

  await service.configure(
    androidConfiguration: AndroidConfiguration(
      onStart: onStart,
      autoStart: true,
      isForegroundMode: true, // Foreground-сервис остаётся живым в фоне
      notificationChannelId: 'gps_tracker_channel',
      initialNotificationTitle: '📍 Мой GPS Локатор',
      initialNotificationContent: 'Сбор геоданных активен в фоновом режиме...',
      foregroundServiceNotificationId: 888,
      autoStartOnBoot: true, // Стартовать при перезагрузке
    ),
    iosConfiguration: IosConfiguration(
      autoStart: true,
      onForeground: onStart,
      onBackground: onStartBackground,
    ),
  );
}

@pragma('vm:entry-point')
bool onStartBackground(ServiceInstance service) {
  WidgetsFlutterBinding.ensureInitialized();
  return true;
}

@pragma('vm:entry-point')
void onStart(ServiceInstance service) async {
  DartPluginRegistrant.ensureInitialized();
  final dbPath = await getDatabasesPath();
  final path = p.join(dbPath, 'gps_tracker.db');
  
  final database = await openDatabase(
    path, 
    version: 1,
    onCreate: (db, version) async {
      await db.execute(
        'CREATE TABLE gps_logs (id INTEGER PRIMARY KEY AUTOINCREMENT, timestamp TEXT, latitude REAL, longitude REAL)'
      );
    },
  );

  // Функция для безопасной передачи свежих логов из БД прямо в UI-интерфейс
  Future<void> sendDataToUi(String status, double currentLat, double currentLon, String currentTime, {String debugInfo = ''}) async {
    final logs = await database.query('gps_logs', orderBy: 'id DESC', limit: 20);
    final payload = {
      "latitude": currentLat.toString(),
      "longitude": currentLon.toString(),
      "timestamp": currentTime,
      "status": status,
      "logs": jsonEncode(logs),
    };
    if (debugMode && debugInfo.isNotEmpty) {
      payload['debug'] = debugInfo;
    }
    service.invoke('update', payload);
  }

  // Первичный ответ, чтобы UI не зависал
  await sendDataToUi("Поиск спутников...", 0.0, 0.0, "--:--:--");

  // Функция для сбора GPS координат
  Future<void> collectGpsData() async {
    String timeStamp = DateFormat('yyyy-MM-dd HH:mm:ss').format(DateTime.now());
    double lat = 0.0;
    double lon = 0.0;

    try {
      Position position = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.high,
        timeLimit: const Duration(seconds: 15),
      );
      lat = position.latitude;
      lon = position.longitude;

      // Запись точки в SQLite
      await database.insert('gps_logs', {
        'timestamp': timeStamp,
        'latitude': lat,
        'longitude': lon,
      });

      // Отправка на ваш корпоративный сервер
      final response = await http.post(
        Uri.parse('http://89.147.202.166:1153/tayqa/tiger/api/development/v5.40/DynamicApi/PostDynamicData/GpsTracker_Ferid'),
        headers: {
          'Content-Type': 'application/json', 
          'username': 'faridq'
        },
        body: jsonEncode({
          'Latitude': lat.toString(),
          'Longitude': lon.toString(),
          'GpsDate': timeStamp,
        }),
      ).timeout(const Duration(seconds: 15));

      String currentStatus = response.statusCode == 200 ? "В сети (ОК)" : "Ошибка API: ${response.statusCode}";
      await sendDataToUi(currentStatus, lat, lon, timeStamp);

    } on TimeoutException catch (e, stack) {
      final debugText = 'TimeoutException: $e\n$stack';
      debugPrint('Background timeout error: $debugText');
      await sendDataToUi('Таймаут сети', lat, lon, timeStamp, debugInfo: debugText);
    } on SocketException catch (e, stack) {
      final debugText = 'SocketException: $e\n$stack';
      debugPrint('Background socket error: $debugText');
      await sendDataToUi('Ошибка сети', lat, lon, timeStamp, debugInfo: debugText);
    } on DatabaseException catch (e, stack) {
      final debugText = 'DatabaseException: $e\n$stack';
      debugPrint('Background DB error: $debugText');
      await sendDataToUi('База данных занята', lat, lon, timeStamp, debugInfo: debugText);
    } on PermissionDeniedException catch (e, stack) {
      final debugText = 'PermissionDeniedException: $e\n$stack';
      debugPrint('Background permission error: $debugText');
      await sendDataToUi('Нет доступа к GPS', lat, lon, timeStamp, debugInfo: debugText);
    } on LocationServiceDisabledException catch (e, stack) {
      final debugText = 'LocationServiceDisabledException: $e\n$stack';
      debugPrint('Background GPS disabled: $debugText');
      await sendDataToUi('GPS выключен', lat, lon, timeStamp, debugInfo: debugText);
    } on Exception catch (e, stack) {
      final errorText = e.toString().toLowerCase();
      final debugText = '$e\n$stack';
      debugPrint('Background other exception: $debugText');
      String currentStatus;
      if (errorText.contains('permission') || errorText.contains('denied')) {
        currentStatus = 'Нет доступа к GPS';
      } else if (errorText.contains('location') || errorText.contains('gps')) {
        currentStatus = 'Ошибка GPS';
      } else if (errorText.contains('timeout')) {
        currentStatus = 'Таймаут сети';
      } else if (errorText.contains('socket') || errorText.contains('network')) {
        currentStatus = 'Ошибка сети';
      } else if (errorText.contains('database is locked')) {
        currentStatus = 'База данных занята';
      } else {
        final message = e.toString();
        final shortMessage = message.length <= 40 ? message : '${message.substring(0, 40)}...';
        currentStatus = 'Сбой службы: $shortMessage';
      }
      await sendDataToUi(currentStatus, lat, lon, timeStamp, debugInfo: debugText);
    } catch (e, stack) {
      final debugText = '$e\n$stack';
      debugPrint('Background unknown error: $debugText');
      final message = e.toString();
      final shortMessage = message.length <= 40 ? message : '${message.substring(0, 40)}...';
      await sendDataToUi('Сбой службы: $shortMessage', lat, lon, timeStamp, debugInfo: debugText);
    }
  }

  // Немедленно собираем первую координату
  await collectGpsData();

  // Слушаем запросы ручного обновления из экрана приложения
  service.on('refresh_logs').listen((event) async {
    final logs = await database.query('gps_logs', orderBy: 'id DESC', limit: 20);
    service.invoke('logs_loaded', {"logs": jsonEncode(logs)});
  });

  // Периодически собираем GPS координаты каждые 60 секунд
  Timer.periodic(const Duration(seconds: 60), (timer) async {
    await collectGpsData();
  });
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'GPS Мониторинг',
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF1A237E),
          primary: const Color(0xFF1A237E),
          surface: const Color(0xFFF8FAFC),
        ),
        cardTheme: CardTheme(
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
            side: BorderSide(color: Colors.grey.shade200),
          ),
          color: Colors.white,
        ),
      ),
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
  String _lat = "0.0000", _lon = "0.0000", _time = "--:--:--", _status = "Запуск сервиса...";
  String _debugInfo = '';
  List<dynamic> _savedLogs = [];

  @override
  void initState() {
    super.initState();
    
    // При старте экрана просим фоновый поток выдать нам последние логи
    Timer(const Duration(milliseconds: 600), () {
      FlutterBackgroundService().invoke('refresh_logs');
    });

    // Принимаем регулярные пакеты обновлений геоданных и логов от сервиса
    FlutterBackgroundService().on('update').listen((event) {
      if (event != null && mounted) {
        setState(() {
          _lat = event['latitude'].toString();
          _lon = event['longitude'].toString();
          _time = event['timestamp'].toString();
          _status = event['status'].toString();
          _debugInfo = event['debug']?.toString() ?? '';
          if (event['logs'] != null) {
            _savedLogs = jsonDecode(event['logs'].toString());
          }
        });
      }
    });

    // Обрабатываем ручной ответ со списком логов
    FlutterBackgroundService().on('logs_loaded').listen((event) {
      if (event != null && event['logs'] != null && mounted) {
        setState(() {
          _savedLogs = jsonDecode(event['logs'].toString());
        });
      }
    });
  }

  void _openMiniMap(BuildContext currentContext, double latitude, double longitude, String timestamp) {
    final point = ll.LatLng(latitude, longitude);

    showModalBottomSheet(
      context: currentContext,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (BuildContext sheetContext) {
        return Container(
          height: MediaQuery.of(sheetContext).size.height * 0.6,
          decoration: const BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.only(
              topLeft: Radius.circular(24),
              topRight: Radius.circular(24),
            ),
          ),
          child: Column(
            children: [
              Container(
                margin: const EdgeInsets.symmetric(vertical: 12),
                height: 4,
                width: 40,
                decoration: BoxDecoration(color: Colors.grey.shade300, borderRadius: BorderRadius.circular(2)),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 4),
                child: Text(
                  'Точка от $timestamp',
                  style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15, color: Color(0xFF1A237E)),
                ),
              ),
              const Divider(),
              Expanded(
                child: ClipRRect(
                  borderRadius: const BorderRadius.only(
                    bottomLeft: Radius.circular(24),
                    bottomRight: Radius.circular(24),
                  ),
                  child: FlutterMap(
                    options: MapOptions(
                      initialCenter: point,
                      initialZoom: 15.5,
                    ),
                    children: [
                      TileLayer(
                        urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                        userAgentPackageName: 'com.example.gps_tracker',
                      ),
                      MarkerLayer(
                        markers: [
                          Marker(
                            point: point,
                            width: 40,
                            height: 40,
                            child: const Icon(
                              Icons.location_on,
                              color: Colors.red,
                              size: 40,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Theme.of(context).colorScheme.surface,
      appBar: AppBar(
        title: const Text('Мой GPS Монитор', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 20)),
        centerTitle: true,
        backgroundColor: Colors.white,
        elevation: 0,
      ),
      body: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SizedBox(height: 20),
            Container(
              padding: const EdgeInsets.all(24),
              decoration: BoxDecoration(
                gradient: const LinearGradient(
                  colors: [Color(0xFF1A237E), Color(0xFF3949AB)],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
                borderRadius: BorderRadius.circular(28),
                boxShadow: [
                  BoxShadow(
                    color: const Color(0xFF1A237E).withOpacity(0.25),
                    blurRadius: 20,
                    offset: const Offset(0, 10),
                  )
                ],
              ),
              child: Column(
                children: [
                  Row(
                    children: [
                      const Text("Текущий статус", style: TextStyle(color: Colors.white70, fontSize: 16)),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                          decoration: BoxDecoration(
                            color: Colors.white.withOpacity(0.2),
                            borderRadius: BorderRadius.circular(20),
                          ),
                          child: Text(
                            _status,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 12),
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 24),
                  if (_debugInfo.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 16),
                      child: Text(
                        _debugInfo,
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(color: Colors.white70, fontSize: 12),
                      ),
                    ),
                  Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: Colors.white.withOpacity(0.15),
                          shape: BoxShape.circle,
                        ),
                        child: const Icon(Icons.my_location, color: Colors.white, size: 32),
                      ),
                      const SizedBox(width: 16),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              "$_lat, $_lon", 
                              style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w900, letterSpacing: 0.5),
                            ),
                            const SizedBox(height: 4),
                            Text("Обновлено: $_time", style: const TextStyle(color: Colors.white60, fontSize: 13)),
                          ],
                        ),
                      )
                    ],
                  )
                ],
              ),
            ),
            
            const SizedBox(height: 28),
            const Text(
              'Последние точки GPS (Нажмите для просмотра)',
              style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold, color: Color(0xFF1E293B)),
            ),
            const SizedBox(height: 12),
            
            Expanded(
              child: _savedLogs.isEmpty
                  ? const Center(
                      child: Text(
                        'Ожидание первых данных от службы...',
                        style: TextStyle(color: Colors.grey),
                      ),
                    )
                  : ListView.builder(
                      itemCount: _savedLogs.length,
                      padding: const EdgeInsets.only(bottom: 20),
                      itemBuilder: (listContext, index) {
                        final log = _savedLogs[index];
                        final double logLat = log['latitude'] is String ? double.parse(log['latitude']) : (log['latitude'] as num).toDouble();
                        final double logLon = log['longitude'] is String ? double.parse(log['longitude']) : (log['longitude'] as num).toDouble();
                        final String logTime = log['timestamp'] ?? '';

                        return Padding(
                          padding: const EdgeInsets.only(bottom: 10),
                          child: Card(
                            child: InkWell(
                              borderRadius: BorderRadius.circular(16),
                              onTap: () {
                                if (logLat != 0.0 && logLon != 0.0) {
                                  _openMiniMap(context, logLat, logLon, logTime);
                                }
                              },
                              child: ListTile(
                                contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                                leading: Container(
                                  padding: const EdgeInsets.all(8),
                                  decoration: BoxDecoration(
                                    color: const Color(0xFF1A237E).withOpacity(0.1),
                                    borderRadius: BorderRadius.circular(12),
                                  ),
                                  child: const Icon(
                                    Icons.map_outlined,
                                    color: Color(0xFF1A237E),
                                  ),
                                ),
                                title: Text(
                                  '$logLat, $logLon',
                                  style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14, color: Color(0xFF334155)),
                                ),
                                subtitle: Text(
                                  'Время лога: $logTime',
                                  style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
                                ),
                                trailing: Icon(Icons.chevron_right, color: Colors.grey.shade400, size: 20),
                              ),
                            ),
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