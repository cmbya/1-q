// Actual embedded production JS; no network, cookies or real accounts.
import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';
import test from 'node:test';
const source=fs.readFileSync(new URL('../ParcelKeeper/Services/JDInAppClient.swift',import.meta.url),'utf8');
const script=source.match(/static let capture = #"""\n([\s\S]*?)\n"""#/)[1];
const oid='123456789', detail=`https://trade.m.jd.com/order/deal_wuliu_jdm.shtml?dealId=${oid}`;
function fixture(href=detail){
 let response; const messages=[];
 const c={URL,URLSearchParams,location:{href},document:{body:{innerText:''},querySelectorAll:()=>[]},webkit:{messageHandlers:{jdCapture:{postMessage:x=>messages.push(x)}}}};
 c.window=c;c.fetch=async()=>({status:200,url:'https://api.m.jd.com/api',clone:()=>({text:async()=>JSON.stringify(response)})});vm.createContext(c);vm.runInContext(script,c);
 return {c,messages,snapshot:()=>c.__parcelJDSnapshot(),async capture(value,order=oid,fn='pcdetail_traceMultiPackage'){response=value;await c.fetch('https://api.m.jd.com/api?functionId='+fn+'&body='+encodeURIComponent(JSON.stringify({orderId:order})));await new Promise(r=>setImmediate(r));return messages.filter(x=>x.kind==='logistics').at(-1);}};
}
const group=(number='JD12345678',content='包裹运输中',status='运输中')=>({carriageInfo:{},trackGroupInfo:{orderCarriageInfo:{carriageId:number,carrier:'京东快递'},orderTrackShowList:[{CreationTime:'2026-11-01 10:00:00',Content:content,StatusName:status}]}});
test('empty top carriageInfo cannot mask evidenced group carrier; StatusName survives',async()=>{
 const value=await fixture().capture({multiPackageTrackInfoList:[group(undefined,'','已签收')]});
 assert.equal(value?.parcels[0].number,'JD12345678');assert.equal(value.parcels[0].points[0].text,'已签收');
});
test('numbered outer parcel keeps nested carrier metadata when its own label is empty',async()=>{
 const f=fixture(); const p=group();p.carriageInfo={carriageId:'JD12345678',carrier:''};
 const value=await f.capture({multiPackageTrackInfoList:[p]});assert.equal(value.parcels[0].carrier,'京东快递');
});
test('explicit conflicting carriage identity is rejected, not combined',async()=>{
 const f=fixture();const p=group();p.carriageInfo={carriageId:'SF12345678',carrier:'顺丰'};await f.capture({multiPackageTrackInfoList:[p]});assert.equal(f.messages.at(-1).error,'identity');
});
test('numbered responses merge split parcels and repeated nodes rather than returning only first',async()=>{
 const f=fixture();await f.capture({multiPackageTrackInfoList:[group()]});
 const value=await f.capture({multiPackageTrackInfoList:[group('SF12345678','本人取件')]});
 assert.deepEqual(Array.from(value?.parcels||[],p=>p.number),['JD12345678','SF12345678']);
 const again=await f.capture({multiPackageTrackInfoList:[group()]});assert.equal(again.parcels[0].points.length,1);
});
test('status plus content retained, no naked service exclusion for after-sales status',async()=>{
 const f=fixture();const value=await f.capture({multiPackageTrackInfoList:[group(undefined,'包裹到达','待取件')]});assert.equal(value?.parcels[0].points[0].text,'待取件 包裹到达');
 await f.capture({body:{orderList:[{orderId:oid,orderStatusInfo:{orderStatusName:'售后服务完成'},wareInfoList:[{wareName:'商品'}]}]}},oid,'order_list_m');assert.equal(f.messages.filter(x=>x.kind==='orders').at(-1).orders[0].excluded,false);
});
test('same-card date supplement and only real next-page links exposed',()=>{
 const f=fixture('https://trade.m.jd.com/order/orderlist_jdm.shtml');
 const card={innerText:`订单号：${oid}\n下单时间：2026-10-15 12:00:00`,querySelectorAll:()=>[]};
 f.c.document.querySelectorAll=()=>[{href:detail,closest:()=>card},{href:'https://trade.m.jd.com/order/orderlist_jdm.shtml?page=2',innerText:'下一页',getAttribute:()=>null,closest:()=>null}];
 const page=f.snapshot();assert.equal(page.orders[0].submittedAt,'2026-10-15 12:00:00');assert.equal(page.nextURL,'https://trade.m.jd.com/order/orderlist_jdm.shtml?page=2');
 f.c.document.querySelectorAll=()=>[{href:'https://evil.test/order/orderlist_jdm.shtml?page=2',innerText:'下一页',getAttribute:()=>null}];assert.equal(f.snapshot().nextURL,'');
});
test('date-only detail requires explicit exact ID and submission label; never logistics dates',()=>{
 const f=fixture(`https://trade.m.jd.com/order/detail.action?orderId=${oid}`);
 f.c.document.body.innerText=`订单详情\n订单编号：${oid}\n下单时间：2026-10-15 12:00:00`;
 assert.equal(f.snapshot().kind,'orderDate');assert.equal(f.snapshot().submittedAt,'2026-10-15 12:00:00');
 f.c.document.body.innerText=`订单详情\n订单编号：987654321\n下单时间：2026-10-15 12:00:00`;assert.notEqual(f.snapshot().recognized,true);
 f.c.document.body.innerText=`订单详情\n订单编号：${oid}\n签收时间：2026-10-15 12:00:00`;assert.notEqual(f.snapshot().recognized,true);
});
test('response pending state tracks deferred fetch bodies until later split data is captured',async()=>{
 const f=fixture();let release;
 // A separate page context holds clone().text(), as happens when another parcel response is still arriving.
 const c={URL,URLSearchParams,location:{href:detail},document:{body:{innerText:''},querySelectorAll:()=>[]},webkit:{messageHandlers:{jdCapture:{postMessage:()=>{}}}}};
 c.window=c;c.fetch=async()=>({status:200,url:'https://api.m.jd.com/api',clone:()=>({text:()=>new Promise(r=>release=r)})});vm.createContext(c);vm.runInContext(script,c);
 await c.fetch('https://api.m.jd.com/api?functionId=pcdetail_traceMultiPackage&body='+encodeURIComponent(JSON.stringify({orderId:oid})));
 assert.equal(c.__parcelJDSnapshot().pendingRequests,1);
 release(JSON.stringify({multiPackageTrackInfoList:[group()]}));await new Promise(r=>setImmediate(r));assert.equal(c.__parcelJDSnapshot().pendingRequests,0);
});
test('date supplement link is page-observed, exact-ID, unique and credential-free',()=>{
 const f=fixture('https://trade.m.jd.com/order/orderlist_jdm.shtml');
 const url=`https://trade.m.jd.com/order/detail.action?orderId=${oid}`;
 let links=[{href:url}];const card={innerText:`订单号：${oid}\n售后服务完成`,querySelectorAll:()=>links};
 f.c.document.querySelectorAll=()=>[{href:detail,closest:()=>card}];
 assert.equal(f.snapshot().orders[0].dateURL,url);
 links=[{href:url+'&pt_key=SECRET'}];assert.equal(f.snapshot().orders[0].dateURL,'');
 links=[{href:'https://trade.m.jd.com/order/detail.action?orderId=987654321'}];assert.equal(f.snapshot().orders[0].dateURL,'');
 links=[{href:url},{href:url+'&source=2'}];assert.equal(f.snapshot().orders[0].dateURL,'');
});
test('mobile business labels match shared policy without after-sales false exclusions',async()=>{
 for (const [label,excluded] of [['售后服务已完成',false],['虚拟订单',true],['虚拟业务',true],['虚拟服务',true],['生活服务',true],['服务订单',true]]) {
  const f=fixture();await f.capture({body:{orderList:[{orderId:oid,orderStatusInfo:{orderStatusName:label},wareInfoList:[{wareName:'商品'}]}]}},oid,'order_list_m');
  assert.equal(f.messages.filter(x=>x.kind==='orders').at(-1).orders[0].excluded,excluded,label);
 }
});
test('native chain keeps bounded collection, safe refresh and terminal-only rotation contracts',()=>{
 assert.match(source,/sourceURL: String\? = nil/);assert.match(source,/saveRotated\(/);assert.match(source,/expectedGeneration: generation/);assert.match(source,/maxPages/);assert.match(source,/detailFailed/);assert.match(source,/stoppedReason/);
 assert.doesNotMatch(source,/if let captured \{ return captured \}/);
 const collect=source.slice(source.indexOf('private func collectOrders'),source.indexOf('    func query('));
 assert.ok(collect.indexOf('order.submittedAt = try JDPageParser.submission') < collect.indexOf('guard report.consider('));
 assert.doesNotMatch(source.slice(source.indexOf('func verifySession'),source.indexOf('func fetchOrders')),/persistRotation|saveRotated/);
 assert.equal((source.match(/saveRotated\(/g)||[]).length,1);
 assert.match(source,/guard JDPageParser.sameAccount\(cookies, rotated\)/);
 assert.match(source,/guard try MallSession\(platform: \.jd\).saveRotated/);
 assert.match(source,/pendingRequests.*Int.*== 0/);
});
