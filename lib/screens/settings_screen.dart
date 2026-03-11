import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:package_info_plus/package_info_plus.dart';
import '../providers/theme_provider.dart';
import '../services/update_service.dart';

class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isDark = ref.watch(themeProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('設定', style: TextStyle(fontSize: 16))),
      body: ListView(
        children: [
          SwitchListTile(
            secondary: Icon(isDark ? Icons.dark_mode : Icons.light_mode),
            title: const Text('ダークモード'),
            value: isDark,
            onChanged: (v) => ref.read(themeProvider.notifier).state = v,
          ),
          const Divider(height: 1),
          ListTile(
            leading: const Icon(Icons.system_update),
            title: const Text('アップデートを確認'),
            onTap: () {
              UpdateService.checkForUpdate(context);
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text('最新版を確認中...'),
                  duration: Duration(seconds: 2),
                ),
              );
            },
          ),
          const Divider(height: 1),
          FutureBuilder<PackageInfo>(
            future: PackageInfo.fromPlatform(),
            builder: (ctx, snap) {
              final version = snap.data?.version ?? '...';
              final build = snap.data?.buildNumber ?? '';
              return ListTile(
                leading: const Icon(Icons.info_outline),
                title: const Text('バージョン'),
                subtitle: Text('v$version+$build'),
              );
            },
          ),
        ],
      ),
    );
  }
}
