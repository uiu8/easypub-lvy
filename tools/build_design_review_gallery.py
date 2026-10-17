"""Package real Flutter design captures as an offline review gallery."""
from pathlib import Path
import hashlib
import html
import json
import shutil
import zipfile

root = Path(__file__).resolve().parent.parent
review = root / 'design/review-20260930-v2.1'
data = json.loads((review / 'scenes.json').read_text(encoding='utf-8'))
scenes = data['scenes']
assert len(scenes) == len({s['id'] for s in scenes})
for scene in scenes:
    p = review / scene['image']
    assert p.is_file() and p.stat().st_size > 1000
    scene['sha256'] = hashlib.sha256(p.read_bytes()).hexdigest()
    raw = p.read_bytes()
    assert raw[:8] == b'\x89PNG\r\n\x1a\n'
    assert [int.from_bytes(raw[16:20], 'big'), int.from_bytes(raw[20:24], 'big')] == data['png_size']

cards = []
for index, scene in enumerate(scenes, 1):
    esc = lambda s: html.escape(s, quote=True)
    cards.append(f'''<article data-section="{esc(scene['section'])}" data-title="{esc(scene['title'])}">
    <a class="shot" href="{esc(scene['image'])}" data-index="{index-1}"><img src="{esc(scene['image'])}" loading="lazy" alt="{esc(scene['title'])}"></a>
    <div class="caption"><span>{index:02d} / {esc(scene['section'])}</span><h2>{esc(scene['title'])}</h2><p>{esc(scene['description'])}</p><a href="{esc(scene['image'])}" target="_blank">原图 ↗</a></div></article>''')
sections = list(dict.fromkeys(s['section'] for s in scenes))
filters = '<button class="active" data-filter="all">全部</button>' + ''.join(f'<button data-filter="{html.escape(s)}">{html.escape(s)}</button>' for s in sections)
template = '''<!doctype html><html lang="zh-CN"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>EasyPub++ · 全界面设计评审 v2.1</title>
<style>*{box-sizing:border-box}body{margin:0;background:#f5f2eb;color:#262522;font:15px/1.6 "Microsoft YaHei",sans-serif}a{color:#23664f}header,main{max-width:1540px;margin:auto;padding:40px}header{padding-bottom:20px}.eyebrow{letter-spacing:.2em;color:#66625b;font-size:12px}h1{font-size:38px;margin:12px 0}header p{max-width:900px;color:#66625b}.links{display:flex;gap:20px;flex-wrap:wrap;margin:22px 0}.notice{padding:14px 18px;background:#e8e3d9;border-radius:8px;max-width:1100px}.filters{position:sticky;top:0;z-index:1;background:#f5f2ebeb;backdrop-filter:blur(12px);padding:15px 40px;border-top:1px solid #d9d3c8;border-bottom:1px solid #d9d3c8;display:flex;gap:10px;flex-wrap:wrap}button{font:inherit;border:1px solid #d9d3c8;background:#fcfaf5;color:#262522;padding:7px 14px;border-radius:6px;cursor:pointer}button.active{background:#23664f;color:white;border-color:#23664f}.grid{display:grid;grid-template-columns:repeat(2,minmax(0,1fr));gap:24px}article{background:#fcfaf5;border:1px solid #d9d3c8;border-radius:10px;overflow:hidden}.shot{display:block;background:#eee9df}.shot img{display:block;width:100%;height:auto;aspect-ratio:1.5}.caption{padding:18px 22px}.caption span{font-size:12px;color:#66625b}h2{font-size:18px;margin:5px 0}.caption p{font-size:13px;color:#66625b;margin:5px 0 10px}#viewer{position:fixed;inset:0;background:#262522ef;z-index:10;display:none;flex-direction:column;align-items:center;padding:15px}#viewer.open{display:flex}#viewer img{max-width:100%;max-height:calc(100vh - 80px);object-fit:contain;min-height:0}#bar{color:white;display:flex;align-items:center;gap:14px;margin-bottom:12px}#bar button{background:transparent;color:white;border-color:#789186}footer{padding:28px 40px;color:#66625b;font-size:12px}@media(max-width:850px){.grid{grid-template-columns:1fr}header,main{padding:24px}.filters{padding:12px 24px}h1{font-size:28px}}</style>
<header><div class="eyebrow">EASYPUB++ / DESIGN REVIEW V2.1 / 2026.09.30</div><h1>全书检查，各页就地处理。</h1>
<p>检查与修复汇总当前书的章节、清理、信息及资源结果，各工作页保留专业处理。删除数字步骤栏，通过简短状态、明确动作与复查结果保持操作连续。以下为真实 Flutter 组件渲染的设计提案，等待确认后接入正式功能。</p>
<div class="links"><a href="design-document.md">完整设计与还原验收文档</a><a href="research.md">四家公司官方设计依据</a><a href="feature-inventory.md">全部功能归属与现状</a><a href="coverage-audit.md">功能遗漏与待补清单</a><a href="manifest.json">图像与源文件基线</a></div>
<div class="notice">共 COUNT 张预览 · 1440 × 960 逻辑像素 / 2160 × 1440 PNG。图片使用合成书稿，按钮用于表达设计，不代表业务已经接通；尚未完整出图的功能见遗漏清单，场景数不等于功能覆盖率。原生文件选择窗口由 Windows 提供，本提案展示调用入口及选择结果。字体扩展继续暂缓。</div></header>
<nav class="filters">FILTERS</nav><main><div class="grid">CARDS</div></main>
<footer>确认后按相同组件、设计参数和逐页截图还原。当前正式软件未被此提案替换。设置子页、弹窗和关键失败状态均可从此索引查看；更多数据量及窗口断点需继续验收。</footer>
<div id="viewer" role="dialog" aria-modal="true" aria-label="预览原图"><div id="bar"><button id="prev">← 上一张</button><span id="title"></span><button id="next">下一张 →</button><button id="close">关闭 Esc</button></div><img id="large" alt=""></div>
<script>const scenes=DATA;let current=0;const viewer=document.querySelector('#viewer');function show(i){current=(i+scenes.length)%scenes.length;const s=scenes[current];document.querySelector('#large').src=s.image;document.querySelector('#large').alt=s.title;document.querySelector('#title').textContent=(current+1)+' / '+scenes.length+' · '+s.title;viewer.classList.add('open');document.querySelector('#close').focus();}document.querySelectorAll('.shot').forEach(a=>a.addEventListener('click',e=>{e.preventDefault();show(Number(a.dataset.index));}));document.querySelector('#prev').onclick=()=>show(current-1);document.querySelector('#next').onclick=()=>show(current+1);document.querySelector('#close').onclick=()=>viewer.classList.remove('open');document.addEventListener('keydown',e=>{if(!viewer.classList.contains('open'))return;if(e.key==='Escape')viewer.classList.remove('open');if(e.key==='ArrowRight')show(current+1);if(e.key==='ArrowLeft')show(current-1);});document.querySelectorAll('[data-filter]').forEach(b=>b.onclick=()=>{document.querySelectorAll('[data-filter]').forEach(x=>x.classList.toggle('active',x===b));document.querySelectorAll('article').forEach(a=>a.hidden=b.dataset.filter!=='all'&&a.dataset.section!==b.dataset.filter);});</script></html>'''
template = template.replace('COUNT', str(len(scenes))).replace('FILTERS', filters).replace('CARDS', '\n'.join(cards)).replace('DATA;', json.dumps(scenes, ensure_ascii=False).replace('</', '<\\/')+';')
(review / 'index.html').write_text(template, encoding='utf-8')
doc = (root / 'docs/09_全书检查与领域修复设计.md').read_text(encoding='utf-8')
doc = doc.replace('../design/review-20260930-v2.1/', '').replace('(07_前端重设计与还原验收.md)', '(first-review-detail.md)').replace('(08_EasyPub++前端第二稿与修复闭环.md)', '(second-review-detail.md)').replace('(10_前端功能覆盖复核.md)', '(coverage-audit.md)')
(review / 'design-document.md').write_text(doc, encoding='utf-8')
shutil.copyfile(root / 'docs/08_EasyPub++前端第二稿与修复闭环.md', review / 'second-review-detail.md')
shutil.copyfile(root / 'docs/07_前端重设计与还原验收.md', review / 'first-review-detail.md')
shutil.copyfile(root / 'docs/research/2026-09-30_前端重设计依据.md', review / 'research.md')
shutil.copyfile(root / 'docs/10_前端功能覆盖复核.md', review / 'coverage-audit.md')
source = review / 'preview-source'
source.mkdir(exist_ok=True)
for item in (root / 'design_preview/lib/design_review').glob('*.dart'):
    shutil.copyfile(item, source / item.name)
shutil.copyfile(root / 'design_preview/lib/design_review_main.dart', source / 'design_review_main.dart')
shutil.copyfile(root / 'design_preview/tool/render_design_review_test.dart', source / 'render_design_review_test.dart')
data['product_name'] = 'EasyPub++'
data['revision'] = 'v2.1'
data['sources'] = {str(p.relative_to(root)).replace('\\','/'): hashlib.sha256(p.read_bytes()).hexdigest() for p in sorted((root / 'design_preview/lib/design_review').glob('*.dart'))}
(review / 'manifest.json').write_text(json.dumps(data, ensure_ascii=False, indent=2), encoding='utf-8')
(review / 'README.txt').write_text('EasyPub++ 全界面设计提案 v2.1\n双击 index.html 查看全部页面；点击图片放大，方向键切换，Esc 关闭。\n这是设计评审资料，不替换当前软件，也不执行转换。\n批准后冻结 manifest.json 中的图片及组件源码哈希作为还原基线。\n', encoding='utf-8')
archive = root / 'artifacts/release/EasyPubPlusPlus-frontend-design-20260930-v2.1.zip'
with zipfile.ZipFile(archive, 'w', compression=zipfile.ZIP_DEFLATED) as z:
    for p in sorted(review.rglob('*')):
        if p.is_file(): z.write(p, 'EasyPubPlusPlus-frontend-design-v2.1/' + str(p.relative_to(review)))
with zipfile.ZipFile(archive) as z:
    assert z.testzip() is None
    for scene in scenes:
        assert hashlib.sha256(z.read('EasyPubPlusPlus-frontend-design-v2.1/'+scene['image'])).hexdigest() == scene['sha256']
print(json.dumps({'scenes':len(scenes),'archive':str(archive),'bytes':archive.stat().st_size,'sha256':hashlib.sha256(archive.read_bytes()).hexdigest(),'verified':True}))
