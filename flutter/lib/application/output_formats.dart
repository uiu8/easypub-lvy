/// 输出格式（后来含 TXT）。EPUB 与 TXT 由程序内置生成；TXT 先按同一出版快照生成 EPUB，
/// 再取出正文，章节标题与清理规则和 EPUB 成品一致。AZW3、MOBI 用 Kindling，KFX 用 Bokai。
const outputFormats = ['EPUB', 'AZW3', 'MOBI', 'KFX', 'TXT'];

/// 这种格式是否要用外部转换器（Kindling / Bokai）。
bool usesKindleEngine(String format) =>
    const {'AZW3', 'MOBI', 'KFX'}.contains(format);
