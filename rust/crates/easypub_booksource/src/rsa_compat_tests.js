(function(){
  function check(ok){if(!ok)throw Error('RSA 合成向量不匹配');}
  function denied(fn){let failed=false;try{fn();}catch(e){failed=true;}check(failed);}
  const plain='公开测试 RSA 中文';
  for(const c of f.cases){
    const rsa=java.createAsymmetricCrypto(c.algorithm).setPublicKey(f.public).setPrivateKey(f.private);
    check(rsa.decryptStr(c.cipher)===plain);
    check(rsa.decryptStr(rsa.encryptBase64(plain))===plain);
    check(rsa.decryptStr(rsa.encryptHex(plain))===plain);
    denied(()=>rsa.encrypt(plain,false));denied(()=>rsa.decrypt(c.cipher,true));
  }
  const signer=java.createSign('SHA256withRSA').setPublicKey(f.public).setPrivateKey(f.private);
  check(signer.signBase64(plain)===f.signature);
  check(signer.verify(plain,f.signature));check(!signer.verify(plain+'!',f.signature));
  const decode=x=>java.util.Base64.getDecoder().decode(x);
  const factory=java.security.KeyFactory.getInstance('RSA');
  const publicKey=factory.generatePublic(new java.security.spec.X509EncodedKeySpec(decode(f.public)));
  const privateKey=factory.generatePrivate(new java.security.spec.PKCS8EncodedKeySpec(decode(f.private)));
  for(const c of f.cases){const cipher=javax.crypto.Cipher.getInstance(c.algorithm);cipher.init(2,privateKey);check(String(new java.lang.String(cipher.doFinal(decode(c.cipher)),'UTF-8'))===plain);}
  const sig=java.security.Signature.getInstance('SHA256withRSA');
  sig.initSign(privateKey);sig.update(new java.lang.String(plain).getBytes('UTF-8'));check(java.util.Base64.getEncoder().encodeToString(sig.sign())===f.signature);
  sig.initVerify(publicKey);sig.update(new java.lang.String(plain).getBytes('UTF-8'));check(sig.verify(decode(f.signature)));
  denied(()=>java.createAsymmetricCrypto('RSA/ECB/NoPadding'));
  denied(()=>factory.generatePrivate(new java.security.spec.PKCS8EncodedKeySpec(decode(f.public))));
  denied(()=>javax.crypto.Cipher.getInstance('RSA').init(1,privateKey));
  return 'rsa-ok';
})();
