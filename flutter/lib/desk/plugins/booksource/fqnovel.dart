part of '../booksource_page.dart';

/// 接入本机 FQNovel（LIB-211）：只填端口，地址固定为本机 127.0.0.1。先检测，就绪后经订阅导入；
/// 已订阅过时转到订阅差异确认。EasyPub 不内置 FQNovel 的签名或设备程序。
extension _BookSourceFqnovel on _BookSourcePageState {
  static const _workers = {
    'ready': '已就绪',
    'starting': '正在启动',
    'stopped': '已停止',
    'unknown': '状态未知',
  };

  Future<void> _fqnovel() async {
    final port = TextEditingController(text: '9999');
    Map? health, imported;
    String? error;
    int? importedPort;
    bool busy = false;
    await showDialog<void>(
      context: context,
      builder: (dialog) => DeskControllerScope(
        controllers: [port],
        child: StatefulBuilder(
          builder: (dialog, change) {
            final d = dialog.desk;
            Future<void> run(bool import) async {
              final p = int.tryParse(port.text.trim());
              if (p == null || p < 1 || p > 65535) {
                change(() => error = '端口须为 1–65535 的数字。');
                return;
              }
              change(() {
                busy = true;
                error = null;
              });
              try {
                if (import) {
                  final r =
                      await api!.call('fqnovel.import', {'port': p}) as Map;
                  health = r['health'] as Map?;
                  if (r['imported'] == true) {
                    imported = r['subscription'] as Map;
                    importedPort = p;
                    if (dialog.mounted) Navigator.pop(dialog);
                    return;
                  }
                } else {
                  health =
                      await api!.call('fqnovel.detect', {'port': p}) as Map;
                }
              } catch (e) {
                error = bookSourceErrorText(e);
              }
              if (dialog.mounted) change(() => busy = false);
            }

            final h = health;
            final ready = h?['ready'] == true;
            return DeskAlert(
              key: const ValueKey('booksource-fqnovel-dialog'),
              title: const Text('接入本机 FQNovel'),
              content: SizedBox(
                width: 460,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const DeskText(
                      '先在这台电脑上打开 FQNovel Desktop，等它就绪后再接入。EasyPub 只读取它在本机提供的书源，之后的更新照常在“订阅与更新”里确认。',
                      size: 13,
                    ),
                    const SizedBox(height: 14),
                    Row(
                      children: [
                        const DeskText('127.0.0.1 :', size: 13),
                        const SizedBox(width: 8),
                        SizedBox(
                          width: 90,
                          child: TextField(
                            key: const ValueKey('booksource-fqnovel-port'),
                            controller: port,
                            enabled: !busy,
                            keyboardType: TextInputType.number,
                            inputFormatters: [
                              FilteringTextInputFormatter.digitsOnly,
                              LengthLimitingTextInputFormatter(5),
                            ],
                            decoration: const InputDecoration(
                              isDense: true,
                              hintText: '端口',
                            ),
                            onChanged: (_) => change(() => health = null),
                          ),
                        ),
                        const SizedBox(width: 10),
                        DeskButton(
                          '检测',
                          key: const ValueKey('booksource-fqnovel-detect'),
                          busy: busy,
                          onPressed: busy ? null : () => run(false),
                        ),
                      ],
                    ),
                    if (h != null) ...[
                      const SizedBox(height: 12),
                      Row(
                        key: const ValueKey('booksource-fqnovel-status'),
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Padding(
                            padding: const EdgeInsets.only(top: 5),
                            child: Container(
                              width: 8,
                              height: 8,
                              decoration: BoxDecoration(
                                color: ready
                                    ? d.add
                                    : h['running'] == true
                                    ? d.warn
                                    : d.pen,
                                shape: BoxShape.circle,
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                DeskText(
                                  h['running'] != true
                                      ? '没有检测到 FQNovel'
                                      : h['service'] == null
                                      ? '这个端口上不是 FQNovel'
                                      : 'FQNovel Desktop · ${_workers[h['worker']] ?? '状态未知'}',
                                  size: 13,
                                  bold: true,
                                ),
                                DeskText(
                                  '${h['next_action'] ?? ''}',
                                  size: 12.5,
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ],
                    if (error != null) ...[
                      const SizedBox(height: 10),
                      DeskNote(error!, tone: Tone.warn),
                    ],
                    const SizedBox(height: 12),
                    const DeskNote(
                      'FQNovel 的服务没有密码，只支持本机地址，不要把它的监听范围改成局域网。检测最多等 1 秒，读取书源最多 10 秒；关掉这个窗口不会中断已经发出的请求。',
                    ),
                  ],
                ),
              ),
              actions: [
                DeskButton(
                  '关闭',
                  quiet: true,
                  onPressed: () => Navigator.pop(dialog),
                ),
                DeskButton(
                  '接入',
                  key: const ValueKey('booksource-fqnovel-import'),
                  primary: true,
                  busy: busy && ready,
                  onPressed: busy || !ready ? null : () => run(true),
                  disabledReason: ready ? null : '先检测，FQNovel 就绪后才能接入',
                ),
              ],
            );
          },
        ),
      ),
    );
    final result = imported;
    if (result == null || !mounted) return;
    final url = 'http://127.0.0.1:$importedPort/book-source/fqnovel.json';
    await _loadSources();
    update(() => sourceMessage = '本机 FQNovel：${_importSummary(result)}');
    if (result['previewRequired'] == true && mounted) {
      await _subscriptionPreview(url, result['subscription'] as Map);
    }
  }
}
