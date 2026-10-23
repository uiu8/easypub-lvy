//! 书源的四个流程：搜索、书籍信息、目录、正文。
use crate::{engine::Scope, node::Node, pattern, source::BookSource, text};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use std::collections::{HashMap, HashSet};

const MAX_TOC_PAGES: usize = 500;
const MAX_CHAPTERS: usize = 50_000;
const MAX_CONTENT_PAGES: usize = 100;

#[derive(Clone, Debug, Default, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase", default)]
pub struct Book {
    pub name: String,
    pub author: String,
    pub kind: String,
    pub word_count: String,
    #[serde(alias = "latestChapterTitle")]
    pub last_chapter: String,
    pub intro: String,
    pub cover_url: String,
    pub book_url: String,
    pub toc_url: String,
    /// 书源地址。
    pub origin: String,
    pub origin_name: String,
    /// 文件类书源的下载地址。
    pub download_urls: Vec<String>,
    /// 书籍变量（`book.putVariable`），JSON 文字。
    pub variable: String,
    /// 规则变量随书籍跨 RPC 传递；不能放入同源共享状态。
    #[serde(with = "crate::rule_state", skip_serializing_if = "HashMap::is_empty")]
    pub rule_variables: HashMap<String, String>,
    #[serde(alias = "totalChapterNum")]
    pub chapter_count: usize,
    pub count_exact: bool,
    /// 书源脚本设置的目录方向，随书籍跨 RPC 保存。
    pub reverse_toc: bool,
}

#[derive(Clone, Debug, Default, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase", default)]
pub struct Chapter {
    pub index: usize,
    #[serde(alias = "chapterName")]
    pub title: String,
    #[serde(alias = "chapterUrl")]
    pub url: String,
    /// 目录里同一章的其他分页地址；老数据默认空。
    pub extra_urls: Vec<String>,
    /// 目录头部移除的最新章节项数，只记在第一项，供下载质量报告使用。
    pub dropped_latest_block: usize,
    pub is_volume: bool,
    pub is_vip: bool,
    pub is_pay: bool,
    pub update_time: String,
    #[serde(with = "crate::rule_state", skip_serializing_if = "HashMap::is_empty")]
    pub rule_variables: HashMap<String, String>,
}

fn truthy(text: &str) -> bool {
    !matches!(
        text.trim().to_ascii_lowercase().as_str(),
        "" | "false" | "0" | "null" | "undefined" | "no"
    )
}

impl Book {
    fn json(&self) -> Value {
        let mut public = self.clone();
        public.rule_variables.clear();
        let mut v = serde_json::to_value(public).unwrap_or_else(|_| json!({}));
        v["ruleVariables"] = json!(self.rule_variables);
        if let Ok(vars) = serde_json::from_str::<Value>(&self.variable) {
            v["variables"] = vars;
        }
        v["latestChapterTitle"] = Value::String(self.last_chapter.clone());
        v
    }
}

impl Chapter {
    fn json(&self) -> Value {
        let mut public = self.clone();
        public.rule_variables.clear();
        let mut value = serde_json::to_value(public).unwrap_or_else(|_| json!({}));
        value["ruleVariables"] = json!(self.rule_variables);
        value
    }
}

impl Scope<'_, '_> {
    fn rules(&self, group: fn(&BookSource) -> &crate::source::Rules, key: &str) -> String {
        BookSource::rule(group(self.source()), key).to_owned()
    }

    fn book_from(&self, item: &Node, group: fn(&BookSource) -> &crate::source::Rules) -> Book {
        let field = |key: &str| {
            let rule = self.rules(group, key);
            if rule.is_empty() {
                String::new()
            } else {
                self.get_string_on(&rule, item).trim().to_owned()
            }
        };
        // name 中的 @put 常供后面的地址字段使用。
        let name = text::clean_name(&field("name"));
        let author = text::clean_author(&field("author"));
        let kind_rule = self.rules(group, "kind");
        let kind = if kind_rule.is_empty() {
            String::new()
        } else {
            self.get_strings_on(&kind_rule, item)
                .iter()
                .flat_map(|s| s.split(['\n', ',']))
                .map(str::trim)
                .filter(|s| !s.is_empty())
                .collect::<Vec<_>>()
                .join(",")
        };
        let book_url = self.url_field(&self.rules(group, "bookUrl"), item);
        let cover = self.url_field(&self.rules(group, "coverUrl"), item);
        Book {
            name,
            author,
            kind,
            word_count: field("wordCount"),
            last_chapter: field("lastChapter"),
            intro: text::html_to_text(&field("intro")),
            cover_url: if cover.is_empty() {
                cover
            } else {
                self.absolute(&cover)
            },
            book_url: if book_url.is_empty() {
                String::new()
            } else {
                self.absolute(&book_url)
            },
            origin: self.source().book_source_url.clone(),
            origin_name: self.source().book_source_name.clone(),
            rule_variables: self.inner.st.borrow().vars.clone(),
            ..Default::default()
        }
    }

    /// 网址类字段只取第一个结果（同阅读）：规则命中多个链接时不能拼在一起。
    fn url_field(&self, rule: &str, item: &Node) -> String {
        if rule.is_empty() {
            return String::new();
        }
        self.get_strings_on(rule, item)
            .into_iter()
            .flat_map(|s| s.lines().map(str::to_owned).collect::<Vec<_>>())
            .map(|s| s.trim().to_owned())
            .find(|s| !s.is_empty())
            .unwrap_or_default()
    }

    /// 搜索第 `page` 页。搜索结果直接跳到书籍详情页时，按详情页解析成一项。
    pub fn search(&self, key: &str, page: i64) -> Result<Vec<Book>, String> {
        if !self.source().html.is_empty() {
            let value = crate::qysg::call(self, "search", json!([key, page]))?;
            if value
                .as_array()
                .is_some_and(|items| items.iter().any(|b| b["type"].as_i64().unwrap_or(0) != 0))
            {
                return Err("HTML 书源返回音频或漫画，当前仅支持文字书籍".into());
            }
            return self.script_books(value);
        }
        if !self.source().main_js.is_empty() {
            let value = self.main_call("search", json!([key, page]))?;
            return self.script_books(value);
        }
        let url = self.source().search_url.trim().to_owned();
        if url.is_empty() {
            return Err("书源没有搜索地址".into());
        }
        {
            let mut st = self.inner.st.borrow_mut();
            st.key = key.to_owned();
            st.page = page;
            st.vars.clear();
            st.script_error = None;
        }
        self.set_book(json!({}));
        let response = self.fetch(&url)?;
        let pattern = self.source().book_url_pattern.trim().to_owned();
        if !pattern.is_empty()
            && pattern::compile(&pattern).is_some_and(|p| p.is_match(&response.url))
        {
            let mut book = Book {
                book_url: response.url.clone(),
                ..Default::default()
            };
            self.parse_info(&mut book)?;
            return Ok(vec![book]);
        }
        let list_rule = self.rules(|s| &s.rule_search, "bookList");
        let items = if list_rule.is_empty() {
            Vec::new()
        } else {
            self.get_elements(&list_rule)
        };
        if items.is_empty() && !self.rules(|s| &s.rule_book_info, "name").is_empty() {
            // 没有列表：可能直接是详情页。
            let mut book = Book {
                book_url: response.url.clone(),
                ..Default::default()
            };
            self.parse_info(&mut book)?;
            return Ok(if book.name.is_empty() {
                Vec::new()
            } else {
                vec![book]
            });
        }
        let mut books = Vec::new();
        let mut seen = HashSet::new();
        let list_vars = self.inner.st.borrow().vars.clone();
        for item in &items {
            self.inner.st.borrow_mut().vars = list_vars.clone();
            let mut book = self.book_from(item, |s| &s.rule_search);
            if book.name.is_empty() {
                continue;
            }
            if book.book_url.is_empty() {
                book.book_url = response.url.clone();
            }
            if seen.insert(book.book_url.clone()) {
                books.push(book);
            }
        }
        if books.is_empty()
            && let Some(e) = self.inner.st.borrow_mut().script_error.take()
        {
            return Err(format!("搜索脚本出错：{e}"));
        }
        Ok(books)
    }

    /// 发现页（分类）同搜索，用发现规则。
    pub fn explore(&self, url: &str, page: i64) -> Result<Vec<Book>, String> {
        if !self.source().main_js.is_empty() {
            return self.script_books(self.main_call("explore", json!([url, page]))?);
        }
        {
            let mut st = self.inner.st.borrow_mut();
            st.page = page;
            st.script_error = None;
        }
        self.fetch(url)?;
        let list_rule = self.rules(|s| &s.rule_explore, "bookList");
        let group: fn(&BookSource) -> &crate::source::Rules = if list_rule.is_empty() {
            |s| &s.rule_search
        } else {
            |s| &s.rule_explore
        };
        let list_rule = if list_rule.is_empty() {
            self.rules(|s| &s.rule_search, "bookList")
        } else {
            list_rule
        };
        let items = self.get_elements(&list_rule);
        let list_vars = self.inner.st.borrow().vars.clone();
        let books: Vec<Book> = items
            .iter()
            .map(|item| {
                self.inner.st.borrow_mut().vars = list_vars.clone();
                self.book_from(item, group)
            })
            .filter(|b| !b.name.is_empty())
            .collect();
        if books.is_empty()
            && let Some(e) = self.inner.st.borrow_mut().script_error.take()
        {
            return Err(format!("发现脚本出错：{e}"));
        }
        Ok(books)
    }

    /// 打开书籍详情页并补全信息；目录地址为空时用详情页地址。
    pub fn book_info(&self, book: &mut Book) -> Result<(), String> {
        if !self.source().html.is_empty() {
            let mut value = crate::qysg::call(self, "info", json!([book.book_url]))?;
            if value["type"].as_i64().unwrap_or(0) != 0 {
                return Err("HTML 书源当前仅支持文字书籍".into());
            }
            let fields = value.as_object_mut().ok_or("HTML 书源详情格式无效")?;
            if let Some(last) = fields.remove("latestChapterTitle") {
                fields.insert("lastChapter".into(), last);
            }
            let mut merged = serde_json::to_value(&*book).unwrap();
            for (key, value) in fields {
                merged[key] = value.clone();
            }
            *book = serde_json::from_value(merged).map_err(|_| "HTML 书源详情格式无效")?;
            if book.toc_url.is_empty() {
                book.toc_url = book.book_url.clone();
            }
            book.toc_url = crate::engine::absolute(&book.book_url, &book.toc_url);
            return Ok(());
        }
        if !self.source().main_js.is_empty() {
            let value = self.main_call("getBookInfo", json!([book]))?;
            if value.is_object() {
                let mut merged = serde_json::to_value(&*book).unwrap();
                for (key, value) in value.as_object().unwrap() {
                    merged[key] = value.clone();
                }
                *book = serde_json::from_value(merged).map_err(|_| "单文件 JS 书籍信息格式错误")?;
            }
            return Ok(());
        }
        if book.book_url.trim().is_empty() {
            return Err("没有书籍地址".into());
        }
        self.set_book(book.json());
        self.fetch(&book.book_url.clone())?;
        self.parse_info(book)
    }

    fn parse_info(&self, book: &mut Book) -> Result<(), String> {
        let init = self.rules(|s| &s.rule_book_info, "init");
        if !init.is_empty()
            && let Some(first) = self.get_elements(&init).into_iter().next()
        {
            self.set_content(first, None);
        }
        let content = self.content();
        let info = self.book_from(&content, |s| &s.rule_book_info);
        let rename = !self.rules(|s| &s.rule_book_info, "canReName").is_empty();
        let keep = |old: &mut String, new: String, can_replace: bool| {
            if !new.is_empty() && (old.is_empty() || can_replace) {
                *old = new;
            }
        };
        keep(&mut book.name, info.name, rename);
        keep(&mut book.author, info.author, rename);
        keep(&mut book.kind, info.kind, true);
        keep(&mut book.word_count, info.word_count, true);
        keep(&mut book.last_chapter, info.last_chapter, true);
        keep(&mut book.intro, info.intro, true);
        keep(&mut book.cover_url, info.cover_url, true);
        let toc = self.rules(|s| &s.rule_book_info, "tocUrl");
        let toc_url = self.url_field(&toc, &content);
        let page_url = self.inner.st.borrow().redirect_url.clone();
        book.toc_url = if toc_url.is_empty() {
            page_url.clone()
        } else {
            self.absolute(&toc_url)
        };
        if book.book_url.is_empty() {
            book.book_url = page_url;
        }
        let downloads = self.rules(|s| &s.rule_book_info, "downloadUrls");
        if !downloads.is_empty() {
            book.download_urls = self
                .get_strings_on(&downloads, &content)
                .iter()
                .map(|u| self.absolute(u))
                .collect();
        }
        book.origin = self.source().book_source_url.clone();
        book.origin_name = self.source().book_source_name.clone();
        book.rule_variables = self.inner.st.borrow().vars.clone();
        book.reverse_toc = self.inner.st.borrow().book["reverseToc"]
            .as_bool()
            .unwrap_or(false);
        book.variable = self
            .inner
            .st
            .borrow()
            .book
            .get("variables")
            .map(Value::to_string)
            .unwrap_or_default();
        self.set_book(book.json());
        Ok(())
    }

    /// 目录：逐页读取（`nextTocUrl` 给出的地址去重后排队），`chapterList` 开头 `-` 时整体倒序。
    pub fn toc(&self, book: &Book) -> Result<Vec<Chapter>, String> {
        if !self.source().html.is_empty() {
            let url = if book.toc_url.is_empty() {
                &book.book_url
            } else {
                &book.toc_url
            };
            let value = crate::qysg::call(self, "chapter", json!([url]))?;
            let items = value.as_array().ok_or("HTML 书源目录格式无效")?;
            if items.len() > MAX_CHAPTERS {
                return Err("目录章节过多".into());
            }
            let mut chapters = Vec::new();
            for (index, item) in items.iter().enumerate() {
                let mut item = item.clone();
                item["title"] = item["name"].clone();
                item["url"] = item["chapterId"].clone();
                let mut c: Chapter =
                    serde_json::from_value(item).map_err(|_| "HTML 书源目录格式无效")?;
                c.index = index;
                c.url = crate::engine::absolute(url, &c.url);
                chapters.push(c);
            }
            return Ok(crate::chapter_cleanup::normalize_toc(chapters));
        }
        if !self.source().main_js.is_empty() {
            let value = self.main_call("getChapters", json!([book]))?;
            let mut chapters: Vec<Chapter> =
                serde_json::from_value(value).map_err(|_| "单文件 JS 目录格式错误")?;
            for (i, c) in chapters.iter_mut().enumerate() {
                c.index = i;
                c.url = self.absolute(&c.url);
            }
            return Ok(crate::chapter_cleanup::normalize_toc(chapters));
        }
        self.set_book(book.json());
        self.inner.st.borrow_mut().script_error = None;
        let toc_url = if book.toc_url.is_empty() {
            book.book_url.clone()
        } else {
            book.toc_url.clone()
        };
        let list_rule = self.rules(|s| &s.rule_toc, "chapterList");
        if list_rule.is_empty() {
            return Err("书源没有目录规则".into());
        }
        let (reverse, list_rule) = match list_rule.strip_prefix('-') {
            Some(r) => (true, r.to_owned()),
            None => (false, list_rule.trim_start_matches('+').to_owned()),
        };
        let pre = self.rules(|s| &s.rule_toc, "preUpdateJs");
        if !pre.is_empty() {
            self.js_or_log(&pre);
        }
        let mut queue = std::collections::VecDeque::from([toc_url.clone()]);
        let mut seen: HashSet<String> = HashSet::from([toc_url]);
        let mut chapters: Vec<Chapter> = Vec::new();
        let (mut unlinked, mut linked) = (Vec::new(), false);
        let mut address_error = None;
        let mut pages = 0;
        while let Some(url) = queue.pop_front() {
            pages += 1;
            if pages > MAX_TOC_PAGES {
                return Err("目录页数过多".into());
            }
            self.fetch(&url)?;
            let items = self.get_elements(&list_rule);
            let list_vars = self.inner.st.borrow().vars.clone();
            for item in items {
                self.inner.st.borrow_mut().vars = list_vars.clone();
                let get = |key: &str| {
                    let rule = self.rules(|s| &s.rule_toc, key);
                    if rule.is_empty() {
                        String::new()
                    } else {
                        self.get_string_on(&rule, &item).trim().to_owned()
                    }
                };
                let title = get("chapterName");
                if title.is_empty() {
                    continue;
                }
                let raw_url = self.url_field(&self.rules(|s| &s.rule_toc, "chapterUrl"), &item);
                if raw_url.is_empty()
                    && let Some(error) = self.inner.st.borrow_mut().script_error.take()
                {
                    address_error.get_or_insert(error);
                }
                // 没有链接的目录项先按卷名处理（只保留标题，不去取正文）；整本都没有链接时见循环后。
                let explicit_volume = truthy(&get("isVolume"));
                let is_volume = explicit_volume || raw_url.is_empty();
                let page = self.inner.st.borrow().redirect_url.clone();
                if raw_url.is_empty() && !explicit_volume {
                    unlinked.push((chapters.len(), page.clone()));
                } else if !explicit_volume {
                    linked = true;
                }
                let url = if raw_url.is_empty() {
                    format!("{page}#{title}")
                } else {
                    self.absolute(&raw_url)
                };
                chapters.push(Chapter {
                    index: 0,
                    title: crate::dom::normalize(&title),
                    url,
                    is_volume,
                    is_vip: truthy(&get("isVip")),
                    is_pay: truthy(&get("isPay")),
                    update_time: get("updateTime"),
                    rule_variables: self.inner.st.borrow().vars.clone(),
                    ..Default::default()
                });
                if chapters.len() > MAX_CHAPTERS {
                    return Err("章节过多".into());
                }
            }
            self.inner.st.borrow_mut().vars = list_vars;
            let next = self.rules(|s| &s.rule_toc, "nextTocUrl");
            if !next.is_empty() {
                let content = self.content();
                for u in self.get_strings_on(&next, &content) {
                    let u = self.absolute(u.trim());
                    if !u.is_empty() && seen.insert(u.clone()) {
                        queue.push_back(u);
                    }
                }
            }
        }
        if chapters.is_empty()
            && let Some(e) = self.inner.st.borrow_mut().script_error.take()
        {
            return Err(format!("目录脚本出错：{e}"));
        }
        // 整本目录都没有链接（单篇、诗词类书源）：与阅读一致，这些项是章节，正文就在所在目录页。
        if !linked {
            // 混合目录里的无链接项可以是卷名；只有全目录地址失败才阻止单篇回退。
            if let Some(error) = address_error {
                return Err(format!("目录脚本出错：{error}"));
            }
            for (i, page) in unlinked {
                chapters[i].is_volume = false;
                chapters[i].url = page;
            }
        }
        if reverse
            ^ self.inner.st.borrow().book["reverseToc"]
                .as_bool()
                .unwrap_or(false)
        {
            chapters.reverse();
        }
        chapters = crate::chapter_cleanup::normalize_toc(chapters);
        let format = self.rules(|s| &s.rule_toc, "formatJs");
        for (i, c) in chapters.iter_mut().enumerate() {
            c.index = i;
            if !format.is_empty() {
                self.ctx.globals().set("index", i as i64 + 1).ok();
                self.ctx.globals().set("gInt", 0).ok();
                self.inner.st.borrow_mut().title = c.title.clone();
                if let Ok(t) = self.eval_js_string(&format, &[Node::Text(c.title.clone())])
                    && !t.trim().is_empty()
                {
                    c.title = t.trim().to_owned();
                }
            }
        }
        Ok(chapters)
    }

    fn js_or_log(&self, code: &str) {
        let code = code.trim().strip_prefix("@js:").unwrap_or(code.trim());
        let code = code
            .strip_prefix("<js>")
            .map(|c| c.trim_end().trim_end_matches("</js>"))
            .unwrap_or(code);
        if let Err(e) = self.eval_js(code, &[Node::Text(String::new())]) {
            self.log(format!("JS 出错：{e}"));
        }
    }

    /// 一章正文（已转成文字、已做书源净化）。`next_chapter_url` 用于判断正文翻页何时到了下一章。
    pub fn chapter_content(
        &self,
        book: &Book,
        chapter: &Chapter,
        next_chapter_url: &str,
    ) -> Result<String, String> {
        let key = format!(
            "{}\n{}\n{}\n{}",
            book.book_url,
            chapter.url,
            next_chapter_url,
            crate::control::current().remove_prompts
        );
        self.inner.rt.flights.run(key, || {
            self.chapter_content_inner(book, chapter, next_chapter_url)
        })
    }

    fn chapter_content_inner(
        &self,
        book: &Book,
        chapter: &Chapter,
        next_chapter_url: &str,
    ) -> Result<String, String> {
        if chapter.is_volume && chapter.url.contains('#') {
            return Ok(String::new());
        }
        if chapter.is_pay {
            return Err("付费章节，未取到".into());
        }
        let mut context = crate::control::current();
        context.profile = crate::control::Profile::Content;
        let _guard = context.clone().enter();
        self.set_book(book.json());
        self.set_chapter(chapter.json());
        {
            let mut st = self.inner.st.borrow_mut();
            st.next_chapter_url = next_chapter_url.to_owned();
            st.script_error = None;
        }
        if !self.source().html.is_empty() {
            let value = crate::qysg::call(self, "content", json!([chapter.url]))?;
            let body = value.as_str().ok_or("HTML 书源正文格式无效")?;
            return Ok(self.finish_content(body, chapter));
        }
        if !self.source().main_js.is_empty() {
            let result = self.main_call("getContent", json!([chapter, book, next_chapter_url]))?;
            let text = result
                .as_str()
                .or_else(|| result["content"].as_str())
                .ok_or("单文件 JS 正文格式错误")?;
            return Ok(self.finish_content(text, chapter));
        }
        let content_rule = self.rules(|s| &s.rule_content, "content");
        if content_rule.is_empty() {
            return Err("书源没有正文规则".into());
        }
        let next_chapter = if next_chapter_url.is_empty() {
            String::new()
        } else {
            self.absolute(next_chapter_url)
        };
        let mut queue = std::collections::VecDeque::from([chapter.url.clone()]);
        let mut queued = HashSet::from([chapter.url.clone()]);
        for url in &chapter.extra_urls {
            if queued.insert(url.clone()) {
                queue.push_back(url.clone());
            }
        }
        let mut visited = HashSet::new();
        let mut output = String::new();
        while !queue.is_empty() {
            context.check()?;
            let urls: Vec<_> = (0..3)
                .filter_map(|_| queue.pop_front())
                .filter(|u| !visited.contains(u))
                .collect();
            if visited.len() + urls.len() > MAX_CONTENT_PAGES {
                return Err("正文页数过多".into());
            }
            let pages = if urls.len() == 1 {
                vec![self.content_page(book, chapter, &urls[0])?]
            } else {
                // 只并发已知地址；未知的“下一页”仍顺序发现。每个子线程有自己的 JS 上下文。
                std::thread::scope(|scope| {
                    let handles: Vec<_> = urls
                        .iter()
                        .map(|url| {
                            let rt = self.inner.rt.clone();
                            let vars = self.inner.st.borrow().vars.clone();
                            let context = context.clone();
                            scope.spawn(move || {
                                let _guard = context.enter();
                                let engine = crate::engine::Engine::new(rt)?;
                                engine.state().vars = vars;
                                engine.state().next_chapter_url = next_chapter_url.to_owned();
                                engine.run(|s| s.content_page(book, chapter, url))
                            })
                        })
                        .collect();
                    handles
                        .into_iter()
                        .map(|h| h.join().map_err(|_| "正文分页读取失败".to_owned())?)
                        .collect::<Result<Vec<_>, String>>()
                })?
            };
            for (url, page) in urls.into_iter().zip(pages) {
                visited.insert(url);
                visited.insert(page.redirect);
                crate::chapter_cleanup::append_page(&mut output, &page.text);
                for next in page.next {
                    if next != next_chapter
                        && !visited.contains(&next)
                        && queued.insert(next.clone())
                    {
                        queue.push_back(next);
                    }
                }
            }
        }
        if output.trim().is_empty() {
            if let Some(e) = self.inner.st.borrow_mut().script_error.take() {
                return Err(format!("正文脚本出错：{e}"));
            }
            return Err("正文为空".into());
        }
        Ok(output)
    }

    fn script_books(&self, value: Value) -> Result<Vec<Book>, String> {
        let mut books: Vec<Book> =
            serde_json::from_value(value).map_err(|_| "单文件 JS 搜索结果格式错误")?;
        for book in &mut books {
            book.origin = self.source().book_source_url.clone();
            book.origin_name = self.source().book_source_name.clone();
            book.book_url = self.absolute(&book.book_url);
        }
        Ok(books)
    }
    fn finish_content(&self, content: &str, chapter: &Chapter) -> String {
        let mut text = text::html_to_text(content);
        let replace = self.rules(|s| &s.rule_content, "replaceRegex");
        if !replace.is_empty() {
            text = self.get_string_on(&replace, &Node::Text(text));
        }
        crate::chapter_cleanup::clean_page(
            &text,
            &chapter.title,
            crate::control::current().remove_prompts,
        )
    }
    pub fn chapter_batch(
        &self,
        book: &Book,
        chapters: &[Chapter],
    ) -> Result<std::collections::HashMap<String, String>, String> {
        let mut context = crate::control::current();
        context.profile = crate::control::Profile::Content;
        if !crate::hosts::local(self.source().base_url()) {
            self.net().wait_turn(&context).map_err(|e| e.0)?;
        }
        context.batch_rate_reserved = true;
        let _guard = context.enter();
        self.set_book(book.json());
        let urls: HashSet<_> = chapters.iter().map(|c| c.url.clone()).collect();
        if urls.len() != chapters.len() || chapters.len() > 50 {
            return Err("批量章节地址必须唯一且不超过 50 章".into());
        }
        {
            let mut state = self.inner.st.borrow_mut();
            state.batch_urls = urls;
            state.batch_content.clear();
        }
        let args = json!(chapters.iter().map(Chapter::json).collect::<Vec<_>>());
        let setup = format!("globalThis.chapters={args};");
        self.eval_js(&setup, &[])?;
        let result = if !self.source().main_js.is_empty() {
            self.main_call("getContentBatch", json!([chapters, book]))
                .map(|_| ())
        } else {
            let code = self.rules(|s| &s.rule_content, "contentBatch");
            let code = code
                .trim()
                .trim_start_matches("@js:")
                .trim_start_matches("<js>")
                .trim_end_matches("</js>");
            // result 和 chapters 都是本批数组，包括仅一章的情况。
            self.eval_js(&format!("result=chapters;\n{code}"), &[])
                .map(|_| ())
        };
        let raw = std::mem::take(&mut self.inner.st.borrow_mut().batch_content);
        self.inner.st.borrow_mut().batch_urls.clear();
        // 部分回存后脚本失败仍保留已回存项，漏项交回单章路径。
        if raw.is_empty() {
            result?;
        }
        Ok(chapters
            .iter()
            .filter_map(|c| {
                raw.get(&c.url)
                    .map(|t| (c.url.clone(), self.finish_content(t, c)))
            })
            .collect())
    }

    fn content_page(
        &self,
        book: &Book,
        chapter: &Chapter,
        url: &str,
    ) -> Result<ContentPage, String> {
        self.set_book(book.json());
        self.set_chapter(chapter.json());
        let web_js = self.rules(|s| &s.rule_content, "webJs");
        let mut spec = self.analyze_url(url)?;
        if !web_js.is_empty() {
            spec.web_js = web_js;
        }
        let source_regex = self.rules(|s| &s.rule_content, "sourceRegex");
        if spec.web_view && !source_regex.is_empty() {
            spec.request.source_regex = Some(source_regex);
        }
        self.fetch_analyzed(&spec)?;
        let content = self.content();
        let mut text =
            text::html_to_text(&self.get_string(&self.rules(|s| &s.rule_content, "content")));
        let replace = self.rules(|s| &s.rule_content, "replaceRegex");
        if !replace.is_empty() {
            text = self.get_string_on(&replace, &Node::Text(text));
            text = text::html_to_text(&text);
        }
        let next_rule = self.rules(|s| &s.rule_content, "nextContentUrl");
        let next = if next_rule.is_empty() {
            vec![]
        } else {
            self.get_strings_on(&next_rule, &content)
                .iter()
                .flat_map(|s| s.lines())
                .filter(|u| !u.trim().is_empty())
                .map(|u| self.absolute(u.trim()))
                // 页尾按钮可能返回 javascript: / mailto: 等占位链接，它们不是正文分页。
                .filter(|u| {
                    reqwest::Url::parse(crate::engine::split_options(u).0)
                        .is_ok_and(|url| matches!(url.scheme(), "http" | "https"))
                })
                .collect()
        };
        if text.trim().is_empty() {
            if let Some(e) = self.inner.st.borrow_mut().script_error.take() {
                return Err(format!("正文脚本出错：{e}"));
            }
            return Err("正文为空".into());
        }
        if crate::webview::looks_like_challenge(&text) && text.chars().count() < 1000 {
            return Err("需要网页验证".into());
        }
        Ok(ContentPage {
            text: crate::chapter_cleanup::clean_page(
                &text,
                &chapter.title,
                crate::control::current().remove_prompts,
            ),
            next,
            redirect: self.inner.st.borrow().redirect_url.clone(),
        })
    }
}

struct ContentPage {
    text: String,
    next: Vec<String>,
    redirect: String,
}
