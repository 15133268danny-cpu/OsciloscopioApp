import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';

void main() {
  runApp(const MaterialApp(
    debugShowCheckedModeBanner: false,
    home: OsciloscopioScreen(),
  ));
}

class OsciloscopioScreen extends StatefulWidget {
  const OsciloscopioScreen({Key? key}) : super(key: key);

  @override
  State<OsciloscopioScreen> createState() => _OsciloscopioScreenState();
}

class _OsciloscopioScreenState extends State<OsciloscopioScreen> {
  RawDatagramSocket? _socket;
  bool _conectado = false;
  bool _modoHold = false;

  final List<double> _muestrasCH1 = [];
  final int _capacidadBuffer = 600;
  double _voltsDiv = 1.0;
  double _offsetY = 0.0;

  Future<void> _toggleUdp() async {
    if (_conectado) {
      _socket?.close();
      setState(() => _conectado = false);
      return;
    }

    try {
      _socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 8888);
      setState(() => _conectado = true);

      _socket!.listen((event) {
        if (event == RawSocketEvent.read) {
          final dg = _socket!.receive();
          if (dg != null && !_modoHold) {
            _procesarPaquete(dg.data);
          }
        }
      });
    } catch (e) {
      setState(() => _conectado = false);
    }
  }

  void _procesarPaquete(Uint8List data) {
    for (int i = 0; i <= data.length - 9; i++) {
      if (data[i] == 0xAA && data[i + 8] == 0x55) {
        int raw1 = (data[i + 1] << 8) | data[i + 2];
        double v1 = (raw1 * 3.3) / 4095.0;

        setState(() {
          _muestrasCH1.add(v1);
          if (_muestrasCH1.length > _capacidadBuffer) {
            _muestrasCH1.removeAt(0);
          }
        });
        break;
      }
    }
  }

  @override
  void dispose() {
    _socket?.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF101622),
      appBar: AppBar(
        title: const Text('OSCILOSCOPIO UDP :8888', style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold)),
        backgroundColor: const Color(0xFF17202C),
        actions: [
          IconButton(
            icon: Icon(_modoHold ? Icons.play_arrow : Icons.pause),
            color: _modoHold ? Colors.orange : Colors.white,
            onPressed: () => setState(() => _modoHold = !_modoHold),
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: Container(
              margin: const EdgeInsets.all(8),
              color: const Color(0xFF0D131A),
              child: CustomPaint(
                painter: OsciloscopioPainter(_muestrasCH1, _voltsDiv, _offsetY),
                child: Container(),
              ),
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            color: const Color(0xFF17202C),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: _conectado ? Colors.redAccent : const Color(0xFF008CDC),
                  ),
                  onPressed: _toggleUdp,
                  child: Text(_conectado ? 'DESCONECTAR' : 'CONECTAR UDP'),
                ),
                Text(
                  'Buffer: ${_muestrasCH1.length} pts',
                  style: const TextStyle(color: Colors.white70, fontFamily: 'monospace'),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class OsciloscopioPainter extends CustomPainter {
  final List<double> muestras;
  final double vDiv;
  final double offsetY;

  OsciloscopioPainter(this.muestras, this.vDiv, this.offsetY);

  @override
  void paint(Canvas canvas, Size size) {
    final double anchoCuadro = size.width / 10.0;
    final double altoCuadro = size.height / 8.0;
    final double yCentro = size.height / 2.0;

    final pGrid = Paint()
      ..color = const Color(0xFF202C3D)
      ..strokeWidth = 1.0
      ..style = PaintingStyle.stroke;

    for (int i = 0; i <= 10; i++) {
      canvas.drawLine(Offset(i * anchoCuadro, 0), Offset(i * anchoCuadro, size.height), pGrid);
    }
    for (int i = 0; i <= 8; i++) {
      canvas.drawLine(Offset(0, i * altoCuadro), Offset(size.width, i * altoCuadro), pGrid);
    }

    if (muestras.length < 2) return;

    final pTrazo = Paint()
      ..color = const Color(0xFF00D7FF)
      ..strokeWidth = 2.0
      ..style = PaintingStyle.stroke;

    final path = Path();
    for (int i = 0; i < muestras.length; i++) {
      double x = (i / (muestras.length - 1)) * size.width;
      double y = yCentro - (offsetY * altoCuadro) - ((muestras[i] / vDiv) * altoCuadro);
      if (i == 0) {
        path.moveTo(x, y);
      } else {
        path.lineTo(x, y);
      }
    }
    canvas.drawPath(path, pTrazo);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => true;
}
