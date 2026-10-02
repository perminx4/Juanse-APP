import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/bluetooth_service.dart';

class ConsoleScreen extends StatelessWidget {
  const ConsoleScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Consola de Datos'),
      ),
      body: Consumer<BluetoothService>(
        builder: (context, service, child) {
          if (service.consoleLog.isEmpty) {
            return const Center(child: Text('Aún no hay datos en la consola.'));
          }
          return ListView.builder(
            reverse: true, // Muestra los logs más nuevos arriba
            itemCount: service.consoleLog.length,
            itemBuilder: (context, index) {
              final log = service.consoleLog[index];
              Color color = Colors.grey;
              if (log.contains("TX:")) color = Colors.lightBlueAccent;
              if (log.contains("RX:")) color = Colors.lightGreenAccent;
              if (log.contains("ERROR") || log.contains("Fallo")) color = Colors.redAccent;

              return Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                child: Text(log, style: TextStyle(color: color, fontFamily: 'monospace')),
              );
            },
          );
        },
      ),
    );
  }
}
