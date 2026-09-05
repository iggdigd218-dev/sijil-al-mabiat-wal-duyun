// ويدجت مؤشر حالة المزامنة في شريط الحالة.
import 'package:flutter/material.dart';

import '../../data/sync/sync_service.dart';

class SyncStatusBadge extends StatelessWidget {
  final SyncStatusInfo info;
  final VoidCallback? onTap;
  const SyncStatusBadge({super.key, required this.info, this.onTap});

  @override
  Widget build(BuildContext context) {
    final (icon, color, label) = switch (info.state) {
      SyncState.synced => (Icons.cloud_done, Colors.green, 'متزامن'),
      SyncState.syncing => (Icons.sync, Colors.amber, 'جاري المزامنة'),
      SyncState.pending => (Icons.cloud_upload, Colors.orange, 'في الانتظار (${info.pending})'),
      SyncState.failed => (Icons.error_outline, Colors.red, 'فشل (${info.failed})'),
      SyncState.offline => (Icons.cloud_off, Colors.grey, 'غير فعّال'),
    };
    return Tooltip(
      message: label,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(6),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 16, color: color),
              if (info.pending > 0 || info.failed > 0) ...[
                const SizedBox(width: 4),
                Text('${info.pending + info.failed}',
                    style: TextStyle(fontSize: 11, color: color)),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
