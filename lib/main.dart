import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'package:flutter/material.dart';

void main() {
  runApp(const MaterialApp(
    debugShowCheckedModeBanner: false,
    home: OsciloscopioApp(),
  ));
}

class OsciloscopioApp extends StatefulWidget {
  const OsciloscopioApp({Key? key}) : super(key: key);

  @override
  State<OsciloscopioApp> createState() => _OsciloscopioAppState();
}

class _OsciloscopioAppState extends State<OsciloscopioApp> {
  // Comunicación y estado
  RawDatagramSocket? _socket;
  Timer? _timerSimulacion;
  bool _conectado = false;
  bool _simulando = false;
  bool _modoHold = false;
  String _estadoTexto = "DESCONECTADO";
  Color _colorEstado = const Color(0xFF8A99AD);

  // Búfer de datos (CH1, CH2, CH3)
  final List<List<double>> _canales = [[], [], []];
  static const int capacidadMax = 2000;
  double _tiempoAcumulado = 0.0;
  double _dtSimulado = 0.000000025; // Base de tiempo para 40 MSPS (resuelve señales de > 4 MHz)

  // Ajustes de visualización por canal
  final List<double> _vDiv = [1.0, 1.0, 1.0];
  final List<double> _offsetY = [-2.0, 0.0, 2.0];
  final List<bool> _visible = [true, true, true];
  int _canalActivo = 0;

  // Base de tiempo horizontal (microsegundos por división)
  double _usPorDiv = 0.5;

  // Paleta de colores idéntica a tu diseño de PC
  final List<Color> _coloresCH = const [
    Color(0xFF00C8FF), // CH1 Azul / Cian
    Color(0xFFFFA000), // CH2 Ámbar / Naranja
    Color(0xFFFF4141), // CH3 Rojo
  ];

  String _telemetriaTexto = "CH1: 0.00 V | Vpp: 0.00 V | Vrms: 0.00 V";

  // --- FUNCIÓN DE SIMULACIÓN INTERNA (> 4 MHz) ---
  void _toggleSimulacion() {
    if (_simulando) {
      _timerSimulacion?.cancel();
      setState(() {
        _simulando = false;
        _conectado = false;
        _estadoTexto = "DESCONECTADO";
        _colorEstado = const Color(0xFF8A99AD);
      });
      return;
    }

    _desconectarUDP();
    _simulando = true;
    _conectado = true;
    _estadoTexto = "SIMULACIÓN 4.5 MHz";
    _colorEstado = const Color(0xFF00C8FF);

    _timerSimulacion = Timer.periodic(const Duration(milliseconds: 33), (t) {
      if (!_modoHold) {
        for (int k = 0; k < 100; k++) {
          _tiempoAcumulado += _dtSimulado;
          // Señal 1: Senoidal pura de 4.5 MHz
          double v1 = 1.65 + 1.35 * sin(2.0 * pi * 4500000.0 * _tiempoAcumulado);
          // Señal 2: Onda de 1.0 MHz
          double v2 = 1.65 + 1.00 * sin(2.0 * pi * 1000000.0 * _tiempoAcumulado);
          // Señal 3: Pulso cuadrado de 2.0 MHz
          double v3 = (sin(2.0 * pi * 2000000.0 * _tiempoAcumulado) > 0) ? 3.3 : 0.0;

          _canales[0].add(v1);
          _canales[1].add(v2);
          _canales[2].add(v3);
        }

        for (int c = 0; c < 3; c++) {
          if (_canales[c].length > capacidadMax) {
            _canales[c].removeRange(0, _canales[c].length - capacidadMax);
          }
        }
        _actualizarTelemetria();
        setState(() {});
      }
    });
    setState(() {});
  }

  // --- CONEXIÓN UDP CON ESP32 ---
  Future<void> _toggleUDP() async {
    if (_conectado && !_simulando) {
      _desconectarUDP();
      return;
    }
    if (_simulando) _toggleSimulacion();

    try {
      _socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 8888);
      setState(() {
        _conectado = true;
        _estadoTexto = "UDP :8888 ACTIVO";
        _colorEstado = const Color(0xFF2ECC71);
      });

      _socket!.listen((event) {
        if (event == RawSocketEvent.read) {
          final dg = _socket!.receive();
          if (dg != null && !_modoHold) {
            _procesarPaquete(dg.data);
          }
        }
      });
    } catch (e) {
      setState(() {
        _conectado = false;
        _estadoTexto = "ERROR DE CONEXIÓN";
        _colorEstado = const Color(0xFFDC3C3C);
      });
    }
  }

  void _desconectarUDP() {
    _socket?.close();
    _socket = null;
    setState(() {
      _conectado = false;
      _estadoTexto = "DESCONECTADO";
      _colorEstado = const Color(0xFF8A99AD);
    });
  }

  void _procesarPaquete(Uint8List data) {
    for (int i = 0; i <= data.length - 9; i++) {
      if (data[i] == 0xAA && data[i + 8] == 0x55) {
        int chk = 0xAA;
        for (int k = 1; k <= 6; k++) chk ^= data[i + k];

        if ((chk & 0xFF) == data[i + 7]) {
          int adc1 = (data[i + 1] << 8) | data[i + 2];
          int adc2 = (data[i + 3] << 8) | data[i + 4];
          int adc3 = (data[i + 5] << 8) | data[i + 6];

          _canales[0].add((adc1 * 3.3) / 4095.0);
          _canales[1].add((adc2 * 3.3) / 4095.0);
          _canales[2].add((adc3 * 3.3) / 4095.0);

          for (int c = 0; c < 3; c++) {
            if (_canales[c].length > capacidadMax) _canales[c].removeAt(0);
          }
        }
      }
    }
    _actualizarTelemetria();
    setState(() {});
  }

  void _actualizarTelemetria() {
    int ch = _canalActivo;
    if (_canales[ch].length < 10) return;

    List<double> m = _canales[ch];
    double vmax = m.reduce(max);
    double vmin = m.reduce(min);
    double vpp = vmax - vmin;

    double sumaCuad = 0;
    for (double v in m) sumaCuad += v * v;
    double vrms = sqrt(sumaCuad / m.length);

    _telemetriaTexto = "CH${ch + 1}: ${m.last.toStringAsFixed(2)} V | Vpp: ${vpp.toStringAsFixed(2)} V | Vrms: ${vrms.toStringAsFixed(2)} V";
  }

  @override
  void dispose() {
    _socket?.close();
    _timerSimulacion?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF101622),
      body: SafeArea(
        child: Column(
          children: [
            // Barra de Título y Botones Principales
            Container(
              height: 48,
              color: const Color(0xFF17202C),
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Row(
                children: [
                  const Text("SCOPE RF 4MHz", style: TextStyle(color: Color(0xFF00C8FF), fontWeight: FontWeight.bold, fontSize: 13)),
                  const SizedBox(width: 8),
                  ElevatedButton(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: _simulando ? Colors.purple : const Color(0xFF283648),
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      minimumSize: const Size(50, 30),
                    ),
                    onPressed: _toggleSimulacion,
                    child: Text(_simulando ? "PARAR SIM" : "SIMULAR", style: const TextStyle(fontSize: 10)),
                  ),
                  const SizedBox(width: 6),
                  ElevatedButton(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: _conectado && !_simulando ? Colors.redAccent : const Color(0xFF008CDC),
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      minimumSize: const Size(50, 30),
                    ),
                    onPressed: _toggleUDP,
                    child: Text(_conectado && !_simulando ? "PARAR UDP" : "CONECTAR UDP", style: const TextStyle(fontSize: 10)),
                  ),
                  const SizedBox(width: 6),
                  ElevatedButton(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: _modoHold ? Colors.orange : const Color(0xFF283648),
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      minimumSize: const Size(40, 30),
                    ),
                    onPressed: () => setState(() => _modoHold = !_modoHold),
                    child: Text(_modoHold ? "RUN" : "HOLD", style: const TextStyle(fontSize: 10)),
                  ),
                  const Spacer(),
                  Text(_estadoTexto, style: TextStyle(color: _colorEstado, fontSize: 10, fontWeight: FontWeight.bold)),
                ],
              ),
            ),

            // Barra de Mediciones (Telemetría)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              color: const Color(0xFF0C1017),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(_telemetriaTexto, style: TextStyle(color: _coloresCH[_canalActivo], fontFamily: 'monospace', fontSize: 11, fontWeight: FontWeight.bold)),
                  Text("Base: ${_usPorDiv.toStringAsFixed(1)} us/div", style: const TextStyle(color: Colors.white70, fontFamily: 'monospace', fontSize: 11)),
                ],
              ),
            ),

            // Lienzo Gráfico con la Retícula
            Expanded(
              child: Container(
                margin: const EdgeInsets.all(4),
                color: const Color(0xFF161B22),
                child: CustomPaint(
                  painter: OsciloscopioPainter(
                    canales: _canales,
                    visible: _visible,
                    colores: _coloresCH,
                    vDiv: _vDiv,
                    offsetY: _offsetY,
                    canalActivo: _canalActivo,
                  ),
                  child: Container(),
                ),
              ),
            ),

            // Controles Inferiores (Canales, Escalas y Posición)
            Container(
              color: const Color(0xFF17202C),
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              child: Column(
                children: [
                  Row(
                    children: [
                      const Text("CANAL:", style: TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.bold)),
                      const SizedBox(width: 6),
                      DropdownButton<int>(
                        value: _canalActivo,
                        dropdownColor: const Color(0xFF202C3D),
                        style: TextStyle(color: _coloresCH[_canalActivo], fontWeight: FontWeight.bold, fontSize: 11),
                        items: const [
                          DropdownMenuItem(value: 0, child: Text("CH1 (Azul)")),
                          DropdownMenuItem(value: 1, child: Text("CH2 (Ámbar)")),
                          DropdownMenuItem(value: 2, child: Text("CH3 (Rojo)")),
                        ],
                        onChanged: (v) => setState(() => _canalActivo = v!),
                      ),
                      const Spacer(),
                      for (int c = 0; c < 3; c++) ...[
                        Text("CH${c + 1}", style: TextStyle(color: _coloresCH[c], fontSize: 10, fontWeight: FontWeight.bold)),
                        Checkbox(
                          value: _visible[c],
                          activeColor: _coloresCH[c],
                          onChanged: (val) => setState(() => _visible[c] = val!),
                        ),
                      ],
                    ],
                  ),
                  Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text("V/DIV: ${_vDiv[_canalActivo].toStringAsFixed(1)} V", style: const TextStyle(color: Colors.white70, fontSize: 10)),
                            Slider(
                              value: _vDiv[_canalActivo],
                              min: 0.2,
                              max: 5.0,
                              divisions: 24,
                              activeColor: _coloresCH[_canalActivo],
                              onChanged: (v) => setState(() => _vDiv[_canalActivo] = v),
                            ),
                          ],
                        ),
                      ),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text("POSICIÓN Y: ${_offsetY[_canalActivo].toStringAsFixed(1)}", style: const TextStyle(color: Colors.white70, fontSize: 10)),
                            Slider(
                              value: _offsetY[_canalActivo],
                              min: -4.0,
                              max: 4.0,
                              divisions: 16,
                              activeColor: Colors.white70,
                              onChanged: (v) => setState(() => _offsetY[_canalActivo] = v),
                            ),
                          ],
                        ),
                      ),
                    ],
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

// Pintor de la pantalla gráfica
class OsciloscopioPainter extends CustomPainter {
  final List<List<double>> canales;
  final List<bool> visible;
  final List<Color> colores;
  final List<double> vDiv;
  final List<double> offsetY;
  final int canalActivo;

  OsciloscopioPainter({
    required this.canales,
    required this.visible,
    required this.colores,
    required this.vDiv,
    required this.offsetY,
    required this.canalActivo,
  });

  @override
  void paint(Canvas canvas, Size size) {
    const double mL = 34.0, mR = 8.0, mT = 8.0, mB = 8.0;
    final rGrid = Rect.fromLTWH(mL, mT, size.width - mL - mR, size.height - mT - mB);

    // Fondo del osciloscopio
    canvas.drawRect(rGrid, Paint()..color = const Color(0xFF141922));

    double anchoC = rGrid.width / 10.0;
    double altoC = rGrid.height / 8.0;

    // Retícula 10x8
    final pGrid = Paint()..color = const Color(0xFF263342)..strokeWidth = 1.0;
    for (int i = 0; i <= 10; i++) {
      canvas.drawLine(Offset(rGrid.left + i * anchoC, rGrid.top), Offset(rGrid.left + i * anchoC, rGrid.bottom), pGrid);
    }
    for (int i = 0; i <= 8; i++) {
      canvas.drawLine(Offset(rGrid.left, rGrid.top + i * altoC), Offset(rGrid.right, rGrid.top + i * altoC), pGrid);
    }

    // Ejes centrales de referencia
    double yCenter = rGrid.top + 4 * altoC;
    double xCenter = rGrid.left + 5 * anchoC;
    final pEjes = Paint()..color = const Color(0xFF4C617A)..strokeWidth = 1.2..style = PaintingStyle.stroke;
    canvas.drawLine(Offset(rGrid.left, yCenter), Offset(rGrid.right, yCenter), pEjes);
    canvas.drawLine(Offset(xCenter, rGrid.top), Offset(xCenter, rGrid.bottom), pEjes);
    canvas.drawRect(rGrid, pEjes);

    // Flechas indicadoras de tierra (GND) a la izquierda
    for (int ch = 0; ch < 3; ch++) {
      double yGnd = (yCenter - offsetY[ch] * altoC).clamp(rGrid.top, rGrid.bottom);
      final pathF = Path()
        ..moveTo(mL - 18, yGnd - 5)
        ..lineTo(mL - 2, yGnd)
        ..lineTo(mL - 18, yGnd + 5)
        ..close();
      canvas.drawPath(pathF, Paint()..color = colores[ch]);
    }

    // Dibujo de las señales
    const int ptsVisibles = 300;
    for (int ch = 0; ch < 3; ch++) {
      if (!visible[ch] || canales[ch].length < 2) continue;

      int total = canales[ch].length;
      int inicio = max(0, total - ptsVisibles);
      int cant = total - inicio;

      final path = Path();
      for (int i = 0; i < cant; i++) {
        double x = rGrid.left + (i / (cant - 1)) * rGrid.width;
        double v = canales[ch][inicio + i];
        double y = yCenter - (offsetY[ch] * altoC) - ((v / vDiv[ch]) * altoC);

        if (i == 0) path.moveTo(x, y); else path.lineTo(x, y);
      }
      canvas.drawPath(path, Paint()..color = colores[ch]..strokeWidth = (ch == canalActivo ? 2.2 : 1.4)..style = PaintingStyle.stroke);
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => true;
}
