import 'package:flutter/material.dart';

import '../app_state.dart';
import 'common.dart';

class LogsPage extends StatelessWidget {
  final AppState state;
  const LogsPage({super.key, required this.state});

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        SectionTitle(
          '内核日志',
          tail: '${state.logs.length} 行（最新在上）',
          trailing: Btn(
            label: '清空',
            onTap: () {
              state.logs.clear();
              state.setError(null);
            },
          ),
        ),
        Expanded(
          child: state.logs.isEmpty
              ? Center(child: Text('暂无日志', style: mono.copyWith(color: dim)))
              : ListView.builder(
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  itemCount: state.logs.length,
                  itemBuilder: (context, i) {
                    final line = state.logs[i];
                    final isErr = line.startsWith('[err]') || line.contains('level=error');
                    return Padding(
                      padding: const EdgeInsets.symmetric(vertical: 1),
                      child: Text(
                        line,
                        style: mono.copyWith(fontSize: 11, color: isErr ? red : dim, height: 1.35),
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }
}
