//! 搜索逐源推送；线程自身受预算约束，不遗留超时的后台请求。
use super::*;
use crate::control::{Context, ErrorKind, Profile};
use std::{
    collections::{HashSet, VecDeque},
    time::Instant,
};

#[derive(Clone, Default, serde::Serialize)]
#[serde(rename_all = "camelCase")]
struct Page {
    source_id: String,
    source_name: String,
    page: usize,
    next_page: usize,
    ended: bool,
    failed: bool,
    error: String,
    cause: Option<String>,
    #[serde(skip)]
    fingerprints: HashSet<String>,
}
#[derive(Default)]
pub(super) struct Session {
    params: Value,
    pages: HashMap<String, Page>,
    rows: Vec<Value>,
}
pub(super) fn resume(params: &Value, retry: bool) -> Result<Value, String> {
    let id = param::<String>(params, "searchId")?;
    let session = state()
        .search_sessions
        .get(&id)
        .cloned()
        .ok_or("搜索已过期，请重新搜索")?;
    let mut request = session.lock().unwrap().params.clone();
    request["searchId"] = json!(id);
    request["resume"] = json!(if retry { "retry" } else { "more" });
    if let Some(source) = params["sourceId"].as_str() {
        request["retrySource"] = json!(source);
    }
    search(&request)
}
pub(super) fn cancel(params: &Value) -> Result<Value, String> {
    let id = params["searchId"].as_str();
    let st = state();
    for (key, cancel) in &st.searches {
        if id.is_none_or(|id| id == key) {
            cancel.store(true, Ordering::Relaxed);
        }
    }
    crate::hosts::wake();
    Ok(Value::Null)
}

pub(super) fn search(params: &Value) -> Result<Value, String> {
    let (merged, summary) = collect(params, true)?;
    let mut result = summary;
    // V87 客户端仍可取整批结果；V88 用 stream:true，只返回汇总。
    if params["stream"] != true {
        result["results"] = json!(merged);
    }
    Ok(result)
}

fn collect(params: &Value, emit: bool) -> Result<(Vec<Value>, Value), String> {
    let key = param::<String>(params, "key")?;
    let key = key.trim();
    if key.is_empty() {
        return Err("请输入书名或作者".into());
    }
    let start = Instant::now();
    let search_id = params["searchId"]
        .as_str()
        .map(str::to_owned)
        .unwrap_or_else(|| {
            format!(
                "s{}",
                std::time::SystemTime::now()
                    .duration_since(std::time::UNIX_EPOCH)
                    .unwrap_or_default()
                    .as_nanos()
            )
        });
    let continuation = params["resume"].as_str();
    let cancel = Arc::new(AtomicBool::new(false));
    let session = {
        let mut st = state();
        if st.searches.contains_key(&search_id) {
            return Err("这次搜索仍在进行".into());
        }
        let session = if continuation.is_some() {
            st.search_sessions
                .get(&search_id)
                .cloned()
                .ok_or("搜索已过期，请重新搜索")?
        } else {
            if emit {
                for c in st.searches.values() {
                    c.store(true, Ordering::Relaxed);
                }
                st.search_sessions.clear();
            }
            let session = Arc::new(Mutex::new(Session {
                params: params.clone(),
                ..Default::default()
            }));
            if emit {
                st.search_sessions
                    .insert(search_id.clone(), session.clone());
            }
            session
        };
        st.searches.insert(search_id.clone(), cancel.clone());
        session
    };
    let wanted = params["sourceIds"].as_array();
    let files = params["files"].as_array();
    let groups = params["groups"].as_array();
    let mut skipped = 0usize;
    let mut webview_skipped = 0usize;
    let mut duplicate_skipped = 0usize;
    let mut list = Vec::new();
    let mut seen = HashSet::new();
    {
        let st = state();
        for (s, enabled) in &st.sources {
            if !wanted.map_or(*enabled, |ids| ids.iter().any(|id| id == s.id()))
                || !support::check(s).is_empty()
            {
                continue;
            }
            let file = if s.meta.file.is_empty() {
                "旧版导入"
            } else {
                &s.meta.file
            };
            if files.is_some_and(|f| !f.iter().any(|v| v == file))
                || groups
                    .is_some_and(|g| !s.groups().iter().any(|name| g.iter().any(|v| v == name)))
            {
                continue;
            }
            if params["onlyPriority"] == true && !s.priority() {
                continue;
            }
            let web = support::needs_web_view(s);
            if web && params["includeWebView"] != true {
                webview_skipped += 1;
                continue;
            }
            if continuation.is_none()
                && wanted.is_none()
                && params["skipUnhealthy"] != false
                && s.meta.health.cooling_down(now_secs())
            {
                skipped += 1;
                continue;
            }
            if let Some(mode) = continuation {
                let data = session.lock().unwrap();
                let Some(page) = data.pages.get(s.id()) else {
                    continue;
                };
                let selected = params["retrySource"].as_str().is_none_or(|id| id == s.id());
                if !selected
                    || if mode == "retry" {
                        !page.failed
                    } else {
                        page.ended || page.failed
                    }
                {
                    continue;
                }
            }
            if !seen.insert(s.book_source_url.clone()) {
                duplicate_skipped += 1;
                continue;
            }
            list.push((
                s.id().to_owned(),
                s.book_source_name.trim().to_owned(),
                web,
                s.meta.health.fail_streak,
                s.meta.health.speed(),
                !s.priority(),
                s.custom_order,
                -s.score(),
                s.meta.pinned,
                s.meta.rating,
            ));
        }
    }
    list.sort_by_key(|s| (s.2, s.5, s.6, s.3, s.7, s.4));
    if continuation.is_none() && params["quick"] == true {
        list.truncate(params["limit"].as_u64().unwrap_or(60).clamp(1, 500) as usize);
    }
    {
        let mut data = session.lock().unwrap();
        for item in &list {
            data.pages.entry(item.0.clone()).or_insert_with(|| Page {
                source_id: item.0.clone(),
                source_name: item.1.clone(),
                next_page: 1,
                ..Default::default()
            });
        }
    }
    let total = list.len();
    let concurrency = params["concurrency"].as_u64().unwrap_or(24).clamp(1, 64) as usize;
    let filter = params["filterTitle"] != false;
    let filter_key = key.to_lowercase();
    let existing = session.lock().unwrap().rows.clone();
    let index: HashMap<(String, String), usize> = existing
        .iter()
        .enumerate()
        .map(|(i, r)| {
            (
                (
                    r["name"].as_str().unwrap_or("").into(),
                    r["author"].as_str().unwrap_or("").into(),
                ),
                i,
            )
        })
        .collect();
    let merged = Mutex::new((existing, index));
    let done = std::sync::atomic::AtomicUsize::new(0);
    let failed = std::sync::atomic::AtomicUsize::new(0);
    let empty = std::sync::atomic::AtomicUsize::new(0);
    // WebView 确实是单实例：普通源先跑，WebView 后跑并且只开一个工作线程。
    for web in [false, true] {
        let queue = Mutex::new(
            list.iter()
                .filter(|s| s.2 == web)
                .cloned()
                .collect::<VecDeque<_>>(),
        );
        let count = queue.lock().unwrap().len();
        std::thread::scope(|scope| {
            for _ in 0..if web {
                1.min(count)
            } else {
                concurrency.min(count)
            } {
                let (queue, merged, done, failed, empty, cancel, search_id, filter_key, session) = (
                    &queue,
                    &merged,
                    &done,
                    &failed,
                    &empty,
                    cancel.clone(),
                    &search_id,
                    &filter_key,
                    &session,
                );
                scope.spawn(move ||{
                    while !cancel.load(Ordering::Relaxed){
                        let Some((id,name,_,_,_,_,order,inverse_score,pinned,rating))=queue.lock().unwrap().pop_front() else{break;};
                        let at=Instant::now();let mut context=Context::new(Profile::Search,cancel.clone());
                        context.deadline=Some(at+Duration::from_secs(10));context.interactive=false;
                        let _guard=context.enter();
                        let page=session.lock().unwrap().pages.get(&id).map_or(1,|p|p.next_page.max(1));
                        let result=with_engine(&id,|e|e.run(|s|s.search(key,page as i64)));
                        if cancel.load(Ordering::Relaxed){break;}
                        let ms=at.elapsed().as_millis() as u64;
                        let status={
                            let mut data=session.lock().unwrap();
                            let p=data.pages.entry(id.clone()).or_insert_with(||Page{source_id:id.clone(),source_name:name.clone(),next_page:1,..Default::default()});
                            match &result {
                                Ok(books)=>{
                                    let mut identities:Vec<_>=books.iter().map(|b|(&b.book_url,&b.name,&b.author)).collect();
                                    identities.sort();
                                    let fingerprint=serde_json::to_string(&identities).unwrap();
                                    p.ended=books.is_empty()||!p.fingerprints.insert(fingerprint);
                                    p.page=page;p.next_page=page+1;p.failed=false;p.error.clear();p.cause=None;
                                }
                                Err(e)=>{p.failed=true;p.next_page=page;p.error=crate::probe::reason(e).into();p.cause=ErrorKind::classify(e).cause().map(str::to_owned);}
                            }
                            p.clone()
                        };
                        match &result {
                            Err(e) => {
                                sources::record_health(&id,ms,false,ErrorKind::classify(e).label(),None);
                                failed.fetch_add(1,Ordering::Relaxed);
                            }
                            Ok(books) if books.is_empty() => {
                                // 空关键词命中不代表规则坏了，也不证明正文可读；只记耗时。
                                empty.fetch_add(1,Ordering::Relaxed);
                                if let Some((s,_))=state().sources.iter_mut().find(|(s,_)|s.id()==id) {
                                    s.meta.health.latency(ms);
                                }
                            }
                            Ok(_) => {sources::record_health(&id,ms,true,"",None);}
                        }
                        let mut books:Vec<_>=result.unwrap_or_default().into_iter().filter(|b|!filter || b.name.to_lowercase().contains(filter_key)).collect();
                        for book in &mut books {book.chapter_count=enrich::estimate(&book.last_chapter);}
                        {
                            let mut merged=merged.lock().unwrap();
                            let (rows,index)=&mut *merged;
                            for book in &books {
                                let source=json!({"sourceId":id,"sourceName":name,"book":book,"ms":ms,"pinned":pinned,"rating":rating,"score":-inverse_score,"customOrder":order});
                                let key=(book.name.clone(),book.author.clone());
                                if let Some(&i)=index.get(&key) {
                                    let sources=rows[i]["sources"].as_array_mut().unwrap();
                                    if !sources.iter().any(|s|s["sourceId"]==id) {sources.push(source);}
                                } else {
                                    index.insert(key,rows.len());
                                    rows.push(json!({"name":book.name,"author":book.author,"sources":[source]}));
                                }
                            }
                        }
                        if emit {
                            send(json!({"event":"search.result","searchId":search_id,"sourceId":id,"sourceName":name,"items":books,"ms":ms,"pinned":pinned,"rating":rating,"score":-inverse_score,"customOrder":order,"pageState":status}));
                            send(json!({"event":"search.progress","searchId":search_id,"done":done.fetch_add(1,Ordering::Relaxed)+1,"total":total,
                                "found":merged.lock().unwrap().0.len(),"skipped":skipped,"webViewSkipped":webview_skipped}));
                        } else {done.fetch_add(1,Ordering::Relaxed);}
                    }
                });
            }
        });
    }
    {
        let mut st = state();
        st.searches.remove(&search_id);
        save(&st)?;
    }
    let (mut merged, _) = merged.into_inner().unwrap();
    enrich::order(&mut merged, key);
    let pages = {
        let mut data = session.lock().unwrap();
        data.rows = merged.clone();
        let mut pages: Vec<_> = data.pages.values().cloned().collect();
        pages.sort_by(|a, b| a.source_id.cmp(&b.source_id));
        pages
    };
    let summary = json!({"searchId":search_id,"searched":done.load(Ordering::Relaxed),"total":total,"failed":failed.load(Ordering::Relaxed),"empty":empty.load(Ordering::Relaxed),
        "found":merged.len(),"skipped":skipped,"webViewSkipped":webview_skipped,"duplicateSkipped":duplicate_skipped,"elapsedMs":start.elapsed().as_millis(),"cancelled":cancel.load(Ordering::Relaxed),"pages":pages});
    Ok((merged, summary))
}

pub(super) fn resolve(params: &Value) -> Result<Value, String> {
    let text = param::<String>(params, "text")?;
    let mut rows = Vec::new();
    for line in text
        .lines()
        .map(str::trim)
        .filter(|s| !s.is_empty())
        .take(200)
    {
        let (name, author) = line
            .rsplit_once(char::is_whitespace)
            .map(|(n, a)| (n.trim(), a.trim()))
            .unwrap_or((line, ""));
        let mut request = params.clone();
        request["key"] = json!(name);
        request["filterTitle"] = json!(true);
        let (mut candidates, _) = collect(&request, false)?;
        candidates.retain(|b| b["name"] == name && (author.is_empty() || b["author"] == author));
        rows.push(json!({"line":line,"name":name,"author":author,"status":match candidates.len(){0=>"missing",1=>"resolved",_=>"ambiguous"},"candidates":candidates}));
        send(json!({"event":"batch.progress","done":rows.len()}));
    }
    Ok(json!({"items":rows}))
}
