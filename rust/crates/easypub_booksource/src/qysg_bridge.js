// EasyPub 独立实现的轻悦时光消息接口。宿主只开放网络、内存缓存和网页读取。
(() => {
  let serial = 0;
  const queue = [], pending = new Map();
  window.flutter_inappwebview = {
    callHandler(name, ...args) {
      return new Promise((resolve, reject) => {
        if (pending.size >= 128) { reject(new Error("bridge queue full")); return; }
        const id = ++serial;
        pending.set(id, {resolve, reject});
        queue.push({id, name, args});
      });
    }
  };
  window.__epDrain = () => queue.splice(0, 32);
  window.__epReply = (id, value, error) => {
    const p = pending.get(id); pending.delete(id);
    if (p) error ? p.reject(new Error(error)) : p.resolve(value);
  };
  window.__epRun = (method, args) => {
    if (window.__epStarted) return;
    window.__epStarted = true;
    Promise.resolve().then(() => {
      const f = window[method];
      if (typeof f !== "function") throw new Error("entry");
      return f(...args);
    }).then(value => {
      window.__epResult = JSON.stringify({ok:true, value});
    }).catch(() => {
      window.__epResult = JSON.stringify({ok:false});
    });
  };
})();
