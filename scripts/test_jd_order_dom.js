#!/usr/bin/env node
'use strict';
// Execute the actual Swift embedded script, not a second implementation.
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const file = path.join(__dirname, '../ParcelKeeper/Services/JDOrderSelection.swift');
const source = fs.readFileSync(file, 'utf8');
const match = source.match(/static let domScript: String = #"""\n([\s\S]*?)\n\s*"""#/);
assert.ok(match, 'Swift domScript raw string missing');
class Element {
  constructor(tag, text = '', attrs = {}, children = []) { this.tagName = tag.toUpperCase(); this.text = text; this.attrs = attrs; this.children = children; this.hidden = false; for (const c of children) c.parentElement = this; }
  get innerText() { return [this.text, ...this.children.map(c => c.innerText)].filter(Boolean).join('\n'); }
  get textContent() { return this.innerText; }
  getAttribute(k) { return this.attrs[k] ?? null; }
  getClientRects() { return this.hidden ? [] : [{}]; }
  querySelectorAll(selector) { const all = this.children.flatMap(c => [c, ...c.querySelectorAll('*')]); return selector === '*' ? all : all.filter(e => selector === 'a[href]' ? e.tagName === 'A' && e.attrs.href : false); }
}
const ID = '123456789012';
const url = id => `https://trade.m.jd.com/order/deal_wuliu_jdm.shtml?dealId=${id}&orderType=0&dealState=7`;
const link = (href = url(ID)) => new Element('a', '查看物流', {href});
const card = (id = ID, a = link(url(id)), date = '2026-10-20 12:34:56') => new Element('section', `订单编号：${id}\n下单时间：${date}\n已签收`, {}, [new Element('div', '咖啡', {}, [a])]);
function run(children, pathname = '/order/orderlist_jdm.shtml') {
  const body = new Element('body', '我的订单', {}, children);
  return JSON.parse(JSON.stringify(vm.runInNewContext(match[1], {document: {body, documentElement: body, querySelectorAll: s => body.querySelectorAll(s)}, location: {href: `https://trade.m.jd.com${pathname}`, hostname: 'trade.m.jd.com', pathname}, URL, getComputedStyle: e => ({display: e.hidden ? 'none' : 'block', visibility: 'visible', opacity: '1'})})));
}
let out = run([card()]);
assert.equal(out.recognized, true); assert.equal(out.rows.length, 1);
assert.equal(out.rows[0].id, ID); assert.equal(out.rows[0].url, url(ID));
assert.equal(out.rows[0].orderDate, '2026-10-20 12:34:56');
assert.match(out.rows[0].text, /已签收/);
assert.equal(run([card(ID, link('//trade.m.jd.com/order/deal_wuliu_jdm.shtml?dealId='+ID))]).rows.length, 1);
assert.equal(run([card(ID, link('/order/deal_wuliu_jdm.shtml?dealId='+ID))]).rows.length, 1);
const hidden = link(); hidden.hidden = true; assert.equal(run([card(ID, hidden)]).rows.length, 0);
const hiddenCard = card(); hiddenCard.hidden = true; assert.equal(run([hiddenCard]).rows.length, 0);
for (const href of [url(ID)+'&dealId='+ID, url(ID)+'&orderID=999999', url(ID).replace('trade.m.jd.com', 'evil.com'), url(ID).replace('https:', 'http:')]) assert.equal(run([card(ID, link(href))]).rows.length, 0, href);
const mixed = card(); mixed.children.push(new Element('span', '订单编号：999999')); mixed.children.at(-1).parentElement = mixed;
assert.equal(run([mixed]).rows.length, 0);
const mixedLinks = card(); const other = link(url('999999')); other.parentElement = mixedLinks; mixedLinks.children.push(other);
assert.equal(run([mixedLinks]).rows.length, 0);
assert.equal(run([card(ID), card('999999')]).rows.length, 2);
assert.equal(run([card(ID), card(ID)]).rows.length, 0, 'duplicate identity snapshot is ambiguous');
assert.equal(run([link(), new Element('div', '订单编号：'+ID+'\n下单时间：2026-10-20 12:34:56')]).rows.length, 0, 'no whole-page pairing');
assert.equal(run([card()], '/login').recognized, false);
assert.equal(run([]).recognized, false, 'unknown/unfinished page is not empty success');
out = run([new Element('div', '暂无订单')]); assert.equal(out.recognized, true); assert.equal(out.empty, true);
assert.equal(run([card(ID, link(), '10-20')]).rows[0].orderDate, '');
assert.equal(run([card(ID, link(), '2026-10-20')]).rows[0].orderDate, '2026-10-20');
assert.equal(run(Array.from({length:201}, (_,i)=>card(String(123456789000+i)))).recognized, false);
assert.equal(run(Array.from({length:2001}, ()=>link())).recognized, false);
console.log('PASS: JD DOM script identity, visibility, URL, date, recognized-empty and bounds fixtures');
