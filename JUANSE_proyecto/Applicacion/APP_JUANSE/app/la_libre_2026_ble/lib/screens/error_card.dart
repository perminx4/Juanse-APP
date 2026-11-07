import 'package:flutter/material.dart';
import '../services/bluetooth_service.dart';

/// Tarjeta "Error": muestra TODO EL TIEMPO el error que usa el PID (el robot lo manda 20 veces por segundo,
/// quieto o corriendo), la suma sin dividir y el divisor (que se cambia desde acá: "div:x").
/// Además muestra el error más alto y el más bajo de la última corrida (los mide el robot en CADA ciclo,
/// de Start a Stop) y calcula qué divisor deja el error máximo en 255: es una cuenta, divisor = suma ÷ 255.
class ErrorCard extends StatelessWidget {
  final BluetoothService s;
  const ErrorCard({super.key, required this.s});

  static const double objetivo = 255;

  /// Número tal cual (sin el ".0" de los enteros)
  static String txtNum(double v) {
    if (!v.isFinite) return '—';
    final t = v.toString();
    return t.endsWith('.0') ? t.substring(0, t.length - 2) : t;
  }

  /// Número con 6 cifras significativas, sin ceros de más (para el divisor sugerido)
  static String txt6(double v) {
    var t = v.toStringAsPrecision(6);
    if (t.contains('.') && !t.contains('e')) {
      t = t.replaceFirst(RegExp(r'0+$'), '');
      if (t.endsWith('.')) t = t.substring(0, t.length - 1);
    }
    return t;
  }

  static String _txtInt(int? v) => v == null ? '—' : v.toString();

  void _aviso(BuildContext context, String texto) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(texto), duration: const Duration(seconds: 3)));
  }

  Future<void> _mandarDivisor(BuildContext context, String texto) async {
    final ok = await s.setDivisorError(texto);
    if (!context.mounted) return;
    if (ok) {
      _aviso(context, 'Enviado div:${texto.trim().replaceAll(',', '.')}. Para que quede al apagar el robot, tocá Guardar.');
    } else {
      _aviso(context, 'Poné un número distinto de 0 (podés usar decimales).');
    }
  }

  Future<void> _editarDivisor(BuildContext context) async {
    final controller = TextEditingController(text: txtNum(s.divisorError));
    final txt = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Divisor del error'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'error = suma de los sensores ÷ divisor. Tu código original usa 48. Más grande = error más chico. '
              'Se manda tal cual lo escribís (decimales y negativos también; el 0 no).',
              style: TextStyle(fontSize: 13),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: controller,
              autofocus: true,
              keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true),
              decoration: const InputDecoration(labelText: 'Divisor'),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancelar')),
          FilledButton(onPressed: () => Navigator.pop(ctx, controller.text), child: const Text('Mandar')),
        ],
      ),
    );
    if (txt == null || !context.mounted) return;
    await _mandarDivisor(context, txt);
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

  /// Barra de -255 a +255 con una marca donde está el error ahora (si se pasa, queda pegada al borde en rojo)
  Widget _barra(int error) {
    final pasado = error.abs() > objetivo;
    final x = (error / objetivo).clamp(-1.0, 1.0).toDouble();
    return Column(
      children: [
        SizedBox(
          height: 14,
          child: Stack(
            children: [
              Positioned.fill(
                child: Container(
                  decoration: BoxDecoration(
                    color: Colors.white10,
                    borderRadius: BorderRadius.circular(7),
                    border: Border.all(color: Colors.white24),
                  ),
                ),
              ),
              const Align(
                alignment: Alignment.center,
                child: SizedBox(width: 1, height: 14, child: ColoredBox(color: Colors.white38)),
              ),
              Align(
                alignment: Alignment(x, 0),
                child: Container(
                  width: 10,
                  height: 14,
                  decoration: BoxDecoration(
                    color: pasado ? Colors.redAccent : Colors.amberAccent,
                    borderRadius: BorderRadius.circular(5),
                  ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 2),
        const Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text('-255', style: TextStyle(fontSize: 10, color: Colors.white54)),
            Text('0', style: TextStyle(fontSize: 10, color: Colors.white54)),
            Text('+255', style: TextStyle(fontSize: 10, color: Colors.white54)),
          ],
        ),
      ],
    );
  }

  /// Qué divisor deja el error máximo en 255, con la suma sin dividir más grande (en valor absoluto)
  List<Widget> _sugerencia(BuildContext context, int? sumaMaxAbs) {
    if (sumaMaxAbs == null || sumaMaxAbs <= 0) return const [];
    final sugerido = sumaMaxAbs / objetivo;
    final txt = txt6(sugerido);
    final actual = s.divisorError;
    final factor = sugerido / actual; // para comportarse igual: Kp, Ki y Kd x factor
    final kp = double.tryParse(s.kp);
    final kd = double.tryParse(s.kd);
    var reescala = 'Ojo: con ese divisor el error queda ${txt6(actual / sugerido)} veces lo que es ahora. '
        'Para que el robot se comporte igual que ahora, Kp, Ki y Kd van multiplicados por ${txt6(factor)}';
    if (kp != null && kd != null) {
      reescala += ' (Kp ${txtNum(kp)} → ${txt6(kp * factor)}, Kd ${txtNum(kd)} → ${txt6(kd * factor)})';
    }
    reescala += ', y el umbral de curva (umb) por ${txt6(actual / sugerido)}.';
    return [
      const SizedBox(height: 6),
      Row(
        children: [
          Expanded(
            child: Text(
              'Para que el error máximo sea 255: divisor ≈ $txt  (= $sumaMaxAbs ÷ 255)',
              style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Colors.amberAccent),
            ),
          ),
          const SizedBox(width: 6),
          OutlinedButton(
            style: OutlinedButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4)),
            onPressed: s.isConnected ? () => _mandarDivisor(context, txt) : null,
            child: Text('Usar $txt', style: const TextStyle(fontSize: 12)),
          ),
        ],
      ),
      if ((factor - 1).abs() > 0.0005)
        Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Text(reescala, style: const TextStyle(fontSize: 11, color: Colors.white54)),
        ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final e = s.ultimoErrores;
    final conectado = s.isConnected;
    final int? vivoSumaAbs = (s.sumVivoMax == null || s.sumVivoMin == null)
        ? null
        : (s.sumVivoMax!.abs() > s.sumVivoMin!.abs() ? s.sumVivoMax!.abs() : s.sumVivoMin!.abs());
    final divDistinto = e != null && (e.dv - s.divisorError).abs() > 1e-9 * s.divisorError.abs();

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
                const Icon(Icons.straighten, size: 20, color: Colors.amberAccent),
                const SizedBox(width: 8),
                const Expanded(
                  child: Text('Error (lo que usa el PID)',
                      style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold, color: Colors.amberAccent)),
                ),
                ActionChip(
                  avatar: const Icon(Icons.edit, size: 14),
                  label: Text('÷ ${txtNum(s.divisorError)}', style: const TextStyle(fontSize: 12)),
                  tooltip: 'Cambiar el divisor',
                  onPressed: conectado ? () => _editarDivisor(context) : null,
                ),
              ],
            ),
            const Divider(height: 12),
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Expanded(
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    alignment: Alignment.centerLeft,
                    child: Text(
                      conectado ? '${s.posVal}' : '—',
                      style: const TextStyle(fontSize: 34, fontWeight: FontWeight.bold),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    const Text('suma sin dividir', style: TextStyle(fontSize: 11, color: Colors.white70)),
                    Text(
                      conectado && s.haySumaError ? '${s.sumaError}' : '—',
                      style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold),
                    ),
                  ],
                ),
              ],
            ),
            const SizedBox(height: 6),
            _barra(s.posVal),
            const SizedBox(height: 4),
            Text(
              'error = suma ÷ ${txtNum(s.divisorError)}, sin decimales (el robot lo usa entero). '
              'Llega 20 veces por segundo, quieto o corriendo.'
              '${conectado && !s.haySumaError ? ' Tu robot no manda la suma: cargale el firmware nuevo.' : ''}',
              style: const TextStyle(fontSize: 11, color: Colors.white54),
            ),

            // ---- Última corrida (de Start a Stop), medida por el robot en cada ciclo ----
            const SizedBox(height: 10),
            Row(
              children: [
                const Expanded(
                  child: Text('Última corrida (Start → Stop, cada ciclo del robot)',
                      style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold)),
                ),
                SizedBox(
                  width: 32,
                  height: 32,
                  child: IconButton(
                    padding: EdgeInsets.zero,
                    tooltip: 'Pedirlo otra vez',
                    icon: const Icon(Icons.refresh, size: 18),
                    onPressed: conectado ? () => s.pedirResumen() : null,
                  ),
                ),
              ],
            ),
            if (e == null)
              const Text(
                'Todavía no hay corrida. Dale Start y después Stop: acá aparece el error más alto y el más bajo '
                'que tuvo, medidos en cada ciclo del lazo (no solo en las muestras de la telemetría).',
                style: TextStyle(fontSize: 12, color: Colors.white70),
              ),
            if (e != null) ...[
              const SizedBox(height: 4),
              Row(
                children: [
                  _dato('Más alto', '${e.emx}'),
                  _dato('Más bajo', '${e.emn}'),
                  _dato('Máx. |error|', '${e.errorMaxAbs}'),
                ],
              ),
              const SizedBox(height: 6),
              Row(
                children: [
                  _dato('Suma más alta', '${e.smx}'),
                  _dato('Suma más baja', '${e.smn}'),
                  _dato('Con divisor', txtNum(e.dv)),
                ],
              ),
              if (divDistinto)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    'Esa corrida se largó con divisor ${txtNum(e.dv)}; ahora está en ${txtNum(s.divisorError)}. '
                    'La suma sin dividir no depende del divisor.',
                    style: const TextStyle(fontSize: 11, color: Colors.white54),
                  ),
                ),
              ..._sugerencia(context, e.sumaMaxAbs),
            ],

            // ---- En vivo, desde que tocaste Reiniciar ----
            const SizedBox(height: 10),
            Row(
              children: [
                const Expanded(
                  child: Text('En vivo (desde Reiniciar)', style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold)),
                ),
                TextButton.icon(
                  icon: const Icon(Icons.restart_alt, size: 16),
                  label: const Text('Reiniciar', style: TextStyle(fontSize: 12)),
                  onPressed: s.reiniciarErrorVivo,
                ),
              ],
            ),
            Row(
              children: [
                _dato('Más alto', _txtInt(s.errVivoMax)),
                _dato('Más bajo', _txtInt(s.errVivoMin)),
                _dato('Suma máx.', _txtInt(s.sumVivoMax)),
                _dato('Suma mín.', _txtInt(s.sumVivoMin)),
              ],
            ),
            ..._sugerencia(context, vivoSumaAbs),
            const SizedBox(height: 4),
            const Text(
              'Para medirlo a mano: con el robot quieto, tocá Reiniciar y pasá la línea despacio por debajo de los '
              '12 sensores, de punta a punta. Son muestras de 20 por segundo: si la pasás rápido se puede perder el '
              'pico (lo de "Última corrida" no se pierde nada).',
              style: TextStyle(fontSize: 11, color: Colors.white54),
            ),
          ],
        ),
      ),
    );
  }
}
