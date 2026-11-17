import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

const _discoveryPort = 43870;
const _transferPort = 43871;
const _maxTransferBytes = 2 * 1024 * 1024 * 1024;
const _multicastChannel =
    MethodChannel('io.github.lizcanoskr.aerodrop/multicast');

void main() {
  runApp(const AeroDropApp());
}

class AeroDropApp extends StatelessWidget {
  const AeroDropApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'AeroDrop',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xff4468e8),
          brightness: Brightness.light,
        ),
        useMaterial3: true,
      ),
      home: const HomePage(),
    );
  }
}

class Peer {
  const Peer({
    required this.id,
    required this.name,
    required this.address,
    required this.port,
  });

  final String id;
  final String name;
  final String address;
  final int port;
}

class IncomingTransfer {
  IncomingTransfer({
    required this.name,
    required this.bytes,
    required this._decision,
  });

  final String name;
  final int bytes;
  final Completer<bool> _decision;

  void accept() {
    if (!_decision.isCompleted) _decision.complete(true);
  }

  void reject() {
    if (!_decision.isCompleted) _decision.complete(false);
  }
}

class NearbyService {
  NearbyService() : deviceId = _randomHex(12);

  final String deviceId;
  final Map<String, Peer> _peers = {};
  final StreamController<List<Peer>> _peersController =
      StreamController<List<Peer>>.broadcast();
  final StreamController<IncomingTransfer> _incomingController =
      StreamController<IncomingTransfer>.broadcast();

  RawDatagramSocket? _discoverySocket;
  HttpServer? _server;
  Timer? _advertiseTimer;
  Timer? _expireTimer;
  String? _receiveCode;
  bool _closed = false;

  Stream<List<Peer>> get peers => _peersController.stream;
  Stream<IncomingTransfer> get incoming => _incomingController.stream;
  bool get isReceiving => _server != null;
  String? get receiveCode => _receiveCode;

  Future<void> start() async {
    try {
      if (Platform.isAndroid) {
        await _multicastChannel.invokeMethod<void>('acquire');
      }
      _discoverySocket = await RawDatagramSocket.bind(
        InternetAddress.anyIPv4,
        _discoveryPort,
        reuseAddress: true,
        reusePort: true,
      );
      _discoverySocket!.broadcastEnabled = true;
      _discoverySocket!.listen(_readDiscovery);
      _expireTimer = Timer.periodic(const Duration(seconds: 4), (_) {
        final cutoff = DateTime.now().subtract(const Duration(seconds: 12));
        _peers.removeWhere((id, _) {
          final expired = peerSeenAt[id]!.isBefore(cutoff);
          if (expired) peerSeenAt.remove(id);
          return expired;
        });
        _publishPeers();
      });
    } on SocketException catch (error) {
      throw StateError('No se pudo iniciar el descubrimiento: ${error.message}');
    }
  }

  final Map<String, DateTime> peerSeenAt = {};

  void _readDiscovery(RawSocketEvent event) {
    if (event != RawSocketEvent.read) return;
    final socket = _discoverySocket;
    if (socket == null) return;

    Datagram? datagram;
    while ((datagram = socket.receive()) != null) {
      try {
        final message =
            jsonDecode(utf8.decode(datagram!.data)) as Map<String, dynamic>;
        if (message['service'] != 'aerodrop' ||
            message['id'] == deviceId ||
            message['name'] is! String ||
            message['port'] != _transferPort) {
          continue;
        }
        final peer = Peer(
          id: message['id'] as String,
          name: (message['name'] as String).trim().isEmpty
              ? 'Dispositivo AeroDrop'
              : message['name'] as String,
          address: datagram.address.address,
          port: _transferPort,
        );
        _peers[peer.id] = peer;
        peerSeenAt[peer.id] = DateTime.now();
        _publishPeers();
      } on FormatException {
        // Ignore unrelated datagrams on the discovery port.
      } on TypeError {
        // Ignore malformed discovery messages.
      }
    }
  }

  void _publishPeers() {
    if (!_peersController.isClosed) {
      _peersController.add(List<Peer>.unmodifiable(_peers.values));
    }
  }

  Future<void> startReceiving() async {
    if (_server != null) return;
    final server = await HttpServer.bind(InternetAddress.anyIPv4, _transferPort);
    _server = server;
    _receiveCode = (Random.secure().nextInt(900000) + 100000).toString();
    server.listen(_handleUpload);
    _advertiseTimer = Timer.periodic(
      const Duration(seconds: 2),
      (_) => _announce(),
    );
    _announce();
  }

  Future<void> stopReceiving() async {
    _advertiseTimer?.cancel();
    _advertiseTimer = null;
    _receiveCode = null;
    final server = _server;
    _server = null;
    await server?.close(force: true);
  }

  void _announce() {
    final socket = _discoverySocket;
    if (socket == null || _receiveCode == null || _closed) return;
    final message = utf8.encode(jsonEncode({
      'service': 'aerodrop',
      'id': deviceId,
      'name': Platform.localHostname,
      'port': _transferPort,
    }));
    try {
      socket.send(message, InternetAddress('255.255.255.255'), _discoveryPort);
    } on SocketException {
      // Discovery is best-effort; the receive server remains available.
    }
  }

  Future<void> _handleUpload(HttpRequest request) async {
    if (request.method != 'POST' || request.uri.path != '/upload') {
      request.response.statusCode = HttpStatus.notFound;
      await request.response.close();
      return;
    }
    if (request.headers.value('x-aerodrop-code') != _receiveCode) {
      request.response.statusCode = HttpStatus.forbidden;
      await request.response.close();
      return;
    }
    final length = request.contentLength;
    if (length < 0 || length > _maxTransferBytes) {
      request.response.statusCode = HttpStatus.requestEntityTooLarge;
      await request.response.close();
      return;
    }
    final encodedName = request.headers.value('x-aerodrop-name');
    final name = _decodeName(encodedName);
    if (name == null) {
      request.response.statusCode = HttpStatus.badRequest;
      await request.response.close();
      return;
    }

    final transfer = IncomingTransfer(
      name: name,
      bytes: length,
      _decision: Completer<bool>(),
    );
    _incomingController.add(transfer);
    final accepted = await transfer._decision.future.timeout(
      const Duration(seconds: 90),
      onTimeout: () => false,
    );
    if (!accepted) {
      request.response.statusCode = HttpStatus.forbidden;
      await request.response.close();
      return;
    }

    try {
      final directory = await getApplicationDocumentsDirectory();
      final output = await _createIncomingFile(directory.path, name);
      await request.pipe(output.openWrite());
      request.response.statusCode = HttpStatus.ok;
      request.response.write('ok');
      await request.response.close();
    } on IOException catch (error) {
      stderr.writeln('AeroDrop could not save an incoming file: $error');
      if (!request.response.headersSent) {
        request.response.statusCode = HttpStatus.internalServerError;
        await request.response.close();
      }
    } on Exception catch (error) {
      stderr.writeln('AeroDrop could not handle an incoming file: $error');
      if (!request.response.headersSent) {
        request.response.statusCode = HttpStatus.internalServerError;
        await request.response.close();
      }
    }
  }

  Future<File> _createIncomingFile(String directory, String name) async {
    var candidate = '$directory${Platform.pathSeparator}$name';
    var counter = 1;
    while (true) {
      final file = File(candidate);
      try {
        await file.create(recursive: true, exclusive: true);
        return file;
      } on FileSystemException {
        if (!await file.exists()) rethrow;
      }
      final dot = name.lastIndexOf('.');
      final stem = dot > 0 ? name.substring(0, dot) : name;
      final extension = dot > 0 ? name.substring(dot) : '';
      candidate =
          '$directory${Platform.pathSeparator}$stem ($counter)$extension';
      counter++;
    }
  }

  Future<bool> sendFile(Peer peer, String code, File file) async {
    final length = await file.length();
    if (length > _maxTransferBytes) {
      throw StateError('El tamaño máximo por archivo es 2 GB.');
    }
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 8);
    try {
      final request = await client.postUrl(
        Uri(scheme: 'http', host: peer.address, port: peer.port, path: '/upload'),
      );
      request.headers
        ..set('content-type', 'application/octet-stream')
        ..set('content-length', length)
        ..set('x-aerodrop-code', code)
        ..set('x-aerodrop-name', base64Url.encode(utf8.encode(file.uri.pathSegments.last)));
      await request.addStream(file.openRead());
      final response = await request.close().timeout(
        const Duration(minutes: 10),
      );
      await response.drain<void>();
      return response.statusCode == HttpStatus.ok;
    } finally {
      client.close(force: true);
    }
  }

  static String? _decodeName(String? encoded) {
    if (encoded == null) return null;
    try {
      var name = utf8.decode(base64Url.decode(encoded));
      name = name.replaceAll('\\', '/').split('/').last;
      name = name.replaceAll(RegExp(r'[\x00-\x1f]'), '_').trim();
      if (name.isEmpty || name == '.' || name == '..') return null;
      return name;
    } on FormatException {
      return null;
    }
  }

  Future<void> dispose() async {
    _closed = true;
    await stopReceiving();
    _expireTimer?.cancel();
    _discoverySocket?.close();
    if (Platform.isAndroid) {
      await _multicastChannel.invokeMethod<void>('release');
    }
    await _peersController.close();
    await _incomingController.close();
  }

  static String _randomHex(int bytes) {
    final random = Random.secure();
    return List<int>.generate(bytes, (_) => random.nextInt(256))
        .map((value) => value.toRadixString(16).padLeft(2, '0'))
        .join();
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final NearbyService _service = NearbyService();
  final TextEditingController _codeController = TextEditingController();
  StreamSubscription<List<Peer>>? _peerSubscription;
  StreamSubscription<IncomingTransfer>? _incomingSubscription;
  List<Peer> _peers = [];
  String _status = 'Buscando dispositivos cercanos…';
  bool _receiving = false;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _start();
  }

  Future<void> _start() async {
    try {
      await _service.start();
      _peerSubscription = _service.peers.listen((peers) {
        if (mounted) setState(() => _peers = peers);
      });
      _incomingSubscription = _service.incoming.listen(_askToReceive);
      if (mounted) setState(() => _status = 'AeroDrop está listo');
    } on StateError catch (error) {
      if (mounted) setState(() => _status = error.message);
    } on SocketException catch (error) {
      if (mounted) setState(() => _status = error.message);
    } on Exception catch (error) {
      if (mounted) setState(() => _status = error.toString());
    }
  }

  Future<void> _toggleReceiving(bool enabled) async {
    try {
      if (enabled) {
        await _service.startReceiving();
      } else {
        await _service.stopReceiving();
      }
      if (mounted) setState(() => _receiving = enabled);
    } on SocketException catch (error) {
      if (mounted) {
        setState(() => _status = 'No se pudo cambiar el modo de recepción: $error');
      }
    } on HttpException catch (error) {
      if (mounted) {
        setState(() => _status = 'No se pudo cambiar el modo de recepción: $error');
      }
    }
  }

  Future<void> _askToReceive(IncomingTransfer transfer) async {
    if (!mounted) {
      transfer.reject();
      return;
    }
    final accepted = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        title: const Text('Transferencia entrante'),
        content: Text(
          '${transfer.name}\n${_formatBytes(transfer.bytes)}\n\n'
          '¿Quieres guardar este archivo?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Rechazar'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Aceptar'),
          ),
        ],
      ),
    );
    if (accepted == true) {
      transfer.accept();
    } else {
      transfer.reject();
    }
  }

  Future<void> _sendTo(Peer peer) async {
    final code = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Enviar a ${peer.name}'),
        content: TextField(
          controller: _codeController,
          autofocus: true,
          keyboardType: TextInputType.number,
          maxLength: 6,
          decoration: const InputDecoration(
            labelText: 'Código de recepción',
            hintText: '6 dígitos',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, _codeController.text.trim()),
            child: const Text('Continuar'),
          ),
        ],
      ),
    );
    _codeController.clear();
    if (code == null || code.length != 6) return;

    final result = await FilePicker.platform.pickFiles();
    final path = result?.files.single.path;
    if (path == null) {
      if (mounted) setState(() => _status = 'No se pudo acceder al archivo elegido.');
      return;
    }
    if (mounted) setState(() => _busy = true);
    try {
      final sent = await _service.sendFile(peer, code, File(path));
      if (mounted) {
        setState(() => _status =
            sent ? 'Archivo enviado a ${peer.name}' : 'El receptor rechazó el envío.');
      }
    } on StateError catch (error) {
      if (mounted) setState(() => _status = error.message);
    } on IOException catch (error) {
      if (mounted) setState(() => _status = 'No se pudo enviar el archivo: $error');
    } on TimeoutException catch (error) {
      if (mounted) setState(() => _status = 'La transferencia agotó el tiempo: $error');
    } on Exception catch (error) {
      if (mounted) setState(() => _status = 'No se pudo enviar el archivo: $error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  void dispose() {
    if (_peerSubscription != null) unawaited(_peerSubscription!.cancel());
    if (_incomingSubscription != null) {
      unawaited(_incomingSubscription!.cancel());
    }
    unawaited(_service.dispose());
    _codeController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('AeroDrop'),
        centerTitle: false,
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 16),
            child: Icon(
              Icons.circle,
              size: 12,
              color: _receiving ? Colors.green : theme.colorScheme.outline,
            ),
          ),
        ],
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 720),
          child: ListView(
            padding: const EdgeInsets.all(24),
            children: [
              Text('Compartir cerca, sin complicaciones',
                  style: theme.textTheme.headlineSmall),
              const SizedBox(height: 8),
              Text(_status, style: theme.textTheme.bodyMedium),
              const SizedBox(height: 24),
              Card(
                child: SwitchListTile(
                  value: _receiving,
                  onChanged: _busy ? null : _toggleReceiving,
                  title: const Text('Listo para recibir'),
                  subtitle: Text(
                    _receiving
                        ? 'Código: ${_service.receiveCode ?? "…"} · Mantén AeroDrop abierto'
                        : 'Actívalo para aparecer en otros dispositivos',
                  ),
                  secondary: const Icon(Icons.download_rounded),
                ),
              ),
              if (_receiving)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Text(
                    'Solo en una red Wi-Fi de confianza: esta beta no cifra las transferencias.',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.error,
                    ),
                  ),
                ),
              const SizedBox(height: 28),
              Row(
                children: [
                  Text('Dispositivos cercanos',
                      style: theme.textTheme.titleLarge),
                  const Spacer(),
                  IconButton(
                    tooltip: 'Actualizar lista',
                    onPressed: () => setState(() {}),
                    icon: const Icon(Icons.refresh),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              if (_peers.isEmpty)
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      children: [
                        const Icon(Icons.devices_other, size: 36),
                        const SizedBox(height: 12),
                        const Text('No hay dispositivos disponibles'),
                        const SizedBox(height: 4),
                        Text(
                          'Conecta ambos dispositivos a la misma Wi-Fi y activa la recepción en el otro.',
                          textAlign: TextAlign.center,
                          style: theme.textTheme.bodySmall,
                        ),
                      ],
                    ),
                  ),
                )
              else
                ..._peers.map(
                  (peer) => Card(
                    child: ListTile(
                      leading: const CircleAvatar(
                        child: Icon(Icons.devices),
                      ),
                      title: Text(peer.name),
                      subtitle: Text(peer.address),
                      trailing: FilledButton.tonal(
                        onPressed: _busy ? null : () => _sendTo(peer),
                        child: const Text('Enviar archivo'),
                      ),
                    ),
                  ),
                ),
              const SizedBox(height: 24),
              Text(
                'La beta envía archivos individuales. El acceso a carpetas y el cifrado llegarán en versiones futuras.',
                style: theme.textTheme.bodySmall,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

String _formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  if (bytes < 1024 * 1024 * 1024) {
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
  return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
}
