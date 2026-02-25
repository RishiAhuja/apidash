import 'dart:convert';
import 'package:apidash_core/apidash_core.dart';
import 'package:apidash_design_system/apidash_design_system.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:apidash/providers/providers.dart';
import 'package:apidash/consts.dart';

class GrpcResponsePane extends ConsumerWidget {
  const GrpcResponsePane({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final selectedId = ref.watch(selectedIdStateProvider);
    if (selectedId == null) return kSizedBoxEmpty;

    final connectionInfo = ref.watch(grpcConnectionProvider(selectedId));
    final results = ref.watch(grpcResponseProvider(selectedId));

    return Column(
      children: [
        // Connection status header
        GrpcConnectionStatusHeader(
          connectionInfo: connectionInfo,
          onClear: () {
            ref.read(grpcResponseProvider(selectedId).notifier).clear();
          },
        ),
        // Response content
        Expanded(
          child: connectionInfo.state == GrpcConnectionState.disconnected &&
                  results.isEmpty
              ? const GrpcNotConnectedWidget()
              : connectionInfo.state == GrpcConnectionState.error
                  ? GrpcErrorWidget(
                      errorMessage: connectionInfo.errorMessage)
                  : results.isEmpty
                      ? const GrpcEmptyResponseWidget()
                      : GrpcResponseList(results: results),
        ),
      ],
    );
  }
}

class GrpcConnectionStatusHeader extends StatelessWidget {
  const GrpcConnectionStatusHeader({
    super.key,
    required this.connectionInfo,
    this.onClear,
  });

  final GrpcConnectionInfo connectionInfo;
  final VoidCallback? onClear;

  @override
  Widget build(BuildContext context) {
    final statusColor = switch (connectionInfo.state) {
      GrpcConnectionState.connected => Colors.green,
      GrpcConnectionState.connecting => Colors.orange,
      GrpcConnectionState.error => Colors.red,
      GrpcConnectionState.disconnected => Colors.grey,
    };

    final statusText = switch (connectionInfo.state) {
      GrpcConnectionState.connected => kLabelGrpcConnected,
      GrpcConnectionState.connecting => kLabelGrpcConnecting,
      GrpcConnectionState.error => "Error",
      GrpcConnectionState.disconnected => kLabelGrpcDisconnected,
    };

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(
            color: Theme.of(context).colorScheme.surfaceContainerHighest,
          ),
        ),
      ),
      child: Row(
        children: [
          Container(
            width: 10,
            height: 10,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: statusColor,
            ),
          ),
          kHSpacer8,
          Text(
            statusText,
            style: TextStyle(
              fontWeight: FontWeight.bold,
              color: statusColor,
            ),
          ),
          if (connectionInfo.services.isNotEmpty) ...[
            kHSpacer8,
            Text(
              "${connectionInfo.services.length} service${connectionInfo.services.length != 1 ? 's' : ''}",
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
          const Spacer(),
          IconButton(
            icon: const Icon(Icons.delete_outline, size: 18),
            tooltip: kTooltipClearResponse,
            onPressed: onClear,
            visualDensity: VisualDensity.compact,
          ),
        ],
      ),
    );
  }
}

class GrpcNotConnectedWidget extends StatelessWidget {
  const GrpcNotConnectedWidget({super.key});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.cloud_off_outlined,
            size: 48,
            color: Theme.of(context).colorScheme.outlineVariant,
          ),
          kVSpacer10,
          Text(
            kLabelGrpcNotConnected,
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  color: Theme.of(context).colorScheme.outlineVariant,
                ),
          ),
          kVSpacer5,
          Text(
            kMsgGrpcConnectFirst,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.outlineVariant,
                ),
          ),
        ],
      ),
    );
  }
}

class GrpcEmptyResponseWidget extends StatelessWidget {
  const GrpcEmptyResponseWidget({super.key});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.send_outlined,
            size: 48,
            color: Theme.of(context).colorScheme.outlineVariant,
          ),
          kVSpacer10,
          Text(
            "Select a method and click Invoke",
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.outlineVariant,
                ),
          ),
        ],
      ),
    );
  }
}

class GrpcErrorWidget extends StatelessWidget {
  const GrpcErrorWidget({super.key, this.errorMessage});
  final String? errorMessage;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(24.0),
      child: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.error_outline,
              size: 48,
              color: Theme.of(context).colorScheme.error,
            ),
            kVSpacer10,
            Text(
              "Connection Error",
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    color: Theme.of(context).colorScheme.error,
                  ),
            ),
            if (errorMessage != null) ...[
              kVSpacer5,
              SelectableText(
                errorMessage!,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(context).colorScheme.error,
                    ),
                textAlign: TextAlign.center,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class GrpcResponseList extends StatelessWidget {
  const GrpcResponseList({super.key, required this.results});
  final List<GrpcCallResult> results;

  @override
  Widget build(BuildContext context) {
    return ListView.builder(
      padding: kP8,
      itemCount: results.length,
      itemBuilder: (context, index) {
        return GrpcResponseCard(
          result: results[index],
          index: index,
        );
      },
    );
  }
}

class GrpcResponseCard extends StatelessWidget {
  const GrpcResponseCard({
    super.key,
    required this.result,
    required this.index,
  });

  final GrpcCallResult result;
  final int index;

  @override
  Widget build(BuildContext context) {
    final isSuccess = result.statusCode == 0;
    final statusColor = isSuccess ? Colors.green : Colors.red;
    final statusLabel = isSuccess ? "OK" : "Error ${result.statusCode}";

    return Card(
      margin: kPv2,
      child: Padding(
        padding: kP8,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Status header
            Row(
              children: [
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  decoration: BoxDecoration(
                    color: statusColor.withValues(alpha: 0.15),
                    borderRadius: kBorderRadius4,
                  ),
                  child: Text(
                    statusLabel,
                    style: kCodeStyle.copyWith(
                      fontSize: 12,
                      color: statusColor,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
                kHSpacer8,
                if (result.statusMessage != null &&
                    result.statusMessage!.isNotEmpty)
                  Expanded(
                    child: Text(
                      result.statusMessage!,
                      style: Theme.of(context).textTheme.bodySmall,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                const Spacer(),
                Text(
                  "${result.duration?.inMilliseconds ?? 0} ms",
                  style: kCodeStyle.copyWith(
                    fontSize: 11,
                    color: Theme.of(context).colorScheme.outline,
                  ),
                ),
              ],
            ),
            if (result.responseHeaders.isNotEmpty) ...[
              kVSpacer5,
              _MetadataSection(
                label: "Response Headers",
                data: result.responseHeaders,
                context: context,
              ),
            ],
            if (result.responseTrailers.isNotEmpty) ...[
              kVSpacer5,
              _MetadataSection(
                label: "Trailers",
                data: result.responseTrailers,
                context: context,
              ),
            ],
            // Response messages
            if (result.responseMessages.isNotEmpty) ...[
              kVSpacer5,
              Text(
                "Response (${result.responseMessages.length} message${result.responseMessages.length != 1 ? 's' : ''})",
                style: Theme.of(context).textTheme.labelSmall,
              ),
              kVSpacer3,
              ...result.responseMessages.indexed.map((entry) {
                final (_, msgBytes) = entry;
                // Try to show as UTF-8 text, fallback to hex
                String displayText;
                try {
                  displayText = utf8.decode(msgBytes);
                } catch (_) {
                  displayText = msgBytes
                      .map((b) => b.toRadixString(16).padLeft(2, '0'))
                      .join(' ');
                }
                return Container(
                  width: double.infinity,
                  margin: kPv2,
                  padding: kP8,
                  decoration: BoxDecoration(
                    color: Theme.of(context)
                        .colorScheme
                        .surfaceContainerLowest,
                    borderRadius: kBorderRadius6,
                    border: Border.all(
                      color: Theme.of(context)
                          .colorScheme
                          .surfaceContainerHighest,
                    ),
                  ),
                  child: SelectableText(
                    displayText,
                    style: kCodeStyle.copyWith(fontSize: 12),
                  ),
                );
              }),
            ],
            if (result.error != null) ...[
              kVSpacer5,
              Text(
                result.error!,
                style: TextStyle(
                  color: Theme.of(context).colorScheme.error,
                  fontSize: 12,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _MetadataSection extends StatelessWidget {
  const _MetadataSection({
    required this.label,
    required this.data,
    required this.context,
  });

  final String label;
  final Map<String, String> data;
  final BuildContext context;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: Theme.of(context).textTheme.labelSmall,
        ),
        ...data.entries.map((e) => Padding(
              padding: kPv2,
              child: Row(
                children: [
                  Text(
                    "${e.key}: ",
                    style: kCodeStyle.copyWith(
                      fontSize: 11,
                      fontWeight: FontWeight.bold,
                      color: Theme.of(context).colorScheme.outline,
                    ),
                  ),
                  Expanded(
                    child: Text(
                      e.value,
                      style: kCodeStyle.copyWith(
                        fontSize: 11,
                        color: Theme.of(context).colorScheme.outline,
                      ),
                    ),
                  ),
                ],
              ),
            )),
      ],
    );
  }
}
