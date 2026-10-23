//! 规则变量可能包含会话数据；跨 RPC/缓存只传当前 Windows 用户可解的密文。
use serde::{Deserialize, Deserializer, Serializer};
use std::collections::HashMap;

const CONTEXT: &[u8] = b"EasyPub.booksource.rule-state.v1";

pub fn serialize<S: Serializer>(
    vars: &HashMap<String, String>,
    serializer: S,
) -> Result<S::Ok, S::Error> {
    let bytes = serde_json::to_vec(vars).map_err(serde::ser::Error::custom)?;
    let sealed = crate::login_store::crypt(&bytes, CONTEXT, true)
        .map_err(|_| serde::ser::Error::custom("无法保护书籍规则变量"))?;
    serializer.serialize_str(&hex::encode(sealed))
}

pub fn deserialize<'de, D: Deserializer<'de>>(
    deserializer: D,
) -> Result<HashMap<String, String>, D::Error> {
    let sealed = String::deserialize(deserializer)?;
    if sealed.len() > 256 * 1024 {
        return Err(serde::de::Error::custom("规则变量数据过大"));
    }
    let bytes = hex::decode(sealed).map_err(|_| serde::de::Error::custom("规则变量密文无效"))?;
    let plain = crate::login_store::crypt(&bytes, CONTEXT, false)
        .map_err(|_| serde::de::Error::custom("无法恢复规则变量，请使用原 Windows 用户重新搜索"))?;
    serde_json::from_slice(&plain).map_err(|_| serde::de::Error::custom("规则变量格式无效"))
}
