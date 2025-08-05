import 'dart:async';
import 'dart:math';
import 'dart:convert';

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
        apiKey: 'AIzaSyBtVDQhS0UO0csQgzH9131sGgrMpUQdbfk',
        appId: '1:751952618795:android:371245ef36b575850b116e',
        messagingSenderId: '751952618795',
        projectId: 'smart-ticket-mtc',
        databaseURL: 'https://smart-ticket-mtc-default-rtdb.firebaseio.com',
        storageBucket: 'smart-ticket-mtc.firebasestorage.app',
      ),
    );
    
    // Test Firebase connection
    final database = FirebaseDatabase.instance;
    await database.ref('.info/connected').get();
    print('Firebase connection successful - Smart Ticket MTC');
    
  } catch (e) {
    print('Firebase initialization error: $e');
  }
  
  runApp(MyApp());
}

class MyApp extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Smart Ticket Fraud Detection',
      theme: ThemeData(primarySwatch: Colors.red),
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
  bool isMonitoring = false;

  String connectionKey = "";
  String? sessionKey;
  String? currentTicketCode;
  String deviceId = DateTime.now().millisecondsSinceEpoch.toString(); // Unique ID for each device
  
  // Ticket monitoring
  List<String> activeTickets = [];
  StreamSubscription? _ticketMonitorSub;

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

  // Start monitoring for new tickets in the smart ticket system
  void _startTicketMonitoring() {
    setState(() {
      isMonitoring = true;
    });
    
    print("Starting ticket monitoring...");
    
    // Monitor ticket_sensors for new ticket entries
    _ticketMonitorSub = database.child('ticket_sensors').onValue.listen((event) {
      final data = event.snapshot.value as Map?;
      if (data != null) {
        print("Found tickets in ticket_sensors: ${data.keys}");
        
        // Find the latest ticket (highest timestamp)
        String? latestTicket;
        int latestTimestamp = 0;
        
        for (final ticketCode in data.keys) {
          final ticketData = data[ticketCode] as Map?;
          if (ticketData != null && ticketData.containsKey('accelerometer')) {
            // Extract timestamp from ticket code (TKT_timestamp format)
            final timestampStr = ticketCode.toString().replaceFirst('TKT_', '');
            try {
              final timestamp = int.parse(timestampStr);
              if (timestamp > latestTimestamp) {
                latestTimestamp = timestamp;
                latestTicket = ticketCode.toString();
              }
            } catch (e) {
              print("Error parsing timestamp from ticket: $ticketCode");
            }
          }
        }
        
        if (latestTicket != null && !activeTickets.contains(latestTicket)) {
          print("Found latest active ticket: $latestTicket");
          activeTickets.add(latestTicket);
          _connectToTicket(latestTicket);
        }
      }
    }, onError: (error) {
      print("Error monitoring tickets: $error");
    });
  }

  // Connect to a specific ticket automatically
  void _connectToTicket(String ticketCode) {
    print("Auto-connecting to ticket: $ticketCode");
    setState(() {
      sessionKey = ticketCode;
      connectionKey = ticketCode;
      currentTicketCode = ticketCode;
    });
    _listenToOtherDevice();
  }

  // Decrypt sensor data (implement based on your encryption)
  Map<String, dynamic>? _decryptSensorData(String encryptedData) {
    try {
      print("Received encrypted data: ${encryptedData.substring(0, 50)}..."); // Debug log
      
      // Method 1: Try base64 decoding first
      try {
        String decoded = utf8.decode(base64.decode(encryptedData));
        print("Base64 decoded: $decoded"); // Debug log
        return json.decode(decoded);
      } catch (e) {
        print("Base64 decode failed: $e");
      }
      
      // Method 2: Try direct JSON parsing (if not encrypted)
      try {
        return json.decode(encryptedData);
      } catch (e) {
        print("Direct JSON parse failed: $e");
      }
      
      // Method 3: Custom decryption (you'll need to implement this based on your encryption key/algorithm)
      // For now, create mock data to test the connection
      print("Using mock data for testing");
      return {
        'accel': {'x': 1.5, 'y': 2.3, 'z': 9.8},
        'gyro': {'x': 0.1, 'y': 0.2, 'z': 0.05},
        'speed': 15.5,
        'location': {'latitude': 13.0827, 'longitude': 80.2707}
      };
      
    } catch (e) {
      print("Decryption error: $e");
      return null;
    }
  }

  Future<void> _initializeApp() async {
    bool hasPermission = await _checkLocationPermission();
    if (hasPermission) {
      _startTicketMonitoring(); // Start monitoring for new tickets automatically
      _startListening(); // Start local sensor monitoring
      _startGpsUpdates(); // Start GPS monitoring
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
    print("Starting sensor listeners...");
    // Use regular sensor streams for better compatibility
    _accelSub = accelerometerEvents.listen((AccelerometerEvent event) {
      print("Accel event: ${event.x}, ${event.y}, ${event.z}");
      setState(() {
        _myAccel = [event.x, event.y, event.z];
      });
      _sendToFirebase();
      _compareMotion();
    }, onError: (error) {
      print("Accelerometer error: $error");
    });

    _gyroSub = gyroscopeEvents.listen((GyroscopeEvent event) {
      print("Gyro event: ${event.x}, ${event.y}, ${event.z}");
      setState(() {
        _myGyro = [event.x, event.y, event.z];
      });
      _sendToFirebase();
      _compareMotion();
    }, onError: (error) {
      print("Gyroscope error: $error");
    });
  }

  void _startGpsUpdates() {
    // Reduce GPS frequency to avoid blocking sensor updates
    _gpsTimer = Timer.periodic(Duration(seconds: 5), (_) async {
      bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) return;

      LocationPermission permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
        if (permission == LocationPermission.deniedForever) return;
      }

      Position position = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.medium // Reduced accuracy for speed
      );
      setState(() {
        _mySpeed = position.speed; // speed in m/s
        _myLatitude = position.latitude;
        _myLongitude = position.longitude;
      });
      _sendToFirebase();
    });
  }

  void _sendToFirebase() {
    if (sessionKey == null) return;
    
    // Fast Firebase updates without waiting for response
    database.child('$sessionKey/admin_device').set({
      'accel': {'x': _myAccel[0], 'y': _myAccel[1], 'z': _myAccel[2]},
      'gyro': {'x': _myGyro[0], 'y': _myGyro[1], 'z': _myGyro[2]},
      'speed': _mySpeed,
      'location': {
        'latitude': _myLatitude,
        'longitude': _myLongitude,
      },
      'device_type': 'admin',
      'last_update': ServerValue.timestamp,
    }).catchError((error) {
      // Silent error handling to avoid blocking
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

    print("Listening to ticket data for: $sessionKey");

    // Listen for real sensor data from ticket_sensors path - optimized for speed
    _otherDeviceSub = database.child('ticket_sensors/$sessionKey').onValue.listen((event) {
      final data = event.snapshot.value as Map?;
      print("Raw ticket data received: $data"); // Debug log
      if (data != null) {
        try {
          // Process all data at once without multiple setState calls
          final accel = data['accelerometer'] as Map?;
          final gyro = data['gyroscope'] as Map?;
          final gps = data['gps'] as Map?;
          final speed = data['speed'];
          
          print("Accel data: $accel, Gyro data: $gyro"); // Debug log
          
          // Single setState for all updates - maximum speed
          setState(() {
            if (accel != null) {
              _otherAccel = [
                (accel['x'] ?? 0).toDouble(),
                (accel['y'] ?? 0).toDouble(),
                (accel['z'] ?? 0).toDouble(),
              ];
              print("Updated other accel: $_otherAccel"); // Debug log
            }
            
            if (gyro != null) {
              _otherGyro = [
                (gyro['x'] ?? 0).toDouble(),
                (gyro['y'] ?? 0).toDouble(),
                (gyro['z'] ?? 0).toDouble(),
              ];
              print("Updated other gyro: $_otherGyro"); // Debug log
            }
            
            if (gps != null) {
              _otherLatitude = (gps['latitude'] ?? 0).toDouble();
              _otherLongitude = (gps['longitude'] ?? 0).toDouble();
            }
            
            if (speed != null) {
              _otherSpeed = speed.toDouble();
            }
            
            isConnected = true;
          });
          
          // Immediate motion comparison for real-time feedback
          _compareMotion();
          
        } catch (e) {
          print("Error processing sensor data: $e");
        }
      } else {
        print("No data received for ticket: $sessionKey");
        setState(() {
          isConnected = false;
        });
      }
    }, onError: (error) {
      print("Error listening to ticket sensors: $error");
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
    _ticketMonitorSub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('Smart Ticket Fraud Detection'),
        backgroundColor: Colors.red,
        actions: [
          // Monitoring status
          Container(
            padding: EdgeInsets.symmetric(horizontal: 16.0),
            child: Row(
              children: [
                Icon(
                  isMonitoring ? Icons.radar : Icons.radar_outlined,
                  color: isMonitoring ? Colors.green : Colors.grey,
                ),
                SizedBox(width: 8),
                Text(
                  isMonitoring ? 'MONITORING' : 'OFFLINE',
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.bold,
                    color: isMonitoring ? Colors.green : Colors.grey,
                  ),
                ),
              ],
            ),
          ),
          // Current ticket status
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
                  currentTicketCode ?? 'No Ticket',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                    color: isConnected ? Colors.green : Colors.red,
                  ),
                ),
              ],
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
                      Text('Admin Device (Inspector)', 
                          style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: Colors.red)),
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
                      Text('Passenger Device (Ticket Holder)', 
                          style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: Colors.blue)),
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
                            isConnected ? "Connected to ticket holder" : "Waiting for ticket...",
                            style: TextStyle(fontSize: 16),
                          ),
                        ],
                      ),
                      if (!isConnected) ...[
                        SizedBox(height: 8),
                        Text(
                          'System Status:',
                          style: TextStyle(fontSize: 14, color: Colors.grey[600]),
                        ),
                        Text(
                          '• Monitoring smart ticket database',
                          style: TextStyle(fontSize: 14, color: Colors.grey[600]),
                        ),
                        Text(
                          '• Auto-connecting to new tickets',
                          style: TextStyle(fontSize: 14, color: Colors.grey[600]),
                        ),
                        Text(
                          '• Decrypting sensor data',
                          style: TextStyle(fontSize: 14, color: Colors.grey[600]),
                        ),
                        if (activeTickets.isNotEmpty) ...[
                          SizedBox(height: 8),
                          Text(
                            'Active Tickets: ${activeTickets.length}',
                            style: TextStyle(fontSize: 14, color: Colors.orange[600]),
                          ),
                        ],
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
                            isSameMotion ? "Motion Match" : "Motion Mismatch",
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
                            isSameLocation ? "Speed Match" : "Speed Mismatch",
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
                            isSameCoordinate ? "Location Match" : "Location Mismatch",
                            style: TextStyle(fontSize: 20),
                          ),
                        ],
                      ),
                      SizedBox(height: 16),
                      // Fraud detection summary
                      Container(
                        padding: EdgeInsets.all(16),
                        decoration: BoxDecoration(
                          color: (!isSameMotion || !isSameLocation || !isSameCoordinate) 
                                 ? Colors.red[100] : Colors.green[100],
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(
                            color: (!isSameMotion || !isSameLocation || !isSameCoordinate) 
                                   ? Colors.red : Colors.green,
                            width: 2,
                          ),
                        ),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(
                              (!isSameMotion || !isSameLocation || !isSameCoordinate) 
                                 ? Icons.warning : Icons.check_circle,
                              color: (!isSameMotion || !isSameLocation || !isSameCoordinate) 
                                     ? Colors.red : Colors.green,
                              size: 32,
                            ),
                            SizedBox(width: 10),
                            Text(
                              (!isSameMotion || !isSameLocation || !isSameCoordinate) 
                                 ? "FRAUD DETECTED!" : "No Fraud Detected",
                              style: TextStyle(
                                fontSize: 20,
                                fontWeight: FontWeight.bold,
                                color: (!isSameMotion || !isSameLocation || !isSameCoordinate) 
                                       ? Colors.red : Colors.green,
                              ),
                            ),
                          ],
                        ),
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
