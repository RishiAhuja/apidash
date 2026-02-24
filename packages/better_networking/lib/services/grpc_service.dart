import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:fixnum/fixnum.dart';
import 'package:grpc/grpc.dart';
import 'package:protobuf/protobuf.dart';
import 'package:grpc_reflection/grpc_reflection.dart';

import '../models/grpc_request_model.dart';

/// Describes a single gRPC service discovered via reflection or descriptor.
class GrpcServiceInfo {
  final String serviceName;
  final List<GrpcMethodInfo> methods;

  const GrpcServiceInfo({required this.serviceName, required this.methods});
}

/// Describes a single gRPC method.
class GrpcMethodInfo {
  final String methodName;
  final String fullServiceName;
  final bool clientStreaming;
  final bool serverStreaming;
  final String inputTypeName;
  final String outputTypeName;

  const GrpcMethodInfo({
    required this.methodName,
    required this.fullServiceName,
    required this.clientStreaming,
    required this.serverStreaming,
    required this.inputTypeName,
    required this.outputTypeName,
  });

  String get fullPath => '/$fullServiceName/$methodName';

  GrpcCallType get callType {
    if (clientStreaming && serverStreaming) return GrpcCallType.bidirectional;
    if (clientStreaming) return GrpcCallType.clientStreaming;
    if (serverStreaming) return GrpcCallType.serverStreaming;
    return GrpcCallType.unary;
  }
}

/// Holds the complete type registry for describing gRPC message fields.
class GrpcTypeRegistry {
  final Map<String, DescriptorProto> _messageTypes = {};
  final Map<String, EnumDescriptorProto> _enumTypes = {};

  void registerFile(FileDescriptorProto file) {
    final packagePrefix = file.package.isNotEmpty ? '.${file.package}' : '';
    _registerMessages(file.messageType, packagePrefix);
    _registerEnums(file.enumType, packagePrefix);
  }

  void _registerMessages(List<DescriptorProto> messages, String prefix) {
    for (final msg in messages) {
      final fullName = '$prefix.${msg.name}';
      _messageTypes[fullName] = msg;
      _registerMessages(msg.nestedType, fullName);
      _registerEnums(msg.enumType, fullName);
    }
  }

  void _registerEnums(List<EnumDescriptorProto> enums, String prefix) {
    for (final e in enums) {
      final fullName = '$prefix.${e.name}';
      _enumTypes[fullName] = e;
    }
  }

  DescriptorProto? findMessage(String fullName) => _messageTypes[fullName];
  EnumDescriptorProto? findEnum(String fullName) => _enumTypes[fullName];
}

/// Result of a gRPC call.
class GrpcCallResult {
  final int? statusCode;
  final String? statusMessage;
  final Map<String, String> responseHeaders;
  final Map<String, String> responseTrailers;
  final List<Uint8List> responseMessages;
  final Duration? duration;
  final String? error;

  const GrpcCallResult({
    this.statusCode,
    this.statusMessage,
    this.responseHeaders = const {},
    this.responseTrailers = const {},
    this.responseMessages = const [],
    this.duration,
    this.error,
  });

  bool get isError => error != null || (statusCode != null && statusCode != 0);
}

/// Identity [ClientMethod] that passes raw bytes through without
/// serialization/deserialization.
ClientMethod<List<int>, List<int>> _rawMethod(String path) {
  return ClientMethod<List<int>, List<int>>(
    path,
    (bytes) => bytes,
    (bytes) => bytes,
  );
}

/// Manages a gRPC channel and performs reflection / invocations.
class GrpcClientManager {
  GrpcClientManager._();

  static final Map<String, GrpcClientManager> _instances = {};

  static GrpcClientManager getOrCreate(String requestId) {
    return _instances.putIfAbsent(requestId, () => GrpcClientManager._());
  }

  static void remove(String requestId) {
    final manager = _instances.remove(requestId);
    manager?._dispose();
  }

  ClientChannel? _channel;
  List<GrpcServiceInfo> _services = [];
  GrpcTypeRegistry? _typeRegistry;
  bool _isConnected = false;

  bool get isConnected => _isConnected && _channel != null;
  List<GrpcServiceInfo> get services => List.unmodifiable(_services);
  GrpcTypeRegistry? get typeRegistry => _typeRegistry;

  /// Connect to a gRPC server and discover services.
  Future<void> connect(GrpcRequestModel config) async {
    await _dispose();

    final host = config.host.trim();
    if (host.isEmpty) {
      throw const GrpcError.invalidArgument('Host cannot be empty');
    }

    _channel = ClientChannel(
      host,
      port: config.port,
      options: ChannelOptions(
        credentials: config.useTls
            ? const ChannelCredentials.secure()
            : const ChannelCredentials.insecure(),
        connectionTimeout: const Duration(seconds: 10),
      ),
    );

    if (config.useReflection) {
      await _discoverViaReflection();
    } else if (config.descriptorFileBytes != null) {
      _loadFromDescriptor(config.descriptorFileBytes!);
    }

    _isConnected = true;
  }

  /// Discover services via gRPC server reflection.
  Future<void> _discoverViaReflection() async {
    final reflectionClient = ServerReflectionClient(_channel!);

    // List all services
    final listRequest = ServerReflectionRequest()..listServices = '';

    final responseStream = reflectionClient.serverReflectionInfo(
      Stream.value(listRequest),
    );

    final listResponse = await responseStream.first;
    final serviceNames = listResponse.listServicesResponse.service
        .map((s) => s.name)
        .where((name) => name != 'grpc.reflection.v1alpha.ServerReflection')
        .toList();

    _typeRegistry = GrpcTypeRegistry();
    _services = [];

    // For each service, get file descriptor
    for (final serviceName in serviceNames) {
      final fileRequest = ServerReflectionRequest()
        ..fileContainingSymbol = serviceName;

      final fileStream = reflectionClient.serverReflectionInfo(
        Stream.value(fileRequest),
      );

      final fileResponse = await fileStream.first;
      final fdBytes = fileResponse.fileDescriptorResponse.fileDescriptorProto;

      for (final bytes in fdBytes) {
        final fdProto = FileDescriptorProto.fromBuffer(bytes);
        _typeRegistry!.registerFile(fdProto);

        for (final service in fdProto.service) {
          final fullServiceName = fdProto.package.isNotEmpty
              ? '${fdProto.package}.${service.name}'
              : service.name;

          if (fullServiceName != serviceName) continue;

          final methods = service.method.map((m) {
            return GrpcMethodInfo(
              methodName: m.name,
              fullServiceName: fullServiceName,
              clientStreaming: m.clientStreaming,
              serverStreaming: m.serverStreaming,
              inputTypeName: m.inputType,
              outputTypeName: m.outputType,
            );
          }).toList();

          _services.add(GrpcServiceInfo(
            serviceName: fullServiceName,
            methods: methods,
          ));
        }
      }
    }
  }

  /// Load service definitions from a FileDescriptorSet binary.
  void _loadFromDescriptor(Uint8List descriptorBytes) {
    final descriptorSet = FileDescriptorSet.fromBuffer(descriptorBytes);

    _typeRegistry = GrpcTypeRegistry();
    _services = [];

    for (final file in descriptorSet.file) {
      _typeRegistry!.registerFile(file);

      for (final service in file.service) {
        final fullServiceName = file.package.isNotEmpty
            ? '${file.package}.${service.name}'
            : service.name;

        final methods = service.method.map((m) {
          return GrpcMethodInfo(
            methodName: m.name,
            fullServiceName: fullServiceName,
            clientStreaming: m.clientStreaming,
            serverStreaming: m.serverStreaming,
            inputTypeName: m.inputType,
            outputTypeName: m.outputType,
          );
        }).toList();

        _services.add(GrpcServiceInfo(
          serviceName: fullServiceName,
          methods: methods,
        ));
      }
    }
  }

  /// Invoke a unary gRPC method.
  Future<GrpcCallResult> callUnary({
    required GrpcMethodInfo method,
    required Uint8List requestBytes,
    List<GrpcMetadataEntry> metadata = const [],
  }) async {
    if (_channel == null) {
      return const GrpcCallResult(error: 'Not connected');
    }

    final clientMethod = _rawMethod(method.fullPath);
    final callOptions = CallOptions(
      metadata: _buildMetadata(metadata),
      timeout: const Duration(seconds: 30),
    );

    final stopwatch = Stopwatch()..start();

    try {
      final call = _channel!.createCall(
        clientMethod,
        Stream.value(requestBytes),
        callOptions,
      );

      final responseFuture = ResponseFuture<List<int>>(call);
      final responseBytes = await responseFuture;
      stopwatch.stop();

      final headers = await call.headers;
      final trailers = await call.trailers;

      return GrpcCallResult(
        statusCode: 0,
        statusMessage: 'OK',
        responseHeaders: headers,
        responseTrailers: trailers,
        responseMessages: [Uint8List.fromList(responseBytes)],
        duration: stopwatch.elapsed,
      );
    } on GrpcError catch (e) {
      stopwatch.stop();
      return GrpcCallResult(
        statusCode: e.code,
        statusMessage: e.message,
        error: 'gRPC Error ${e.code}: ${e.message}',
        duration: stopwatch.elapsed,
      );
    } catch (e) {
      stopwatch.stop();
      return GrpcCallResult(
        error: e.toString(),
        duration: stopwatch.elapsed,
      );
    }
  }

  /// Invoke a server-streaming gRPC method.
  Stream<GrpcCallResult> callServerStreaming({
    required GrpcMethodInfo method,
    required Uint8List requestBytes,
    List<GrpcMetadataEntry> metadata = const [],
  }) async* {
    if (_channel == null) {
      yield const GrpcCallResult(error: 'Not connected');
      return;
    }

    final clientMethod = _rawMethod(method.fullPath);
    final callOptions = CallOptions(
      metadata: _buildMetadata(metadata),
    );

    final stopwatch = Stopwatch()..start();

    try {
      final call = _channel!.createCall(
        clientMethod,
        Stream.value(requestBytes),
        callOptions,
      );

      await for (final responseBytes in call.response) {
        yield GrpcCallResult(
          statusCode: 0,
          responseMessages: [Uint8List.fromList(responseBytes)],
          duration: stopwatch.elapsed,
        );
      }

      stopwatch.stop();
      final trailers = await call.trailers;
      yield GrpcCallResult(
        statusCode: 0,
        statusMessage: 'Stream completed',
        responseTrailers: trailers,
        duration: stopwatch.elapsed,
      );
    } on GrpcError catch (e) {
      stopwatch.stop();
      yield GrpcCallResult(
        statusCode: e.code,
        statusMessage: e.message,
        error: 'gRPC Error ${e.code}: ${e.message}',
        duration: stopwatch.elapsed,
      );
    } catch (e) {
      stopwatch.stop();
      yield GrpcCallResult(
        error: e.toString(),
        duration: stopwatch.elapsed,
      );
    }
  }

  /// Start a client-streaming gRPC call.
  GrpcClientStreamController startClientStreaming({
    required GrpcMethodInfo method,
    List<GrpcMetadataEntry> metadata = const [],
  }) {
    if (_channel == null) {
      throw const GrpcError.unavailable('Not connected');
    }

    final clientMethod = _rawMethod(method.fullPath);
    final callOptions = CallOptions(
      metadata: _buildMetadata(metadata),
    );

    final requestController = StreamController<List<int>>();

    final call = _channel!.createCall(
      clientMethod,
      requestController.stream,
      callOptions,
    );

    return GrpcClientStreamController(
      requestSink: requestController,
      call: call,
    );
  }

  /// Start a bidirectional streaming gRPC call.
  GrpcBidiStreamController startBidiStreaming({
    required GrpcMethodInfo method,
    List<GrpcMetadataEntry> metadata = const [],
  }) {
    if (_channel == null) {
      throw const GrpcError.unavailable('Not connected');
    }

    final clientMethod = _rawMethod(method.fullPath);
    final callOptions = CallOptions(
      metadata: _buildMetadata(metadata),
    );

    final requestController = StreamController<List<int>>();

    final call = _channel!.createCall(
      clientMethod,
      requestController.stream,
      callOptions,
    );

    return GrpcBidiStreamController(
      requestSink: requestController,
      call: call,
    );
  }

  Map<String, String> _buildMetadata(List<GrpcMetadataEntry> entries) {
    final map = <String, String>{};
    for (final entry in entries) {
      if (entry.key.isNotEmpty) {
        map[entry.key] = entry.value;
      }
    }
    return map;
  }

  Future<void> disconnect() async {
    await _dispose();
  }

  Future<void> _dispose() async {
    _isConnected = false;
    _services = [];
    _typeRegistry = null;
    await _channel?.shutdown();
    _channel = null;
  }
}

/// Controller for client-streaming calls.
class GrpcClientStreamController {
  final StreamController<List<int>> requestSink;
  final ClientCall<List<int>, List<int>> call;

  GrpcClientStreamController({
    required this.requestSink,
    required this.call,
  });

  void sendMessage(Uint8List bytes) {
    requestSink.add(bytes);
  }

  Future<GrpcCallResult> closeAndReceive() async {
    final stopwatch = Stopwatch()..start();
    try {
      await requestSink.close();
      final responseFuture = ResponseFuture<List<int>>(call);
      final responseBytes = await responseFuture;
      stopwatch.stop();

      final trailers = await call.trailers;
      return GrpcCallResult(
        statusCode: 0,
        statusMessage: 'OK',
        responseMessages: [Uint8List.fromList(responseBytes)],
        responseTrailers: trailers,
        duration: stopwatch.elapsed,
      );
    } on GrpcError catch (e) {
      stopwatch.stop();
      return GrpcCallResult(
        statusCode: e.code,
        statusMessage: e.message,
        error: 'gRPC Error ${e.code}: ${e.message}',
        duration: stopwatch.elapsed,
      );
    } catch (e) {
      stopwatch.stop();
      return GrpcCallResult(
        error: e.toString(),
        duration: stopwatch.elapsed,
      );
    }
  }

  void cancel() {
    requestSink.close();
    call.cancel();
  }
}

/// Controller for bidirectional streaming calls.
class GrpcBidiStreamController {
  final StreamController<List<int>> requestSink;
  final ClientCall<List<int>, List<int>> call;

  GrpcBidiStreamController({
    required this.requestSink,
    required this.call,
  });

  void sendMessage(Uint8List bytes) {
    requestSink.add(bytes);
  }

  Stream<List<int>> get responseStream => call.response;

  void closeSend() {
    requestSink.close();
  }

  void cancel() {
    requestSink.close();
    call.cancel();
  }
}

// ---------------------------------------------------------------------------
// Dynamic Protobuf JSON <-> Binary Codec
// ---------------------------------------------------------------------------

/// Encode a JSON map into protobuf binary using descriptor metadata.
Uint8List jsonToProtobuf(
  Map<String, dynamic> json,
  DescriptorProto descriptor,
  GrpcTypeRegistry typeRegistry,
) {
  final writer = CodedBufferWriter();
  _writeMessage(writer, json, descriptor, typeRegistry);
  return writer.toBuffer();
}

void _writeMessage(
  CodedBufferWriter writer,
  Map<String, dynamic> json,
  DescriptorProto descriptor,
  GrpcTypeRegistry typeRegistry,
) {
  for (final field in descriptor.field) {
    final value = json[field.name] ?? json[field.jsonName];
    if (value == null) continue;

    if (field.label == FieldDescriptorProto_Label.LABEL_REPEATED &&
        value is List) {
      for (final item in value) {
        _writeField(writer, field, item, typeRegistry);
      }
    } else {
      _writeField(writer, field, value, typeRegistry);
    }
  }
}

void _writeField(
  CodedBufferWriter writer,
  FieldDescriptorProto field,
  dynamic value,
  GrpcTypeRegistry typeRegistry,
) {
  final tag = field.number;

  switch (field.type) {
    case FieldDescriptorProto_Type.TYPE_DOUBLE:
      writer.writeField(tag, PbFieldType.OD, (value as num).toDouble());
    case FieldDescriptorProto_Type.TYPE_FLOAT:
      writer.writeField(tag, PbFieldType.OF, (value as num).toDouble());
    case FieldDescriptorProto_Type.TYPE_INT64:
    case FieldDescriptorProto_Type.TYPE_SINT64:
    case FieldDescriptorProto_Type.TYPE_SFIXED64:
      writer.writeField(tag, PbFieldType.O6, _toInt64(value));
    case FieldDescriptorProto_Type.TYPE_UINT64:
    case FieldDescriptorProto_Type.TYPE_FIXED64:
      writer.writeField(tag, PbFieldType.O6, _toInt64(value));
    case FieldDescriptorProto_Type.TYPE_INT32:
    case FieldDescriptorProto_Type.TYPE_SINT32:
    case FieldDescriptorProto_Type.TYPE_SFIXED32:
      writer.writeField(tag, PbFieldType.O3, (value as num).toInt());
    case FieldDescriptorProto_Type.TYPE_UINT32:
    case FieldDescriptorProto_Type.TYPE_FIXED32:
      writer.writeField(tag, PbFieldType.OU3, (value as num).toInt());
    case FieldDescriptorProto_Type.TYPE_BOOL:
      writer.writeField(tag, PbFieldType.OB, value as bool);
    case FieldDescriptorProto_Type.TYPE_STRING:
      writer.writeField(tag, PbFieldType.OS, value as String);
    case FieldDescriptorProto_Type.TYPE_BYTES:
      writer.writeField(tag, PbFieldType.OY, base64Decode(value as String));
    case FieldDescriptorProto_Type.TYPE_ENUM:
      writer.writeField(tag, PbFieldType.O3, (value as num).toInt());
    case FieldDescriptorProto_Type.TYPE_MESSAGE:
      final msgDescriptor = typeRegistry.findMessage(field.typeName);
      if (msgDescriptor != null && value is Map<String, dynamic>) {
        final subWriter = CodedBufferWriter();
        _writeMessage(subWriter, value, msgDescriptor, typeRegistry);
        final subBytes = subWriter.toBuffer();
        writer.writeField(tag, PbFieldType.OM, subBytes);
      }
    default:
      break;
  }
}

Int64 _toInt64(dynamic value) {
  if (value is int) return Int64(value);
  if (value is String) return Int64.parseInt(value);
  return Int64.ZERO;
}

/// Decode protobuf binary into a JSON-like map using descriptor metadata.
Map<String, dynamic> protobufToJson(
  Uint8List bytes,
  DescriptorProto descriptor,
  GrpcTypeRegistry typeRegistry,
) {
  final unknownFields = UnknownFieldSet();
  final reader = CodedBufferReader(bytes);
  unknownFields.mergeFromCodedBufferReader(reader);

  final result = <String, dynamic>{};

  for (final field in descriptor.field) {
    final unknownField = unknownFields.getField(field.number);
    if (unknownField == null) continue;

    final isRepeated =
        field.label == FieldDescriptorProto_Label.LABEL_REPEATED;

    switch (field.type) {
      case FieldDescriptorProto_Type.TYPE_DOUBLE:
        final values =
            unknownField.fixed64s.map((v) => _int64BitsToDouble(v)).toList();
        result[field.name] = isRepeated ? values : values.firstOrNull;
      case FieldDescriptorProto_Type.TYPE_FLOAT:
        final values =
            unknownField.fixed32s.map((v) => _int32BitsToFloat(v)).toList();
        result[field.name] = isRepeated ? values : values.firstOrNull;
      case FieldDescriptorProto_Type.TYPE_INT64:
      case FieldDescriptorProto_Type.TYPE_SINT64:
      case FieldDescriptorProto_Type.TYPE_SFIXED64:
      case FieldDescriptorProto_Type.TYPE_UINT64:
      case FieldDescriptorProto_Type.TYPE_FIXED64:
        final values =
            unknownField.varints.map((v) => v.toString()).toList();
        result[field.name] = isRepeated ? values : values.firstOrNull;
      case FieldDescriptorProto_Type.TYPE_INT32:
      case FieldDescriptorProto_Type.TYPE_SINT32:
      case FieldDescriptorProto_Type.TYPE_SFIXED32:
      case FieldDescriptorProto_Type.TYPE_UINT32:
      case FieldDescriptorProto_Type.TYPE_FIXED32:
        final values =
            unknownField.varints.map((v) => v.toInt()).toList();
        result[field.name] = isRepeated ? values : values.firstOrNull;
      case FieldDescriptorProto_Type.TYPE_BOOL:
        final values =
            unknownField.varints.map((v) => v.toInt() != 0).toList();
        result[field.name] = isRepeated ? values : values.firstOrNull;
      case FieldDescriptorProto_Type.TYPE_STRING:
        final values = unknownField.lengthDelimited
            .map((v) => utf8.decode(v))
            .toList();
        result[field.name] = isRepeated ? values : values.firstOrNull;
      case FieldDescriptorProto_Type.TYPE_BYTES:
        final values = unknownField.lengthDelimited
            .map((v) => base64Encode(v))
            .toList();
        result[field.name] = isRepeated ? values : values.firstOrNull;
      case FieldDescriptorProto_Type.TYPE_ENUM:
        final values =
            unknownField.varints.map((v) => v.toInt()).toList();
        result[field.name] = isRepeated ? values : values.firstOrNull;
      case FieldDescriptorProto_Type.TYPE_MESSAGE:
        final msgDescriptor = typeRegistry.findMessage(field.typeName);
        if (msgDescriptor != null) {
          final values = unknownField.lengthDelimited
              .map((v) => protobufToJson(
                  Uint8List.fromList(v), msgDescriptor, typeRegistry))
              .toList();
          result[field.name] = isRepeated ? values : values.firstOrNull;
        }
      default:
        break;
    }
  }

  return result;
}

double _int64BitsToDouble(Int64 bits) {
  final byteData = ByteData(8);
  byteData.setInt64(0, bits.toInt(), Endian.little);
  return byteData.getFloat64(0, Endian.little);
}

double _int32BitsToFloat(int bits) {
  final byteData = ByteData(4);
  byteData.setInt32(0, bits, Endian.little);
  return byteData.getFloat32(0, Endian.little);
}
