(function(){
  const equal=(a,b)=>{if(JSON.stringify(a)!==JSON.stringify(b))throw Error('vector mismatch '+JSON.stringify(a)+' / '+JSON.stringify(b));};
  const hex=b=>java.hexEncodeToString(b);
  const bytes=s=>java.hexDecodeToByteArray(s);
  equal(hex(Packages.cn.hutool.crypto.digest.DigestUtil.md5('abc')),'900150983cd24fb0d6963f7d28e17f72');
  equal(hex(Packages.cn.hutool.crypto.digest.DigestUtil.md5([97,98,99])),'900150983cd24fb0d6963f7d28e17f72');
  equal(new java.lang.String('中文').getBytes('GBK'),[-42,-48,-50,-60]);
  equal(String(new java.lang.String([-42,-48,-50,-60],java.nio.charset.Charset.forName('GBK'))),'中文');
  equal(new java.lang.String(String.fromCharCode(128,255)).getBytes('ISO-8859-1'),[-128,-1]);
  equal(java.util.Arrays.copyOfRange([1,2,3],1,5),[2,3,0,0]);
  equal(java.util.Base64.getEncoder().encodeToString([-1,-2,-3]),'//79');
  equal(java.util.Base64.getDecoder().decode('//79'),[-1,-2,-3]);
  equal(android.util.Base64.encodeToString([102],2),'Zg==');
  const abc=new java.lang.String('abc').getBytes();
  equal(hex(java.security.MessageDigest.getInstance('MD5').digest(abc)),'900150983cd24fb0d6963f7d28e17f72');
  equal(hex(java.security.MessageDigest.getInstance('SHA-1').digest(abc)),'a9993e364706816aba3e25717850c26c9cd0d89d');
  equal(hex(java.security.MessageDigest.getInstance('SHA-256').digest(abc)),'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad');
  const mac=javax.crypto.Mac.getInstance('HmacSHA256');mac.init(new javax.crypto.spec.SecretKeySpec(Array(20).fill(11),'HmacSHA256'));
  equal(hex(mac.doFinal(new java.lang.String('Hi There').getBytes())),'b0344c61d8db38535ca8afceaf0bf12b881dc200c9833da726e9376c2e32cff7');
  const key=new javax.crypto.spec.SecretKeySpec(bytes('000102030405060708090a0b0c0d0e0f'),'AES');
  const cbcOracle=javax.crypto.Cipher.getInstance('AES/CBC/PKCS5Padding');cbcOracle.init(1,new javax.crypto.spec.SecretKeySpec(Array(16).fill(0),'AES'),new javax.crypto.spec.IvParameterSpec(Array(16).fill(0)));
  equal(hex(cbcOracle.doFinal(abc)),'976a995f94cf4c1e24b6e2fb067e7a69');
  const cipher=javax.crypto.Cipher.getInstance('AES/ECB/NoPadding');cipher.init(1,key);
  equal(hex(cipher.doFinal(bytes('00112233445566778899aabbccddeeff'))),'69c4e0d86a7b0430d8cdb78070b4c55a');
  const gcm=javax.crypto.Cipher.getInstance('AES/GCM/NoPadding');gcm.init(1,new javax.crypto.spec.SecretKeySpec(Array(16).fill(0),'AES'),new javax.crypto.spec.GCMParameterSpec(128,Array(12).fill(0)));
  const sealed=gcm.doFinal(Array(16).fill(0));equal(hex(sealed),'0388dace60b6a392f328c2b971b2fe78ab6e47d42cec13bdf53a67b21257bddf');
  gcm.init(2,new javax.crypto.spec.SecretKeySpec(Array(16).fill(0),'AES'),new javax.crypto.spec.GCMParameterSpec(128,Array(12).fill(0)));equal(gcm.doFinal(sealed),Array(16).fill(0));
  let rejected=false;sealed[0]^=1;gcm.init(2,new javax.crypto.spec.SecretKeySpec(Array(16).fill(0),'AES'),new javax.crypto.spec.GCMParameterSpec(128,Array(12).fill(0)));try{gcm.doFinal(sealed);}catch(_){rejected=true;}equal(rejected,true);
  for(const transform of ['AES/CBC/PKCS5Padding','AES/ECB/PKCS7Padding','DES/CBC/PKCS5Padding','DESede/ECB/PKCS5Padding']) {
    const k=new javax.crypto.spec.SecretKeySpec(Array(transform.startsWith('AES')?16:transform.startsWith('DESede')?24:8).fill(1),'fixture');
    const iv=transform.includes('CBC')?new javax.crypto.spec.IvParameterSpec(Array(transform.startsWith('AES')?16:8).fill(2)):undefined;
    const c=javax.crypto.Cipher.getInstance(transform);c.init(1,k,iv);const e=c.doFinal(abc);c.init(2,k,iv);equal(c.doFinal(e),abc);
  }
  const BI=java.math.BigInteger;equal(new BI('4').modPow(new BI('13'),new BI('497')).toString(),'445');
  for(const [n,b] of [['0',[0]],['127',[127]],['128',[0,-128]],['255',[0,-1]],['-128',[-128]],['-129',[-1,127]]]){equal(new BI(n).toByteArray(),b);equal(new BI(b).toString(),n);}
  equal(new BI(1,[-1]).toString(16),'ff');equal(BI.ONE.shiftLeft(64).toString(),'18446744073709551616');
  const out=new java.io.ByteArrayOutputStream(),zip=new java.util.zip.GZIPOutputStream(out);zip.write(new java.lang.String('甲\r\n乙\n').getBytes());zip.close();
  const jdkGzip=java.util.Base64.getDecoder().decode('H4sIAAAAAAAA/0vLrCgpLUpVSK/KLFB4smPts2ntAHkSNm8TAAAA');
  equal(String(new java.lang.String(new java.util.zip.GZIPInputStream(new java.io.ByteArrayInputStream(jdkGzip)).readAllBytes(),'UTF-8')),'fixture gzip 中文');
  const reader=new java.io.BufferedReader(new java.io.InputStreamReader(new java.util.zip.GZIPInputStream(new java.io.ByteArrayInputStream(out.toByteArray())),'UTF-8'));
  equal(reader.readLine(),'甲');equal(reader.readLine(),'乙');equal(reader.readLine(),null);
  equal(new java.io.ByteArrayInputStream([]).read([]),0);
  rejected=false;try{new java.io.ByteArrayOutputStream().write([1],0,2);}catch(_){rejected=true;}equal(rejected,true);
  const url=new java.net.URL('https://example.invalid/a/b','../c?q=1#x');equal(url.getPath(),'/c');equal(url.getQuery(),'q=1');
  const random=Array(32).fill(0);new java.security.SecureRandom().nextBytes(random);equal(random.length,32);if(!random.every(n=>n>=-128&&n<=127))throw Error('signed bytes');
  if(!/^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/.test(String(java.util.UUID.randomUUID())))throw Error('uuid');

  const imports=new JavaImporter(java.util,java.lang);
  const list=new imports.ArrayList(8);
  equal(list.size(),0);equal(list.add('甲'),true);list.add('乙');list.add(1,null);
  equal(list.toArray(),['甲',null,'乙']);equal(list.get(2),'乙');equal(list.set(1,'丙'),null);
  equal(list.remove('甲'),true);equal(list.remove(1),'乙');
  equal(list.addAll(list),true);equal(list.toArray(),['丙','丙']);
  list.addAll(1,['丁','戊']);list.subList(1,3).clear();equal(list.toArray(),['丙','丙']);
  const copy=new java.util.ArrayList(list);list.clear();equal(copy.size(),2);equal(list.size(),0);
  equal(new java.util.ArrayList(copy.subList(0,1)).toArray(),['丙']);
  const props=imports.System.getProperties();equal(props===imports.System.getProperties(),true);
  equal(typeof props.getProperty('http.agent'),'string');
  equal(props.getProperty('user.home'),null);equal(props.getProperty('java.version','not-a-jvm'),'not-a-jvm');
  equal(props.setProperty('fixture.property','first'),null);equal(imports.System.setProperty('fixture.property','second'),'first');
  equal(props.get('fixture.property'),'second');equal(imports.System.clearProperty('fixture.property'),'second');
  equal(props.getProperty('fixture.property','fallback'),'fallback');
  equal(props.put('fixture.object',7),null);equal(props.getProperty('fixture.object','fallback'),'fallback');equal(props.remove('fixture.object'),7);
  for(const action of [()=>new imports.ArrayList(-1),()=>copy.get(9),()=>copy.add(-1,'x'),()=>props.setProperty('', 'x')]) {
    let failed=false;try{action();}catch(_){failed=true;}equal(failed,true);
  }
  return 'vectors-ok';
})();
