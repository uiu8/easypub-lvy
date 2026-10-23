// 仅追加到私有书源的内存副本；输入均为公开合成值，不调用签名或设备注册。
(function(){
  globalThis.__private_stage=1;
  if(FQ_md5('abc')!=='900150983cd24fb0d6963f7d28e17f72')throw Error('md5 vector');
  globalThis.__private_stage=2;
  const encrypted=FQ_aesCbc(FQ_pad('abc'),'\0'.repeat(16),'\0'.repeat(16));
  const actual=FQ_hex(FQ_s2j(encrypted));
  const c=javax.crypto.Cipher.getInstance('AES/CBC/PKCS5Padding');
  c.init(1,new javax.crypto.spec.SecretKeySpec(Array(16).fill(0),'AES'),new javax.crypto.spec.IvParameterSpec(Array(16).fill(0)));
  const expected=java.hexEncodeToString(c.doFinal([97,98,99]));
  if(expected!=='976a995f94cf4c1e24b6e2fb067e7a69')throw Error('jdk oracle');
  if(actual!==expected)throw Error('aes vector');
  globalThis.__private_stage=3;
  const compressed=FQ_gz('自拟gzip样本');
  const input=new java.io.ByteArrayInputStream(new java.lang.String(compressed).getBytes('ISO-8859-1'));
  const plain=new java.util.zip.GZIPInputStream(input).readAllBytes();
  if(String(new java.lang.String(plain,'UTF-8'))!=='自拟gzip样本')throw Error('gzip vector');
  globalThis.__private_stage=4;
  return 'private-vectors-ok';
})();
