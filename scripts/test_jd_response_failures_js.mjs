import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';
import test from 'node:test';

const source = fs.readFileSync(new URL('../ParcelKeeper/Services/JDInAppClient.swift', import.meta.url), 'utf8');
const script = source.match(/static let capture = #"""\r?\n([\s\S]*?)\r?\n"""#/)[1];

function fixture() {
  const messages = [];
  let response;
  const context = {
    URL, URLSearchParams,
    location: { href: 'https://trade.m.jd.com/order/orderlist_jdm.shtml' },
    document: { body: { innerText: '' }, querySelectorAll: () => [] },
    webkit: { messageHandlers: { jdCapture: { postMessage: value => messages.push(value) } } },
  };
  context.window = context;
  context.fetch = async () => ({ status: 200, url: 'https://api.m.jd.com/client.action', clone: () => ({ text: async () => JSON.stringify(response) }) });
  vm.createContext(context);
  vm.runInContext(script, context);
  return {
    messages,
    async read(payload) {
      response = payload;
      await context.fetch('https://api.m.jd.com/client.action?functionId=order_list_m');
      await new Promise(resolve => setImmediate(resolve));
    },
  };
}

test('HTTP 200 with JD body.errorCode 302 means authentication, not schema failure', async () => {
  for (const errorCode of ['302', 302]) {
    const browser = fixture();
    await browser.read({ code: '0', body: { errorCode, loginUrl: 'https://example.invalid/private', errorReason: 'synthetic-private-reason' } });
    assert.ok(browser.messages.some(message => message.error === 'authentication'));
    assert.ok(!browser.messages.some(message => message.diagnostic === 'responseSchema'));
    assert.doesNotMatch(JSON.stringify(browser.messages), /example|private|loginUrl|errorReason/);
  }
});

test('JD business error is not accepted as an empty or successful order list', async () => {
  const browser = fixture();
  await browser.read({ code: '0', body: { errorCode: 'synthetic-code', errorReason: 'synthetic-reason', orderList: [] } });
  const failure = browser.messages.find(message => message.diagnostic === 'business');
  assert.equal(failure?.metrics.jdBusinessSource, 4);
  assert.ok(!browser.messages.some(message => message.kind === 'orders'));
  assert.doesNotMatch(JSON.stringify(browser.messages), /synthetic/);
});

test('nonzero retcode is a business failure even when code is zero', async () => {
  const browser = fixture();
  await browser.read({ code: '0', retcode: 'synthetic-code', body: { orderList: [] } });
  assert.equal(browser.messages.find(message => message.diagnostic === 'business')?.metrics.jdBusinessSource, 2);
  assert.ok(!browser.messages.some(message => message.kind === 'orders'));
});

test('schema diagnostics locate the invalid layer without recording payload fields', async () => {
  const cases = [
    [null, 1, 1, 0, 0],
    [{ body: 'synthetic-private-value' }, 2, 6, 4, 0],
    [{ body: null }, 2, 6, 1, 0],
    [{ body: {} }, 3, 6, 6, 0],
    [{ body: { orderList: {} } }, 4, 6, 6, 6],
    [{ body: { orderList: Array(201).fill({}) } }, 5, 6, 6, 5],
    [{ body: { orderList: [null] } }, 6, 6, 6, 5],
  ];
  for (const [payload, step, rootType, bodyType, listType] of cases) {
    const browser = fixture();
    await browser.read(payload);
    const failure = browser.messages.find(message => message.diagnostic === 'responseSchema');
    assert.equal(failure?.metrics.jdSchemaStep, step);
    assert.equal(failure.metrics.jdRootType, rootType);
    assert.equal(failure.metrics.jdBodyType, bodyType);
    assert.equal(failure.metrics.jdListType, listType);
    assert.equal(failure.metrics.jdRequestKind, 1);
    assert.ok(!browser.messages.some(message => message.kind === 'orders'));
    assert.doesNotMatch(JSON.stringify(browser.messages), /synthetic|orderList|https:/);
  }
});

test('a later valid response remains usable after a business rejection', async () => {
  const browser = fixture();
  await browser.read({ code: '0', body: { errorCode: 'synthetic-error' } });
  await browser.read({ code: '0', retcode: '0', body: { orderList: [{ orderId: '123456789012', wareInfoList: [] }] } });
  assert.equal(browser.messages.filter(message => message.kind === 'orders').at(-1)?.orders[0].id, '123456789012');
});
