// 字体对象只作内存内不透明句柄，不暴露原始轮廓或文件能力。
(function(){
  const fonts=new WeakMap();
  function query(data,useCache){
    if(useCache!==undefined&&typeof useCache!=='boolean')throw Error('字体缓存参数须为布尔值');
    // 不持久化字体；useCache 只是优化提示，不改变映射结果。
    const glyphs=typeof data==='string'&&/^https?:\/\//i.test(data)?__call('fontUrl',data):__call('fontData',data);
    return wrap(glyphs);
  }
  function wrap(glyphs){
    const reverse=new Map();
    for(const [ch,hash] of Object.entries(glyphs))reverse.set(hash,reverse.has(hash)?null:ch);
    const obj=Object.freeze({});fonts.set(obj,{glyphs,reverse});return obj;
  }
  java.queryTTF=query;
  java.queryBase64TTF=function(data){if(typeof data!=='string')throw Error('字体 Base64 须为字符串');return wrap(__call('fontData',data));};
  java.replaceFont=function(text,errorFont,correctFont,filter){
    if(typeof text!=='string'||(filter!==undefined&&typeof filter!=='boolean'))throw Error('字体替换参数无效');
    const bad=fonts.get(errorFont),good=fonts.get(correctFont);
    if(!bad||!good)throw Error('字体对象无效或来自其他运行时');
    return Array.from(text,ch=>{
      if(/\s/u.test(ch))return ch;
      const hash=bad.glyphs[ch];
      if(!hash)return filter?'':ch;
      return good.reverse.get(hash)||ch;
    }).join('');
  };
})();
