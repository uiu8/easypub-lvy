use easypub_app::{navigation_documents, publication_navigation};
use easypub_core::{
    publication,
    source::{RULE_ID, SourceSnapshot},
    structure::Structure,
};
use std::{fs, io::Write, path::PathBuf};
fn main() -> Result<(), Box<dyn std::error::Error>> {
    let output = PathBuf::from(std::env::args().nth(1).ok_or("output required")?);
    fs::create_dir(&output)?;
    let text = "卷前说明 <script> & \"引用\"\r\n第一卷 起点\r\n第一章 重名\n正文甲😀\n第二章 重名\n正文乙\n第二卷 归来\n第一章 重名\n正文丙";
    let source = SourceSnapshot::from_utf8(text.as_bytes().to_vec(), RULE_ID, || false)
        .map_err(|e| format!("{e:?}"))?;
    let book = publication::compose(&source, &Structure::new(&source), None)
        .map_err(|e| format!("{e:?}"))?;
    for machine in [false, true] {
        for visible in [false, true] {
            for top in [false, true] {
                let dir = output.join(format!(
                    "{}{}{}",
                    u8::from(machine),
                    u8::from(visible),
                    u8::from(top)
                ));
                fs::create_dir(&dir)?;
                let nav = publication_navigation::prepare(&book.tree, machine, visible, top);
                for (name, content) in
                    navigation_documents::prepare(&book, &nav).map_err(|e| format!("{e:?}"))?
                {
                    fs::OpenOptions::new()
                        .write(true)
                        .create_new(true)
                        .open(dir.join(name))?
                        .write_all(content.as_bytes())?;
                }
            }
        }
    }
    fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(output.join("source.txt"))?
        .write_all(text.as_bytes())?;
    Ok(())
}
