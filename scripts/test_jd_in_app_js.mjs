import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';
const swift = fs.readFileSync(new URL('../ParcelKeeper/Services/JDInAppClient.swift', import.meta.url), 'utf8');
const script = swift.match(/static let capture = #"""\n([\s\S]*?)\n"""#/)[1];
const messages = [], diagnostics = [];
const context = {URL, URLSearchParams, location: {href:'https://trade.m.jd.com/order/orderlist_jdm.shtml'}, document: {body:{innerText:''},querySelectorAll:()=>[]},webkit:{messageHandlers:{jdCapture:{postMessage:x=>{ (x.kind==='diagnostic' ? diagnostics : messages).push(x); }}}}};
context.window=context;
class XHR {open(method,url){this.url=url;} send(){} addEventListener(name,fn){if(name==='load') this.listener=fn; else this[name+'Listener']=fn;}}
context.XMLHttpRequest=XHR;
let response;
context.fetch=async()=>({url:'https://api.m.jd.com/api',status:200,clone:()=>({text:async()=>JSON.stringify(response)})});
vm.createContext(context); vm.runInContext(script,context);
async function capture(value,url='https://api.m.jd.com/api?functionId=order_list_m',init={}){response=value;await context.fetch(url,init);await new Promise(r=>setImmediate(r));}
await capture({body:{orderList:[{orderId:'123456789',orderStatusInfo:{orderStatusName:'待收货'},wareInfoList:[{wareName:'模拟商品'}],progressInfo:{progressLink:'https://trade.m.jd.com/order/deal_wuliu_jdm.shtml?dealId=123456789&pt_key=SECRET'},pt_key:'SECRET'}]}});
assert.equal(messages[0].orders[0].id,'123456789');assert.doesNotMatch(JSON.stringify(messages),/SECRET|pt_key/);
await capture({body:{orderList:[]}});assert.equal(messages[1].kind,'orders');assert.deepEqual(Array.from(messages[1].orders),[]);
await capture({unknown:[]});assert.equal(messages.length,2);
await capture({body:{carriageId:'JD12345678',carrier:'京东快递',tracePointVOList:[{createTime:'2026-11-01 10:00:00',wlStateDesc:'已到达'}]}},'https://api.m.jd.com/api?functionId=get_logistics_list_by_order_m&body='+encodeURIComponent(JSON.stringify({orderId:'123456789'})));
assert.equal(messages[2].orderID,'123456789');assert.equal(messages[2].parcels[0].number,'JD12345678');
await capture({body:{orderList:[]}},'https://evil.example/api');assert.equal(messages.length,3);
await capture({code:3});assert.equal(messages[3].error,'authentication');
const xhr=new context.XMLHttpRequest();xhr.open('POST','https://api.m.jd.com/api?functionId=order_list_m');xhr.send();xhr.responseURL=xhr.url;xhr.responseText=JSON.stringify({body:{orderList:[]}});xhr.listener();assert.equal(messages[4].kind,'orders');
const snapshot=vm.runInContext('window.__parcelJDSnapshot()',context);assert.equal(snapshot.recognized,false);
// Whole-page logistics DOM is unproven even with one order/waybill; reject it.
context.location.href='https://trade.m.jd.com/order/deal_wuliu_jdm.shtml?dealId=123456789';
context.document.body.innerText='订单号：123456789\n运单号：JD12345678\n物流公司：京东快递\n2026-11-01 10:00:00\n包裹已到达驿站';
let dom=vm.runInContext('window.__parcelJDSnapshot()',context);assert.equal(dom.recognized,false);
context.document.body.innerText+='\n运单号：SF12345678';dom=vm.runInContext('window.__parcelJDSnapshot()',context);assert.equal(dom.recognized,false);
context.document.body.innerText='订单号：987654321\n运单号：JD12345678\n2026-11-01 10:00:00\n包裹已签收';assert.equal(vm.runInContext('window.__parcelJDSnapshot()',context).recognized,false);
context.location.href='https://trade.m.jd.com/order/orderlist_jdm.shtml';context.document.body.innerText='暂无订单';assert.equal(vm.runInContext('window.__parcelJDSnapshot()',context).recognized,true);
context.document.body.innerText='请输入验证码';assert.equal(vm.runInContext('window.__parcelJDSnapshot()',context).error,'verification');
await capture({body:{orderId:'987654321',carriageId:'JD12345678',carrier:'京东快递',tracePointVOList:[]}},'https://api.m.jd.com/api?functionId=get_logistics_list_by_order_m&body='+encodeURIComponent(JSON.stringify({orderId:'123456789'})));assert.equal(messages.at(-1).error,'identity');
const before=messages.length;
await capture({success:false,data:{orderList:[]}});assert.equal(messages.length,before);
await capture({multiPackageTrackInfoList:[{carriageInfo:{carriageId:'JD12345678',carrier:'京东快递'},trackGroupInfo:{orderTrackShowList:[{CreationTime:'2026-11-01 10:00:00',Content:'运输中'}]}},{carriageInfo:{carriageId:'SF12345678',carrier:'顺丰'},trackGroupInfo:{orderTrackShowList:[{CreationTime:'2026-11-01 11:00:00',Content:'本人签收'}]}}]},'https://api.m.jd.com/api?functionId=pcdetail_traceMultiPackage&body='+encodeURIComponent(JSON.stringify({orderId:'123456789'})));
assert.equal(messages.at(-1).parcels.length,2);assert.notEqual(messages.at(-1).parcels[0].points[0].text,messages.at(-1).parcels[1].points[0].text);
assert.ok(diagnostics.some(x=>x.diagnostic==='networkResponse' && x.httpStatus===200));
assert.ok(diagnostics.some(x=>x.diagnostic==='schema'));
assert.ok(diagnostics.some(x=>x.diagnostic==='business'));
xhr.errorListener();assert.equal(diagnostics.at(-1).diagnostic,'network');
for (const x of diagnostics) {
  assert.ok(['schema','json','business','network','networkResponse'].includes(x.diagnostic));
  assert.ok(Object.keys(x).every(k=>['kind','diagnostic','httpStatus'].includes(k)));
}
assert.doesNotMatch(JSON.stringify(diagnostics),/SECRET|pt_key|trackingNo|https:|123456789/);
console.log('JD JS synthetic checks passed: fetch/XHR, empty/unknown schema, split/DOM identity, host and secret filtering, safe diagnostic codes');
