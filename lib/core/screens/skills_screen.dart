// Skills browser — list installed skills with enabled/disabled status.
import 'package:flutter/material.dart';
import '../services/connection_manager.dart';
import '../../nextgen/theme/nextgen_theme.dart';
import '../../nextgen/ui/widgets.dart';

import 'package:hermes_android/core/l10n/l10n.dart';

class SkillsScreen extends StatefulWidget {
  final SavedConnection connection;
  const SkillsScreen({required this.connection, super.key});

  @override
  State<SkillsScreen> createState() => _SkillsScreenState();
}

class _SkillsScreenState extends State<SkillsScreen> {
  late DashboardClient _client;
  List<Map<String, dynamic>> _skills = [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _client = DashboardClient.fromConnection(widget.connection);
    _load();
  }

  @override
  void dispose() {
    _client.close();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final raw = await _client.getSkills();
      if (!mounted) return;
      setState(() {
        _skills = raw.whereType<Map<String, dynamic>>().toList();
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return NgPage(
      title: context.l10n.skills_2(_skills.length),
      actions: [
        IconButton(
          icon: const Icon(Icons.refresh),
          onPressed: _loading ? null : _load,
        ),
      ],
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    final c = NgColors.of(context);
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) {
      return NgEmpty(
        icon: Icons.error_outline,
        title: context.l10n.failed_to_load_skills,
        body: _error,
        action: TextButton(onPressed: _load, child: Text(context.l10n.retry)),
      );
    }
    if (_skills.isEmpty) {
      return NgEmpty(
        icon: Icons.extension_off,
        title: context.l10n.no_skills_found,
      );
    }
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView.builder(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 32),
        itemCount: _skills.length,
        itemBuilder: (_, i) {
          final skill = _skills[i];
          final name = skill['name'] as String? ?? '';
          final enabled = skill['enabled'] as bool? ?? false;
          final description = skill['description'] as String? ?? '';
          return Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: NgCard(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(name, style: NgType.code.copyWith(color: c.text)),
                        if (description.isNotEmpty) ...[
                          const SizedBox(height: 4),
                          Text(
                            description,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: NgType.caption.copyWith(color: c.text3),
                          ),
                        ],
                      ],
                    ),
                  ),
                  const SizedBox(width: 12),
                  Icon(
                    enabled ? Icons.check_circle : Icons.block,
                    color: enabled ? c.success : c.warning,
                    size: 18,
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}
