part of '../booksource_page.dart';

/// V97 书源交互（LIB-212、LIB-213）：书源脚本在登录、读取详情和目录时请求验证码、登录字段、提示或复制。
/// 按书源显式启用，回复按 source_id + request_id 配对；图片、输入与提示文字都不写日志。
/// 没有发现页，所以不声明 explore_refresh。
extension _BookSourceInteractions on _BookSourcePageState {
  /// book_search、login_open：书源脚本请求搜索或打开登录（LIB-240 协议，LIB-280 界面）。
  static const _capabilities = [
    'notice',
    'clipboard',
    'book_search',
    'login_open',
  ];

  /// 调用会执行书源脚本的接口前启用交互。书源运行时会随启停、订阅更新重建，所以每次都重新启用。
  Future<void> _enableInteractions(String id) async {
    try {
      await api!.call('source.interaction.enable', {
        'id': id,
        'enabled': true,
        'capabilities': _capabilities,
      });
      interactionSources.add(id);
    } catch (_) {
      // 启用失败时，书源脚本会得到“界面尚未连接”的明确错误，原调用照常进行。
    }
  }

  /// 离开书源页：停用交互，后端取消这些书源所有等待中的请求。
  void _disableInteractions() {
    for (final id in interactionSources) {
      api
          ?.call('source.interaction.enable', {'id': id, 'enabled': false})
          .then((_) {}, onError: (_) {});
    }
    interactionSources.clear();
  }

  Future<void> _reply(Map e, Object? value, {bool cancel = false}) async {
    final requestId = '${e['request_id']}';
    if (interactionClosed.remove(requestId)) return;
    try {
      await api!.call('source.interaction.reply', {
        'id': e['source_id'],
        'request_id': requestId,
        if (cancel) 'cancel': true else 'value': value,
      });
    } catch (_) {
      // 请求已超时、被取消或已关闭：后端已经结束等待。
    }
  }

  Future<void> _onInteraction(Map<String, dynamic> e) async {
    final payload = e['payload'] is Map ? e['payload'] as Map : const {};
    final id = '${e['source_id']}';
    final name = sources.firstWhere(
      (s) => s['id'] == id,
      orElse: () => const {'name': '书源'},
    )['name'];
    switch (e['kind']) {
      case 'verification':
        await _verification(e, payload, '$name');
      case 'login_data':
        // 登录表单在提交时已关闭，取本次提交的字段；不在登录中时取消。
        final draft = loginDrafts[id];
        await (draft == null
            ? _reply(e, null, cancel: true)
            : _reply(e, draft));
      case 'login_refresh':
        // 下次打开登录会重新读取书源的表单定义，这里只确认。
        await _reply(e, null);
      case 'notice' when loginDialogSource == id:
        loginNotice.value = '${payload['text'] ?? ''}';
        await _reply(e, true);
      case 'notice':
        final messenger = ScaffoldMessenger.maybeOf(context);
        messenger?.showSnackBar(
          deskSnackBar(
            content: Text('$name：${payload['text'] ?? ''}'),
            duration: Duration(seconds: payload['long'] == true ? 6 : 3),
          ),
        );
        await _reply(e, messenger != null);
      case 'clipboard':
        await _clipboard(e, '${payload['text'] ?? ''}', '$name');
      case 'book_search':
        await _bookSearch(e, payload, '$name');
      case 'login_open':
        await _loginOpen(e, payload, '$name');
      default:
        await _reply(e, null, cancel: true);
    }
  }

  /// 导航的目标书源：payload.source_id 为空时就是发起的书源；不在书库里时返回 null，
  /// 不悄悄换成别的书源。外层 source_id 是发起源，payload.source_id 是目标源。
  Map<String, dynamic>? _navigationTarget(Map e, Map payload) {
    final target = '${payload['source_id'] ?? e['source_id']}';
    return sources.where((s) => '${s['id']}' == target).firstOrNull;
  }

  void _navigationNotice(String text) =>
      ScaffoldMessenger.maybeOf(context)
          ?.showSnackBar(deskSnackBar(content: Text(text)));

  /// 书源请求搜索：切到搜索页，只在目标书源里搜这个关键词；搜索已开始才回复 true。
  Future<void> _bookSearch(Map e, Map payload, String name) async {
    final keyword = '${payload['keyword'] ?? ''}'.trim();
    final target = _navigationTarget(e, payload);
    if (keyword.isEmpty || target == null || searching) {
      _navigationNotice(
        target == null
            ? '$name：找不到要搜索的书源'
            : searching
            ? '$name：正在搜索，稍后再试'
            : '$name：没有搜索关键词',
      );
      await _reply(e, false);
      return;
    }
    update(() {
      tab = 'search';
      searchScope = 'pick';
      pickedSources
        ..clear()
        ..add('${target['id']}');
      query.text = keyword;
    });
    _navigationNotice('「$name」请求搜索“$keyword”');
    unawaited(_search());
    await _reply(e, true);
  }

  /// 书源请求打开登录：打开目标书源的登录窗口；窗口打开就回复 true。
  Future<void> _loginOpen(Map e, Map payload, String name) async {
    final target = _navigationTarget(e, payload);
    if (target == null) {
      _navigationNotice('$name：找不到要打开的书源');
      await _reply(e, false);
      return;
    }
    unawaited(_login(context, target));
    await _reply(e, true);
  }

  /// 后端超时、任务取消或停用交互时撤下对应的弹窗；已回复的请求也会收到 closed，忽略即可。
  void _onInteractionClosed(Map<String, dynamic> e) {
    final requestId = '${e['request_id']}';
    final dialog = interactionDialogs.remove(requestId);
    if (dialog == null || !dialog.mounted) return;
    interactionClosed.add(requestId);
    final route = ModalRoute.of(dialog);
    if (route != null) Navigator.of(dialog).removeRoute(route);
  }

  Future<T?> _interactionDialog<T>(
    Map e,
    Widget Function(BuildContext dialog) builder,
  ) {
    final requestId = '${e['request_id']}';
    return showDialog<T>(
      context: context,
      barrierDismissible: false,
      builder: (dialog) {
        interactionDialogs[requestId] = dialog;
        return builder(dialog);
      },
    ).whenComplete(() => interactionDialogs.remove(requestId));
  }

  Future<void> _verification(Map e, Map payload, String name) async {
    final Uint8List bytes;
    try {
      bytes = base64Decode('${payload['image_base64']}');
    } catch (_) {
      return _reply(e, null, cancel: true);
    }
    if (bytes.isEmpty || !mounted) return _reply(e, null, cancel: true);
    final controller = TextEditingController();
    final code = await _interactionDialog<String>(
      e,
      (dialog) => DeskControllerScope(
        controllers: [controller],
        child: DeskAlert(
          key: const ValueKey('booksource-verification'),
          title: Text('$name 需要验证码'),
          content: SizedBox(
            width: 360,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Center(
                  child: Image.memory(
                    bytes,
                    height: 72,
                    fit: BoxFit.contain,
                    errorBuilder: (_, _, _) =>
                        const DeskNote('验证码图片无法显示，请取消后重试。', tone: Tone.warn),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  key: const ValueKey('booksource-verification-field'),
                  controller: controller,
                  autofocus: true,
                  inputFormatters: [LengthLimitingTextInputFormatter(200)],
                  decoration: const InputDecoration(hintText: '按图片填写'),
                  onSubmitted: (v) => Navigator.pop(dialog, v.trim()),
                ),
                const SizedBox(height: 8),
                const DeskText(
                  'EasyPub 不会自动识别验证码。最多等待 2 分钟，超时后书源会报错。',
                  size: 12,
                ),
              ],
            ),
          ),
          actions: [
            DeskButton(
              '取消',
              quiet: true,
              onPressed: () => Navigator.pop(dialog),
            ),
            DeskButton(
              '提交',
              key: const ValueKey('booksource-verification-submit'),
              primary: true,
              onPressed: () => Navigator.pop(dialog, controller.text.trim()),
            ),
          ],
        ),
      ),
    );
    if (code == null || code.isEmpty) return _reply(e, null, cancel: true);
    await _reply(e, code);
  }

  Future<void> _clipboard(Map e, String text, String name) async {
    final ok = await _interactionDialog<bool>(
      e,
      (dialog) => DeskAlert(
        key: const ValueKey('booksource-clipboard'),
        title: Text('$name 请求复制文字'),
        content: SizedBox(
          width: 420,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const DeskText('书源脚本想把下面的文字放进剪贴板，你确认后才复制。', size: 12.5),
              const SizedBox(height: 10),
              Container(
                constraints: const BoxConstraints(maxHeight: 160),
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: dialog.desk.surface,
                  border: Border.all(color: dialog.desk.line),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: SingleChildScrollView(child: SelectableText(text)),
              ),
            ],
          ),
        ),
        actions: [
          DeskButton(
            '不复制',
            quiet: true,
            onPressed: () => Navigator.pop(dialog, false),
          ),
          DeskButton(
            '复制',
            key: const ValueKey('booksource-clipboard-copy'),
            primary: true,
            onPressed: () => Navigator.pop(dialog, true),
          ),
        ],
      ),
    );
    if (ok == null) return _reply(e, null, cancel: true);
    if (!ok) return _reply(e, false);
    try {
      await Clipboard.setData(ClipboardData(text: text));
    } catch (_) {
      return _reply(e, false);
    }
    await _reply(e, true);
  }
}
