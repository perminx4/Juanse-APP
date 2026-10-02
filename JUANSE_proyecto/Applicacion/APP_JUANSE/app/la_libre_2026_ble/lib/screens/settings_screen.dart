import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/settings_service.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late Map<String, TextEditingController> _controllers;

  @override
  void initState() {
    super.initState();
    _controllers = {};
    final settings = Provider.of<SettingsService>(context, listen: false);
    settings.steps.forEach((key, value) {
      _controllers[key] = TextEditingController(text: value.toString());
    });
  }

  @override
  void dispose() {
    _controllers.forEach((key, controller) {
      controller.dispose();
    });
    super.dispose();
  }

  // --- NUEVO: Función para guardar el valor ---
  void _saveValue(String key, String value) {
    final settings = Provider.of<SettingsService>(context, listen: false);
    final doubleValue = double.tryParse(value);
    if (doubleValue != null) {
      settings.saveStep(key, doubleValue);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Ajustes de Incrementos'),
      ),
      body: Consumer<SettingsService>(
        builder: (context, settings, child) {
          return ListView(
            padding: const EdgeInsets.all(16.0),
            children: settings.steps.entries.map((entry) {
              return Padding(
                padding: const EdgeInsets.symmetric(vertical: 8.0),
                child: TextField(
                  controller: _controllers[entry.key],
                  decoration: InputDecoration(
                    labelText: 'Salto para ${entry.key.toUpperCase()}',
                    border: const OutlineInputBorder(),
                  ),
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  // --- MODIFICADO: Ahora guarda el valor en cada cambio ---
                  onChanged: (value) {
                    _saveValue(entry.key, value);
                  },
                ),
              );
            }).toList(),
          );
        },
      ),
    );
  }
}
