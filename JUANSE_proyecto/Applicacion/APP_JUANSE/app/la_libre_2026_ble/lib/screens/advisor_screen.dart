import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/bluetooth_service.dart';
import '../services/pid_advisor.dart';

/// Pestaña "Asesor": después de cada corrida muestra cómo se comportó el robot y RECOMIENDA qué
/// parámetros tocar. No cambia nada solo: cada recomendación tiene su botón "Aplicar".
class AdvisorScreen extends StatelessWidget {
  const AdvisorScreen({super.key});

  String _dos(int n) => n.toString().padLeft(2, '0');

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Asesor de PID')),
      body: Consumer<BluetoothService>(
        builder: (context, s, _) {
          final conectado = s.isConnected;
          final informe = s.ultimoInforme;
          return ListView(
            padding: const EdgeInsets.all(12),
            children: [
              _cardEstado(s, conectado),
              if (informe != null) ..._secciones(context, s, informe, conectado),
              if (s.historialInformes.length > 1) _cardHistorial(s),
            ],
          );
        },
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

  Widget _cardEstado(BluetoothService s, bool conectado) {
    String estado;
    if (!conectado) {
      estado = 'Conectate al robot para empezar.';
    } else if (s.grabandoCorrida) {
      estado = 'Corrida en curso (${s.muestrasCorridaActual} muestras). Cuando pares el robot te muestro las recomendaciones.';
    } else if (s.ultimoInforme == null) {
      estado = 'Largá el robot y dejalo dar una vuelta completa. Al pararlo, acá aparecen las recomendaciones.';
    } else {
      estado = 'Listo. Corrida analizada. Podés largar otra vez para comparar.';
    }
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _titulo('Asesor de PID', Icons.insights),
            const Text(
              'Mira cómo se comportó el error durante la corrida (si oscila, si una rueda se frena, si anda '
              'corrido) y te sugiere qué parámetro tocar. Solo recomienda: no se cambia nada hasta que toques '
              '"Aplicar". Cambiá de a una cosa por vez y corré de nuevo para comparar. Son reglas simples, no '
              'una verdad absoluta: la pista manda. Para separar rectas de curvas en el modo Normal hace falta '
              'el firmware nuevo.',
              style: TextStyle(fontSize: 12, color: Colors.white70),
            ),
            const SizedBox(height: 8),
            Text(estado, style: const TextStyle(fontSize: 13)),
          ],
        ),
      ),
    );
  }

  List<Widget> _secciones(BuildContext context, BluetoothService s, InformeAsesor informe, bool conectado) {
    final puedeAplicar = conectado && s.estadoVal != 1;
    return [
      Card(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _titulo('Última corrida (${informe.duracionS.toStringAsFixed(1)} s, ${_dos(informe.hora.hour)}:${_dos(informe.hora.minute)})',
                  Icons.speed),
              if (informe.grupos.isEmpty)
                const Text('No hubo datos suficientes.', style: TextStyle(fontSize: 12, color: Colors.white54))
              else ...[
                _filaTabla('Tramo', 'Tiempo', 'Error', 'Oscila', 'Rueda 0', true),
                for (final g in informe.grupos)
                  _filaTabla(
                    g.nombre,
                    '${g.segundos.toStringAsFixed(1)} s',
                    g.rms.toStringAsFixed(0),
                    '${g.oscHz.toStringAsFixed(1)} Hz',
                    '${(g.satCero * 100).round()}%',
                    false,
                  ),
                const Padding(
                  padding: EdgeInsets.only(top: 6),
                  child: Text(
                    'Error = error RMS (cuánto se aleja de la línea). Oscila = veces por segundo que cruza la línea. '
                    'Rueda 0 = porcentaje del tiempo que una rueda está frenada del todo.',
                    style: TextStyle(fontSize: 11, color: Colors.white54),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
      if (informe.sugerencias.isNotEmpty)
        Card(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _titulo('Recomendaciones', Icons.lightbulb_outline),
                const Text(
                  'Calculadas sobre los valores con los que corriste. Después de aplicar, tocá Guardar si querés '
                  'que queden en el robot al apagarlo.',
                  style: TextStyle(fontSize: 11, color: Colors.white54),
                ),
                for (final g in informe.sugerencias) _filaSugerencia(context, s, g, puedeAplicar),
              ],
            ),
          ),
        ),
      if (informe.notas.isNotEmpty)
        Card(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _titulo('Notas', Icons.info_outline),
                for (final n in informe.notas)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 6),
                    child: Text('• $n', style: const TextStyle(fontSize: 12, color: Colors.white70)),
                  ),
              ],
            ),
          ),
        ),
    ];
  }

  Widget _filaTabla(String a, String b, String c, String d, String e, bool encabezado) {
    final estilo = TextStyle(
      fontSize: 12,
      fontWeight: encabezado ? FontWeight.bold : FontWeight.normal,
      color: encabezado ? Colors.white70 : Colors.white,
    );
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          Expanded(flex: 4, child: Text(a, style: estilo)),
          Expanded(flex: 2, child: Text(b, style: estilo)),
          Expanded(flex: 2, child: Text(c, style: estilo)),
          Expanded(flex: 3, child: Text(d, style: estilo)),
          Expanded(flex: 2, child: Text(e, style: estilo)),
        ],
      ),
    );
  }

  Widget _filaSugerencia(BuildContext context, BluetoothService s, Sugerencia g, bool puedeAplicar) {
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  '${g.etiqueta}: ${g.actualTexto} → ${g.sugeridoTexto}',
                  style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold),
                ),
              ),
              FilledButton(
                onPressed: puedeAplicar
                    ? () {
                        s.sendCommand('${g.cmd}:${g.sugeridoTexto}');
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            content: Text('Aplicado: ${g.etiqueta} = ${g.sugeridoTexto}'),
                            duration: const Duration(seconds: 3),
                          ),
                        );
                      }
                    : null,
                child: const Text('Aplicar'),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(g.motivo, style: const TextStyle(fontSize: 12, color: Colors.white70)),
        ],
      ),
    );
  }

  String _resumenParams(InformeAsesor i) {
    final p = i.params;
    final r = i.rectas;
    if (r != null && r.nombre.startsWith('Mapa')) {
      return 'Kp ${p.rkp.toStringAsFixed(1)}  Kd ${p.rkd.toStringAsFixed(1)}  V ${p.rvm}';
    }
    return 'Kp ${p.kp.toStringAsFixed(1)}  Kd ${p.kd.toStringAsFixed(1)}  VM ${p.vm}';
  }

  Widget _cardHistorial(BluetoothService s) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _titulo('Corridas anteriores', Icons.history),
            const Text(
              'Para comparar: si al cambiar un parámetro el error y la oscilación de las rectas bajan, vas bien.',
              style: TextStyle(fontSize: 11, color: Colors.white54),
            ),
            const SizedBox(height: 6),
            for (final i in s.historialInformes)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 3),
                child: Row(
                  children: [
                    Expanded(
                      flex: 2,
                      child: Text('${_dos(i.hora.hour)}:${_dos(i.hora.minute)}', style: const TextStyle(fontSize: 12)),
                    ),
                    Expanded(
                      flex: 6,
                      child: Text(_resumenParams(i), style: const TextStyle(fontSize: 12)),
                    ),
                    Expanded(
                      flex: 5,
                      child: Text(
                        i.rectas == null
                            ? 'sin datos de recta'
                            : 'Error ${i.rectas!.rms.toStringAsFixed(0)} · ${i.rectas!.oscHz.toStringAsFixed(1)} Hz',
                        style: const TextStyle(fontSize: 12, color: Colors.white70),
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}
