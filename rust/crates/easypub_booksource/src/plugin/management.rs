use super::*;
pub(super) fn source(method: &str, params: &Value) -> Result<Value, String> {
    let mut st = state();
    let ids: Vec<String> = params["ids"]
        .as_array()
        .map(|a| {
            a.iter()
                .filter_map(|v| v.as_str().map(str::to_owned))
                .collect()
        })
        .unwrap_or_else(|| vec![params["id"].as_str().unwrap_or("").into()]);
    if method == "sources.order" {
        let mut selected = std::collections::HashSet::new();
        for (order, id) in ids.iter().enumerate() {
            if !selected.insert(id) {
                return Err("排序列表不能包含重复书源".into());
            }
            if let Some((s, _)) = st.sources.iter_mut().find(|(s, _)| s.id() == id) {
                s.custom_order = order as i64;
            }
        }
        let mut order = ids.len() as i64;
        for (s, _) in &mut st.sources {
            if !selected.contains(&s.id().to_owned()) {
                s.custom_order = order;
                order += 1;
            }
        }
        save(&st)?;
        return Ok(Value::Null);
    }
    let top = st
        .sources
        .iter()
        .map(|(s, _)| s.custom_order)
        .min()
        .unwrap_or(0);
    let bottom = st
        .sources
        .iter()
        .map(|(s, _)| s.custom_order)
        .max()
        .unwrap_or(0);
    let mut offset = 0;
    for (s, enabled) in &mut st.sources {
        if !ids.iter().any(|id| id == s.id()) {
            continue;
        }
        match method {
            "sources.pin" => {
                offset += 1;
                if params["position"] == "bottom" {
                    s.meta.pinned = false;
                    s.custom_order = bottom.saturating_add(offset);
                } else if params["pinned"] == false {
                    s.meta.pinned = false;
                } else {
                    s.meta.pinned = true;
                    s.custom_order = top.saturating_sub(offset);
                }
            }
            "sources.rate" => {
                s.meta.rating = params["rating"].as_i64().unwrap_or(0).clamp(-2, 2);
                s.weight = s.meta.rating;
            }
            "sources.tags" => return Ok(json!({"tags":s.tags(),"recommended":s.recommended()})),
            "sources.crawlProfile.get" => {
                return Ok(
                    json!({"profile":s.meta.crawl,"suggestion":s.meta.crawl_suggestion,
                "learned":crate::hosts::host(s.base_url(),32).diagnostic().learned}),
                );
            }
            "sources.crawlProfile.set" => {
                let mut p: source::CrawlProfile = param(params, "profile")?;
                p.concurrency = p.concurrency.map(|n| n.clamp(1, 32));
                p.retries = p.retries.map(|n| n.min(3));
                p.max_interval = p.max_interval.max(p.min_interval);
                p.timeout_ms = p.timeout_ms.map(|n| n.clamp(1000, 180000));
                if !["", "direct", "proxy"].contains(&p.proxy_mode.as_str()) {
                    return Err("书源代理选项无效".into());
                }
                s.meta.crawl = p;
                s.meta.health.retry_after = 0;
                if let Some(v) = params["enabled"].as_bool() {
                    *enabled = v;
                }
                if let Some(v) = params["group"].as_str() {
                    s.book_source_group = v.into();
                }
                if let Some(v) = params["concurrentRate"].as_str() {
                    s.concurrent_rate = v.into();
                }
                if let Some(v) = params["userAgent"].as_str() {
                    let mut headers: Value = serde_json::from_str(&s.header).unwrap_or(json!({}));
                    if !headers.is_object() {
                        headers = json!({});
                    }
                    headers["User-Agent"] = json!(v);
                    s.header = headers.to_string();
                }
            }
            _ => return Err("不支持的书源设置请求".into()),
        }
    }
    for id in ids {
        st.runtimes.remove(&id);
    }
    save(&st)?;
    Ok(Value::Null)
}
pub(super) fn handle(method: &str, params: &Value) -> Result<Value, String> {
    match method {
        "download.diagnose" => {
            let mut result = json!({"hosts":crate::hosts::diagnostics()});
            if params.get("toc").is_some() {
                let toc: Vec<Chapter> = param(params, "toc")?;
                let other: Vec<Chapter> = param(params, "otherToc")?;
                let mapping = crate::scheduler::alignment(&toc, &other);
                let primary_site = crate::scheduler::content_site(&Book::default(), &toc);
                let other_site = crate::scheduler::content_site(&Book::default(), &other);
                result["alignment"] = json!({
                    "equivalent": mapping.is_some(),
                    "independentSites": primary_site.is_some() && other_site.is_some() && primary_site != other_site,
                    "matched": mapping.as_ref().map_or(0, |m| m.iter().flatten().count()),
                    "primaryCount": toc.iter().filter(|c| !c.is_volume).count(),
                    "otherCount": other.iter().filter(|c| !c.is_volume).count()
                });
            }
            Ok(result)
        }
        "network.proxy.get" => Ok(crate::network_config::get()),
        "network.proxy.refresh" => {
            crate::network_config::refresh();
            sources::retry_after_network_change()?;
            Ok(crate::network_config::get())
        }
        "network.proxy.set" => {
            crate::network_config::set(param(params, "config")?)?;
            let value = crate::network_config::get();
            let path = state().data.join("network.json");
            download::write_atomic(&path, &serde_json::to_vec(&value).unwrap())?;
            sources::retry_after_network_change()?;
            Ok(value)
        }
        "network.proxy.test" => crate::network_config::diagnose(params),
        "filters.list" | "filters.save" => {
            let st = state(); // 与写入一起串行，避免丢失同时保存的筛选。
            let path = st.data.join("filters.json");
            let mut filters: Vec<Value> = std::fs::read(&path)
                .ok()
                .and_then(|b| serde_json::from_slice(&b).ok())
                .unwrap_or_default();
            if method == "filters.save" {
                let name = param::<String>(params, "name")?;
                if name.trim().is_empty() {
                    return Err("筛选组合需要名称".into());
                }
                filters.retain(|f| f["name"] != name);
                if params["delete"] != true {
                    filters.push(json!({"name":name,"filter":params["filter"]}));
                }
                download::write_atomic(&path, &serde_json::to_vec(&filters).unwrap())?;
            }
            Ok(json!(filters))
        }
        "library.provenance" => {
            let key = param::<String>(params, "key")?;
            let record = load_library()
                .into_iter()
                .find(|r| r["key"] == key)
                .ok_or("没有下载记录")?;
            let book: Book = param(&record, "book")?;
            let options: Options = param(&record, "options")?;
            let cache = download::cache_dir(&options.folder, &book);
            if crate::catalogue::pending(&cache) {
                return Err("目录缓存正在迁移，请先继续下载".into());
            }
            let toc: Vec<Chapter> = std::fs::read(cache.join("toc.json"))
                .ok()
                .and_then(|b| serde_json::from_slice(&b).ok())
                .or_else(|| serde_json::from_value(record["toc"].clone()).ok())
                .unwrap_or_default();
            let mut records = Vec::new();
            for (i, chapter) in toc.iter().enumerate() {
                if let Ok(b) = std::fs::read(cache.join(format!("{i:05}.meta.json")))
                    && let Ok(mut v) = serde_json::from_slice::<Value>(&b)
                {
                    v["index"] = json!(i + 1);
                    v["title"] = json!(chapter.title);
                    records.push(v);
                }
            }
            Ok(json!(records))
        }
        _ => Err("不支持的管理请求".into()),
    }
}
pub(super) fn load() {
    let dir = state().data.clone();
    crate::hosts::load(&dir);
    sources::load_import_options(&dir);
    if let Ok(b) = std::fs::read(dir.join("network.json"))
        && let Ok(v) = serde_json::from_slice::<Value>(&b)
        && let Ok(mut c) = serde_json::from_value::<crate::network_config::ProxyConfig>(v.clone())
    {
        // V89 旧配置原来只对勾选书源生效，升级不能悄悄扩大范围。
        if v.get("scope").is_none() {
            c.scope = "marked".into();
        }
        let _ = crate::network_config::set(c);
    }
}
