# gRPC Support in ApiDash — Implementation & Debugging Guide

> **Branch:** `feat/grpc-support`  
> **Primary file:** `packages/better_networking/lib/services/grpc_service.dart`  
> **Model:** `packages/better_networking/lib/models/grpc_request_model.dart`  
> **Provider:** `lib/providers/collection_providers.dart`  
> **UI:** `lib/screens/home_page/editor_pane/url_card.dart`, `lib/screens/home_page/editor_pane/details_card/grpc_response_pane.dart`

---

## Table of Contents

1. [gRPC Concepts Primer](#1-grpc-concepts-primer)
2. [Architecture Overview](#2-architecture-overview)
3. [The Data Model — `GrpcRequestModel`](#3-the-data-model--grpcrequestmodel)
4. [The gRPC Service — `grpc_service.dart`](#4-the-grpc-service--grpc_servicedart)
5. [The Provider Layer — `connectGrpc` / `invokeGrpc`](#5-the-provider-layer--connectgrpc--invokegrpc)
6. [The UI Layer](#6-the-ui-layer)
7. [Bugs Found and Fixed](#7-bugs-found-and-fixed)

---

## 1. gRPC Concepts Primer

Understanding gRPC requires knowing a few foundational things before reading the code.

### 1.1 What is gRPC?

gRPC is a high-performance RPC (Remote Procedure Call) framework developed by Google. Unlike REST, which is text-based (HTTP/1.1 + JSON), gRPC:

- Runs over **HTTP/2**, which allows multiplexed streams over a single TCP connection
- Uses **Protocol Buffers** (protobuf) as the default wire format — a compact binary encoding
- Defines its API contract in `.proto` files, which are compiled into strongly-typed client/server code

### 1.2 HTTP/2 and Why It Matters

HTTP/2 carries gRPC messages as binary **frames**. The key frame types relevant here:

| Frame | Meaning |
|---|---|
| `DATA` | Contains a portion of an HTTP/2 message body |
| `HEADERS` | Carries gRPC metadata (request/response headers, grpc-status) |
| `RST_STREAM` | Abruptly cancels a single stream (one RPC call) |
| `GOAWAY` | Server-initiated signal to close the entire HTTP/2 **connection** |

A `GOAWAY` with `errorCode: 10` is `CONNECT_ERROR` — the server encountered an error on a stream severe enough that it chose to nuke the entire connection rather than just RST the individual stream. This typically means the server's protobuf parser received bytes it could not make sense of, which is exactly what our encoder bug caused.

### 1.3 The Four gRPC Call Types

gRPC methods come in four streaming flavours, defined by two booleans in the `.proto` definition (`client_streaming`, `server_streaming`):

```
Unary:              Client sends 1 message  → Server sends 1 message
Server Streaming:   Client sends 1 message  → Server sends N messages
Client Streaming:   Client sends N messages → Server sends 1 message
Bidirectional:      Client sends N messages → Server sends N messages (concurrently)
```

Everything except Unary involves a long-lived HTTP/2 stream.

### 1.4 Protocol Buffers Wire Format

Protobuf binary encoding is built from **fields**. Each field on the wire consists of:

```
[tag varint] [payload]
```

The **tag** encodes two things packed into a single varint:

```
tag = (fieldNumber << 3) | wireType
```

The **wire type** tells the decoder how many bytes to consume for the payload:

| Wire Type | Value | Used for |
|---|---|---|
| Varint | 0 | int32, int64, uint32, uint64, sint32, sint64, bool, enum |
| 64-bit fixed | 1 | fixed64, sfixed64, double |
| Length-delimited | 2 | string, bytes, embedded messages, repeated packed fields |
| 32-bit fixed | 5 | fixed32, sfixed32, float |

**Wire type mismatch is catastrophic.** If the encoder writes `FIXED32` with wire type 0 (varint) instead of wire type 5 (4-byte fixed), the decoder reads a variable-length varint where it expected exactly 4 bytes. Every subsequent field in the message starts at the wrong offset. The entire message is unintelligible. For gRPC this causes the server to send GOAWAY.

### 1.5 Special Protobuf Encodings

- **`sint32`/`sint64` — ZigZag encoding:** Normal varints encode negative numbers as 10 bytes (the sign bit extends all the way up). ZigZag remaps them: `0→0, -1→1, 1→2, -2→3, ...` via `(n << 1) ^ (n >> 31)`. This makes small negative numbers cheap. If you omit zigzag and just encode a plain varint, negative values are encoded differently and the server decodes the wrong number.

- **`int32` negative values:** A negative `int32` must be sign-extended to 64 bits and encoded as a 10-byte varint. This mirrors what the server's parser expects.

- **`fixed32`/`sfixed32`:** Always exactly 4 bytes, little-endian. IEEE 754 floats also use this wire type.

- **`fixed64`/`sfixed64`:** Always exactly 8 bytes, little-endian. IEEE 754 doubles also use this wire type.

### 1.6 Server Reflection

gRPC servers can expose a special meta-service called **gRPC Server Reflection** (defined in `grpc.reflection.v1alpha`). It lets clients ask:

1. "What services do you expose?" → returns a list of service names
2. "Give me the `.proto` descriptor for service X" → returns a `FileDescriptorProto` binary blob

This is strictly a gRPC bidi-streaming call (`ServerReflectionInfo`) — the client sends `ServerReflectionRequest` messages and the server replies with `ServerReflectionResponse` messages. ApiDash uses this to discover services without requiring the user to supply a `.proto` file.

---

## 2. Architecture Overview

```
┌─────────────────────────────────────────────────────┐
│                    Flutter UI                       │
│  GrpcPortField  GrpcConnectButton  GrpcResponsePane │
└─────────────────────┬───────────────────────────────┘
                      │ Riverpod actions
┌─────────────────────▼───────────────────────────────┐
│               Provider Layer                        │
│  connectGrpc()  invokeGrpc()  disconnectGrpc()      │
│  grpcConnectionProvider  grpcResponseProvider       │
└─────────────────────┬───────────────────────────────┘
                      │ calls
┌─────────────────────▼───────────────────────────────┐
│           GrpcClientManager (per-request-id)        │
│  connect()   callUnary()   callServerStreaming()     │
│  startClientStreaming()  startBidiStreaming()        │
└─────────────────────┬───────────────────────────────┘
                      │ uses
┌─────────────────────▼───────────────────────────────┐
│  grpc package: ClientChannel, createCall, GrpcError │
│  grpc_reflection: ServerReflectionClient            │
│  protobuf package: CodedBufferReader, UnknownField  │
└─────────────────────────────────────────────────────┘
```

The `GrpcClientManager` is a per-request-ID singleton holding the live `ClientChannel`. One `RequestModel` in the collection = one manager that lives as long as the connection is open.

---

## 3. The Data Model — `GrpcRequestModel`

**File:** [`packages/better_networking/lib/models/grpc_request_model.dart`](../packages/better_networking/lib/models/grpc_request_model.dart)

```dart
@JsonSerializable(explicitToJson: true, anyMap: true)
class GrpcRequestModel {
  final String host;
  final int port;
  final bool useTls;
  final String? selectedService;
  final String? selectedMethod;
  final String requestBody;
  final List<GrpcMetadataEntry> metadata;
  final bool useReflection;
  final Uint8List? descriptorFileBytes;

  const GrpcRequestModel({
    this.host = "",
    this.port = 50051,      // ← default gRPC port
    this.useTls = false,    // ← h2c (cleartext) by default
    ...
  });
}
```

**Why `useTls = false` and `port = 50051`?**

The most common development and testing setup (including `grpcb.in:9000`) uses **h2c** — HTTP/2 cleartext without TLS. The original defaults were `useTls: true` and `port: 443`, which caused every connection to fail unless the user manually changed both values. The defaults were flipped to match reality.

**The `_sentinel` pattern for nullable `copyWith`:**

```dart
static const _sentinel = Object();

GrpcRequestModel copyWith({
  Object? selectedService = _sentinel,
  ...
}) {
  return GrpcRequestModel(
    selectedService: identical(selectedService, _sentinel)
        ? this.selectedService
        : selectedService as String?,
  );
}
```

Standard Dart `copyWith` cannot distinguish "I want to set this field to null" from "I omitted this argument". The sentinel solves this: if you pass `selectedService: null`, it becomes null; if you don't pass it, `identical(arg, _sentinel)` is true and the old value is kept.

**`GrpcMetadataEntry`** represents a single key/value gRPC metadata header (equivalent to HTTP headers). These are sent as `CallOptions.metadata` map and appear on the wire as HTTP/2 pseudo-headers.

**`descriptorFileBytes`** stores a raw `FileDescriptorSet` binary (`.pb` file) as base64 in JSON. This is for users who want to provide their own `.proto` compiled descriptor instead of relying on server reflection.

---

## 4. The gRPC Service — `grpc_service.dart`

**File:** [`packages/better_networking/lib/services/grpc_service.dart`](../packages/better_networking/lib/services/grpc_service.dart)

This is the largest file and the heart of the feature. It is divided into four logical sections.

### 4.1 Data Structures

```dart
class GrpcServiceInfo {
  final String serviceName;         // e.g. "grpc.testing.TestService"
  final List<GrpcMethodInfo> methods;
}

class GrpcMethodInfo {
  final String methodName;          // e.g. "UnaryCall"
  final String fullServiceName;     // e.g. "grpc.testing.TestService"
  final bool clientStreaming;
  final bool serverStreaming;
  final String inputTypeName;       // e.g. ".grpc.testing.SimpleRequest"
  final String outputTypeName;

  String get fullPath => '/$fullServiceName/$methodName';
  // e.g. "/grpc.testing.TestService/UnaryCall"

  GrpcCallType get callType { ... }
}
```

`fullPath` is what gRPC uses as the HTTP/2 `:path` pseudo-header. It must be exactly `/<package.ServiceName>/<MethodName>`.

```dart
class GrpcTypeRegistry {
  final Map<String, DescriptorProto> _messageTypes = {};
  final Map<String, EnumDescriptorProto> _enumTypes = {};

  void registerFile(FileDescriptorProto file) { ... }
  DescriptorProto? findMessage(String fullName) => _messageTypes[fullName];
}
```

The `GrpcTypeRegistry` is a runtime lookup table built from reflection data. When we get a `FileDescriptorProto` back from the server, we iterate all its message types and store them under their fully-qualified names (e.g. `.helloworld.HelloRequest`). Later, when encoding a field of type `TYPE_MESSAGE`, `findMessage(field.typeName)` gives us the nested `DescriptorProto` for recursive encoding.

### 4.2 The Raw Bytes Channel Trick

```dart
ClientMethod<List<int>, List<int>> _rawMethod(String path) {
  return ClientMethod<List<int>, List<int>>(
    path,
    (bytes) => bytes,   // serializer: identity
    (bytes) => bytes,   // deserializer: identity
  );
}
```

The `grpc` Dart package was designed for generated code: you normally pass a `ClientMethod<RequestType, ResponseType>` that knows how to serialize/deserialize your compiled protobuf types. Since ApiDash builds protobuf messages dynamically (from JSON + a runtime descriptor), there is no generated type. The solution is to declare a `ClientMethod<List<int>, List<int>>` with identity functions. We do the serialization ourselves (`jsonToProtobuf` → `Uint8List`) before calling `createCall`, and do deserialization ourselves (`protobufToJson`) after receiving the `List<int>` response.

### 4.3 `GrpcClientManager` — Lifecycle

```dart
class GrpcClientManager {
  static final Map<String, GrpcClientManager> _instances = {};

  static GrpcClientManager getOrCreate(String requestId) {
    return _instances.putIfAbsent(requestId, () => GrpcClientManager._());
  }

  static void remove(String requestId) {
    final manager = _instances.remove(requestId);
    manager?._dispose();
  }

  ClientChannel? _channel;
  ...
}
```

One `GrpcClientManager` per `requestId` (the request's UUID in the collection). It holds the live `ClientChannel` between connect and disconnect. `remove()` is called at the start of every `connectGrpc()` to destroy any stale manager from a previous connection attempt before creating a fresh one. Without this, clicking "Connect" a second time would reuse the old, possibly broken channel.

### 4.4 `connect()` — The Dual-Channel Design

```dart
Future<void> connect(GrpcRequestModel config) async {
  await _dispose();

  final channelOptions = ChannelOptions(
    credentials: config.useTls
        ? const ChannelCredentials.secure()
        : const ChannelCredentials.insecure(),
    connectionTimeout: const Duration(seconds: 10),
  );

  // Main channel — for actual RPC invocations ONLY.
  _channel = ClientChannel(host, port: config.port, options: channelOptions);

  if (config.useReflection) {
    // Separate ephemeral channel for reflection.
    final reflectionChannel = ClientChannel(
      host, port: config.port, options: channelOptions,
    );
    try {
      await _discoverViaReflection(reflectionChannel);
    } finally {
      await reflectionChannel.shutdown();   // always cleaned up
    }
  }
  ...
}
```

**Why two channels?**

Server reflection uses the bidi-streaming RPC `ServerReflectionInfo`. In Dart's `grpc` package, calling `.first` on a bidi stream (to get just one response) cancels the underlying stream after reading one message. HTTP/2 stream cancellation is expressed as a `RST_STREAM` frame. Some gRPC server implementations (including `grpcb.in`) treat `RST_STREAM` as an error severe enough to close the entire HTTP/2 connection with a `GOAWAY` frame. If reflection and invocations share the same channel, this GOAWAY kills the connection before we can invoke any methods.

By using a dedicated ephemeral channel for reflection that is shut down cleanly after discovery, the main `_channel` is never touched by reflection and remains healthy for actual calls.

### 4.5 `_discoverViaReflection()`

```dart
Future<void> _discoverViaReflection(ClientChannel channel) async {
  final reflectionClient = ServerReflectionClient(channel);

  // Step 1: List all services
  final listResponse = await reflectionClient.serverReflectionInfo(
    Stream.value(ServerReflectionRequest()..listServices = ''),
  ).first;

  final serviceNames = listResponse.listServicesResponse.service
      .map((s) => s.name)
      .where((name) => name != 'grpc.reflection.v1alpha.ServerReflection')
      .toList();

  // Step 2: For each service, fetch its file descriptor
  for (final serviceName in serviceNames) {
    final fileResponse = await reflectionClient.serverReflectionInfo(
      Stream.value(ServerReflectionRequest()..fileContainingSymbol = serviceName),
    ).first;

    final fdBytes = fileResponse.fileDescriptorResponse.fileDescriptorProto;
    for (final bytes in fdBytes) {
      final fdProto = FileDescriptorProto.fromBuffer(bytes);
      _typeRegistry!.registerFile(fdProto);
      // Extract service + method metadata from the descriptor...
    }
  }
}
```

The reflection protocol works in two steps:
1. `listServices = ''` returns a flat list of all service names.
2. `fileContainingSymbol = serviceName` returns a `FileDescriptorProto` — the binary-encoded `.proto` file that contains that service. This gives us the full type schema for all messages used by that service.

We filter out `grpc.reflection.v1alpha.ServerReflection` itself — it is a meta-service that clients should not show to users.

### 4.6 Calling Methods

All four call variants use `_channel!.createCall(clientMethod, requestStream, callOptions)`.

**Unary (`callUnary`):**

```dart
final call = _channel!.createCall(
  _rawMethod(method.fullPath),
  Stream.value(requestBytes),   // single-element request stream
  callOptions,
);
final responseFuture = ResponseFuture<List<int>>(call);
final responseBytes = await responseFuture;
```

`Stream.value(requestBytes)` wraps a single `Uint8List` as a one-element stream, satisfying the `Stream<Q>` parameter that `createCall` requires. `ResponseFuture` is the `grpc` package's wrapper that awaits the single response message and surfaces the `GrpcError` if the call fails.

**Server Streaming (`callServerStreaming`):**

```dart
await for (final responseBytes in call.response) {
  yield GrpcCallResult(...);
}
```

`call.response` is a `Stream<List<int>>` that emits one item per message the server sends. We `yield` a `GrpcCallResult` per message so the UI can update incrementally.

**Client/Bidi Streaming:**

These return a *controller* object to the caller rather than a future/stream:

```dart
class GrpcClientStreamController {
  final StreamController<List<int>> requestSink;
  final ClientCall<List<int>, List<int>> call;

  void sendMessage(Uint8List bytes) => requestSink.add(bytes);
  Future<GrpcCallResult> closeAndReceive() async { ... }
}
```

The `requestSink` is the live pipe into the HTTP/2 stream. Calling `.add()` sends a gRPC message frame. Calling `.close()` sends the HTTP/2 `DATA` frame with the `END_STREAM` flag, signalling to the server that the client is done sending.

### 4.7 The Protobuf Encoder — `jsonToProtobuf`

This is the most complex part and the source of every invocation bug. The goal is: given a `Map<String, dynamic>` (JSON the user typed) and a `DescriptorProto` (the message schema from reflection), produce a valid protobuf binary `Uint8List`.

#### 4.7.1 Why Not Use `PbFieldType.writeField`?

The `protobuf` Dart package provides `CodedBufferWriter.writeField(tag, fieldType, value)` for writing compiled `GeneratedMessage` subclasses. It was designed to be called with the exact `PbFieldType` constant that the generated code uses for each field. The constants map like this:

| PbFieldType | Wire type emitted |
|---|---|
| `O3` (optional int32) | 0 (varint) |
| `OU3` (optional uint32) | 0 (varint) |
| `O6` (optional int64) | 0 (varint) |
| `OF` (optional float) | 5 (fixed32) |
| `OD` (optional double) | 1 (fixed64) |

Notice that `SFIXED32`, `FIXED32`, `SFIXED64`, `FIXED64` have their own `PbFieldType` constants (`OSF3`, `OF3`, `OSF6`, `OF6`), but the old code was mapping those proto field types to `O3`/`OU3`/`O6`, which all use varint wire type. The result was corrupt wire format. The only correct approach is to write the wire format directly.

#### 4.7.2 The `_Buf` Buffer

```dart
class _Buf {
  final List<int> _b = [];
  void addByte(int v) => _b.add(v & 0xFF);
  void addAll(List<int> bytes) => _b.addAll(bytes);
  Uint8List toBytes() => Uint8List.fromList(_b);
}
```

A minimal growable byte array. We use `& 0xFF` in `addByte` to ensure only the low 8 bits are stored, guarding against accidental negative values appearing in the list.

#### 4.7.3 Varint Encoding

```dart
void _writeVarint(_Buf buf, int value) {
  var v = value;
  while (v > 0x7F || v < 0) {
    buf.addByte((v & 0x7F) | 0x80);
    v = v >>> 7;    // unsigned right-shift
  }
  buf.addByte(v);
}
```

Protobuf varint is **base-128**: each byte encodes 7 bits of data, with the MSB (bit 7) set to 1 if more bytes follow, 0 if this is the last byte. The loop condition `v < 0` catches negative Dart `int` values (which are 64-bit signed): a negative `v >>> 7` will eventually reach zero from the top, so the loop terminates.

For 64-bit values (from `fixnum`'s `Int64`), the function cannot use Dart's native `int >>>` because `Int64` is a class, not a primitive. A separate function handles that:

```dart
void _writeVarint64(_Buf buf, Int64 value) {
  var v = value;
  while (v > Int64(0x7F) || v < Int64.ZERO) {
    buf.addByte(((v & Int64(0x7F)) | Int64(0x80)).toInt());
    v = v.shiftRightUnsigned(7);   // Int64's unsigned right-shift method
  }
  buf.addByte(v.toInt());
}
```

`Int64.shiftRightUnsigned` is equivalent to `>>>` for `Int64`.

#### 4.7.4 Tags and Length-Delimited Fields

```dart
void _writeTag(_Buf buf, int fieldNumber, int wireType) {
  _writeVarint(buf, (fieldNumber << 3) | wireType);
}

void _writeLengthDelimited(_Buf buf, int fieldNumber, List<int> bytes) {
  _writeTag(buf, fieldNumber, _kWireLen);    // wire type 2
  _writeVarint(buf, bytes.length);           // length prefix
  buf.addAll(bytes);                         // payload
}
```

The tag packs `fieldNumber` and `wireType` together. `_writeLengthDelimited` is used for strings, bytes, and embedded messages — they all share wire type 2, preceded by a varint length.

#### 4.7.5 `_encodeField` — Full Type Dispatch

```dart
void _encodeField(
  _Buf buf, FieldDescriptorProto field, dynamic value, GrpcTypeRegistry typeRegistry,
) {
  final fn = field.number;
  switch (field.type) {

    // Wire type 0 — varint
    case TYPE_BOOL:
      _writeTag(buf, fn, _kWireVarint);
      _writeVarint(buf, (value as bool) ? 1 : 0);

    case TYPE_ENUM:
    case TYPE_INT32:
    case TYPE_UINT32:
      _writeTag(buf, fn, _kWireVarint);
      // Int64 wrapping ensures negative int32 is sign-extended to 64 bits,
      // producing the correct 10-byte varint the protobuf spec mandates.
      _writeVarint64(buf, Int64((value as num).toInt()));

    case TYPE_SINT32:
      // ZigZag: (n << 1) ^ (n >> 31)
      // Maps 0→0, -1→1, 1→2, -2→3, -- small signed values stay small.
      _writeTag(buf, fn, _kWireVarint);
      final v = (value as num).toInt();
      _writeVarint(buf, (v << 1) ^ (v >> 31));

    case TYPE_INT64:
    case TYPE_UINT64:
      _writeTag(buf, fn, _kWireVarint);
      _writeVarint64(buf, _parseInt64(value));

    case TYPE_SINT64:
      // ZigZag on Int64: (v << 1) ^ (v >> 63)
      _writeTag(buf, fn, _kWireVarint);
      final v = _parseInt64(value);
      _writeVarint64(buf, (v << 1) ^ (v >> 63));

    // Wire type 5 — 4 bytes fixed, little-endian
    case TYPE_FLOAT:
      _writeTag(buf, fn, _kWire32Bit);      // _kWire32Bit = 5
      final bd = ByteData(4)
        ..setFloat32(0, (value as num).toDouble(), Endian.little);
      buf.addAll(bd.buffer.asUint8List());

    case TYPE_FIXED32:
    case TYPE_SFIXED32:
      _writeTag(buf, fn, _kWire32Bit);
      final bd = ByteData(4)
        ..setUint32(0, (value as num).toInt() & 0xFFFFFFFF, Endian.little);
      buf.addAll(bd.buffer.asUint8List());

    // Wire type 1 — 8 bytes fixed, little-endian
    case TYPE_DOUBLE:
      _writeTag(buf, fn, _kWire64Bit);      // _kWire64Bit = 1
      final bd = ByteData(8)
        ..setFloat64(0, (value as num).toDouble(), Endian.little);
      buf.addAll(bd.buffer.asUint8List());

    case TYPE_FIXED64:
    case TYPE_SFIXED64:
      _writeTag(buf, fn, _kWire64Bit);
      final v = _parseInt64(value);
      // ByteData.setInt64 doesn't exist in all Flutter targets, so we
      // manually write the low 32 bits then the high 32 bits.
      final bd = ByteData(8)
        ..setInt32(0, v.toUnsigned(32).toInt(), Endian.little)
        ..setInt32(4, (v >> 32).toUnsigned(32).toInt(), Endian.little);
      buf.addAll(bd.buffer.asUint8List());

    // Wire type 2 — length-delimited
    case TYPE_STRING:
      _writeLengthDelimited(buf, fn, utf8.encode(value as String));

    case TYPE_BYTES:
      // Users provide bytes as base64 strings in JSON.
      // base64.normalize() handles padded, unpadded, and URL-safe variants.
      final bytes = base64Decode(base64.normalize(value as String));
      _writeLengthDelimited(buf, fn, bytes);

    case TYPE_MESSAGE:
      final msgDescriptor = typeRegistry.findMessage(field.typeName);
      if (msgDescriptor != null && value is Map<String, dynamic>) {
        final subBytes = _encodeMessage(value, msgDescriptor, typeRegistry);
        _writeLengthDelimited(buf, fn, subBytes);   // recursive
      }
  }
}
```

**`_parseInt64`** handles three possible JSON representations of a 64-bit integer:

```dart
Int64 _parseInt64(dynamic value) {
  if (value is int) return Int64(value);          // Dart int (up to 2^53 in JS)
  if (value is String) return Int64.parseInt(value);  // "9007199254740993"
  return Int64.ZERO;
}
```

String representation is important because JavaScript (and Flutter Web) cannot represent integers larger than 2^53 exactly. The official protobuf JSON spec encodes `int64`/`uint64` as strings for this reason.

### 4.8 The Protobuf Decoder — `protobufToJson`

```dart
Map<String, dynamic> protobufToJson(
  Uint8List bytes,
  DescriptorProto descriptor,
  GrpcTypeRegistry typeRegistry,
) {
  final unknownFields = UnknownFieldSet();
  final reader = CodedBufferReader(bytes);
  unknownFields.mergeFromCodedBufferReader(reader);
  ...
}
```

Since we don't have generated message classes, we use `protobuf`'s `UnknownFieldSet` as a wire-format parser. It groups all fields by field number and wire type into buckets:

| Bucket | Wire type |
|---|---|
| `unknownField.varints` | 0 — varints |
| `unknownField.fixed32s` | 5 — 4-byte fixed |
| `unknownField.fixed64s` | 1 — 8-byte fixed |
| `unknownField.lengthDelimited` | 2 — length-delimited |

We look up each field from the descriptor, find its corresponding bucket, and convert back to Dart primitives. The decoder must mirror the encoder:
- `FIXED32`/`SFIXED32` read from `fixed32s` (not `varints`)
- `FIXED64`/`SFIXED64` read from `fixed64s`
- `SINT32`/`SINT64` un-zigzag their values

---

## 5. The Provider Layer — `connectGrpc` / `invokeGrpc`

**File:** [`lib/providers/collection_providers.dart`](../../lib/providers/collection_providers.dart)

### 5.1 `connectGrpc()`

```dart
Future<void> connectGrpc() async {
  final requestId = ref.read(selectedIdStateProvider);
  var grpcConfig = state![requestId]?.grpcRequestModel;

  // --- Fix: host:port auto-splitting ---
  // Users naturally type "grpcb.in:9000" in the host field.
  // ClientChannel(host, port: ...) expects ONLY the hostname.
  // If we pass "grpcb.in:9000" as the host, DNS resolves "grpcb.in:9000"
  // as a literal hostname, which fails.
  final rawHost = grpcConfig.host.trim();
  final colonIdx = rawHost.lastIndexOf(':');
  if (colonIdx > 0) {
    final maybePort = int.tryParse(rawHost.substring(colonIdx + 1));
    if (maybePort != null) {
      final cleanHost = rawHost.substring(0, colonIdx);
      grpcConfig = grpcConfig.copyWith(host: cleanHost, port: maybePort);
      update(id: requestId, grpcRequestModel: grpcConfig);
    }
  }

  // --- Fix: destroy stale manager before reconnect ---
  // Without this, clicking Connect twice reuses a potentially broken channel.
  GrpcClientManager.remove(requestId);
  final manager = GrpcClientManager.getOrCreate(requestId);

  ref.read(grpcConnectionProvider(requestId).notifier).state =
      const GrpcConnectionInfo(state: GrpcConnectionState.connecting);

  try {
    await manager.connect(grpcConfig);
    ...
  } catch (e) {
    ref.read(grpcConnectionProvider(requestId).notifier).state =
        GrpcConnectionInfo(
      state: GrpcConnectionState.error,
      errorMessage: 'Failed to connect to ${grpcConfig.host}:${grpcConfig.port} — $e',
    );
  }
}
```

The host:port splitting uses `lastIndexOf(':')` rather than `indexOf(':')` to correctly handle IPv6 addresses like `[::1]:50051` — the port separator is always the last colon.

The error message was upgraded to include `host:port` because the original message just said "Failed to connect — $e", which gave no context about what endpoint was being tried (in particular when the port had silently read as a wrong value due to the stale closure bug).

### 5.2 `invokeGrpc()`

```dart
Future<void> invokeGrpc() async {
  ...
  // Find the DescriptorProto for the input type
  final inputDescriptor = manager.typeRegistry!.findMessage(
    methodInfo.inputTypeName,
  );

  // Encode user's JSON into protobuf bytes
  final requestBytes = jsonToProtobuf(
    jsonDecode(grpcConfig.requestBody),
    inputDescriptor!,
    manager.typeRegistry!,
  );

  // Invoke
  final result = await manager.callUnary(
    method: methodInfo,
    requestBytes: requestBytes,
    metadata: grpcConfig.metadata,
  );

  // Decode response bytes back to JSON for display
  if (!result.isError && result.responseMessages.isNotEmpty) {
    final outputDescriptor = manager.typeRegistry!.findMessage(
      methodInfo.outputTypeName,
    );
    final decoded = protobufToJson(
      result.responseMessages.first,
      outputDescriptor!,
      manager.typeRegistry!,
    );
    ...
  }
}
```

---

## 6. The UI Layer

### 6.1 `EditorPaneRequestURLCard` — The Top Bar

**File:** [`lib/screens/home_page/editor_pane/url_card.dart`](../../lib/screens/home_page/editor_pane/url_card.dart)

For gRPC requests, the top bar shows:
- `URLTextField` (host field — repurposed from the HTTP URL field)
- `GrpcPortField` (80px wide port input)
- `GrpcConnectButton`

The `APIType.grpc` cases in the switch expressions suppress the HTTP method dropdown (which has no meaning for gRPC).

### 6.2 `URLTextField` — Host Field

```dart
initialValue: switch (requestModel.apiType) {
  APIType.grpc => requestModel.grpcRequestModel?.host,
  _ => requestModel.httpRequestModel?.url,
},
onChanged: (value) {
  if (requestModel.apiType == APIType.grpc) {
    ref.read(...).update(
      grpcRequestModel: requestModel.grpcRequestModel?.copyWith(host: value),
    );
  }
  ...
},
onFieldSubmitted: (value) {
  if (requestModel.apiType == APIType.grpc) {
    ref.read(...).connectGrpc();   // pressing Enter connects
  }
  ...
},
```

The same `URLTextField` widget is reused across all API types. For gRPC it binds to `grpcRequestModel.host` instead of `httpRequestModel.url`. Pressing Enter on the host field triggers `connectGrpc()`, the same UX pattern as MQTT.

### 6.3 `GrpcPortField` — The Stale Closure Fix

```dart
class GrpcPortField extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final selectedId = ref.watch(selectedIdStateProvider);

    // Watch the port value so the field rebuilds when it changes externally
    // (e.g. when connectGrpc() parses "host:port" and writes back the port).
    ref.watch(selectedRequestModelProvider
        .select((value) => value?.grpcRequestModel?.port));

    // Read the CURRENT model for the initial value.
    final requestModel = ref
        .read(collectionStateNotifierProvider.notifier)
        .getRequestModel(selectedId!);
    final port = requestModel?.grpcRequestModel?.port ?? 50051;

    return TextFormField(
      key: Key("grpc-port-$selectedId"),
      initialValue: port.toString(),
      ...
      onChanged: (value) {
        final p = int.tryParse(value);
        if (p != null) {
          // CRITICAL: read the CURRENT model INLINE, not the captured one.
          // If we used the `requestModel` variable captured at build time,
          // we would call copyWith on a stale snapshot from an old build,
          // overwriting any changes made since that build with old data.
          final currentModel = ref
              .read(collectionStateNotifierProvider.notifier)
              .getRequestModel(selectedId);
          ref.read(collectionStateNotifierProvider.notifier).update(
            grpcRequestModel:
                currentModel?.grpcRequestModel?.copyWith(port: p),
          );
        }
      },
    );
  }
}
```

**The stale closure bug:** In Flutter, `build()` captures variables. If `onChanged` closed over the `requestModel` variable from the outer scope of `build()`, that closure would hold a reference to the model snapshot at the time of the last build. If any other code (e.g. `connectGrpc()` parsing `"grpcb.in:9000"` and writing back the parsed host) updated the model before the user has finished typing, the `onChanged` closure would call `copyWith` on the stale snapshot, effectively reverting those updates. The fix reads the model freshly inside `onChanged` every time it is called.

**Why `Key("grpc-port-$selectedId")`?** When the user switches to a different request in the sidebar, `selectedId` changes. Without a key, Flutter might reuse the existing `TextFormField` widget and not reset `initialValue`. The key forces Flutter to create a new widget instance whenever the request ID changes.

### 6.4 `GrpcConnectButton`

```dart
return ADFilledButton(
  isTonal: isConnected,   // different style when connected (for "Disconnect")
  items: [
    Text(isConnecting ? kLabelGrpcConnecting
                      : isConnected ? kLabelDisconnect : kLabelConnect),
    Icon(isConnected ? Icons.link_off : Icons.link),
  ],
  onPressed: isConnecting
      ? null                        // disabled while connecting
      : () {
          if (isConnected) {
            ref.read(...).disconnectGrpc();
          } else {
            ref.read(...).connectGrpc();
          }
        },
);
```

The button is disabled (grayed out) while connecting — `onPressed: null`. This prevents double-connects and gives clear visual feedback. The `isTonal: isConnected` switches to a secondary/tonal style when connected, making the "Disconnect" action visually distinct from the initial "Connect" action.

### 6.5 `GrpcResponsePane`

**File:** [`lib/screens/home_page/editor_pane/details_card/grpc_response_pane.dart`](../../lib/screens/home_page/editor_pane/details_card/grpc_response_pane.dart)

The response pane is a `Column` with a fixed-height status header and an `Expanded` content area. The content area displays one of five states:

```
disconnected + no results  →  GrpcNotConnectedWidget  (cloud-off icon, "Connect first")
connecting                 →  (header dots animate)
error                      →  GrpcErrorWidget          (red error icon + scrollable message)
connected + no results     →  GrpcEmptyResponseWidget  ("Select a method and click Invoke")
connected + has results    →  GrpcResponseList         (list of GrpcResponseCard)
```

#### `GrpcConnectionStatusHeader`

```dart
final statusColor = switch (connectionInfo.state) {
  GrpcConnectionState.connected    => Colors.green,
  GrpcConnectionState.connecting   => Colors.orange,
  GrpcConnectionState.error        => Colors.red,
  GrpcConnectionState.disconnected => Colors.grey,
};
```

A 10×10 colored circle (like a connection LED) + status label + service count. Mirrors similar headers in the MQTT and WebSocket panes.

#### `GrpcErrorWidget` — Scrollable + Selectable

```dart
return SingleChildScrollView(
  padding: const EdgeInsets.all(24.0),
  child: Center(
    child: Column(
      children: [
        Icon(Icons.error_outline, ...),
        Text("Connection Error"),
        SelectableText(
          errorMessage!,
          textAlign: TextAlign.center,
        ),
      ],
    ),
  ),
);
```

Two deliberate choices here:
1. **`SingleChildScrollView`** — long error messages (especially connection stack traces) would overflow the viewport and clipping would hide useful information. Wrapping in a scroll view lets the user see the full message.
2. **`SelectableText`** — the user needs to copy the error message to search for it, file a bug report, or paste it elsewhere. `Text` is not selectable; `SelectableText` is.

#### `GrpcResponseCard`

Each response message is displayed as a `Card` with:
- Status badge (green "OK" or red "Error N")
- Status message text
- Duration in ms
- Response headers (collapsible section)
- Trailers (collapsible section)
- Response body: decoded as UTF-8 text if possible, hex otherwise

```dart
String displayText;
try {
  displayText = utf8.decode(msgBytes);
} catch (_) {
  displayText = msgBytes
      .map((b) => b.toRadixString(16).padLeft(2, '0'))
      .join(' ');
}
```

The UTF-8 decode approach is intentional: after `protobufToJson`, the response is re-encoded as a JSON string (`jsonEncode(decoded)`) before arriving here, so it will almost always be valid UTF-8. But for raw binary responses or decode failures, the hex fallback ensures something readable is always shown.

---

## 7. Bugs Found and Fixed

All bugs were observed against `grpcb.in:9000` (h2c, no TLS, standard test server).

### Bug 1 — Default TLS / Port Mismatch

**Symptom:** Connection fails immediately, never reaches the server.

**Root cause:** `useTls = true` (default) + `port = 443` — `grpcb.in:9000` requires h2c and port 9000. The TLS handshake was sent to a non-TLS port.

**Fix:** Changed constructor defaults to `useTls = false`, `port = 50051`. Updated `.g.dart` JSON fallbacks to match.

---

### Bug 2 — DNS Fails with "grpcb.in:9000" in Host Field

**Symptom:** `Failed host lookup: 'grpcb.in:9000'`

**Root cause:** The user naturally typed `grpcb.in:9000` in the host field. `ClientChannel("grpcb.in:9000", port: 50051)` passed the entire string as the hostname to DNS resolution. DNS cannot resolve `grpcb.in:9000` as a hostname.

**Fix:** Added host:port splitting in `connectGrpc()` before constructing the channel.

---

### Bug 3 — Stale Port (e.g. port = 49517)

**Symptom:** After typing a port, invoke showed a random ephemeral port like 49517 in the error message.

**Root cause:** `GrpcPortField.onChanged` captured `requestModel` from the `build()` scope. Between the `build()` call and the `onChanged` call, `connectGrpc()` had parsed `"grpcb.in:9000"` and written a new model. The closure then called `copyWith(port: p)` on the stale old model, which had a stale port, partly overwriting the host update.

**Fix:** Read the model inline inside `onChanged` instead of using the captured variable.

---

### Bug 4 — Reflection Kills Main Channel (GOAWAY after connect)

**Symptom:** Services were discovered successfully, then the first invoke immediately returned `GOAWAY errorCode: 10`.

**Root cause:** `_discoverViaReflection` called `.first` on bidi streams. This sent `RST_STREAM` to cancel the stream after reading one response. The server (`grpcb.in`) treated `RST_STREAM` as connection-fatal and closed the entire HTTP/2 connection with `GOAWAY`. Since reflection and invocations shared the same `ClientChannel`, the invoke arrived on a dead connection.

**Fix:** Run reflection on a separate ephemeral `ClientChannel`, shut it down cleanly after use. The main `_channel` is never touched by reflection.

---

### Bug 5 — Wrong Wire Types (GOAWAY on every invoke)

**Symptom:** `gRPC Error 2: HTTP/2 error: Connection is being forcefully terminated. (errorCode: 10)` — every invoke, regardless of method.

**Root cause:** The old encoder used `PbFieldType.writeField` with wrong constants for these proto field types:

| Field type | Old constant | Wire type sent | Correct wire type |
|---|---|---|---|
| `SFIXED32` | `O3` (int32) | 0 (varint) | **5 (4-byte fixed)** |
| `FIXED32` | `OU3` (uint32) | 0 (varint) | **5 (4-byte fixed)** |
| `SFIXED64` | `O6` (int64) | 0 (varint) | **1 (8-byte fixed)** |
| `FIXED64` | `O6` (int64) | 0 (varint) | **1 (8-byte fixed)** |
| `SINT32` | `O3` | 0, no zigzag | 0, with zigzag |
| `SINT64` | `O6` | 0, no zigzag | 0, with zigzag |

Even for messages that contained none of those field types, the mismatch in the request message the server received corrupted field boundary tracking in the server's protobuf parser, producing `GOAWAY`.

**Fix:** Complete rewrite of `jsonToProtobuf` / `_encodeField` using `_Buf` + direct varint encoding with correct wire types for every field type. Also fixed `protobufToJson` decoder to read `FIXED32`/`SFIXED32` from `fixed32s` bucket, `FIXED64`/`SFIXED64` from `fixed64s`, and un-zigzag `SINT32`/`SINT64`.

---

*End of document.*
