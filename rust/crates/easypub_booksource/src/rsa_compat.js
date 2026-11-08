// 纯内存 RSA 子集。字符串明文为 UTF-8，密文/签名为 Base64 或 hex。
(function () {
  const native=(...args)=>__call('javaCompat','rsa',...args);
  const input=x=>Array.isArray(x)?x:typeof x==='string'?__call('javaCompat','encode',x,'UTF-8'):(()=>{throw Error('RSA 输入类型无效');})();
  const encoded=x=>Array.isArray(x)?x:typeof x==='string'?(/^(?:[a-fA-F0-9]{2})+$/.test(x)?__call('hexDecode',x,'bytes'):__call('javaCompat','unbase64',x)):(()=>{throw Error('RSA 编码类型无效');})();
  const b64=x=>__call('base64Encode',{b:x});
  const hex=x=>x.map(b=>(b&255).toString(16).padStart(2,'0')).join('');
  function spec(bytes) {const data=input(bytes).slice();this.getEncoded=()=>data.slice();}
  java.security.spec={X509EncodedKeySpec:spec,PKCS8EncodedKeySpec:spec};
  java.security.KeyFactory={getInstance:algorithm=>{
    if(String(algorithm).toUpperCase()!=='RSA')throw Error('不支持的 KeyFactory 算法');
    const make=(s,privateKey)=>{const data=s.getEncoded();native(privateKey?'privateKey':'publicKey','RSA',data);return {getEncoded:()=>data.slice(),getAlgorithm:()=> 'RSA',getFormat:()=>privateKey?'PKCS#8':'X.509',privateKey};};
    return {generatePublic:s=>make(s,false),generatePrivate:s=>make(s,true)};
  }};
  java.security.Signature={getInstance:algorithm=>{
    if(!/^SHA256withRSA$/i.test(algorithm))throw Error('不支持的 RSA 签名算法');
    let key,mode,data=[];
    const init=(k,m)=>{if(k.privateKey!==(m==='sign'))throw Error('RSA 密钥类型无效');key=k.getEncoded();mode=m;data=[];};
    return {initSign:k=>init(k,'sign'),initVerify:k=>init(k,'verify'),update:a=>{if(!mode)throw Error('Signature 尚未初始化');data=data.concat(input(a));if(data.length>16777216)throw Error('RSA 数据超过上限');},
      sign:()=>{if(mode!=='sign')throw Error('Signature 模式无效');const out=native('sign',algorithm,key,data);data=[];return out;},
      verify:s=>{if(mode!=='verify')throw Error('Signature 模式无效');const out=native('verify',algorithm,key,data,input(s));data=[];return out;}};
  }};
  const cipher=javax.crypto.Cipher.getInstance;
  javax.crypto.Cipher.getInstance=function(algorithm) {
    if(!/^RSA(?:\/|$)/i.test(algorithm))return cipher(algorithm);
    const rsa=java.createAsymmetricCrypto(algorithm);let mode,data=[];
    return {init:(m,k,params)=>{if(params!==undefined)throw Error('尚不支持显式 RSA 参数');if(m!==1&&m!==2)throw Error('RSA Cipher 模式无效');if(k.privateKey!==(m===2))throw Error('RSA 密钥类型无效');mode=m;data=[];if(m===1)rsa.setPublicKey(k.getEncoded());else rsa.setPrivateKey(k.getEncoded());},
      update:a=>{if(!mode)throw Error('Cipher 尚未初始化');data=data.concat(input(a));if(data.length>512)throw Error('RSA 单块数据长度无效');return [];},
      doFinal:a=>{if(!mode)throw Error('Cipher 尚未初始化');const all=data.concat(a===undefined?[]:input(a));data=[];return mode===1?rsa.encrypt(all):rsa.decrypt(all);}};
  };
  java.createAsymmetricCrypto=function(algorithm) {
    if(!/^(RSA|RSA\/ECB\/(PKCS1Padding|OAEPWithSHA-(1|256)AndMGF1Padding))$/i.test(algorithm))throw Error('不支持的 RSA 算法组合');
    let pub,priv;
    const run=(op,data,usePublic)=>{
      if(usePublic!==undefined&&typeof usePublic!=='boolean')throw Error('RSA 密钥选择须为布尔值');
      if((op==='encrypt'&&usePublic===false)||(op==='decrypt'&&usePublic===true))throw Error('不支持 RSA 私钥加密或公钥解密');
      return native(op,algorithm,op==='encrypt'?pub:priv,op==='encrypt'?input(data):encoded(data));
    };
    const obj={setPublicKey:k=>{pub=k;return obj;},setPrivateKey:k=>{priv=k;return obj;},
      encrypt:(d,k)=>run('encrypt',d,k),encryptBase64:(d,k)=>b64(run('encrypt',d,k)),encryptHex:(d,k)=>hex(run('encrypt',d,k)),
      decrypt:(d,k)=>run('decrypt',d,k),decryptStr:(d,k)=>__call('javaCompat','decode',run('decrypt',d,k),'UTF-8')};
    return obj;
  };
  java.createSign=function(algorithm) {
    if(!/^SHA256withRSA$/i.test(algorithm))throw Error('不支持的 RSA 签名算法');
    let pub,priv;
    const obj={setPublicKey:k=>{pub=k;return obj;},setPrivateKey:k=>{priv=k;return obj;},
      sign:d=>native('sign',algorithm,priv,input(d)),signBase64:d=>b64(native('sign',algorithm,priv,input(d))),signHex:d=>hex(native('sign',algorithm,priv,input(d))),
      verify:(d,s)=>native('verify',algorithm,pub,input(d),encoded(s))};
    return obj;
  };
})();
