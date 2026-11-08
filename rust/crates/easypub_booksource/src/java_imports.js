// 仅导入 Rust 提供的兼容类，不加载 JVM 或动态查找任意 Java 类型。
function (classes) {
  const g = globalThis;
  const entries = classes.map(path => {
    const parts = path.split('.'), name = parts.pop();
    const parent = parts.reduce((value, key) => value[key], g);
    return { name, parent, value: parent[name] };
  });
  function resolve(args, packages) {
    const found = [];
    for (const value of args) {
      const matches = entries.filter(entry => entry.value === value || (packages && entry.parent === value));
      if (!matches.length) throw Error('不支持的 Java 类或包导入');
      found.push(...matches);
    }
    return found;
  }
  function install(target, entries, skipExisting) {
    for (const entry of entries) {
      if (Object.prototype.hasOwnProperty.call(target, entry.name)) {
        if (skipExisting || target[entry.name] === entry.value) continue;
        throw Error('Java 导入名称冲突');
      }
      Object.defineProperty(target, entry.name, { value: entry.value, writable: true, configurable: true, enumerable: true });
    }
    return target;
  }
  g.importClass = function (...classes) { install(g, resolve(classes, false), false); };
  // 包导入不覆盖 JS 内置 String 等已有全局名。
  g.importPackage = function (...packages) { install(g, resolve(packages, true), true); };
  g.JavaImporter = function (...imports) {
    const target = install(Object.create(null), resolve(imports, true), false);
    Object.defineProperties(target, {
      importClass: { value: function (...classes) { install(target, resolve(classes, false), false); }, configurable: true, writable: true },
      importPackage: { value: function (...packages) { install(target, resolve(packages, true), false); }, configurable: true, writable: true }
    });
    return target;
  };
}
