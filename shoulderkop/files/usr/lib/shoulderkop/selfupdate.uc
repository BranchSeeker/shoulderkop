// selfupdate.uc — автообновление пакета shoulderkop с GitHub Releases.
//
// По умолчанию выключено (auto_update=0). Включается галочкой в LuCI; тогда
// cron раз в сутки запускает `shoulderkop self-update --quiet`.
//
// Правила:
//   • ставим только версию новее установленной (--force — переустановить);
//   • скачиваем пакет и luci-app, сверяем SHA256SUMS, если он есть в релизе;
//   • при любой ошибке сети/пакета оставляем рабочую версию и пишем причину;
//   • одновременно может идти только один self-update (lock-файл).

'use strict';

let fs = require("fs");
let uci = require("uci");
let fetchmod = require("fetch");

const REPO = "BranchSeeker/shoulderkop";
const API = "https://api.github.com/repos/" + REPO + "/releases/latest";
const HTML_LATEST = "https://github.com/" + REPO + "/releases/latest";
const UA = "shoulderkop/0.5";
const STATE = "/tmp/shoulderkop.selfupdate.json";
const LOCK = "/tmp/shoulderkop.selfupdate.lock";
const LOG = "/tmp/shoulderkop.selfupdate.log";

// В РФ github.com бывает недоступен целиком (TCP timeout), при этом
// зеркало-прокси вида https://gh-proxy.com/https://github.com/... работает.
// api.github.com зеркала не проксируют (403), поэтому его не трогаем.
let MIRRORS = [ "https://gh-proxy.com/", "https://ghfast.top/", "https://ghproxy.net/" ];

let mirror_used = false;

function mirrorable(url) {
	return (index("" + url, "://github.com/") >= 0) ||
		(index("" + url, "://raw.githubusercontent.com/") >= 0);
}

// запрос с запасным путём через зеркало: только когда прямой путь не дал
// ответа или упал с 5xx (404/403 зеркало всё равно не исправит)
function fetch_any(url, opts) {
	let r = fetchmod.fetch(url, opts);
	if (r.http == 200 || r.http == 403 || r.http == 404 || !mirrorable(url))
		return r;
	if (r.http != 0 && r.http < 500)
		return r;
	for (let m in MIRRORS) {
		let r2 = fetchmod.fetch(m + url, opts);
		if (r2.http == 200) {
			mirror_used = true;
			return r2;
		}
	}
	return r;
}

function fetch_file_any(url, dest, opts) {
	let r = fetchmod.fetch_to_file(url, dest, opts);
	if (r.ok || !mirrorable(url))
		return r;
	if (r.http != 0 && r.http < 500)
		return r;
	for (let m in MIRRORS) {
		let r2 = fetchmod.fetch_to_file(m + url, dest, opts);
		if (r2.ok) {
			mirror_used = true;
			return r2;
		}
	}
	return r;
}

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
	let tmp = "/tmp/.shoulderkop.upd." + own_pid() + "." + seq;
	system(cmd + " > " + tmp + " 2>/dev/null");
	let out = fs.readfile(tmp);
	fs.unlink(tmp);
	return (out == null) ? "" : out;
}

function quiet(cmd) {
	system(cmd + " >/dev/null 2>&1");
}

function read_state() {
	let raw = fs.readfile(STATE);
	if (raw == null || raw == "")
		return null;
	try {
		let s = json(raw);
		return (type(s) == "object") ? s : null;
	} catch (e) {
		return null;
	}
}

function write_state(s) {
	// отметка, что GitHub пришлось тянуть через зеркало — видна в status
	if (mirror_used)
		s.mirror = "yes";
	fs.writefile(STATE, sprintf("%J", s));
}

function cfg_get(name) {
	let c = uci.cursor();
	if (!c.load("shoulderkop"))
		return "";
	let v = c.get("shoulderkop", "settings", name);
	return (v == null) ? "" : "" + v;
}

function pkg_manager() {
	if (trim(sh("command -v apk 2>/dev/null")) != "")
		return "apk";
	if (trim(sh("command -v opkg 2>/dev/null")) != "")
		return "opkg";
	return "";
}

function installed_version() {
	let raw = fs.readfile("/usr/lib/shoulderkop/version");
	if (raw != null && trim(raw) != "") {
		let v = trim(split(trim(raw), "\n")[0]);
		if (v != "")
			return v;
	}

	let mgr = pkg_manager();
	if (mgr == "apk") {
		let out = trim(sh("apk list --installed shoulderkop 2>/dev/null | head -n 1"));
		if (out != "") {
			let first = split(out, " ")[0];
			first = replace(first, "shoulderkop-", "");
			let dash = rindex(first, "-r");
			if (dash > 0)
				first = substr(first, 0, dash);
			return first;
		}
	} else if (mgr == "opkg") {
		let out = trim(sh("opkg status shoulderkop 2>/dev/null | sed -n 's/^Version: //p' | head -n 1"));
		if (out != "") {
			let dash = rindex(out, "-");
			return (dash > 0) ? substr(out, 0, dash) : out;
		}
	}
	return "";
}

function ver_parts(v) {
	let out = [];
	let cur = "";
	v = "" + (v == null ? "" : v);
	for (let i = 0; i < length(v); i++) {
		let c = ord(substr(v, i, 1));
		if (c >= 0x30 && c <= 0x39) {
			cur += substr(v, i, 1);
			continue;
		}
		if (cur != "") {
			push(out, cur);
			cur = "";
		}
	}
	if (cur != "")
		push(out, cur);
	return out;
}

// -1 / 0 / 1
function ver_cmp(a, b) {
	let pa = ver_parts(a);
	let pb = ver_parts(b);
	let n = (length(pa) > length(pb)) ? length(pa) : length(pb);
	for (let i = 0; i < n; i++) {
		let x = (i < length(pa)) ? int(pa[i]) : 0;
		let y = (i < length(pb)) ? int(pb[i]) : 0;
		if (x > y)
			return 1;
		if (x < y)
			return -1;
	}
	return 0;
}

function basename(url) {
	let s = trim("" + (url == null ? "" : url));
	let q = index(s, "?");
	if (q >= 0)
		s = substr(s, 0, q);
	let slash = rindex(s, "/");
	return (slash >= 0) ? substr(s, slash + 1) : s;
}

// [{ name, url, size }]
function release_assets_from_api(doc) {
	let out = [];
	if (type(doc) != "object" || type(doc.assets) != "array")
		return out;
	for (let a in doc.assets) {
		if (type(a) != "object")
			continue;
		let u = "" + (a.browser_download_url || "");
		let n = "" + (a.name || basename(u));
		if (u == "")
			continue;
		push(out, { name: n, url: u, size: int("" + (a.size || 0)) });
	}
	return out;
}

function release_assets_from_html(tag) {
	let url = "https://github.com/" + REPO + "/releases/expanded_assets/" + tag;
	let r = fetch_any(url, { ua: UA, proxy: true });
	if (r.http != 200 && r.http != 0)
		return [];
	let out = [];
	let seen = {};
	for (let line in split(r.body, "\n")) {
		let p = index(line, "/" + REPO + "/releases/download/");
		if (p < 0)
			continue;
		let rest = substr(line, p);
		let q = index(rest, "\"");
		if (q > 0)
			rest = substr(rest, 0, q);
		let u = "https://github.com" + rest;
		let n = basename(u);
		if (n == "" || seen[u])
			continue;
		seen[u] = true;
		push(out, { name: n, url: u, size: 0 });
	}
	return out;
}

// { ok, tag, assets, via, error }
function latest_release() {
	let r = fetchmod.fetch(API, {
		ua: UA,
		headers: [ [ "Accept", "application/vnd.github+json" ] ],
		proxy: true
	});
	if (r.http == 200) {
		let doc = null;
		try { doc = json(r.body); } catch (e) { doc = null; }
		if (type(doc) == "object") {
			let tag = trim("" + (doc.tag_name || ""));
			let assets = release_assets_from_api(doc);
			if (tag != "" && length(assets) > 0)
				return { ok: true, tag: tag, assets: assets, via: r.via, error: "" };
		}
	}

	// API мог отдать 403 (лимит) — разбираем страницу релиза
	let hr = fetch_any(HTML_LATEST, { ua: UA, proxy: true });
	let tag = "";
	let marker = "/releases/tag/";
	let off = 0;
	while (true) {
		let p = index(substr(hr.body, off), marker);
		if (p < 0)
			break;
		let abs = off + p + length(marker);
		let rest = substr(hr.body, abs);
		let q = index(rest, "\"");
		let q2 = index(rest, "'");
		if (q < 0 || (q2 >= 0 && q2 < q))
			q = q2;
		if (q < 0)
			q = index(rest, " ");
		if (q > 0) {
			let cand = trim(substr(rest, 0, q));
			// в HTML есть шаблон /releases/tag/*name — берём только vX.Y.Z
			if (substr(cand, 0, 1) == "v") {
				let c2 = ord(substr(cand, 1, 1));
				if (c2 >= 0x30 && c2 <= 0x39) {
					tag = cand;
					break;
				}
			}
		}
		off = abs;
	}
	if (tag == "")
		return { ok: false, tag: "", assets: [], via: hr.via,
			error: "cannot find latest release (HTTP " + hr.http + ")" };

	let assets = release_assets_from_html(tag);
	if (length(assets) == 0)
		return { ok: false, tag: tag, assets: [], via: r.via,
			error: "cannot list assets of " + tag };
	return { ok: true, tag: tag, assets: assets, via: r.via, error: "" };
}

function pick_assets(assets, ext) {
	let main = null;
	let luci = null;
	let sums = null;
	for (let a in assets) {
		let n = a.name;
		if (n == "SHA256SUMS") {
			sums = a;
			continue;
		}
		if (length(n) < length(ext) + 1 || substr(n, length(n) - length(ext) - 1) != "." + ext)
			continue;
		if (substr(n, 0, 9) == "luci-app-") {
			if (luci == null)
				luci = a;
		} else if (substr(n, 0, 11) == "shoulderkop") {
			if (main == null)
				main = a;
		}
	}
	return { main: main, luci: luci, sums: sums };
}

function sha256(path) {
	let out = trim(sh("sha256sum '" + path + "' 2>/dev/null"));
	let sp = index(out, " ");
	if (sp <= 0)
		return "";
	return substr(out, 0, sp);
}

// проверка SHA256SUMS: { ok, errors[] }
function verify_sums(dir, files, sums_asset) {
	let errors = [];
	if (sums_asset == null)
		return { ok: true, errors: [ "SHA256SUMS нет в релизе — проверка пропущена" ] };

	let path = dir + "/SHA256SUMS";
	let r = fetch_file_any(sums_asset.url, path, { ua: UA, fast: true, proxy: true });
	if (!r.ok) {
		push(errors, "SHA256SUMS не скачался (HTTP " + r.http + ")");
		return { ok: false, errors: errors };
	}

	let text = fs.readfile(path);
	let want = {};
	for (let line in split(text, "\n")) {
		line = trim(line);
		if (line == "")
			continue;
		let sp = index(line, " ");
		if (sp <= 0)
			continue;
		let h = substr(line, 0, sp);
		let n = trim(substr(line, sp + 1));
		if (substr(n, 0, 2) == "./")
			n = substr(n, 2);
		want[n] = h;
	}

	for (let f in files) {
		if (want[f.name] == null) {
			push(errors, "нет хэша для " + f.name);
			continue;
		}
		let got = sha256(dir + "/" + f.name);
		if (got == "") {
			push(errors, "sha256sum недоступен — " + f.name + " не проверен");
			continue;
		}
		if (lc(got) != lc(want[f.name]))
			push(errors, "хэш не совпал: " + f.name);
	}
	return { ok: length(errors) == 0, errors: errors };
}

function install_file(path, mgr) {
	let rc = 0;
	if (mgr == "apk") {
		rc = system("apk add --allow-untrusted '" + path + "' >>" + LOG + " 2>&1");
		if (rc != 0) {
			system("apk update >>" + LOG + " 2>&1");
			rc = system("apk add --allow-untrusted '" + path + "' >>" + LOG + " 2>&1");
		}
	} else if (mgr == "opkg") {
		rc = system("opkg install --force-reinstall '" + path + "' >>" + LOG + " 2>&1");
	}
	return rc == 0;
}

function lock_acquire() {
	let st = fs.stat(LOCK);
	if (st != null) {
		let pid = trim(fs.readfile(LOCK));
		if (pid != "" && fs.stat("/proc/" + pid) != null)
			return false;
		fs.unlink(LOCK);
	}
	fs.writefile(LOCK, own_pid());
	return true;
}

function lock_release() {
	fs.unlink(LOCK);
}

function run(opts) {
	opts = opts || {};
	let check_only = (opts.check == true);
	let force = (opts.force == true);

	// своё зеркало важнее списка по умолчанию: сети бывают разные
	let custom = trim("" + (opts.mirror || ""));
	if (custom != "") {
		if (substr(custom, length(custom) - 1) != "/")
			custom += "/";
		MIRRORS = [ custom ];
	}
	mirror_used = false;

	let current = installed_version();
	let latest = latest_release();
	let now = time();
	let result = {
		status: "error",
		current: current,
		previous: current,
		latest: "",
		checked_at: now,
		updated: false,
		via: latest.via,
		files: [],
		errors: []
	};

	if (!latest.ok) {
		push(result.errors, latest.error);
		write_state(result);
		return result;
	}
	result.latest = trim(latest.tag);
	if (substr(result.latest, 0, 1) == "v")
		result.latest = substr(result.latest, 1);

	let mgr = pkg_manager();
	if (mgr == "") {
		push(result.errors, "не найден apk/opkg");
		write_state(result);
		return result;
	}
	let ext = (mgr == "apk") ? "apk" : "ipk";
	let picked = pick_assets(latest.assets, ext);
	if (picked.main == null) {
		push(result.errors, "в релизе " + latest.tag + " нет пакета shoulderkop." + ext);
		write_state(result);
		return result;
	}

	let cmp = (current == "") ? -1 : ver_cmp(result.latest, current);
	if (cmp <= 0 && !force) {
		result.status = "latest";
		write_state(result);
		return result;
	}
	if (check_only) {
		result.status = (cmp > 0) ? "available" : "latest";
		write_state(result);
		return result;
	}

	if (!lock_acquire()) {
		result.status = "busy";
		push(result.errors, "другое обновление уже идёт");
		write_state(result);
		return result;
	}

	let dir = "/tmp/shoulderkop-update." + own_pid();
	quiet("rm -rf " + dir + "; mkdir -p " + dir + "; : > " + LOG);

	let files = [ picked.main ];
	if (picked.luci != null)
		push(files, picked.luci);

	let downloaded = [];
	for (let f in files) {
		let dest = dir + "/" + f.name;
		let r = fetch_file_any(f.url, dest, { ua: UA, proxy: true });
		if (!r.ok) {
			push(result.errors, "не скачался " + f.name + " (HTTP " + r.http + ")");
			lock_release();
			write_state(result);
			return result;
		}
		push(downloaded, f);
	}

	let sums = verify_sums(dir, downloaded, picked.sums);
	for (let e in sums.errors)
		push(result.errors, e);
	if (!sums.ok) {
		push(result.errors, "проверка SHA256SUMS не прошла — обновление отменено");
		lock_release();
		write_state(result);
		return result;
	}

	// главный пакет ставим первым: без него luci-app бесполезен
	install_file(dir + "/" + picked.main.name, mgr);
	let after = installed_version();
	if (ver_cmp(after, result.latest) < 0) {
		push(result.errors, "пакет shoulderkop не установился — смотрите " + LOG);
		lock_release();
		write_state(result);
		return result;
	}

	if (picked.luci != null) {
		if (!install_file(dir + "/" + picked.luci.name, mgr))
			push(result.errors, "luci-app-shoulderkop не установился — CLI обновлён");
	}

	result.status = "updated";
	result.updated = true;
	result.current = installed_version();
	result.files = [];
	for (let f in downloaded)
		push(result.files, f.name);

	// переставить cron/автозапуск по новым правилам (если изменились)
	quiet("/usr/bin/shoulderkop schedule >/dev/null 2>&1");

	lock_release();
	quiet("rm -rf " + dir);
	write_state(result);

	// Вывод делает CLI: ручной запуск печатает отчёт сам, cron — только в лог.
	return result;
}

function status() {
	let st = read_state();
	return {
		enabled: (cfg_get("auto_update") == "1"),
		current: installed_version(),
		last: st
	};
}

return {
	run: run,
	status: status,
	installed_version: installed_version,
	ver_cmp: ver_cmp
};
