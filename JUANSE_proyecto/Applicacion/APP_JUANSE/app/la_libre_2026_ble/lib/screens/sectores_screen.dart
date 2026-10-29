import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../services/bluetooth_service.dart';

/// Parámetro editable con botones − / +.
class _Par {
  final String cmd; // comando del firmware
  final String label;
  final String unidad;
  final double paso;
  final double min;
  final double max;
  final int decimales;
  const _Par(this.cmd, this.label, this.unidad, this.paso, this.min, this.max, this.decimales);
}

// Los tres PID. El rápido es el de "recta" y el lento el de "curva" del modo Mapa; el medio tiene el suyo.
const List<_Par> _pidRapido = [
  _Par('rkp', 'Kp', '', 0.1, 0, 20, 1),
  _Par('rki', 'Ki', '', 0.001, 0, 1, 4),
  _Par('rkd', 'Kd', '', 0.5, 0, 100, 1),
  _Par('frap', '% de VM', '', 0.05, 0.1, 1.0, 2),
];
const List<_Par> _pidMedio = [
  _Par('mkp', 'Kp', '', 0.1, 0, 20, 1),
  _Par('mki', 'Ki', '', 0.001, 0, 1, 4),
  _Par('mkd', 'Kd', '', 0.5, 0, 100, 1),
  _Par('fmed', '% de VM', '', 0.05, 0.1, 1.0, 2),
];
const List<_Par> _pidLento = [
  _Par('ckp', 'Kp', '', 0.1, 0, 20, 1),
  _Par('cki', 'Ki', '', 0.001, 0, 1, 4),
  _Par('ckd', 'Kd', '', 0.5, 0, 100, 1),
  _Par('flen', '% de VM', '', 0.05, 0.1, 1.0, 2),
];
const _Par _parVm = _Par('vm', 'VM (velocidad base)', '', 5.0, 0, 255, 0);
const _Par _parTant = _Par('tant', 'Terminar antes', 'ms', 10.0, 0, 2000, 0);

const List<String> _nombresTipo = ['Rápido', 'Medio', 'Lento'];
const List<Color> _coloresTipo = [Colors.greenAccent, Colors.amber, Colors.redAccent];

/// Pestaña "Sectores": la pista se arma a mano como una lista de sectores. Cada sector tiene un PID
/// (rápido, medio o lento) y un tiempo. Los cambios de sector son solo por reloj.
class SectoresScreen extends StatefulWidget {
  const SectoresScreen({super.key});

  @override
  State<SectoresScreen> createState() => _SectoresScreenState();
}

class _SectoresScreenState extends State<SectoresScreen> {
  final Map<String, double> _local = {};
  final Map<String, Timer> _timersEnvio = {};
  final Map<String, Timer> _timersLimpieza = {};
  int _ultimoAvisoId = 0;

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
      case 'vm':
        return double.tryParse(s.ve) ?? 0;
      case 'rkp':
        return s.rkp;
      case 'rki':
        return s.rki;
      case 'rkd':
        return s.rkd;
      case 'ckp':
        return s.ckp;
      case 'cki':
        return s.cki;
      case 'ckd':
        return s.ckd;
      case 'mkp':
        return s.mkp;
      case 'mki':
        return s.mki;
      case 'mkd':
        return s.mkd;
      case 'frap':
        return s.frap;
      case 'fmed':
        return s.fmed;
      case 'flen':
        return s.flen;
      case 'tant':
        return s.tant.toDouble();
    }
    return 0;
  }

  String _formato(_Par p, double v) {
    return p.decimales == 0 ? v.round().toString() : v.toStringAsFixed(p.decimales);
  }

  // Cambia un parámetro: se muestra al instante y se envía 0,4 s después del último toque
  void _cambiar(BluetoothService s, _Par p, double nuevo) {
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

  Future<String?> _pedirNumero(String titulo, String actual) {
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

  Future<String?> _pedirNombre() {
    final controller = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Nombre de los sectores'),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLength: 15,
          textCapitalization: TextCapitalization.sentences,
          inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[A-Za-z0-9 _.\-]'))],
          decoration: const InputDecoration(
            hintText: 'Ej: Pista 1 carril A',
            helperText: 'Si ya hay uno con ese nombre, se reemplaza',
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancelar')),
          FilledButton(onPressed: () => Navigator.pop(ctx, controller.text), child: const Text('Guardar')),
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

  // ---------------------------------------------------------------------------
  // Pantalla
  // ---------------------------------------------------------------------------
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Sectores')),
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
              _cardSectores(s, conectado, corriendo),
              _cardPid(s, conectado),
              _cardAjustes(s, conectado),
              _cardBiblioteca(s, conectado),
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

  // --- Modo de largada ---------------------------------------------------------
  Widget _cardModo(BluetoothService s, bool conectado, bool corriendo) {
    final sinSectores = s.usarSectores && s.sectores.isEmpty;
    String texto;
    switch (s.modoLargada) {
      case 2:
        texto = 'SECTORES: el robot sigue la lista de sectores de abajo, cambiando de PID solo por tiempo.';
        break;
      case 1:
        texto = 'MAPEO: detecta rectas y curvas con los sensores (modo anterior, pestaña Mapa).';
        break;
      default:
        texto = 'NORMAL: un solo PID para toda la pista.';
    }
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _titulo('Modo de largada', Icons.flag),
            SizedBox(
              width: double.infinity,
              child: SegmentedButton<int>(
                segments: const [
                  ButtonSegment<int>(value: 0, label: Text('Normal'), icon: Icon(Icons.speed)),
                  ButtonSegment<int>(value: 1, label: Text('Mapeo'), icon: Icon(Icons.map)),
                  ButtonSegment<int>(value: 2, label: Text('Sectores'), icon: Icon(Icons.linear_scale)),
                ],
                selected: {s.modoLargada},
                onSelectionChanged: (conectado && !corriendo) ? (sel) => s.setModoLargada(sel.first) : null,
              ),
            ),
            const SizedBox(height: 8),
            Text(texto, style: const TextStyle(fontSize: 13, color: Colors.white70)),
            if (sinSectores)
              const Padding(
                padding: EdgeInsets.only(top: 8),
                child: Text(
                  '⚠️ La lista de sectores está vacía: el robot va a largar en modo Normal hasta que agregues sectores.',
                  style: TextStyle(fontSize: 13, color: Colors.orangeAccent),
                ),
              ),
          ],
        ),
      ),
    );
  }

  // --- Lista de sectores ---------------------------------------------------------
  Widget _cardSectores(BluetoothService s, bool conectado, bool corriendo) {
    final puedeEditar = conectado && !corriendo;
    final actual = (corriendo && s.modoCorrida == 3) ? s.segmentoActual : -1;
    int total = 0;
    for (final x in s.sectores) {
      total += x.ms;
    }
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _titulo('Sectores de la pista (${s.sectores.length}/${BluetoothService.maxSectores})', Icons.linear_scale),
            Text(
              'Tiempo total: ${(total / 1000).toStringAsFixed(2)} s. Cada sector dura lo que le pongas, '
              'contado desde la largada.',
              style: const TextStyle(fontSize: 12, color: Colors.white70),
            ),
            const SizedBox(height: 8),
            if (s.sectores.isNotEmpty) _barraSectores(s, actual),
            for (int i = 0; i < s.sectores.length; i++) _filaSector(s, i, puedeEditar, i == actual),
            if (s.sectores.isEmpty)
              const Padding(
                padding: EdgeInsets.only(top: 4, bottom: 4),
                child: Text('Todavía no hay sectores. Agregá el primero con los botones de abajo.',
                    style: TextStyle(fontSize: 12, color: Colors.white54)),
              ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 6,
              children: [
                for (int t = 0; t < 3; t++)
                  OutlinedButton.icon(
                    onPressed: (puedeEditar && s.sectores.length < BluetoothService.maxSectores)
                        ? () => s.agregarSector(t)
                        : null,
                    icon: Icon(Icons.add, color: _coloresTipo[t]),
                    label: Text(_nombresTipo[t]),
                  ),
              ],
            ),
            if (s.sectores.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: TextButton.icon(
                  onPressed: puedeEditar
                      ? () async {
                          final ok = await _confirmar('Borrar todos los sectores', '¿Borrar toda la lista de sectores?');
                          if (ok) s.sendCommand('secn:0');
                        }
                      : null,
                  icon: const Icon(Icons.delete_sweep),
                  label: const Text('Borrar todos'),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _barraSectores(BluetoothService s, int actual) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: SizedBox(
        height: 26,
        child: Row(
          children: [
            for (int i = 0; i < s.sectores.length; i++)
              Expanded(
                flex: s.sectores[i].ms < 1 ? 1 : s.sectores[i].ms,
                child: Container(
                  margin: const EdgeInsets.symmetric(horizontal: 1),
                  decoration: BoxDecoration(
                    color: _coloresTipo[s.sectores[i].tipo.clamp(0, 2).toInt()].withAlpha(i == actual ? 255 : 150),
                    borderRadius: BorderRadius.circular(4),
                    border: i == actual ? Border.all(color: Colors.white, width: 2) : null,
                  ),
                  alignment: Alignment.center,
                  child: Text('${i + 1}', style: const TextStyle(fontSize: 11, color: Colors.black, fontWeight: FontWeight.bold)),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _filaSector(BluetoothService s, int i, bool puedeEditar, bool esActual) {
    final sec = s.sectores[i];
    final tipo = sec.tipo.clamp(0, 2).toInt();
    final color = _coloresTipo[tipo];
    return Container(
      margin: const EdgeInsets.only(top: 4),
      padding: const EdgeInsets.symmetric(horizontal: 4),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(6),
        border: esActual ? Border.all(color: Colors.white, width: 1.5) : null,
      ),
      child: Row(
        children: [
          SizedBox(
            width: 24,
            child: Text('${i + 1}', style: const TextStyle(fontSize: 13, color: Colors.white54)),
          ),
          InkWell(
            onTap: puedeEditar ? () => s.editarSector(i, (tipo + 1) % 3, sec.ms) : null,
            child: Container(
              width: 68,
              padding: const EdgeInsets.symmetric(vertical: 6),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(6),
                border: Border.all(color: color, width: 1),
              ),
              alignment: Alignment.center,
              child: Text(_nombresTipo[tipo], style: TextStyle(fontSize: 13, color: color, fontWeight: FontWeight.bold)),
            ),
          ),
          const Spacer(),
          IconButton(
            visualDensity: VisualDensity.compact,
            icon: const Icon(Icons.remove_circle_outline),
            onPressed: puedeEditar ? () => s.editarSector(i, tipo, sec.ms - 50) : null,
          ),
          SizedBox(
            width: 64,
            child: InkWell(
              onTap: puedeEditar
                  ? () async {
                      final txt = await _pedirNumero('Tiempo del sector ${i + 1} (ms)', sec.ms.toString());
                      if (txt == null || !mounted) return;
                      final nuevo = int.tryParse(txt.trim());
                      if (nuevo != null) s.editarSector(i, tipo, nuevo);
                    }
                  : null,
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Text('${sec.ms} ms', textAlign: TextAlign.center, style: const TextStyle(fontSize: 14)),
              ),
            ),
          ),
          IconButton(
            visualDensity: VisualDensity.compact,
            icon: const Icon(Icons.add_circle_outline),
            onPressed: puedeEditar ? () => s.editarSector(i, tipo, sec.ms + 50) : null,
          ),
          PopupMenuButton<String>(
            enabled: puedeEditar,
            onSelected: (v) {
              if (v == 'subir') s.moverSector(i, -1);
              if (v == 'bajar') s.moverSector(i, 1);
              if (v == 'borrar') s.eliminarSector(i);
            },
            itemBuilder: (ctx) => const [
              PopupMenuItem<String>(value: 'subir', child: Text('Subir')),
              PopupMenuItem<String>(value: 'bajar', child: Text('Bajar')),
              PopupMenuItem<String>(value: 'borrar', child: Text('Eliminar')),
            ],
          ),
        ],
      ),
    );
  }

  // --- Los 3 PID ---------------------------------------------------------------------
  Widget _filaPar(BluetoothService s, _Par p, bool conectado) {
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
                      final txt = await _pedirNumero(p.label, _formato(p, valor));
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

  Widget _bloquePid(BluetoothService s, int tipo, List<_Par> pars, bool conectado) {
    final vm = _local['vm'] ?? _valorRobot(s, 'vm');
    final factor = _local[pars.last.cmd] ?? _valorRobot(s, pars.last.cmd);
    final pwm = (vm * factor).round();
    final color = _coloresTipo[tipo];
    return Container(
      margin: const EdgeInsets.only(top: 10),
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color, width: 1),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'PID ${_nombresTipo[tipo].toUpperCase()}  ·  va a $pwm de PWM (${(factor * 100).round()}% de VM)',
            style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: color),
          ),
          for (final p in pars) _filaPar(s, p, conectado),
        ],
      ),
    );
  }

  Widget _cardPid(BluetoothService s, bool conectado) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _titulo('Los 3 PID', Icons.tune),
            const Text(
              'Cada PID tiene su Kp, Ki y Kd y su velocidad como porcentaje de VM: si cambiás VM, los tres se '
              'escalan juntos. El PID rápido es el mismo que "Recta" y el lento el mismo que "Curva" en el modo '
              'Mapeo (la velocidad de esos dos solo cuenta allá).',
              style: TextStyle(fontSize: 12, color: Colors.white70),
            ),
            const SizedBox(height: 6),
            _filaPar(s, _parVm, conectado),
            _bloquePid(s, 0, _pidRapido, conectado),
            _bloquePid(s, 1, _pidMedio, conectado),
            _bloquePid(s, 2, _pidLento, conectado),
          ],
        ),
      ),
    );
  }

  // --- Ajustes --------------------------------------------------------------------------
  Widget _cardAjustes(BluetoothService s, bool conectado) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _titulo('Ajustes', Icons.settings),
            _filaPar(s, _parTant, conectado),
            const Text(
              'Terminar antes: cuando el sector que sigue es MÁS LENTO, el cambio se adelanta esos milisegundos '
              '(para frenar antes de la curva). Si el que sigue es más rápido no se adelanta nada.',
              style: TextStyle(fontSize: 11, color: Colors.white54),
            ),
            const SizedBox(height: 6),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Repetir la lista', style: TextStyle(fontSize: 14)),
              subtitle: const Text(
                'Al terminar el último sector vuelve al primero (varias vueltas). Apagado: se queda con el PID '
                'del último sector.',
                style: TextStyle(fontSize: 11, color: Colors.white54),
              ),
              value: s.repetir,
              onChanged: conectado ? (v) => s.setRepetir(v) : null,
            ),
            const Text(
              'Los cambios de velocidad entre PID usan una rampa para que las ruedas no patinen. Se regula en '
              'Mapa → Ajustes avanzados (subida y bajada de velocidad).',
              style: TextStyle(fontSize: 11, color: Colors.white54),
            ),
          ],
        ),
      ),
    );
  }

  // --- Sectores guardados con nombre ----------------------------------------------------
  Widget _cardBiblioteca(BluetoothService s, bool conectado) {
    final puedeEditar = conectado && s.estadoVal == 0;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: _titulo(
                    'Sectores guardados (${s.bibSectores.length}/${BluetoothService.maxMapasGuardados})',
                    Icons.folder_open,
                  ),
                ),
                IconButton(
                  tooltip: 'Actualizar la lista',
                  icon: const Icon(Icons.refresh),
                  onPressed: conectado ? () => s.pedirBibSectores() : null,
                ),
              ],
            ),
            const Text(
              'Guardá con nombre la lista de cada pista y cargala cuando la necesites. Se guardan en la memoria '
              'del robot al instante. Al cargar una, pasa a ser la lista activa. Solo con el robot parado.',
              style: TextStyle(fontSize: 12, color: Colors.white70),
            ),
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: (puedeEditar && s.sectores.isNotEmpty)
                    ? () async {
                        final nombre = await _pedirNombre();
                        if (nombre == null || !mounted) return;
                        s.guardarSectoresEnBiblioteca(nombre);
                      }
                    : null,
                icon: const Icon(Icons.save_alt),
                label: const Text('Guardar la lista actual como...'),
              ),
            ),
            if (s.bibSectores.isEmpty)
              const Padding(
                padding: EdgeInsets.only(top: 10),
                child: Text('Todavía no hay listas guardadas.', style: TextStyle(fontSize: 12, color: Colors.white54)),
              ),
            for (final m in s.bibSectores) _filaGuardada(s, m, puedeEditar),
          ],
        ),
      ),
    );
  }

  Widget _filaGuardada(BluetoothService s, SectoresGuardadoInfo m, bool puedeEditar) {
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Row(
        children: [
          const Icon(Icons.linear_scale, size: 20),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(m.nombre, style: const TextStyle(fontSize: 14), overflow: TextOverflow.ellipsis),
                Text('${m.sectores} sectores', style: const TextStyle(fontSize: 11, color: Colors.white54)),
              ],
            ),
          ),
          TextButton(
            onPressed: puedeEditar
                ? () async {
                    final ok = await _confirmar('Cargar sectores',
                        'Se reemplaza la lista actual del robot por "${m.nombre}". Si la actual no está guardada, '
                        'se pierde. ¿Seguro?');
                    if (ok) s.cargarSectoresDeBiblioteca(m);
                  }
                : null,
            child: const Text('Cargar'),
          ),
          IconButton(
            tooltip: 'Borrar',
            visualDensity: VisualDensity.compact,
            icon: const Icon(Icons.delete_outline),
            onPressed: puedeEditar
                ? () async {
                    final ok = await _confirmar('Borrar lista guardada', '¿Borrar "${m.nombre}"?');
                    if (ok) s.borrarSectoresDeBiblioteca(m);
                  }
                : null,
          ),
        ],
      ),
    );
  }

  Widget _cardGuardar(BluetoothService s, bool conectado) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _titulo('Guardar en el robot', Icons.save),
            const Text(
              'Guarda en la memoria del robot los tres PID, los porcentajes, "terminar antes", la lista de '
              'sectores actual y el modo de largada. Sin esto, todo se pierde al apagarlo.',
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

  Widget _cardAyuda() {
    return const Card(
      child: Padding(
        padding: EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Cómo se usa', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
            SizedBox(height: 6),
            Text(
              '1. Dividí la pista en sectores y agregalos en orden. Por ejemplo: recta, zig-zag, curva, recta, '
              'curva, rampa, curva, recta → Rápido, Medio, Lento, Rápido, Lento, Medio, Lento, Rápido.\n\n'
              '2. Ponele a cada sector cuánto dura (ms). El tiempo corre desde que largás, y el robot cambia de '
              'PID solo por reloj: nada de lo que lean los sensores lo mueve.\n\n'
              '3. Tuneá los tres PID y sus porcentajes de VM. Rápido: Kp bajo, 100%. Lento: Kp más alto, 50%. '
              'Medio: en el medio, 80%.\n\n'
              '4. "Terminar antes" frena un poco antes del cambio a un sector más lento.\n\n'
              '5. Elegí el modo Sectores y largá. Corré, ajustá los tiempos y guardá la lista con nombre para '
              'cada pista. La pestaña Asesor también te recomienda cambios en este modo.\n\n'
              'Ojo: como todo va por reloj, si cambia mucho la batería o el agarre de la pista, los bordes se '
              'corren. Corré siempre con la batería bien cargada y revisá los tiempos si cambia algo.',
              style: TextStyle(fontSize: 12, color: Colors.white70),
            ),
          ],
        ),
      ),
    );
  }
}
