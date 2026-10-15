import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/bluetooth_service.dart';

class GraphScreen extends StatefulWidget {
  const GraphScreen({super.key});

  @override
  State<GraphScreen> createState() => _GraphScreenState();
}

class _GraphScreenState extends State<GraphScreen> {
  @override
  Widget build(BuildContext context) {
    final service = context.watch<BluetoothService>();

    return Scaffold(
      appBar: AppBar(
        title: const Text('Gráficos en Tiempo Real'),
        actions: [
          IconButton(
            icon: Icon(service.isPaused ? Icons.play_arrow : Icons.pause),
            tooltip: service.isPaused ? 'Reanudar' : 'Pausar',
            onPressed: () {
              context.read<BluetoothService>().togglePause();
            },
          ),
          IconButton(
            icon: Icon(service.isRecording ? Icons.stop : Icons.fiber_manual_record, color: service.isRecording ? Colors.red : null),
            tooltip: service.isRecording ? 'Detener Grabación' : 'Iniciar Grabación',
            onPressed: () async {
              if (service.isRecording) {
                final filePath = await context.read<BluetoothService>().stopAndSaveRecording();
                if (mounted && filePath != null) {
                  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Datos guardados en $filePath'), duration: const Duration(seconds: 5)));
                }
              } else {
                context.read<BluetoothService>().startRecording();
              }
            },
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text("Velocidad Ruedas (0-255)", style: Theme.of(context).textTheme.headlineSmall),
          const SizedBox(height: 8),
          Row(
            children: [
              _legendItem(Colors.orange, "Izquierda (L)"),
              const SizedBox(width: 16),
              _legendItem(Colors.teal, "Derecha (R)"),
            ],
          ),
          const SizedBox(height: 8),
          _buildMultiLineChart(
            line1Data: service.lData,
            line2Data: service.rData,
            line1Color: Colors.orange,
            line2Color: Colors.teal,
            minY: 0,
            maxY: 255,
          ),
          const SizedBox(height: 32),

          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text("Error de posición", style: Theme.of(context).textTheme.headlineSmall),
              const Text("🎯 Centro ideal: 0", style: TextStyle(color: Colors.greenAccent, fontSize: 12, fontWeight: FontWeight.bold)),
            ],
          ),
          const SizedBox(height: 16),
          _buildPosChart(service.posData),
          const SizedBox(height: 32),

          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text("Error suavizado", style: Theme.of(context).textTheme.headlineSmall),
              Text("Umbral de curva: ${service.umb}", style: const TextStyle(color: Colors.orangeAccent, fontSize: 12, fontWeight: FontWeight.bold)),
            ],
          ),
          const SizedBox(height: 16),
          _buildEaChart(service.eaData, service.umb.toDouble()),
        ],
      ),
    );
  }

  Widget _legendItem(Color color, String text) {
    return Row(
      children: [
        Container(width: 16, height: 16, color: color),
        const SizedBox(width: 8),
        Text(text),
      ],
    );
  }

  // El robot manda el error con signo (0 = línea centrada): el eje es simétrico y se ajusta solo
  Widget _buildPosChart(List<FlSpot> data) {
    double maxAbs = 100;
    for (final p in data) {
      if (p.y.abs() > maxAbs) maxAbs = p.y.abs();
    }
    final double limite = (maxAbs * 1.2).ceilToDouble();
    return AspectRatio(
      aspectRatio: 1.7,
      child: LineChart(
        LineChartData(
          minY: -limite,
          maxY: limite,
          lineTouchData: _lineTouchData(),
          lineBarsData: [
            _lineBarData(data, Colors.redAccent),
          ],
          extraLinesData: ExtraLinesData(
            horizontalLines: [
              HorizontalLine(
                y: 0,
                color: Colors.greenAccent,
                strokeWidth: 2,
                dashArray: [6, 4],
                label: HorizontalLineLabel(
                  show: true,
                  alignment: Alignment.topRight,
                  padding: const EdgeInsets.only(right: 8, bottom: 4),
                  style: const TextStyle(color: Colors.greenAccent, fontSize: 10, fontWeight: FontWeight.bold),
                  labelResolver: (line) => "Centro (0)",
                ),
              ),
            ],
          ),
          titlesData: _titlesData(),
          gridData: _gridData(),
          borderData: FlBorderData(show: true, border: Border.all(color: Colors.white24)),
        ),
      ),
    );
  }

  // Error suavizado que usa el robot para decidir recta/curva, con la línea del umbral
  Widget _buildEaChart(List<FlSpot> data, double umbral) {
    double maxVal = umbral * 2;
    for (final p in data) {
      if (p.y * 1.2 > maxVal) maxVal = p.y * 1.2;
    }
    if (maxVal < 10) maxVal = 10;
    return AspectRatio(
      aspectRatio: 1.7,
      child: LineChart(
        LineChartData(
          minY: 0,
          maxY: maxVal.ceilToDouble(),
          lineTouchData: _lineTouchData(),
          lineBarsData: [
            _lineBarData(data, Colors.lightBlueAccent),
          ],
          extraLinesData: ExtraLinesData(
            horizontalLines: [
              HorizontalLine(
                y: umbral,
                color: Colors.orangeAccent,
                strokeWidth: 2,
                dashArray: [6, 4],
                label: HorizontalLineLabel(
                  show: true,
                  alignment: Alignment.topRight,
                  padding: const EdgeInsets.only(right: 8, bottom: 4),
                  style: const TextStyle(color: Colors.orangeAccent, fontSize: 10, fontWeight: FontWeight.bold),
                  labelResolver: (line) => "Umbral",
                ),
              ),
            ],
          ),
          titlesData: _titlesData(),
          gridData: _gridData(),
          borderData: FlBorderData(show: true, border: Border.all(color: Colors.white24)),
        ),
      ),
    );
  }

  Widget _buildMultiLineChart({
    required List<FlSpot> line1Data,
    required List<FlSpot> line2Data,
    required Color line1Color,
    required Color line2Color,
    double? minY,
    double? maxY,
  }) {
    return AspectRatio(
      aspectRatio: 1.7,
      child: LineChart(
        LineChartData(
          minY: minY,
          maxY: maxY,
          lineTouchData: _lineTouchData(),
          lineBarsData: [
            _lineBarData(line1Data, line1Color),
            _lineBarData(line2Data, line2Color),
          ],
          titlesData: _titlesData(),
          gridData: _gridData(),
          borderData: FlBorderData(show: true, border: Border.all(color: Colors.white24)),
        ),
      ),
    );
  }

  LineChartBarData _lineBarData(List<FlSpot> spots, Color color) {
    return LineChartBarData(
      spots: spots,
      isCurved: true,
      color: color,
      barWidth: 3,
      dotData: const FlDotData(show: false),
      belowBarData: BarAreaData(show: true, color: color.withValues(alpha: 0.2)),
    );
  }

  FlTitlesData _titlesData() {
    return FlTitlesData(
      leftTitles: AxisTitles(
        sideTitles: SideTitles(
          showTitles: true,
          reservedSize: 44,
          getTitlesWidget: (value, meta) {
            if (value == meta.max) {
              return const SizedBox.shrink();
            }
            return Padding(
              padding: const EdgeInsets.only(right: 4.0),
              child: Text(meta.formattedValue, style: const TextStyle(fontSize: 10), textAlign: TextAlign.right),
            );
          },
        ),
      ),
      bottomTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
      topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
      rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
    );
  }

  FlGridData _gridData() {
    return FlGridData(
      show: true,
      getDrawingHorizontalLine: (value) => const FlLine(color: Colors.white12, strokeWidth: 1),
      getDrawingVerticalLine: (value) => const FlLine(color: Colors.white12, strokeWidth: 1),
    );
  }

  LineTouchData _lineTouchData() {
    return LineTouchData(
      touchTooltipData: LineTouchTooltipData(
        getTooltipColor: (spot) => Colors.blueGrey.withValues(alpha: 0.8),
        getTooltipItems: (List<LineBarSpot> touchedBarSpots) {
          return touchedBarSpots.map((barSpot) {
            final flSpot = barSpot;
            return LineTooltipItem(
              flSpot.y.toStringAsFixed(2),
              const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
            );
          }).toList();
        },
      ),
      handleBuiltInTouches: true,
    );
  }
}