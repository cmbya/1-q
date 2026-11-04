// Fixtures reflect public JD list wire fields and detail URL, not an authenticated response.
import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';
import test from 'node:test';
const swift=fs.readFileSync(new URL('../ParcelKeeper/Services/JDInAppClient.swift',import.meta.url),'utf8');
const script=swift.match(/static let capture = #"""\n([\s\S]*?)\n"""#/)[1];
const order='123456789012', entry=`https://trade.m.jd.com/order/n_detail_jdm.shtml?deal_id=${order}`;
function fixture(href='https://trade.m.jd.com/order/orderlist_jdm.shtml') {
 let response;const messages=[];
 const c={URL,URLSearchParams,location:{href},document:{body:{innerText:''},querySelectorAll:()=>[]},webkit:{messageHandlers:{jdCapture:{postMessage:x=>messages.push(x)}}}};
 c.window=c;c.fetch=async()=>({url:'https://api.m.jd.com/api',status:200,clone:()=>({text:async()=>JSON.stringify(response)})});vm.createContext(c);vm.runInContext(script,c);
 return {c,messages,async capture(value,fn='order_list_m'){response=value;await c.fetch('https://api.m.jd.com/api?functionId='+fn+'&body='+encodeURIComponent(JSON.stringify({orderId:order})));await new Promise(r=>setImmediate(r));return messages.filter(x=>x.kind==='orders').at(-1);}};
}
test('actual structured orderDetailLink supplies date URL even without anchors or dateSubmit',async()=>{
 const f=fixture();const page=await f.capture({body:{orderList:[{orderId:order,orderDetailLink:{url:entry},orderStatusInfo:{orderStatusName:'已完成'},wareInfoList:[{wareName:'合成商品'}]}]}});
 assert.equal(page.orders[0].dateURL,entry);assert.equal(page.orders[0].submittedAt,'');
});
test('actual deal_id detail entry recognizes explicit order/date labels',()=>{
 const f=fixture(entry);f.c.document.body.innerText=`订单编号：${order}\n下单时间：2026-10-15 12:00:00`;
 const page=f.c.__parcelJDSnapshot();assert.equal(page.kind,'orderDate');assert.equal(page.orderID,order);assert.equal(page.submittedAt,'2026-10-15 12:00:00');
});
test('mobile order_detail_m extracts only explicitly labelled summary date bound to orderCommonVo',async()=>{
 const f=fixture(entry);
 await f.capture({body:{orderCommonVo:{orderId:order},summaryList:[{title:'订单编号',content:order},{title:'下单时间',content:'2026-10-15<br/>12:00:00'},{title:'支付时间',content:'2026-10-16 12:00:00'}]}},'order_detail_m');
 const page=f.messages.find(x=>x.kind==='orderDate');assert.ok(page);assert.equal(page.orderID,order);assert.equal(page.submittedAt,'2026-10-15 12:00:00');
});
test('detail response rejects conflicting account order and never borrows unlabelled timestamp',async()=>{
 for(const body of [
  {orderCommonVo:{orderId:'987654321012'},summaryList:[{title:'下单时间',content:'2026-10-15'}]},
  {orderCommonVo:{orderId:order},summaryList:[{title:'签收时间',content:'2026-10-15'}]},
  {orderCommonVo:{orderId:order},summaryList:[{title:'下单时间',content:'2026-10-15'},{title:'下单时间',content:'2026-10-16'}]},
  {summaryList:[{title:'下单时间',content:'2026-10-15'}]},
 ]) {
  const f=fixture(entry);await f.capture({body},'order_detail_m');assert.equal(f.messages.some(x=>x.kind==='orderDate'),false);
 }
});
test('structured detail links reject duplicate identity, foreign order and credentials',async()=>{
 for(const url of [entry+'&deal_id='+order,entry+'&orderId='+order,entry.replace(order,'987654321012'),entry+'&pt_key=SECRET','https://evil.test/order/n_detail_jdm.shtml?deal_id='+order]) {
  const page=await fixture().capture({body:{orderList:[{orderId:order,orderDetailLink:{url},wareInfoList:[]}]}});
  assert.equal(page.orders[0].dateURL,'',url);assert.doesNotMatch(JSON.stringify(page),/SECRET/);
 }
});
