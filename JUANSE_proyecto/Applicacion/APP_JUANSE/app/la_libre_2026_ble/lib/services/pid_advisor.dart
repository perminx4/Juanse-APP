// ============================================================================
// ASESOR DE PID
// Mira cómo se comportó el error durante una corrida y RECOMIENDA qué parámetros
// tocar. No cambia nada por sí solo: cada recomendación tiene un botón "Aplicar"
// que decide el usuario.
//
// Es código Dart puro (sin Flutter) para poder probarlo aparte.
//
// Qué mide en cada tramo (rectas y curvas por separado):
//   - error RMS y error medio (cuánto se aleja de la línea)
//   - oscilación: cuántas veces por segundo cruza la línea (en Hz)
//   - sesgo: si el error promedio queda corrido hacia un lado
//   - saturación: porcentaje del tiempo que una rueda está en 0
// Son reglas de sentido común, no un modelo exacto: sirven para decidir hacia
// dónde mover un parámetro, de a poco.
// ============================================================================
import 'dart:math' as math;

/// Una muestra de telemetría durante una corrida (llega cada ~50 ms).
class MuestraCorrida {
  final int ms; // milisegundos desde que arrancó la corrida
  final int err; // error con signo
  final int l; // PWM rueda izquierda
  final int r; // PWM rueda derecha
  final int md; // 0 normal, 1 grabando, 2 carrera con mapa
  final int tr; // 0 recta, 1 curva (detectada por los sensores)
  const MuestraCorrida(this.ms, this.err, this.l, this.r, this.md, this.tr);
}

/// Valores de los parámetros con los que se hizo la corrida.
class ParamsCorrida {
  final double kp, ki, kd;
  final int vm;
  final double rkp, rki, rkd;
  final int rvm;
  final double ckp, cki, ckd;
  final int cvm;
  final double fcur;
  final int umb;
  const ParamsCorrida({
    this.kp = 3,
    this.ki = 0,
    this.kd = 35,
    this.vm = 255,
    this.rkp = 3,
    this.rki = 0,
    this.rkd = 35,
    this.rvm = 255,
    this.ckp = 3,
    this.cki = 0,
    this.ckd = 35,
    this.cvm = 150,
    this.fcur = 1.0,
    this.umb = 80,
  });
}

/// Una recomendación: cambiar el parámetro [cmd] de [actual] a [sugerido].
class Sugerencia {
  final String cmd; // comando del firmware (kp, kd, vm, fcur, rkp, ckp, ...)
  final String etiqueta; // nombre para mostrar
  final double actual;
  final double sugerido;
  final int decimales;
  final String motivo;
  const Sugerencia(this.cmd, this.etiqueta, this.actual, this.sugerido, this.decimales, this.motivo);

  String get actualTexto => actual.toStringAsFixed(decimales);
  String get sugeridoTexto => sugerido.toStringAsFixed(decimales);
}

/// Números de un grupo de muestras (por ejemplo "Normal · rectas").
class EstadisticasGrupo {
  final String nombre;
  final int muestras;
  final double segundos;
  final double rms; // error cuadrático medio
  final double mediaAbs; // error absoluto medio
  final double sesgo; // error medio con signo
  final double p95; // el 95% del tiempo el error absoluto está por debajo de esto
  final double oscHz; // cruces de la línea por segundo / 2
  final double satCero; // fracción del tiempo con una rueda en 0
  const EstadisticasGrupo(this.nombre, this.muestras, this.segundos, this.rms, this.mediaAbs, this.sesgo, this.p95,
      this.oscHz, this.satCero);
}

class InformeAsesor {
  final DateTime hora;
  final double duracionS;
  final ParamsCorrida params;
  final List<EstadisticasGrupo> grupos; // solo los que tuvieron muestras
  final List<Sugerencia> sugerencias;
  final List<String> notas;
  const InformeAsesor(this.hora, this.duracionS, this.params, this.grupos, this.sugerencias, this.notas);

  /// Grupo de rectas con más datos (para comparar corridas entre sí)
  EstadisticasGrupo? get rectas {
    EstadisticasGrupo? mejor;
    for (final g in grupos) {
      if (g.nombre.contains('rectas') && (mejor == null || g.muestras > mejor.muestras)) mejor = g;
    }
    return mejor;
  }
}

// Grupos de muestras
const int gNormalRecta = 0;
const int gNormalCurva = 1;
const int gRecta = 2;
const int gCurva = 3;
const List<String> nombresGrupo = ['Normal · rectas', 'Normal · curvas', 'Mapa · rectas', 'Mapa · curvas'];

// Umbrales de las reglas (todos juntos para poder ajustarlos)
const double _minSegRecta = 1.5; // menos que esto en rectas: pocos datos
const double _minSegCurva = 0.8;
const double _oscMinHz = 1.5; // por debajo no se considera oscilación
const double _oscRapidaHz = 4.5; // por encima es vibración rápida (ruido de Kd)
const double _satRecta = 0.10; // rueda en 0 más del 10% del tiempo en recta
const double _satCurva = 0.35;
const double _transitorioInicioMs = 500; // se ignora el arranque
const double _transitorioFinMs = 300; // y el final

int _grupoDe(MuestraCorrida m) {
  if (m.md == 0) return m.tr == 1 ? gNormalCurva : gNormalRecta;
  if (m.md == 1) return gCurva; // al grabar se usa el perfil de curva
  return m.tr == 1 ? gCurva : gRecta;
}

bool _esRecta(int g) => g == gNormalRecta || g == gRecta;

class _Acum {
  int n = 0;
  double t = 0;
  double sumE = 0;
  double sumE2 = 0;
  double sumAbs = 0;
  int sat = 0;
  int cruces = 0;
  final List<double> abs = [];
}

class _Perfil {
  final String kpCmd, kdCmd, velCmd, nombre;
  final double kp, kd;
  final int vel;
  const _Perfil(this.kpCmd, this.kdCmd, this.velCmd, this.nombre, this.kp, this.kd, this.vel);
}

_Perfil _perfilDe(int g, ParamsCorrida p) {
  switch (g) {
    case gNormalRecta:
    case gNormalCurva:
      return _Perfil('kp', 'kd', 'vm', 'Normal', p.kp, p.kd, p.vm);
    case gRecta:
      return _Perfil('rkp', 'rkd', 'rvm', 'Recta', p.rkp, p.rkd, p.rvm);
    default:
      return _Perfil('ckp', 'ckd', 'cvm', 'Curva', p.ckp, p.ckd, p.cvm);
  }
}

/// Multiplica [actual] por [factor] redondeando a [dec] decimales. Si el redondeo no lo mueve, lo mueve
/// un paso. Devuelve null si no hay forma de cambiarlo (por los límites).
double? _ajustar(double actual, double factor, {int dec = 1, double min = 0.1, double max = 100}) {
  final escala = math.pow(10, dec).toDouble();
  final a = (actual * escala).round() / escala;
  var v = (actual * factor * escala).round() / escala;
  if (v == a) v = a + (factor > 1 ? 1 : -1) / escala;
  v = v.clamp(min, max).toDouble();
  v = (v * escala).round() / escala;
  if (v == a) return null;
  return v;
}

int? _ajustarEntero(int actual, double factor, {int paso = 5, int min = 0, int max = 255}) {
  var v = (actual * factor / paso).round() * paso;
  if (v == actual) v = actual + (factor > 1 ? paso : -paso);
  if (v < min) v = min;
  if (v > max) v = max;
  if (v == actual) return null;
  return v;
}

class _Constructor {
  final List<Sugerencia> lista = [];
  final List<String> notas = [];

  /// Agrega una recomendación. Si ya hay otra para el mismo parámetro, se queda la primera (las rectas
  /// se evalúan antes: es lo más prudente) y, si piden cosas opuestas, lo avisa.
  void agregar(Sugerencia s) {
    for (final x in lista) {
      if (x.cmd == s.cmd) {
        if ((x.sugerido - x.actual) * (s.sugerido - s.actual) < 0) {
          notas.add('Las curvas pedirían ${s.etiqueta} ${s.sugeridoTexto}, pero las rectas piden lo contrario. '
              'El modo Normal usa un solo PID para todo; con el modo Mapa podés usar uno para rectas y otro para curvas.');
        }
        return;
      }
    }
    lista.add(s);
  }
}

String _pct(double f) => '${(f * 100).round()}%';

/// Analiza una corrida y arma el informe con las recomendaciones.
InformeAsesor analizarCorrida(List<MuestraCorrida> crudas, ParamsCorrida p, {DateTime? hora}) {
  final ahora = hora ?? DateTime.now();
  if (crudas.length < 2) {
    return InformeAsesor(ahora, 0, p, const [], const [], const ['La corrida fue demasiado corta para analizarla.']);
  }
  final duracionS = (crudas.last.ms - crudas.first.ms) / 1000.0;
  final ultimoMs = crudas.last.ms;
  final datos = crudas.where((m) => m.ms >= _transitorioInicioMs && m.ms <= ultimoMs - _transitorioFinMs).toList();

  // Umbrales de amplitud: por debajo de esto el error es "ruido" y no cuenta como cruce de la línea
  final umb = p.umb <= 0 ? 80 : p.umb;
  final a0 = math.max(3.0, 0.06 * umb); // rectas
  final a1 = math.max(8.0, 0.20 * umb); // curvas

  final acum = List<_Acum>.generate(4, (_) => _Acum());
  MuestraCorrida? prev;
  int grupoPrev = -1;
  int lado = 0;
  for (final m in datos) {
    final g = _grupoDe(m);
    final continua = prev != null && grupoPrev == g && (m.ms - prev.ms) <= 150;
    final a = acum[g];
    if (continua) {
      a.t += (m.ms - prev.ms) / 1000.0;
    } else {
      lado = 0;
    }
    final e = m.err.toDouble();
    a.n++;
    a.sumE += e;
    a.sumE2 += e * e;
    a.sumAbs += e.abs();
    a.abs.add(e.abs());
    if (m.l <= 0 || m.r <= 0) a.sat++;
    final amp = _esRecta(g) ? a0 : a1;
    if (e.abs() > amp) {
      final s = e > 0 ? 1 : -1;
      if (lado != 0 && s != lado) a.cruces++;
      lado = s;
    }
    prev = m;
    grupoPrev = g;
  }

  final stats = List<EstadisticasGrupo?>.filled(4, null);
  for (int g = 0; g < 4; g++) {
    final a = acum[g];
    if (a.n == 0) continue;
    a.abs.sort();
    final p95 = a.abs[math.min(a.abs.length - 1, (a.abs.length * 0.95).floor())];
    stats[g] = EstadisticasGrupo(
      nombresGrupo[g],
      a.n,
      a.t,
      math.sqrt(a.sumE2 / a.n),
      a.sumAbs / a.n,
      a.sumE / a.n,
      p95,
      a.t > 0.3 ? a.cruces / (2 * a.t) : 0,
      a.sat / a.n,
    );
  }

  final c = _Constructor();
  final notas = c.notas;
  bool hayProblema = false;
  bool hayDatosBuenos = false;

  // Primero las rectas y después las curvas (las rectas mandan si hay conflicto)
  for (final g in const [gNormalRecta, gRecta, gNormalCurva, gCurva]) {
    final st = stats[g];
    if (st == null) continue;
    final pf = _perfilDe(g, p);
    final recta = _esRecta(g);

    if (st.segundos < (recta ? _minSegRecta : _minSegCurva)) {
      notas.add('Pocos datos en ${st.nombre} (${st.segundos.toStringAsFixed(1)} s): para recomendar algo hace falta '
          'una vuelta completa.');
      continue;
    }
    hayDatosBuenos = true;

    if (recta) {
      bool problema = false;
      // 1) Oscilación en las rectas
      if (st.oscHz >= _oscMinHz && st.rms > 1.2 * a0) {
        problema = true;
        if (st.oscHz < _oscRapidaHz) {
          final v = _ajustar(pf.kp, 0.85, dec: 1, min: 0.1, max: 20);
          if (v != null) {
            c.agregar(Sugerencia(
                pf.kpCmd,
                'Kp (${pf.nombre})',
                pf.kp,
                v,
                1,
                'En ${st.nombre} el robot oscila a ~${st.oscHz.toStringAsFixed(1)} veces por segundo '
                '(error RMS ${st.rms.toStringAsFixed(0)}). Suele ser Kp alto para el Kd: bajá Kp un poco. '
                'Si después se vuelve lento para corregir, en vez de bajar Kp probá subir Kd.'));
          }
        } else {
          final v = _ajustar(pf.kd, 0.8, dec: 1, min: 0, max: 100);
          if (v != null) {
            c.agregar(Sugerencia(
                pf.kdCmd,
                'Kd (${pf.nombre})',
                pf.kd,
                v,
                1,
                'En ${st.nombre} el robot vibra rápido (~${st.oscHz.toStringAsFixed(1)} veces por segundo). '
                'Suele ser un Kd demasiado alto, que amplifica el ruido de los sensores: bajalo un poco.'));
          }
        }
      }
      // 2) Rueda frenada en las rectas
      if (st.satCero > _satRecta) {
        problema = true;
        final v = _ajustar(pf.kp, 0.8, dec: 1, min: 0.1, max: 20);
        if (v != null) {
          c.agregar(Sugerencia(
              pf.kpCmd,
              'Kp (${pf.nombre})',
              pf.kp,
              v,
              1,
              'En ${st.nombre} una rueda llega a 0 el ${_pct(st.satCero)} del tiempo: la corrección es '
              'demasiado fuerte. Bajá Kp.'));
        }
      }
      // 3) Sesgo (anda corrido hacia un lado)
      if (st.rms > a0 && st.sesgo.abs() > math.max(1.5 * a0, 0.6 * st.rms)) {
        problema = true;
        notas.add('En ${st.nombre} el error medio es ${st.sesgo.toStringAsFixed(0)}: el robot anda corrido hacia un '
            'lado. Recalibrá sobre la pista y revisá que los motores y las ruedas estén parejos. No te recomiendo '
            'subir Ki: en este código el término integral se llena en ~1 segundo y puede desestabilizar todo.');
      }
      if (problema) hayProblema = true;
    } else {
      bool problema = false;
      final normal = g == gNormalCurva;
      // 1) Entra demasiado rápido: una rueda se frena casi del todo
      if (st.satCero > _satCurva) {
        problema = true;
        if (normal) {
          if (p.fcur >= 0.99) {
            c.agregar(Sugerencia('fcur', 'Freno en curvas', p.fcur, 0.8, 2,
                'En las curvas una rueda llega a 0 el ${_pct(st.satCero)} del tiempo: entra demasiado rápido. '
                'Activá el freno en curvas (0.80 = en curva va al 80% de la velocidad).'));
          } else {
            final v = _ajustar(p.fcur, 0.9, dec: 2, min: 0.3, max: 1.0);
            if (v != null) {
              c.agregar(Sugerencia('fcur', 'Freno en curvas', p.fcur, v, 2,
                  'Aun con freno, una rueda llega a 0 el ${_pct(st.satCero)} del tiempo en curva. Frená un poco más.'));
            }
          }
        } else {
          final v = _ajustarEntero(pf.vel, 0.9);
          if (v != null) {
            c.agregar(Sugerencia(pf.velCmd, 'Velocidad (${pf.nombre})', pf.vel.toDouble(), v.toDouble(), 0,
                'En ${st.nombre} una rueda llega a 0 el ${_pct(st.satCero)} del tiempo: entra demasiado rápido. '
                'Bajá la velocidad de curva.'));
          }
        }
      }
      // 2) Oscilación dentro de la curva
      final oscila = st.oscHz >= _oscMinHz && st.rms > a1;
      if (oscila) {
        problema = true;
        final v = _ajustar(pf.kp, 0.85, dec: 1, min: 0.1, max: 20);
        if (v != null) {
          c.agregar(Sugerencia(pf.kpCmd, 'Kp (${pf.nombre})', pf.kp, v, 1,
              'En ${st.nombre} el robot zigzaguea (~${st.oscHz.toStringAsFixed(1)} veces por segundo) mientras '
              'toma la curva. Bajá un poco Kp.'));
        }
      }
      // 3) Se abre en las curvas (confianza baja)
      if (!oscila && st.satCero < 0.20 && st.mediaAbs > 2.2 * umb) {
        problema = true;
        final v = _ajustar(pf.kp, 1.2, dec: 1, min: 0.1, max: 20);
        if (v != null) {
          c.agregar(Sugerencia(pf.kpCmd, 'Kp (${pf.nombre})', pf.kp, v, 1,
              'En ${st.nombre} el error se mantiene alto (~${st.mediaAbs.toStringAsFixed(0)}): al robot le falta '
              'fuerza para seguir la curva. Probá un poco más de Kp. (Confianza baja: también puede ser exceso '
              'de velocidad.)'));
        }
      }
      if (problema) hayProblema = true;
    }
  }

  // Todo bien y sin nada que corregir: se puede probar más velocidad
  if (hayDatosBuenos && !hayProblema && c.lista.isEmpty) {
    final candidatos = <int>[gNormalRecta, gRecta];
    for (final g in candidatos) {
      if (stats[g] == null || stats[g]!.segundos < _minSegRecta) continue;
      final pf = _perfilDe(g, p);
      final v = _ajustarEntero(pf.vel, 1.08);
      if (v != null && v > pf.vel) {
        c.agregar(Sugerencia(pf.velCmd, 'Velocidad (${pf.nombre})', pf.vel.toDouble(), v.toDouble(), 0,
            'Las rectas se ven estables (error RMS ${stats[g]!.rms.toStringAsFixed(0)}, sin oscilación). Podés '
            'probar un poco más de velocidad y volver a correr.'));
      }
    }
    if (c.lista.isEmpty) notas.add('Todo se ve estable. No encuentro nada para mejorar con esta corrida.');
  }

  if (!hayDatosBuenos && notas.isEmpty) {
    notas.add('No hay datos suficientes en esta corrida.');
  }

  return InformeAsesor(
    ahora,
    duracionS,
    p,
    [for (final s in stats) if (s != null) s],
    c.lista,
    notas,
  );
}
