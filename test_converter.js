const fs = require('fs');
const vm = require('vm');

global.window = global;
global.atob = value => Buffer.from(value, 'base64').toString('binary');
vm.runInThisContext(fs.readFileSync('www/converter.js', 'utf8'));

const link = 'vmess://ewogICJ2IjogIjIiLAogICJwcyI6ICIyMjIuMTY3LjIzNS4xNDEiLAogICJhZGQiOiAiMjIyLjE2Ny4yMzUuMTQxIiwKICAicG9ydCI6IDEzOTk4LAogICJpZCI6ICI4NTBkMWRiZC0zMGM4LTQ2ODEtYmQ0ZC05MDcyN2Y1ZWJkZDEiLAogICJzY3kiOiAiYXV0byIsCiAgIm5ldCI6ICJ0Y3AiLAogICJ0bHMiOiAibm9uZSIsCiAgInR5cGUiOiAiaHR0cCIsCiAgInBhdGgiOiAiLyIKfQ==';
const result = OpenClashConverter.convert(link, '');
if (result.errors.length) throw new Error(result.errors.join('\n'));
const node = result.nodes[0];
if (node.network !== 'http') throw new Error(`expected network=http, got ${node.network}`);
if (node.tls !== false) throw new Error(`expected tls=false, got ${node.tls}`);
if (!node['http-opts'] || node['http-opts'].method !== 'GET' || node['http-opts'].path[0] !== '/') throw new Error('invalid http-opts');
if (node['tcp-opts']) throw new Error('tcp-opts must not be generated for VMess HTTP');
console.log(JSON.stringify(node));
