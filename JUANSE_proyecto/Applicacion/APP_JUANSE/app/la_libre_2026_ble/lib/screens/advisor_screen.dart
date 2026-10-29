import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/bluetooth_service.dart';
import '../services/pid_advisor.dart';

/// Pestaña "Asesor": después de cada corrida muestra cómo se comportó el robot y RECOMIENDA qué
/// parámetros tocar. Aprende de tus corridas: compara con la anterior y te dice si el último
/// cambio mejoró o empeoró. No cambia nada solo: cada recomendación tiene su botón "Aplicar".
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
      estado = 'Listo. Corrida analizada. Cambiá UNA cosa, largá otra vez y te digo si mejoró.';
    }
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _titulo('Asesor de PID', Icons.insights),
            const Text(
              'Mide el error de cada corrida (rectas y curvas por separado, y cómo se estabiliza al salir de las '
              'curvas), la compara con la anterior y te sugiere qué parámetro tocar, con su nivel de confianza. '
              'Solo recomienda: no se cambia nada hasta que toques "Aplicar". Son reglas de control y '
              'comparación entre corridas, no una verdad absoluta: la pista manda. Para separar rectas de curvas '
              'en el modo Normal hace falta el firmware nuevo.',
              style: TextStyle(fontSize: 12, color: Colors.white70),
            ),
            const SizedBox(height: 8),
            Text(estado, style: const TextStyle(fontSize: 13)),
          ],
        ),
      ),
    );
  }

  Color _colorPuntaje(int p) {
    if (p >= 75) return Colors.greenAccent;
    if (p >= 50) return Colors.amber;
    return Colors.redAccent;
  }

  List<Widget> _secciones(BuildContext context, BluetoothService s, InformeAsesor informe, bool conectado) {
    final puedeAplicar = conectado && s.estadoVal != 1;
    return [
      // ---- Diagnóstico y puntaje ----
      Card(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _titulo('Diagnóstico (${informe.duracionS.toStringAsFixed(1)} s, ${_dos(informe.hora.hour)}:${_dos(informe.hora.minute)})',
                  Icons.psychology),
              Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    '${informe.puntaje}',
                    style: TextStyle(fontSize: 40, fontWeight: FontWeight.bold, color: _colorPuntaje(informe.puntaje)),
                  ),
                  const Padding(
                    padding: EdgeInsets.only(bottom: 8, left: 4),
                    child: Text('/ 100', style: TextStyle(fontSize: 14, color: Colors.white54)),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.only(bottom: 6),
                      child: Text(
                        'Modo ${informe.modo} · velocidad media ${informe.velocidadMedia.round()}',
                        style: const TextStyle(fontSize: 12, color: Colors.white70),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Text(informe.diagnostico, style: const TextStyle(fontSize: 13)),
              if (informe.salidaEventos >= 2)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(
                    'Al salir de ${informe.salidaEventos} curvas: se pasa un ${(informe.salidaSobrepaso * 100).round()}% '
                    'para el otro lado y tarda ${informe.salidaAsentamientoS.toStringAsFixed(1)} s en calmarse.',
                    style: const TextStyle(fontSize: 12, color: Colors.white70),
                  ),
                ),
            ],
          ),
        ),
      ),
      // ---- Resultado del último cambio ----
      if (informe.evaluacion != null) _cardEvaluacion(informe.evaluacion!),
      // ---- Tabla ----
      Card(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _titulo('Números de la corrida', Icons.speed),
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
      // ---- Recomendaciones ----
      if (informe.sugerencias.isNotEmpty)
        Card(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _titulo('Recomendaciones', Icons.lightbulb_outline),
                const Text(
                  'Ordenadas de más a menos confiable. Aplicá solo la primera, corré de nuevo y mirá el resultado: '
                  'así sabés qué cambio hizo qué. Calculadas sobre los valores con los que corriste; después de '
                  'aplicar, tocá Guardar si querés que queden en el robot al apagarlo.',
                  style: TextStyle(fontSize: 11, color: Colors.white54),
                ),
                for (int i = 0; i < informe.sugerencias.length; i++)
                  _filaSugerencia(context, s, informe.sugerencias[i], puedeAplicar, i == 0),
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

  Widget _cardEvaluacion(Evaluacion e) {
    IconData icono;
    Color color;
    String titulo;
    switch (e.veredicto) {
      case 'mejoro':
        icono = Icons.trending_up;
        color = Colors.greenAccent;
        titulo = 'El último cambio mejoró';
        break;
      case 'velocidad_ok':
        icono = Icons.trending_up;
        color = Colors.greenAccent;
        titulo = 'Más velocidad y sigue estable';
        break;
      case 'empeoro':
        icono = Icons.trending_down;
        color = Colors.redAccent;
        titulo = 'El último cambio empeoró';
        break;
      case 'velocidad_mal':
        icono = Icons.trending_down;
        color = Colors.redAccent;
        titulo = 'Con esa velocidad ya no es estable';
        break;
      case 'igual':
        icono = Icons.trending_flat;
        color = Colors.amber;
        titulo = 'El último cambio casi no se nota';
        break;
      default:
        icono = Icons.trending_flat;
        color = Colors.white54;
        titulo = 'Sin cambios desde la corrida anterior';
    }
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icono, size: 22, color: color),
                const SizedBox(width: 8),
                Expanded(child: Text(titulo, style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold, color: color))),
              ],
            ),
            const SizedBox(height: 6),
            Text(e.texto, style: const TextStyle(fontSize: 12, color: Colors.white70)),
          ],
        ),
      ),
    );
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

  Widget _chip(String texto, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: color, width: 0.8),
      ),
      child: Text(texto, style: TextStyle(fontSize: 10, color: color, fontWeight: FontWeight.bold)),
    );
  }

  Widget _filaSugerencia(BuildContext context, BluetoothService s, Sugerencia g, bool puedeAplicar, bool primera) {
    final colorConf = g.confianza >= 0.7 ? Colors.greenAccent : (g.confianza >= 0.45 ? Colors.amber : Colors.white54);
    return Padding(
      padding: const EdgeInsets.only(top: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 6,
            runSpacing: 4,
            children: [
              if (primera) _chip('PROBÁ ESTA PRIMERO', Colors.lightBlueAccent),
              _chip('Confianza ${g.nivel}', colorConf),
              if (g.origen == 'revertir') _chip('Volver atrás', Colors.redAccent),
              if (g.origen == 'aprendizaje') _chip('Seguir la mejora', Colors.greenAccent),
            ],
          ),
          const SizedBox(height: 6),
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
              'Para comparar: el puntaje sube cuando bajan el error y la oscilación.',
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
                      flex: 3,
                      child: Text(
                        'Puntaje ${i.puntaje}',
                        style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: _colorPuntaje(i.puntaje)),
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
