// diag.uc — сетевая диагностика shoulderkop.
//
// Идея: раз в 5 минут дешёвая проверка «есть ли интернет» (HTTP-запрос на
// gstatic.com/generate_204, как это делает сам podkop для urltest). Если всё
// хорошо — на этом всё, в журнал ничего не пишем. Если плохо — полная
// диагностика по образцу `podkop global_check`: сервисы, nft, DNS, узлы, и
// починка: автозапуск podkop, перезапуск, спуск по DNS-лестнице, а при полном
// отсутствии живых узлов — перевод всего в direct.
//
// Всё, что можно, переиспользуем у podkop: `podkop check_dns_available`,
// `podkop get_status`, `podkop reload`. Своё — только оркестрация, лимиты и
// история проверок (последние 10 в /tmp).

'use strict';

let fs = require("fs");
let uci = require("uci");

const CONFIG = "shoulderkop";
const SECTION = "settings";

const REPORT = "/tmp/shoulderkop.diag.json";        // последний отчёт
const HISTORY = "/tmp/shoulderkop.diag.history.json"; // до 10 отчётов
const LIMITS = "/tmp/shoulderkop.diag.limits.json";   // лимиты починки
const HISTORY_MAX = 10;

const GSTATIC = "https://www.gstatic.com/generate_204";
const PODKOP = "/etc/init.d/podkop";
const SINGBOX = "/etc/init.d/sing-box";

// DNS-лестница: от лучшего варианта к худшему (тип + сервер в терминах podkop).
// Для DoH нужен hostname (sing-box проверяет сертификат), для DoT и UDP — тоже
// hostname/IP, которые podkop сам подставит в dig/sing-box.
const LADDER = [
	{ type: "doh", server: "dns.google" },
	{ type: "dot", server: "dns.google" },
	{ type: "doh", server: "cloudflare-dns.com" },
	{ type: "dot", server: "one.one.one.one" },
	{ type: "doh", server: "common.dot.dns.yandex.net" },
	{ type: "dot", server: "common.dot.dns.yandex.net" },
	{ type: "udp", server: "77.88.8.8" }
];

// лимиты: перезапускаем podkop не чаще 3 раз за 30 минут, DNS меняем не чаще
// раза в 10 минут, direct включаем/выключаем не чаще раза в 10 минут
const RESTART_MAX = 3;
const RESTART_WINDOW = 1800;
const SWITCH_COOLDOWN = 600;

let sh_seq = 0;

function own_pid() {
	let s = fs.readfile("/proc/self/stat");
	if (s == null || s == "")
		return "" + time();
	let sp = index(s, " ");
	return (sp > 0) ? substr(s, 0, sp) : "" + time();
}

function sh(cmd) {
	sh_seq++;
	let tmp = "/tmp/.shoulderkop.diag." + own_pid() + "." + sh_seq;
	system(cmd + " > " + tmp + " 2>/dev/null");
	let out = fs.readfile(tmp);
	fs.unlink(tmp);
	return (out == null) ? "" : out;
}

function quiet(cmd) {
	system(cmd + " >/dev/null 2>&1");
}

function read_json(path, def) {
	let raw = fs.readfile(path);
	if (raw == null || raw == "")
		return def;
	try {
		return json(raw);
	} catch (e) {
		return def;
	}
}

function write_json(path, val) {
	fs.writefile(path, sprintf("%J", val));
}

function cfg(name, def) {
	let c = uci.cursor();
	if (!c.load(CONFIG))
		return def;
	let v = c.get(CONFIG, SECTION, name);
	return (v == null || "" + v == "") ? def : "" + v;
}

function cfg_bool(name, def) {
	let v = cfg(name, null);
	if (v == null)
		return def;
	return ("" + v == "1");
}

function cfg_set(name, value) {
	let c = uci.cursor();
	if (!c.load(CONFIG))
		return false;
	c.set(CONFIG, SECTION, name, value);
	c.commit(CONFIG);
	return true;
}

function is_enabled(init) {
	return trim(sh("ls /etc/rc.d/S*" + init + " 2>/dev/null")) != "";
}

function init_exists(init) {
	return fs.stat("/etc/init.d/" + init) != null;
}

function singbox_running() {
	if (trim(sh("pgrep -f '[s]ing-box[^ ]* run' 2>/dev/null")) != "")
		return true;
	return trim(sh("pidof sing-box 2>/dev/null")) != "" ||
		trim(sh("pidof sing-box-core 2>/dev/null")) != "";
}

function tunnel_up() {
	return trim(sh("nft list table inet PodkopTable 2>/dev/null")) != "";
}

function http_code(url, extra) {
	return trim(sh("curl -s -m 8 -o /dev/null -w '%{http_code}' " +
		((extra != null) ? extra : "") + " '" + url + "'"));
}

function internet_ok() {
	let code = http_code(GSTATIC, null);
	return (code == "200" || code == "204" || code == "301" || code == "302");
}

function dns_level_get() {
	let v = cfg("dns_level", null);
	if (v == null)
		return -1; // ещё не управляем: считаем, что настроено вручную
	let n = int(v);
	if (n < 0 || n >= length(LADDER))
		return -1;
	return n;
}

function current_dns() {
	let c = uci.cursor();
	if (!c.load("podkop"))
		return { type: "", server: "" };
	return {
		type: "" + (c.get("podkop", "settings", "dns_type") || ""),
		server: "" + (c.get("podkop", "settings", "dns_server") || "")
	};
}

function probe_level(i) {
	let e = LADDER[i];
	if (e == null)
		return false;

	if (e.type == "doh") {
		let code = http_code("https://" + e.server + "/dns-query?name=google.com&type=A",
			"-H 'accept: application/dns-json'");
		return (code == "200");
	}

	if (e.type == "dot")
		return trim(sh("dig @" + e.server + " google.com +tls +timeout=3 +tries=1 " +
			"+tls-hostname=" + e.server + " >/dev/null 2>&1 && echo ok")) == "ok";

	return trim(sh("dig @" + e.server + " google.com +timeout=2 +tries=1 " +
		">/dev/null 2>&1 && echo ok")) == "ok";
}

function first_working_from(from) {
	for (let i = from; i < length(LADDER); i++)
		if (probe_level(i))
			return i;
	return -1;
}

function podkop_enabled() {
	return init_exists("podkop") && is_enabled("podkop");
}

function nft_ok() {
	return tunnel_up();
}

function podkop_state() {
	let raw = trim(sh("/usr/bin/podkop get_status 2>/dev/null"));
	if (raw == "")
		return null;
	try {
		return json(raw);
	} catch (e) {
		return null;
	}
}

function limits_load() {
	let l = read_json(LIMITS, null);
	if (type(l) != "object")
		l = {};
	l.restarts = l.restarts || [];
	l.last_dns = l.last_dns || 0;
	l.last_direct = l.last_direct || 0;
	return l;
}

function limits_save(l) {
	write_json(LIMITS, l);
}

function can_restart(l) {
	let now = time();
	let fresh = [];
	for (let t in l.restarts)
		if (now - int(t) < RESTART_WINDOW)
			push(fresh, int(t));
	l.restarts = fresh;
	return length(fresh) < RESTART_MAX;
}

function took_restart(l) {
	push(l.restarts, time());
	limits_save(l);
}

function restart_podkop(l, actions) {
	if (!init_exists("podkop"))
		return false;
	if (!can_restart(l)) {
		push(actions, "podkop: перезапуск не делаем — исчерпан лимит (" +
			RESTART_MAX + " за " + (RESTART_WINDOW / 60) + " мин)");
		return false;
	}
	quiet(PODKOP + " restart");
	took_restart(l);
	push(actions, "podkop: перезапущен");
	return true;
}

function to_direct(l, actions) {
	let now = time();
	if (now - int(l.last_direct) < SWITCH_COOLDOWN) {
		push(actions, "direct: не переключаем — недавно уже переключали");
		return false;
	}
	l.last_direct = now;
	limits_save(l);

	quiet(PODKOP + " disable");
	quiet(PODKOP + " stop");
	quiet("nft delete table inet PodkopTable");
	cfg_set("direct_mode", "1");
	push(actions, "все узлы недоступны: podkop остановлен, трафик идёт напрямую (direct)");
	return true;
}

function from_direct(l, actions) {
	let now = time();
	if (now - int(l.last_direct) < SWITCH_COOLDOWN) {
		push(actions, "direct: не возвращаем — недавно переключали");
		return false;
	}
	l.last_direct = now;
	limits_save(l);

	if (init_exists("podkop"))
		quiet(PODKOP + " enable");
	quiet(PODKOP + " start");
	cfg_set("direct_mode", "0");
	push(actions, "узлы снова живы: podkop включён, возвращаемся в туннель");
	return true;
}

function set_dns_level(i, l, actions) {
	let now = time();
	if (now - int(l.last_dns) < SWITCH_COOLDOWN) {
		push(actions, "dns: не переключаем — недавно уже переключали");
		return false;
	}

	let e = LADDER[i];
	let c = uci.cursor();
	if (!c.load("podkop"))
		return false;
	c.set("podkop", "settings", "dns_type", e.type);
	c.set("podkop", "settings", "dns_server", e.server);
	c.commit("podkop");

	l.last_dns = now;
	limits_save(l);
	cfg_set("dns_level", "" + i);
	push(actions, "dns: переключён на " + e.type + " " + e.server + " (ступень " + (i + 1) + ")");

	if (init_exists("podkop"))
		quiet(PODKOP + " reload");
	return true;
}

function run_checks(quick) {
	let checks = [];

	function add(name, ok, detail) {
		push(checks, { name: name, ok: ok, detail: detail });
	}

	add("internet", internet_ok(), GSTATIC);

	// podkop не установлен — проверять и чинить нечего, смотрим только связность
	if (!init_exists("podkop"))
		return checks;

	if (quick)
		return checks;

	add("podkop", podkop_enabled(), podkop_enabled() ? "автозапуск включён" : "автозапуск выключен");
	add("sing-box", singbox_running(), singbox_running() ? "процесс работает" : "процесс не найден");
	add("nft", nft_ok(), nft_ok() ? "таблица PodkopTable есть" : "таблицы PodkopTable нет");

	let cur = current_dns();
	let lvl = dns_level_get();
	if (lvl >= 0) {
		let e = LADDER[lvl];
		add("dns", probe_level(lvl), e.type + " " + e.server + " (ступень " + (lvl + 1) + ")");
	} else if (cur.type != "") {
		add("dns", trim(sh("dig @127.0.0.1 google.com +timeout=2 +tries=1 >/dev/null 2>&1 && echo ok")) == "ok",
			"dnsmasq: " + cur.type + " " + cur.server);
	}

	return checks;
}

function failed(checks) {
	let out = [];
	for (let c in checks)
		if (!c.ok)
			push(out, c.name);
	return out;
}

function log_msg(msg) {
	quiet("logger -t shoulderkop-diag " + "'" + replace(msg, "'", "") + "'");
}

function save(report) {
	write_json(REPORT, report);

	let hist = read_json(HISTORY, []);
	if (type(hist) != "array")
		hist = [];
	// пишем только когда что-то произошло: успешные тихие проверки не засоряют
	if (!report.ok || length(report.actions || []) > 0 || (report.checks || []).length > 1)
		push(hist, report);
	if (length(hist) > HISTORY_MAX)
		hist = slice(hist, length(hist) - HISTORY_MAX);
	write_json(HISTORY, hist);
}

function state() {
	let r = read_json(REPORT, null);
	let hist = read_json(HISTORY, []);
	return {
		report: r,
		history: (type(hist) == "array") ? hist : [],
		enabled: cfg_bool("diag_enabled", true),
		interval: cfg("diag_interval", "5m"),
		level: dns_level_get(),
		direct: cfg_bool("direct_mode", false),
		ladder: LADDER
	};
}

function after_update() {
	let actions = [];
	let l = limits_load();
	if (cfg_bool("direct_mode", false)) {
		from_direct(l, actions);
		return { left_direct: true, actions: actions };
	}
	return { left_direct: false, actions: actions };
}

function run(opts) {
	opts = opts || {};
	let quick = (opts.quick == true);
	let force = (opts.force == true);

	if (!cfg_bool("diag_enabled", true) && !force)
		return { skipped: true, reason: "diag_enabled=0" };

	let l = limits_load();
	let started = time();
	let actions = [];
	let errors = [];

	let checks = run_checks(quick);
	let bad = failed(checks);

	// всё хорошо — молча выходим (в журнал попадём только при проблеме)
	if (length(bad) == 0) {
		let ok_report = {
			ts: started,
			ok: true,
			quick: quick,
			level: dns_level_get(),
			checks: checks,
			actions: [],
			errors: []
		};
		save(ok_report);
		return ok_report;
	}

	log_msg("проблема: " + join(", ", bad));

	if (!quick && init_exists("podkop") && cfg_bool("diag_repair", true)) {
		// 1. автозапуск podkop снят — возвращаем (это и есть «интернет пропал
		//    после ребута»), если не в direct-режиме
		if (!podkop_enabled() && init_exists("podkop") && !cfg_bool("direct_mode", false)) {
			quiet(PODKOP + " enable");
			push(actions, "podkop: автозапуск включён");
		}

		// 2. сервис не поднят / nft нет — перезапускаем
		if (!singbox_running() || !nft_ok())
			restart_podkop(l, actions);

		// 3. интернета всё ещё нет — спускаемся по DNS-лестнице до первой
		//    рабочей ступени (DoH → DoT → UDP 77.88.8.8)
		if (!internet_ok()) {
			let lvl = dns_level_get();
			let from = (lvl >= 0) ? lvl + 1 : 0;
			let next = first_working_from(from);
			if (next < 0 && from > 0)
				next = first_working_from(0);
			if (next >= 0)
				set_dns_level(next, l, actions);
			else
				push(actions, "dns: ни одна ступень не отвечает — проблема не в DNS");
		}

		// 4. всё ещё нет интернета — переводим в direct, чтобы LAN не остался
		//    без сети совсем
		if (!internet_ok())
			to_direct(l, actions);

		// 5. direct и интернет есть, а узлы уже живы — возвращаемся
		if (cfg_bool("direct_mode", false) && internet_ok() && opts.resume == true)
			from_direct(l, actions);

		checks = run_checks(false);
		bad = failed(checks);
	}

	let report = {
		ts: started,
		ok: length(bad) == 0,
		quick: quick,
		level: dns_level_get(),
		checks: checks,
		actions: actions,
		errors: errors
	};

	save(report);

	if (length(actions) > 0)
		log_msg("починка: " + join("; ", actions));
	if (length(bad) > 0)
		log_msg("остались проблемы: " + join(", ", bad));

	return report;
}

return {
	run: run,
	state: state,
	after_update: after_update,
	internet_ok: internet_ok,
	probe_level: probe_level,
	ladder: LADDER
};
