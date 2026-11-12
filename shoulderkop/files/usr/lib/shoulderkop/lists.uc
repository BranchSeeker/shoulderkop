// lists.uc — локальный кэш белых списков РКН для LTE-режима.
//
// В LTE podkop кладёт в skop_lte_direct две remote-ссылки (.srs на GitHub).
// Когда провайдер режет GitHub, а туннель ещё не поднялся, podkop не может
// собрать конфиг. Поэтому списки скачиваются заранее (при живой подписке),
// распаковываются в обычные текстовые списки и podkop получает локальные пути
// (local_domain_lists / local_subnet_lists) — без сети при каждом reload.
//
// Если скачать/распаковать не удалось, ничего не меняем: apply продолжит
// использовать remote-ссылки, как раньше.

'use strict';

let fs = require("fs");
let fetchmod = require("fetch");

const DIR = "/etc/shoulderkop/lists";
const GEOSITE_TXT = DIR + "/geosite.txt";
const GEOIP_TXT = DIR + "/geoip.txt";
const META = DIR + "/meta.json";
const SRS_DOMAIN = DIR + "/geosite.srs";
const SRS_SUBNET = DIR + "/geoip.srs";

const GEOSITE_SRS = "https://github.com/BranchSeeker/rkn-whitelist-srs/releases/latest/download/geosite.srs";
const GEOIP_SRS = "https://github.com/BranchSeeker/rkn-whitelist-srs/releases/latest/download/geoip.srs";

// запасной источник, если sing-box не умеет rule-set decompile
const PLAIN_GEOSITE = "https://raw.githubusercontent.com/hydraponique/roscomvpn-geosite/master/data/whitelist";
const PLAIN_GEOIP = "https://raw.githubusercontent.com/hydraponique/roscomvpn-geoip/release/text/whitelist.txt";

const TTL = 24 * 3600;
const UA = "shoulderkop/0.5";

let seq = 0;

function own_pid() {
	let s = fs.readfile("/proc/self/stat");
	if (s == null || s == "")
		return "" + time();
	let sp = index(s, " ");
	return (sp > 0) ? substr(s, 0, sp) : "" + time();
}

function sh(cmd) {
	seq++;
	let tmp = "/tmp/.shoulderkop.lists." + own_pid() + "." + seq;
	system(cmd + " > " + tmp + " 2>/dev/null");
	let out = fs.readfile(tmp);
	fs.unlink(tmp);
	return (out == null) ? "" : out;
}

function quiet(cmd) {
	system(cmd + " >/dev/null 2>&1");
}

function file_size(path) {
	let st = fs.stat(path);
	if (st == null || st.size == null)
		return 0;
	return int(st.size);
}

function ensure_dir() {
	quiet("mkdir -p " + DIR);
}

function read_meta() {
	let raw = fs.readfile(META);
	if (raw == null || raw == "")
		return {};
	try {
		let m = json(raw);
		return (type(m) == "object") ? m : {};
	} catch (e) {
		return {};
	}
}

function write_atomic(path, text) {
	let tmp = path + ".tmp." + own_pid();
	if (fs.writefile(tmp, text) == false)
		return false;
	return fs.rename(tmp, path) != false;
}

// uhttpd уже слушает LuCI. Отдаём кэш .srs с 127.0.0.1:80, чтобы podkop
// скачивал бинарный rule-set локально, а не разбирал 6700 подсетей в plain
// (это занимает минуты на каждом reload).
function uhttpd_port() {
	let listen = trim(sh("uci -q get uhttpd.main.listen_http 2>/dev/null"));
	if (listen == "")
		return 0;
	let first = split(listen, " ")[0];
	let colon = rindex(first, ":");
	if (colon < 0)
		return int(first);
	return int(substr(first, colon + 1));
}

function www_root() {
	let h = trim(sh("uci -q get uhttpd.main.home 2>/dev/null"));
	return (h != "") ? h : "/www";
}

function publish_http() {
	let root = www_root();
	if (fs.stat("/etc/init.d/uhttpd") == null || fs.stat(root) == null)
		return null;

	let d = file_size(SRS_DOMAIN) > 0;
	let s = file_size(SRS_SUBNET) > 0;
	if (!d && !s)
		return null;

	let dir = root + "/shoulderkop-lists";
	quiet("mkdir -p " + dir);
	if (d)
		quiet("cp -f " + SRS_DOMAIN + " " + dir + "/geosite.srs");
	if (s)
		quiet("cp -f " + SRS_SUBNET + " " + dir + "/geoip.srs");

	let port = uhttpd_port();
	if (port <= 0)
		port = 80;
	let base = "http://127.0.0.1" + ((port == 80) ? "" : ":" + port) + "/shoulderkop-lists";
	let probe = (d ? "/geosite.srs" : "/geoip.srs");
	let code = trim(sh("curl -s -m 3 -o /dev/null -w '%{http_code}' '" + base + probe + "'"));
	if (code != "200")
		return null;

	return {
		domain: d ? (base + "/geosite.srs") : null,
		subnet: s ? (base + "/geoip.srs") : null,
		port: port
	};
}

function local_files() {
	let meta = read_meta();
	let d = file_size(GEOSITE_TXT);
	let s = file_size(GEOIP_TXT);
	let sd = file_size(SRS_DOMAIN);
	let ss = file_size(SRS_SUBNET);
	return {
		domain: (d > 0) ? GEOSITE_TXT : null,
		subnet: (s > 0) ? GEOIP_TXT : null,
		http_domain: (sd > 0 && meta.http_domain != null) ? "" + meta.http_domain : null,
		http_subnet: (ss > 0 && meta.http_subnet != null) ? "" + meta.http_subnet : null,
		domain_size: d,
		subnet_size: s,
		domain_count: int("" + (meta.domain_count || 0)),
		subnet_count: int("" + (meta.subnet_count || 0)),
		updated: int("" + (meta.updated || 0)),
		source: "" + (meta.source || "")
	};
}

function valid_domain(v) {
	v = trim("" + (v == null ? "" : v));
	if (v == "" || length(v) > 253)
		return false;
	if (index(v, " ") >= 0 || index(v, "/") >= 0 || index(v, ":") >= 0)
		return false;
	if (index(v, ".") < 0)
		return false;
	for (let i = 0; i < length(v); i++) {
		let c = ord(substr(v, i, 1));
		let ok = (c >= 0x41 && c <= 0x5a) || (c >= 0x61 && c <= 0x7a) ||
			(c >= 0x30 && c <= 0x39) || c == 0x2d || c == 0x2e || c == 0x5f;
		if (!ok)
			return false;
	}
	return true;
}

function valid_cidr(v) {
	v = trim("" + (v == null ? "" : v));
	let slash = index(v, "/");
	if (slash < 0)
		return fetchmod.is_ipv4(v);
	let base = substr(v, 0, slash);
	let pfx = substr(v, slash + 1);
	if (!fetchmod.is_ipv4(base) || pfx == "")
		return false;
	for (let i = 0; i < length(pfx); i++) {
		let c = ord(substr(pfx, i, 1));
		if (c < 0x30 || c > 0x39)
			return false;
	}
	let n = int(pfx);
	return (n >= 0 && n <= 32);
}

function add_unique(list, seen, v) {
	if (seen[v])
		return false;
	seen[v] = true;
	push(list, v);
	return true;
}

// .srs → JSON (sing-box rule-set decompile)
function decompile(srs, jsonpath) {
	quiet("rm -f '" + jsonpath + "'");
	quiet("sing-box rule-set decompile '" + srs + "' -o '" + jsonpath + "' 2>/dev/null");
	return file_size(jsonpath) > 0;
}

function extract_domains(jsonpath) {
	let raw = fs.readfile(jsonpath);
	if (raw == null || raw == "")
		return { lines: [], skipped: 0 };
	let doc = null;
	try { doc = json(raw); } catch (e) { return { lines: [], skipped: 0 }; }
	if (type(doc) != "object" || type(doc.rules) != "array")
		return { lines: [], skipped: 0 };

	let lines = [];
	let seen = {};
	let skipped = 0;

	function add(k) {
		if (k == null)
			return;
		if (type(k) == "array") {
			for (let x in k)
				add(x);
			return;
		}
		let v = trim("" + k);
		if (!valid_domain(v)) {
			skipped++;
			return;
		}
		add_unique(lines, seen, v);
	}

	for (let r in doc.rules) {
		if (type(r) != "object")
			continue;
		add(r.domain_suffix);
		add(r.domain);
		// keyword/regex в локальный plain-список podkop не переносятся
		for (let key in [ "domain_keyword", "domain_regex" ]) {
			let v = r[key];
			if (type(v) == "array")
				skipped += length(v);
			else if (v != null)
				skipped++;
		}
	}
	return { lines: lines, skipped: skipped };
}

function extract_subnets(jsonpath) {
	let raw = fs.readfile(jsonpath);
	if (raw == null || raw == "")
		return { lines: [], skipped: 0 };
	let doc = null;
	try { doc = json(raw); } catch (e) { return { lines: [], skipped: 0 }; }
	if (type(doc) != "object" || type(doc.rules) != "array")
		return { lines: [], skipped: 0 };

	let lines = [];
	let seen = {};
	let skipped = 0;
	for (let r in doc.rules) {
		if (type(r) != "object" || type(r.ip_cidr) != "array")
			continue;
		for (let c in r.ip_cidr) {
			let v = trim("" + c);
			if (!valid_cidr(v)) {
				skipped++;
				continue;
			}
			add_unique(lines, seen, v);
		}
	}
	return { lines: lines, skipped: skipped };
}

function parse_plain_domains(text) {
	let lines = [];
	let seen = {};
	let skipped = 0;
	for (let line in split("" + (text == null ? "" : text), "\n")) {
		line = trim(line);
		if (line == "" || substr(line, 0, 1) == "#")
			continue;
		let low = lc(line);
		let v = line;
		if (substr(low, 0, 7) == "domain:") {
			v = substr(line, 7);
		} else if (substr(low, 0, 5) == "full:") {
			v = substr(line, 5);
		} else if (substr(low, 0, 8) == "keyword:" || substr(low, 0, 7) == "regexp:" ||
			   substr(low, 0, 8) == "include:" || index(line, ":") >= 0) {
			skipped++;
			continue;
		}
		v = trim(v);
		if (!valid_domain(v)) {
			skipped++;
			continue;
		}
		add_unique(lines, seen, v);
	}
	return { lines: lines, skipped: skipped };
}

function parse_plain_subnets(text) {
	let lines = [];
	let seen = {};
	let skipped = 0;
	for (let line in split("" + (text == null ? "" : text), "\n")) {
		line = trim(line);
		if (line == "" || substr(line, 0, 1) == "#")
			continue;
		if (!valid_cidr(line)) {
			skipped++;
			continue;
		}
		add_unique(lines, seen, line);
	}
	return { lines: lines, skipped: skipped };
}

function write_lines(path, lines) {
	if (length(lines) == 0)
		return false;
	lines = sort(lines);
	return write_atomic(path, join("\n", lines) + "\n");
}

// force = игнорировать TTL
function sync(force) {
	ensure_dir();

	let now = time();
	let meta = read_meta();
	let cur = local_files();

	// даже при свежем TTL освежаем локальный HTTP-кэш: podkop не должен
	// разбирать plain-списки, если можно отдать бинарный .srs
	let http_ready = (cur.http_domain != null && cur.http_subnet != null);
	if (!force && meta.updated != null && now - int("" + (meta.updated || 0)) < TTL &&
	    (http_ready || (cur.domain != null && cur.subnet != null))) {
		let hp0 = publish_http();
		if (hp0 != null) {
			if (meta.http_domain != hp0.domain || meta.http_subnet != hp0.subnet) {
				meta.http_domain = hp0.domain;
				meta.http_subnet = hp0.subnet;
				write_atomic(META, sprintf("%J", meta));
			}
			return {
				ok: true, skipped: true, source: "http",
				domain_count: cur.domain_count, subnet_count: cur.subnet_count,
				updated: cur.updated, http_domain: hp0.domain,
				http_subnet: hp0.subnet, errors: []
			};
		}
		return {
			ok: true, skipped: true,
			source: (cur.domain != null) ? "plain" : cur.source,
			domain_count: cur.domain_count, subnet_count: cur.subnet_count,
			updated: cur.updated, http_domain: null, http_subnet: null,
			errors: []
		};
	}

	let errors = [];
	let dom = { lines: [], skipped: 0 };
	let sub = { lines: [], skipped: 0 };
	let source = "srs";

	// Недавняя неудача: не долбим GitHub на каждом обновлении подписки
	if (!force && meta.last_error != null && now - int("" + meta.last_error) < 1800 &&
	    (cur.domain == null || cur.subnet == null)) {
		let hp1 = publish_http();
		return {
			ok: (hp1 != null), skipped: true,
			source: (hp1 != null) ? "http" : cur.source,
			domain_count: cur.domain_count, subnet_count: cur.subnet_count,
			updated: cur.updated,
			http_domain: (hp1 != null) ? hp1.domain : null,
			http_subnet: (hp1 != null) ? hp1.subnet : null,
			errors: [ "recent failure" ]
		};
	}

	let dsrs = "/tmp/shoulderkop.geosite.srs";
	let gsrs = "/tmp/shoulderkop.geoip.srs";
	let djson = "/tmp/shoulderkop.geosite.json";
	let gjson = "/tmp/shoulderkop.geoip.json";

	let dr = fetchmod.fetch_to_file(GEOSITE_SRS, dsrs, { ua: UA, fast: true, proxy: true });
	let gr = fetchmod.fetch_to_file(GEOIP_SRS, gsrs, { ua: UA, fast: true, proxy: true });
	if (!dr.ok)
		errors.push("geosite.srs: HTTP " + dr.http + " (" + dr.via + ")");
	if (!gr.ok)
		errors.push("geoip.srs: HTTP " + gr.http + " (" + gr.via + ")");

	// бинарные .srs кладём на диск: их отдаёт локальный uhttpd
	if (dr.ok)
		quiet("cp -f " + dsrs + " " + SRS_DOMAIN);
	if (gr.ok)
		quiet("cp -f " + gsrs + " " + SRS_SUBNET);

	let d_ok = dr.ok && decompile(dsrs, djson);
	let g_ok = gr.ok && decompile(gsrs, gjson);
	if (d_ok)
		dom = extract_domains(djson);
	if (g_ok)
		sub = extract_subnets(gjson);

	// sing-box может быть старой сборкой без rule-set decompile — берём
	// исходные plain-списки (они и есть вход .srs)
	if (length(dom.lines) == 0 || length(sub.lines) == 0) {
		source = "plain";
		if (length(dom.lines) == 0) {
			let p = "/tmp/shoulderkop.geosite.plain";
			let r = fetchmod.fetch_to_file(PLAIN_GEOSITE, p, { ua: UA, fast: true, proxy: true });
			if (r.ok)
				dom = parse_plain_domains(fs.readfile(p));
			else
				errors.push("geosite plain: HTTP " + r.http);
		}
		if (length(sub.lines) == 0) {
			let p = "/tmp/shoulderkop.geoip.plain";
			let r = fetchmod.fetch_to_file(PLAIN_GEOIP, p, { ua: UA, fast: true, proxy: true });
			if (r.ok)
				sub = parse_plain_subnets(fs.readfile(p));
			else
				errors.push("geoip plain: HTTP " + r.http);
		}
	}

	let dom_written = false;
	let sub_written = false;
	if (length(dom.lines) > 0)
		dom_written = write_lines(GEOSITE_TXT, dom.lines);
	else if (cur.domain == null)
		errors.push("geosite: no usable entries");
	if (length(sub.lines) > 0)
		sub_written = write_lines(GEOIP_TXT, sub.lines);
	else if (cur.subnet == null)
		errors.push("geoip: no usable entries");

	let hp = publish_http();
	if (hp != null)
		source = "http";
	let http_ok = (hp != null);
	let written = dom_written || sub_written || dr.ok || gr.ok;
	let dcount = dom_written ? length(dom.lines) : cur.domain_count;
	let scount = sub_written ? length(sub.lines) : cur.subnet_count;
	let ok = http_ok || ((dom_written || cur.domain != null) && (sub_written || cur.subnet != null));
	let result = {
		ok: ok,
		skipped: false,
		source: source,
		domain_count: dcount,
		subnet_count: scount,
		domain_skipped: dom.skipped,
		subnet_skipped: sub.skipped,
		updated: written ? now : int("" + (meta.updated || 0)),
		http_domain: hp ? hp.domain : null,
		http_subnet: hp ? hp.subnet : null,
		errors: errors
	};

	// мета пишется и при неудаче: last_error не даёт дёргать сеть каждый запуск
	let m = {
		updated: result.updated,
		domain_count: dcount,
		subnet_count: scount,
		source: source,
		http_domain: result.http_domain,
		http_subnet: result.http_subnet,
		errors: errors
	};
	if (!written)
		m.last_error = now;
	write_atomic(META, sprintf("%J", m));

	quiet("rm -f " + dsrs + " " + gsrs + " " + djson + " " + gjson +
		" /tmp/shoulderkop.geosite.plain /tmp/shoulderkop.geoip.plain");

	return result;
}

function status() {
	let lf = local_files();
	return {
		domain: lf.domain,
		subnet: lf.subnet,
		http_domain: lf.http_domain,
		http_subnet: lf.http_subnet,
		domain_count: lf.domain_count,
		subnet_count: lf.subnet_count,
		updated: lf.updated,
		source: lf.source,
		dir: DIR
	};
}

return {
	sync: sync,
	status: status,
	local_files: local_files,
	http_urls: publish_http
};
