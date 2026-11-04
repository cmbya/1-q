// Independent fixtures based on Parcly pinned connector's decode/response-first flow.
// No upstream implementation copied; no real account payloads or requests.
import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';
import test from 'node:test';
const source=fs.readFileSync(new URL('../ParcelKeeper/Services/JDInAppClient.swift',import.meta.url),'utf8');
const script=source.match(/static let capture = #"""\n([\s\S]*?)\n"""#/)[1];
const oid='123456789012';
const response={body:{orderList:[{orderId:oid,orderStatusInfo:{orderStatusName:'已完成'},wareInfoList:[{wareName:'合成商品'}],orderDetailLink:{url:`https://trade.m.jd.com/order/n_detail_jdm.shtml?deal_id=${oid}`}}],totalNum:1}};
function fixture(){
 const messages=[];let raw;
 const c={URL,URLSearchParams,location:{href:'https://trade.m.jd.com/order/orderlist_jdm.shtml'},document:{body:{innerText:''},querySelectorAll:()=>[]},webkit:{messageHandlers:{jdCapture:{postMessage:x=>messages.push(x)}}}};
 c.window=c;c.fetch=async()=>({status:200,url:'https://api.m.jd.com/api',clone:()=>({text:async()=>raw})});vm.createContext(c);vm.runInContext(script,c);
 return {messages,async read(payload=response,body='{}',fn='order_list_m') {raw=typeof payload==='string'?payload:JSON.stringify(payload);await c.fetch('https://api.m.jd.com/api?functionId='+fn+'&body='+encodeURIComponent(body));await new Promise(r=>setImmediate(r));return messages.filter(x=>x.kind==='orders').at(-1);}};
}
test('Parcly string-wrapped response decodes before inspecting body.orderList',async()=>{
 const f=fixture();const value=await f.read(JSON.stringify(JSON.stringify(response)));
 assert.equal(value?.orders[0].id,oid);
});
test('current authenticated list is recognized even when first observed request is page 2 or 3',async()=>{
 for(const page of [2,3]) {const f=fixture();const value=await f.read(response,JSON.stringify({page,pageSize:10,curTab:'all'}));assert.equal(value?.orders[0].id,oid);assert.equal(value.listCanAdvance,false);}
});
test('request-body null or unknown shape cannot invalidate valid response orders',async()=>{
 for(const body of ['null','[]','not-json','{}']) {const f=fixture();const value=await f.read(response,body);assert.equal(value?.orders[0].id,oid);assert.ok(!f.messages.some(x=>x.diagnostic==='processing'));}
});
test('response-first list capture does not require a guessed functionId',async()=>{
 const f=fixture();const value=await f.read(response,'{}','page_response_variant');assert.equal(value?.orders[0].id,oid);
});
test('Parcly fallback logistics link carries observed order-state sku shop fields',async()=>{
 const f=fixture();const row={...response.body.orderList[0],orderType:0,orderStatusInfo:{orderStatusName:'已完成',originOrderStatus:7},wareInfoList:[{wareName:'合成商品',skuId:'1234'}],shopInfo:{shopId:'5678'}};
 const value=await f.read({body:{orderList:[row]}});const url=new URL(value.orders[0].url);
 assert.equal(url.searchParams.get('dealState'),'7');assert.equal(url.searchParams.get('skuid'),'1234');assert.equal(url.searchParams.get('shopid'),'5678');assert.equal(url.searchParams.get('dealId'),oid);
});
test('decode and response schema failures have distinct closed diagnostic labels',async()=>{
 const decode=fixture();await decode.read('not-json');assert.ok(decode.messages.some(x=>x.diagnostic==='jsonDecode'));
 const schema=fixture();await schema.read({body:{other:[]}});assert.ok(schema.messages.some(x=>x.diagnostic==='responseSchema'));
 for(const f of [decode,schema]) assert.doesNotMatch(JSON.stringify(f.messages),/not-json|other|https:|123456789012/);
});
test('null list entries do not erase separate valid rows or become false empty evidence',async()=>{
 const f=fixture();const value=await f.read({body:{orderList:[null,response.body.orderList[0]]}});assert.equal(value?.orders.length,1);assert.equal(value.orders[0].id,oid);
 const invalid=fixture();await invalid.read({body:{orderList:[null]}});assert.equal(invalid.messages.some(x=>x.kind==='orders'),false);
});
