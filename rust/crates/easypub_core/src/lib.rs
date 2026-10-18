//! Read-only R1 source experiments. No Flutter, I/O, or implicit legacy rules.
mod cp936_table;
pub mod encoding;
pub mod heading_typos;
pub mod recognition;
pub mod chapter_rules;
pub mod source;

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum ErrorCode {
    InvalidUtf8,
    InvalidEncoding,
    InvalidRule,
    OutputConflict,
    SourceChanged,
    Transaction,
    UnsupportedRule,
    InvalidCursor,
    InvalidLimit,
    NotFound,
    Io,
    TooLarge,
    Busy,
    Cancelled,
    StaleRevision,
    Internal,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ApiError {
    pub code: ErrorCode,
    pub operation: String,
    pub retryable: bool,
    pub next_action: String,
}

impl ApiError {
    pub fn new(code: ErrorCode, operation: &str, next_action: &str) -> Self {
        Self {
            code,
            operation: operation.into(),
            retryable: false,
            next_action: next_action.into(),
        }
    }
}

mod chinese_variant;
pub mod cleanup;
mod cleanup_duplicates;
mod cleanup_notice;
mod cleanup_numbers;
mod cleanup_ocr;
mod cleanup_punctuation;
pub mod cleanup_rules;
mod cleanup_text;

pub mod manual_edit;

pub mod publication;
pub mod rare_chars;
pub mod structure;

pub mod review;

pub mod effective_edit;
pub mod effective_repair;

mod effective_move;

pub mod duplicate_blocks;
mod effective_merge;
