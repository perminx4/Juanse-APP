// ============================================================================
// ASESOR DE PID (versión 2)
// Mira cómo se comportó el robot durante una corrida y RECOMIENDA qué parámetros
// tocar. No cambia nada por sí solo: cada recomendación tiene un botón "Aplicar".
//
// Es código Dart puro (sin Flutter) para poder probarlo aparte.
//
// Qué hace:
//  1. MIDE cada tramo (rectas y curvas por separado): error, oscilación (y qué tan
//     periódica es), rueda frenada, corrimiento hacia un lado.
//  2. MIDE cómo se estabiliza el robot al salir de cada curva: cuánto se pasa para
//     el otro lado y cuánto tarda en calmarse (respuesta al escalón).
//  3. APRENDE de tus corridas: compara con la corrida anterior, detecta qué
//     parámetros cambiaste y si el resultado mejoró o empeoró. Si empeoró propone
//     volver atrás; si mejoró propone seguir un paso más (como el método Twiddle).
//  4. Puntúa cada corrida de 0 a 100 para que puedas comparar rápido.
//  5. Cada recomendación trae un nivel de confianza; la más confiable va primero.
//
// Son reglas de ingeniería de control + comparación entre corridas, no un modelo
// de IA entrenado: sirven para decidir hacia dónde mover un parámetro, de a poco.
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
  final double mkp, mki, mkd; // PID medio (modo Sectores)
  final double frap, fmed, flen; // factor de VM de cada PID (modo Sectores)
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
    this.mkp = 3,
    this.mki = 0,
    this.mkd = 35,
    this.frap = 1.0,
    this.fmed = 0.8,
    this.flen = 0.5,
  });
}

/// Número para mostrar y mandar: entero si [dec] es 0; si no, hasta 8 decimales sin ceros de más (nada de redondear a 1 decimal).
String _fmtNum(double v, int dec) {
  if (dec == 0) return v.round().toString();
  var s = v.toStringAsFixed(8);
  if (s.contains('.') && !s.contains('e')) {
    s = s.replaceFirst(RegExp(r'0+$'), '');
    if (s.endsWith('.')) s = s.substring(0, s.length - 1);
  }
  return s;
}

/// Una recomendación: cambiar el parámetro [cmd] de [actual] a [sugerido].
class Sugerencia {
  final String cmd; // comando del firmware (kp, ki, kd, vm, fcur, rkp, ckp, ...)
  final String etiqueta; // nombre para mostrar
  final double actual;
  final double sugerido;
  final int decimales;
  final String motivo;
  final double confianza; // 0 a 1
  final String origen; // 'regla', 'revertir' o 'aprendizaje'
  const Sugerencia(this.cmd, this.etiqueta, this.actual, this.sugerido, this.decimales, this.motivo,
      {this.confianza = 0.5, this.origen = 'regla'});

  String get actualTexto => _fmtNum(actual, decimales);
  String get sugeridoTexto => _fmtNum(sugerido, decimales);
  String get nivel => confianza >= 0.7 ? 'alta' : (confianza >= 0.45 ? 'media' : 'baja');
}

/// Un parámetro que cambió entre dos corridas.
class CambioParam {
  final String cmd;
  final String etiqueta;
  final double antes;
  final double despues;
  final int decimales;
  const CambioParam(this.cmd, this.etiqueta, this.antes, this.despues, this.decimales);
  String get texto => '$etiqueta ${_fmtNum(antes, decimales)} → ${_fmtNum(despues, decimales)}';
}

/// Resultado de comparar esta corrida con la anterior.
class Evaluacion {
  final List<CambioParam> cambios;
  final String veredicto; // mejoro, empeoro, igual, velocidad_ok, velocidad_mal, sin_cambios
  final double puntajeAntes;
  final double puntajeAhora;
  final String texto;
  const Evaluacion(this.cambios, this.veredicto, this.puntajeAntes, this.puntajeAhora, this.texto);
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
  final double periodicidad; // 0 a 1: qué tan regular es la oscilación (1 = senoide perfecta)
  final int muestrasEstables; // muestras de régimen estable (más de 1 s después de entrar al tramo)
  final double sesgoEstable; // error medio con signo en régimen estable
  final double rmsEstable; // error RMS en régimen estable
  const EstadisticasGrupo(this.nombre, this.muestras, this.segundos, this.rms, this.mediaAbs, this.sesgo, this.p95,
      this.oscHz, this.satCero, this.periodicidad, this.muestrasEstables, this.sesgoEstable, this.rmsEstable);
}

class InformeAsesor {
  final DateTime hora;
  final double duracionS;
  final ParamsCorrida params;
  final String modo; // 'Normal' o 'Mapa'
  final List<EstadisticasGrupo> grupos; // solo los que tuvieron muestras
  final List<Sugerencia> sugerencias; // la primera es la más confiable
  final List<String> notas;
  final String diagnostico;
  final double costo; // cuanto más bajo, mejor
  final int puntaje; // 0 a 100
  final double velocidadMedia; // PWM promedio de las dos ruedas
  final Evaluacion? evaluacion; // comparación con la corrida anterior
  final int salidaEventos; // cantidad de salidas de curva medidas
  final double salidaSobrepaso; // cuánto se pasa al otro lado (fracción del error de la curva)
  final double salidaAsentamientoS; // segundos hasta calmarse
  const InformeAsesor(
    this.hora,
    this.duracionS,
    this.params,
    this.modo,
    this.grupos,
    this.sugerencias,
    this.notas,
    this.diagnostico,
    this.costo,
    this.puntaje,
    this.velocidadMedia,
    this.evaluacion,
    this.salidaEventos,
    this.salidaSobrepaso,
    this.salidaAsentamientoS,
  );

  /// Grupo de rectas con más datos (para comparar corridas entre sí)
  EstadisticasGrupo? get rectas {
    EstadisticasGrupo? mejor;
    for (final g in grupos) {
      if ((g.nombre.contains('rectas') || g.nombre.contains('rápido')) && (mejor == null || g.muestras > mejor.muestras)) mejor = g;
    }
    return mejor;
  }
}

// Grupos de muestras
const int gNormalRecta = 0;
const int gNormalCurva = 1;
const int gRecta = 2;
const int gCurva = 3;
const int gRapido = 4; // modo Sectores
const int gMedio = 5;
const int gLento = 6;
const List<String> nombresGrupo = [
  'Normal · rectas',
  'Normal · curvas',
  'Mapa · rectas',
  'Mapa · curvas',
  'Sectores · rápido',
  'Sectores · medio',
  'Sectores · lento',
];

// Umbrales de las reglas (todos juntos para poder ajustarlos)
const double _minSegRecta = 1.5; // menos que esto en rectas: pocos datos
const double _minSegCurva = 0.8;
const double _oscMinHz = 1.5; // por debajo no se considera oscilación
const double _oscRapidaHz = 4.5; // por encima es vibración rápida (ruido de Kd)
const double _satRecta = 0.10; // rueda en 0 más del 10% del tiempo en recta
const double _satCurva = 0.35;
const double _transitorioInicioMs = 500; // se ignora el arranque
const double _transitorioFinMs = 300; // y el final
const double _cambioSignificativo = 0.12; // 12% de cambio en el costo = mejora/empeora de verdad
const double _kiMaxSeguro = 0.004; // Ki*10000 es lo máximo que puede aportar el integral (se satura en ±10000)
const double _kiIntegralMax = 10000; // clamp del integral en el firmware
const Set<String> _cmdsVelocidad = {'vm', 'rvm', 'cvm', 'fcur', 'frap', 'fmed', 'flen'};

int _grupoDe(MuestraCorrida m) {
  // En el modo Sectores 'tr' trae el tipo de sector: 0 rápido, 1 medio, 2 lento
  if (m.md == 3) return m.tr == 1 ? gMedio : (m.tr == 2 ? gLento : gRapido);
  if (m.md == 0) return m.tr == 1 ? gNormalCurva : gNormalRecta;
  if (m.md == 1) return gCurva; // al grabar se usa el perfil de curva
  return m.tr == 1 ? gCurva : gRecta;
}

bool _esRecta(int g) => g == gNormalRecta || g == gRecta || g == gRapido;

class _Acum {
  int n = 0;
  double t = 0;
  double sumE = 0;
  double sumE2 = 0;
  double sumAbs = 0;
  int sat = 0;
  int cruces = 0;
  int nEst = 0;
  double sumEst = 0;
  double sumEst2 = 0;
  final List<double> abs = [];
  final List<List<double>> tandas = []; // errores de cada tramo continuo (para la periodicidad)
  List<double> actual = [];
}

class _Perfil {
  final String kpCmd, kiCmd, kdCmd, velCmd, nombre;
  final double kp, ki, kd;
  final int vel;
  const _Perfil(this.kpCmd, this.kiCmd, this.kdCmd, this.velCmd, this.nombre, this.kp, this.ki, this.kd, this.vel);
}

_Perfil _perfilDe(int g, ParamsCorrida p) {
  switch (g) {
    case gNormalRecta:
    case gNormalCurva:
      return _Perfil('kp', 'ki', 'kd', 'vm', 'Normal', p.kp, p.ki, p.kd, p.vm);
    case gRecta:
      return _Perfil('rkp', 'rki', 'rkd', 'rvm', 'Recta', p.rkp, p.rki, p.rkd, p.rvm);
    case gRapido:
      return _Perfil('rkp', 'rki', 'rkd', 'vm', 'Rápido', p.rkp, p.rki, p.rkd, p.vm);
    case gMedio:
      return _Perfil('mkp', 'mki', 'mkd', 'vm', 'Medio', p.mkp, p.mki, p.mkd, p.vm);
    case gLento:
      return _Perfil('ckp', 'cki', 'ckd', 'vm', 'Lento', p.ckp, p.cki, p.ckd, p.vm);
    default:
      return _Perfil('ckp', 'cki', 'ckd', 'cvm', 'Curva', p.ckp, p.cki, p.ckd, p.cvm);
  }
}

/// Multiplica [actual] por [factor] redondeando a [dec] decimales. Si el redondeo no lo mueve, lo mueve
/// un paso. Devuelve null si no hay forma de cambiarlo (por los límites).
double? _ajustar(double actual, double factor, {int dec = 1, double min = 0, double max = 1e12}) {
  // Con valores chicos se usan más decimales (si no, 0.085 se redondearía a 0.1 y no cambiaría nada)
  final objetivo = (actual * factor).abs();
  while (dec < 6 && objetivo < 2 * math.pow(10, -dec)) {
    dec++;
  }
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

/// Confianza de una regla: cuánto se pasó del umbral ([evidencia], 1 = recién cruzado, 2 o más = muy
/// claro) y cuántos segundos de datos hay. Más datos y más evidencia = más confianza.
double _conf(double evidencia, double segundos, {double bono = 0, double tope = 0.9}) {
  final base = 0.3 + 0.3 * evidencia.clamp(0.0, 2.0);
  final datos = (segundos / 6.0).clamp(0.5, 1.0);
  return ((base + bono) * datos).clamp(0.2, tope).toDouble();
}

class _Constructor {
  final List<Sugerencia> lista = [];
  final List<String> notas = [];

  /// Agrega una recomendación. Si ya hay otra para el mismo parámetro, se queda la primera (los pedidos
  /// de revertir y las rectas se evalúan antes) y, si piden cosas opuestas, lo avisa.
  void agregar(Sugerencia s) {
    for (final x in lista) {
      if (x.cmd == s.cmd) {
        if (x.origen == 'regla' && s.origen == 'regla' && (x.sugerido - x.actual) * (s.sugerido - s.actual) < 0) {
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

double _mediana(List<double> v) {
  if (v.isEmpty) return 0;
  final s = List<double>.of(v)..sort();
  final m = s.length ~/ 2;
  return s.length.isOdd ? s[m] : (s[m - 1] + s[m]) / 2;
}

/// Qué tan regular es la oscilación (0 a 1), mirando la autocorrelación de cada tramo continuo.
double _periodicidad(List<List<double>> tandas) {
  double suma = 0;
  int pesos = 0;
  for (final t in tandas) {
    if (t.length < 24) continue; // menos de ~1.2 s
    final media = t.reduce((a, b) => a + b) / t.length;
    final e = [for (final x in t) x - media];
    double r0 = 0;
    for (final x in e) {
      r0 += x * x;
    }
    if (r0 <= 0) continue;
    final maxLag = math.min(20, e.length ~/ 2);
    final r = <double>[];
    for (int k = 1; k <= maxLag; k++) {
      double s = 0;
      for (int i = 0; i + k < e.length; i++) {
        s += e[i] * e[i + k];
      }
      r.add(s / r0);
    }
    // se busca el primer cruce por cero y, después, el pico más alto
    int k0 = -1;
    for (int k = 0; k < r.length; k++) {
      if (r[k] < 0) {
        k0 = k;
        break;
      }
    }
    if (k0 < 0) continue;
    double pico = 0;
    for (int k = k0; k < r.length; k++) {
      if (r[k] > pico) pico = r[k];
    }
    suma += pico * t.length;
    pesos += t.length;
  }
  return pesos == 0 ? 0 : (suma / pesos).clamp(0.0, 1.0).toDouble();
}

class _Salidas {
  int eventos = 0;
  double sobrepaso = 0; // fracción del error de la curva
  double asentamientoS = 0;
}

/// Mide cómo se estabiliza el robot cuando sale de una curva (respuesta al escalón).
_Salidas _analizarSalidas(List<MuestraCorrida> d, int mdObjetivo, double minErrCurva, double a0) {
  final ratios = <double>[];
  final asent = <double>[];
  for (int i = 1; i < d.length; i++) {
    final a = d[i - 1];
    final b = d[i];
    if (!(a.tr == 1 && b.tr == 0 && a.md == mdObjetivo && b.md == mdObjetivo && (b.ms - a.ms) <= 150)) continue;
    // error medio de los últimos ~0.3 s de la curva
    double suma = 0;
    int n = 0;
    for (int k = i - 1; k >= 0 && n < 6 && d[k].tr == 1 && d[k].md == mdObjetivo; k--) {
      suma += d[k].err;
      n++;
    }
    if (n < 3) continue;
    final sc = suma / n;
    if (sc.abs() < minErrCurva) continue;
    final signo = sc > 0 ? 1.0 : -1.0;
    // ventana posterior (hasta 0.8 s)
    double sobre = 0;
    int ok = 0;
    int calmas = 0;
    double? tAsent;
    int ultimoMs = a.ms;
    for (int j = i; j < d.length; j++) {
      final m = d[j];
      if (m.tr != 0 || m.md != mdObjetivo || m.ms - ultimoMs > 150 || m.ms - b.ms > 800) break;
      final e = m.err.toDouble();
      sobre = math.max(sobre, -signo * e);
      if (tAsent == null) {
        if (e.abs() < 1.5 * a0) {
          calmas++;
          if (calmas >= 3) tAsent = (m.ms - b.ms) / 1000.0;
        } else {
          calmas = 0;
        }
      }
      ultimoMs = m.ms;
      ok++;
    }
    if (ok < 8) continue;
    ratios.add(sobre / sc.abs());
    asent.add(tAsent ?? 0.8);
  }
  final s = _Salidas();
  s.eventos = ratios.length;
  if (ratios.length >= 2) {
    s.sobrepaso = _mediana(ratios);
    s.asentamientoS = _mediana(asent);
  } else {
    s.eventos = 0;
  }
  return s;
}

/// Lista de parámetros que cambiaron entre dos corridas (solo los del modo que se usó).
List<CambioParam> cambiosEntre(ParamsCorrida a, ParamsCorrida b, String modo) {
  final out = <CambioParam>[];
  void ver(String cmd, String etiqueta, double antes, double despues, int dec, double tol) {
    if ((antes - despues).abs() > tol) out.add(CambioParam(cmd, etiqueta, antes, despues, dec));
  }

  if (modo == 'Sectores') {
    ver('rkp', 'Kp (Rápido)', a.rkp, b.rkp, 1, 0.05);
    ver('rki', 'Ki (Rápido)', a.rki, b.rki, 4, 0.00005);
    ver('rkd', 'Kd (Rápido)', a.rkd, b.rkd, 1, 0.05);
    ver('mkp', 'Kp (Medio)', a.mkp, b.mkp, 1, 0.05);
    ver('mki', 'Ki (Medio)', a.mki, b.mki, 4, 0.00005);
    ver('mkd', 'Kd (Medio)', a.mkd, b.mkd, 1, 0.05);
    ver('ckp', 'Kp (Lento)', a.ckp, b.ckp, 1, 0.05);
    ver('cki', 'Ki (Lento)', a.cki, b.cki, 4, 0.00005);
    ver('ckd', 'Kd (Lento)', a.ckd, b.ckd, 1, 0.05);
    ver('vm', 'VM', a.vm.toDouble(), b.vm.toDouble(), 0, 0.5);
    ver('frap', '% Rápido', a.frap, b.frap, 2, 0.005);
    ver('fmed', '% Medio', a.fmed, b.fmed, 2, 0.005);
    ver('flen', '% Lento', a.flen, b.flen, 2, 0.005);
  } else if (modo == 'Normal') {
    ver('kp', 'Kp', a.kp, b.kp, 1, 0.05);
    ver('ki', 'Ki', a.ki, b.ki, 4, 0.00005);
    ver('kd', 'Kd', a.kd, b.kd, 1, 0.05);
    ver('vm', 'Velocidad', a.vm.toDouble(), b.vm.toDouble(), 0, 0.5);
    ver('fcur', 'Freno en curvas', a.fcur, b.fcur, 2, 0.005);
  } else {
    ver('rkp', 'Kp (Recta)', a.rkp, b.rkp, 1, 0.05);
    ver('rki', 'Ki (Recta)', a.rki, b.rki, 4, 0.00005);
    ver('rkd', 'Kd (Recta)', a.rkd, b.rkd, 1, 0.05);
    ver('rvm', 'Velocidad (Recta)', a.rvm.toDouble(), b.rvm.toDouble(), 0, 0.5);
    ver('ckp', 'Kp (Curva)', a.ckp, b.ckp, 1, 0.05);
    ver('cki', 'Ki (Curva)', a.cki, b.cki, 4, 0.00005);
    ver('ckd', 'Kd (Curva)', a.ckd, b.ckd, 1, 0.05);
    ver('cvm', 'Velocidad (Curva)', a.cvm.toDouble(), b.cvm.toDouble(), 0, 0.5);
  }
  return out;
}

/// Analiza una corrida y arma el informe con las recomendaciones.
/// [anteriores] son los informes previos (el más nuevo primero): se usan para aprender de los cambios.
InformeAsesor analizarCorrida(List<MuestraCorrida> crudas, ParamsCorrida p,
    {DateTime? hora, List<InformeAsesor> anteriores = const []}) {
  final ahora = hora ?? DateTime.now();
  if (crudas.length < 2) {
    return InformeAsesor(ahora, 0, p, 'Normal', const [], const [],
        const ['La corrida fue demasiado corta para analizarla.'], 'Sin datos suficientes.', 0, 0, 0, null, 0, 0, 0);
  }
  final duracionS = (crudas.last.ms - crudas.first.ms) / 1000.0;
  final ultimoMs = crudas.last.ms;
  final datos = crudas.where((m) => m.ms >= _transitorioInicioMs && m.ms <= ultimoMs - _transitorioFinMs).toList();

  // Umbrales de amplitud: por debajo de esto el error es "ruido" y no cuenta como cruce de la línea
  final umb = p.umb <= 0 ? 80 : p.umb;
  final a0 = math.max(3.0, 0.06 * umb); // rectas
  final a1 = math.max(8.0, 0.20 * umb); // curvas

  // ---------------- 1) Estadísticas por grupo ----------------
  final acum = List<_Acum>.generate(7, (_) => _Acum());
  MuestraCorrida? prev;
  int grupoPrev = -1;
  int lado = 0;
  int inicioTandaMs = 0;
  int cuentaNormal = 0, cuentaMapa = 0, cuentaSect = 0;
  double sumaVel = 0;
  for (final m in datos) {
    final g = _grupoDe(m);
    final continua = prev != null && grupoPrev == g && (m.ms - prev.ms) <= 150;
    final a = acum[g];
    if (continua) {
      a.t += (m.ms - prev.ms) / 1000.0;
    } else {
      lado = 0;
      inicioTandaMs = m.ms;
      if (a.actual.isNotEmpty) a.tandas.add(a.actual);
      a.actual = [];
    }
    final e = m.err.toDouble();
    a.n++;
    a.sumE += e;
    a.sumE2 += e * e;
    a.sumAbs += e.abs();
    a.abs.add(e.abs());
    a.actual.add(e);
    if (m.ms - inicioTandaMs > 1000) {
      a.nEst++;
      a.sumEst += e;
      a.sumEst2 += e * e;
    }
    if (m.l <= 0 || m.r <= 0) a.sat++;
    final amp = _esRecta(g) ? a0 : a1;
    if (e.abs() > amp) {
      final s = e > 0 ? 1 : -1;
      if (lado != 0 && s != lado) a.cruces++;
      lado = s;
    }
    if (m.md == 0) {
      cuentaNormal++;
    } else if (m.md == 3) {
      cuentaSect++;
    } else {
      cuentaMapa++;
    }
    sumaVel += (m.l + m.r) / 2.0;
    prev = m;
    grupoPrev = g;
  }
  for (final a in acum) {
    if (a.actual.isNotEmpty) a.tandas.add(a.actual);
  }

  final stats = List<EstadisticasGrupo?>.filled(7, null);
  for (int g = 0; g < 7; g++) {
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
      _periodicidad(a.tandas),
      a.nEst,
      a.nEst > 0 ? a.sumEst / a.nEst : 0,
      a.nEst > 0 ? math.sqrt(a.sumEst2 / a.nEst) : 0,
    );
  }

  final esSectores = cuentaSect > cuentaNormal && cuentaSect >= cuentaMapa;
  final esNormal = !esSectores && cuentaNormal >= cuentaMapa;
  final modo = esSectores ? 'Sectores' : (esNormal ? 'Normal' : 'Mapa');
  final velocidadMedia = datos.isEmpty ? 0.0 : sumaVel / datos.length;

  // ---------------- 2) Costo y puntaje de la corrida ----------------
  double costo = 0, peso = 0;
  for (int g = 0; g < 7; g++) {
    final st = stats[g];
    if (st == null || st.segundos < 0.5) continue;
    final recta = _esRecta(g);
    final ref = recta ? umb.toDouble() : 2.0 * umb;
    final jg = st.rms / ref + 2 * st.satCero + (recta ? 0.15 : 0.08) * st.oscHz;
    costo += st.segundos * jg;
    peso += st.segundos;
  }
  costo = peso > 0 ? costo / peso : 0;
  final puntaje = peso > 0 ? (100 * math.exp(-1.5 * costo)).round() : 0;

  // ---------------- 3) Salidas de curva ----------------
  // En el modo Sectores no hay detección de curva: no se analiza la salida de curva
  final sal = esSectores ? _Salidas() : _analizarSalidas(datos, esNormal ? 0 : 2, math.max(2 * a0, 0.5 * umb), a0);

  final salidaProblematica = sal.eventos >= 2 && ((sal.sobrepaso > 0.35 && sal.asentamientoS > 0.4) || (sal.sobrepaso < 0.10 && sal.asentamientoS > 0.7));

  final c = _Constructor();
  final notas = c.notas;
  final problemas = <String>[]; // frases para el diagnóstico
  bool hayProblema = false;
  bool hayDatosBuenos = false;

  // ---------------- 4) Aprender: comparar con la corrida anterior ----------------
  Evaluacion? evaluacion;
  InformeAsesor? previo;
  for (final x in anteriores) {
    if (x.modo == modo && x.duracionS >= 3 && x.grupos.isNotEmpty) {
      previo = x;
      break;
    }
  }
  final valido = peso >= 2.0;
  if (previo != null && valido) {
    final cambios = cambiosEntre(previo.params, p, modo);
    if (cambios.isEmpty) {
      evaluacion = Evaluacion(cambios, 'sin_cambios', previo.puntaje.toDouble(), puntaje.toDouble(),
          'No cambiaste ningún parámetro desde la corrida anterior: el puntaje pasó de ${previo.puntaje} a $puntaje '
          '(esa es la variación normal entre vueltas).');
    } else {
      final soloVelocidad = cambios.every((x) => _cmdsVelocidad.contains(x.cmd));
      final lista = cambios.map((x) => x.texto).join(', ');
      final difAbs = previo.costo - costo; // positivo = mejoró
      final pct = difAbs / math.max(previo.costo, 0.05);
      if (soloVelocidad) {
        final estable = costo <= previo.costo * 1.25 + 0.05;
        if (estable) {
          evaluacion = Evaluacion(cambios, 'velocidad_ok', previo.puntaje.toDouble(), puntaje.toDouble(),
              'Cambiaste la velocidad ($lista): velocidad media ${previo.velocidadMedia.round()} → '
              '${velocidadMedia.round()} y el robot sigue estable (puntaje ${previo.puntaje} → $puntaje).');
        } else {
          evaluacion = Evaluacion(cambios, 'velocidad_mal', previo.puntaje.toDouble(), puntaje.toDouble(),
              'Cambiaste la velocidad ($lista) y el puntaje bajó de ${previo.puntaje} a $puntaje: con esa velocidad '
              'el robot ya no se mantiene estable.');
          for (final x in cambios) {
            c.agregar(Sugerencia(x.cmd, x.etiqueta, x.despues, x.antes, x.decimales,
                'Con ${x.etiqueta} ${x.despues.toStringAsFixed(x.decimales)} el puntaje bajó de ${previo.puntaje} a '
                '$puntaje. Volvé al valor anterior.',
                confianza: 0.8, origen: 'revertir'));
          }
        }
      } else if (pct >= _cambioSignificativo && difAbs >= 0.03) {
        evaluacion = Evaluacion(cambios, 'mejoro', previo.puntaje.toDouble(), puntaje.toDouble(),
            'Cambiaste $lista y MEJORÓ: puntaje ${previo.puntaje} → $puntaje.');
      } else if (pct <= -_cambioSignificativo && -difAbs >= 0.03) {
        evaluacion = Evaluacion(cambios, 'empeoro', previo.puntaje.toDouble(), puntaje.toDouble(),
            'Cambiaste $lista y EMPEORÓ: puntaje ${previo.puntaje} → $puntaje.');
        for (final x in cambios) {
          c.agregar(Sugerencia(x.cmd, x.etiqueta, x.despues, x.antes, x.decimales,
              'Después de cambiar ${x.etiqueta} a ${x.despues.toStringAsFixed(x.decimales)} el puntaje bajó de '
              '${previo.puntaje} a $puntaje. Volvé al valor anterior y probá otra cosa.',
              confianza: 0.85, origen: 'revertir'));
        }
      } else {
        evaluacion = Evaluacion(cambios, 'igual', previo.puntaje.toDouble(), puntaje.toDouble(),
            'Cambiaste $lista pero casi no se nota (puntaje ${previo.puntaje} → $puntaje). Probá un cambio más '
            'grande o tocá otro parámetro.');
      }
    }
  }

  // ---------------- 5) Reglas por grupo (primero rectas, después curvas) ----------------
  for (final g in const [gNormalRecta, gRecta, gRapido, gNormalCurva, gCurva, gMedio, gLento]) {
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

    // Sector medio (zig-zag): cruza la línea a propósito, así que no se mira la oscilación.
    // Solo se vigila que una rueda no se frene de más.
    if (g == gMedio) {
      if (st.satCero > _satCurva) {
        hayProblema = true;
        problemas.add('una rueda se frena en el sector medio (${_pct(st.satCero)})');
        final v = _ajustar(p.fmed, 0.9, dec: 2, min: 0.1, max: 10.0);
        if (v != null) {
          c.agregar(Sugerencia('fmed', '% Medio (de VM)', p.fmed, v, 2,
              'En ${st.nombre} una rueda llega a 0 el ${_pct(st.satCero)} del tiempo: entra demasiado rápido. '
              'Bajá el porcentaje de velocidad del sector medio.',
              confianza: _conf(st.satCero / _satCurva, st.segundos)));
        }
      }
      continue;
    }

    if (recta) {
      bool problema = false;
      final oscila = st.oscHz >= _oscMinHz && st.rms > 1.2 * a0;
      // 1) Oscilación en las rectas
      if (oscila) {
        problema = true;
        final bono = st.periodicidad > 0.5 ? 0.15 : 0.0;
        final conf = _conf(st.rms / (1.2 * a0), st.segundos, bono: bono);
        final reg = st.periodicidad > 0.5 ? ' (muy regular: es una oscilación de verdad, no ruido)' : '';
        if (st.oscHz < _oscRapidaHz) {
          problemas.add('oscilación en rectas (~${st.oscHz.toStringAsFixed(1)} Hz)');
          final v = _ajustar(pf.kp, 0.85, dec: 1, min: 0, max: 1e12);
          if (v != null) {
            c.agregar(Sugerencia(
                pf.kpCmd,
                'Kp (${pf.nombre})',
                pf.kp,
                v,
                1,
                'En ${st.nombre} el robot oscila a ~${st.oscHz.toStringAsFixed(1)} veces por segundo$reg '
                '(error RMS ${st.rms.toStringAsFixed(0)}). Suele ser Kp alto para el Kd: bajá Kp un poco. '
                'Si después se vuelve lento para corregir, en vez de bajar Kp probá subir Kd.',
                confianza: conf));
          }
        } else {
          problemas.add('vibración rápida en rectas (~${st.oscHz.toStringAsFixed(1)} Hz)');
          final v = _ajustar(pf.kd, 0.8, dec: 1, min: 0, max: 1e12);
          if (v != null) {
            c.agregar(Sugerencia(
                pf.kdCmd,
                'Kd (${pf.nombre})',
                pf.kd,
                v,
                1,
                'En ${st.nombre} el robot vibra rápido (~${st.oscHz.toStringAsFixed(1)} veces por segundo). '
                'Suele ser un Kd demasiado alto, que amplifica el ruido de los sensores: bajalo un poco.',
                confianza: conf));
          }
        }
        // Con Ki activo y oscilación lenta, el integral puede estar empeorando todo
        if (pf.ki > 0 && st.oscHz < _oscRapidaHz) {
          final v = _ajustar(pf.ki, 0.5, dec: 4, min: 0, max: _kiMaxSeguro);
          if (v != null) {
            c.agregar(Sugerencia(pf.kiCmd, 'Ki (${pf.nombre})', pf.ki, v, 4,
                'Hay oscilación en ${st.nombre} y Ki está activo: el integral agrega retraso y puede sostenerla. '
                'Probá con la mitad.',
                confianza: _conf(st.rms / (1.2 * a0), st.segundos, bono: 0.0, tope: 0.6)));
          }
        }
      }
      // 2) Rueda frenada en las rectas
      if (st.satCero > _satRecta) {
        problema = true;
        problemas.add('una rueda se frena en rectas (${_pct(st.satCero)})');
        final v = _ajustar(pf.kp, 0.8, dec: 1, min: 0, max: 1e12);
        if (v != null) {
          c.agregar(Sugerencia(
              pf.kpCmd,
              'Kp (${pf.nombre})',
              pf.kp,
              v,
              1,
              'En ${st.nombre} una rueda llega a 0 el ${_pct(st.satCero)} del tiempo: la corrección es '
              'demasiado fuerte. Bajá Kp.',
              confianza: _conf(st.satCero / _satRecta, st.segundos)));
        }
      }
      // 3) Corrimiento constante hacia un lado
      // Se mide en régimen estable (sin el primer segundo de cada recta, que es el coletazo de la curva)
      final sesgo = st.sesgoEstable;
      final hayBias = st.muestrasEstables >= 20 &&
          st.rmsEstable > a0 &&
          sesgo.abs() > math.max(2 * a0, 0.7 * st.rmsEstable);
      if (hayBias) {
        problema = true;
        problemas.add('anda corrido hacia un lado (error medio ${sesgo.toStringAsFixed(0)})');
        notas.add('En ${st.nombre} el error medio es ${sesgo.toStringAsFixed(0)}: el robot anda corrido hacia un '
            'lado. Antes que nada recalibrá sobre la pista y revisá que los motores y las ruedas estén parejos.');
        // Ki: solo si no hay oscilación, ruedas frenadas ni problemas al salir de curvas (si no, el problema es otro)
        if (!oscila && st.satCero < 0.05 && st.periodicidad < 0.4 && st.segundos >= 3 && !salidaProblematica) {
          double? kiNuevo;
          if (pf.ki <= 0) {
            final obj = (1.5 * math.max(pf.kp, 0.1) * sesgo.abs() / _kiIntegralMax).clamp(0.0003, 0.003).toDouble();
            kiNuevo = (obj * 10000).round() / 10000;
          } else if (pf.ki < _kiMaxSeguro) {
            kiNuevo = _ajustar(pf.ki, 1.5, dec: 4, min: 0.0001, max: _kiMaxSeguro);
          }
          if (kiNuevo != null && kiNuevo != pf.ki) {
            final autoridad = (kiNuevo * _kiIntegralMax).round();
            c.agregar(Sugerencia(
                pf.kiCmd,
                'Ki (${pf.nombre})',
                pf.ki,
                kiNuevo,
                4,
                'El error en ${st.nombre} (en régimen estable) es siempre hacia el mismo lado: el robot necesita una corrección '
                'constante y el término integral la aprende solo. El valor es chico a propósito: en este código '
                'el integral se llena en ~1 segundo, así que Ki×10000 es lo máximo que puede aportar (unos '
                '$autoridad de PWM). Si el corrimiento viene de la calibración, recalibrar es mejor. Si después '
                'de usar Ki el robot se pasa al salir de las curvas, bajalo.',
                confianza: _conf(sesgo.abs() / (2 * a0), st.segundos, tope: 0.55)));
          }
        }
      }
      if (problema) hayProblema = true;
    } else {
      bool problema = false;
      final normal = g == gNormalCurva;
      // 1) Entra demasiado rápido: una rueda se frena casi del todo
      if (st.satCero > _satCurva) {
        problema = true;
        problemas.add('una rueda se frena en curvas (${_pct(st.satCero)})');
        final conf = _conf(st.satCero / _satCurva, st.segundos);
        if (normal) {
          if (p.fcur >= 0.99) {
            c.agregar(Sugerencia('fcur', 'Freno en curvas', p.fcur, 0.8, 2,
                'En las curvas una rueda llega a 0 el ${_pct(st.satCero)} del tiempo: entra demasiado rápido. '
                'Activá el freno en curvas (0.80 = en curva va al 80% de la velocidad).',
                confianza: conf));
          } else {
            final v = _ajustar(p.fcur, 0.9, dec: 2, min: 0.3, max: 10.0);
            if (v != null) {
              c.agregar(Sugerencia('fcur', 'Freno en curvas', p.fcur, v, 2,
                  'Aun con freno, una rueda llega a 0 el ${_pct(st.satCero)} del tiempo en curva. Frená un poco más.',
                  confianza: conf));
            }
          }
        } else if (g == gLento) {
          final v = _ajustar(p.flen, 0.9, dec: 2, min: 0.1, max: 10.0);
          if (v != null) {
            c.agregar(Sugerencia('flen', '% Lento (de VM)', p.flen, v, 2,
                'En ${st.nombre} una rueda llega a 0 el ${_pct(st.satCero)} del tiempo: entra demasiado rápido. '
                'Bajá el porcentaje de velocidad del sector lento.',
                confianza: conf));
          }
        } else {
          final v = _ajustarEntero(pf.vel, 0.9);
          if (v != null) {
            c.agregar(Sugerencia(pf.velCmd, 'Velocidad (${pf.nombre})', pf.vel.toDouble(), v.toDouble(), 0,
                'En ${st.nombre} una rueda llega a 0 el ${_pct(st.satCero)} del tiempo: entra demasiado rápido. '
                'Bajá la velocidad de curva.',
                confianza: conf));
          }
        }
      }
      // 2) Oscilación dentro de la curva
      final oscila = st.oscHz >= _oscMinHz && st.rms > a1;
      if (oscila) {
        problema = true;
        problemas.add('zigzaguea en curvas (~${st.oscHz.toStringAsFixed(1)} Hz)');
        final v = _ajustar(pf.kp, 0.85, dec: 1, min: 0, max: 1e12);
        if (v != null) {
          c.agregar(Sugerencia(pf.kpCmd, 'Kp (${pf.nombre})', pf.kp, v, 1,
              'En ${st.nombre} el robot zigzaguea (~${st.oscHz.toStringAsFixed(1)} veces por segundo) mientras '
              'toma la curva. Bajá un poco Kp.',
              confianza: _conf(st.rms / a1, st.segundos, bono: st.periodicidad > 0.5 ? 0.15 : 0)));
        }
      }
      // 3) Se abre en las curvas (confianza baja)
      if (!oscila && st.satCero < 0.20 && st.mediaAbs > 2.2 * umb) {
        problema = true;
        problemas.add('se abre en curvas (error ~${st.mediaAbs.toStringAsFixed(0)})');
        final v = _ajustar(pf.kp, 1.2, dec: 1, min: 0, max: 1e12);
        if (v != null) {
          c.agregar(Sugerencia(pf.kpCmd, 'Kp (${pf.nombre})', pf.kp, v, 1,
              'En ${st.nombre} el error se mantiene alto (~${st.mediaAbs.toStringAsFixed(0)}): al robot le falta '
              'fuerza para seguir la curva. Probá un poco más de Kp. (Confianza baja: también puede ser exceso '
              'de velocidad.)',
              confianza: _conf(st.mediaAbs / (2.2 * umb), st.segundos, tope: 0.4)));
        }
      }
      if (problema) hayProblema = true;
    }
  }

  // ---------------- 6) Reglas de la salida de curva (respuesta al escalón) ----------------
  if (sal.eventos >= 2) {
    final pf = _perfilDe(esNormal ? gNormalRecta : gRecta, p);
    final nombre = pf.nombre;
    final conf = (0.45 + 0.05 * math.min(sal.eventos, 6)).clamp(0.45, 0.75).toDouble();
    if (sal.sobrepaso > 0.35 && sal.asentamientoS > 0.4) {
      hayProblema = true;
      problemas.add('se pasa para el otro lado al salir de las curvas (${_pct(sal.sobrepaso)} del error de la curva)');
      if (pf.ki > 0) {
        final v = _ajustar(pf.ki, 0.5, dec: 4, min: 0, max: _kiMaxSeguro);
        if (v != null) {
          c.agregar(Sugerencia(pf.kiCmd, 'Ki ($nombre)', pf.ki, v, 4,
              'Al salir de ${sal.eventos} curvas el robot se pasa ${_pct(sal.sobrepaso)} para el otro lado y tarda '
              '${sal.asentamientoS.toStringAsFixed(1)} s en calmarse. Con Ki activo suele ser el integral lleno '
              'de la curva ("windup"): bajá Ki.',
              confianza: conf + 0.1));
        }
      }
      final kdBase = pf.kd > 0 ? pf.kd : math.max(1.0, pf.kp * 10);
      final v = pf.kd > 0 ? _ajustar(pf.kd, 1.25, dec: 1, min: 0, max: 1e12) : (kdBase * 10).round() / 10;
      if (v != null && v != pf.kd) {
        c.agregar(Sugerencia(pf.kdCmd, 'Kd ($nombre)', pf.kd, v, 1,
            'Al salir de ${sal.eventos} curvas el robot se pasa ${_pct(sal.sobrepaso)} para el otro lado y tarda '
            '${sal.asentamientoS.toStringAsFixed(1)} s en calmarse: falta amortiguación. Subí un poco Kd.',
            confianza: conf));
      }
    } else if (sal.sobrepaso < 0.10 && sal.asentamientoS > 0.7) {
      hayProblema = true;
      problemas.add('tarda en recuperarse al salir de las curvas (${sal.asentamientoS.toStringAsFixed(1)} s)');
      final v = _ajustar(pf.kp, 1.2, dec: 1, min: 0, max: 1e12);
      if (v != null) {
        c.agregar(Sugerencia(pf.kpCmd, 'Kp ($nombre)', pf.kp, v, 1,
            'Al salir de ${sal.eventos} curvas el robot tarda ${sal.asentamientoS.toStringAsFixed(1)} s en volver '
            'a la línea y casi no se pasa: reacciona despacio. Probá un poco más de Kp.',
            confianza: conf - 0.1));
      }
    }
  }

  // ---------------- 7) Aprender: si el último cambio mejoró, seguir en esa dirección ----------------
  if (evaluacion != null && evaluacion.veredicto == 'mejoro') {
    final noVel = evaluacion.cambios.where((x) => !_cmdsVelocidad.contains(x.cmd)).toList();
    if (noVel.length == 1) {
      final x = noVel.first;
      final f = x.antes == 0 ? 1.0 : (x.despues / x.antes);
      final seguir = f == 1.0 ? null : math.pow(f, 0.7).toDouble();
      if (seguir != null) {
        final dec = x.decimales;
        final nuevo = _ajustar(x.despues, seguir, dec: dec, min: 0.0, max: dec == 4 ? _kiMaxSeguro : 1e12);
        if (nuevo != null) {
          c.agregar(Sugerencia(x.cmd, x.etiqueta, x.despues, nuevo, dec,
              'Cambiar ${x.etiqueta} de ${x.antes.toStringAsFixed(dec)} a ${x.despues.toStringAsFixed(dec)} mejoró '
              'el puntaje (${evaluacion.puntajeAntes.round()} → ${evaluacion.puntajeAhora.round()}). Probá un paso '
              'más en la misma dirección; cuando la mejora sea chica, ya estás cerca de lo mejor.',
              confianza: 0.55, origen: 'aprendizaje'));
        }
      }
    }
  }

  // ---------------- 8) Todo bien: se puede probar más velocidad ----------------
  if (hayDatosBuenos && !hayProblema && c.lista.isEmpty) {
    final g = esSectores ? gRapido : (esNormal ? gNormalRecta : gRecta);
    final st = stats[g];
    if (st != null && st.segundos >= _minSegRecta) {
      final pf = _perfilDe(g, p);
      final v = _ajustarEntero(pf.vel, 1.08);
      if (v != null && v > pf.vel) {
        c.agregar(Sugerencia(pf.velCmd, esSectores ? 'VM (velocidad base)' : 'Velocidad (${pf.nombre})', pf.vel.toDouble(), v.toDouble(), 0,
            esSectores
                ? 'El sector rápido se ve estable (error RMS ${st.rms.toStringAsFixed(0)}, sin oscilación). Podés '
                    'probar un poco más de VM (se escalan los tres sectores) y volver a correr.'
                : 'Las rectas se ven estables (error RMS ${st.rms.toStringAsFixed(0)}, sin oscilación). Podés '
                    'probar un poco más de velocidad y volver a correr.',
            confianza: 0.5));
      }
    }
    if (c.lista.isEmpty) notas.add('Todo se ve estable. No encuentro nada para mejorar con esta corrida.');
  }

  if (!hayDatosBuenos && notas.isEmpty) {
    notas.add('No hay datos suficientes en esta corrida.');
  }

  // ---------------- 9) Orden final: la más confiable primero ----------------
  final ordenadas = List<Sugerencia>.of(c.lista);
  final indice = <Sugerencia, int>{for (int i = 0; i < ordenadas.length; i++) ordenadas[i]: i};
  ordenadas.sort((a, b) {
    final d = b.confianza.compareTo(a.confianza);
    return d != 0 ? d : indice[a]!.compareTo(indice[b]!);
  });
  final limitadas = ordenadas.length > 4 ? ordenadas.sublist(0, 4) : ordenadas;

  String diagnostico;
  if (!hayDatosBuenos) {
    diagnostico = 'Todavía no hay datos suficientes: dá una vuelta completa.';
  } else if (problemas.isEmpty) {
    diagnostico = 'El robot se comporta bien en esta corrida (puntaje $puntaje de 100).';
  } else {
    diagnostico = 'Lo que veo: ${problemas.join('; ')}. Puntaje $puntaje de 100.';
  }

  return InformeAsesor(
    ahora,
    duracionS,
    p,
    modo,
    [for (final s in stats) if (s != null) s],
    limitadas,
    notas,
    diagnostico,
    costo,
    puntaje,
    velocidadMedia,
    evaluacion,
    sal.eventos,
    sal.sobrepaso,
    sal.asentamientoS,
  );
}
