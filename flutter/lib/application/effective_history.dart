// 章节修改历史的存储形状：修改步骤共用一份（logs），每个状态只记用到第几条。
// 其他代码不直接拆这个结构，都从这里取。
/// 第 [index] 个状态的修改请求：{base_id, actions, checkpoint?}。
/// 旧版保存的历史每个状态自带 actions，原样返回。
Map<String, dynamic> effectiveRequest(Map history, int index) {
  final request =
      ((history['history'] as List)[index] as Map)['request'] as Map;
  if (request['actions'] != null) return request.cast<String, dynamic>();
  final count = request['count'] as int? ?? 0;
  return {
    'base_id': request['base_id'],
    'actions': count == 0
        ? const <dynamic>[]
        : ((history['logs'] as List)[request['log'] as int? ?? 0] as List)
              .sublist(0, count),
    if (request['checkpoint'] != null) 'checkpoint': request['checkpoint'],
  };
}

/// 当前状态的修改请求。
Map<String, dynamic> currentEffectiveRequest(Map history) =>
    effectiveRequest(history, history['cursor'] as int);
