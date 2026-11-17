//! JS 元素共享文档树。树由原生函数闭包持有，最后一个 JS 引用释放后一起回收。
use std::{cell::RefCell, collections::HashMap};

use rquickjs::{Ctx, Function};
use scraper::ElementRef;
use serde_json::{Value, json};

#[cfg(test)]
thread_local! {
    static LIVE_DOCUMENTS: std::cell::Cell<usize> = const { std::cell::Cell::new(0) };
}

#[cfg(test)]
struct DocumentLifetime;

#[cfg(test)]
impl Drop for DocumentLifetime {
    fn drop(&mut self) {
        LIVE_DOCUMENTS.with(|count| count.set(count.get() - 1));
    }
}

#[cfg(test)]
pub(crate) fn live_documents() -> usize {
    LIVE_DOCUMENTS.with(std::cell::Cell::get)
}

pub fn install(ctx: &Ctx<'_>) -> rquickjs::Result<()> {
    ctx.globals()
        .set("__epJsoup", Function::new(ctx.clone(), create)?)
}

fn create<'js>(ctx: Ctx<'js>, html: String) -> rquickjs::Result<Function<'js>> {
    let (doc, root) = crate::engine::jsoup_root(&html);
    let ids: Vec<_> = doc.tree.root().descendants().map(|n| n.id()).collect();
    let indexes: HashMap<_, _> = ids.iter().enumerate().map(|(i, id)| (*id, i)).collect();
    let root_index = indexes[&root];
    let doc = RefCell::new(doc);
    #[cfg(test)]
    let lifetime = {
        LIVE_DOCUMENTS.with(|count| count.set(count.get() + 1));
        DocumentLifetime
    };
    Function::new(ctx, move |request: String| -> String {
        #[cfg(test)]
        let _keep_alive = &lifetime;
        let result = crate::pattern::checked(|| -> Result<Value, String> {
            crate::control::current().check()?;
            let args: Vec<Value> = serde_json::from_str(&request).map_err(|_| "无效的元素操作")?;
            let op = args.first().and_then(Value::as_str).unwrap_or("");
            if op == "root" {
                return Ok(json!(root_index));
            }
            let index = args.get(1).and_then(Value::as_u64).ok_or("缺少元素编号")? as usize;
            let id = *ids.get(index).ok_or("无效元素编号")?;
            if op == "remove" {
                doc.borrow_mut()
                    .tree
                    .get_mut(id)
                    .ok_or("元素不存在")?
                    .detach();
                return Ok(Value::Null);
            }
            let doc = doc.borrow();
            let node = doc.tree.get(id).ok_or("元素不存在")?;
            let element = ElementRef::wrap(node);
            let arg = args.get(2).and_then(Value::as_str).unwrap_or("");
            match op {
                "select" | "children" => {
                    let found = if op == "children" {
                        node.children()
                            .filter_map(ElementRef::wrap)
                            .map(|e| e.id())
                            .collect()
                    } else {
                        crate::jcss::select_css(&doc, id, arg)?
                    };
                    Ok(json!(
                        found.iter().map(|id| indexes[id]).collect::<Vec<_>>()
                    ))
                }
                "value" => Ok(Value::String(match arg {
                    "outer" => element.map(|e| e.html()).unwrap_or_default(),
                    "inner" => element.map(|e| e.inner_html()).unwrap_or_default(),
                    "text" => crate::dom::text(node),
                    "ownText" => crate::dom::own_text(node),
                    "tag" => element
                        .map(|e| e.value().name().to_owned())
                        .unwrap_or_default(),
                    k if k.starts_with("attr:") => element
                        .and_then(|e| e.attr(&k[5..]))
                        .unwrap_or("")
                        .to_owned(),
                    k if k.starts_with("has:") => element
                        .is_some_and(|e| e.attr(&k[4..]).is_some())
                        .to_string(),
                    _ => return Err("不支持的元素取值".into()),
                })),
                _ => Err("不支持的元素操作".into()),
            }
        })
        .and_then(|result| result);
        match result {
            Ok(value) => json!({"v": value}).to_string(),
            Err(error) => json!({"__error": error}).to_string(),
        }
    })
}
