// fetch.uc — HTTP-загрузка с запасным «прямым» путём.
//
// Зачем: когда podkop поднят, но все серверы мертвы, обычный curl с роутера
// может не работать — DNS уходит в мёртвый sing-box, а трафик к IP подписки
// помечается в nft и уходит в тот же мёртвый tproxy. Тогда подписка не
// обновляется, хотя интернет через WAN есть.
//
// Прямой путь:
//   1. берём WAN-интерфейс/адрес и DNS провайдера из ubus (не 127.0.0.1);
//   2. временно добавляем IP DNS и IP подписки в nft-набор localv4 podkop —
//      правило `mangle_output ip daddr @localv4 return` стоит до установки
//      метки, поэтому такой трафик идёт напрямую;
//   3. резолвим имя через DNS провайдера и просим curl `--resolve`.
// После запроса набор чистится. Если podkop не установлен/не запущен, шаг 2
// просто ничего не делает.
//
// Порядок попыток: обычный короткий запрос → прямой → обычный длинный.
// Так здоровый роутер не платит за прямой путь, а мёртвый туннель получает
// шанс восстановиться.

'use strict';

let fs = require("fs");

const CONNECT_TIMEOUT = 4;
const PUBLIC_DNS = [ "77.88.8.8", "8.8.8.8", "1.1.1.1" ];

let seq = 0;

function own_pid() {
	let s = fs.readfile("/proc/self/stat");
	if (s == null || s == "")
		return "" + time();
	let sp = index(s, " ");
	return (sp > 0) ? substr(s, 0, sp) : "" + time();
}

// system() не отдаёт stdout в этой сборке ucode — пишем в файл и читаем
function sh(cmd) {
	seq++;
	let tmp = "/tmp/.shoulderkop.net." + own_pid() + "." + seq;
	system(cmd + " > " + tmp + " 2>/dev/null");
	let out = fs.readfile(tmp);
	fs.unlink(tmp);
	return (out == null) ? "" : out;
}

function quiet(cmd) {
	system(cmd + " >/dev/null 2>&1");
}

function is_ipv4(s) {
	let p = split("" + s, ".");
	if (length(p) != 4)
		return false;
	for (let x in p) {
		x = trim(x);
		if (x == "" || length(x) > 3)
			return false;
		for (let i = 0; i < length(x); i++) {
			let c = ord(substr(x, i, 1));
			if (c < 0x30 || c > 0x39)
				return false;
		}
		let n = int(x);
		if (n < 0 || n > 255)
			return false;
	}
	return true;
}

// приватные адреса уже покрыты localv4; добавлять/удалять их нельзя —
// удаление адреса из диапазона разрезает диапазон и оставляет дыру
function is_private_ipv4(s) {
	let p = split("" + s, ".");
	if (length(p) != 4)
		return false;
	let a = int(p[0]), b = int(p[1]);
	if (a == 0 || a == 10 || a == 127)
		return true;
	if (a == 169 && b == 254)
		return true;
	if (a == 172 && b >= 16 && b <= 31)
		return true;
	if (a == 192 && b == 168)
		return true;
	return false;
}

function uniq(list) {
	let out = [];
	let seen = {};
	for (let v in list) {
		v = trim("" + v);
		if (v == "" || seen[v])
			continue;
		seen[v] = true;
		push(out, v);
	}
	return out;
}

// ---- WAN и DNS -------------------------------------------------------------

function parse_nameservers(text) {
	let out = [];
	for (let line in split("" + (text == null ? "" : text), "\n")) {
		line = trim(line);
		if (substr(lc(line), 0, 10) != "nameserver")
			continue;
		let v = trim(substr(line, 10));
		if (v == "" || v == "127.0.0.1" || v == "::1")
			continue;
		push(out, v);
	}
	return out;
}

// { device, src, dns: [...] }
function wan_info() {
	let st = null;
	let raw = trim(sh("ubus call network.interface.wan status 2>/dev/null"));
	if (raw != "") {
		try { st = json(raw); } catch (e) { st = null; }
	}

	let info = { device: "", src: "", dns: [] };

	// default route: самый надёжный источник dev/src, даже если интерфейс
	// называется не wan (wwan, pppoe-wan и т.п.)
	let route = trim(sh("ip route get 1.1.1.1 2>/dev/null"));
	let parts = split(route, " ");
	for (let i = 0; i < length(parts); i++) {
		if (parts[i] == "dev" && i + 1 < length(parts) && info.device == "")
			info.device = parts[i + 1];
		else if (parts[i] == "src" && i + 1 < length(parts) && info.src == "")
			info.src = parts[i + 1];
	}

	if (st != null) {
		if (info.device == "")
			info.device = "" + (st["l3_device"] || st.device || "");
		let addrs = st["ipv4-address"];
		if (info.src == "" && type(addrs) == "array" && length(addrs) > 0)
			info.src = "" + (addrs[0].address || "");
		let dns = st["dns-server"];
		if (type(dns) == "array")
			for (let d in dns)
				push(info.dns, "" + d);
	}

	if (length(info.dns) == 0)
		info.dns = parse_nameservers(fs.readfile("/tmp/resolv.conf.d/resolv.conf.auto"));
	if (length(info.dns) == 0)
		info.dns = parse_nameservers(fs.readfile("/etc/resolv.conf"));

	info.dns = uniq(info.dns);
	return info;
}

function resolve_via(host, server) {
	let out = sh("nslookup " + host + " " + server + " 2>/dev/null");
	for (let line in split(out, "\n")) {
		line = trim(line);
		let low = lc(line);
		if (substr(low, 0, 7) != "address")
			continue;
		let colon = index(line, ":");
		if (colon < 0)
			continue;
		let v = trim(substr(line, colon + 1));
		let sp = index(v, " ");
		if (sp > 0)
			v = substr(v, 0, sp);
		if (v == server || !is_ipv4(v))
			continue;
		return v;
	}
	return "";
}

function resolve(host) {
	host = trim("" + (host == null ? "" : host));
	if (is_ipv4(host))
		return host;

	let info = wan_info();
	let servers = uniq(info.dns);
	for (let d in PUBLIC_DNS)
		push(servers, d);
	servers = uniq(servers);

	for (let s in servers) {
		if (!is_ipv4(s))
			continue;
		let ip = resolve_via(host, s);
		if (ip != "")
			return ip;
	}
	return "";
}

// ---- nft-обход podkop ------------------------------------------------------

function podkop_table() {
	return trim(sh("nft list table inet PodkopTable 2>/dev/null")) != "";
}

function nft_bypass(ips, add) {
	ips = uniq(ips);
	if (length(ips) == 0 || !podkop_table())
		return;
	for (let ip in ips) {
		if (!is_ipv4(ip) || is_private_ipv4(ip))
			continue;
		if (add)
			quiet("nft add element inet PodkopTable localv4 { " + ip + " }");
		else
			quiet("nft delete element inet PodkopTable localv4 { " + ip + " }");
	}
}

// ---- URL ------------------------------------------------------------------

// https://host:443/path?x=1#frag → { scheme, host, port }
function url_parts(url) {
	let s = trim("" + (url == null ? "" : url));
	let sep = index(s, "://");
	if (sep <= 0)
		return null;
	let scheme = lc(substr(s, 0, sep));
	let rest = substr(s, sep + 3);
	let h = index(rest, "#");
	if (h >= 0)
		rest = substr(rest, 0, h);
	let q = index(rest, "?");
	if (q >= 0)
		rest = substr(rest, 0, q);
	let slash = index(rest, "/");
	let auth = (slash >= 0) ? substr(rest, 0, slash) : rest;
	let at = rindex(auth, "@");
	if (at >= 0)
		auth = substr(auth, at + 1);

	let host = auth;
	let port = (scheme == "https") ? 443 : 80;
	if (substr(host, 0, 1) == "[") {
		let rb = index(host, "]");
		if (rb > 0) {
			let tail = substr(host, rb + 1);
			host = substr(host, 1, rb - 1);
			if (substr(tail, 0, 1) == ":")
				port = int(substr(tail, 1));
		}
	} else {
		let c = rindex(host, ":");
		if (c > 0) {
			let p = substr(host, c + 1);
			let ok = length(p) > 0;
			for (let i = 0; i < length(p); i++) {
				let ch = ord(substr(p, i, 1));
				if (ch < 0x30 || ch > 0x39) { ok = false; break; }
			}
			if (ok) {
				port = int(p);
				host = substr(host, 0, c);
			}
		}
	}

	if (host == "")
		return null;
	return { scheme: scheme, host: host, port: port };
}

function hdr_val(v) {
	return trim(replace(replace("" + (v == null ? "" : v), "'", ""), "\n", " "));
}

// один curl-запрос; mode = normal | direct
function attempt(url, opts, mode, timeout) {
	opts = opts || {};
	seq++;
	let base = "/tmp/.shoulderkop.net." + own_pid() + "." + seq;
	let bodyf = base + ".body";
	let headf = base + ".head";

	let extra = "";
	let bypass = [];
	let host = "";
	let ip = "";

	if (mode == "proxy") {
		extra += " --proxy 'http://127.0.0.1:4534'";
	} else if (mode == "direct") {
		let hp = url_parts(url);
		if (hp == null) {
			try { fs.unlink(bodyf); } catch (e) {}
			try { fs.unlink(headf); } catch (e) {}
			return { http: 0, body: "", headers: "", via: "direct" };
		}
		host = hp.host;

		// DNS провайдера должен идти мимо podkop — иначе его же и не резолвим
		let info = wan_info();
		bypass = uniq(info.dns);
		nft_bypass(bypass, true);

		ip = resolve(host);
		if (ip != "") {
			push(bypass, ip);
			nft_bypass([ ip ], true);
			extra += " -4 --resolve '" + host + ":" + hp.port + ":" + ip + "'";
		}

		if (info.src != "")
			extra += " --interface '" + hdr_val(info.src) + "'";
		else if (info.device != "")
			extra += " --interface '" + hdr_val(info.device) + "'";
	}

	let cmd = "curl -s -L -m " + timeout + " --connect-timeout " + CONNECT_TIMEOUT +
		" -A '" + hdr_val(opts.ua || "shoulderkop") + "'";
	for (let h in (opts.headers || []))
		if (hdr_val(h[1]) != "")
			cmd += " -H '" + hdr_val(h[0]) + ": " + hdr_val(h[1]) + "'";
	cmd += extra;
	cmd += " -D " + headf + " -o " + bodyf + " -w '%{http_code}' '" + hdr_val(url) + "'";

	let raw = trim(sh(cmd));
	let http = (raw == "") ? 0 : int(raw);
	let body = fs.readfile(bodyf);
	let head = fs.readfile(headf);

	if (mode == "direct")
		nft_bypass(bypass, false);

	try { fs.unlink(bodyf); } catch (e) {}
	try { fs.unlink(headf); } catch (e) {}

	return {
		http: http,
		body: (body == null) ? "" : body,
		headers: (head == null) ? "" : head,
		via: mode,
		ip: ip
	};
}

// opts: { ua, headers: [[k,v],...] }
function fetch(url, opts) {
	let tries = [
		{ mode: "normal", timeout: 8 },
		{ mode: "direct", timeout: 20 }
	];
	if (opts && opts.proxy)
		push(tries, { mode: "proxy", timeout: 15 });
	push(tries, { mode: "normal", timeout: 25 });

	let last = { http: 0, body: "", headers: "", via: "" };
	for (let t in tries) {
		let r = attempt(url, opts, t.mode, t.timeout);
		if (r.http != 0)
			return r;
		last = r;
	}
	return last;
}

// скачать в файл (пакеты/списки): тело не держим в памяти
function fetch_to_file(url, dest, opts) {
	opts = opts || {};
	let tries = opts.fast ? [
		{ mode: "normal", timeout: 10 },
		{ mode: "direct", timeout: 25 }
	] : [
		{ mode: "normal", timeout: 10 },
		{ mode: "direct", timeout: 90 }
	];
	if (opts.proxy)
		push(tries, { mode: "proxy", timeout: opts.fast ? 20 : 60 });
	push(tries, opts.fast ? { mode: "normal", timeout: 30 } : { mode: "normal", timeout: 120 });

	let last = { ok: false, http: 0, via: "" };
	for (let t in tries) {
		seq++;
		let base = "/tmp/.shoulderkop.net." + own_pid() + "." + seq;
		let bodyf = base + ".body";
		let headf = base + ".head";
		let extra = "";
		let bypass = [];
		let ip = "";

		if (t.mode == "proxy") {
			extra += " --proxy 'http://127.0.0.1:4534'";
		} else if (t.mode == "direct") {
			let hp = url_parts(url);
			if (hp != null) {
				let info = wan_info();
				bypass = uniq(info.dns);
				nft_bypass(bypass, true);
				ip = resolve(hp.host);
				if (ip != "") {
					push(bypass, ip);
					nft_bypass([ ip ], true);
					extra += " -4 --resolve '" + hp.host + ":" + hp.port + ":" + ip + "'";
				}
				if (info.src != "")
					extra += " --interface '" + hdr_val(info.src) + "'";
				else if (info.device != "")
					extra += " --interface '" + hdr_val(info.device) + "'";
			}
		}

		let cmd = "curl -s -L -m " + t.timeout + " --connect-timeout " + CONNECT_TIMEOUT +
			" -A '" + hdr_val(opts.ua || "shoulderkop") + "'";
		for (let h in (opts.headers || []))
			if (hdr_val(h[1]) != "")
				cmd += " -H '" + hdr_val(h[0]) + ": " + hdr_val(h[1]) + "'";
		cmd += extra + " -o " + bodyf + " -w '%{http_code}' '" + hdr_val(url) + "'";

		let raw = trim(sh(cmd));
		let http = (raw == "") ? 0 : int(raw);

		if (t.mode == "direct")
			nft_bypass(bypass, false);

		try { fs.unlink(headf); } catch (e) {}
		if (http >= 200 && http < 300) {
			system("mv -f " + bodyf + " '" + hdr_val(dest) + "'");
			return { ok: true, http: http, via: t.mode, ip: ip };
		}
		try { fs.unlink(bodyf); } catch (e) {}
		last = { ok: false, http: http, via: t.mode, ip: ip };
	}
	return last;
}

return {
	fetch: fetch,
	fetch_to_file: fetch_to_file,
	resolve: resolve,
	wan_info: wan_info,
	url_parts: url_parts,
	is_ipv4: is_ipv4
};
