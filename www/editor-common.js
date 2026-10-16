(function(global) {
  'use strict';

  var STORAGE_KEY = 'openclash-editor-draft-v3';
  var urls = {};

  function configure(value) { urls = value || {}; }

  function post(url, data) {
    return fetch(url, {
      method: 'POST', credentials: 'same-origin',
      headers: {'Content-Type': 'application/x-www-form-urlencoded;charset=UTF-8'},
      body: new URLSearchParams(data || {})
    }).then(function(response) {
      return response.text().then(function(text) {
        try { return JSON.parse(text); }
        catch (_) { throw new Error('服务器返回异常（HTTP ' + response.status + '）：\n' + text.slice(0, 240)); }
      });
    });
  }

  function get(url) {
    return fetch(url, {credentials: 'same-origin'}).then(function(response) {
      return response.text().then(function(text) {
        try { return JSON.parse(text); }
        catch (_) { throw new Error('读取接口返回异常（HTTP ' + response.status + '）'); }
      });
    });
  }

  function ipToInt(ip) {
    var parts = String(ip || '').split('.');
    if (parts.length !== 4 || parts.some(function(value) { return !/^\d{1,3}$/.test(value) || Number(value) > 255; })) return null;
    return parts.reduce(function(total, value) { return total * 256 + Number(value); }, 0);
  }

  function intToIp(value) {
    return [Math.floor(value / 16777216) % 256, Math.floor(value / 65536) % 256, Math.floor(value / 256) % 256, value % 256].join('.');
  }

  function cidrInfo(cidr) {
    var match = String(cidr || '').trim().match(/^([^/]+)\/(\d{1,2})$/);
    if (!match) return null;
    var address = ipToInt(match[1]), prefix = Number(match[2]);
    if (address === null || prefix < 1 || prefix > 30) return null;
    var size = Math.pow(2, 32 - prefix), network = Math.floor(address / size) * size;
    return {cidr: intToIp(network) + '/' + prefix, network: network, first: network + 1, last: network + size - 2};
  }

  function ruleParts(rule) {
    var parts = String(rule).split(',');
    return {ip: parts[1] || '', name: parts[2] || '', suffix: parts.slice(3)};
  }

  function numberNodes(nodes, prefix, start) {
    var first = Number(start);
    return nodes.map(function(node, index) {
      node.name = String(prefix) + (first + index);
      return node;
    });
  }

  var AIRPORT_GROUP_ORDER = ['HK','US','SG','TW','JP','OTHER'];
  var AIRPORT_GROUP_NAMES = {'HK':'🇭🇰 香港中转','US':'🇺🇸 美国中转','SG':'🇸🇬 新加坡中转','TW':'🇹🇼 台湾中转','JP':'🇯🇵 日本中转','OTHER':'中转代理组'};

  function countryTag(name) {
    var raw = String(name || ''), s = raw.toLowerCase();
    if (raw.indexOf('\uD83C\uDDED\uD83C\uDDF0') >= 0 || /香港|hong\s?kong|\bhk\b|\bhk[-_0-9]/i.test(s)) return 'HK';
    if (raw.indexOf('\uD83C\uDDFA\uD83C\uDDF8') >= 0 || /美国|洛杉矶|纽约|圣何塞|硅谷|\bus\b|\busa\b|united states/i.test(s)) return 'US';
    if (raw.indexOf('\uD83C\uDDF8\uD83C\uDDEC') >= 0 || /新加坡|狮城|\bsg\b|singapore/i.test(s)) return 'SG';
    if (raw.indexOf('\uD83C\uDDF9\uD83C\uDDFC') >= 0 || /台湾|台北|\btw\b|taiwan/i.test(s)) return 'TW';
    if (raw.indexOf('\uD83C\uDDEF\uD83C\uDDF5') >= 0 || /日本|东京|大阪|\bjp\b|japan/i.test(s)) return 'JP';
    return 'OTHER';
  }

  function airportGroupName(tag) { return AIRPORT_GROUP_NAMES[tag] || AIRPORT_GROUP_NAMES.OTHER; }

  function buildAirportGroups(nodes) {
    var by = {};
    (nodes || []).forEach(function(node) {
      var tag = countryTag(node.name);
      (by[tag] = by[tag] || []).push(node.name);
    });
    var groups = AIRPORT_GROUP_ORDER.filter(function(tag) { return by[tag] && by[tag].length; }).map(function(tag) {
      return { name: airportGroupName(tag), type: 'url-test', proxies: by[tag] };
    });
    groups.push({ name: '节点选择代理组', type: 'select', proxies: (nodes || []).map(function(node) { return node.name; }) });
    return groups;
  }

  function recalculateNextIp(draft) {
    var info = cidrInfo(draft.network_cidr), start = ipToInt(draft.start_ip);
    if (!info || start === null || start < info.first || start > info.last) { draft.next_ip = ''; return ''; }
    var used = {}, gateway = ipToInt(draft.gateway_ip);
    draft.rules.forEach(function(rule) {
      var value = ipToInt(ruleParts(rule).ip.replace(/\/32$/, ''));
      if (value !== null) used[value] = true;
    });
    (draft.slots || []).forEach(function(slot) {
      var value = ipToInt(slot.ip);
      if (value !== null) used[value] = true;
    });
    var poolStart = ipToInt(draft.dhcp_pool_start), poolEnd = ipToInt(draft.dhcp_pool_end);
    while (start <= info.last) {
      if (used[start] || start === gateway) { start++; continue; }
      if (poolStart !== null && poolEnd !== null && start >= poolStart && start <= poolEnd) { start = poolEnd + 1; continue; }
      break;
    }
    draft.next_ip = start <= info.last ? intToIp(start) : '';
    return draft.next_ip;
  }

  function removeNodes(draft, names) {
    var selected = Object.create(null), existing = Object.create(null);
    (names || []).forEach(function(name) { selected[String(name)] = true; });
    draft.nodes.forEach(function(node) {
      if (selected[node.name]) existing[node.name] = true;
    });
    var nodeCount = Object.keys(existing).length, beforeRules = draft.rules.length, beforeSlots = (draft.slots || []).length;
    draft.nodes = draft.nodes.filter(function(node) { return !existing[node.name]; });
    draft.rules = draft.rules.filter(function(rule) { return !existing[ruleParts(rule).name]; });
    draft.slots = (draft.slots || []).filter(function(slot) { return !existing[slot.node]; });
    draft.selected_node_names = (draft.selected_node_names || []).filter(function(name) { return !existing[name]; });
    recalculateNextIp(draft);
    return {nodes: nodeCount, rules: beforeRules - draft.rules.length, slots: beforeSlots - draft.slots.length};
  }

  function removeRulesByIps(draft, ips) {
    var selected = Object.create(null);
    (ips || []).forEach(function(ip) { selected[String(ip)] = true; });
    var before = draft.rules.length;
    draft.rules = draft.rules.filter(function(rule) { return !selected[ruleParts(rule).ip]; });
    draft.slots = (draft.slots || []).filter(function(slot) { return !selected[String(slot.ip) + '/32']; });
    recalculateNextIp(draft);
    return before - draft.rules.length;
  }

  function fromState(state) {
    var draft = {
      schema: 3,
      source_sha256: state.source_sha256,
      nodes: state.nodes || [], rules: state.rules || [], slots: state.slots || [],
      existing_node_names: (state.nodes || []).map(function(node) { return node.name; }),
      existing_rules: (state.rules || []).slice(),
      network_cidr: state.network_cidr,
      detected_lan_cidr: state.detected_lan_cidr,
      gateway_ip: state.gateway_ip || '',
      dhcp_pool_start: state.dhcp_pool_start || '',
      dhcp_pool_end: state.dhcp_pool_end || '',
      groups: state.groups || [],
      manual_network: !!state.manual_network,
      start_ip: state.start_ip,
      next_ip: state.next_ip || '',
      version: state.version || 'dev',
      architecture: state.architecture || 'unknown',
      detection_source: state.detection_source,
      detection_error: state.detection_error
    };
    recalculateNextIp(draft);
    return draft;
  }

  function saveDraft(draft) {
    recalculateNextIp(draft);
    sessionStorage.setItem(STORAGE_KEY, JSON.stringify(draft));
  }

  function clearDraft() { sessionStorage.removeItem(STORAGE_KEY); }

  function loadDraft() {
    return get(urls.state).then(function(state) {
      if (!state.ok) throw new Error(state.error + (state.details ? '\n' + state.details : ''));
      var stored = null;
      try { stored = JSON.parse(sessionStorage.getItem(STORAGE_KEY) || 'null'); } catch (_) { stored = null; }
      if (stored && stored.schema === 3 && stored.source_sha256 === state.source_sha256) {
        stored.version = state.version || stored.version;
        stored.architecture = state.architecture || stored.architecture || 'unknown';
        stored.detected_lan_cidr = state.detected_lan_cidr;
        stored.gateway_ip = state.gateway_ip || '';
        stored.dhcp_pool_start = state.dhcp_pool_start || '';
        stored.dhcp_pool_end = state.dhcp_pool_end || '';
        stored.groups = state.groups || [];
        stored.detection_source = state.detection_source;
        stored.detection_error = state.detection_error;
        if (!stored.manual_network) {
          stored.network_cidr = state.network_cidr;
          stored.start_ip = state.start_ip;
        }
        recalculateNextIp(stored);
        return stored;
      }
      var draft = fromState(state);
      saveDraft(draft);
      return draft;
    });
  }

  function esc(value) {
    return String(value == null ? '' : value).replace(/[&<>"']/g, function(character) {
      return {'&':'&amp;', '<':'&lt;', '>':'&gt;', '"':'&quot;', "'":'&#39;'}[character];
    });
  }

  global.OpenClashEditor = {
    configure: configure, get: get, post: post,
    loadDraft: loadDraft, saveDraft: saveDraft, clearDraft: clearDraft,
    recalculateNextIp: recalculateNextIp,
    ipToInt: ipToInt, intToIp: intToIp, cidrInfo: cidrInfo,
    ruleParts: ruleParts, numberNodes: numberNodes,
    countryTag: countryTag, airportGroupName: airportGroupName, buildAirportGroups: buildAirportGroups,
    removeNodes: removeNodes, removeRulesByIps: removeRulesByIps, esc: esc
  };
})(window);
