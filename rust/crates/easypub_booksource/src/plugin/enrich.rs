use super::*;
pub(super) fn estimate(title: &str) -> usize {
    static RE: std::sync::LazyLock<regex::Regex> = std::sync::LazyLock::new(|| {
        regex::Regex::new(r"(?:第\s*|^\s*\[?)(\d+)\s*(?:[章节回]|\])").unwrap()
    });
    RE.captures(&crate::text::to_num_chapter(title))
        .and_then(|c| c[1].parse().ok())
        .unwrap_or(0)
}
pub(super) fn key(id: &str, book: &Book) -> String {
    format!("{id}\n{}", book.book_url)
}
pub(super) fn order(items: &mut [Value], keyword: &str) {
    let count = |s: &Value| s["book"]["chapterCount"].as_u64().unwrap_or(0);
    let mut maxima = std::collections::HashMap::<String, u64>::new();
    for row in items.iter() {
        let n = row["sources"]
            .as_array()
            .into_iter()
            .flatten()
            .map(&count)
            .max()
            .unwrap_or(0);
        let maximum = maxima
            .entry(row["name"].as_str().unwrap_or("").to_owned())
            .or_default();
        *maximum = (*maximum).max(n);
    }
    for row in items.iter_mut() {
        if let Some(sources) = row["sources"].as_array_mut() {
            sources.sort_by_key(|s| {
                (
                    s["pinned"] != true,
                    std::cmp::Reverse(count(s)),
                    std::cmp::Reverse(s["book"]["lastChapter"].as_str().unwrap_or("").to_owned()),
                    std::cmp::Reverse(
                        s["score"]
                            .as_i64()
                            .or_else(|| s["rating"].as_i64())
                            .unwrap_or(0),
                    ),
                    s["ms"].as_u64().unwrap_or(u64::MAX),
                )
            });
            let max = sources.iter().map(&count).max().unwrap_or(0);
            for s in sources {
                s["possiblyIncomplete"] = json!(count(s) > 0 && count(s) * 10 < max * 9);
            }
        }
    }
    let rank = |row: &Value| {
        let sources = row["sources"].as_array().cloned().unwrap_or_default();
        let n = sources.iter().map(&count).max().unwrap_or(0);
        let maximum = maxima
            .get(row["name"].as_str().unwrap_or(""))
            .copied()
            .unwrap_or(0);
        let ratio = if maximum == 0 {
            0
        } else if n * 100 >= maximum * 98 {
            10000
        } else {
            n * 10000 / maximum
        };
        (
            row["name"] != keyword,
            row["author"] != keyword,
            !sources.iter().any(|s| s["pinned"] == true),
            std::cmp::Reverse(ratio),
            std::cmp::Reverse(sources.len()),
            std::cmp::Reverse(
                sources
                    .iter()
                    .filter_map(|s| s["score"].as_i64().or_else(|| s["rating"].as_i64()))
                    .max()
                    .unwrap_or(0),
            ),
            sources
                .iter()
                .filter_map(|s| s["ms"].as_u64())
                .min()
                .unwrap_or(u64::MAX),
        )
    };
    // 先按同名书的最大章数算比例，避免成对“相差 2%”比较不具传递性。
    items.sort_by_key(rank);
}
pub(super) fn toc(id: &str, book: &mut Book, refresh: bool) -> Result<Vec<Chapter>, String> {
    let key = key(id, book);
    if !refresh {
        let cached = state().book_cache.get(&key).cloned();
        if let Some((b, t)) = cached
            && !t.is_empty()
        {
            *book = b;
            return Ok(t);
        }
    }
    let toc = with_engine(id, |e| {
        e.run(|s| {
            if book.toc_url.is_empty() {
                s.book_info(book)?;
            }
            s.toc(book)
        })
    })?;
    book.chapter_count = toc.iter().filter(|c| !c.is_volume).count();
    book.count_exact = true;
    if let Some(c) = toc.iter().rev().find(|c| !c.is_volume) {
        book.last_chapter = c.title.clone();
    }
    state().book_cache.insert(key, (book.clone(), toc.clone()));
    Ok(toc)
}
pub(super) fn run(params: &Value) -> Result<Value, String> {
    let mut items: Vec<Value> = param(params, "results")?;
    order(&mut items, params["key"].as_str().unwrap_or(""));
    let jobs = Mutex::new(
        items
            .into_iter()
            .take(10)
            .flat_map(|item| {
                let mut sources = item["sources"].as_array().cloned().unwrap_or_default();
                sources.sort_by_key(|s| s["ms"].as_u64().unwrap_or(u64::MAX));
                sources.truncate(3);
                sources
            })
            .collect::<std::collections::VecDeque<_>>(),
    );
    let done = Mutex::new(Vec::new());
    std::thread::scope(|scope| {
        for _ in 0..4 {
            let (jobs, done) = (&jobs, &done);
            scope.spawn(move||{
                loop {
                    let item=jobs.lock().unwrap().pop_front();
                    let Some(item)=item else{break;};
                    let Some(id)=item["sourceId"].as_str() else{continue;};
                    let Ok(mut book)=serde_json::from_value::<Book>(item["book"].clone()) else{continue;};
                    let mut ctx=crate::control::Context::new(crate::control::Profile::Detail,Arc::new(AtomicBool::new(false)));
                    ctx.interactive=false;ctx.deadline=Some(std::time::Instant::now()+Duration::from_secs(30));let _guard=ctx.enter();
                    match toc(id,&mut book,params["refresh"]==true) {
                        Ok(_)=>{
                            let event=json!({"event":"search.enrich","searchId":params["searchId"],"sourceId":id,"book":book,
                                "chapterCount":book.chapter_count,"latest":book.last_chapter,"exact":true});
                            send(event.clone());done.lock().unwrap().push(event);
                        },
                        Err(_)=>send(json!({"event":"search.enrich","searchId":params["searchId"],"sourceId":id,"book":book,"error":"目录暂时无法读取"})),
                    }
                }
            });
        }
    });
    Ok(json!({"items":done.into_inner().unwrap()}))
}
