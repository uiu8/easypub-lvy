//! 书源引擎（插件 P1）：按阅读 3.0 书源规则搜索、取书籍信息、目录与正文。
//!
//! 规则语法依据阅读的公开说明独立实现（阅读为 GPL-3.0，本项目不抄写其代码）。
pub mod catalogue;
pub mod chapter_cleanup;
pub mod control;
pub mod corpus;
pub mod crypto;
pub mod dom;
pub mod download;
pub mod engine;
pub mod hosts;
pub mod jcss;
pub mod jsonpath;
pub mod jsoup;
pub mod net;
pub mod network_config;
pub mod node;
pub mod pattern;
pub mod plugin;
pub mod probe;
pub mod qysg;
pub mod rule;
pub mod scheduler;
pub mod singleflight;
pub mod source;
pub mod source_formats;
pub mod support;
pub mod text;
pub mod webbook;
pub mod webview;
pub mod xpath;

#[cfg(test)]
mod live;
#[cfg(test)]
mod tests;
#[cfg(test)]
mod v89_tests;
#[cfg(test)]
mod v90_tests;
