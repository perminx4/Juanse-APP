import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart' hide BluetoothService;
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:permission_handler/permission_handler.dart';
import '../services/bluetooth_service.dart';
import '../services/settings_service.dart';
import 'settings_screen.dart';

class ControlScreen extends StatefulWidget {
  const ControlScreen({super.key});
  @override
  State<ControlScreen> createState() => _ControlScreenState();
}

class _ControlScreenState extends State<ControlScreen> {
  final Map<String, double> _controlValues = {
    'kp': 3.0, 'ki': 0.0, 'kd': 35.0, 'vm': 255.0,
  };
  Map<String, double> _previousControlValues = {};
  bool _valuesInitialized = false;

  final Map<String, Map<String, double>> _parameterRanges = {
    'kp': {'min': 0, 'max': 20},
    'ki': {'min': 0, 'max': 1},
    'kd': {'min': 0, 'max': 100},
    'vm': {'min': 100, 'max': 255},
  };

  Future<void> _saveProfile() async {
    final profileNameController = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Guardar Perfil'),
        content: TextField(
          controller: profileNameController,
          decoration: const InputDecoration(hintText: "Nombre del perfil"),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancelar')),
          TextButton(onPressed: () => Navigator.of(context).pop(profileNameController.text), child: const Text('Guardar')),
        ],
      ),
    );
    if (name != null && name.isNotEmpty) {
      final prefs = await SharedPreferences.getInstance();
      final profileData = jsonEncode(_controlValues);
      await prefs.setString('profile_$name', profileData);
      _showFeedback('Perfil "$name" guardado.');
    }
  }

  Future<void> _loadProfile() async {
    final prefs = await SharedPreferences.getInstance();
    final keys = prefs.getKeys();
    final profileNames = keys.where((key) => key.startsWith('profile_')).map((key) => key.substring(8)).toList();
    if (profileNames.isEmpty) { _showFeedback('No hay perfiles guardados.'); return; }
    final selectedProfile = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Cargar Perfil'),
        content: SizedBox(
          width: double.maxFinite,
          child: ListView.builder(
            shrinkWrap: true,
            itemCount: profileNames.length,
            itemBuilder: (context, index) => ListTile(
              title: Text(profileNames[index]),
              onTap: () => Navigator.of(context).pop(profileNames[index]),
            ),
          ),
        ),
      ),
    );
    if (selectedProfile != null) {
      final profileData = prefs.getString('profile_$selectedProfile');
      if (profileData != null) {
        final decodedData = jsonDecode(profileData) as Map<String, dynamic>;
        setState(() {
          _controlValues.forEach((key, value) {
            _controlValues[key] = (decodedData[key] ?? 0.0).toDouble();
          });
        });
        _controlValues.forEach((key, value) {
          _sendControlValue(key, value);
        });
        _showFeedback('Perfil "$selectedProfile" cargado.');
      }
    }
  }

  void _showFeedback(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message), duration: const Duration(seconds: 1)));
  }

  void _sendControlValue(String command, double value) {
    final bluetoothService = Provider.of<BluetoothService>(context, listen: false);
    String key = command.toLowerCase();
    if (key == 've') key = 'vm';

    String formattedValue;
    if (key == 'ki') {
      formattedValue = value.toStringAsFixed(2);
    } else if (['kp', 'kd'].contains(key)) {
      formattedValue = value.toStringAsFixed(1);
    } else {
      formattedValue = value.toInt().toString();
    }
    bluetoothService.sendCommand("$key:$formattedValue");
    _showFeedback('Enviado: $key:$formattedValue');
  }

  void _sendOnOffCommand(String command) {
    Provider.of<BluetoothService>(context, listen: false).sendCommand(command);
    _showFeedback('Comando "$command" enviado.');
  }

  void _syncValuesFromDevice(BluetoothService service) {
    if (!_valuesInitialized) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          setState(() {
            _controlValues['kp'] = double.tryParse(service.kp) ?? _controlValues['kp']!;
            _controlValues['ki'] = double.tryParse(service.ki) ?? _controlValues['ki']!;
            _controlValues['kd'] = double.tryParse(service.kd) ?? _controlValues['kd']!;
            _controlValues['vm'] = double.tryParse(service.ve) ?? _controlValues['vm']!;

            _valuesInitialized = true;
          });
        }
      });
    } else if (service.hasFreshConfigPayload) {
      service.consumeFreshConfigPayload();

      Map<String, double> incomingRobotVals = {
        'kp': double.tryParse(service.kp) ?? _controlValues['kp']!,
        'ki': double.tryParse(service.ki) ?? _controlValues['ki']!,
        'kd': double.tryParse(service.kd) ?? _controlValues['kd']!,
        'vm': double.tryParse(service.ve) ?? _controlValues['vm']!,
      };

      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          setState(() {
            _previousControlValues = Map<String, double>.from(_controlValues);
            _controlValues.addAll(incomingRobotVals);
          });
        }
      });
    }
  }

  double _getRobotValue(String key, BluetoothService service) {
    switch (key) {
      case 'kp': return double.tryParse(service.kp) ?? _controlValues['kp']!;
      case 'ki': return double.tryParse(service.ki) ?? _controlValues['ki']!;
      case 'kd': return double.tryParse(service.kd) ?? _controlValues['kd']!;
      case 'vm':
      case 've': return double.tryParse(service.ve) ?? _controlValues['vm']!;
      case 'mc': return double.tryParse(service.mc) ?? _controlValues['mc']!;
      case 'ab': return double.tryParse(service.ab) ?? _controlValues['ab']!;
      case 'vb': return double.tryParse(service.vb) ?? _controlValues['vb']!;
      case 'fb': return double.tryParse(service.fb) ?? _controlValues['fb']!;
      case 'kf': return double.tryParse(service.kf) ?? _controlValues['kf']!;
      case 'psup': return double.tryParse(service.pSup) ?? _controlValues['psup']!;
      case 'pinf': return double.tryParse(service.pInf) ?? _controlValues['pinf']!;
      default: return _controlValues[key] ?? 0.0;
    }
  }

  bool _isDifferentFromRobot(String key, BluetoothService service) {
    if (!service.isConnected) return false;
    final double robotVal = _getRobotValue(key, service);
    final double appVal = _controlValues[key] ?? 0.0;
    final double tolerance = key == 'ki' ? 0.005 : 0.05;
    return (robotVal - appVal).abs() > tolerance;
  }

  Future<void> _editValueWithKeyboard(String key) async {
    final textController = TextEditingController(text: _controlValues[key].toString());
    final newValue = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Editar ${key.toUpperCase()}'),
        content: TextField(
          controller: textController,
          keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true),
          autofocus: true,
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancelar')),
          TextButton(onPressed: () => Navigator.of(context).pop(textController.text), child: const Text('Aceptar')),
        ],
      ),
    );
    if (newValue != null) {
      final doubleValue = double.tryParse(newValue);
      if (doubleValue != null) {
        final min = _parameterRanges[key]!['min']!;
        final max = _parameterRanges[key]!['max']!;
        setState(() {
          _controlValues[key] = doubleValue.clamp(min, max);
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Control y Parámetros'),
        actions: [
          IconButton(
            icon: const Icon(Icons.settings),
            tooltip: 'Ajustes',
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(builder: (context) => const SettingsScreen()),
              );
            },
          ),
          Consumer<BluetoothService>(
            builder: (context, service, child) {
              if (!service.isConnected) return const SizedBox.shrink();
              return IconButton(
                icon: const Icon(Icons.bluetooth_disabled),
                tooltip: 'Desconectar',
                onPressed: () => service.disconnect(),
              );
            },
          ),
        ],
      ),
      body: Column(
        children: [
          _buildStatusBanner(),
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(12.0),
              child: Consumer<BluetoothService>(
                builder: (context, service, child) {
                  if (service.isConnected && service.initialDataReceived) {
                    _syncValuesFromDevice(service);
                  }
                  if (service.isConnecting) {
                    return const Center(heightFactor: 5, child: CircularProgressIndicator());
                  }
                  if (!service.isConnected && !_valuesInitialized) {
                    return _buildConnectionUI(context, service);
                  }
                  return _buildControlUI(service);
                },
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildStatusBanner() {
    return Consumer<BluetoothService>(
      builder: (context, service, child) {
        if (service.isLowBattery) {
          return Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            color: Colors.red[900],
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(Icons.battery_alert, color: Colors.white, size: 20),
                const SizedBox(width: 8),
                Text(
                  '⚠️ ¡ALERTA BATERÍA BAJA: ${service.bat} V (< 10.8V)!',
                  style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 13),
                ),
              ],
            ),
          );
        }

        if (!service.isConnected) {
          return Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            color: Colors.red[800],
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Row(
                  children: [
                    Icon(Icons.bluetooth_disabled, color: Colors.white, size: 16),
                    SizedBox(width: 6),
                    Text(
                      'Desconectado',
                      style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 12),
                    ),
                  ],
                ),
                TextButton.icon(
                  style: TextButton.styleFrom(
                    foregroundColor: Colors.white,
                    backgroundColor: Colors.white24,
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  ),
                  icon: const Icon(Icons.replay, size: 14),
                  label: const Text('Reconectar Robot', style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold)),
                  onPressed: () async {
                    _showFeedback("Buscando robot para reconectar...");
                    bool success = await service.reconnectToLastDevice();
                    if (!success) {
                      _showFeedback("No se encontró el robot guardado.");
                    }
                  },
                ),
              ],
            ),
          );
        }

        return Container(
          width: double.infinity,
          padding: const EdgeInsets.all(8.0),
          color: Colors.green[800],
          child: Text(
            'Conectado a: ${service.deviceName} (${service.rssi} dBm)',
            textAlign: TextAlign.center,
            style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
          ),
        );
      },
    );
  }

  Widget _buildConnectionUI(BuildContext context, BluetoothService service) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(Icons.bluetooth_searching, size: 90, color: Colors.blueAccent),
          const SizedBox(height: 20),
          const Text('Busca un dispositivo BLE o reconecta al último.'),
          const SizedBox(height: 20),
          ElevatedButton.icon(
            icon: const Icon(Icons.search),
            label: const Text('Buscar Dispositivos BLE'),
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.blueAccent,
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
            ),
            onPressed: () => _showDeviceList(context, service),
          ),
          const SizedBox(height: 10),
          if (service.lastDeviceAddress.isNotEmpty)
            OutlinedButton.icon(
              icon: const Icon(Icons.replay),
              label: const Text('Reconectar Rápido'),
              style: OutlinedButton.styleFrom(foregroundColor: Colors.blueAccent),
              onPressed: () async {
                bool success = await service.reconnectToLastDevice();
                if (!success) {
                  _showFeedback('No se pudo reconectar.');
                }
              },
            ),
          const SizedBox(height: 24),
          const Divider(),
          const SizedBox(height: 12),
          OutlinedButton.icon(
            icon: const Icon(Icons.visibility),
            label: const Text('PROBAR INTERFAZ (SIN ROBOT)'),
            style: OutlinedButton.styleFrom(
              foregroundColor: Colors.blueAccent,
              side: const BorderSide(color: Colors.blueAccent, width: 1.5),
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
            ),
            onPressed: () {
              setState(() {
                _valuesInitialized = true;
              });
            },
          ),
        ],
      ),
    );
  }

  Future<void> _showDeviceList(BuildContext context, BluetoothService service) async {
    if (Theme.of(context).platform == TargetPlatform.android) {
      Map<Permission, PermissionStatus> statuses = await [
        Permission.bluetoothScan,
        Permission.bluetoothConnect,
        Permission.location,
      ].request();

      if ((statuses[Permission.bluetoothScan]?.isDenied ?? false) ||
          (statuses[Permission.bluetoothConnect]?.isDenied ?? false)) {
        _showFeedback("Se necesitan permisos de Bluetooth para buscar dispositivos.");
        return;
      }
    }

    if (!mounted) return;
    service.startScan();

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (context) {
        return SizedBox(
          height: MediaQuery.of(context).size.height * 0.7,
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.all(16.0),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text(
                      "Dispositivos BLE Encontrados",
                      style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                    ),
                    IconButton(
                      icon: const Icon(Icons.refresh),
                      onPressed: () => service.startScan(),
                    ),
                  ],
                ),
              ),
              const Divider(height: 1),
              Expanded(
                child: StreamBuilder<List<ScanResult>>(
                  stream: FlutterBluePlus.scanResults,
                  initialData: const [],
                  builder: (context, snapshot) {
                    final results = List<ScanResult>.from(snapshot.data ?? []);
                    results.sort((a, b) => b.rssi.compareTo(a.rssi));

                    if (results.isEmpty) {
                      return const Center(
                        child: Text("Buscando dispositivos BLE en el entorno..."),
                      );
                    }

                    return ListView.builder(
                      itemCount: results.length,
                      itemBuilder: (context, index) {
                        final r = results[index];
                        String name = r.device.platformName;
                        if (name.isEmpty) name = r.advertisementData.advName;
                        if (name.isEmpty) name = "Dispositivo oculto";

                        final rssi = r.rssi;
                        Color rssiColor = Colors.red;
                        if (rssi > -60) {
                          rssiColor = Colors.green;
                        } else if (rssi > -80) {
                          rssiColor = Colors.orange;
                        }

                        return ListTile(
                          leading: CircleAvatar(
                            backgroundColor: Colors.blueAccent.withValues(alpha: 0.2),
                            child: const Icon(Icons.bluetooth_searching, color: Colors.blueAccent),
                          ),
                          title: Text(name, style: const TextStyle(fontWeight: FontWeight.bold)),
                          subtitle: Text(
                            "ID: ${r.device.remoteId}\nSeñal: $rssi dBm",
                            style: TextStyle(fontSize: 12, color: rssiColor),
                          ),
                          trailing: ElevatedButton(
                            style: ElevatedButton.styleFrom(
                              backgroundColor: Colors.blueAccent,
                              foregroundColor: Colors.white,
                            ),
                            onPressed: () {
                              Navigator.of(context).pop();
                              service.connectToDevice(r.device);
                            },
                            child: const Text("Conectar"),
                          ),
                        );
                      },
                    );
                  },
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  // --- ESTRUCTURA DE LA PANTALLA ---
  Widget _buildControlUI(BluetoothService service) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _buildActionButtons(service),
        const SizedBox(height: 12),
        _buildParameterControls(service),
        const SizedBox(height: 12),
        _buildProfileManagement(),

        const SizedBox(height: 20),
        Row(
          children: [
            Expanded(child: Divider(color: service.isLowBattery ? Colors.redAccent : Colors.blueAccent, thickness: 1)),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8.0),
              child: Text(
                "TELEMETRÍA ROBOT",
                style: TextStyle(color: service.isLowBattery ? Colors.redAccent : Colors.blueAccent, fontSize: 12, fontWeight: FontWeight.bold),
              ),
            ),
            Expanded(child: Divider(color: service.isLowBattery ? Colors.redAccent : Colors.blueAccent, thickness: 1)),
          ],
        ),
        const SizedBox(height: 12),

        _buildCriticalDataDisplay(service),
        const SizedBox(height: 12),
        _buildSensorArrayView(service),
        const SizedBox(height: 12),
        _buildDataDisplay(service),
      ],
    );
  }

  // --- COMANDOS DEL ROBOT ---
  Widget _buildActionButtons(BluetoothService service) {
    final bool isCorriendo = service.isConnected && service.estadoVal == 1;
    final bool canCalibrateOrSave = !isCorriendo;
    final bool isWhiteTrack = service.lineaBlanca == "1";
    final Color themeColor = service.isLowBattery ? Colors.redAccent : Colors.blueAccent;

    return Card(
      elevation: 3,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Padding(
        padding: const EdgeInsets.all(12.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (!service.isConnected)
              Container(
                margin: const EdgeInsets.only(bottom: 10),
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                decoration: BoxDecoration(
                  color: Colors.redAccent.withValues(alpha: 0.15),
                  border: Border.all(color: Colors.redAccent.withValues(alpha: 0.5)),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Row(
                      children: [
                        Icon(Icons.bluetooth_disabled, color: Colors.redAccent, size: 18),
                        SizedBox(width: 8),
                        Text("Robot Desconectado", style: TextStyle(color: Colors.redAccent, fontWeight: FontWeight.bold, fontSize: 12)),
                      ],
                    ),
                    ElevatedButton.icon(
                      icon: const Icon(Icons.replay, size: 14),
                      label: const Text("Reconectar", style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold)),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.blueAccent,
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
                      ),
                      onPressed: () async {
                        _showFeedback("Buscando robot para reconectar...");
                        bool success = await service.reconnectToLastDevice();
                        if (!success) {
                          _showFeedback("No se encontró el robot.");
                        }
                      },
                    ),
                  ],
                ),
              ),

            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text('Comandos del Robot', style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold, color: themeColor)),
                Row(
                  children: [
                    if (isCorriendo)
                      const Padding(
                        padding: EdgeInsets.only(right: 4.0),
                        child: Text('🔒 Corriendo', style: TextStyle(color: Colors.amberAccent, fontSize: 11, fontWeight: FontWeight.bold)),
                      ),
                    SizedBox(
                      width: 32,
                      height: 32,
                      child: IconButton(
                        padding: EdgeInsets.zero,
                        icon: Icon(Icons.refresh, color: themeColor, size: 20),
                        tooltip: 'Refrescar Parámetros Completo (refresh)',
                        onPressed: () => _sendOnOffCommand('refresh'),
                      ),
                    ),
                  ],
                ),
              ],
            ),
            const Divider(height: 12),
            const SizedBox(height: 6),

            // --- FILA 1: START (VERDE) Y STOP (ROJO) ---
            Row(
              children: [
                Expanded(
                  child: ElevatedButton.icon(
                    icon: const Icon(Icons.play_arrow, size: 20),
                    label: const Text('Start', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.green[700],
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                    ),
                    onPressed: () => _sendOnOffCommand('on'),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: ElevatedButton.icon(
                    icon: const Icon(Icons.stop, size: 20),
                    label: const Text('Stop', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.red[700],
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                    ),
                    onPressed: () => _sendOnOffCommand('off'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),

            // --- FILA 2: CALIBRAR, GUARDAR Y SWITCH PISTA N/B ---
            Row(
              children: [
                Expanded(
                  flex: 3,
                  child: ElevatedButton.icon(
                    icon: const Icon(Icons.tune, size: 16),
                    label: const Text('Calibrar', style: TextStyle(fontSize: 11)),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: themeColor,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 2),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                    ),
                    onPressed: canCalibrateOrSave ? () => _sendOnOffCommand('cal') : null,
                  ),
                ),
                const SizedBox(width: 4),
                Expanded(
                  flex: 3,
                  child: ElevatedButton.icon(
                    icon: const Icon(Icons.save, size: 16),
                    label: const Text('Guardar', style: TextStyle(fontSize: 11)),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: themeColor,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 2),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                    ),
                    onPressed: canCalibrateOrSave ? () => _sendOnOffCommand('save') : null,
                  ),
                ),
                const SizedBox(width: 4),
                // --- SWITCH PISTA N / B ---
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                  decoration: BoxDecoration(
                    color: Colors.white10,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: isWhiteTrack ? Colors.white : Colors.grey[800]!, width: 1),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        "N",
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.bold,
                          color: !isWhiteTrack ? Colors.white : Colors.white38,
                        ),
                      ),
                      Transform.scale(
                        scale: 0.75,
                        child: Switch(
                          value: isWhiteTrack,
                          activeThumbColor: Colors.white,
                          activeTrackColor: Colors.grey[400],
                          inactiveThumbColor: Colors.grey[300],
                          inactiveTrackColor: Colors.black54,
                          onChanged: (bool val) {
                            _sendOnOffCommand('line:${val ? "1" : "0"}');
                          },
                        ),
                      ),
                      Text(
                        "B",
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.bold,
                          color: isWhiteTrack ? Colors.white : Colors.white38,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  // --- BARRAS DE SENSORES ---
  Widget _buildSensorArrayView(BluetoothService service) {
    final sensors = service.sensors;
    final Color themeColor = service.isLowBattery ? Colors.redAccent : Colors.blueAccent;

    return Card(
      elevation: 3,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Padding(
        padding: const EdgeInsets.all(12.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Flexible(
                  child: Text(
                    'Sensores IR (12 Canales)',
                    style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold, color: themeColor),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  service.isConnected ? "20Hz" : "Modo Prueba",
                  style: const TextStyle(fontSize: 11, color: Colors.white54),
                ),
              ],
            ),
            const Divider(height: 12),
            const SizedBox(height: 8),
            SizedBox(
              height: 125,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: List.generate(12, (index) {
                  int val = (index < sensors.length) ? sensors[index] : 0;
                  double pct = (val / 1023.0).clamp(0.0, 1.0);

                  return Column(
                    children: [
                      Text(
                        "$val",
                        style: const TextStyle(fontSize: 9, fontWeight: FontWeight.bold, color: Colors.white70),
                      ),
                      const SizedBox(height: 4),
                      Expanded(
                        child: Container(
                          width: 16,
                          decoration: BoxDecoration(
                            color: Colors.white10,
                            borderRadius: BorderRadius.circular(6),
                            border: Border.all(color: Colors.white24, width: 1),
                          ),
                          alignment: Alignment.bottomCenter,
                          child: AnimatedFractionallySizedBox(
                            duration: const Duration(milliseconds: 100),
                            heightFactor: pct,
                            widthFactor: 1.0,
                            child: Container(
                              decoration: BoxDecoration(
                                color: themeColor,
                                borderRadius: BorderRadius.circular(5),
                              ),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        "S${index + 1}",
                        style: const TextStyle(fontSize: 9, color: Colors.white54),
                      ),
                    ],
                  );
                }),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCriticalDataDisplay(BluetoothService service) {
    final Color themeColor = service.isLowBattery ? Colors.redAccent : Colors.blueAccent;

    return Card(
      elevation: 3,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: service.isLowBattery ? const BorderSide(color: Colors.redAccent, width: 2) : BorderSide.none,
      ),
      child: Padding(
        padding: const EdgeInsets.all(12.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text('Telemetría Crítica', style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold, color: themeColor)),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: themeColor.withValues(alpha: 0.2),
                    border: Border.all(color: themeColor),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    service.estadoLabel,
                    style: TextStyle(color: themeColor, fontWeight: FontWeight.bold, fontSize: 11),
                  ),
                ),
              ],
            ),
            const Divider(height: 12),
            const SizedBox(height: 6),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceAround,
              children: [
                _criticalDataItem("Pitch", "${service.pitchActual}°", Icons.screen_rotation, themeColor),
                _criticalDataItem("Posición", service.pos, Icons.center_focus_strong, themeColor),
                _criticalDataItem(
                  "Batería",
                  "${service.bat} V",
                  service.isLowBattery ? Icons.battery_alert : Icons.battery_charging_full,
                  service.isLowBattery ? Colors.redAccent : themeColor,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _criticalDataItem(String label, String value, IconData icon, Color color) {
    return Column(
      children: [
        Icon(icon, color: color, size: 24),
        const SizedBox(height: 2),
        Text(label, style: const TextStyle(color: Colors.white70, fontSize: 11)),
        const SizedBox(height: 2),
        Text(value, style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold, color: color == Colors.redAccent ? Colors.redAccent : Colors.white)),
      ],
    );
  }

  Widget _buildProfileManagement() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(8.0),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: [
            ElevatedButton.icon(
              icon: const Icon(Icons.save, size: 16),
              label: const Text("Guardar Perfil", style: TextStyle(fontSize: 12)),
              style: ElevatedButton.styleFrom(backgroundColor: Colors.blueAccent, foregroundColor: Colors.white),
              onPressed: _saveProfile,
            ),
            ElevatedButton.icon(
              icon: const Icon(Icons.folder_open, size: 16),
              label: const Text("Cargar Perfil", style: TextStyle(fontSize: 12)),
              style: ElevatedButton.styleFrom(backgroundColor: Colors.blueAccent, foregroundColor: Colors.white),
              onPressed: _loadProfile,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDataDisplay(BluetoothService service) {
    final Color themeColor = service.isLowBattery ? Colors.redAccent : Colors.blueAccent;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Datos Recibidos', style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold, color: themeColor)),
            const Divider(height: 12),
            const SizedBox(height: 6),
            Row(
              children: [
                _dataDisplayItem("KP", service.kp),
                _dataDisplayItem("KI", service.ki),
                _dataDisplayItem("KD", service.kd),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                _dataDisplayItem("Pos", service.pos),
                _dataDisplayItem("Vb", service.vb),
                Expanded(child: Container()),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                _dataDisplayItem("VM", service.ve),
                _dataDisplayItem("MC", service.mc),
                _dataDisplayItem("AB", service.ab),
                _dataDisplayItem("FB", service.fb),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                _dataDisplayItem("KF", service.kf),
                _dataDisplayItem("Pitch", service.pitchActual),
                _dataDisplayItem("Roll", service.rollActual),
                _dataDisplayItem("Pista", service.lineaBlanca == "1" ? "Blanca (B)" : "Negra (N)"),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                _dataDisplayItem("P_sup", service.pSup),
                _dataDisplayItem("P_inf", service.pInf),
                Expanded(child: Container()),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _dataDisplayItem(String label, String value) {
    return Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: const TextStyle(color: Colors.white70, fontSize: 11),
          ),
          const SizedBox(height: 2),
          Text(
            value,
            style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
          ),
        ],
      ),
    );
  }

  Future<void> _sendAllDifferentParameters(BluetoothService service) async {
    final diffKeys = _controlValues.keys.where((k) => _isDifferentFromRobot(k, service)).toList();
    if (diffKeys.isEmpty) return;

    int sentCount = 0;
    for (String rawKey in diffKeys) {
      String key = rawKey.toLowerCase();
      if (key == 've') key = 'vm';

      double value = _controlValues[rawKey]!;
      String formattedValue;
      if (['ki', 'vb', 'fb', 'kf', 'psup', 'pinf'].contains(key)) {
        formattedValue = value.toStringAsFixed(2);
      } else if (['kp', 'kd', 'ab'].contains(key)) {
        formattedValue = value.toStringAsFixed(1);
      } else {
        formattedValue = value.toInt().toString();
      }
      service.sendCommand("$key:$formattedValue");
      sentCount++;
      await Future.delayed(const Duration(milliseconds: 100));
    }
    _showFeedback('Enviados $sentCount parámetros al robot.');
  }

  // --- CONTROLES DE PARÁMETROS ---
  Widget _buildParameterControls(BluetoothService service) {
    final settings = Provider.of<SettingsService>(context);
    final Color themeColor = service.isLowBattery ? Colors.redAccent : Colors.blueAccent;

    final int diffCount = _controlValues.keys.where((k) => _isDifferentFromRobot(k, service)).length;

    return Card(
      elevation: 3,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Padding(
        padding: const EdgeInsets.all(12.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text('Ajuste de Parámetros', style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold, color: themeColor)),
                ElevatedButton.icon(
                  icon: Icon(diffCount > 0 ? Icons.published_with_changes : Icons.check_circle_outline, size: 15),
                  label: Text(
                    diffCount > 0 ? "Enviar ($diffCount)" : "Sincronizado",
                    style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold),
                  ),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: diffCount > 0 ? Colors.redAccent : Colors.white10,
                    foregroundColor: diffCount > 0 ? Colors.white : Colors.white38,
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                    elevation: diffCount > 0 ? 2 : 0,
                  ),
                  onPressed: diffCount > 0 ? () => _sendAllDifferentParameters(service) : null,
                ),
              ],
            ),
            const Divider(height: 12),
            ..._controlValues.entries.map((entry) {
              final key = entry.key;
              final isFloat2 = ['ki', 'vb', 'fb', 'kf', 'psup', 'pinf'].contains(key);
              final isFloat1 = ['kp', 'kd', 'ab'].contains(key);
              final step = settings.steps[key] ?? 1.0;
              final min = _parameterRanges[key]!['min']!;
              final max = _parameterRanges[key]!['max']!;

              final double currentVal = _controlValues[key] ?? 0.0;
              final double? prevVal = _previousControlValues[key];
              final bool hasPreviousDiff = prevVal != null && (prevVal - currentVal).abs() > 0.001;

              final String prevValStr = prevVal != null
                  ? (isFloat2
                      ? prevVal.toStringAsFixed(2)
                      : (isFloat1 ? prevVal.toStringAsFixed(1) : prevVal.toInt().toString()))
                  : "";

              return Padding(
                padding: const EdgeInsets.symmetric(vertical: 4.0),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Wrap(
                            crossAxisAlignment: WrapCrossAlignment.center,
                            spacing: 4,
                            runSpacing: 2,
                            children: [
                              Text(
                                key.toUpperCase(),
                                style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.white, fontSize: 13),
                              ),
                              if (hasPreviousDiff)
                                Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                                  decoration: BoxDecoration(
                                    color: Colors.redAccent.withValues(alpha: 0.2),
                                    borderRadius: BorderRadius.circular(4),
                                    border: Border.all(color: Colors.redAccent, width: 0.8),
                                  ),
                                  child: Text(
                                    "Ant: $prevValStr",
                                    style: const TextStyle(fontSize: 9, color: Colors.redAccent, fontWeight: FontWeight.bold),
                                  ),
                                ),
                            ],
                          ),
                        ],
                      ),
                    ),
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        SizedBox(
                          width: 30,
                          height: 30,
                          child: IconButton(
                            padding: EdgeInsets.zero,
                            icon: const Icon(Icons.remove, size: 18),
                            onPressed: () {
                              setState(() {
                                _controlValues[key] = (_controlValues[key]! - step).clamp(min, max);
                              });
                            },
                          ),
                        ),
                        GestureDetector(
                          onTap: () => _editValueWithKeyboard(key),
                          child: SizedBox(
                            width: 48,
                            child: Text(
                              isFloat2
                                  ? _controlValues[key]!.toStringAsFixed(2)
                                  : (isFloat1
                                      ? _controlValues[key]!.toStringAsFixed(1)
                                      : _controlValues[key]!.toInt().toString()),
                              style: const TextStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.bold,
                                color: Colors.white,
                              ),
                              textAlign: TextAlign.center,
                            ),
                          ),
                        ),
                        SizedBox(
                          width: 30,
                          height: 30,
                          child: IconButton(
                            padding: EdgeInsets.zero,
                            icon: const Icon(Icons.add, size: 18),
                            onPressed: () {
                              setState(() {
                                _controlValues[key] = (_controlValues[key]! + step).clamp(min, max);
                              });
                            },
                          ),
                        ),
                        SizedBox(
                          width: 30,
                          height: 30,
                          child: IconButton(
                            padding: EdgeInsets.zero,
                            icon: Icon(Icons.send, color: themeColor, size: 18),
                            tooltip: 'Enviar ${key.toUpperCase()}',
                            onPressed: () {
                              _sendControlValue(key, _controlValues[key]!);
                            },
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              );
            }),
          ],
        ),
      ),
    );
  }
}