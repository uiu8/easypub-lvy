// 本机 JDK 对照，全部为公开合成输入，不读用户书源或凭据。
import java.util.*;
import java.io.*;
import java.util.zip.*;
import java.math.BigInteger;
import java.security.*;
import javax.crypto.*;
import javax.crypto.spec.*;

class v97_java_oracle {
    public static void main(String[] args) throws Exception {
        var cipher = Cipher.getInstance("AES/CBC/PKCS5Padding");
        cipher.init(Cipher.ENCRYPT_MODE, new SecretKeySpec(new byte[16], "AES"), new IvParameterSpec(new byte[16]));
        var compressed = new ByteArrayOutputStream();
        try(var gzip = new GZIPOutputStream(compressed)) { gzip.write("fixture gzip 中文".getBytes("UTF-8")); }
        System.out.println("{\"aes_cbc_abc\":\""+HexFormat.of().formatHex(cipher.doFinal("abc".getBytes("UTF-8")))
            +"\",\"md5_abc\":\""+HexFormat.of().formatHex(MessageDigest.getInstance("MD5").digest("abc".getBytes("UTF-8")))
            +"\",\"gzip\":\""+Base64.getEncoder().encodeToString(compressed.toByteArray())
            +"\",\"big_integer_negative\":"+Arrays.toString(new BigInteger("-129").toByteArray())
            +",\"gbk\":"+Arrays.toString("中文".getBytes("GBK"))+"}");
    }
}
