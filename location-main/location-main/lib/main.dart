import 'package:flutter/material.dart';
import 'dart:async';
import 'dart:convert';
import 'package:geolocator/geolocator.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:flutter_app/filters/kalman.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
// Supabase config passed via dart-define
const String _supabaseUrl = String.fromEnvironment('SUPABASE_URL', defaultValue: '');
const String _supabaseAnonKey = String.fromEnvironment('SUPABASE_ANON_KEY', defaultValue: '');

enum TrackingMode {
  all,
  mapOnly,
  soundOnly,
}


class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  TrackingMode _mode = TrackingMode.all;
  final String _shareCode = 'ABC123';
  bool _isSoundOn = true;
  bool _isChildDevice = false; // whether this app instance acts as the child's device
  String? _parentName;
  final List<Map<String, String>> _children = [
    {'name': 'Alice', 'code': 'ABC123'},
    {'name': 'Bob', 'code': 'XYZ789'},
  ];
  int? _selectedChildIndex;
  Timer? _pollTimer;
  Position? _currentPosition;
  StreamSubscription<Position>? _positionSubscription;
  StreamSubscription? _remoteCommandSubscription;
  GoogleMapController? _mapController;
  final List<String> _logs = [];
  bool _showLogs = false;
  LocationPermission? _lastPermission;
  // Smoothing / filtering
  OneDKalman _kfLat = OneDKalman(q: 1e-4, r: 5e-3);
  OneDKalman _kfLng = OneDKalman(q: 1e-4, r: 5e-3);
  LatLng? _filteredLatLng;
  DateTime? _lastPositionTime;
  StreamSubscription? _supabaseStreamSubscription;
  int _distanceFilter = 5;
  // Tunables
  double _maxAccuracy = 100.0; // meters
  double _maxSpeed = 50.0; // m/s (~180 km/h) - drop improbable jumps
  int _restartAttempts = 0;


  @override
  void initState() {
    super.initState();
    _initApp();
  }

  Future<void> _initApp() async {
    try {
      if (_supabaseUrl.isNotEmpty && _supabaseAnonKey.isNotEmpty) {
        await Supabase.initialize(url: _supabaseUrl, anonKey: _supabaseAnonKey);
        _log('Initialized Supabase');
        _useSupabase = true;
      } else {
        _log('Supabase keys not provided; using local testing backend');
        _useSupabase = false;
      }
    } catch (e) {
      _log('Supabase init failed: $e');
      _useSupabase = false;
    }
    await _loadSettings();
    await _initLocationTracking();
  }

  bool _useSupabase = false;

  Future<void> _loadSettings() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final q = prefs.getDouble('kf_q');
      final r = prefs.getDouble('kf_r');
      final df = prefs.getInt('distance_filter');
      final ma = prefs.getDouble('max_accuracy');
      final ms = prefs.getDouble('max_speed');
      setState(() {
        if (q != null) {
          _kfLat.q = q;
          _kfLng.q = q;
        }
        if (r != null) {
          _kfLat.r = r;
          _kfLng.r = r;
        }
        if (df != null) _distanceFilter = df;
        if (ma != null) _maxAccuracy = ma;
        if (ms != null) _maxSpeed = ms;
      });
      _log('Loaded saved settings');
    } catch (e) {
      _log('Failed to load settings: $e');
    }
  }

  Future<void> _saveSettings() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setDouble('kf_q', _kfLat.q);
      await prefs.setDouble('kf_r', _kfLat.r);
      await prefs.setInt('distance_filter', _distanceFilter);
      await prefs.setDouble('max_accuracy', _maxAccuracy);
      await prefs.setDouble('max_speed', _maxSpeed);
      _log('Saved settings');
    } catch (e) {
      _log('Failed to save settings: $e');
    }
  }

  Future<void> _initLocationTracking() async {
    LocationPermission permission = await Geolocator.checkPermission();
    _lastPermission = permission;
    _log('Checked permission: $permission');
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
      _lastPermission = permission;
      _log('Requested permission: $permission');
      if (permission == LocationPermission.denied) return;
    }
    if (permission == LocationPermission.deniedForever) {
      _log('Permission denied forever');
      return;
    }

    try {
      final initial = await Geolocator.getCurrentPosition();
      _log('Initial position: ${initial.latitude}, ${initial.longitude} (acc: ${initial.accuracy})');
      setState(() {
        _currentPosition = initial;
      });
    } catch (e) {
      _log('Error getting initial position: $e');
    }

    _positionSubscription = Geolocator.getPositionStream(
      locationSettings: LocationSettings(
        accuracy: LocationAccuracy.bestForNavigation,
        distanceFilter: _distanceFilter,
      ),
    ).listen((Position position) async {
      try {
        _log('Raw update: ${position.latitude}, ${position.longitude} (acc: ${position.accuracy})');

        // Time delta
        final now = DateTime.now();
        double dt = 1.0;
        if (_lastPositionTime != null) {
          dt = now.difference(_lastPositionTime!).inMilliseconds / 1000.0;
          if (dt <= 0) dt = 1.0;
        }

        // Speed guard (compute using last filtered or raw position)
        double? lastLat = _filteredLatLng?.latitude ?? _currentPosition?.latitude;
        double? lastLng = _filteredLatLng?.longitude ?? _currentPosition?.longitude;
        bool drop = false;
        if (lastLat != null && lastLng != null) {
          final dist = Geolocator.distanceBetween(lastLat, lastLng, position.latitude, position.longitude);
          final speed = dist / dt; // m/s
          if (speed.isFinite && speed > _maxSpeed && position.accuracy > _maxAccuracy) {
            _log('Dropping jump: speed=${speed.toStringAsFixed(1)}m/s, acc=${position.accuracy}m');
            drop = true;
          }
        }

        if (!drop) {
          // Apply Kalman smoothing independently
          final double fLat = _kfLat.filter(position.latitude);
          final double fLng = _kfLng.filter(position.longitude);
          _filteredLatLng = LatLng(fLat, fLng);

          _lastPositionTime = now;
          setState(() {
            _currentPosition = position;
          });

          if (_mapController != null && _filteredLatLng != null) {
            await _mapController!.animateCamera(
              CameraUpdate.newLatLng(_filteredLatLng!),
            );
          }

          if (_mode == TrackingMode.soundOnly && _isSoundOn) {
            _playBeep();
          }
          // If running as a child device, publish filtered location to shared prefs for parents
          if (_isChildDevice) {
            final code = _children[_selectedChildIndex ?? 0]['code']!;
            _publishLocationForCode(code, _filteredLatLng!);
          }
        }
        _restartAttempts = 0;
      } catch (e, st) {
        _log('Error in position listener: $e');
        // attempt to recover subscription a few times
        _restartAttempts++;
        if (_restartAttempts < 4) {
          _log('Attempting to restart subscription ($_restartAttempts)');
          _positionSubscription?.cancel();
          Future.delayed(const Duration(seconds: 1), _initLocationTracking);
        } else {
          _log('Max restart attempts reached');
        }
      }
    }, onError: (e) {
      _log('Position stream error: $e');
    });
  }

  Future<void> _requestAlwaysPermission() async {
    _log('Requesting "always" permission');
    final p = await Geolocator.requestPermission();
    _lastPermission = p;
    _log('Permission result: $p');
    if (p == LocationPermission.deniedForever) {
      _log('Opening app settings because permission is denied forever');
      await Geolocator.openAppSettings();
    }
    setState(() {});
  }

  void _log(String message) {
    final ts = DateTime.now().toIso8601String();
    setState(() {
      _logs.insert(0, '[$ts] $message');
      if (_logs.length > 200) _logs.removeLast();
    });
  }



Future<void> _publishLocationForCode(String code, LatLng loc) async {
  try {
    if (_useSupabase) {
      final client = Supabase.instance.client;
      
      // Use the 'locations' table. 
      // upsert handles the logic: "If code exists, update it. If not, insert it."
      await client.from('locations').upsert({
        'code': code,
        'lat': loc.latitude,
        'lng': loc.longitude,
        'name': _children[_selectedChildIndex ?? 0]['name'] ?? 'child',
        'ts': DateTime.now().toIso8601String(),
      }, onConflict: 'code'); // This uses 'code' to find the existing row

      _log('Published to Supabase: $code');
    } else {
      // ... keep your existing SharedPreferences logic here ...
    }
  } catch (e) {
    _log('Failed to publish location: $e');
  }
}

  void _startPollingChild(String code) {
   _stopPollingChild(); // Cleans up previous subscriptions/timers

  if (_useSupabase) {
    _log('Starting Realtime stream for $code');
    _supabaseStreamSubscription = Supabase.instance.client
        .from('locations')
        .stream(primaryKey: ['id']) // Use 'id' here since it's your actual PK
        .eq('code', code)
        .listen((List<Map<String, dynamic>> data) {
      if (data.isNotEmpty) {
        final row = data.first;
        final lat = (row['lat'] as num).toDouble();
        final lng = (row['lng'] as num).toDouble();

        setState(() {
          _filteredLatLng = LatLng(lat, lng);
          _currentPosition = Position(
              longitude: lng,
              latitude: lat,
              timestamp: DateTime.now(),
              accuracy: 0, altitude: 0, heading: 0, speed: 0, speedAccuracy: 0);
        });

        if (_mapController != null) {
          _mapController!.animateCamera(CameraUpdate.newLatLng(_filteredLatLng!));
        }
      }
    });
        } else {
          final prefs = await SharedPreferences.getInstance();
          final s = prefs.getString('child:$code');
          if (s == null) return;
          final m = jsonDecode(s) as Map<String, dynamic>;
          final lat = (m['lat'] as num).toDouble();
          final lng = (m['lng'] as num).toDouble();
          final ts = m['ts'] as String;
          _log('Polled child $code @ $ts -> $lat,$lng');
          setState(() {
            _filteredLatLng = LatLng(lat, lng);
            _currentPosition = Position(
                longitude: lng,
                latitude: lat,
                timestamp: DateTime.parse(ts),
                accuracy: 0,
                altitude: 0,
                heading: 0,
                speed: 0,
                speedAccuracy: 0);
          });
          if (_mapController != null) {
            _mapController!.animateCamera(CameraUpdate.newLatLng(_filteredLatLng!));
          }
        }
      } catch (e) {
        _log('Polling error: $e');
      }
    });
  }


  void _stopPollingChild() {
    _pollTimer?.cancel();
    _pollTimer = null;
    _supabaseStreamSubscription?.cancel(); // Add this line
  _supabaseStreamSubscription = null;
  }
  void _listenForRemoteCommands() {
    _remoteCommandSubscription?.cancel(); // Clear any old subscription first
    
    if (!_useSupabase || !_isChildDevice) return;

    final code = _children[_selectedChildIndex ?? 0]['code']!;
    _log('Listening for remote commands for $code...');

    _remoteCommandSubscription = Supabase.instance.client
        .from('remote_commands')
        .stream(primaryKey: ['id'])
        .eq('child_code', code)
        .listen((data) {
      if (data.isNotEmpty) {
        final lastCommand = data.last;
        // Check if the command is 'beep' and it's fresh (e.g., within last 30s)
        if (lastCommand['command'] == 'beep') {
          _playBeep();
          _log('Remote beep received from parent!');
        }
      }
    });
  }

  void _resetFilters() {
    _kfLat.reset();
    _kfLng.reset();
    _filteredLatLng = null;
    setState(() {
      _logs.clear();
    });
    _log('Filters reset');
  }

@override
  void dispose() {
    _positionSubscription?.cancel();
    _mapController?.dispose();
    _stopPollingChild();
    _remoteCommandSubscription?.cancel(); // <--- Add this line
    super.dispose();
  }

  void _playBeep() {
    if (_mode == TrackingMode.soundOnly && _isSoundOn) {
      final player = AudioPlayer();
      player.play(AssetSource('sounds/beep.mp3'));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Tracking App')),
      body: Column(
        children: [
         Text('Share Code: $_shareCode'),
         // Permission prompt banner
         if (_lastPermission == LocationPermission.whileInUse)
           Card(
             color: Colors.orange[50],
             margin: const EdgeInsets.all(8.0),
             child: ListTile(
               leading: const Icon(Icons.info_outline),
               title: const Text('Background tracking disabled'),
               subtitle: const Text('Request "Always" location permission for background tracking'),
               trailing: ElevatedButton(
                 onPressed: _requestAlwaysPermission,
                 child: const Text('Request Always'),
               ),
             ),
           ),
         // Tunables and Toggle logs
         Card(
           margin: const EdgeInsets.symmetric(horizontal: 8.0, vertical: 4.0),
           child: Padding(
             padding: const EdgeInsets.all(8.0),
             child: Column(
               crossAxisAlignment: CrossAxisAlignment.start,
               children: [
                 const Text('Filters & Tunables', style: TextStyle(fontWeight: FontWeight.bold)),
                 Row(children: [
                   const Text('Kalman q:'),
                   Expanded(
                     child: Slider.adaptive(
                       value: _kfLat.q,
                       min: 0.00001,
                       max: 0.01,
                       divisions: 1000,
                       label: _kfLat.q.toStringAsPrecision(2),
                      onChanged: (v) {
                        setState(() {
                          _kfLat.q = v;
                          _kfLng.q = v;
                        });
                        _saveSettings();
                      },
                     ),
                   ),
                   Text(_kfLat.q.toStringAsExponential(1)),
                 ]),
                 Row(children: [
                   const Text('Kalman r:'),
                   Expanded(
                     child: Slider.adaptive(
                       value: _kfLat.r,
                       min: 0.0001,
                       max: 0.1,
                       divisions: 1000,
                       label: _kfLat.r.toStringAsPrecision(2),
                      onChanged: (v) {
                        setState(() {
                          _kfLat.r = v;
                          _kfLng.r = v;
                        });
                        _saveSettings();
                      },
                     ),
                   ),
                   Text(_kfLat.r.toStringAsExponential(1)),
                 ]),
                 Row(children: [
                   const Text('Distance filter (m):'),
                   const SizedBox(width: 8),
                   SizedBox(
                     width: 100,
                     child: TextFormField(
                       initialValue: _distanceFilter.toString(),
                       keyboardType: TextInputType.number,
                       onFieldSubmitted: (v) {
                         final parsed = int.tryParse(v) ?? _distanceFilter;
                         setState(() {
                           _distanceFilter = parsed;
                           // restart subscription to apply new distance filter
                           _positionSubscription?.cancel();
                           _initLocationTracking();
                         });
                         _saveSettings();
                       },
                     ),
                   ),
                   const SizedBox(width: 12),
                   ElevatedButton(onPressed: _resetFilters, child: const Text('Reset Filters')),
                 ]),
                 const SizedBox(height: 8),
                 Row(children: [
                   const Text('Max accuracy (m):'),
                   const SizedBox(width: 8),
                   Expanded(
                     child: Slider.adaptive(
                       value: _maxAccuracy,
                       min: 5,
                       max: 500,
                       divisions: 99,
                       label: '${_maxAccuracy.toStringAsFixed(0)} m',
                        onChanged: (v) => setState(() { _maxAccuracy = v; _saveSettings(); }),
                     ),
                   ),
                   SizedBox(width: 64, child: Text('${_maxAccuracy.toStringAsFixed(0)} m')),
                 ]),
                 Row(children: [
                   const Text('Max speed (m/s):'),
                   const SizedBox(width: 8),
                   Expanded(
                     child: Slider.adaptive(
                       value: _maxSpeed,
                       min: 1,
                       max: 100,
                       divisions: 99,
                       label: '${_maxSpeed.toStringAsFixed(0)} m/s',
                        onChanged: (v) => setState(() { _maxSpeed = v; _saveSettings(); }),
                     ),
                   ),
                   SizedBox(width: 64, child: Text('${_maxSpeed.toStringAsFixed(0)} m/s')),
                 ]),
               ],
             ),
           ),
         ),
         // Toggle logs
         Row(
           mainAxisAlignment: MainAxisAlignment.end,
           children: [
             TextButton.icon(
               onPressed: () => setState(() => _showLogs = !_showLogs),
               icon: const Icon(Icons.notes),
               label: Text(_showLogs ? 'Hide Logs' : 'Show Logs'),
             ),
           ],
         ),
          // Tracking Mode Selection
         SegmentedButton<TrackingMode>(
  segments: const [
    ButtonSegment(value: TrackingMode.all, label: Text('All Systems')),
    ButtonSegment(value: TrackingMode.mapOnly, label: Text('Map Only')),
    ButtonSegment(value: TrackingMode.soundOnly, label: Text('Sound Only')),
  ],
  selected: {_mode},
  onSelectionChanged: (Set<TrackingMode> newSelection) {
    setState(() {
      _mode = newSelection.first;
    });
  },
),

         // Role: act as child device toggle
         SwitchListTile(
           title: const Text('Act as Child Device (publish location for parents)'),
           value: _isChildDevice,
           onChanged: (v) {
             setState(() {
               _isChildDevice = v;
               if (v) {
                 // ensure a child entry exists for this device
                 if (_selectedChildIndex == null) {
                   _children.add({'name': 'ThisDevice', 'code': _shareCode});
                   _selectedChildIndex = _children.length - 1;
                 }
                 // stop polling when acting as child
                 _stopPollingChild();
                 _listenForRemoteCommands();
                 } else {
                  _remoteCommandSubscription?.cancel(); // <--- Add this line here
                
               }
             });
           },
         ),

          // Location Display
          if (_currentPosition != null) ...[
            Builder(builder: (context) {
              final lat = _filteredLatLng?.latitude ?? _currentPosition!.latitude;
              final lng = _filteredLatLng?.longitude ?? _currentPosition!.longitude;
              return Text('Lat: ${lat.toStringAsFixed(6)}, Lng: ${lng.toStringAsFixed(6)}');
            }),
            if (_mode != TrackingMode.soundOnly)
              SizedBox(
                height: 200,
                child: GoogleMap(
                  initialCameraPosition: CameraPosition(
                    target: LatLng(_currentPosition!.latitude, _currentPosition!.longitude),
                    zoom: 15,
                  ),
                ),
              ),
          ],
          // Sound Toggle
          if (_mode == TrackingMode.soundOnly)
            SwitchListTile(
              title: const Text('Enable Sound'),
              value: _isSoundOn,
              onChanged: (bool value) {
                setState(() {
                  _isSoundOn = value;
                  if (_isSoundOn) _playBeep();
                });
              },
            ),
          // Parent / Child UI
          if (_parentName == null) 
            Padding(
              padding: const EdgeInsets.all(16.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Parent Login', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 8),
                  TextField(
                    decoration: const InputDecoration(labelText: 'Parent name'),
                    onSubmitted: (v) {
                      if (v.trim().isEmpty) return;
                      setState(() {
                        _parentName = v.trim();
                      });
                    },
                  ),
                  const SizedBox(height: 8),
                  const Text('Or enter child share code below to view without logging in'),
                ],
              ),
            )
          else
            Padding(
              padding: const EdgeInsets.all(8.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Parent: $_parentName', style: const TextStyle(fontWeight: FontWeight.bold)),
                  const SizedBox(height: 8),
                  const Text('Children', style: TextStyle(fontWeight: FontWeight.bold)),
                  SizedBox(
                    height: 120,
                    child: ListView.builder(
                      itemCount: _children.length,
                      itemBuilder: (context, i) {
                        final child = _children[i];
                        final selected = i == _selectedChildIndex;
                        return ListTile(
                          title: Text(child['name']!),
                          subtitle: Text('Code: ${child['code']}'),
                          trailing: selected ? const Icon(Icons.check_circle, color: Colors.green) : null,
                          onTap: () {
                            setState(() {
                              _selectedChildIndex = i;
                              // start polling the selected child's published location
                              _startPollingChild(child['code']!);
                            });
                          },
                        );
                      },
                    ),
                  ),
                ],
              ),
            ),

          // Enter share code to add/select child (works whether logged in or not)
          Padding(
            padding: const EdgeInsets.all(16.0),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: TextEditingController(text: ''),
                    decoration: const InputDecoration(
                      labelText: 'Enter Share Code',
                      hintText: 'e.g., ABC123',
                    ),
                    onSubmitted: (code) {
                      final c = code.trim();
                      if (c.isEmpty) return;
                      final idx = _children.indexWhere((ch) => ch['code'] == c);
                      if (idx >= 0) {
                        setState(() {
                          _selectedChildIndex = idx;
                        });
                        _log('Selected child ${_children[idx]['name']} by code');
                        _startPollingChild(_children[idx]['code']!);
                      } else {
                        // Add a new child entry (unknown name)
                        setState(() {
                          _children.add({'name': 'Child', 'code': c});
                          _selectedChildIndex = _children.length - 1;
                        });
                        _log('Added new child with code $c');
                        _startPollingChild(c);
                      }
                    },
                  ),
                ),
                const SizedBox(width: 8),
                ElevatedButton(
                  onPressed: () {
                    setState(() {
                      _parentName = null;
                      _selectedChildIndex = null;
                      _stopPollingChild();
                    });
                  },
                  child: const Text('Logout'),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
