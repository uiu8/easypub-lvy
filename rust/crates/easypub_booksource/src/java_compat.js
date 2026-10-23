// 独立实现的纯内存 Java 子集；不加载 JVM，不开放文件、反射、进程和 URL 联网。
(function(g) {
  const native=(op,...a)=>__call('javaCompat',op,...a);
  const signed=a=>Array.from(typeof a==='number'?[a]:a,x=>(Number(x)&255)>127?(Number(x)&255)-256:Number(x)&255);
  const deny=name=>native('unsupported',name);
  const absent=name=>new Proxy(function(){return deny(name);},{get:(_,p)=>absent(name+'.'+String(p)),construct:()=>deny(name)});
  const guard=(o,name)=>new Proxy(o,{get:(t,p)=>p in t?t[p]:absent(name+'.'+String(p))});
  const charset=c=>c==null?'UTF-8':String(c);
  function JString(x,...args) {
    let value;
    if(Array.isArray(x)) {
      if(typeof args[0]==='number') { x=x.slice(args[0],args[0]+args[1]); args=args.slice(2); }
      value=native('decode',signed(x),charset(args[0]));
    } else value=x==null?'':String(x);
    const s=new String(value);
    s.getBytes=c=>native('encode',value,charset(c));
    return s;
  }
  java.lang.String=JString;
  function Thread(){return deny('java.lang.Thread');}
  Thread.sleep=function(ms,nanos=0){
    if(arguments.length<1||arguments.length>2||!Number.isInteger(ms)||ms<0||!Number.isInteger(nanos)||nanos<0||nanos>999999)throw Error('Thread.sleep 参数无效');
    return __call('sleep',ms+(nanos>0?1:0));
  };
  java.lang.Thread=guard(Thread,'java.lang.Thread');
  // 每个引擎独立的兼容属性；不读取宿主环境变量、用户目录或 JVM 配置。
  let properties;
  function getProperties(){
    if(properties)return properties;
    const entries=new Map(Object.entries(native('properties')));
    const key=k=>{if(k==null||String(k)==='')throw Error('属性键不能为空');return String(k);};
    const get=k=>entries.has(k)?entries.get(k):null;
    const put=(k,v)=>{if(k==null||v==null)throw Error('属性不能为 null');const old=get(k);entries.set(k,v);return old;};
    properties=guard({get,put,containsKey:k=>entries.has(k),size:()=>entries.size,isEmpty:()=>entries.size===0,
      remove:k=>{const old=get(k);entries.delete(k);return old;},clear:()=>entries.clear(),
      getProperty:(k,fallback=null)=>{const v=get(key(k));return typeof v==='string'?v:fallback;},
      setProperty:(k,v)=>{if(typeof v!=='string')throw Error('属性值须为字符串');return put(key(k),v);}
    },'java.util.Properties');
    return properties;
  }
  java.lang.System=guard({currentTimeMillis:()=>Date.now(),getProperties,
    getProperty:(...args)=>getProperties().getProperty(...args),
    setProperty:(...args)=>getProperties().setProperty(...args),
    clearProperty:k=>{if(k==null||String(k)==='')throw Error('属性键不能为空');return getProperties().remove(String(k));}
  },'java.lang.System');

  java.nio={charset:{Charset:{forName:c=>{
    native('encode','',charset(c)); return {toString:()=>String(c),name:()=>String(c)};
  }}}};
  java.util=java.util||{};
  java.util.Arrays={copyOfRange:(a,start,end)=>{
    if(!Number.isInteger(start)||!Number.isInteger(end)||start<0||start>a.length||end<start||end-start>16777216) throw Error('数组范围无效');
    return Array.from({length:end-start},(_,i)=>i+start<a.length?a[i+start]:0);
  }};
  const encoder={encodeToString:a=>__call('base64Encode',{b:signed(a)}),encode:a=>native('encode',encoder.encodeToString(a),'ISO-8859-1')};
  const decoder={decode:a=>native('unbase64',Array.isArray(a)?String(new JString(a,'ISO-8859-1')):String(a))};
  java.util.Base64={getEncoder:()=>encoder,getDecoder:()=>decoder};
  g.android={util:{Base64:{DEFAULT:0,NO_WRAP:2,encodeToString:(a,flags)=>{
    if(flags!==0&&flags!==2) return deny('android.util.Base64.flags');
    const s=encoder.encodeToString(a);return flags===2?s:(s.match(/.{1,76}/g)||[]).join('\n')+(s?'\n':'');
  },decode:(a,flags)=>{if(flags!==0&&flags!==2)return deny('android.util.Base64.flags');return decoder.decode(a);}}}};
  g.android.text={TextUtils:guard({isEmpty:value=>value==null||String(value).length===0},'android.text.TextUtils')};
  const cookieManager=guard({
    getCookie:function(url){if(arguments.length!==1||typeof url!=='string')throw Error('Cookie 查询参数无效');return __call('cookieGet',url)||null;},
    setCookie:function(url,value,callback){if(arguments.length>3||typeof url!=='string'||typeof value!=='string'||callback!=null)throw Error('Cookie 写入仅支持网址和值，不支持异步回调');__call('cookieSetResponse',url,value);}
  },'android.webkit.CookieManager');
  g.android.webkit={CookieManager:guard({getInstance:()=>cookieManager},'android.webkit.CookieManager')};
  java.security={MessageDigest:{getInstance:algo=>{
    let buffer=[]; const name=String(algo); __call('digest',{b:[]},name);
    return {update:a=>{buffer=buffer.concat(signed(a));},reset:()=>{buffer=[];},digest:a=>{
      if(a!==undefined)buffer=buffer.concat(signed(a)); const result=signed(__call('hexDecode',__call('digest',{b:buffer},name),'bytes'));buffer=[];return result;
    }};
  }},SecureRandom:function(){this.nextBytes=a=>{const b=native('random',a.length);for(let i=0;i<a.length;i++)a[i]=b[i];};this.generateSeed=n=>native('random',n);}};
  java.util.UUID={randomUUID:()=>{
    const b=native('random',16).map(x=>x&255);b[6]=(b[6]&15)|64;b[8]=(b[8]&63)|128;
    const h=b.map(x=>x.toString(16).padStart(2,'0')).join('');const s=h.slice(0,8)+'-'+h.slice(8,12)+'-'+h.slice(12,16)+'-'+h.slice(16,20)+'-'+h.slice(20);
    return {toString:()=>s};
  }};
  function Key(bytes,algorithm){this.bytes=signed(bytes);this.getEncoded=()=>this.bytes.slice();this.getAlgorithm=()=>String(algorithm);}
  function IV(bytes){this.bytes=signed(bytes);this.getIV=()=>this.bytes.slice();}
  function GCM(bits,bytes){if(bits!==128)return deny('javax.crypto.spec.GCMParameterSpec.tagLength');IV.call(this,bytes);this.getTLen=()=>bits;}
  g.javax={crypto:{spec:{SecretKeySpec:Key,IvParameterSpec:IV,GCMParameterSpec:GCM},Cipher:{ENCRYPT_MODE:1,DECRYPT_MODE:2,getInstance:t=>{
    const transform=String(t).includes('/')?String(t):String(t)+'/ECB/PKCS5Padding';
    if(!/^(AES|DES|DESede)\/(ECB|CBC|GCM)\/(PKCS5Padding|PKCS7Padding|NoPadding)$/i.test(transform))return deny('javax.crypto.Cipher.transformation');
    let mode,key,iv,aad=[],data=[];
    return {init:(m,k,v)=>{if(m!==1&&m!==2)return deny('javax.crypto.Cipher.mode');mode=m;key=k.getEncoded();iv=v?v.getIV():null;aad=[];data=[];},
      updateAAD:a=>{aad=aad.concat(signed(a));},update:a=>{data=data.concat(signed(a));return [];},
      doFinal:a=>{if(!mode)throw Error('Cipher 尚未初始化');if(a!==undefined)data=data.concat(signed(a));const out=native('cipher',transform,key,iv,mode===1,data,aad);data=[];return out;}};
  }},Mac:{getInstance:name=>{
    if(!/^HmacSHA(1|256)$/i.test(name))return deny('javax.crypto.Mac.algorithm');
    let key,buffer=[];return {init:k=>{key=k.getEncoded();buffer=[];},update:a=>{buffer=buffer.concat(signed(a));},doFinal:a=>{
      if(!key)throw Error('Mac 尚未初始化');if(a!==undefined)buffer=buffer.concat(signed(a));
      const out=signed(__call('hexDecode',__call('hmac',{b:buffer},String(name),{b:key},'hex'),'bytes'));buffer=[];return out;
    }};
  }}}};
  const magnitude=a=>a.reduce((v,b)=>(v<<8n)|BigInt(b&255),0n);
  function BI(value,radix) {
    if(value instanceof BI)this.n=value.n;
    // BigInteger(numBits, Random)：0 到 2^numBits-1 的均匀随机数（Diffie-Hellman 等用）。
    else if(typeof value==='number'&&radix&&typeof radix.nextBytes==='function'){if(!Number.isInteger(value)||value<0||value>65536)throw Error('BigInteger 位数无效');const a=Array(Math.ceil(value/8)).fill(0);radix.nextBytes(a);this.n=a.length?magnitude(a)&((1n<<BigInt(value))-1n):0n;}
    else if(Array.isArray(radix)) {const m=magnitude(radix);if(![-1,0,1].includes(value)||(value===0&&m!==0n))throw Error('BigInteger signum 无效');this.n=BigInt(value)*m;}
    else if(Array.isArray(value)) {if(!value.length)throw Error('BigInteger 空字节');this.n=magnitude(value);if((value[0]&128)!==0)this.n-=1n<<BigInt(value.length*8);}
    else if(radix===undefined||radix===10)this.n=BigInt(value);
    else {
      if(radix<2||radix>36)throw Error('BigInteger radix 无效');let s=String(value).toLowerCase(),negative=s[0]==='-';if(negative||s[0]==='+')s=s.slice(1);
      if(!s.length)throw Error('BigInteger 空字符串');this.n=0n;for(const c of s){const d='0123456789abcdefghijklmnopqrstuvwxyz'.indexOf(c);if(d<0||d>=radix)throw Error('BigInteger 字符无效');this.n=this.n*BigInt(radix)+BigInt(d);}if(negative)this.n=-this.n;
    }
  }
  BI.valueOf=x=>new BI(x);BI.ONE=new BI(1);BI.ZERO=new BI(0);BI.TEN=new BI(10);
  BI.prototype.toString=function(radix){return this.n.toString(radix||10);};
  BI.prototype.toByteArray=function(){let size=1;while(this.n<-(1n<<BigInt(size*8-1))||this.n>=(1n<<BigInt(size*8-1)))size++;let n=BigInt.asUintN(size*8,this.n),a=Array(size);for(let i=size-1;i>=0;i--){a[i]=Number(n&255n);n>>=8n;}return signed(a);};
  for(const [name,fn] of Object.entries({add:(a,b)=>a+b,subtract:(a,b)=>a-b,multiply:(a,b)=>a*b,divide:(a,b)=>a/b,remainder:(a,b)=>a%b,and:(a,b)=>a&b,or:(a,b)=>a|b,xor:(a,b)=>a^b}))BI.prototype[name]=function(b){return new BI(fn(this.n,b.n));};
  BI.prototype.mod=function(m){if(m.n<=0n)throw Error('模数须为正');return new BI((this.n%m.n+m.n)%m.n);};
  BI.prototype.modPow=function(exponent,modulus){if(exponent.n<0n)return deny('java.math.BigInteger.negativeExponent');let e=exponent.n,b=this.mod(modulus).n,r=1n%modulus.n;while(e){if(e&1n)r=r*b%modulus.n;b=b*b%modulus.n;e>>=1n;}return new BI(r);};
  BI.prototype.shiftLeft=function(n){return new BI(this.n<<BigInt(n));};BI.prototype.shiftRight=function(n){return new BI(this.n>>BigInt(n));};
  BI.prototype.intValue=function(){return Number(BigInt.asIntN(32,this.n));};BI.prototype.signum=function(){return this.n<0n?-1:this.n>0n?1:0;};
  BI.prototype.compareTo=function(b){return this.n<b.n?-1:this.n>b.n?1:0;};BI.prototype.equals=function(b){return b instanceof BI&&this.n===b.n;};
  java.math={BigInteger:BI};
  function range(a,offset,length){const start=offset===undefined?0:offset,n=length===undefined?a.length:length;if(!Number.isInteger(start)||!Number.isInteger(n)||start<0||n<0||start+n>a.length)throw Error('流数组范围无效');return [start,n];}
  function Output(){this.data=[];this.write=(a,offset,length)=>{let b;if(typeof a==='number')b=signed([a]);else {const [start,n]=range(a,offset,length);b=signed(a.slice(start,start+n));}if(this.data.length+b.length>16777216)throw Error('内存流超过上限');this.data=this.data.concat(b);};this.toByteArray=()=>this.data.slice();this.toString=c=>String(new JString(this.data,c));this.close=()=>{};this.flush=()=>{};}
  function Input(a){this.data=signed(a);this.at=0;this.read=(b,offset,length)=>{if(b===undefined)return this.at>=this.data.length?-1:this.data[this.at++]&255;const [start,len]=range(b,offset,length);if(!len)return 0;if(this.at>=this.data.length)return -1;const n=Math.min(len,this.data.length-this.at);for(let i=0;i<n;i++)b[start+i]=this.data[this.at++];return n;};this.readAllBytes=()=>{const out=this.data.slice(this.at);this.at=this.data.length;return out;};this.close=()=>{};}
  function Reader(input,encoding){this.text=String(new JString(input.readAllBytes(),encoding));this.close=()=>input.close();}
  function Buffered(reader){const lines=reader.text.split(/\r\n|\r|\n/);if(lines[lines.length-1]==='')lines.pop();this.readLine=()=>lines.length?lines.shift():null;this.close=()=>reader.close();}
  // HttpURLConnection 子集：请求在第一次读响应时经插件网络通道发出；不开放套接字或任意协议。
  function Connection(url){
    let method='GET',sent=null,out=null;const headers={};
    const run=()=>{if(!sent)sent=__call('httpConnect',{url,method,headers,body:out?out.data:null});return sent;};
    const idle=()=>{};
    this.setRequestMethod=m=>{m=String(m).toUpperCase();if(!['GET','POST','PUT','DELETE','HEAD'].includes(m))throw Error('不支持的请求方法');method=m;};
    this.setRequestProperty=(k,v)=>{if(sent)throw Error('请求已发送');headers[String(k)]=String(v);};
    this.addRequestProperty=this.setRequestProperty;
    this.setDoOutput=idle;this.setDoInput=idle;this.setConnectTimeout=idle;this.setReadTimeout=idle;
    this.setUseCaches=idle;this.setInstanceFollowRedirects=idle;this.connect=idle;this.disconnect=idle;
    this.getOutputStream=()=>{if(sent)throw Error('请求已发送');if(!out)out=new Output();return out;};
    this.getResponseCode=()=>run().code;
    this.getInputStream=()=>{const r=run();if(r.code>=400)throw Error('HTTP 状态 '+r.code);return new Input(r.body);};
    this.getErrorStream=()=>{const r=run();return r.code>=400?new Input(r.body):null;};
    this.getHeaderField=n=>{const v=run().headers[String(n).toLowerCase()];return v===undefined?null:v;};
    this.getContentEncoding=()=>this.getHeaderField('content-encoding');
    this.getURL=()=>new java.net.URL(url);
  }
  java.io={ByteArrayInputStream:Input,ByteArrayOutputStream:Output,InputStreamReader:Reader,BufferedReader:Buffered};
  java.util.zip={GZIPInputStream:function(input){Input.call(this,native('gunzip',input.readAllBytes()));},GZIPOutputStream:function(output){Output.call(this);let finished=false;const write=this.write;this.write=(...args)=>{if(finished)throw Error('压缩流已结束');write(...args);};this.finish=()=>{if(!finished){output.write(native('gzip',this.data));finished=true;}};this.close=()=>{this.finish();output.close();};}};
  java.net.URL=function(base,path){const value=native('url',String(base),path===undefined?null:String(path));this.toString=()=>value.url;this.toExternalForm=()=>value.url;this.getHost=()=>value.host;this.getPort=()=>value.port;this.getProtocol=()=>value.protocol;this.getPath=()=>value.path;this.getQuery=()=>value.query;this.getRef=()=>value.ref;this.openConnection=()=>new Connection(value.url);this.openStream=()=>deny('java.net.URL.openStream');};
  for(const key of ['lang','io','math','net','security']){
    for(const name of Object.keys(java[key]))if((typeof java[key][name]==='object'||typeof java[key][name]==='function')&&java[key][name]!==null)java[key][name]=guard(java[key][name],'java.'+key+'.'+name);
    java[key]=guard(java[key],'java.'+key);
  }
  java.nio.ByteBuffer=guard({allocate:n=>{
    if(!Number.isInteger(n)||n<0||n>16777216)throw Error('ByteBuffer 容量无效');
    const data=Array(n).fill(0);return guard({array:()=>data,capacity:()=>n},'java.nio.ByteBuffer');
  }},'java.nio.ByteBuffer');
  java.nio=guard(java.nio,'java.nio');java.util=guard(java.util,'java.util');
  g.javax.crypto=guard(g.javax.crypto,'javax.crypto');g.javax=guard(g.javax,'javax');
  function RequestBuilder() {
    let url='',headers=Object.create(null);
    this.url=value=>{url=String(value);return this;};
    this.get=()=>this;
    this.addHeader=(name,value)=>{name=String(name).toLowerCase();if(name in headers)throw Error('暂不支持重复名称的请求头');headers[name]=String(value);return this;};
    this.build=()=>({url,headers:{...headers}});
  }
  function OkHttpClient() {
    this.newCall=request=>{
      const spec={url:request.url,method:'GET',headers:{...request.headers},body:null};
      let executed=false;
      return {execute:()=>{
        if(executed)throw Error('请求已经执行');executed=true;
        const response=__call('httpConnect',spec);
        let closed=false;
        const body={bytes:()=>{if(closed)throw Error('响应体已关闭');closed=true;return signed(response.body);},close:()=>{closed=true;}};
        return {code:()=>response.code,body:()=>body,close:()=>body.close()};
      }};
    };
  }
  g.okhttp3=guard({Request:guard({Builder:RequestBuilder},'okhttp3.Request'),OkHttpClient},'okhttp3');
  g.cn={hutool:{crypto:{digest:{DigestUtil:guard({md5:data=>signed(__call('hexDecode',__call('digest',Array.isArray(data)?{b:signed(data)}:{s:String(data)},'MD5',32),'bytes'))},'cn.hutool.crypto.digest.DigestUtil')}}}};
  g.java=guard(java,'java');
  g.android=guard(g.android,'android');g.Packages=guard({java:g.java,javax:g.javax,android:g.android,org:g.org,okhttp3:g.okhttp3,cn:g.cn},'Packages');
  // 阅读里网页文本是 Java 字符串，书源常把 replaceAll 的第一个参数写成 Java 正则；原文里没有这串字面文字时才按正则替换。
  const literalReplaceAll=String.prototype.replaceAll;
  Object.defineProperty(String.prototype,'replaceAll',{configurable:true,writable:true,value:function(p,r){
    const text=String(this);
    if(typeof p==='string'&&p&&!text.includes(p)&&/[\\[\](){}*+?.^$|]/.test(p)){
      try{return text.replace(new RegExp(p,'g'),typeof r==='string'?r.replace(/\\\$/g,'$$$$'):r);}catch(e){}
    }
    return literalReplaceAll.call(text,p,r);
  }});
})(globalThis);
