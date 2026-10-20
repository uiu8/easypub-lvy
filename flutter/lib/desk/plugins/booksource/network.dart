part of '../booksource_page.dart';

class _NetworkDialog extends StatefulWidget {
  const _NetworkDialog(this.api, this.config);
  final BookSourceApi api;
  final Map config;
  @override
  State<_NetworkDialog> createState() => _NetworkDialogState();
}

class _NetworkDialogState extends State<_NetworkDialog> {
  late String mode = '${widget.config['mode'] ?? 'none'}';
  late String scope = '${widget.config['scope'] ?? 'all'}';
  late bool bypassLocal = widget.config['bypassLocal'] != false;
  late final address = TextEditingController(
    text: '${widget.config['url'] ?? ''}',
  );
  late final bypass = TextEditingController(
    text: '${widget.config['noProxy'] ?? ''}',
  );
  late final timeout = TextEditingController(
    text: '${(_num(widget.config['connectTimeoutMs'] ?? 8000) / 1000).round()}',
  );
  final target = TextEditingController(text: 'https://www.yckceo.com');
  late Map system = widget.config['system'] as Map? ?? {};
  List samples = [];
  String? error;
  bool busy = false;
  Map<String, dynamic> draft() => {
    'mode': mode,
    'scope': scope,
    'url': address.text.trim(),
    'bypassLocal': bypassLocal,
    'noProxy': bypass.text.trim(),
    'connectTimeoutMs': (int.tryParse(timeout.text) ?? 0) * 1000,
    'keepCredentials': true,
  };
  Future<void> run(String action) async {
    setState(() {
      busy = true;
      error = null;
    });
    try {
      if (action == 'refresh') {
        final result = await widget.api.call('network.proxy.refresh') as Map;
        if (mounted) setState(() => system = result['system'] as Map? ?? {});
      } else if (action == 'test') {
        final result = await widget.api.call('network.proxy.test', {
          'config': draft(),
          'url': target.text.trim(),
        }) as Map;
        if (mounted) setState(() => samples = result['samples'] as List? ?? []);
      } else {
        await widget.api.call('network.proxy.set', {'config': draft()});
        if (mounted) Navigator.pop(context);
      }
    } catch (e) {
      if (mounted) setState(() => error = '$e');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  void dispose() {
    for (final c in [address, bypass, timeout, target]) {
      c.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('网络与代理'),
    content: SizedBox(
      width: 600,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            DropdownButtonFormField<String>(
              key: const ValueKey('network-mode'),
              initialValue: mode.isEmpty ? 'none' : mode,
              decoration: const InputDecoration(labelText: '连接方式'),
              items: const [
                DropdownMenuItem(value: 'none', child: Text('直连')),
                DropdownMenuItem(value: 'system', child: Text('系统代理')),
                DropdownMenuItem(value: 'manual', child: Text('手动代理')),
              ],
              onChanged: busy ? null : (v) => setState(() => mode = v!),
            ),
            if (mode == 'system') ...[
              const SizedBox(height: 12),
              DeskText(
                system['available'] == true
                    ? '${system['source'] ?? '系统设置'}\nHTTP：${system['http'] ?? ''}\nHTTPS：${system['https'] ?? ''}'
                    : '未检测到系统静态代理。',
                size: 12,
              ),
              if (system['pac'] == true)
                const DeskNote(
                  '检测到 PAC。请改填代理软件的本机端口；插件暂不执行 PAC。',
                  tone: Tone.warn,
                ),
              DeskButton(
                '重新读取系统代理',
                key: const ValueKey('network-refresh'),
                quiet: true,
                onPressed: busy ? null : () => run('refresh'),
              ),
            ],
            if (mode == 'manual') ...[
              TextField(
                key: const ValueKey('network-address'),
                controller: address,
                enabled: !busy,
                obscureText: true,
                decoration: const InputDecoration(
                  labelText: '代理地址',
                  hintText: 'http://127.0.0.1:端口 或 socks5h://127.0.0.1:端口',
                ),
              ),
              const DeskText(
                'SOCKS5 使用本机 DNS；SOCKS5h 交给代理解析。账号密码仅本次运行有效。',
                size: 12,
              ),
            ],
            const SizedBox(height: 12),
            DropdownButtonFormField<String>(
              key: const ValueKey('network-scope'),
              initialValue: scope,
              decoration: const InputDecoration(labelText: '代理作用范围'),
              items: const [
                DropdownMenuItem(value: 'all', child: Text('全部书源与网址导入')),
                DropdownMenuItem(value: 'marked', child: Text('仅指定书源与网址导入')),
              ],
              onChanged: busy ? null : (v) => setState(() => scope = v!),
            ),
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              value: bypassLocal,
              dense: true,
              title: const Text('本机服务直连（localhost / 回环 IP）'),
              onChanged: busy ? null : (v) => setState(() => bypassLocal = v!),
            ),
            TextField(
              controller: bypass,
              enabled: !busy,
              decoration: const InputDecoration(
                labelText: '其他直连地址',
                hintText: '域名或 IP，逗号分隔；example.com 包含其子域名',
              ),
            ),
            TextField(
              key: const ValueKey('network-timeout'),
              controller: timeout,
              enabled: !busy,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(labelText: '连接超时（1–60 秒）'),
            ),
            const SizedBox(height: 12),
            const DeskText('每个书源可单独选择直连。TUN 若开启，仍可能接管系统网络。', size: 12),
            const Divider(height: 24),
            TextField(
              key: const ValueKey('network-target'),
              controller: target,
              enabled: !busy,
              decoration: const InputDecoration(labelText: '测试网址'),
            ),
            DeskButton(
              busy ? '正在检测…' : '对比直连与当前选择',
              key: const ValueKey('network-test'),
              onPressed: busy ? null : () => run('test'),
            ),
            const DeskText('测试不保存设置，仅读取少量响应；每条路径最多等待 20 秒。', size: 12),
            for (final result in samples)
              Padding(
                padding: const EdgeInsets.only(top: 10),
                child: SelectableText(
                  '${result['label']}：${result['ok'] == true ? 'HTTP ${result['status']} · ${result['protocol']}' : result['error']} · ${result['ms']} ms\n'
                  '${result['route']?['reason'] ?? ''}'
                  '${result['route']?['endpoint'] == null ? '' : ' · ${result['route']['endpoint']}'}',
                ),
              ),
            if (error != null) DeskNote(error!, tone: Tone.warn),
          ],
        ),
      ),
    ),
    actions: [
      DeskButton(
        '取消',
        quiet: true,
        onPressed: busy ? null : () => Navigator.pop(context),
      ),
      DeskButton(
        '保存',
        key: const ValueKey('network-save'),
        primary: true,
        onPressed: busy ? null : () => run('save'),
      ),
    ],
  );
}
