// Production embedded JS, synthetic transport/DOM. No account or business requests.
import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';
import test from 'node:test';
const s=fs.readFileSync(new URL('../ParcelKeeper/Services/JDInAppClient.swift',import.meta.url),'utf8');
const script=s.match(/static let capture = #"""\n([\s\S]*?)\n"""#/)[1];
function fixture(){
 const messages=[];let response,body;const distances=[];
 const el={id:'/order/orderlist_jdm.shtml',scrollHeight:1400,clientHeight:500,scrollTop:0,getClientRects:()=>[1],dispatchEvent(){distances.push(this.scrollHeight-this.scrollTop-this.clientHeight);}};
 const c={URL,URLSearchParams,Map,Set,Event:class Event{},setTimeout,requestAnimationFrame:fn=>setTimeout(fn,0),getComputedStyle:()=>({display:'block'}),location:{href:'https://trade.m.jd.com/order/orderlist_jdm.shtml',pathname:'/order/orderlist_jdm.shtml'},document:{body:{innerText:''},querySelectorAll:sel=>sel==='.taro_page'?[el]:[]},webkit:{messageHandlers:{jdCapture:{postMessage:x=>messages.push(x)}}}};
 c.window=c;c.fetch=async()=>({url:'https://api.m.jd.com/api',status:200,clone:()=>({text:async()=>JSON.stringify(response)})});vm.createContext(c);vm.runInContext(script,c);
 return {c,el,messages,distances,async page(page,ids,extra={}){response={body:{orderList:ids.map(id=>({orderId:id,wareInfoList:[]})),totalNum:ids.length}};body={page,pageSize:2,curTab:'all',...extra};await c.fetch('https://api.m.jd.com/api?functionId=order_list_m&body='+encodeURIComponent(JSON.stringify(body)));await new Promise(r=>setImmediate(r));return messages.filter(x=>x.kind==='orders').at(-1);}};
}
test('successive natural pages aggregate exact IDs, keep overlap, and mark short-page end',async()=>{
 const f=fixture();let p=await f.page(1,['123456789','123456790']);assert.equal(p.listPages,1);assert.equal(p.listCanAdvance,true);
 p=await f.page(2,['123456790','123456791']);assert.deepEqual(Array.from(p.orders,x=>x.id),['123456789','123456790','123456791']);assert.equal(p.listPages,2);
 p=await f.page(3,[]);assert.equal(p.listCanAdvance,false);assert.equal(p.listPages,3);assert.equal(p.orders.length,3);
});
test('natural pages with wrong filter or skipped sequence cannot mix accounts/tabs',async()=>{
 const f=fixture();await f.page(1,['123456789','123456790']);await f.page(2,['999999999'],{curTab:'waitReceipt'});
 assert.equal(f.messages.filter(x=>x.kind==='orders').at(-1).orders.length,2);
 await f.page(3,['888888888']);assert.equal(f.messages.filter(x=>x.kind==='orders').at(-1).listPages,1);
});
test('unsequenced later response cannot replace earlier verified pages',async()=>{
 const f=fixture();await f.page(1,['123456789','123456790']);await f.page('2',['999999999']);
 const p=f.messages.filter(x=>x.kind==='orders').at(-1);assert.equal(p.listPages,1);assert.equal(p.orders[0].id,'123456789');
});
test('next trigger re-arms >400 before entering <400 in the unique Taro container',async()=>{
 const f=fixture();await f.page(1,['123456789','123456790']);assert.equal(f.c.__parcelJDNextPage(),true);await new Promise(r=>setTimeout(r,15));
 assert.ok(f.distances.length>=2);assert.ok(f.distances[0]>400);assert.ok(f.distances.at(-1)<400);
});
test('no speculative pagination when container cannot rearm or page is complete',async()=>{
 const f=fixture();await f.page(1,['123456789','123456790']);f.el.scrollHeight=800;assert.equal(f.c.__parcelJDNextPage(),false);
 await f.page(2,[]);f.el.scrollHeight=1400;assert.equal(f.c.__parcelJDNextPage(),false);
});
