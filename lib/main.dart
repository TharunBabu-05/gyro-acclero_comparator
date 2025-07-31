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
      options: const FirebaseOptions(
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
    print('Firebase initialized successfully');
  } catch (e) {
    print('Firebase initialization error: $e');
  }
  
  runApp(MyApp());
}

class MyApp extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Bus Fraud Detection',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(primarySwatch: Colors.red),
      home: BusFraudDetectionPage(),
    );
  }
}

class BusFraudDetectionPage extends StatefulWidget {
  @override
  _BusFraudDetectionPageState createState() => _BusFraudDetectionPageState();
}

class _BusFraudDetectionPageState extends State<BusFraudDetectionPage> {
  final database = FirebaseDatabase.instance.ref();
  StreamSubscription<AccelerometerEvent>? _accelSub;
  StreamSubscription<GyroscopeEvent>? _gyroSub;
  Timer? _gpsTimer;
  StreamSubscription? _otherDeviceSub;
  StreamSubscription? _passengerSessionListener;

  // Motion and sensor data
  List<double> _myAccel = [0, 0, 0];
  List<double> _otherAccel = [0, 0, 0];  
  List<double> _myGyro = [0, 0, 0];
  List<double> _otherGyro = [0, 0, 0];
  double _mySpeed = 0.0;
  double _otherSpeed = 0.0;
  
  // Location data
  double _myLatitude = 0.0;
  double _myLongitude = 0.0;
  double _otherLatitude = 0.0;
  double _otherLongitude = 0.0;

  // Status flags
  bool isSameMotion = false;
  bool isSameLocation = false;
  bool isSameCoordinate = false;
  bool isConnected = false;
  bool isValidatingTicket = false;
  bool fraudDetected = false;

  // Connection data
  String connectionKey = "";
  String? sessionKey;
  String deviceId = "bus_validator_${DateTime.now().millisecondsSinceEpoch}";
  String busId = "BUS_001";
  
  // Fraud detection variables
  String? currentPassengerId;
  int plannedExitStop = 0;
  int currentBusStop = 0;
  double correlationScore = 0.0;
  double penaltyAmount = 0.0;

  Future<bool> _checkLocationPermission() async {
    bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) {
      _showLocationDialog();
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

  void _showLocationDialog() {
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
  }

  @override
  void initState() {
    super.initState();
    _initializeApp();
  }

  Future<void> _initializeApp() async {
    bool hasPermission = await _checkLocationPermission();
    if (hasPermission) {
      _startFraudDetectionMode();
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

  void _startFraudDetectionMode() {
    // Start listening for new passenger sessions from Smart Ticket MTC
    _listenForPassengerSessions();
    // Start collecting this device's sensor data (bus data)
    _startListening();
    _startGpsUpdates();
    // Register this device as a bus validator
    _registerBusValidator();
  }

  void _registerBusValidator() {
    database.child('bus_validators/$busId').set({
      'deviceId': deviceId,
      'status': 'active',
      'route': 'Route_42',
      'current_stop': currentBusStop,
      'lastUpdate': ServerValue.timestamp,
    });
  }

  void _listenForPassengerSessions() {
    _passengerSessionListener = database.child('passenger_sessions').onChildAdded.listen((event) {
      final sessionData = event.snapshot.value as Map?;
      if (sessionData != null) {
        String sessionId = event.snapshot.key ?? '';
        String passengerId = sessionData['passenger_id'] ?? '';
        String ticketId = sessionData['ticket_id'] ?? '';
        int plannedExit = sessionData['planned_exit_stop'] ?? 0;
        String status = sessionData['status'] ?? '';
        
        if (sessionId.isNotEmpty && status == 'active') {
          _connectToPassenger(sessionId, passengerId, ticketId, plannedExit);
        }
      }
    });
  }

  void _connectToPassenger(String sessionId, String passengerId, String ticketId, int plannedExit) {
    setState(() {
      sessionKey = sessionId;
      connectionKey = sessionId;
      isValidatingTicket = true;
      currentPassengerId = passengerId;
      plannedExitStop = plannedExit;
      fraudDetected = false;
    });
    
    // Start listening to passenger's device sensor data
    _listenToPassengerDevice(sessionId, passengerId);
    
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('🚌 New passenger detected!\nTicket: $ticketId\nPlanned Exit: Stop $plannedExit'),
        duration: Duration(seconds: 4),
        backgroundColor: Colors.blue,
      ),
    );
  }

  void _startListening() {
    _accelSub = accelerometerEvents.listen((AccelerometerEvent event) {
      setState(() {
        _myAccel = [event.x, event.y, event.z];
      });
      _sendToFirebase();
      _compareMotionForFraudDetection();
    });

    _gyroSub = gyroscopeEvents.listen((GyroscopeEvent event) {
      setState(() {
        _myGyro = [event.x, event.y, event.z];
      });
      _sendToFirebase();
      _compareMotionForFraudDetection();
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

      try {
        Position position = await Geolocator.getCurrentPosition(
          desiredAccuracy: LocationAccuracy.high
        );
        setState(() {
          _mySpeed = position.speed;
          _myLatitude = position.latitude;
          _myLongitude = position.longitude;
        });
        _sendToFirebase();
        _compareMotionForFraudDetection();
      } catch (e) {
        print('GPS error: $e');
      }
    });
  }

  void _sendToFirebase() {
    if (sessionKey == null) return;
    
    // Send bus device data (this is the bus validator device)
    database.child('sessions/$sessionKey/$deviceId').set({
      'device_type': 'bus_validator',
      'bus_id': busId,
      'current_stop': currentBusStop,
      'accel': {'x': _myAccel[0], 'y': _myAccel[1], 'z': _myAccel[2]},
      'gyro': {'x': _myGyro[0], 'y': _myGyro[1], 'z': _myGyro[2]},
      'speed': _mySpeed,
      'location': {
        'latitude': _myLatitude,
        'longitude': _myLongitude,
      },
      'last_update': ServerValue.timestamp,
    }).then((_) {
      // Remove this device's data when disconnected
      database.child('sessions/$sessionKey/$deviceId')
        .onDisconnect()
        .remove();
    });
  }

  void _listenToPassengerDevice(String sessionId, String passengerId) {
    if (sessionId.isEmpty) return;

    // Cancel existing subscription if any
    _otherDeviceSub?.cancel();

    // Clear passenger device data
    setState(() {
      _otherAccel = [0, 0, 0];
      _otherGyro = [0, 0, 0];
      _otherSpeed = 0.0;
      _otherLatitude = 0.0;
      _otherLongitude = 0.0;
      isConnected = false;
    });

    // Listen for passenger device data using session ID
    _otherDeviceSub = database.child('sessions/$sessionId').onValue.listen((event) {
      final data = event.snapshot.value as Map?;
      if (data != null) {
        // Find passenger device (not the bus validator)
        String? passengerDeviceId;
        for (final key in data.keys) {
          final deviceData = data[key] as Map?;
          if (deviceData != null && deviceData['device_type'] == 'passenger') {
            passengerDeviceId = key;
            break;
          }
        }
        
        if (passengerDeviceId != null) {
          final passengerData = data[passengerDeviceId] as Map?;
          if (passengerData != null) {
            setState(() {
              final accel = passengerData['accel'] as Map?;
              if (accel != null) {
                _otherAccel = [
                  (accel['x'] ?? 0).toDouble(),
                  (accel['y'] ?? 0).toDouble(),
                  (accel['z'] ?? 0).toDouble(),
                ];
              }
              final gyro = passengerData['gyro'] as Map?;
              if (gyro != null) {
                _otherGyro = [
                  (gyro['x'] ?? 0).toDouble(),
                  (gyro['y'] ?? 0).toDouble(),
                  (gyro['z'] ?? 0).toDouble(),
                ];
              }
              final location = passengerData['location'] as Map?;
              if (location != null) {
                _otherLatitude = (location['latitude'] ?? 0).toDouble();
                _otherLongitude = (location['longitude'] ?? 0).toDouble();
              }
              _otherSpeed = (passengerData['speed'] ?? 0).toDouble();
              isConnected = true;
            });
            _compareMotionForFraudDetection();
          }
        }
      } else {
        setState(() {
          isConnected = false;
        });
      }
    }, onError: (error) {
      print("Error listening to passenger: $error");
    });
  }

  void _compareMotionForFraudDetection() {
    if (!mounted || !isConnected) return;
    
    const double accelThreshold = 3.0;  
    const double gyroThreshold = 1.0;   
    const double speedThreshold = 2.0;  
    const double locationThreshold = 5.0; 

    // Only compare if we have data from passenger device
    if (_otherAccel.every((val) => val == 0.0) && _otherGyro.every((val) => val == 0.0)) {
      setState(() {
        isSameMotion = false;
        isSameLocation = false;
        isSameCoordinate = false;
        correlationScore = 0.0;
      });
      return;
    }

    // Calculate distance between bus and passenger in meters
    final double distance = Geolocator.distanceBetween(
      _myLatitude, _myLongitude,
      _otherLatitude, _otherLongitude
    );

    // Calculate acceleration difference
    final double accelDiff = sqrt(
      pow(_myAccel[0] - _otherAccel[0], 2) +
      pow(_myAccel[1] - _otherAccel[1], 2) +
      pow(_myAccel[2] - _otherAccel[2], 2)
    );

    // Calculate gyroscope difference
    final double gyroDiff = sqrt(
      pow(_myGyro[0] - _otherGyro[0], 2) +
      pow(_myGyro[1] - _otherGyro[1], 2) +
      pow(_myGyro[2] - _otherGyro[2], 2)
    );

    // Calculate speed difference
    final double speedDiff = (_mySpeed - _otherSpeed).abs();

    // Calculate correlation score (higher = more similar motion)
    double accelScore = max(0.0, 1.0 - (accelDiff / 10.0));
    double gyroScore = max(0.0, 1.0 - (gyroDiff / 5.0));
    double speedScore = max(0.0, 1.0 - (speedDiff / 10.0));
    double locationScore = max(0.0, 1.0 - (distance / 50.0));
    
    setState(() {
      correlationScore = (accelScore + gyroScore + speedScore + locationScore) / 4.0;
      isSameMotion = accelDiff < accelThreshold && gyroDiff < gyroThreshold;
      isSameLocation = speedDiff < speedThreshold;
      isSameCoordinate = distance < locationThreshold;
    });

    // Check for fraud (passenger not actually on bus)
    bool isPassengerOnBus = correlationScore > 0.7 && isSameMotion && isSameLocation && isSameCoordinate;
    
    if (!isPassengerOnBus && currentBusStop > plannedExitStop) {
      // Fraud detected: passenger should have exited but is still being tracked
      _detectFraud();
    }

    // Store real-time validation data
    if (sessionKey != null && currentPassengerId != null) {
      database.child('fraud_detection/$sessionKey').set({
        'passenger_id': currentPassengerId,
        'bus_id': busId,
        'planned_exit_stop': plannedExitStop,
        'current_bus_stop': currentBusStop,
        'correlation_score': correlationScore,
        'is_on_bus': isPassengerOnBus,
        'motion_match': isSameMotion,
        'speed_match': isSameLocation,
        'location_match': isSameCoordinate,
        'distance_apart': distance,
        'last_update': ServerValue.timestamp,
      });
    }
  }

  void _detectFraud() {
    if (fraudDetected) return; // Already detected
    
    setState(() {
      fraudDetected = true;
    });

    int extraStops = currentBusStop - plannedExitStop;
    penaltyAmount = extraStops * 5.0; // ₹5 per extra stop

    // Store fraud detection result
    if (sessionKey != null && currentPassengerId != null) {
      database.child('fraud_detection/$sessionKey').update({
        'fraud_detected': true,
        'planned_exit_stop': plannedExitStop,
        'actual_exit_stop': currentBusStop,
        'extra_stops': extraStops,
        'penalty_amount': penaltyAmount,
        'fraud_timestamp': ServerValue.timestamp,
      });
    }

    // Show fraud alert
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('🚨 FRAUD DETECTED!\nPassenger $currentPassengerId\nExtra stops: $extraStops\nPenalty: ₹${penaltyAmount.toStringAsFixed(0)}'),
        backgroundColor: Colors.red,
        duration: Duration(seconds: 6),
      ),
    );
  }

  // Method to manually update bus stop (for demo purposes)
  void _updateBusStop(int newStop) {
    setState(() {
      currentBusStop = newStop;
    });
    
    database.child('bus_validators/$busId').update({
      'current_stop': currentBusStop,
      'lastUpdate': ServerValue.timestamp,
    });
  }

  @override
  void dispose() {
    _accelSub?.cancel();
    _gyroSub?.cancel();
    _gpsTimer?.cancel();
    _otherDeviceSub?.cancel();
    _passengerSessionListener?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('🚌 Bus Fraud Detection System'),
        backgroundColor: Colors.red[800],
        foregroundColor: Colors.white,
        actions: [
          // Bus stop controller
          Container(
            padding: EdgeInsets.symmetric(horizontal: 8.0),
            child: Row(
              children: [
                Text('Stop: ', style: TextStyle(color: Colors.white)),
                Container(
                  padding: EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text('$currentBusStop', 
                      style: TextStyle(color: Colors.red[800], fontWeight: FontWeight.bold)),
                ),
                IconButton(
                  icon: Icon(Icons.add, color: Colors.white),
                  onPressed: () => _updateBusStop(currentBusStop + 1),
                  tooltip: 'Next Stop',
                ),
              ],
            ),
          ),
          // Status indicator
          Container(
            padding: EdgeInsets.symmetric(horizontal: 16.0),
            child: Row(
              children: [
                Icon(
                  fraudDetected ? Icons.warning : (isValidatingTicket ? Icons.search : Icons.bus_alert),
                  color: fraudDetected ? Colors.orange : (isValidatingTicket ? Colors.green : Colors.white),
                ),
                SizedBox(width: 8),
                Text(
                  fraudDetected ? 'FRAUD!' : (isValidatingTicket ? 'Monitoring' : 'Ready'),
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                    color: fraudDetected ? Colors.orange : Colors.white,
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
              // Bus Validator Status
              Card(
                color: Colors.blue[50],
                child: Padding(
                  padding: EdgeInsets.all(16.0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Icon(Icons.directions_bus, color: Colors.blue[800], size: 24),
                          SizedBox(width: 8),
                          Text('Bus Validator - $busId', 
                              style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: Colors.blue[800])),
                        ],
                      ),
                      SizedBox(height: 10),
                      Text('Status: ${isValidatingTicket ? "Validating Passenger" : "Ready for Validation"}',
                           style: TextStyle(fontSize: 16, color: isValidatingTicket ? Colors.green[700] : Colors.orange[700])),
                      if (sessionKey != null) ...[
                        SizedBox(height: 5),
                        Text('Current Session: $sessionKey', style: TextStyle(fontSize: 14, color: Colors.grey[700])),
                      ],
                      SizedBox(height: 10),
                      Text('Accelerometer: X: ${_myAccel[0].toStringAsFixed(2)}, Y: ${_myAccel[1].toStringAsFixed(2)}, Z: ${_myAccel[2].toStringAsFixed(2)}'),
                      Text('Gyroscope: X: ${_myGyro[0].toStringAsFixed(2)}, Y: ${_myGyro[1].toStringAsFixed(2)}, Z: ${_myGyro[2].toStringAsFixed(2)}'),
                      Text('Speed: ${(_mySpeed * 3.6).toStringAsFixed(2)} km/h'),
                    ],
                  ),
                ),
              ),
              SizedBox(height: 16),
              
              // Passenger Device Data (when connected)
              if (isConnected) ...[
                Card(
                  color: Colors.green[50],
                  child: Padding(
                    padding: EdgeInsets.all(16.0),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Icon(Icons.smartphone, color: Colors.green[700], size: 24),
                            SizedBox(width: 8),
                            Text('Passenger Device', 
                                style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: Colors.green[700])),
                          ],
                        ),
                        SizedBox(height: 10),
                        Text('Accelerometer: X: ${_otherAccel[0].toStringAsFixed(2)}, Y: ${_otherAccel[1].toStringAsFixed(2)}, Z: ${_otherAccel[2].toStringAsFixed(2)}'),
                        Text('Gyroscope: X: ${_otherGyro[0].toStringAsFixed(2)}, Y: ${_otherGyro[1].toStringAsFixed(2)}, Z: ${_otherGyro[2].toStringAsFixed(2)}'),
                        Text('Speed: ${(_otherSpeed * 3.6).toStringAsFixed(2)} km/h'),
                        SizedBox(height: 8),
                        Text('Correlation Score: ${(correlationScore * 100).toStringAsFixed(1)}%', 
                             style: TextStyle(fontWeight: FontWeight.bold, 
                                            color: correlationScore > 0.7 ? Colors.green : Colors.red)),
                      ],
                    ),
                  ),
                ),
                SizedBox(height: 16),
              ],
              
              // Validation Status
              Card(
                color: isConnected ? Colors.white : Colors.grey[100],
                child: Padding(
                  padding: EdgeInsets.all(16.0),
                  child: Column(
                    children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(
                            isConnected ? Icons.phone_android : Icons.phone_android_outlined,
                            color: isConnected ? Colors.green : Colors.grey,
                            size: 24,
                          ),
                          SizedBox(width: 8),
                          Text(
                            isConnected ? "Passenger Connected" : "Waiting for passenger...",
                            style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                          ),
                        ],
                      ),
                      if (!isConnected) ...[
                        SizedBox(height: 8),
                        Text(
                          'Listening for new ticket purchases...',
                          style: TextStyle(fontSize: 14, color: Colors.grey[600]),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
              SizedBox(height: 16),
              
              // Validation Results (only show when connected)
              if (isConnected) ...[
                Card(
                  child: Padding(
                    padding: EdgeInsets.all(16.0),
                    child: Column(
                      children: [
                        Text('Validation Results', 
                             style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
                        SizedBox(height: 16),
                        
                        // Fraud Detection Status
                        Container(
                          padding: EdgeInsets.all(16),
                          decoration: BoxDecoration(
                            color: fraudDetected ? Colors.red[100] : Colors.green[100],
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(
                              color: fraudDetected ? Colors.red : Colors.green,
                              width: 2,
                            ),
                          ),
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(
                                fraudDetected ? Icons.error : Icons.verified_user,
                                color: fraudDetected ? Colors.red[700] : Colors.green[700],
                                size: 32,
                              ),
                              SizedBox(width: 12),
                              Expanded(
                                child: Column(
                                  children: [
                                    Text(
                                      fraudDetected ? "FRAUD DETECTED! ❌" : "PASSENGER VALIDATED ✅",
                                      style: TextStyle(
                                        fontSize: 18,
                                        fontWeight: FontWeight.bold,
                                        color: fraudDetected ? Colors.red[700] : Colors.green[700],
                                      ),
                                    ),
                                    if (fraudDetected) ...[
                                      SizedBox(height: 4),
                                      Text(
                                        'Penalty: ₹${penaltyAmount.toStringAsFixed(0)}',
                                        style: TextStyle(fontSize: 16, color: Colors.red[700]),
                                      ),
                                    ],
                                  ],
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
            ],
          ),
        ),
      ),
    );
  }
}
