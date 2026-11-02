'use strict';
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const root = path.resolve(__dirname, '..');
const file = fs.existsSync(path.join(root, 'ParcelKeeper/Services/JDWebScripts.swift')) ? 'JDWebScripts.swift' : 'MallWebClient.swift';
const swift = fs.readFileSync(path.join(root, 'ParcelKeeper/Services', file), 'utf8');
const script = swift.match(/(?:static let observer|private static let observerScript) = #"""\n([\s\S]*?)\n\s*"""#/)[1];
function environment() {
  class Node {
    appendChild(child) { this.children.push(child); return child; }
    insertBefore(child) { this.children.push(child); return child; }
    replaceChild(child, old) { this.children[this.children.indexOf(old)] = child; return old; }
    constructor() { this.children = []; }
  }
  class Element extends Node {
    setAttribute(name, value) { this[name] = value; }
    querySelectorAll() { return this.children; }
  }
  class HTMLScriptElement extends Element { get src() { return this._src || ''; } set src(v) { this._src = String(v); } }
  class XMLHttpRequest { addEventListener(_, fn) { this.listener = fn; } send(...args) { this.sent = args; return 7; } }
  const messages = [];
  const c = {URL, TextEncoder, Node, Element, HTMLScriptElement, XMLHttpRequest, location: {href:'https://trade.m.jd.com/order/orderlist_jdm.shtml'}, document: new Element(), MutationObserver: class { observe() {} }, webkit: {messageHandlers:{mallResponse:{postMessage(m) { messages.push(m); }}}}};
  c.window = c; c.top = c;
  c.fetch = function() { return Promise.resolve({url:'https://mobile.yangkeduo.com/proxy/api/aristotle/order_list_v4', clone() { return {text:async () => '{"orders":[]}'}; }}); };
  vm.createContext(c); vm.runInContext(script, c);
  return {c, messages};
}
const url = (callback, fn = 'order_list_m', host = 'api.m.jd.com') => `https://${host}/api?functionId=${fn}&callback=${encodeURIComponent(callback)}`;
function run(name, test) { tests.push([name,test]); }
const tests = [];
run('diagnostic readiness and request observation preserve callbacks', () => {
  const {c,messages}=environment(); assert.equal(c.__mallObserverReady,true);
  c.cb=v=>v; const s=new c.HTMLScriptElement(); s.src=url('cb'); c.document.appendChild(s);
  assert.ok(c.__mallRequestsObserved>0); c.cb({body:{orderList:[]}}); assert.equal(messages.length,1);
});
run('existing callback keeps this, args, result; URL unchanged', () => {
  const {c,messages} = environment(); let seen;
  c.jd = {done: function(...args) { seen = [this,args]; return 42; }};
  const s = new c.HTMLScriptElement(); s.src = url('jd.done'); c.document.appendChild(s);
  const body = {body:{orderList:[]}}; assert.equal(c.jd.done(body,'extra'),42);
  assert.equal(seen[0],c.jd); assert.equal(seen[1][0],body); assert.equal(seen[1][1],'extra');
  assert.equal(s.src,url('jd.done')); assert.equal(messages.length,1); assert.deepEqual(JSON.parse(messages[0].body),body);
});
run('deleted callback slot can be reinstalled for same name', () => {
  const {c,messages}=environment();
  for(let i=0;i<3;i++) {
    c.cb=v=>v; const s=new c.HTMLScriptElement(); s.src=url('cb')+'&page='+i;
    c.document.appendChild(s); c.cb({i}); delete c.cb;
  }
  assert.equal(messages.length,3);
});
run('saved callback retains request identity after callback name reuse', () => {
  const {c,messages}=environment(); c.cb=v=>v;
  const a=new c.HTMLScriptElement(); a.src=url('cb')+'&page=1'; const old=c.cb;
  const b=new c.HTMLScriptElement(); b.src=url('cb')+'&page=2'; old({ok:1});
  assert.equal(new URL(messages[0].url).searchParams.get('page'),'1');
});
run('late callback assignment after src and insertion', () => {
  const {c,messages} = environment(); const s = new c.HTMLScriptElement(); s.setAttribute('src',url('late')); c.document.insertBefore(s,null);
  c.late = function(v) { return v; }; const data = {ok:true}; assert.equal(c.late(data),data); assert.equal(messages.length,1);
});
run('late dotted namespace assignment', () => {
  const {c,messages} = environment(); const s = new c.HTMLScriptElement(); s.src = url('later.done'); c.document.appendChild(s);
  c.later = {}; c.later.done = v => v; c.later.done({ok:true}); assert.equal(messages.length,1);
});
run('callback exception still propagates even if bridge fails', () => {
  const {c} = environment(); c.cb = () => { throw new Error('site error'); }; const s = new c.HTMLScriptElement(); s.src = url('cb');
  c.webkit.messageHandlers.mallResponse.postMessage = () => { throw new Error('bridge'); };
  assert.throws(() => c.cb({ok:1}), /site error/);
});
run('host, function, duplicate query, dangerous callback rejected', () => {
  for (const raw of [url('cb','other'),url('cb','order_list_m','api.m.jd.com.evil.test'),url('cb')+'&functionId=other',url('cb')+'&callback=other',url('x[0]'),url('__proto__.cb'),url('constructor.cb'),url('cb()'),url('cb').replace('https:','http:')]) {
    const {c,messages} = environment(); const original = () => 1; c.cb = original;
    const s = new c.HTMLScriptElement(); s.src = raw; c.document.appendChild(s); c.cb({ok:1}); assert.equal(c.cb,original); assert.equal(messages.length,0);
  }
});
run('order page captures twenty responses while detail stays at four', () => {
  for (const [pathname,limit] of [['/order/orderlist_jdm.shtml',20],['/order/deal_wuliu_jdm.shtml',4]]) {
    const {c,messages}=environment(); c.location.pathname=pathname;
    c.cb=v=>v; const s=new c.HTMLScriptElement(); s.src=url('cb'); c.document.appendChild(s);
    for(let i=0;i<25;i++) c.cb({body:{orderList:[{orderId:String(i)}]}});
    assert.equal(messages.length,limit);
  }
});
run('both allowed JD functions; bound of four; cyclic payload safe', () => {
  const {c,messages} = environment(); c.cb = v => 9; const s = new c.HTMLScriptElement(); s.src = url('cb','get_logistics_list_by_order_m');
  const cyclic = {}; cyclic.self = cyclic; assert.equal(c.cb(cyclic),9);
  for(let i=0;i<8;i++) c.cb({i}); assert.equal(messages.length,4);
});
run('insertion discovers script whose native src setter was used', () => {
  const {c,messages} = environment(); c.cb = v => v;
  const s = new c.HTMLScriptElement(); s._src = url('cb'); c.document.appendChild(s);
  c.cb({ok:1}); assert.equal(messages.length,1);
});
run('oversized UTF-8 payload ignored and replacement callback retained', () => {
  const {c,messages} = environment(); c.cb = () => 1;
  const s = new c.HTMLScriptElement(); s.src = url('cb'); c.document.appendChild(s);
  assert.equal(c.cb({text:'界'.repeat(700000)}),1); assert.equal(messages.length,0);
  c.cb = function(...args) { assert.equal(this,c); return args[1]; };
  assert.equal(c.cb({ok:1},23),23); assert.equal(messages.length,1);
});
run('site accessor callback is not overwritten', () => {
  const {c,messages} = environment(); const callback = () => 5;
  Object.defineProperty(c,'cb',{get() { return callback; },configurable:true});
  const s = new c.HTMLScriptElement(); s.src = url('cb'); c.document.appendChild(s);
  assert.equal(c.cb,callback); assert.equal(c.cb({ok:1}),5); assert.equal(messages.length,0);
});
run('XHR and PDD fetch remain functional', async () => {
  const {c,messages} = environment(); const xhr = new c.XMLHttpRequest(); xhr.responseURL = url('unused'); xhr.responseText = '{"body":{}}';
  assert.equal(xhr.send('body'),7); xhr.listener(); await c.fetch('/ignored'); await new Promise(resolve => setImmediate(resolve));
  assert.equal(messages.length,2);
});
(async () => { let failed=0; for(const [name,test] of tests) { try { await test(); console.log('PASS '+name); } catch(e) { failed++; console.error('FAIL '+name+'\n'+e.stack); } } console.log(`${tests.length-failed}/${tests.length} passed`); process.exitCode = failed ? 1 : 0; })();
