// 仅生成公开测试密钥，绝不能用于生产。无需读取书源或用户凭据。
import java.nio.file.*;
import java.nio.charset.StandardCharsets;
import java.security.*;
import java.util.Base64;
import javax.crypto.Cipher;
import javax.crypto.spec.OAEPParameterSpec;
import java.security.spec.MGF1ParameterSpec;

class v97_rsa_oracle {
    static String b64(byte[] b) { return Base64.getEncoder().encodeToString(b); }
    public static void main(String[] args) throws Exception {
        if(args[0].equals("--verify")) {
            var p=new java.util.Properties();try(var r=Files.newBufferedReader(Path.of(args[1]))){p.load(r);}
            var key=KeyFactory.getInstance("RSA").generatePrivate(new java.security.spec.PKCS8EncodedKeySpec(Base64.getDecoder().decode(p.getProperty("private"))));
            int i=0;
            for(var algorithm:new String[]{"RSA/ECB/PKCS1Padding","RSA/ECB/OAEPWithSHA-1AndMGF1Padding","RSA/ECB/OAEPWithSHA-256AndMGF1Padding"}) {
                var cipher=Cipher.getInstance(algorithm);cipher.init(Cipher.DECRYPT_MODE,key);
                if(!new String(cipher.doFinal(Base64.getDecoder().decode(p.getProperty("cipher"+i++))),StandardCharsets.UTF_8).equals("公开测试 RSA 中文"))throw new Exception("RSA cross-check failed");
            }
            System.out.println("JDK decrypted all three AWS-LC RSA outputs.");return;
        }
        var generator=KeyPairGenerator.getInstance("RSA");
        generator.initialize(2048);
        var key=generator.generateKeyPair();
        var data="公开测试 RSA 中文".getBytes(StandardCharsets.UTF_8);
        var json=new StringBuilder("{\"testOnly\":true,\"public\":\"").append(b64(key.getPublic().getEncoded()))
            .append("\",\"private\":\"").append(b64(key.getPrivate().getEncoded())).append("\",\"cases\":[");
        boolean first=true;
        for(var algorithm:new String[]{"RSA/ECB/PKCS1Padding","RSA/ECB/OAEPWithSHA-1AndMGF1Padding","RSA/ECB/OAEPWithSHA-256AndMGF1Padding"}) {
            var cipher=Cipher.getInstance(algorithm);
            cipher.init(Cipher.ENCRYPT_MODE,key.getPublic());
            if(algorithm.contains("OAEP")) {
                var params=cipher.getParameters().getParameterSpec(OAEPParameterSpec.class);
                if(!((MGF1ParameterSpec)params.getMGFParameters()).getDigestAlgorithm().equals("SHA-1"))throw new Exception("MGF oracle changed");
            }
            if(!first)json.append(','); first=false;
            json.append("{\"algorithm\":\"").append(algorithm).append("\",\"cipher\":\"").append(b64(cipher.doFinal(data))).append("\"}");
        }
        var signature=Signature.getInstance("SHA256withRSA");signature.initSign(key.getPrivate());signature.update(data);
        json.append("],\"signature\":\"").append(b64(signature.sign())).append("\"}");
        Files.writeString(Path.of(args[0]),json.toString(),StandardCharsets.UTF_8);
        System.out.println("Synthetic RSA fixture written; OAEP MGF1 SHA-1 verified.");
    }
}
