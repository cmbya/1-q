// Offline execution of the production WKWebView script, not a JS reimplementation.
import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';
import test from 'node:test';
const source = fs.readFileSync(new URL('../ParcelKeeper/Services/JDInAppClient.swift', import.meta.url), 'utf8');
const script = source.match(/static let capture = #"""\n([\s\S]*?)\n"""#/)[1];
function fixture() {
  const messages = []; let response;
  const context = {URL, URLSearchParams, location:{href:'https://trade.m.jd.com/order/orderlist_jdm.shtml'}, document:{body:{innerText:''},querySelectorAll:()=>[]}, webkit:{messageHandlers:{jdCapture:{postMessage:x=>messages.push(x)}}}};
  context.window=context;
  context.fetch=async()=>({url:'https://api.m.jd.com/api',status:200,clone:()=>({text:async()=>JSON.stringify(response)})});
  vm.createContext(context); vm.runInContext(script,context);
  return {context, messages, async capture(value, fn='order_list_m') {response=value; await context.fetch('https://api.m.jd.com/api?functionId='+fn+'&body='+encodeURIComponent(JSON.stringify({orderId:'123456789'}))); await new Promise(r=>setImmediate(r)); return messages.filter(x=>x.kind==='orders').at(-1);}};
}
const row = extra => ({orderId:'123456789',orderStatusInfo:{orderStatusName:'已完成'},wareInfoList:[{wareName:'含配送字样的实物商品'}],...extra});
test('captured submitted date is whitelisted; completed state is retained; shipment time is never substituted', async()=>{
  const f=fixture(); const page=await f.capture({body:{orderList:[row({dateSubmit:'2026-10-15 12:00:00',deliveryTime:'2026-11-04 10:00:00',pt_key:'SECRET'})]}});
  assert.equal(page.orders[0].submittedAt,'2026-10-15 12:00:00');
  assert.equal(page.orders[0].status,'已完成'); assert.equal(page.orders[0].excluded,false);
  assert.doesNotMatch(JSON.stringify(page),/SECRET|pt_key|deliveryTime/);
});
test('unknown date remains missing, not taken from unrelated timestamps',async()=>{
  const page=await fixture().capture({body:{orderList:[row({deliveryTime:'2026-11-04',createTime:'2026-11-04'})]}});
  assert.equal(page.orders[0].submittedAt,'');
});
test('explicit business/status excludes takeaway and virtual, never a product title containing 配送',async()=>{
  for (const [extra,excluded] of [[{orderType:4},true],[{orderType:69},true],[{orderStatusInfo:{orderStatusName:'京东外卖 已完成'}},true],[{orderStatusInfo:{orderStatusName:'京东秒送 已完成'}},true],[{},false]]) {
    const page=await fixture().capture({body:{orderList:[row(extra)]}}); assert.equal(page.orders[0].excluded,excluded);
  }
});
test('DOM date must be explicitly labelled on the same order card',()=>{
  const f=fixture(); const card={innerText:'订单号：123456789\n下单时间：2026-10-15 12:00:00\n已签收\n配送商品'};
  f.context.document.querySelectorAll=()=>[{href:'https://trade.m.jd.com/order/deal_wuliu_jdm.shtml?dealId=123456789',closest:()=>card}];
  let page=f.context.__parcelJDSnapshot(); assert.equal(page.orders[0].submittedAt,'2026-10-15 12:00:00');
  card.innerText='订单号：123456789\n签收时间：2026-10-15 12:00:00'; page=f.context.__parcelJDSnapshot(); assert.equal(page.orders[0].submittedAt,'');
  for (const invalid of ['下单时间：2026-10-15garbage', '商品名称：下单时间：2026-10-15', '下单时间：2026-10-15 99:99:99suffix']) {
    card.innerText='订单号：123456789\n'+invalid; assert.equal(f.context.__parcelJDSnapshot().orders[0].submittedAt,'');
  }
});
test('known structured empty details provide provisional evidence without inventing a waybill',async()=>{
  const f=fixture(); await f.capture({body:{carriageId:'',tracePointVOList:[]}},'get_logistics_list_by_order_m');
  const empty=f.messages.find(x=>x.kind==='logisticsEmpty'); assert.ok(empty); assert.equal(empty.orderID,'123456789'); assert.equal(empty.parcels.length,0);
});
