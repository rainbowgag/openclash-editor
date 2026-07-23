const fs = require('fs');
const vm = require('vm');

global.window = global;
global.atob = value => Buffer.from(value, 'base64').toString('binary');
vm.runInThisContext(fs.readFileSync('www/converter.js', 'utf8'));
vm.runInThisContext(fs.readFileSync('www/editor-common.js', 'utf8'));

const link = 'vmess://ewogICJ2IjogIjIiLAogICJwcyI6ICIyMjIuMTY3LjIzNS4xNDEiLAogICJhZGQiOiAiMjIyLjE2Ny4yMzUuMTQxIiwKICAicG9ydCI6IDEzOTk4LAogICJpZCI6ICI4NTBkMWRiZC0zMGM4LTQ2ODEtYmQ0ZC05MDcyN2Y1ZWJkZDEiLAogICJzY3kiOiAiYXV0byIsCiAgIm5ldCI6ICJ0Y3AiLAogICJ0bHMiOiAibm9uZSIsCiAgInR5cGUiOiAiaHR0cCIsCiAgInBhdGgiOiAiLyIKfQ==';
const result = OpenClashConverter.convert(link, '');
if (result.errors.length) throw new Error(result.errors.join('\n'));
const node = result.nodes[0];
if (node.network !== 'http') throw new Error(`expected network=http, got ${node.network}`);
if (node.tls !== false) throw new Error(`expected tls=false, got ${node.tls}`);
if (!node['http-opts'] || node['http-opts'].method !== 'GET' || node['http-opts'].path[0] !== '/') throw new Error('invalid http-opts');
if (node['tcp-opts']) throw new Error('tcp-opts must not be generated for VMess HTTP');
console.log(JSON.stringify(node));

const socksInput = [
  '1.2.3.4:1080:alice:secret',
  'socks5://bob:p%40ss@5.6.7.8:2080',
  'carol:word@9.10.11.12:3080'
].join('\n');
const socksResult = OpenClashConverter.convert(socksInput, '中转');
if (socksResult.errors.length) throw new Error(socksResult.errors.join('\n'));
if (socksResult.nodes.length !== 3) throw new Error('expected 3 SOCKS5 nodes');
const expectedSocks = [
  ['1.2.3.4', 1080, 'alice', 'secret'],
  ['5.6.7.8', 2080, 'bob', 'p@ss'],
  ['9.10.11.12', 3080, 'carol', 'word']
];
socksResult.nodes.forEach((item, index) => {
  const expected = expectedSocks[index];
  if (item.type !== 'socks5' || item.server !== expected[0] || item.port !== expected[1] || item.username !== expected[2] || item.password !== expected[3] || item.udp !== true) throw new Error(`invalid SOCKS5 node ${index + 1}`);
  if (item.name !== `SOCKS5 ${expected[0]}:${expected[1]}`) throw new Error(`invalid SOCKS5 name ${index + 1}`);
  if (item['dialer-proxy'] !== '中转') throw new Error(`missing SOCKS5 dialer-proxy ${index + 1}`);
});
console.log(JSON.stringify(socksResult.nodes));

const numbered = Array.from({length: 10}, (_, index) => ({name: `old-${index + 1}`}));
OpenClashEditor.numberNodes(numbered, '美国', 5);
if (numbered[0].name !== '美国5' || numbered[9].name !== '美国14') throw new Error('bulk node numbering failed');
console.log(`${numbered[0].name}...${numbered[9].name}`);

const draft = {
  nodes: [
    {name: '美国1'}, {name: '美国2'}, {name: '日本1'}
  ],
  rules: [
    'SRC-IP-CIDR,192.168.100.2/32,美国1',
    'SRC-IP-CIDR,192.168.100.3/32,美国2',
    'SRC-IP-CIDR,192.168.100.4/32,美国1',
    'SRC-IP-CIDR,192.168.100.5/32,日本1'
  ],
  selected_node_names: ['美国1', '日本1'],
  network_cidr: '192.168.100.0/24',
  start_ip: '192.168.100.2',
  gateway_ip: '192.168.100.1'
};
const removedNodes = OpenClashEditor.removeNodes(draft, ['美国1', '不存在']);
if (removedNodes.nodes !== 1 || removedNodes.rules !== 2) throw new Error('bulk node removal returned wrong counts');
if (draft.nodes.some(item => item.name === '美国1') || draft.rules.some(rule => rule.endsWith(',美国1'))) throw new Error('bulk node removal left linked data');
if (draft.selected_node_names.join(',') !== '日本1') throw new Error('bulk node removal left selected node names');
if (draft.next_ip !== '192.168.100.2') throw new Error(`released IP was not reused: ${draft.next_ip}`);

const removedRules = OpenClashEditor.removeRulesByIps(draft, ['192.168.100.3/32']);
if (removedRules !== 1 || draft.nodes.length !== 2) throw new Error('bulk rule removal changed nodes or returned wrong count');
if (draft.rules.some(rule => OpenClashEditor.ruleParts(rule).ip === '192.168.100.3/32')) throw new Error('bulk rule removal left selected IP');
console.log(JSON.stringify({removedNodes, removedRules, nextIp: draft.next_ip}));
