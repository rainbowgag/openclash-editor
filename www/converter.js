(function(global) {
  'use strict';

  function decode(value) {
    try { return decodeURIComponent((value || '').replace(/\+/g, '%20')); }
    catch (_) { return value || ''; }
  }

  function hostPort(value, fallback) {
    var server = '', port = fallback || 443;
    if (value.charAt(0) === '[') {
      var end = value.indexOf(']');
      if (end < 0) throw new Error('IPv6 地址格式错误');
      server = value.slice(1, end);
      if (value.slice(end + 1).charAt(0) === ':') port = Number(value.slice(end + 2)) || port;
    } else {
      var colon = value.lastIndexOf(':');
      if (colon < 0) server = value;
      else { server = value.slice(0, colon); port = Number(value.slice(colon + 1)) || port; }
    }
    return { server: decode(server), port: port };
  }

  function network(value) {
    var type = (value || '').toLowerCase();
    if (!type) return 'tcp';
    if (type === 'websocket') return 'ws';
    return type;
  }

  function bool(value, fallback) {
    if (value === null || value === undefined || value === '') return !!fallback;
    return ['1', 'true', 'yes'].indexOf(String(value).toLowerCase()) >= 0;
  }

  function splitLink(link, scheme) {
    var body = link.trim().slice(scheme.length);
    var hash = body.indexOf('#');
    var name = hash >= 0 ? decode(body.slice(hash + 1)) : '';
    if (hash >= 0) body = body.slice(0, hash);
    var qm = body.indexOf('?');
    return {
      authority: qm >= 0 ? body.slice(0, qm) : body,
      params: new URLSearchParams(qm >= 0 ? body.slice(qm + 1) : ''),
      name: name
    };
  }

  function parseVless(link, dialer) {
    var part = splitLink(link, 'vless://');
    var at = part.authority.lastIndexOf('@');
    if (at <= 0) throw new Error('缺少 UUID 或服务器');
    var uuid = decode(part.authority.slice(0, at));
    var hp = hostPort(part.authority.slice(at + 1), 443);
    var p = part.params, type = network(p.get('type'));
    var security = (p.get('security') || '').toLowerCase();
    var sni = p.get('sni') || p.get('servername') || '';
    var fp = p.get('fp') || p.get('fingerprint') || '';
    var node = { name: part.name || hp.server, type: 'vless', server: hp.server, port: hp.port, uuid: uuid, udp: true, network: type };
    if (p.get('flow')) node.flow = p.get('flow');
    if (security === 'tls' || security === 'reality') node.tls = true;
    if (sni || security === 'reality') node.servername = sni || hp.server;
    if (fp) node['client-fingerprint'] = fp;
    var alpn = p.get('alpn');
    if (alpn) node.alpn = alpn.split(',').map(function(v) { return v.trim(); }).filter(Boolean);
    if (security === 'reality') {
      var reality = {};
      var pbk = p.get('pbk') || p.get('publicKey');
      var sid = p.get('sid') || p.get('shortId');
      var spx = decode(p.get('spx') || p.get('spiderX') || '');
      if (pbk) reality['public-key'] = pbk;
      if (sid) reality['short-id'] = sid;
      if (spx) reality['spider-x'] = spx;
      if (Object.keys(reality).length) node['reality-opts'] = reality;
    }
    if (type === 'ws') {
      node['ws-opts'] = { path: decode(p.get('path') || '/') };
      var host = p.get('host') || sni;
      if (host) node['ws-opts'].headers = { Host: host };
    }
    if (type === 'grpc') {
      var service = decode(p.get('serviceName') || '');
      node['grpc-opts'] = {};
      if (service) node['grpc-opts']['grpc-service-name'] = service;
    }
    var header = p.get('headerType');
    if (type === 'tcp' && header && header !== 'none') node['tcp-opts'] = { header: { type: header } };
    if (dialer) node['dialer-proxy'] = dialer;
    return node;
  }

  function base64Json(value) {
    var payload = String(value || '').replace(/-/g, '+').replace(/_/g, '/');
    while (payload.length % 4) payload += '=';
    try {
      var binary = atob(payload);
      var bytes = Uint8Array.from(binary, function(ch) { return ch.charCodeAt(0); });
      return JSON.parse(new TextDecoder('utf-8').decode(bytes));
    } catch (_) { throw new Error('VMess 内容不是有效的 Base64 JSON'); }
  }

  function parseVmess(link, dialer) {
    var data = base64Json(link.trim().slice('vmess://'.length));
    var server = String(data.add || data.server || '').trim();
    var uuid = String(data.id || data.uuid || '').trim();
    if (!server || !uuid) throw new Error('缺少服务器或 UUID');
    var type = network(data.net || 'tcp');
    var node = {
      name: String(data.ps || data.name || server), type: 'vmess', server: server,
      port: Number(data.port) || 443, uuid: uuid, alterId: Number(data.aid) || 0,
      cipher: data.scy || data.cipher || 'auto', udp: true, network: type
    };
    var tls = String(data.tls || '').toLowerCase();
    if (tls === 'tls' || tls === 'true' || tls === '1') node.tls = true;
    var sni = String(data.sni || data.servername || '').trim();
    if (sni) node.servername = sni;
    var fp = String(data.fp || data.fingerprint || '').trim();
    if (fp) node['client-fingerprint'] = fp;
    if (data.alpn) node.alpn = String(data.alpn).split(',').map(function(v) { return v.trim(); }).filter(Boolean);
    if (type === 'ws') {
      node['ws-opts'] = { path: decode(data.path || '/') };
      if (data.host) node['ws-opts'].headers = { Host: String(data.host) };
    }
    if (type === 'tcp' && data.type && data.type !== 'none') {
      node['tcp-opts'] = { header: { type: data.type } };
    }
    if (dialer) node['dialer-proxy'] = dialer;
    return node;
  }

  function parseHy2(link, dialer) {
    var lower = link.toLowerCase();
    var scheme = lower.indexOf('hysteria2://') === 0 ? 'hysteria2://' : 'hy2://';
    var part = splitLink(link, scheme);
    var at = part.authority.lastIndexOf('@');
    if (at <= 0) throw new Error('缺少密码或服务器');
    var password = decode(part.authority.slice(0, at));
    var hp = hostPort(part.authority.slice(at + 1), 443), p = part.params;
    var node = { name: part.name || hp.server, type: 'hysteria2', server: hp.server, port: hp.port, password: password };
    var alpn = p.get('alpn');
    if (alpn) node.alpn = alpn.split(',').map(function(v) { return v.trim(); }).filter(Boolean);
    if (p.get('obfs')) node.obfs = p.get('obfs');
    var obfsPassword = p.get('obfs-password') || p.get('obfs_password');
    if (obfsPassword) node['obfs-password'] = obfsPassword;
    node['skip-cert-verify'] = bool(p.get('insecure') || p.get('skip-cert-verify'), false);
    var sni = p.get('sni') || p.get('servername');
    if (sni) node.sni = sni;
    if (dialer) node['dialer-proxy'] = dialer;
    return node;
  }

  function parse(link, dialer) {
    var lower = link.toLowerCase();
    if (lower.indexOf('vless://') === 0) return parseVless(link, dialer);
    if (lower.indexOf('vmess://') === 0) return parseVmess(link, dialer);
    if (lower.indexOf('hysteria2://') === 0 || lower.indexOf('hy2://') === 0) return parseHy2(link, dialer);
    throw new Error('仅支持 vless://、vmess://、hysteria2:// 或 hy2://');
  }

  function convert(text, dialer) {
    var nodes = [], errors = [];
    String(text || '').split(/\r?\n/).map(function(v) { return v.trim(); }).filter(Boolean).forEach(function(line, index) {
      try { nodes.push(parse(line, String(dialer || '').trim())); }
      catch (error) { errors.push('第 ' + (index + 1) + ' 行：' + error.message); }
    });
    return { nodes: nodes, errors: errors };
  }

  global.OpenClashConverter = { convert: convert };
})(window);
