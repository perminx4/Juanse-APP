import 'package:flutter/material.dart';
import '../services/bluetooth_service.dart';

/// Tarjeta "Última corrida (medida en el robot)": muestra el resumen que manda el robot al parar
/// ({"Run":...}), medido en CADA ciclo del lazo de control, y dice en palabras si el PID le está sacando
/// velocidad y por qué. También tiene el botón de la prueba a fondo (las dos ruedas a 255 sin PID).
class ResumenCorridaCard extends StatelessWidget {
  final BluetoothService s;
  final bool conBotonPrueba;
  const ResumenCorridaCard({super.key, required this.s, this.conBotonPrueba = true});

  String _f1(double v) => v.toStringAsFixed(1);

  String _nombreModo(int m) {
    if (m == 3) return 'Sectores';
    if (m == 4) return 'Prueba a fondo';
    return 'Normal';
  }

  /// Conclusiones en palabras. Son cuentas sobre lo que midió el robot, no adivinanzas.
  List<String> _conclusiones(ResumenCorrida r) {
    final out = <String>[];
    final seg = r.ms / 1000.0;
    if (r.modo == 4) {
      out.add('Las dos ruedas estuvieron a 255 (100 %) sin PID durante ${seg.toStringAsFixed(2)} s. '
          'Medí cuánto avanzó: velocidad máxima real ≈ distancia ÷ tiempo (un poco más, por lo que tarda en '
          'acelerar). Si así ya va lento comparado con el robot de tu amigo, el límite es el hardware '
          '(tensión que le llega al TB6612, motores, reducción, ruedas), no el código.');
      return out;
    }
    if (r.modo == 3) {
      out.add('Corrida en modo SECTORES: la velocidad pedida es VM × el % de cada sector (en promedio ${_f1(r.vo)}).');
    } else if (r.vo < 254.5) {
      out.add('La velocidad pedida media fue ${_f1(r.vo)} de 255: VM está por debajo de 255 o el freno en curvas '
          '(fcur menor que 1) la bajó en las curvas.');
    }
    final perdida = r.vo - r.velMedia;
    final pct = r.vo > 0 ? 100 * perdida / r.vo : 0.0;
    if (pct < 5) {
      out.add('El PID casi no le sacó velocidad (${pct.toStringAsFixed(0)} % de lo pedido): en esta corrida el '
          'código no es lo que limita.');
    } else {
      out.add('El PID le sacó en promedio ${_f1(perdida)} de PWM (${pct.toStringAsFixed(0)} % de lo pedido). Con VM '
          'en 255 el PID solo puede frenar una rueda (la otra ya está al máximo), así que cada corrección cuesta '
          'velocidad. En las curvas eso es necesario; en las rectas, no.');
      if (r.ad >= r.ap && r.ad >= r.ai) {
        var texto = 'La mayor parte viene del término D (Kd × cambio del error): ${_f1(r.ad)} de PWM en promedio.';
        final kd = double.tryParse(s.kd) ?? 0;
        final rz = s.ruidoReposo;
        if (r.modo == 0 && kd > 0 && rz > 0) {
          final porRuido = kd * rz;
          texto += ' Con el robot quieto, Kd × ruido = ${_f1(porRuido)}';
          texto += porRuido >= 0.5 * r.ad
              ? ': buena parte de ese D es ruido de los sensores, no curvas.'
              : ': el ruido explica poco; el D viene de los movimientos reales.';
        }
        out.add('$texto Probá bajar Kd de a poco y fijate si sube la velocidad media sin que empiece a oscilar.');
      } else if (r.ap >= r.ai) {
        out.add('La mayor parte viene del término P (Kp × error): ${_f1(r.ap)} de PWM en promedio. El error de este '
            'robot llega a cientos o miles, así que un Kp chico ya corrige mucho: si sigue bien la línea con menos, '
            'bajá Kp.');
      } else {
        out.add('La mayor parte viene del término I (Ki × integral): ${_f1(r.ai)} de PWM en promedio. Bajá Ki.');
      }
    }
    if (r.rc >= 10) {
      out.add('Una rueda estuvo en 0 el ${_f1(r.rc)} % del tiempo: ahí la corrección fue igual o mayor que la '
          'velocidad pedida (el PID está saturado).');
    }
    if (r.hz > 0 && r.hz < 300) {
      out.add('El lazo de control corrió a solo ${r.hz} veces por segundo: es lento para un velocista.');
    }
    return out;
  }

  Widget _dato(String etiqueta, String valor) {
    return Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(etiqueta, style: const TextStyle(color: Colors.white70, fontSize: 11)),
          const SizedBox(height: 2),
          Text(valor, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
        ],
      ),
    );
  }

  Future<void> _pruebaAFondo(BuildContext context) async {
    final controller = TextEditingController(text: '1000');
    final txt = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Prueba a fondo (sin PID)'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Las dos ruedas van a 255 durante el tiempo que pongas y el robot para solo. NO sigue la línea: '
              'ponelo en una recta larga o en el piso, con lugar adelante (lo podés parar con Stop o el pulsador). '
              'Sirve para medir la velocidad máxima real del hardware, sin nada del control.',
              style: TextStyle(fontSize: 13),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: controller,
              autofocus: true,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(labelText: 'Duración (ms)'),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancelar')),
          FilledButton(onPressed: () => Navigator.pop(ctx, controller.text), child: const Text('Largar')),
        ],
      ),
    );
    if (txt == null) return;
    final ms = int.tryParse(txt.trim());
    if (ms == null || ms <= 0) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Poné un tiempo en milisegundos, mayor que 0.')),
        );
      }
      return;
    }
    await s.pruebaAFondo(ms);
  }

  @override
  Widget build(BuildContext context) {
    final r = s.ultimoResumen;
    final conectado = s.isConnected;
    final corriendo = s.estadoVal == 1;
    return Card(
      elevation: 3,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.speed, size: 20, color: Colors.lightBlueAccent),
                const SizedBox(width: 8),
                const Expanded(
                  child: Text('Última corrida (medida en el robot)',
                      style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold, color: Colors.lightBlueAccent)),
                ),
                SizedBox(
                  width: 32,
                  height: 32,
                  child: IconButton(
                    padding: EdgeInsets.zero,
                    tooltip: 'Pedir el resumen otra vez',
                    icon: const Icon(Icons.refresh, size: 20),
                    onPressed: conectado ? () => s.pedirResumen() : null,
                  ),
                ),
              ],
            ),
            const Divider(height: 12),
            if (r == null)
              const Text(
                'Todavía no hay corridas medidas. Largá el robot y, al pararlo, acá aparece cuánto le pidió a las '
                'ruedas, cuánto les llegó de verdad y qué término del PID le sacó velocidad. Lo mide el robot en '
                'cada ciclo del lazo, no con las muestras de 20 Hz.',
                style: TextStyle(fontSize: 12, color: Colors.white70),
              ),
            if (r != null) ...[
              Text(
                '${_nombreModo(r.modo)} · ${(r.ms / 1000.0).toStringAsFixed(2)} s · lazo ${r.hz} Hz (${r.ciclos} ciclos)',
                style: const TextStyle(fontSize: 12, color: Colors.white70),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  _dato('Pedida', _f1(r.vo)),
                  _dato('Real (media)', '${_f1(r.velMedia)} (${(100 * r.velMedia / 255).toStringAsFixed(0)} %)'),
                  _dato('Izq / Der', '${_f1(r.vi)} / ${_f1(r.vd)}'),
                ],
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  _dato('Rueda en 0', '${_f1(r.rc)} %'),
                  _dato('Aporte P', _f1(r.ap)),
                  _dato('Aporte I', _f1(r.ai)),
                  _dato('Aporte D', _f1(r.ad)),
                ],
              ),
              const SizedBox(height: 4),
              const Text(
                'Aportes = promedio de |Kp × error|, |Ki × integral| y |Kd × cambio del error|, en PWM (0 a 255).',
                style: TextStyle(fontSize: 10, color: Colors.white54),
              ),
              const SizedBox(height: 8),
              for (final c in _conclusiones(r))
                Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: Text('• $c', style: const TextStyle(fontSize: 12)),
                ),
            ],
            if (conBotonPrueba) ...[
              const SizedBox(height: 8),
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  icon: const Icon(Icons.bolt, size: 18),
                  label: const Text('Prueba a fondo (255 sin PID)'),
                  onPressed: (conectado && !corriendo) ? () => _pruebaAFondo(context) : null,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
