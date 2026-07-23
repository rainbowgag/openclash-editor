(function(global) {
  'use strict';

  var STORAGE_KEY = 'openclash-editor-draft-v2';
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

  function recalculateNextIp(draft) {
    var info = cidrInfo(draft.network_cidr), start = ipToInt(draft.start_ip);
    if (!info || start === null || start < info.first || start > info.last) { draft.next_ip = ''; return ''; }
    var used = {}, gateway = ipToInt(draft.gateway_ip);
    draft.rules.forEach(function(rule) {
      var value = ipToInt(ruleParts(rule).ip.replace(/\/32$/, ''));
      if (value !== null) used[value] = true;
    });
    while (start <= info.last && (used[start] || start === gateway)) start++;
    draft.next_ip = start <= info.last ? intToIp(start) : '';
    return draft.next_ip;
  }

  function removeNodes(draft, names) {
    var selected = Object.create(null), existing = Object.create(null);
    (names || []).forEach(function(name) { selected[String(name)] = true; });
    draft.nodes.forEach(function(node) {
      if (selected[node.name]) existing[node.name] = true;
    });
    var nodeCount = Object.keys(existing).length, beforeRules = draft.rules.length;
    draft.nodes = draft.nodes.filter(function(node) { return !existing[node.name]; });
    draft.rules = draft.rules.filter(function(rule) { return !existing[ruleParts(rule).name]; });
    draft.selected_node_names = (draft.selected_node_names || []).filter(function(name) { return !existing[name]; });
    recalculateNextIp(draft);
    return {nodes: nodeCount, rules: beforeRules - draft.rules.length};
  }

  function removeRulesByIps(draft, ips) {
    var selected = Object.create(null);
    (ips || []).forEach(function(ip) { selected[String(ip)] = true; });
    var before = draft.rules.length;
    draft.rules = draft.rules.filter(function(rule) { return !selected[ruleParts(rule).ip]; });
    recalculateNextIp(draft);
    return before - draft.rules.length;
  }

  function fromState(state) {
    var draft = {
      schema: 2,
      source_sha256: state.source_sha256,
      nodes: state.nodes || [], rules: state.rules || [],
      existing_node_names: (state.nodes || []).map(function(node) { return node.name; }),
      existing_rules: (state.rules || []).slice(),
      network_cidr: state.network_cidr,
      detected_lan_cidr: state.detected_lan_cidr,
      gateway_ip: state.gateway_ip || '',
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
      if (stored && stored.schema === 2 && stored.source_sha256 === state.source_sha256) {
        stored.version = state.version || stored.version;
        stored.architecture = state.architecture || stored.architecture || 'unknown';
        stored.detected_lan_cidr = state.detected_lan_cidr;
        stored.gateway_ip = state.gateway_ip || '';
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
    removeNodes: removeNodes, removeRulesByIps: removeRulesByIps, esc: esc
  };
})(window);
