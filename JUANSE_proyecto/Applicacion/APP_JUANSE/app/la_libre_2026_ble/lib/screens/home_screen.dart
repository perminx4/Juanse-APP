import 'package:flutter/material.dart';
import 'control_screen.dart';
import 'graph_screen.dart';
import 'console_screen.dart';
import 'sessions_screen.dart'; // <-- Importa la nueva pantalla

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  int _selectedIndex = 0;

  // --- AÑADIDO: Nueva pantalla a la lista ---
  static const List<Widget> _widgetOptions = <Widget>[
    ControlScreen(),
    GraphScreen(),
    ConsoleScreen(),
    SessionsScreen(), // <-- Nueva pestaña
  ];

  void _onItemTapped(int index) {
    setState(() {
      _selectedIndex = index;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: _widgetOptions.elementAt(_selectedIndex),
      ),
      bottomNavigationBar: BottomNavigationBar(
        // --- AÑADIDO: Nuevo ítem en la barra ---
        items: const <BottomNavigationBarItem>[
          BottomNavigationBarItem(
            icon: Icon(Icons.tune),
            label: 'Control',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.show_chart),
            label: 'Gráficos',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.terminal),
            label: 'Consola',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.folder_copy),
            label: 'Sesiones', // <-- Nueva pestaña
          ),
        ],
        currentIndex: _selectedIndex,
        onTap: _onItemTapped,
        // --- AÑADIDO: Estilo para que se vean todas las pestañas ---
        type: BottomNavigationBarType.fixed,
      ),
    );
  }
}
