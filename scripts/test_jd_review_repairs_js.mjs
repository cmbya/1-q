// Executes the actual embedded production JavaScript. Offline synthetic page/network fixtures only.
import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';
import test from 'node:test';
const source = fs.readFileSync(new URL('../ParcelKeeper/Services/JDInAppClient.swift', import.meta.url), 'utf8');
const script = source.match(/static let capture = #"""\n([\s\S]*?)\n"""#/)[1];
const orderID = '123456789';
const detailURL = `https://trade.m.jd.com/order/deal_wuliu_jdm.shtml?dealId=${orderID}`;
const current = '订单号：123456789\n运单号：JD12345678\n物流公司：京东快递\n2026-11-01 10:00:00\n包裹运输中';
const recommendation = '\n猜你喜欢\n2026-11-02 10:00:00\n包裹已签收，推荐商品';
function fixture(body = current) {
  const messages = [];
  let response;
  const context = {URL, URLSearchParams, location:{href:detailURL}, document:{body:{innerText:body}, querySelectorAll:()=>[]}, webkit:{messageHandlers:{jdCapture:{postMessage:value=>messages.push(value)}}}};
  context.window=context;
  context.fetch=async()=>({url:'https://api.m.jd.com/api',status:200,clone:()=>({text:async()=>JSON.stringify(response)})});
  vm.createContext(context); vm.runInContext(script,context);
  return {messages, snapshot:()=>context.__parcelJDSnapshot(), async capture(value, fn='pcdetail_traceMultiPackage') {
    response=value;
    await context.fetch('https://api.m.jd.com/api?functionId='+fn+'&body='+encodeURIComponent(JSON.stringify({orderId:orderID})));
    await new Promise(resolve=>setImmediate(resolve));
    return messages.filter(value=>value.kind==='logistics');
  }};
}
const group = {orderCarriageInfo:{carriageId:'JD12345678',carrier:'京东快递'},orderTrackShowList:[{CreationTime:'2026-11-01 10:00:00',Content:'包裹运输中'}]};
test('unproven whole-page DOM is rejected even with a single plausible order/waybill',()=>{
  assert.equal(fixture().snapshot().recognized,false);
});
test('a newer recommendation node with no second waybill cannot contaminate current parcel',()=>{
  const value=fixture(current+recommendation).snapshot();
  assert.equal(value.recognized,false);
  assert.equal(value.parcels,undefined);
});
test('an unrelated order in recommendations cannot establish current parcel identity',()=>{
  assert.equal(fixture('订单号：987654321\n'+current+recommendation).snapshot().recognized,false);
});
test('structured PC group.orderCarriageInfo remains usable despite unrelated page content',async()=>{
  const values=await fixture(current+recommendation).capture({multiPackageTrackInfoList:[{trackGroupInfo:group}]});
  assert.equal(values.length,1); assert.equal(values[0].parcels[0].number,'JD12345678');
  assert.equal(values[0].parcels[0].points.length,1);
  assert.equal(values[0].parcels[0].points[0].text,'包裹运输中');
});
test('missing PC numbers do not emit a premature recognized logistics response',async()=>{
  const values=await fixture().capture({multiPackageTrackInfoList:[{carriageInfo:{},trackGroupInfo:{orderTrackShowList:group.orderTrackShowList}}]});
  assert.equal(values.length,0);
});
test('missing mobile number does not prevent subsequent structured response',async()=>{
  const f=fixture();
  assert.equal((await f.capture({body:{carriageId:'',tracePointVOList:[]}},'get_logistics_list_by_order_m')).length,0);
  const values=await f.capture({multiPackageTrackInfoList:[{trackGroupInfo:group}]});
  assert.equal(values.length,1); assert.equal(values[0].parcels[0].number,'JD12345678');
});
test('split parcels remain separate and unnumbered packages are not invented',async()=>{
  const values=await fixture().capture({multiPackageTrackInfoList:[{carriageInfo:{carriageId:'SF12345678',carrier:'顺丰'},trackGroupInfo:{orderTrackShowList:[{CreationTime:'2026-11-02 10:00:00',Content:'本人已取件'}]}},{trackGroupInfo:group},{carriageInfo:{},trackGroupInfo:{orderTrackShowList:[]}}]});
  assert.equal(values[0].parcels.length,2);
  assert.equal(values[0].parcels[0].points[0].text,'本人已取件');
  assert.equal(values[0].parcels[1].points[0].text,'包裹运输中');
});
