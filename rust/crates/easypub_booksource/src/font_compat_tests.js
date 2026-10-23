(function(){
  function check(ok){if(!ok)throw Error('字体映射夹具不匹配');}
  function denied(fn){let failed=false;try{fn();}catch(e){failed=true;}check(failed);}
  const good=java.queryTTF(fonts[0]),bad=java.queryBase64TTF(fonts[1]);
  const text='\ue001\ue002\ue003\ue004 ?\n';
  check(java.replaceFont(text,bad,good)==='乙甲𠀀丙 ?\n');
  check(java.replaceFont(text,bad,good,true)==='乙甲𠀀丙 \n');
  check(java.replaceFont('\ue002',bad,java.queryTTF(fonts[2]))==='\ue002');
  check(java.replaceFont('\ue002',bad,java.queryTTF(fonts[3]),true)==='\ue002');
  check(java.replaceFont('𠀀',good,good)==='𠀀');
  const bytes=java.base64DecodeToByteArray(fonts[0]);
  check(java.replaceFont(text,bad,java.queryTTF(bytes,false))==='乙甲𠀀丙 ?\n');
  denied(()=>java.replaceFont(text,{},good));denied(()=>java.replaceFont(text,bad,good,'true'));
  denied(()=>java.queryTTF('file:///secret.ttf'));denied(()=>java.queryTTF('C:\\secret.ttf'));
  denied(()=>java.queryTTF('https://example.invalid/font.ttf'));
  denied(()=>java.queryBase64TTF('https://example.invalid/font.ttf'));
  denied(()=>java.queryTTF('not a font'));
  return 'font-ok';
})();
