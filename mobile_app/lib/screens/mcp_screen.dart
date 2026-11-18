import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_fonts/google_fonts.dart';
import '../services/api_client.dart';
import '../widgets/app_sidebar.dart';

final mcpServersProvider = FutureProvider.autoDispose<List<dynamic>>((ref) {
  return ref.watch(apiClientProvider).getMcpServers();
});

final skillsProvider = FutureProvider.autoDispose<List<dynamic>>((ref) {
  return ref.watch(apiClientProvider).getSkills();
});

final pluginsProvider = FutureProvider.autoDispose<List<dynamic>>((ref) {
  return ref.watch(apiClientProvider).getPlugins();
});

class McpScreen extends ConsumerWidget {
  const McpScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return DefaultTabController(
      length: 3,
      child: Scaffold(
        appBar: AppBar(
          title: Text(
            'Customizations & MCP',
            style: GoogleFonts.jetBrainsMono(fontWeight: FontWeight.bold, fontSize: 18),
          ),
          bottom: const TabBar(
            tabs: [
              Tab(icon: Icon(Icons.hub_outlined), text: 'MCP Servers'),
              Tab(icon: Icon(Icons.auto_awesome_outlined), text: 'Skills'),
              Tab(icon: Icon(Icons.extension_outlined), text: 'Plugins'),
            ],
          ),
        ),
        drawer: const AppSidebar(),
        body: TabBarView(
          children: [
            _buildMcpTab(context, ref),
            _buildSkillsTab(context, ref),
            _buildPluginsTab(context, ref),
          ],
        ),
      ),
    );
  }

  Widget _buildMcpTab(BuildContext context, WidgetRef ref) {
    final colorScheme = Theme.of(context).colorScheme;
    final mcpAsync = ref.watch(mcpServersProvider);

    return RefreshIndicator(
      onRefresh: () async => ref.refresh(mcpServersProvider),
      child: mcpAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (err, stack) => Center(
          child: Padding(
            padding: const EdgeInsets.all(24.0),
            child: Text('Failed to load MCP servers: $err', style: TextStyle(color: colorScheme.error)),
          ),
        ),
        data: (servers) {
          if (servers.isEmpty) {
            return Center(
              child: Text('No active MCP servers found', style: TextStyle(color: colorScheme.onSurfaceVariant)),
            );
          }

          return ListView.builder(
            padding: const EdgeInsets.all(16),
            itemCount: servers.length,
            itemBuilder: (context, index) {
              final s = servers[index] as Map<String, dynamic>;
              final spec = s['spec'] as Map<String, dynamic>? ?? {};
              final serverName = spec['serverName'] as String? ?? 'Unnamed Server';
              final status = s['status'] as String? ?? 'UNKNOWN';
              final isReady = status.contains('READY');
              final tools = s['tools'] as List<dynamic>? ?? [];

              return Card(
                margin: const EdgeInsets.only(bottom: 12),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                  side: BorderSide(color: colorScheme.outlineVariant),
                ),
                child: ExpansionTile(
                  leading: Icon(
                    Icons.circle,
                    size: 14,
                    color: isReady ? Colors.green : Colors.amber,
                  ),
                  title: Text(
                    serverName,
                    style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                  ),
                  subtitle: Text(
                    '${isReady ? "Ready" : status} • ${tools.length} tools available',
                    style: TextStyle(color: colorScheme.onSurfaceVariant, fontSize: 12),
                  ),
                  children: [
                    if (tools.isEmpty)
                      const Padding(
                        padding: EdgeInsets.all(16.0),
                        child: Text('No tools reported by this server.'),
                      )
                    else
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: tools.map((t) {
                            final toolName = t['name'] as String? ?? '';
                            final toolDesc = t['description'] as String? ?? '';
                            return Padding(
                              padding: const EdgeInsets.only(bottom: 8.0),
                              child: Row(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Icon(Icons.build_outlined, size: 16, color: colorScheme.primary),
                                  const SizedBox(width: 8),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          toolName,
                                          style: GoogleFonts.jetBrainsMono(
                                            fontWeight: FontWeight.w600,
                                            fontSize: 13,
                                            color: colorScheme.primary,
                                          ),
                                        ),
                                        if (toolDesc.isNotEmpty)
                                          Text(
                                            toolDesc,
                                            style: TextStyle(color: colorScheme.onSurfaceVariant, fontSize: 11),
                                          ),
                                      ],
                                    ),
                                  ),
                                ],
                              ),
                            );
                          }).toList(),
                        ),
                      ),
                  ],
                ),
              );
            },
          );
        },
      ),
    );
  }

  Widget _buildSkillsTab(BuildContext context, WidgetRef ref) {
    final colorScheme = Theme.of(context).colorScheme;
    final skillsAsync = ref.watch(skillsProvider);

    return RefreshIndicator(
      onRefresh: () async => ref.refresh(skillsProvider),
      child: skillsAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (err, stack) => Center(
          child: Padding(
            padding: const EdgeInsets.all(24.0),
            child: Text('Failed to load skills: $err', style: TextStyle(color: colorScheme.error)),
          ),
        ),
        data: (skills) {
          if (skills.isEmpty) {
            return Center(
              child: Text('No skills registered', style: TextStyle(color: colorScheme.onSurfaceVariant)),
            );
          }

          return ListView.builder(
            padding: const EdgeInsets.all(16),
            itemCount: skills.length,
            itemBuilder: (context, index) {
              final skill = skills[index] as Map<String, dynamic>;
              final name = skill['name'] as String? ?? 'Unnamed Skill';
              final desc = skill['description'] as String? ?? 'No description';

              return Card(
                margin: const EdgeInsets.only(bottom: 12),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                  side: BorderSide(color: colorScheme.outlineVariant),
                ),
                child: ListTile(
                  leading: Icon(Icons.auto_awesome, color: colorScheme.secondary),
                  title: Text(name, style: const TextStyle(fontWeight: FontWeight.bold)),
                  subtitle: Padding(
                    padding: const EdgeInsets.only(top: 4.0),
                    child: Text(desc, style: TextStyle(color: colorScheme.onSurfaceVariant, fontSize: 12)),
                  ),
                ),
              );
            },
          );
        },
      ),
    );
  }

  Widget _buildPluginsTab(BuildContext context, WidgetRef ref) {
    final colorScheme = Theme.of(context).colorScheme;
    final pluginsAsync = ref.watch(pluginsProvider);

    return RefreshIndicator(
      onRefresh: () async => ref.refresh(pluginsProvider),
      child: pluginsAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (err, stack) => Center(
          child: Padding(
            padding: const EdgeInsets.all(24.0),
            child: Text('Failed to load plugins: $err', style: TextStyle(color: colorScheme.error)),
          ),
        ),
        data: (plugins) {
          if (plugins.isEmpty) {
            return Center(
              child: Text('No plugins available', style: TextStyle(color: colorScheme.onSurfaceVariant)),
            );
          }

          return ListView.builder(
            padding: const EdgeInsets.all(16),
            itemCount: plugins.length,
            itemBuilder: (context, index) {
              final plugin = plugins[index] as Map<String, dynamic>;
              final title = plugin['title'] as String? ?? plugin['id'] as String? ?? 'Plugin';
              final desc = plugin['description'] as String? ?? '';

              return Card(
                margin: const EdgeInsets.only(bottom: 12),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                  side: BorderSide(color: colorScheme.outlineVariant),
                ),
                child: ListTile(
                  leading: Icon(Icons.extension, color: colorScheme.primary),
                  title: Text(title, style: const TextStyle(fontWeight: FontWeight.bold)),
                  subtitle: desc.isNotEmpty
                      ? Padding(
                          padding: const EdgeInsets.only(top: 4.0),
                          child: Text(desc, style: TextStyle(color: colorScheme.onSurfaceVariant, fontSize: 12)),
                        )
                      : null,
                ),
              );
            },
          );
        },
      ),
    );
  }
}
