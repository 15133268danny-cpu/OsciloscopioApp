import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'package:flutter/material.dart';

void main() {
  runApp(const MaterialApp(
    debugShowCheckedModeBanner: false,
    home: OsciloscopioCompletoScreen(),
  ));
}

class MarcadorPunto {
  final int id;
  final int canal;
  final int indiceMuestra;
  final double tiempoSeg;
  final double voltaje;

  MarcadorPunto({
    required this.id,
    required this.canal,
    required this.indiceMuestra,
    required this.tiempoSeg,
    required this.voltaje,
  });
}

class OsciloscopioCompletoScreen extends StatefulWidget {
  const OsciloscopioCompletoScreen({Key? key}) : super(key: key);

  @override
  State<OsciloscopioCompletoScreen> createState() => _OsciloscopioCompletoScreenState();
}

class _OsciloscopioCompletoScreenState extends State<OsciloscopioCompletoScreen> {
  RawDatagramSocket? _socket;
  Timer? _timerSimulacion;
  bool _enEjecucion = false;
  bool _modoSimulacion = false;
  bool _modoHold = false;
  bool _mostrarTabla = false;
  String _estadoTexto = "DESCONECTADO";
  Color _colorEstado = const Color(0xFF8A99AD);

  // Búfer profundo de muestras (CH1, CH2, CH3)
  static const int capacidadBuffer = 20000;
  double _dtMuestra = 0.000000025; // 25 ns = 40 MSPS (Permite ver ondas de > 4 MHz)
  double _tiempoAcumulado = 0.0;
  final List<List<double>> _canales = [[], [], []];

  // Configuración individual por canal
  final List<double> _vDiv = [1.0, 1.0, 1.0];
  final List<double> _offsetY = [-2.0, 0.0, 2.0];
  final List<bool> _invertir = [false, false, false];
  final List<String> _acople = ["DC", "DC", "DC"];
  final List<bool> _visibilidad = [true, true, true];
  int _canalActivo = 0;

  // Base de tiempo (en microsegundos por división)
  double _usPorDiv = 0.5; // 0.5 us/div * 10 div = 5 us (Permite ver 20 ciclos de 4 MHz)
  double _desplazamientoUs = 0.0;

  // Marcadores de inspección
  final List<MarcadorPunto> _marcadores = [];
  int _contadorMarcadores = 1;

  final List<Color> _coloresCH = const [
    Color(0xFF00C8FF), // CH1 Cian
    Color(0xFFFFA000), // CH2 Ámbar
    Color(0xFFFF4141), // CH3 Rojo
  ];

  String _telemetriaVoltaje = "CH1: -- | Vpp: -- | Vmax: -- | Vrms: --";
  String _telemetriaTiempo = "T: -- | Frec: -- | Duty: --";
  String _deltaMarcadores = "";

  // --- MODO SIMULACIÓN INTERNA (4.5 MHz) ---
  void _toggleSimulacion() {
    if (_modoSimulacion) {
      _timerSimulacion?.cancel();
      setState(() {
        _modoSimulacion = false;
        _enEjecucion = false;
        _estadoTexto = "DESCONECTADO";
        _colorEstado = const Color(0xFF8A99AD);
      });
      return;
    }

    _desconectarUDP();
    _modoSimulacion = true;
    _enEjecucion = true;
    _dtMuestra = 0.000000025; // 40 MSPS
    _estadoTexto = "SIMULACIÓN 4.5 MHz";
    _colorEstado = const Color(0xFF00C8FF);

    _timerSimulacion = Timer.periodic(const Duration(milliseconds: 33), (t) {
      if (!_modoHold) {
        for (int k = 0; k < 120; k++) {
          _tiempoAcumulado += _dtMuestra;
          // CH1: Seno 4.5 MHz
          double v1 = 1.65 + 1.35 * sin(2.0 * pi * 4500000.0 * _tiempoAcumulado);
          // CH2: Rampa / Rizado 1.0 MHz
          double v2 = 1.65 + 1.10 * sin(2.0 * pi * 1000000.0 * _tiempoAcumulado);
          // CH3: Pulso RF digital 2.25 MHz
          double v3 = (sin(2.0 * pi * 2250000.0 * _tiempoAcumulado) > 0) ? 3.3 : 0.0;

          _canales[0].add(v1);
          _canales[1].add(v2);
          _canales[2].add(v3);
        }

        for (int c = 0; c < 3; c++) {
          if (_canales[c].length > capacidadBuffer) {
            _canales[c].removeRange(0, _canales[c].length - capacidadBuffer);
          }
        }
        _actualizarCalculos();
        setState(() {});
      }
    });
    setState(() {});
  }

  // --- RECEPTOR UDP ---
  Future<void> _toggleUDP() async {
    if (_enEjecucion && !_modoSimulacion) {
      _desconectarUDP();
      return;
    }
    if (_modoSimulacion) _toggleSimulacion();

    try {
      _socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 8888);
      setState(() {
        _enEjecucion = true;
        _estadoTexto = "UDP :8888 ACTIVO";
        _colorEstado = const Color(0xFF2ECC71);
      });

      _socket!.listen((event) {
        if (event == RawSocketEvent.read) {
          final dg = _socket!.receive();
          if (dg != null && !_modoHold) {
            _procesarPaqueteUDP(dg.data);
          }
        }
      });
    } catch (e) {
      setState(() {
        _enEjecucion = false;
        _estadoTexto = "ERROR DE SOCKET";
        _colorEstado = const Color(0xFFDC3C3C);
      });
    }
  }

  void _desconectarUDP() {
    _socket?.close();
    _socket = null;
    setState(() {
      _enEjecucion = false;
      _estadoTexto = "DESCONECTADO";
      _colorEstado = const Color(0xFF8A99AD);
    });
  }

  void _procesarPaqueteUDP(Uint8List data) {
    int i = 0;
    while (i <= data.length - 9) {
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
            if (_canales[c].length > capacidadBuffer) _canales[c].removeAt(0);
          }
          i += 9;
          continue;
        }
      }
      i++;
    }
    _actualizarCalculos();
    setState(() {});
  }

  void _actualizarCalculos() {
    int ch = _canalActivo;
    if (_canales[ch].length < 10) return;

    List<double> m = _canales[ch];
    double vmax = m.reduce(max);
    double vmin = m.reduce(min);
    double vpp = vmax - vmin;

    double suma = 0, sq = 0;
    for (double v in m) {
      suma += v;
      sq += v * v;
    }
    double vavg = suma / m.length;
    double vrms = sqrt(sq / m.length);

    _telemetriaVoltaje = "CH${ch + 1}: Vpp: ${vpp.toStringAsFixed(2)}V | Vmax: ${vmax.toStringAsFixed(2)}V | Vmin: ${vmin.toStringAsFixed(2)}V | Vrms: ${vrms.toStringAsFixed(2)}V";

    double periodo = 0;
    double mid = (vmax + vmin) / 2.0;
    int idx1 = -1, idx2 = -1;
    for (int k = m.length - 2; k > max(0, m.length - 800); k--) {
      if (m[k] <= mid && m[k + 1] > mid) {
        if (idx2 == -1) {
          idx2 = k;
        } else {
          idx1 = k;
          break;
        }
      }
    }

    if (idx1 != -1 && idx2 != -1) {
      periodo = (idx2 - idx1) * _dtMuestra;
      double frec = (periodo > 0) ? (1.0 / periodo) : 0;
      _telemetriaTiempo = "T: ${(periodo * 1e6).toStringAsFixed(2)} us | F: ${(frec / 1e6).toStringAsFixed(2)} MHz";
    } else {
      _telemetriaTiempo = "Muestras: ${m.length} | Base: ${_usPorDiv.toStringAsFixed(2)} us/div";
    }

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

  void _agregarMarcadorTáctil(Offset localPos, Size size) {
    if (!_modoHold) return;
    int ch = _canalActivo;
    int total = _canales[ch].length;
    if (total < 2) return;

    double puntosPantalla = (_usPorDiv * 10.0 * 1e-6) / _dtMuestra;
    int startIndex = max(0, total - puntosPantalla.toInt() - (_desplazamientoUs * 1e-6 / _dtMuestra).toInt());
    int rel = ((localPos.dx / size.width) * puntosPantalla).toInt();
    int absIdx = (startIndex + rel).clamp(0, total - 1);

    setState(() {
      _marcadores.add(MarcadorPunto(
        id: _contadorMarcadores++,
        canal: ch,
        indiceMuestra: absIdx,
        tiempoSeg: absIdx * _dtMuestra,
        voltaje: _canales[ch][absIdx],
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
            // ================= 1. BARRA SUPERIOR =================
            Container(
              height: 46,
              color: const Color(0xFF17202C),
              padding: const EdgeInsets.symmetric(horizontal: 6),
              child: Row(
                children: [
                  const Text("SCOPE RF", style: TextStyle(color: Color(0xFF00C8FF), fontWeight: FontWeight.bold, fontSize: 12)),
                  const SizedBox(width: 6),
                  ElevatedButton(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: _modoSimulacion ? Colors.purple : const Color(0xFF283648),
                      padding: const EdgeInsets.symmetric(horizontal: 6),
                      minimumSize: const Size(45, 28),
                    ),
                    onPressed: _toggleSimulacion,
                    child: Text(_modoSimulacion ? "SIM: ON" : "SIMULAR", style: const TextStyle(fontSize: 9)),
                  ),
                  const SizedBox(width: 4),
                  ElevatedButton(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: _enEjecucion && !_modoSimulacion ? Colors.redAccent : const Color(0xFF008CDC),
                      padding: const EdgeInsets.symmetric(horizontal: 6),
                      minimumSize: const Size(45, 28),
                    ),
                    onPressed: _toggleUDP,
                    child: Text(_enEjecucion && !_modoSimulacion ? "DESCONECTAR" : "UDP :8888", style: const TextStyle(fontSize: 9)),
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
                      for (var c in _canales) c.clear();
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

            // ================= 2. MINIMAPA HISTÓRICO GLOBAL =================
            GestureDetector(
              onHorizontalDragUpdate: (details) {
                if (_canales[_canalActivo].isEmpty) return;
                setState(() {
                  double factor = details.primaryDelta! / 300.0;
                  _desplazamientoUs += factor * (_canales[_canalActivo].length * _dtMuestra * 1e6);
                  _desplazamientoUs = _desplazamientoUs.clamp(0.0, 50000.0);
                });
              },
              child: Container(
                height: 24,
                color: const Color(0xFF1C2533),
                margin: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                child: CustomPaint(
                  painter: MinimapaPainter(
                    muestras: _canales[_canalActivo],
                    color: _coloresCH[_canalActivo],
                    usPorDiv: _usPorDiv,
                    desplazamientoUs: _desplazamientoUs,
                    dtMuestra: _dtMuestra,
                  ),
                ),
              ),
            ),

            // ================= 3. HUD DE TELEMETRÍA =================
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              color: const Color(0xFF0C1017),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(_telemetriaVoltaje, style: TextStyle(color: _coloresCH[_canalActivo], fontFamily: 'monospace', fontSize: 10, fontWeight: FontWeight.bold)),
                      Text(_telemetriaTiempo, style: const TextStyle(color: Colors.white70, fontFamily: 'monospace', fontSize: 10)),
                    ],
                  ),
                  if (_deltaMarcadores.isNotEmpty)
                    Text(_deltaMarcadores, style: const TextStyle(color: Colors.yellowAccent, fontFamily: 'monospace', fontSize: 10)),
                ],
              ),
            ),

            // ================= 4. LIENZO / TABLA =================
            Expanded(
              child: _mostrarTabla
                  ? _construirTabla()
                  : GestureDetector(
                      onTapUp: (details) => _agregarMarcadorTáctil(details.localPosition, MediaQuery.of(context).size),
                      child: Container(
                        margin: const EdgeInsets.all(4),
                        color: const Color(0xFF161B22),
                        child: CustomPaint(
                          painter: OsciloscopioPrincipalPainter(
                            canales: _canales,
                            visible: _visibilidad,
                            colores: _coloresCH,
                            vDiv: _vDiv,
                            offsetY: _offsetY,
                            invertir: _invertir,
                            acople: _acople,
                            usPorDiv: _usPorDiv,
                            desplazamientoUs: _desplazamientoUs,
                            dtMuestra: _dtMuestra,
                            canalActivo: _canalActivo,
                            marcadores: _marcadores,
                          ),
                          child: Container(),
                        ),
                      ),
                    ),
            ),

            // ================= 5. PANEL DE CONTROL TÁCTIL =================
            _construirControlesInferiores(),
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
          double t = i * _dtMuestra * 1e6;
          return Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceAround,
              children: [
                Text("${t.toStringAsFixed(2)} us", style: const TextStyle(color: Colors.white70, fontFamily: 'monospace', fontSize: 11)),
                Text("CH1: ${_canales[0][i].toStringAsFixed(2)}V", style: TextStyle(color: _coloresCH[0], fontFamily: 'monospace', fontSize: 11)),
                Text("CH2: ${_canales[1][i].toStringAsFixed(2)}V", style: TextStyle(color: _coloresCH[1], fontFamily: 'monospace', fontSize: 11)),
                Text("CH3: ${_canales[2][i].toStringAsFixed(2)}V", style: TextStyle(color: _coloresCH[2], fontFamily: 'monospace', fontSize: 11)),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _construirControlesInferiores() {
    return Container(
      color: const Color(0xFF17202C),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
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
                  value: _visibilidad[c],
                  activeColor: _coloresCH[c],
                  onChanged: (val) => setState(() => _visibilidad[c] = val!),
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
                    Text("V/DIV: ${_vDiv[_canalActivo].toStringAsFixed(2)}V", style: const TextStyle(color: Colors.white70, fontSize: 9)),
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
                    Text("OFFSET Y: ${_offsetY[_canalActivo].toStringAsFixed(