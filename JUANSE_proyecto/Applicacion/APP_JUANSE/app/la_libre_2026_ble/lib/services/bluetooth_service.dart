import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:csv/csv.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart' hide BluetoothService;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

const String LAST_DEVICE_ID_KEY = "last_device_id";
const String nusServiceUuid = "6e400001-b5a3-f393-e0a9-e50e24dcca9e";
const String txCharacteristicUuid = "6e400003-b5a3-f393-e0a9-e50e24dcca9e";
const String rxCharacteristicUuid = "6e400002-b5a3-f393-e0a9-e50e24dcca9e";

final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();

enum BLEStatus { disconnected, scanning, connecting, connected }

/// Un tramo del mapa de la pista: tipo 0 = recta, 1 = curva, y su duración en ms.
class MapSeg {
  int tipo;
  int ms;
  MapSeg(this.tipo, this.ms);
}

class BluetoothService with ChangeNotifier {
  BluetoothDevice? _connectedDevice;
  BluetoothCharacteristic? _txCharacteristic;
  BluetoothCharacteristic? _rxCharacteristic;

  BLEStatus _status = BLEStatus.disconnected;
  BLEStatus get status => _status;

  bool get isConnected => _status == BLEStatus.connected;
  bool get isConnecting => _status == BLEStatus.connecting;
  bool get isScanning => _status == BLEStatus.scanning;

  String? _lastDeviceId;
  String get lastDeviceAddress => _lastDeviceId ?? "";
  int rssi = -100;
  bool initialDataReceived = false;

  BluetoothDevice? get connectedDevice => _connectedDevice;
  String get deviceName {
    if (_connectedDevice == null) return "Desconocido";
    if (_connectedDevice!.platformName.isNotEmpty) return _connectedDevice!.platformName;
    return _connectedDevice!.remoteId.toString();
  }

  // --- Gráficos y Consola ---
  final List<FlSpot> pitchData = [];
  final List<FlSpot> rollData = [];
  final List<FlSpot> posData = [];
  final List<FlSpot> eaData = [];
  final List<FlSpot> lData = [];
  final List<FlSpot> rData = [];
  final List<String> consoleLog = [];
  int _dataCounter = 0;
  static const int maxDataPoints = 100;

  // --- Grabación ---
  bool _isRecording = false;
  bool get isRecording => _isRecording;
  bool _isPaused = false;
  bool get isPaused => _isPaused;
  final List<Map<String, dynamic>> _recordedData = [];

  // --- Contrato Telemetría Carga Fija ---
  int _est = 0; // 0 = Espera, 1 = Corriendo, 2 = Calibrando
  int _posInt = 0; // 0 a 7000
  String _bat = "--"; // Sin medidor de batería en el robot
  List<int> _sensors = List.filled(12, 0); // 12 sensores IR (0 a 1023)

  int get estadoVal => _est;
  int get posVal => _posInt;
  String get bat => _bat;
  double get batVal => double.tryParse(_bat) ?? 0.0;
  bool get isLowBattery => false; // el robot no mide batería
  List<int> get sensors => List.unmodifiable(_sensors);

  // --- Mapa de pista y perfil de curva (firmware con mapeo) ---
  int _md = 0; // modo de corrida: 0 normal, 1 mapeando, 2 carrera con mapa
  int _tr = 0; // tramo detectado por los sensores: 0 recta, 1 curva
  int _ea = 0; // error absoluto suavizado (para elegir el umbral de curva)
  int _sg = -1; // tramo actual del mapa en carrera (-1 = ninguno)
  int get modoCorrida => _md;
  int get tramoDetectado => _tr;
  int get errorAbsSuave => _ea;
  int get segmentoActual => _sg;

  // Perfiles de PID del modo con mapa y parámetros del mapa
  // (los manda el robot en "refresh" y tras cada cambio)
  double rkp = 3.0, rki = 0.0, rkd = 35.0; // PID de recta
  int rvm = 255;
  double ckp = 3.0, cki = 0.0, ckd = 35.0; // PID de curva
  int cvm = 150;
  int adel = 150;
  double esc = 1.0; // factor de velocidad de las rectas (x2 = la recta dura la mitad)
  double ecu = 1.0; // factor de velocidad de las curvas
  double racel = 1.0; // rampa de aceleración (PWM por ms)
  double rfren = 2.0; // rampa de frenado (PWM por ms)
  int tmin = 300; // al grabar, los tramos más cortos que esto (ms) se fusionan
  bool sens = true; // frenar si los sensores ven curva aunque el mapa diga recta
  bool repetir = true; // al terminar el último tramo vuelve al primero (varias vueltas)
  int umb = 80;
  int tcf = 60;
  bool usarMapa = false;
  int pasadas = 0;
  final List<MapSeg> segmentos = [];

  // Avisos del robot (guardado, pasada incorporada/descartada)
  String ultimoAviso = "";
  int avisoId = 0;

  bool _hasFreshConfigPayload = false;
  bool get hasFreshConfigPayload => _hasFreshConfigPayload;

  void consumeFreshConfigPayload() {
    _hasFreshConfigPayload = false;
  }

  String get estadoLabel {
    switch (_est) {
      case 0:
        return "ESPERA";
      case 1:
        return "CORRIENDO";
      case 2:
        return "CALIBRANDO";
      default:
        return "DESCONOCIDO ($_est)";
    }
  }

  // --- Contrato Telemetría Carga Condicional ---
  String _kp = "0.0", _ki = "0.0", _kd = "0.0", _pos = "0.0";
  String _l = "0", _r = "0", _ve = "0", _mc = "0", _ab = "0.8";
  String _pitchActual = "0.00", _rollActual = "0.00";
  String _vb = "0.70", _fb = "0.70", _kf = "0.60";
  String _pSup = "0.00", _pInf = "0.00";
  String _lineaBlanca = "0";

  String get kp => _kp;
  String get ki => _ki;
  String get kd => _kd;
  String get pos => _pos;
  String get l => _l;
  String get r => _r;
  String get ve => _ve;
  String get mc => _mc;
  String get ab => _ab;
  String get fb => _fb;
  String get kf => _kf;
  String get pitchActual => _pitchActual;
  String get rollActual => _rollActual;
  String get vb => _vb;
  String get pSup => _pSup;
  String get pInf => _pInf;
  String get lineaBlanca => _lineaBlanca;

  // --- Subscripciones BLE ---
  StreamSubscription? _statusSubscription;
  StreamSubscription? _lastValueSubscription;
  StreamSubscription? _adapterStateSubscription;
  StreamSubscription? _scanSubscription;
  Timer? _rssiTimer;

  String _rxBuffer = "";

  BluetoothService() {
    _loadLastDevice();
    _initBluetoothAdapter();
  }

  Future<void> _loadLastDevice() async {
    final prefs = await SharedPreferences.getInstance();
    _lastDeviceId = prefs.getString(LAST_DEVICE_ID_KEY);
    notifyListeners();
  }

  Future<void> _saveDevice(String deviceId) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(LAST_DEVICE_ID_KEY, deviceId);
    _lastDeviceId = deviceId;
  }

  void _initBluetoothAdapter() {
    _adapterStateSubscription = FlutterBluePlus.adapterState.listen((state) {
      if (state == BluetoothAdapterState.on) {
        if (_status == BLEStatus.disconnected) {
          reconnectToLastDevice();
        }
      } else {
        _status = BLEStatus.disconnected;
        _resetTelemetryData();
        notifyListeners();
      }
    });
  }

  Future<void> startScan() async {
    if (_status == BLEStatus.scanning || _status == BLEStatus.connecting) return;

    final adapterState = await FlutterBluePlus.adapterState.first;
    if (adapterState != BluetoothAdapterState.on) {
      _addLog("Bluetooth desactivado en el sistema.");
      return;
    }

    _status = BLEStatus.scanning;
    _addLog("Escaneando dispositivos BLE...");
    notifyListeners();

    try {
      await FlutterBluePlus.startScan(timeout: const Duration(seconds: 5));
      Future.delayed(const Duration(seconds: 5), () {
        if (_status == BLEStatus.scanning) {
          _status = BLEStatus.disconnected;
          notifyListeners();
        }
      });
    } catch (e) {
      _addLog("Error al iniciar escaneo BLE: $e");
      _status = BLEStatus.disconnected;
      notifyListeners();
    }
  }

  Future<void> connectToDevice(BluetoothDevice device) async {
    _statusSubscription?.cancel();
    _lastValueSubscription?.cancel();
    _rssiTimer?.cancel();

    _status = BLEStatus.connecting;
    initialDataReceived = false;
    _clearGraphData();
    String nameToDisplay = device.platformName.isNotEmpty ? device.platformName : device.remoteId.toString();
    _addLog("Conectando a BLE $nameToDisplay...");
    notifyListeners();

    try {
      await device.connect(autoConnect: false, timeout: const Duration(seconds: 10));
      _connectedDevice = device;
      await _saveDevice(device.remoteId.toString());

      try {
        await device.requestMtu(512);
      } catch (e) {
        _addLog("MTU request warning: $e");
      }

      _startRssiMonitoring(device);

      _statusSubscription = device.connectionState.listen((state) {
        if (state == BluetoothConnectionState.connected) {
          _status = BLEStatus.connected;
          _addLog("Conectado a $deviceName");
        } else if (state == BluetoothConnectionState.disconnected) {
          _status = BLEStatus.disconnected;
          _txCharacteristic = null;
          _rxCharacteristic = null;
          _rssiTimer?.cancel();
          _resetTelemetryData();
          _addLog("Desconectado de $deviceName");
        }
        notifyListeners();
      });

      List<dynamic> discoveredServices = await device.discoverServices();
      
      BluetoothCharacteristic? foundTx;
      BluetoothCharacteristic? foundRx;

      for (var service in discoveredServices) {
        String serviceUuid = service.uuid.toString().toLowerCase();
        for (var char in service.characteristics) {
          String charUuid = char.uuid.toString().toLowerCase();
          if (serviceUuid == nusServiceUuid) {
            if (charUuid == txCharacteristicUuid) {
              foundTx = char;
            } else if (charUuid == rxCharacteristicUuid) {
              foundRx = char;
            }
          } else {
            if (foundTx == null && (char.properties.notify || char.properties.indicate)) {
              foundTx = char;
            }
            if (foundRx == null && (char.properties.write || char.properties.writeWithoutResponse)) {
              foundRx = char;
            }
          }
        }
      }

      _txCharacteristic = foundTx;
      _rxCharacteristic = foundRx;

      if (_txCharacteristic != null) {
        await _txCharacteristic!.setNotifyValue(true);
        _lastValueSubscription = _txCharacteristic!.onValueReceived.listen((value) {
          _onDataReceived(value);
        });
      }

      _status = BLEStatus.connected;
      _addLog("Canales BLE configurados. Enviando Handshake 'refresh'...");
      
      // Handshake: Escribir "refresh" en RX inmediatamente al conectar
      Future.delayed(const Duration(milliseconds: 300), () {
        sendCommand("refresh");
      });
      // El mapa se pide aparte (llega en bloques chicos)
      Future.delayed(const Duration(milliseconds: 900), () {
        sendCommand("mapget");
      });

    } catch (e) {
      _status = BLEStatus.disconnected;
      _resetTelemetryData();
      _addLog("Error de conexión BLE: $e");
    } finally {
      notifyListeners();
    }
  }

  Future<bool> reconnectToLastDevice() async {
    if (_lastDeviceId == null || _lastDeviceId!.isEmpty) return false;
    if (_status != BLEStatus.disconnected) return false;

    _addLog("Intentando reconectar al dispositivo guardado: $_lastDeviceId");
    _scanSubscription?.cancel();
    
    Completer<bool> completer = Completer<bool>();

    _scanSubscription = FlutterBluePlus.onScanResults.listen((results) {
      for (ScanResult r in results) {
        if (r.device.remoteId.toString() == _lastDeviceId) {
          FlutterBluePlus.stopScan();
          _scanSubscription?.cancel();
          connectToDevice(r.device);
          if (!completer.isCompleted) completer.complete(true);
          break;
        }
      }
    });

    try {
      await FlutterBluePlus.startScan(timeout: const Duration(seconds: 4));
      Future.delayed(const Duration(seconds: 4), () {
        if (!completer.isCompleted) completer.complete(false);
      });
    } catch (e) {
      if (!completer.isCompleted) completer.complete(false);
    }

    return completer.future;
  }

  void disconnect() {
    _connectedDevice?.disconnect();
    _status = BLEStatus.disconnected;
    _txCharacteristic = null;
    _rxCharacteristic = null;
    initialDataReceived = false;
    _rssiTimer?.cancel();
    _resetTelemetryData();
    _addLog("Desconectado.");
    notifyListeners();
  }

  void _resetTelemetryData() {
    _sensors = List.filled(12, 0);
    _est = 0;
    _posInt = 0;
    _bat = "--";
    _md = 0;
    _tr = 0;
    _ea = 0;
    _sg = -1;
  }

  void _startRssiMonitoring(BluetoothDevice device) {
    _rssiTimer?.cancel();
    _rssiTimer = Timer.periodic(const Duration(seconds: 2), (timer) async {
      if (isConnected) {
        try {
          rssi = await device.readRssi();
          notifyListeners();
        } catch (e) {
          // Omitir error temporal de RSSI
        }
      } else {
        timer.cancel();
      }
    });
  }

  void _onDataReceived(List<int> value) {
    if (value.isEmpty) return;
    String decoded = utf8.decode(value, allowMalformed: true);
    if (decoded.isEmpty) return;

    _rxBuffer += decoded;

    // Extraer paquetes JSON completos entre '{' y '}'
    while (_rxBuffer.contains('{') && _rxBuffer.contains('}')) {
      int start = _rxBuffer.indexOf('{');
      int end = _rxBuffer.indexOf('}', start);
      if (end != -1 && end > start) {
        String jsonCandidate = _rxBuffer.substring(start, end + 1).trim();
        _rxBuffer = _rxBuffer.substring(end + 1);
        _processJsonPayload(jsonCandidate);
      } else {
        break;
      }
    }
  }

  int _rxCount = 0;

  void _processJsonPayload(String jsonStr) {
    // La telemetría normal llega a 20 Hz: se registra 1 de cada 20 para no saturar la consola.
    // Los demás paquetes (config, mapa, avisos) se registran siempre.
    _rxCount++;
    final bool esTelemetriaNormal = jsonStr.contains('"Tr":');
    if (!esTelemetriaNormal || _rxCount % 20 == 0) {
      _addLog("RX: $jsonStr");
    }
    try {
      final jsonData = jsonDecode(jsonStr) as Map<String, dynamic>;

      // --- Paquetes especiales (no son telemetría: no tocan los gráficos) ---
      if (jsonData.containsKey('MapI')) {
        _handleMapChunk(jsonData);
        notifyListeners();
        return;
      }
      if (jsonData.containsKey('RKP') || jsonData.containsKey('ADEL')) {
        _handleExtraConfig(jsonData);
        notifyListeners();
        return;
      }
      if (jsonData.containsKey('Ack')) {
        _handleAck(jsonData);
        notifyListeners();
        return;
      }

      // --- 1. CARGA FIJA (OBLIGATORIA EN CADA PAQUETE a 20Hz) ---
      if (jsonData.containsKey('Pitch') && jsonData['Pitch'] != null) {
        _pitchActual = (jsonData['Pitch'] as num).toDouble().toStringAsFixed(1);
      } else if (jsonData.containsKey('Pitch_Actual') && jsonData['Pitch_Actual'] != null) {
        _pitchActual = (jsonData['Pitch_Actual'] as num).toDouble().toStringAsFixed(1);
      }

      if (jsonData.containsKey('Est') && jsonData['Est'] != null) {
        _est = (jsonData['Est'] as num).toInt();
      } else if (jsonData.containsKey('estado') && jsonData['estado'] != null) {
        _est = (jsonData['estado'] as num).toInt();
      }

      if (jsonData['Md'] is num) _md = (jsonData['Md'] as num).toInt();
      if (jsonData['Tr'] is num) _tr = (jsonData['Tr'] as num).toInt();
      if (jsonData['Ea'] is num) _ea = (jsonData['Ea'] as num).toInt();
      if (jsonData['Sg'] is num) _sg = (jsonData['Sg'] as num).toInt();

      if (jsonData.containsKey('Pos') && jsonData['Pos'] != null) {
        _posInt = (jsonData['Pos'] as num).toInt();
        _pos = _posInt.toString();
      } else if (jsonData.containsKey('pos') && jsonData['pos'] != null) {
        _posInt = (jsonData['pos'] as num).toInt();
        _pos = _posInt.toString();
      }

      if (jsonData.containsKey('Bat') && jsonData['Bat'] != null) {
        _bat = (jsonData['Bat'] as num).toDouble().toStringAsFixed(2);
      } else if (jsonData.containsKey('Vb') && jsonData['Vb'] != null) {
        _bat = (jsonData['Vb'] as num).toDouble().toStringAsFixed(2);
      }

      if (jsonData.containsKey('S') && jsonData['S'] is List) {
        final rawList = jsonData['S'] as List;
        List<int> parsedSensors = rawList.map((e) => (e as num).toInt().clamp(0, 1023)).toList();
        while (parsedSensors.length < 12) {
          parsedSensors.add(0);
        }
        if (parsedSensors.length > 12) {
          parsedSensors = parsedSensors.sublist(0, 12);
        }
        _sensors = parsedSensors;
      }

      // --- 2. CARGA CONDICIONAL (CLAVES OPCIONALES DE CONFIGURACIÓN) ---
      bool configKeyFound = false;

      if (jsonData.containsKey('KP') && jsonData['KP'] != null) {
        _kp = (jsonData['KP'] as num).toDouble().toStringAsFixed(1);
        configKeyFound = true;
      }

      if (jsonData.containsKey('KI') && jsonData['KI'] != null) {
        _ki = (jsonData['KI'] as num).toDouble().toStringAsFixed(2);
        configKeyFound = true;
      }

      if (jsonData.containsKey('KD') && jsonData['KD'] != null) {
        _kd = (jsonData['KD'] as num).toDouble().toStringAsFixed(1);
        configKeyFound = true;
      }

      if (jsonData.containsKey('AB') && jsonData['AB'] != null) {
        _ab = (jsonData['AB'] as num).toDouble().toStringAsFixed(1);
        configKeyFound = true;
      } else if (jsonData.containsKey('ab') && jsonData['ab'] != null) {
        _ab = (jsonData['ab'] as num).toDouble().toStringAsFixed(1);
        configKeyFound = true;
      }

      if (jsonData.containsKey('VB') && jsonData['VB'] != null) {
        _vb = (jsonData['VB'] as num).toDouble().toStringAsFixed(2);
        configKeyFound = true;
      }

      if (jsonData.containsKey('VM') && jsonData['VM'] != null) {
        _ve = (jsonData['VM'] as num).toInt().toString();
        configKeyFound = true;
      } else if (jsonData.containsKey('Ve') && jsonData['Ve'] != null) {
        _ve = (jsonData['Ve'] as num).toInt().toString();
        configKeyFound = true;
      }

      if (jsonData.containsKey('MC') && jsonData['MC'] != null) {
        _mc = (jsonData['MC'] as num).toInt().toString();
        configKeyFound = true;
      }

      if (jsonData.containsKey('FB') && jsonData['FB'] != null) {
        _fb = (jsonData['FB'] as num).toDouble().toStringAsFixed(2);
        configKeyFound = true;
      }

      if (jsonData.containsKey('KF') && jsonData['KF'] != null) {
        _kf = (jsonData['KF'] as num).toDouble().toStringAsFixed(2);
        configKeyFound = true;
      }

      if (jsonData.containsKey('LB') && jsonData['LB'] != null) {
        _lineaBlanca = jsonData['LB'].toString();
        configKeyFound = true;
      } else if (jsonData.containsKey('Linea_Blanca') && jsonData['Linea_Blanca'] != null) {
        _lineaBlanca = jsonData['Linea_Blanca'].toString();
        configKeyFound = true;
      }

      if (configKeyFound) {
        _hasFreshConfigPayload = true;
      }

      _l = (jsonData['L'] ?? _l).toString();
      _r = (jsonData['R'] ?? _r).toString();
      _rollActual = (jsonData['Yaw_Actual'] ?? _rollActual).toString();
      _pSup = (jsonData['P_sup'] ?? _pSup).toString();
      _pInf = (jsonData['P_inf'] ?? _pInf).toString();

      if (_isRecording) {
        _recordedData.add(jsonData);
      }

      _updateGraphData();
      if (!initialDataReceived) {
        initialDataReceived = true;
      }
      notifyListeners();
    } catch (e) {
      _addLog("ERROR: JSON inválido - $e");
    }
  }

  // ---------------------------------------------------------------------------
  // MAPA DE PISTA
  // ---------------------------------------------------------------------------
  void _handleExtraConfig(Map<String, dynamic> j) {
    double d(String k, double cur) => (j[k] is num) ? (j[k] as num).toDouble() : cur;
    int i(String k, int cur) => (j[k] is num) ? (j[k] as num).toInt() : cur;

    rkp = d('RKP', rkp);
    rki = d('RKI', rki);
    rkd = d('RKD', rkd);
    rvm = i('RVM', rvm);
    ckp = d('CKP', ckp);
    cki = d('CKI', cki);
    ckd = d('CKD', ckd);
    cvm = i('CVM', cvm);
    adel = i('ADEL', adel);
    esc = d('ESC', esc);
    ecu = d('ECU', ecu);
    racel = d('RAC', racel);
    rfren = d('RFR', rfren);
    tmin = i('TMIN', tmin);
    sens = i('SENS', sens ? 1 : 0) != 0;
    repetir = i('REP', repetir ? 1 : 0) != 0;
    umb = i('UMB', umb);
    tcf = i('TCF', tcf);
    usarMapa = i('MAPA', usarMapa ? 1 : 0) != 0;
    pasadas = i('PAS', pasadas);

    final n = i('NSEG', segmentos.length);
    if (n < segmentos.length) {
      segmentos.removeRange(n, segmentos.length);
    }
    while (segmentos.length < n) {
      segmentos.add(MapSeg(0, 0));
    }
  }

  void _handleMapChunk(Map<String, dynamic> j) {
    final start = (j['MapI'] is num) ? (j['MapI'] as num).toInt() : 0;
    final n = (j['MapN'] is num) ? (j['MapN'] as num).toInt() : 0;
    if (n < segmentos.length) {
      segmentos.removeRange(n, segmentos.length);
    }
    while (segmentos.length < n) {
      segmentos.add(MapSeg(0, 0));
    }
    final lista = j['Map'];
    if (lista is List) {
      for (int k = 0; k < lista.length; k++) {
        final item = lista[k];
        final idx = start + k;
        if (item is List && item.length >= 2 && idx < segmentos.length) {
          segmentos[idx] = MapSeg((item[0] as num).toInt(), (item[1] as num).toInt());
        }
      }
    }
  }

  void _handleAck(Map<String, dynamic> j) {
    final a = j['Ack'].toString();
    if (a == 'save') {
      _avisar("Guardado en el robot");
    } else if (a == 'pasada') {
      final ok = (j['Ok'] is num) && (j['Ok'] as num).toInt() == 1;
      if (j['PAS'] is num) pasadas = (j['PAS'] as num).toInt();
      final nPasada = (j['N'] is num) ? (j['N'] as num).toInt() : 0;
      final nCrudo = (j['R'] is num) ? (j['R'] as num).toInt() : nPasada;
      final nMapa = (j['NSEG'] is num) ? (j['NSEG'] as num).toInt() : 0;
      final codigo = (j['Cd'] is num) ? (j['Cd'] as num).toInt() : (ok ? 2 : 3);
      final tPasada = (j['TP'] is num) ? (j['TP'] as num).toInt() / 1000.0 : 0.0;
      final tMapa = (j['TM'] is num) ? (j['TM'] as num).toInt() / 1000.0 : 0.0;
      final detalle = nCrudo != nPasada ? "$nCrudo detectados, $nPasada tras limpiar" : "$nPasada tramos";
      if (ok) {
        _avisar("Pasada incorporada al mapa ($detalle, $pasadas pasadas promediadas)");
      } else if (codigo == 4) {
        _avisar("Pasada descartada: duró ${tPasada.toStringAsFixed(1)} s y el mapa dura ${tMapa.toStringAsFixed(1)} s. "
            "¿Diste más de una vuelta? Cada pasada tiene que ser UNA vuelta, parando en el punto de largada.");
      } else {
        _avisar("Pasada descartada: sus tramos no coinciden con el mapa ($nPasada vs $nMapa). "
            "Subí 'Tramo mínimo' o 'Confirmación', o borrá el mapa y grabá de nuevo.");
      }
    }
  }

  void _avisar(String mensaje) {
    ultimoAviso = mensaje;
    avisoId++;
    _addLog("ROBOT: $mensaje");
  }

  /// Elige el modo de largada: false = normal (un solo PID), true = con mapa.
  Future<void> setUsarMapa(bool valor) async {
    usarMapa = valor;
    notifyListeners();
    await sendCommand("mapa:${valor ? 1 : 0}");
  }

  /// Repetir el mapa: al terminar el último tramo vuelve al primero (carreras de varias vueltas).
  Future<void> setRepetir(bool valor) async {
    repetir = valor;
    notifyListeners();
    await sendCommand("rep:${valor ? 1 : 0}");
  }

  /// Activa o desactiva el frenado por sensores (red de seguridad).
  Future<void> setSens(bool valor) async {
    sens = valor;
    notifyListeners();
    await sendCommand("sens:${valor ? 1 : 0}");
  }

  /// Cambia un tramo del mapa (en la app y en el robot).
  Future<void> editarSegmento(int i, int tipo, int ms) async {
    if (i < 0 || i >= 32) return;
    final msOk = ms.clamp(0, 65535).toInt();
    while (segmentos.length <= i) {
      segmentos.add(MapSeg(0, 0));
    }
    segmentos[i] = MapSeg(tipo == 1 ? 1 : 0, msOk);
    notifyListeners();
    await sendCommand("seg:$i,${segmentos[i].tipo},$msOk");
  }

  /// Agrega un tramo al final (alterna recta/curva, 1000 ms para editar después).
  Future<void> agregarSegmento() async {
    final i = segmentos.length;
    if (i >= 32) return;
    await editarSegmento(i, i % 2 == 0 ? 0 : 1, 1000);
  }

  /// Borra el tramo i y corre los siguientes.
  Future<void> eliminarSegmento(int i) async {
    if (i < 0 || i >= segmentos.length) return;
    final copia = List<MapSeg>.from(segmentos);
    copia.removeAt(i);
    for (int j = i; j < copia.length; j++) {
      await sendCommand("seg:$j,${copia[j].tipo},${copia[j].ms}");
      await Future.delayed(const Duration(milliseconds: 60));
    }
    await sendCommand("segn:${copia.length}");
    segmentos
      ..clear()
      ..addAll(copia);
    notifyListeners();
  }

  Future<void> sendCommand(String command) async {
    _addLog("TX: $command");

    // Actualización local de respaldo en UI
    if (command == "line:1") {
      _lineaBlanca = "1";
    } else if (command == "line:0") {
      _lineaBlanca = "0";
    } else if (!isConnected) {
      if (command == "on") _est = 1;
      if (command == "off") _est = 0;
      if (command == "cal") _est = 2;
    }
    notifyListeners();

    if (isConnected && _rxCharacteristic != null) {
      try {
        List<int> bytes = utf8.encode("$command\r\n");
        await _rxCharacteristic!.write(bytes, withoutResponse: _rxCharacteristic!.properties.writeWithoutResponse);
      } catch (e) {
        _addLog("ERROR al enviar BLE: $e");
      }
    } else {
      _addLog("Comando procesado en modo local (sin robot).");
    }
  }

  void _addLog(String message) {
    if (navigatorKey.currentContext != null) {
      consoleLog.insert(0, "${TimeOfDay.now().format(navigatorKey.currentContext!)} - $message");
      if (consoleLog.length > 200) {
        consoleLog.removeLast();
      }
      notifyListeners();
    }
  }

  void _updateGraphData() {
    if (_isPaused) return;
    final newPitch = double.tryParse(_pitchActual) ?? 0.0;
    final newRoll = double.tryParse(_rollActual) ?? 0.0;
    final newPos = double.tryParse(_pos) ?? 0.0;
    final newL = double.tryParse(_l) ?? 0.0;
    final newR = double.tryParse(_r) ?? 0.0;

    _dataCounter++;

    pitchData.add(FlSpot(_dataCounter.toDouble(), newPitch));
    rollData.add(FlSpot(_dataCounter.toDouble(), newRoll));
    posData.add(FlSpot(_dataCounter.toDouble(), newPos));
    eaData.add(FlSpot(_dataCounter.toDouble(), _ea.toDouble()));
    lData.add(FlSpot(_dataCounter.toDouble(), newL));
    rData.add(FlSpot(_dataCounter.toDouble(), newR));

    if (pitchData.length > maxDataPoints) pitchData.removeAt(0);
    if (rollData.length > maxDataPoints) rollData.removeAt(0);
    if (posData.length > maxDataPoints) posData.removeAt(0);
    if (eaData.length > maxDataPoints) eaData.removeAt(0);
    if (lData.length > maxDataPoints) lData.removeAt(0);
    if (rData.length > maxDataPoints) rData.removeAt(0);
  }

  void _clearGraphData() {
    pitchData.clear();
    rollData.clear();
    posData.clear();
    eaData.clear();
    lData.clear();
    rData.clear();
    _dataCounter = 0;
  }

  void togglePause() {
    _isPaused = !_isPaused;
    _addLog(_isPaused ? "Gráficos pausados." : "Gráficos reanudados.");
    notifyListeners();
  }

  void startRecording() {
    _recordedData.clear();
    _isRecording = true;
    _addLog("¡Grabación iniciada!");
    notifyListeners();
  }

  Future<String?> stopAndSaveRecording() async {
    _isRecording = false;
    _addLog("Grabación detenida. Guardando archivo...");
    notifyListeners();

    if (_recordedData.isEmpty) {
      _addLog("No hay datos para guardar.");
      return null;
    }

    try {
      // Claves de todos los paquetes (los de config traen más campos que los de telemetría)
      final List<String> headers = [];
      for (final row in _recordedData) {
        for (final k in row.keys) {
          if (!headers.contains(k)) headers.add(k);
        }
      }
      final List<List<dynamic>> rows = [headers];
      for (final row in _recordedData) {
        rows.add(headers.map((header) => row[header]).toList());
      }

      final String csvData = const ListToCsvConverter().convert(rows);

      final directory = await _carpetaSesiones();
      final timestamp = DateTime.now().toIso8601String().replaceAll(':', '-').split('.').first;
      final file = File('${directory.path}/sesion_control_$timestamp.csv');

      await file.writeAsString(csvData);
      _addLog("Archivo guardado en: ${file.path}");
      _recordedData.clear();
      return file.path;
    } catch (e) {
      _addLog("Error al guardar el archivo: $e");
      return null;
    }
  }

  /// Carpeta propia de la app: no pide permisos y funciona en Android (incluido el 13+) y en iPhone.
  Future<Directory> _carpetaSesiones() async {
    return await getApplicationDocumentsDirectory();
  }

  Future<List<File>> getSavedSessions() async {
    final directory = await _carpetaSesiones();
    final files = directory.listSync();
    return files.whereType<File>().where((file) => file.path.endsWith('.csv')).toList();
  }

  Future<void> deleteSession(File file) async {
    try {
      await file.delete();
      _addLog("Archivo borrado: ${file.path}");
    } catch (e) {
      _addLog("Error al borrar el archivo: $e");
    }
  }

  @override
  void dispose() {
    _statusSubscription?.cancel();
    _lastValueSubscription?.cancel();
    _adapterStateSubscription?.cancel();
    _scanSubscription?.cancel();
    _rssiTimer?.cancel();
    super.dispose();
  }
}
