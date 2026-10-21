import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/bluetooth_service.dart';

/// Definición de un parámetro editable con botones − / +.
class _ParamDef {
  final String cmd; // comando del firmware (kp, rvm, ckd, adel, ...)
  final String label;
  final String unidad;
  final double paso;
  final double min;
  final double max;
  final int decimales;
  const _ParamDef(this.cmd, this.label, this.unidad, this.paso, this.min, this.max, this.decimales);
}

// Tres perfiles de PID: la fórmula es la misma, cambian las ganancias y la velocidad.
const List<_ParamDef> _perfilNormal = [
  _ParamDef('kp', 'Kp', '', 0.5, 0, 20, 1),
  _ParamDef('ki', 'Ki', '', 0.01, 0, 1, 2),
  _ParamDef('kd', 'Kd', '', 1.0, 0, 100, 1),
  _ParamDef('vm', 'Velocidad', '', 5.0, 0, 255, 0),
];

const List<_ParamDef> _perfilRecta = [
  _ParamDef('rkp', 'Kp recta', '', 0.5, 0, 20, 1),
  _ParamDef('rki', 'Ki recta', '', 0.01, 0, 1, 2),
  _ParamDef('rkd', 'Kd recta', '', 1.0, 0, 100, 1),
  _ParamDef('rvm', 'Velocidad recta', '', 5.0, 0, 255, 0),
];

const List<_ParamDef> _perfilCurva = [
  _ParamDef('ckp', 'Kp curva', '', 0.5, 0, 20, 1),
  _ParamDef('cki', 'Ki curva', '', 0.01, 0, 1, 2),
  _ParamDef('ckd', 'Kd curva', '', 1.0, 0, 100, 1),
  _ParamDef('cvm', 'Velocidad curva', '', 5.0, 0, 255, 0),
];

// Frenado y aceleración en las curvas (lo que se usa siempre)
const List<_ParamDef> _paramsMapa = [
  _ParamDef('adel', 'Frenar antes de la curva', 'ms', 10.0, 0, 2000, 0),
  _ParamDef('acel', 'Acelerar al salir de la curva', 'ms', 10.0, -1000, 1000, 0),
];

// Ajustes avanzados (se pueden dejar como están)
const List<_ParamDef> _paramsAvanzados = [
  _ParamDef('umb', 'Umbral de curva', '', 5.0, 5, 2000, 0),
  _ParamDef('tcf', 'Confirmación de tramo', 'ms', 10.0, 10, 500, 0),
  _ParamDef('tmin', 'Tramo mínimo al grabar', 'ms', 50.0, 0, 3000, 0),
  _ParamDef('racel', 'Subida de velocidad', '', 0.1, 0.05, 10, 2),
  _ParamDef('rfren', 'Bajada de velocidad', '', 0.1, 0.05, 10, 2),
];

const List<String> _nombresPerfil = ['Normal', 'Recta', 'Curva'];
const List<String> _descripcionesPerfil = [
  'Se usa en el modo NORMAL: un solo PID para toda la pista. Es el modo seguro.',
  'Se usa en las RECTAS del modo MAPEO.',
  'Se usa en las CURVAS del modo MAPEO y al grabar pasadas. '
      'Grabá las pasadas con la velocidad de curva con la que querés tomar las curvas.',
];

class MapScreen extends StatefulWidget {
  const MapScreen({super.key});

  @override
  State<MapScreen> createState() => _MapScreenState();
}

class _MapScreenState extends State<MapScreen> {
  // Valor que el usuario está editando (se muestra hasta que el robot confirma)
  final Map<String, double> _local = {};
  final Map<String, Timer> _timersEnvio = {};
  final Map<String, Timer> _timersLimpieza = {};
  int _ultimoAvisoId = 0;
  int _perfil = 0; // 0 = Normal, 1 = Recta, 2 = Curva

  @override
  void initState() {
    super.initState();
    _ultimoAvisoId = context.read<BluetoothService>().avisoId;
  }

  @override
  void dispose() {
    for (final t in _timersEnvio.values) {
      t.cancel();
    }
    for (final t in _timersLimpieza.values) {
      t.cancel();
    }
    super.dispose();
  }

  // ---------------------------------------------------------------------------
  // Utilidades
  // ---------------------------------------------------------------------------
  double _valorRobot(BluetoothService s, String cmd) {
    switch (cmd) {
      case 'kp':
        return double.tryParse(s.kp) ?? 0;
      case 'ki':
        return double.tryParse(s.ki) ?? 0;
      case 'kd':
        return double.tryParse(s.kd) ?? 0;
      case 'vm':
        return double.tryParse(s.ve) ?? 0;
      case 'rkp':
        return s.rkp;
      case 'rki':
        return s.rki;
      case 'rkd':
        return s.rkd;
      case 'rvm':
        return s.rvm.toDouble();
      case 'ckp':
        return s.ckp;
      case 'cki':
        return s.cki;
      case 'ckd':
        return s.ckd;
      case 'cvm':
        return s.cvm.toDouble();
      case 'adel':
        return s.adel.toDouble();
      case 'acel':
        return s.acel.toDouble();
      case 'racel':
        return s.racel;
      case 'rfren':
        return s.rfren;
      case 'tmin':
        return s.tmin.toDouble();
      case 'umb':
        return s.umb.toDouble();
      case 'tcf':
        return s.tcf.toDouble();
    }
    return 0;
  }

  String _formato(_ParamDef p, double v) {
    return p.decimales == 0 ? v.round().toString() : v.toStringAsFixed(p.decimales);
  }

  // Cambia un parámetro: se muestra al instante y se envía 0,4 s después del último toque
  void _cambiar(BluetoothService s, _ParamDef p, double nuevo) {
    double v = nuevo;
    if (v < p.min) v = p.min;
    if (v > p.max) v = p.max;
    v = double.parse(v.toStringAsFixed(p.decimales));
    setState(() => _local[p.cmd] = v);

    _timersEnvio[p.cmd]?.cancel();
    _timersLimpieza[p.cmd]?.cancel();
    _timersEnvio[p.cmd] = Timer(const Duration(milliseconds: 400), () {
      s.sendCommand('${p.cmd}:${_formato(p, v)}');
      // Después de que el robot confirme, se vuelve a mostrar el valor del robot
      _timersLimpieza[p.cmd] = Timer(const Duration(milliseconds: 1500), () {
        if (mounted) setState(() => _local.remove(p.cmd));
      });
    });
  }

  Future<String?> _pedirTexto(String titulo, String actual) {
    final controller = TextEditingController(text: actual);
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(titulo),
        content: TextField(
          controller: controller,
          autofocus: true,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancelar')),
          FilledButton(onPressed: () => Navigator.pop(ctx, controller.text), child: const Text('OK')),
        ],
      ),
    );
  }

  Future<bool> _confirmar(String titulo, String mensaje) async {
    final r = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(titulo),
        content: Text(mensaje),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancelar')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Sí')),
        ],
      ),
    );
    return r == true;
  }

  void _mostrarAvisoSiHay(BluetoothService s) {
    if (s.avisoId != _ultimoAvisoId) {
      _ultimoAvisoId = s.avisoId;
      final mensaje = s.ultimoAviso;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(mensaje), duration: const Duration(seconds: 4)),
        );
      });
    }
  }

  // ---------------------------------------------------------------------------
  // Pantalla
  // ---------------------------------------------------------------------------
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Mapa de pista')),
      body: Consumer<BluetoothService>(
        builder: (context, s, child) {
          _mostrarAvisoSiHay(s);
          final conectado = s.isConnected;
          final corriendo = s.estadoVal == 1;
          return ListView(
            padding: const EdgeInsets.all(12),
            children: [
              if (!conectado) _bannerSinConexion(),
              _cardModo(s, conectado, corriendo),
              _cardEstado(s),
              _cardPerfiles(s, conectado),
              _cardGrabar(s, conectado, corriendo),
              _cardTramos(s, conectado, corriendo),
              _cardParametrosMapa(s, conectado),
              _cardAvanzado(s, conectado),
              _cardGuardar(s, conectado),
              _cardAyuda(),
              const SizedBox(height: 24),
            ],
          );
        },
      ),
    );
  }

  Widget _bannerSinConexion() {
    return Card(
      color: Colors.red[900],
      child: const Padding(
        padding: EdgeInsets.all(12),
        child: Row(
          children: [
            Icon(Icons.bluetooth_disabled, color: Colors.white),
            SizedBox(width: 10),
            Expanded(
              child: Text(
                'Sin conexión con el robot. Conectate desde la pestaña Control.',
                style: TextStyle(color: Colors.white),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _titulo(String texto, IconData icono) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: [
          Icon(icono, size: 20, color: Colors.lightBlueAccent),
          const SizedBox(width: 8),
          Expanded(
            child: Text(texto, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
  }

  // --- Modo de largada -------------------------------------------------------
  Widget _cardModo(BluetoothService s, bool conectado, bool corriendo) {
    final sinMapa = s.usarMapa && s.segmentos.isEmpty;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _titulo('Modo de largada', Icons.flag),
            SizedBox(
              width: double.infinity,
              child: SegmentedButton<bool>(
                segments: const [
                  ButtonSegment<bool>(value: false, label: Text('Normal'), icon: Icon(Icons.speed)),
                  ButtonSegment<bool>(value: true, label: Text('Mapeo'), icon: Icon(Icons.map)),
                ],
                selected: {s.usarMapa},
                onSelectionChanged: (conectado && !corriendo) ? (sel) => s.setUsarMapa(sel.first) : null,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              s.usarMapa
                  ? 'MAPEO: usa el PID de recta en las rectas y el de curva en las curvas, '
                      'y frena antes de cada curva según el mapa.'
                  : 'NORMAL: un solo PID, con su velocidad. Ignora el mapa. Es el modo seguro.',
              style: const TextStyle(fontSize: 13, color: Colors.white70),
            ),
            if (sinMapa)
              const Padding(
                padding: EdgeInsets.only(top: 8),
                child: Text(
                  '⚠️ El mapa está vacío: el robot va a largar en modo Normal hasta que grabes la pista.',
                  style: TextStyle(fontSize: 13, color: Colors.orangeAccent),
                ),
              ),
            const SizedBox(height: 4),
            const Text(
              'El modo queda guardado en el robot con "Guardar todo". '
              'El LED de espera parpadea en verde (Normal) o en cian (Mapeo).',
              style: TextStyle(fontSize: 12, color: Colors.white54),
            ),
          ],
        ),
      ),
    );
  }

  // --- Estado en vivo --------------------------------------------------------
  Widget _chip(String texto, Color color) {
    return Chip(
      label: Text(texto, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
      backgroundColor: color,
      visualDensity: VisualDensity.compact,
    );
  }

  Widget _cardEstado(BluetoothService s) {
    final esCurva = s.tramoDetectado == 1;
    String modoTxt;
    switch (s.modoCorrida) {
      case 1:
        modoTxt = 'GRABANDO';
        break;
      case 2:
        modoTxt = 'MAPEO';
        break;
      default:
        modoTxt = 'NORMAL';
    }
    final umbral = s.umb <= 0 ? 1 : s.umb;
    double nivel = s.errorAbsSuave / (umbral * 2);
    if (nivel > 1) nivel = 1;
    if (nivel < 0) nivel = 0;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _titulo('En vivo', Icons.sensors),
            Wrap(
              spacing: 8,
              children: [
                _chip(s.estadoLabel, Colors.blueGrey),
                _chip(modoTxt, Colors.indigo),
                _chip(esCurva ? 'CURVA' : 'RECTA', esCurva ? Colors.deepOrange : Colors.green),
                if (s.segmentoActual >= 0 && s.segmentos.isNotEmpty)
                  _chip('Tramo ${s.segmentoActual + 1} de ${s.segmentos.length}', Colors.teal),
              ],
            ),
            const SizedBox(height: 8),
            Text('Error suavizado: ${s.errorAbsSuave}    Umbral: ${s.umb}',
                style: const TextStyle(fontSize: 13)),
            const SizedBox(height: 4),
            LinearProgressIndicator(
              value: nivel,
              minHeight: 8,
              color: s.errorAbsSuave > s.umb ? Colors.deepOrange : Colors.green,
              backgroundColor: Colors.white12,
            ),
            const SizedBox(height: 4),
            const Text(
              'La marca del medio es el umbral: por encima el robot detecta curva.',
              style: TextStyle(fontSize: 11, color: Colors.white54),
            ),
          ],
        ),
      ),
    );
  }

  // --- Perfiles de PID -------------------------------------------------------
  Widget _cardPerfiles(BluetoothService s, bool conectado) {
    final List<_ParamDef> params = _perfil == 0 ? _perfilNormal : (_perfil == 1 ? _perfilRecta : _perfilCurva);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _titulo('PID y velocidad', Icons.tune),
            SizedBox(
              width: double.infinity,
              child: SegmentedButton<int>(
                showSelectedIcon: false,
                segments: [
                  for (int i = 0; i < _nombresPerfil.length; i++)
                    ButtonSegment<int>(value: i, label: Text(_nombresPerfil[i])),
                ],
                selected: {_perfil},
                onSelectionChanged: (sel) => setState(() => _perfil = sel.first),
              ),
            ),
            const SizedBox(height: 8),
            Text(_descripcionesPerfil[_perfil], style: const TextStyle(fontSize: 12, color: Colors.white70)),
            const SizedBox(height: 6),
            for (final p in params) _filaParametro(s, p, conectado),
          ],
        ),
      ),
    );
  }

  // --- Grabar pasadas --------------------------------------------------------
  Widget _cardGrabar(BluetoothService s, bool conectado, bool corriendo) {
    final puedeIniciar = conectado && s.estadoVal == 0;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _titulo('Grabar la pista', Icons.fiber_manual_record),
            Text(
              'Pasadas promediadas: ${s.pasadas}    Tramos: ${s.segmentos.length}',
              style: const TextStyle(fontSize: 13),
            ),
            const SizedBox(height: 4),
            const Text(
              '1 pasada = 1 vuelta. Poné el robot SIEMPRE en el mismo punto de largada, calibrá, tocá '
              '"Grabar pasada", dejalo dar UNA vuelta y tocá "Terminar pasada" (o frená con el botón) '
              'cuando vuelva a ese punto. No lo dejes dar varias vueltas seguidas: el robot no sabe dónde '
              'empieza la pista y las anotaría como una sola pasada larguísima. '
              'Repetí las veces que quieras: cada pasada se promedia con las anteriores.',
              style: TextStyle(fontSize: 12, color: Colors.white70),
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: FilledButton.icon(
                    onPressed: puedeIniciar ? () => s.sendCommand('mapear') : null,
                    icon: const Icon(Icons.play_arrow),
                    label: const Text('Grabar pasada'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: FilledButton.icon(
                    style: FilledButton.styleFrom(backgroundColor: Colors.red[700]),
                    onPressed: (conectado && corriendo) ? () => s.sendCommand('fin') : null,
                    icon: const Icon(Icons.stop),
                    label: const Text('Terminar pasada'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: conectado ? () => s.sendCommand('mapget') : null,
                    icon: const Icon(Icons.refresh),
                    label: const Text('Pedir mapa'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: (conectado && !corriendo)
                        ? () async {
                            final ok = await _confirmar(
                                'Borrar mapa', 'Se borran todos los tramos del robot. ¿Seguro?');
                            if (ok) s.sendCommand('mapclear');
                          }
                        : null,
                    icon: const Icon(Icons.delete_outline),
                    label: const Text('Borrar mapa'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  // --- Barra visual de la pista ----------------------------------------------
  Widget _barraTramos(BluetoothService s) {
    if (s.segmentos.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: SizedBox(
          height: 32,
          child: Row(
            children: [
              for (int i = 0; i < s.segmentos.length; i++)
                Expanded(
                  flex: s.segmentos[i].ms < 1 ? 1 : s.segmentos[i].ms,
                  child: Container(
                    margin: const EdgeInsets.symmetric(horizontal: 0.5),
                    decoration: BoxDecoration(
                      color: s.segmentos[i].tipo == 1 ? Colors.deepOrange : Colors.green[700],
                      border: (s.segmentoActual == i) ? Border.all(color: Colors.white, width: 2) : null,
                    ),
                    alignment: Alignment.center,
                    child: Text(
                      '${i + 1}',
                      style: const TextStyle(fontSize: 10, fontWeight: FontWeight.bold),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  // --- Tabla de tramos -------------------------------------------------------
  Widget _cardTramos(BluetoothService s, bool conectado, bool corriendo) {
    final editable = conectado && !corriendo;
    int totalMs = 0;
    for (final seg in s.segmentos) {
      totalMs += seg.ms;
    }
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(child: _titulo('Tramos (${s.segmentos.length})', Icons.timeline)),
                Text('Total: ${(totalMs / 1000).toStringAsFixed(2)} s',
                    style: const TextStyle(fontSize: 12, color: Colors.white70)),
              ],
            ),
            _barraTramos(s),
            if (s.segmentos.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 8),
                child: Text('Todavía no hay tramos. Grabá la pista o agregalos a mano.',
                    style: TextStyle(color: Colors.white54)),
              ),
            for (int i = 0; i < s.segmentos.length; i++) _filaTramo(s, i, editable),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                OutlinedButton.icon(
                  onPressed: (editable && s.segmentos.length < 32) ? () => s.agregarSegmento() : null,
                  icon: const Icon(Icons.add),
                  label: const Text('Agregar tramo'),
                ),
                FilledButton.icon(
                  onPressed: (editable && s.carreraLista)
                      ? () async {
                          final ok = await _confirmar('Usar tiempos de la carrera',
                              'Los tiempos de la tabla se reemplazan por los medidos en la última carrera. ¿Seguro?');
                          if (ok) s.adoptarTiempos();
                        }
                      : null,
                  icon: const Icon(Icons.timer),
                  label: const Text('Usar tiempos de la última carrera'),
                ),
              ],
            ),
            if (corriendo)
              const Padding(
                padding: EdgeInsets.only(top: 6),
                child: Text('No se puede editar el mapa con el robot corriendo.',
                    style: TextStyle(fontSize: 12, color: Colors.orangeAccent)),
              ),
            const Padding(
              padding: EdgeInsets.only(top: 6),
              child: Text(
                'Tocá RECTA/CURVA para cambiar el tipo. Tocá el tiempo para escribirlo. '
                'El último tramo dura lo que tardaste en parar el robot: corregilo si hace falta. '
                'Como grabaste despacio, las rectas van a durar menos cuando corras rápido: '
                'corré UNA vuelta en modo Mapeo y parala al volver al punto de largada; el robot mide cuánto '
                'tardó en cada tramo y el botón "Usar tiempos de la última carrera" los copia a la tabla.',
                style: TextStyle(fontSize: 11, color: Colors.white54),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _filaTramo(BluetoothService s, int i, bool editable) {
    final seg = s.segmentos[i];
    final esCurva = seg.tipo == 1;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          SizedBox(
            width: 26,
            child: Text('${i + 1}', style: const TextStyle(color: Colors.white54)),
          ),
          SizedBox(
            width: 82,
            child: ActionChip(
              label: Text(
                esCurva ? 'CURVA' : 'RECTA',
                style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold),
              ),
              backgroundColor: esCurva ? Colors.deepOrange : Colors.green[700],
              visualDensity: VisualDensity.compact,
              onPressed: editable ? () => s.editarSegmento(i, esCurva ? 0 : 1, seg.ms) : null,
            ),
          ),
          IconButton(
            visualDensity: VisualDensity.compact,
            icon: const Icon(Icons.remove_circle_outline),
            onPressed: editable ? () => s.editarSegmento(i, seg.tipo, seg.ms - 50) : null,
          ),
          Expanded(
            child: InkWell(
              onTap: editable
                  ? () async {
                      final txt = await _pedirTexto('Duración del tramo ${i + 1} (ms)', seg.ms.toString());
                      if (txt == null || !mounted) return;
                      final nuevo = int.tryParse(txt.trim());
                      if (nuevo != null) s.editarSegmento(i, seg.tipo, nuevo);
                    }
                  : null,
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Text('${seg.ms} ms', textAlign: TextAlign.center, style: const TextStyle(fontSize: 15)),
              ),
            ),
          ),
          IconButton(
            visualDensity: VisualDensity.compact,
            icon: const Icon(Icons.add_circle_outline),
            onPressed: editable ? () => s.editarSegmento(i, seg.tipo, seg.ms + 50) : null,
          ),
          IconButton(
            visualDensity: VisualDensity.compact,
            icon: const Icon(Icons.delete_outline, color: Colors.redAccent),
            onPressed: editable
                ? () async {
                    final ok = await _confirmar('Eliminar tramo', '¿Eliminar el tramo ${i + 1}?');
                    if (ok) s.eliminarSegmento(i);
                  }
                : null,
          ),
        ],
      ),
    );
  }

  // --- Frenado y aceleración ---------------------------------------------------
  Widget _cardParametrosMapa(BluetoothService s, bool conectado) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _titulo('Frenado y aceleración (modo Mapeo)', Icons.speed),
            for (final p in _paramsMapa) _filaParametro(s, p, conectado),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Repetir el mapa (varias vueltas)', style: TextStyle(fontSize: 14)),
              subtitle: const Text(
                'Al terminar el último tramo vuelve al primero, para carreras de más de una vuelta.',
                style: TextStyle(fontSize: 11, color: Colors.white54),
              ),
              value: s.repetir,
              onChanged: conectado ? (v) => s.setRepetir(v) : null,
            ),
            const Padding(
              padding: EdgeInsets.only(top: 6),
              child: Text(
                'Frenar antes de la curva: cuántos ms antes de que termine la recta (según el mapa) '
                'empieza a frenar. Más alto = frena antes.\n'
                'Acelerar al salir de la curva: con un valor NEGATIVO empieza a acelerar ese tiempo ANTES de '
                'que termine la curva (según el mapa). Con un valor POSITIVO espera ese tiempo después de '
                'empezar la recta antes de acelerar. 0 = justo cuando el mapa dice que empieza la recta.',
                style: TextStyle(fontSize: 11, color: Colors.white54),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // --- Ajustes avanzados -------------------------------------------------------
  Widget _cardAvanzado(BluetoothService s, bool conectado) {
    return Card(
      child: ExpansionTile(
        leading: const Icon(Icons.tune_outlined, color: Colors.lightBlueAccent),
        title: const Text('Ajustes avanzados', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
        subtitle: const Text('Se pueden dejar como están', style: TextStyle(fontSize: 12, color: Colors.white54)),
        childrenPadding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
        children: [
          for (final p in _paramsAvanzados) _filaParametro(s, p, conectado),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Frenar si el error es grande', style: TextStyle(fontSize: 14)),
            subtitle: const Text(
              'Seguridad: aunque el mapa diga recta, si el robot se está yendo de la línea usa el PID de curva.',
              style: TextStyle(fontSize: 11, color: Colors.white54),
            ),
            value: s.sens,
            onChanged: conectado ? (v) => s.setSens(v) : null,
          ),
          const SizedBox(height: 6),
          const Text(
            'Umbral de curva: cuánto error tiene que acumular el robot para considerar que está en una curva. '
            'Si marca curvas en las rectas, subilo; si no detecta curvas, bajalo.\n'
            'Confirmación de tramo: cuánto tiempo seguido tiene que durar un cambio de recta a curva para '
            'creerlo (ignora ruidos).\n'
            'Tramo mínimo al grabar: al grabar, los tramos más cortos que esto se fusionan con el vecino, '
            'para que no queden rectas o curvas falsas.\n'
            'Subida y bajada de velocidad: qué tan rápido cambia la velocidad al pasar de curva a recta y al '
            'revés. Un número más alto hace el cambio más brusco; más bajo, más suave '
            '(con 1.0 pasa de 130 a 255 en unos 0,13 s).',
            style: TextStyle(fontSize: 11, color: Colors.white54),
          ),
        ],
      ),
    );
  }

  Widget _filaParametro(BluetoothService s, _ParamDef p, bool conectado) {
    final valor = _local[p.cmd] ?? _valorRobot(s, p.cmd);
    final texto = p.unidad.isEmpty ? _formato(p, valor) : '${_formato(p, valor)} ${p.unidad}';
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          Expanded(child: Text(p.label, style: const TextStyle(fontSize: 14))),
          IconButton(
            visualDensity: VisualDensity.compact,
            icon: const Icon(Icons.remove_circle_outline),
            onPressed: conectado ? () => _cambiar(s, p, valor - p.paso) : null,
          ),
          SizedBox(
            width: 84,
            child: InkWell(
              onTap: conectado
                  ? () async {
                      final txt = await _pedirTexto(p.label, _formato(p, valor));
                      if (txt == null || !mounted) return;
                      final nuevo = double.tryParse(txt.trim().replaceAll(',', '.'));
                      if (nuevo != null) _cambiar(s, p, nuevo);
                    }
                  : null,
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Text(texto, textAlign: TextAlign.center, style: const TextStyle(fontSize: 15)),
              ),
            ),
          ),
          IconButton(
            visualDensity: VisualDensity.compact,
            icon: const Icon(Icons.add_circle_outline),
            onPressed: conectado ? () => _cambiar(s, p, valor + p.paso) : null,
          ),
        ],
      ),
    );
  }

  // --- Guardar ---------------------------------------------------------------
  Widget _cardGuardar(BluetoothService s, bool conectado) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _titulo('Guardar en el robot', Icons.save),
            const Text(
              'Guarda en la memoria del robot los tres PID (Normal, Recta y Curva), los ajustes, '
              'el modo de largada y el mapa. Sin esto, todo se pierde al apagarlo.',
              style: TextStyle(fontSize: 12, color: Colors.white70),
            ),
            const SizedBox(height: 10),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: conectado ? () => s.sendCommand('save') : null,
                icon: const Icon(Icons.save),
                label: const Text('Guardar todo'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // --- Ayuda -----------------------------------------------------------------
  Widget _cardAyuda() {
    return const Card(
      child: ExpansionTile(
        title: Text('Cómo se usa'),
        childrenPadding: EdgeInsets.fromLTRB(16, 0, 16, 12),
        expandedCrossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '1. Modo NORMAL: tuneá Kp, Ki, Kd y velocidad en "PID y velocidad > Normal". '
            'Es un solo PID para toda la pista y no usa el mapa.\n\n'
            '2. Elegí la velocidad y el PID de CURVA (pestaña "Curva").\n\n'
            '3. Con el robot en el punto de largada y calibrado, tocá "Grabar pasada". Da UNA vuelta con el '
            'PID de curva y anota los tramos. Cuando vuelva al punto de largada, tocá "Terminar pasada".\n\n'
            '4. Volvé a ponerlo en el MISMO punto y repetí. Cada pasada se promedia con las anteriores: '
            'cuantas más hagas, más preciso queda. Si una pasada dura muy distinto del mapa '
            '(por ejemplo, diste dos vueltas) o sus tramos no coinciden, se descarta y te avisa.\n\n'
            '5. Revisá la barra y la tabla de tramos y corregí lo que veas mal.\n\n'
            '6. Cargá el PID y la velocidad de RECTA (pestaña "Recta").\n\n'
            '7. Cambiá el modo a "Mapeo" y largá. Como grabaste despacio, los tiempos de las rectas van a '
            'ser más largos que los reales. Corré UNA vuelta, parala al volver al punto de largada y tocá '
            '"Usar tiempos de la última carrera": el robot mide cuánto tardó en cada tramo y los copia al mapa. '
            'Repetilo un par de veces si querés afinar. También podés escribir los tiempos a mano.\n\n'
            '8. Ajustá "Frenar antes de la curva" hasta que frene justo antes de cada curva, y "Acelerar al '
            'salir de la curva" hasta que acelere cuando quieras. Si la carrera es de varias vueltas, dejá '
            'activado "Repetir el mapa".\n\n'
            '9. Tocá "Guardar todo" para que el robot recuerde todo al apagarse.\n\n'
            'Si algo sale mal en carrera, volvé al modo NORMAL: no usa el mapa.',
            style: TextStyle(fontSize: 13),
          ),
        ],
      ),
    );
  }
}
