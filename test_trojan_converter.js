const fs = require('fs');
const vm = require('vm');

global.window = global;
global.atob = value => Buffer.from(value, 'base64').toString('binary');
vm.runInThisContext(fs.readFileSync('www/converter.js', 'utf8'));

const trojanLink = 'trojan://019f31dd-d6c9-7009-b759-96e2f7461bb7@margaret-rose-kensington.junheff.com:26310?type=tcp&security=tls&sni=ShermaneRouter&allowInsecure=1&insecure=1#%E7%BE%8E%E5%9B%BD-204.141.122.47';
const trojanResult = OpenClashConverter.convert(trojanLink, '');
if (trojanResult.errors.length) throw new Error(trojanResult.errors.join('\n'));
const trojan = trojanResult.nodes[0];
if (trojan.name !== '美国-204.141.122.47' || trojan.type !== 'trojan') throw new Error('invalid Trojan name or type');
if (trojan.server !== 'margaret-rose-kensington.junheff.com' || trojan.port !== 26310) throw new Error('invalid Trojan server');
if (trojan.password !== '019f31dd-d6c9-7009-b759-96e2f7461bb7' || trojan.udp !== true) throw new Error('invalid Trojan credentials');
if (trojan.network !== 'tcp' || trojan.sni !== 'ShermaneRouter' || trojan['skip-cert-verify'] !== true) throw new Error('invalid Trojan TLS options');
console.log(JSON.stringify(trojan));

const trojanGoLink = 'trojan-go://secret%40word@example.com:443/?type=ws&sni=edge.example.com&host=cdn.example.com&path=%2Ftrojan-go&allowInsecure=0&encryption=ss%3Baes-256-gcm%3Aextra-secret#Trojan-Go';
const trojanGoResult = OpenClashConverter.convert(trojanGoLink, '中转');
if (trojanGoResult.errors.length) throw new Error(trojanGoResult.errors.join('\n'));
const trojanGo = trojanGoResult.nodes[0];
if (trojanGo.type !== 'trojan' || trojanGo.password !== 'secret@word' || trojanGo.network !== 'ws') throw new Error('invalid Trojan-Go base fields');
if (trojanGo.sni !== 'edge.example.com' || trojanGo['skip-cert-verify']) throw new Error('invalid Trojan-Go TLS fields');
if (!trojanGo['ws-opts'] || trojanGo['ws-opts'].path !== '/trojan-go' || trojanGo['ws-opts'].headers.Host !== 'cdn.example.com') throw new Error('invalid Trojan-Go ws-opts');
if (!trojanGo['ss-opts'] || trojanGo['ss-opts'].enabled !== true || trojanGo['ss-opts'].method !== 'aes-256-gcm' || trojanGo['ss-opts'].password !== 'extra-secret') throw new Error('invalid Trojan-Go ss-opts');
if (trojanGo['dialer-proxy'] !== '中转') throw new Error('missing Trojan-Go dialer-proxy');
console.log(JSON.stringify(trojanGo));

const originalResult = OpenClashConverter.convert('trojan-go://password@example.net/?type=original#Original', '');
if (originalResult.errors.length || originalResult.nodes[0].network !== 'tcp') throw new Error('Trojan-Go original transport was not mapped to TCP');
