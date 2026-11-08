part of '../booksource_page.dart';

extension _BookSourceResultOrder on _BookSourcePageState {
  num _chapterCount(Map entry) =>
      _num((entry['book'] as Map?)?['chapterCount']);
  int _sourceCompare(Map a, Map b) {
    int c = (b['pinned'] == true ? 1 : 0).compareTo(
      a['pinned'] == true ? 1 : 0,
    );
    if (c != 0) return c;
    c = _chapterCount(b).compareTo(_chapterCount(a));
    if (c != 0) return c;
    c = '${(b['book'] as Map?)?['lastChapter'] ?? ''}'.compareTo(
      '${(a['book'] as Map?)?['lastChapter'] ?? ''}',
    );
    if (c != 0) return c;
    c = _num(b['score'] ?? b['rating'])
        .compareTo(_num(a['score'] ?? a['rating']));
    if (c != 0) return c;
    return _num(a['ms']).compareTo(_num(b['ms']));
  }

  void _orderResults(String key) {
    final selectedKey = _current == null ? null : _bookKey(_current!);
    final selectedId = _currentSource?['sourceId'];
    for (final row in results) {
      final entries = row['sources'] as List;
      entries.sort((a, b) => _sourceCompare(a as Map, b as Map));
      final maximum = entries
          .map((s) => _chapterCount(s as Map))
          .fold<num>(0, (a, b) => a > b ? a : b);
      for (final e in entries) {
        (e as Map)['possiblyIncomplete'] =
            maximum > 0 &&
            _chapterCount(e) > 0 &&
            _chapterCount(e) < maximum * .9;
      }
    }
    num count(Map r) => (r['sources'] as List)
        .map((e) => _chapterCount(e as Map))
        .fold<num>(0, (a, b) => a > b ? a : b);
    num speed(Map r) => (r['sources'] as List)
        .map((s) => _num((s as Map)['ms']))
        .fold<num>(999999, (a, b) => a < b ? a : b);
    num rating(Map r) => (r['sources'] as List)
        .map((s) => _num((s as Map)['score'] ?? s['rating']))
        .fold<num>(-2, (a, b) => a > b ? a : b);
    bool pinned(Map r) =>
        (r['sources'] as List).any((s) => (s as Map)['pinned'] == true);
    final maxima = <String, num>{};
    for (final row in results) {
      final name = '${row['name']}';
      final n = count(row);
      if (n > (maxima[name] ?? 0)) maxima[name] = n;
    }
    num ratio(Map r) {
      final maximum = maxima['${r['name']}'] ?? 0;
      final n = count(r);
      return maximum == 0
          ? 0
          : n * 100 >= maximum * 98
          ? 10000
          : (n * 10000 / maximum).floor();
    }

    String latest(Map r) => (r['sources'] as List)
        .map((s) => '${(s as Map)['book']['lastChapter'] ?? ''}')
        .fold('', (a, b) => a.compareTo(b) > 0 ? a : b);
    results.sort((a, b) {
      int c = 0;
      switch (settings.resultSort) {
        case 'chapters':
          c = count(b).compareTo(count(a));
        case 'latest':
          c = count(b).compareTo(count(a));
          if (c == 0) c = latest(b).compareTo(latest(a));
        case 'sources':
          c = (b['sources'] as List).length.compareTo(
            (a['sources'] as List).length,
          );
        case 'speed':
          c = speed(a).compareTo(speed(b));
        default:
          c = (b['name'] == key ? 1 : 0).compareTo(a['name'] == key ? 1 : 0);
          if (c == 0) {
            c = (b['author'] == key ? 1 : 0).compareTo(
              a['author'] == key ? 1 : 0,
            );
          }
          if (c == 0) c = (pinned(b) ? 1 : 0).compareTo(pinned(a) ? 1 : 0);
          if (c == 0) c = ratio(b).compareTo(ratio(a));
          if (c == 0) {
            c = (b['sources'] as List).length.compareTo(
              (a['sources'] as List).length,
            );
          }
          if (c == 0) c = rating(b).compareTo(rating(a));
          if (c == 0) c = speed(a).compareTo(speed(b));
      }
      return c != 0
          ? c
          : '${a['name']}\n${a['author']}'.compareTo(
              '${b['name']}\n${b['author']}',
            );
    });
    if (selectedKey != null) {
      final i = results.indexWhere((r) => _bookKey(r) == selectedKey);
      selected = i < 0 ? null : i;
      if (i >= 0) {
        final sourceIndex = (results[i]['sources'] as List).indexWhere(
          (s) => (s as Map)['sourceId'] == selectedId,
        );
        selectedSource = sourceIndex < 0 ? 0 : sourceIndex;
      }
    }
  }

  void _applyEnrichment(Map e) {
    if (e['error'] != null) return;
    for (final row in results) {
      for (final raw in row['sources'] as List) {
        final source = raw as Map;
        if (source['sourceId'] == e['sourceId'] &&
            (source['book'] as Map)['bookUrl'] ==
                (e['book'] as Map)['bookUrl']) {
          source['book'] = e['book'];
        }
      }
    }
    _orderResults(query.text.trim());
  }

  Future<void> _enrichResults() async {
    if (enriching || results.isEmpty) return;
    update(() => enriching = true);
    try {
      await api!.call('search.enrich', {
        'searchId': activeSearchId,
        'key': query.text.trim(),
        'results': results,
      });
    } catch (e) {
      update(() => searchStatus = bookSourceErrorText(e));
    } finally {
      update(() => enriching = false);
    }
  }

  String _sourceLabel(Map e) {
    final book = e['book'] as Map;
    final n = _num(book['chapterCount']);
    return '${e['pinned'] == true ? '📌 ' : ''}${e['sourceName']}${n > 0 ? ' · ${book['countExact'] == true ? '' : '约'}$n 章' : ''}${e['possiblyIncomplete'] == true ? ' · 可能不全' : ''}';
  }
}
