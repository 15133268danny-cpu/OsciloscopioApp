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

class MarcadorPunto {
  final int id;
  final int canal;
  final double tiempoSeg;
  final double voltaje;

  MarcadorPunto({
    required this.id,
    required this.canal,
    required this.tiempoSeg,
    required this.voltaje,
  });
}

class OsciloscopioApp extends StatefulWidget {
  const OsciloscopioApp({super.key});

  @override
  State<OsciloscopioApp> createState() => _OsciloscopioAppState();
}

class _OsciloscopioAppState extends State<OsciloscopioApp> {
  RawDatagramSocket? _socket;
  Timer? _timerSimulacion;
  bool _conectado = false;
  bool _simulando = false;
  bool _modoHold = false;
  bool _mostrarTabla = false;
  String _estadoTexto = "DESCONECTADO";
  Color _colorEstado = const Color(0xFF8A99AD);

  // Búfer de datos
  static const int capacidadMax = 2000;
  final List<List<double>> _canales = [[], [], []];
  double _tiempoAcumulado = 0.0;
  final double _dtSimulado = 0.000000025; // 25 ns = 40 MSPS para señales > 4 MHz

  // Parámetros por canal
  final List<double> _vDiv = [1.0, 1.0, 1.0];
  final List<double> _offsetY = [-2.0, 0.0, 2.0];
  final List<bool> _visible = [true, true, true];
  final List<bool> _invertir = [false, false, false];
  final List<String> _acople = ["DC", "DC", "DC"];
  int _canalActivo = 0;

  // Base de tiempo horizontal
  double _usPorDiv = 0.5;

  // Colores idénticos a Visual C#
  final List<Color> _coloresCH = const [
    Color(0xFF00C8FF), // CH1 Cian
    Color(0xFFFFA000), // CH2 Ámbar
    Color(0xFFFF4141), // CH3 Rojo
  ];

  final List<MarcadorPunto> _marcadores = [];
  int _contadorMarcadores = 1;

  String _telemetriaV = "CH1: 0.00 V | Vpp: 0.00 V | Vrms: 0.00 V";
  String _telemetriaT = "Base: 0.50 us/div | Muestras: 0";
  String _deltaMarcadores = "";

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
        for (int k = 0; k < 60; k++) {
          _tiempoAcumulado += _dtSimulado;
          double v1 = 1.65 + 1.35 * sin(2.0 * pi * 4500000.0 * _tiempoAcumulado);
          double v2 = 1.65 + 1.10 * sin(2.0 * pi * 1000000.0 * _tiempoAcumulado);
          double v3 = (sin(2.0 * pi * 2250000.0 * _tiempoAcumulado) > 0) ? 3.3 : 0.0;

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
        _estadoTexto = "ERROR SOCKET";
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
        for (int k = 1; k <= 6; k++) {
          chk ^= data[i + k];
        }

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
          i += 8;
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
    for (double v in m) {
      sumaCuad += v * v;
    }
    double vrms = sqrt(sumaCuad / m.length);

    _telemetriaV = "CH${ch + 1}: ${m.last.toStringAsFixed(2)} V | Vpp: ${vpp.toStringAsFixed(2)} V | Vrms: ${vrms.toStringAsFixed(2)} V";
    _telemetriaT = "Base: ${_usPorDiv.toStringAsFixed(2)} us/div | Muestras: ${m.length}";

    if (_marcadores.length >= 2) {
      var m1 = _marcadores[_marcadores.length - 2];
      var m2 = _marcadores[_marcadores.length - 1];
      double dt = (m2.tiempoSeg - m1.tiempoSeg).abs();
      double dv = (m2.voltaje - m1.voltaje).abs();
      double f = (dt > 0) ? (1.0 / dt) : 0;
      _deltaMarcadores = "ΔT: ${(dt * 1e6).toStringAsFixed(2)} us | ΔV: ${dv.toStringAsFixed(2)} V | f: ${(f / 1e6).toStringAsFixed(2)} MHz";
    } else {
      _deltaMarcadores = "";
    }
  }

  void _colocarMarcador(Offset localPos, Size size) {
    if (!_modoHold) return;
    int ch = _canalActivo;
    if (_canales[ch].length < 2) return;

    int total = _canales[ch].length;
    int rel = ((localPos.dx / size.width) * total).toInt().clamp(0, total - 1);

    setState(() {
      _marcadores.add(MarcadorPunto(
        id: _contadorMarcadores++,
        canal: ch,
        tiempoSeg: rel * _dtSimulado,
        voltaje: _canales[ch][rel],
      ));
    });
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
            // BARRA SUPERIOR
            Container(
              height: 48,
              color: const Color(0xFF17202C),
              padding: const EdgeInsets.symmetric(horizontal: 6),
              child: Row(
                children: [
                  const Text("SCOPE RF", style: TextStyle(color: Color(0xFF00C8FF), fontWeight: FontWeight.bold, fontSize: 12)),
                  const SizedBox(width: 6),
                  ElevatedButton(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: _simulando ? Colors.purple : const Color(0xFF283648),
                      padding: const EdgeInsets.symmetric(horizontal: 6),
                      minimumSize: const Size(44, 28),
                    ),
                    onPressed: _toggleSimulacion,
                    child: Text(_simulando ? "PARAR" : "SIMULAR", style: const TextStyle(fontSize: 9)),
                  ),
                  const SizedBox(width: 4),
                  ElevatedButton(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: _conectado && !_simulando ? Colors.redAccent : const Color(0xFF008CDC),
                      padding: const EdgeInsets.symmetric(horizontal: 6),
                      minimumSize: const Size(44, 28),
                    ),
                    onPressed: _toggleUDP,
                    child: Text(_conectado && !_simulando ? "STOP" : "UDP", style: const TextStyle(fontSize: 9)),
                  ),
                  const SizedBox(width: 4),
                  ElevatedButton(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: _modoHold ? Colors.orange : const Color(0xFF283648),
                      padding: const EdgeInsets.symmetric(horizontal: 6),
                      minimumSize: const Size(40, 28),
                    ),
                    onPressed: () => setState(() => _modoHold = !_modoHold),
                    child: Text(_modoHold ? "RUN" : "HOLD", style: const TextStyle(fontSize: 9)),
                  ),
                  const SizedBox(width: 4),
                  IconButton(
                    icon: Icon(_mostrarTabla ? Icons.show_chart : Icons.table_chart, color: Colors.white, size: 20),
                    onPressed: () => setState(() => _mostrarTabla = !_mostrarTabla),
                  ),
                  ElevatedButton(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFFB3261E),
                      padding: const EdgeInsets.symmetric(horizontal: 6),
                      minimumSize: const Size(38, 28),
                    ),
                    onPressed: () {
                      for (var c in _canales) {
                        c.clear();
                      }
                      _marcadores.clear();
                      setState(() {});
                    },
                    child: const Text("RESET", style: TextStyle(fontSize: 9)),
                  ),
                  const Spacer(),
                  Text(_estadoTexto, style: TextStyle(color: _colorEstado, fontSize: 9, fontWeight: FontWeight.bold)),
                ],
              ),
            ),

            // HUD TELEMETRÍA
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              color: const Color(0xFF0C1017),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(_telemetriaV, style: TextStyle(color: _coloresCH[_canalActivo], fontFamily: 'monospace', fontSize: 10, fontWeight: FontWeight.bold)),
                      Text(_telemetriaT, style: const TextStyle(color: Colors.white70, fontFamily: 'monospace', fontSize: 10)),
                    ],
                  ),
                  if (_deltaMarcadores.isNotEmpty)
                    Text(_deltaMarcadores, style: const TextStyle(color: Colors.yellowAccent, fontFamily: 'monospace', fontSize: 10)),
                ],
              ),
            ),

            // GRÁFICA / TABLA
            Expanded(
              child: _mostrarTabla
                  ? _construirTabla()
                  : LayoutBuilder(
                      builder: (context, constraints) {
                        return GestureDetector(
                          onTapUp: (details) => _colocarMarcador(details.localPosition, Size(constraints.maxWidth, constraints.maxHeight)),
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
                                acople: _acople,
                                invertir: _invertir,
                                canalActivo: _canalActivo,
                                marcadores: _marcadores,
                              ),
                              child: Container(),
                            ),
                          ),
                        );
                      },
                    ),
            ),

            // CONTROLES
            _construirControles(),
          ],
        ),
      ),
    );
  }

  Widget _construirTabla() {
    int total = _canales[0].length;
    int inicio = max(0, total - 40);
    return Container(
      color: const Color(0xFF161B22),
      child: ListView.builder(
        itemCount: total - inicio,
        itemBuilder: (context, idx) {
          int i = inicio + idx;
          double t = i * _dtSimulado * 1e6;
          return Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceAround,
              children: [
                Text("${t.toStringAsFixed(2)} us", style: const TextStyle(color: Colors.white70, fontFamily: 'monospace', fontSize: 10)),
                Text("CH1: ${_canales[0][i].toStringAsFixed(2)}V", style: TextStyle(color: _coloresCH[0], fontFamily: 'monospace', fontSize: 10)),
                Text("CH2: ${_canales[1][i].toStringAsFixed(2)}V", style: TextStyle(color: _coloresCH[1], fontFamily: 'monospace', fontSize: 10)),
                Text("CH3: ${_canales[2][i].toStringAsFixed(2)}V", style: TextStyle(color: _coloresCH[2], fontFamily: 'monospace', fontSize: 10)),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _construirControles() {
    return Container(
      color: const Color(0xFF17202C),
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
      child: Column(
        children: [
          Row(
            children: [
              DropdownButton<int>(
                value: _canalActivo,
                dropdownColor: const Color(0xFF202C3D),
                style: TextStyle(color: _coloresCH[_canalActivo], fontWeight: FontWeight.bold, fontSize: 11),
                items: const [
                  DropdownMenuItem(value: 0, child: Text("CH1")),
                  DropdownMenuItem(value: 1, child: Text("CH2")),
                  DropdownMenuItem(value: 2, child: Text("CH3")),
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
              ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: _invertir[_canalActivo] ? Colors.orange : const Color(0xFF283648),
                  padding: const EdgeInsets.symmetric(horizontal: 6),
                  minimumSize: const Size(36, 26),
                ),
                onPressed: () => setState(() => _invertir[_canalActivo] = !_invertir[_canalActivo]),
                child: const Text("INV", style: TextStyle(fontSize: 9)),
              ),
              const SizedBox(width: 4),
              DropdownButton<String>(
                value: _acople[_canalActivo],
                dropdownColor: const Color(0xFF202C3D),
                style: const TextStyle(color: Colors.white, fontSize: 10),
                items: const [
                  DropdownMenuItem(value: "DC", child: Text("DC")),
                  DropdownMenuItem(value: "AC", child: Text("AC")),
                  DropdownMenuItem(value: "GND", child: Text("GND")),
                ],
                onChanged: (v) => setState(() => _acople[_canalActivo] = v!),
              ),
            ],
          ),
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text("V/DIV: ${_vDiv[_canalActivo].toStringAsFixed(1)}V", style: const TextStyle(color: Colors.white70, fontSize: 9)),
                    Slider(
                      value: _vDiv[_canalActivo],
                      min: 0.1,
                      max: 5.0,
                      divisions: 49,
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
                    Text("OFFSET: ${_offsetY[_canalActivo].toStringAsFixed(1)}", style: const TextStyle(color: Colors.white70, fontSize: 9)),
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
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text("BASE T: ${_usPorDiv.toStringAsFixed(2)} us", style: const TextStyle(color: Colors.cyanAccent, fontSize: 9)),
                    Slider(
                      value: _usPorDiv,
                      min: 0.1,
                      max: 5.0,
                      divisions: 49,
                      activeColor: Colors.cyanAccent,
                      onChanged: (v) => setState(() => _usPorDiv = v),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class OsciloscopioPainter extends CustomPainter {
  final List<List<double>> canales;
  final List<bool> visible;
  final List<Color> colores;
  final List<double> vDiv;
  final List<double> offsetY;
  final List<String> acople;
  final List<bool> invertir;
  final int canalActivo;
  final List<MarcadorPunto> marcadores;

  OsciloscopioPainter({
    required this.canales,
    required this.visible,
    required this.colores,
    required this.vDiv,
    required this.offsetY,
    required this.acople,
    required this.invertir,
    required this.canalActivo,
    required this.marcadores,
  });

  @override
  void paint(Canvas canvas, Size size) {
    const double mL = 34.0, mR = 8.0, mT = 8.0, mB = 8.0;
    final rGrid = Rect.fromLTWH(mL, mT, size.width - mL - mR, size.height - mT - mB);

    canvas.drawRect(rGrid, Paint()..color = const Color(0xFF141922));

    double anchoC = rGrid.width / 10.0;
    double altoC = rGrid.height / 8.0;

    final pGrid = Paint()..color = const Color(0xFF263342)..strokeWidth = 1.0;
    for (int i = 0; i <= 10; i++) {
      canvas.drawLine(Offset(rGrid.left + i * anchoC, rGrid.top), Offset(rGrid.left + i * anchoC, rGrid.bottom), pGrid);
    }
    for (int i = 0; i <= 8; i++) {
      canvas.drawLine(Offset(rGrid.left, rGrid.top + i * altoC), Offset(rGrid.right, rGrid.top + i * altoC), pGrid);
    }

    double yCenter = rGrid.top + 4 * altoC;
    double xCenter = rGrid.left + 5 * anchoC;
    final pEjes = Paint()..color = const Color(0xFF4C617A)..strokeWidth = 1.2..style = PaintingStyle.stroke;
    canvas.drawLine(Offset(rGrid.left, yCenter), Offset(rGrid.right, yCenter), pEje