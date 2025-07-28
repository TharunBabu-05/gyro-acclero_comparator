import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:sensors_plus/sensors_plus.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:geolocator/geolocator.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  
  try {
    await Firebase.initializeApp(
      options: FirebaseOptions(
        apiKey: 'AIzaSyBuWJLOvmlpylyVFhivRfMEZSVGm1lA2jY',
        appId: '1:266720440078:android:3feadecd459c79ab18b15f',
        messagingSenderId: '266720440078',
        projectId: 'gyre-compare',
        databaseURL: 'https://gyre-compare-default-rtdb.firebaseio.com',
        storageBucket: 'gyre-compare.firebasestorage.app',
      ),
    );
    
    // Test Firebase connection
    final database = FirebaseDatabase.instance;
    await database.ref('.info/connected').get();
    print('Firebase connection successful');
    
  } catch (e) {
    print('Firebase initialization error: $e');
  }
  
  runApp(MyApp());
}

class MyApp extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Motion Sync Detection',
      theme: ThemeData(primarySwatch: Colors.blue),
      home: MotionSyncPage(),
    );
  }
}

class MotionSyncPage extends StatefulWidget {
  @override
  _MotionSyncPageState createState() => _MotionSyncPageState();
}

class _MotionSyncPageState extends State<MotionSyncPage> {
  final database = FirebaseDatabase.instance.ref();
  late StreamSubscription<AccelerometerEvent> _accelSub;
  late StreamSubscription<GyroscopeEvent> _gyroSub;
  Timer? _gpsTimer;

  List<double> _myAccel = [0, 0, 0];
  List<double> _otherAccel = [0, 0, 0];

  List<double> _myGyro = [0, 0, 0];
  List<double> _otherGyro = [0, 0, 0];

  double _mySpeed = 0.0;
  double _otherSpeed = 0.0;
  
  // Add location tracking
  double _myLatitude = 0.0;
  double _myLongitude = 0.0;
  double _otherLatitude = 0.0;
  double _otherLongitude = 0.0;

  bool isSameMotion = false;
  bool isSameLocation = false;
  bool isSameCoordinate = false;
  bool isConnected = false;

  String connectionKey = "";
  String? sessionKey;
  String deviceId = DateTime.now().millisecondsSinceEpoch.toString(); // Unique ID for each device

  Future<bool> _checkLocationPermission() async {
    // First check if location service is enabled
    bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) {
      showDialog(
        context: context,
        barrierDismissible: false,
        builder: (BuildContext context) {
          return AlertDialog(
            title: Text('Location Required'),
            content: Text('This app needs location services to work. Please enable location services.'),
            actions: [
              TextButton(
                child: Text('OPEN SETTINGS'),
                onPressed: () async {
                  await Geolocator.openLocationSettings();
                  Navigator.of(context).pop();
                },
              ),
            ],
          );
        },
      );
      return false;
    }

    LocationPermission permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
      if (permission == LocationPermission.denied) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('Location permissions are denied. App needs location to work.'),
          duration: Duration(seconds: 3),
        ));
        return false;
      }
    }

    if (permission == LocationPermission.deniedForever) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('Location permissions are permanently denied. Please enable in settings.'),
        duration: Duration(seconds: 3),
        action: SnackBarAction(
          label: 'SETTINGS',
          onPressed: () => Geolocator.openAppSettings(),
        ),
      ));
      return false;
    }

    return true;
  }

  @override
  void initState() {
    super.initState();
    _initializeApp();
  }

  Future<void> _showConnectionDialog() async {
    String? result = await showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (BuildContext context) {
        String tempKey = '';
        return AlertDialog(
          title: Text('Enter Connection Code'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('Enter the same code on both devices to connect:'),
              SizedBox(height: 10),
              TextField(
                onChanged: (value) => tempKey = value.toUpperCase(),
                textCapitalization: TextCapitalization.characters,
                style: TextStyle(fontSize: 24, letterSpacing: 8),
                textAlign: TextAlign.center,
                maxLength: 6,
                decoration: InputDecoration(
                  hintText: 'ABC123',
                  border: OutlineInputBorder(),
                  counterText: "",
                ),
              ),
              SizedBox(height: 10),
              Text(
                'Make sure both devices have internet connection',
                style: TextStyle(color: Colors.grey[600], fontSize: 12),
                textAlign: TextAlign.center,
              ),
            ],
          ),
          actions: [
            TextButton(
              child: Text('Connect'),
              onPressed: () {
                if (tempKey.length >= 4) {
                  Navigator.of(context).pop(tempKey);
                } else {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text('Please enter at least 4 characters'))
                  );
                }
              },
            ),
          ],
        );
      },
    );

    if (result != null && result.isNotEmpty) {
      setState(() {
        sessionKey = result.toUpperCase();
        connectionKey = result.toUpperCase();
      });
      _startListening();
      _listenToOtherDevice();
      _startGpsUpdates();
    }
  }

  Future<void> _initializeApp() async {
    bool hasPermission = await _checkLocationPermission();
    if (hasPermission) {
      _showConnectionDialog();
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Please enable location services to continue'),
          duration: Duration(seconds: 3),
          action: SnackBarAction(
            label: 'SETTINGS',
            onPressed: () => Geolocator.openLocationSettings(),
          ),
        ),
      );
    }
  }

  void _startListening() {
    _accelSub = accelerometerEvents.listen((AccelerometerEvent event) {
      _myAccel = [event.x, event.y, event.z];
      _sendToFirebase();
      _compareMotion();
    });

    _gyroSub = gyroscopeEvents.listen((GyroscopeEvent event) {
      _myGyro = [event.x, event.y, event.z];
      _sendToFirebase();
      _compareMotion();
    });
  }

  void _startGpsUpdates() {
    _gpsTimer = Timer.periodic(Duration(seconds: 2), (_) async {
      bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) return;

      LocationPermission permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
        if (permission == LocationPermission.deniedForever) return;
      }

      Position position = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.high
      );
      setState(() {
        _mySpeed = position.speed; // speed in m/s
        _myLatitude = position.latitude;
        _myLongitude = position.longitude;
      });
      _sendToFirebase();
      _compareMotion();
    });
  }

  void _sendToFirebase() {
    if (sessionKey == null) return;
    
    database.child('sessions/$sessionKey/$deviceId').set({
      'accel': {'x': _myAccel[0], 'y': _myAccel[1], 'z': _myAccel[2]},
      'gyro': {'x': _myGyro[0], 'y': _myGyro[1], 'z': _myGyro[2]},
      'speed': _mySpeed,
      'location': {
        'latitude': _myLatitude,
        'longitude': _myLongitude,
      },
      'lastUpdate': ServerValue.timestamp,
    });
  }

  StreamSubscription? _otherDeviceSub;

  void _listenToOtherDevice() {
    if (sessionKey == null) return;

    // Cancel existing subscription if any
    _otherDeviceSub?.cancel();

    // Clear other device data
    setState(() {
      _otherAccel = [0, 0, 0];
      _otherGyro = [0, 0, 0];
      _otherSpeed = 0.0;
      _otherLatitude = 0.0;
      _otherLongitude = 0.0;
      isConnected = false;
    });

    // Listen for all devices in the session
    _otherDeviceSub = database.child('sessions/$sessionKey').onValue.listen((event) {
      final data = event.snapshot.value as Map?;
      if (data != null && data.length >= 2) {
        // At least two devices are present
        // Find the other device (not this device)
        String? otherId;
        for (final key in data.keys) {
          if (key != deviceId) {
            otherId = key;
            break;
          }
        }
        if (otherId != null) {
          final otherData = data[otherId] as Map?;
          if (otherData != null) {
            final accel = otherData['accel'] as Map?;
            if (accel != null) {
              _otherAccel = [
                (accel['x'] ?? 0).toDouble(),
                (accel['y'] ?? 0).toDouble(),
                (accel['z'] ?? 0).toDouble(),
              ];
            }
            final gyro = otherData['gyro'] as Map?;
            if (gyro != null) {
              _otherGyro = [
                (gyro['x'] ?? 0).toDouble(),
                (gyro['y'] ?? 0).toDouble(),
                (gyro['z'] ?? 0).toDouble(),
              ];
            }
            final location = otherData['location'] as Map?;
            if (location != null) {
              _otherLatitude = (location['latitude'] ?? 0).toDouble();
              _otherLongitude = (location['longitude'] ?? 0).toDouble();
            }
            _otherSpeed = (otherData['speed'] ?? 0).toDouble();
          }
          setState(() {
            isConnected = true;
          });
          _compareMotion();
        }
      } else {
        setState(() {
          isConnected = false;
        });
      }
    }, onError: (error) {
      print("Error listening to session: $error");
    });
  }

  void _compareMotion() {
    double accelThreshold = 3.0; // Made more lenient for real-world usage
    double gyroThreshold = 1.0; // Made more lenient for real-world usage
    double speedThreshold = 2.0; // 2 m/s difference allowed (about 7.2 km/h)
    double locationThreshold = 5.0; // 5 meters threshold for same location

    // Only compare if we have data from other device
    if (_otherAccel.every((val) => val == 0.0) && _otherGyro.every((val) => val == 0.0)) {
      setState(() {
        isSameMotion = false;
        isSameLocation = false;
        isSameCoordinate = false;
      });
      return;
    }

    // Calculate distance between devices in meters
    double distance = Geolocator.distanceBetween(
      _myLatitude, _myLongitude,
      _otherLatitude, _otherLongitude
    );

    // Calculate acceleration difference
    double accelDiff = sqrt(
      pow(_myAccel[0] - _otherAccel[0], 2) +
      pow(_myAccel[1] - _otherAccel[1], 2) +
      pow(_myAccel[2] - _otherAccel[2], 2),
    );

    // Calculate gyroscope difference
    double gyroDiff = sqrt(
      pow(_myGyro[0] - _otherGyro[0], 2) +
      pow(_myGyro[1] - _otherGyro[1], 2) +
      pow(_myGyro[2] - _otherGyro[2], 2),
    );

    // Calculate speed difference
    double speedDiff = (_mySpeed - _otherSpeed).abs();

    // Update UI with comparison results
    setState(() {
      isSameMotion = accelDiff < accelThreshold && gyroDiff < gyroThreshold;
      isSameLocation = speedDiff < speedThreshold;
      isSameCoordinate = distance < locationThreshold;
    });
  }

  @override
  void dispose() {
    _accelSub.cancel();
    _gyroSub.cancel();
    _gpsTimer?.cancel();
    _otherDeviceSub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('Motion & Location Sync'),
        actions: [
          // Connection status
          Container(
            padding: EdgeInsets.symmetric(horizontal: 16.0),
            child: Row(
              children: [
                Icon(
                  isConnected ? Icons.link : Icons.link_off,
                  color: isConnected ? Colors.green : Colors.red,
                ),
                SizedBox(width: 8),
                Text(
                  sessionKey ?? 'Not Connected',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                    color: isConnected ? Colors.green : Colors.red,
                  ),
                ),
                SizedBox(width: 8),
                IconButton(
                  icon: Icon(Icons.refresh),
                  onPressed: _showConnectionDialog,
                  tooltip: 'Change Connection Code',
                ),
              ],
            ),
          ),
          // Device selector
          Container(
            padding: EdgeInsets.symmetric(horizontal: 16.0),
            child: PopupMenuButton<String>(
              onSelected: (String newId) {
                setState(() {
                  deviceId = newId;
                  _listenToOtherDevice(); // Reconnect with new device ID
                });
              },
              itemBuilder: (BuildContext context) => <PopupMenuEntry<String>>[
                PopupMenuItem<String>(
                  value: 'device1',
                  child: Row(
                    children: [
                      Icon(Icons.phone_android, 
                           color: deviceId == 'device1' ? Colors.blue : Colors.grey),
                      SizedBox(width: 8),
                      Text('Device 1',
                           style: TextStyle(
                             fontWeight: deviceId == 'device1' 
                                        ? FontWeight.bold : FontWeight.normal
                           )),
                    ],
                  ),
                ),
                PopupMenuItem<String>(
                  value: 'device2',
                  child: Row(
                    children: [
                      Icon(Icons.phone_android, 
                           color: deviceId == 'device2' ? Colors.blue : Colors.grey),
                      SizedBox(width: 8),
                      Text('Device 2',
                           style: TextStyle(
                             fontWeight: deviceId == 'device2' 
                                        ? FontWeight.bold : FontWeight.normal
                           )),
                    ],
                  ),
                ),
              ],
              child: Container(
                padding: EdgeInsets.symmetric(vertical: 8.0, horizontal: 12.0),
                decoration: BoxDecoration(
                  border: Border.all(color: Colors.white.withOpacity(0.5)),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  children: [
                    Icon(Icons.phone_android, size: 20),
                    SizedBox(width: 8),
                    Text(
                      'Device: ${deviceId}',
                      style: TextStyle(fontSize: 16),
                    ),
                    Icon(Icons.arrow_drop_down),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
      body: SingleChildScrollView(
        child: Padding(
          padding: EdgeInsets.all(16.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // My Device Sensors
              Card(
                child: Padding(
                  padding: EdgeInsets.all(16.0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('My Device (${deviceId})', 
                          style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
                      SizedBox(height: 10),
                      Text('Accelerometer:'),
                      Text('X: ${_myAccel[0].toStringAsFixed(2)}'),
                      Text('Y: ${_myAccel[1].toStringAsFixed(2)}'),
                      Text('Z: ${_myAccel[2].toStringAsFixed(2)}'),
                      SizedBox(height: 10),
                      Text('Gyroscope:'),
                      Text('X: ${_myGyro[0].toStringAsFixed(2)}'),
                      Text('Y: ${_myGyro[1].toStringAsFixed(2)}'),
                      Text('Z: ${_myGyro[2].toStringAsFixed(2)}'),
                      SizedBox(height: 10),
                      Text('Speed: ${(_mySpeed * 3.6).toStringAsFixed(2)} km/h'),
                    ],
                  ),
                ),
              ),
              SizedBox(height: 16),
              
              // Other Device Sensors
              Card(
                child: Padding(
                  padding: EdgeInsets.all(16.0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Other Device', 
                          style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
                      SizedBox(height: 10),
                      Text('Accelerometer:'),
                      Text('X: ${_otherAccel[0].toStringAsFixed(2)}'),
                      Text('Y: ${_otherAccel[1].toStringAsFixed(2)}'),
                      Text('Z: ${_otherAccel[2].toStringAsFixed(2)}'),
                      SizedBox(height: 10),
                      Text('Gyroscope:'),
                      Text('X: ${_otherGyro[0].toStringAsFixed(2)}'),
                      Text('Y: ${_otherGyro[1].toStringAsFixed(2)}'),
                      Text('Z: ${_otherGyro[2].toStringAsFixed(2)}'),
                      SizedBox(height: 10),
                      Text('Speed: ${(_otherSpeed * 3.6).toStringAsFixed(2)} km/h'),
                    ],
                  ),
                ),
              ),
              SizedBox(height: 16),
              
              // Connection Status
              Card(
                child: Padding(
                  padding: EdgeInsets.all(16.0),
                  child: Column(
                    children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(
                            isConnected ? Icons.cloud_done : Icons.cloud_off,
                            color: isConnected ? Colors.green : Colors.red,
                            size: 24,
                          ),
                          SizedBox(width: 8),
                          Text(
                            isConnected ? "Connected to other device" : "Waiting for other device...",
                            style: TextStyle(fontSize: 16),
                          ),
                        ],
                      ),
                      if (!isConnected) ...[
                        SizedBox(height: 8),
                        Text(
                          'Make sure both devices:',
                          style: TextStyle(fontSize: 14, color: Colors.grey[600]),
                        ),
                        Text(
                          '1. Have internet connection',
                          style: TextStyle(fontSize: 14, color: Colors.grey[600]),
                        ),
                        Text(
                          '2. Use the same connection key',
                          style: TextStyle(fontSize: 14, color: Colors.grey[600]),
                        ),
                        Text(
                          '3. One device is set as Device 1',
                          style: TextStyle(fontSize: 14, color: Colors.grey[600]),
                        ),
                        Text(
                          '4. Other device is set as Device 2',
                          style: TextStyle(fontSize: 14, color: Colors.grey[600]),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
              SizedBox(height: 16),
              
              // Sync Status
              Card(
                child: Padding(
                  padding: EdgeInsets.all(16.0),
                  child: Column(
                    children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(
                            isSameMotion ? Icons.sync : Icons.sync_disabled,
                            color: isSameMotion ? Colors.green : Colors.red,
                            size: 40,
                          ),
                          SizedBox(width: 10),
                          Text(
                            isSameMotion ? "Same Motion" : "Different Motion",
                            style: TextStyle(fontSize: 20),
                          ),
                        ],
                      ),
                      SizedBox(height: 16),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(
                            isSameLocation ? Icons.speed : Icons.speed_outlined,
                            color: isSameLocation ? Colors.green : Colors.red,
                            size: 40,
                          ),
                          SizedBox(width: 10),
                          Text(
                            isSameLocation ? "Same Speed" : "Different Speed",
                            style: TextStyle(fontSize: 20),
                          ),
                        ],
                      ),
                      SizedBox(height: 16),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(
                            isSameCoordinate ? Icons.location_on : Icons.location_off,
                            color: isSameCoordinate ? Colors.green : Colors.red,
                            size: 40,
                          ),
                          SizedBox(width: 10),
                          Text(
                            isSameCoordinate ? "Same Location" : "Different Location",
                            style: TextStyle(fontSize: 20),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
