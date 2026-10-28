import fs from 'node:fs';
import vm from 'node:vm';
import assert from 'node:assert/strict';

const source = fs.readFileSync(new URL('../Resources/extract-detection.js', import.meta.url), 'utf8');
const leaf = value => ({ innerText: value, textContent: value });
const rows = values => ({ querySelectorAll: () => Object.entries(values).map(([label, value]) => ({
  querySelector: selector => leaf(selector === '.risk-label' ? label : value)
})) });
function inspect(dns, service = '全部服务正常') {
  const elements = { dnsLeakContent: rows({ 状态: dns }), claudeAvailContent: rows({ Claude服务状态: service }) };
  return vm.runInNewContext(source, {
    document: { getElementById: id => elements[id] ?? null },
    location: { href: 'https://ip.net.coffee/claude/?ccguard=test' },
    performance: { timeOrigin: Date.now() - 10_000 }, Date, Intl,
    getComputedStyle: () => ({ display: 'block', visibility: 'visible' })
  });
}
const dnsCases = [
  ['未检测到泄露', true], ['DNS 加密或未暴露出口', true],
  ['可能泄露', false], ['检测到泄露', false],
  ['', null], ['检测中...', null], ['无法获取', null], ['新的未知文案', null]
];
for (const [text, expected] of dnsCases) {
  const result = inspect(text);
  assert.equal(result.dnsSafe, expected, text);
  assert.equal(result.raw.dns, text);
}
const serviceCases = [['全部服务正常', true], ['轻微故障', false], ['重大故障', false], ['', null]];
for (const [text, expected] of serviceCases) {
  const result = inspect('未检测到泄露', text);
  assert.equal(result.serviceHealthy, expected, text);
  assert.equal(result.raw.serviceStatus, text);
}
console.log(`Extractor: ${dnsCases.length + serviceCases.length} cases passed`);
