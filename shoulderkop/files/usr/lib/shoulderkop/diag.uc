// diag.uc — сетевая диагностика shoulderkop.
//
// Идея: раз в 5 минут дешёвая проверка «есть ли интернет» (HTTP-запрос на
// gstatic.com/generate_204, как это делает сам podkop для urltest). Если всё
// хорошо — на этом всё, в журнал ничего не пишем. Если плохо — полная
// диагностика по образцу `podkop global_check`: сервисы, nft, DNS, узлы, и
// починка: автозапуск podkop, перезапуск, спуск по DNS-лестнице, а при полном
// отсутствии живых узлов — перевод всего в direct.
//
// Отдельно — пауза подписки: podkop выключен, sing-box и nft должны быть сняты.
// При паузе проверяем ровно этот инвариант и чиним только в сторону снятия:
// никогда не поднимаем podkop и не включаем его автозапуск.
//
// Всё, что можно, переиспользуем у podkop: `podkop check_dns_available`,
// `podkop get_status`, `podkop reload`. Своё — только оркестрация, лимиты и
// история проверок (последние 10 в /tmp).

'use strict';

let fs = require("fs");
let uci = require("uci");
let podkopctl = require("podkopctl");

const CONFIG = "shoulderkop";
const SECTION = "settings";

const REPORT = "/tmp/shoulderkop.diag.json";        // последний отчёт
const HISTORY = "/tmp/shoulderkop.diag.history.json"; // до 10 отчётов
const LIMITS = "/tmp/shoulderkop.diag.limits.json";   // лимиты починки
const HISTORY_MAX = 10;

const GSTATIC = "https://www.gstatic.com/generate_204";
const PODKOP = "/etc/init.d/podkop";
const PODKOP_BIN = "/usr/bin/podkop";

// DNS-лестница: от лучшего варианта к худшему, только IP — чтобы проверка и
// работа DNS не зависели от того, резолвится ли чьё-то имя (когда DNS и сломан,
// резолвить нечем). Проверено на живом роутере: сертификаты 8.8.8.8, 1.1.1.1 и
// 77.88.8.8 содержат IP-SAN, поэтому DoT по IP проходит проверку TLS.
//
// Почему здесь нет Google DoH: https://8.8.8.8/dns-query отдаёт 400 (Google
// требует SNI/Host dns.google, а podkop умеет задать только адрес), а
// https://77.88.8.8/dns-query — 404 (у Яндекса DoH по IP не поднят).
// Поэтому DoH в лестнице один — Cloudflare, он по IP работает.
const LADDER = [
	{ type: "dot", server: "8.8.8.8" },
	{ type: "doh", server: "1.1.1.1" },
	{ type: "dot", server: "1.1.1.1" },
	{ type: "dot", server: "77.88.8.8" },
	{ type: "udp", server: "77.88.8.8" }
];

// лимиты: перезапускаем podkop не чаще 3 раз за 30 минут, DNS меняем не чаще
// раза в 10 минут, direct включаем/выключаем не чаще раза в 10 минут.
// После перезапуска podkop туннель поднимается 25–50 с — в это время ничего
// не чиним, иначе только что поднятый туннель читается как «интернета нет».
const RESTART_MAX = 3;
const RESTART_WINDOW = 1800;
const SWITCH_COOLDOWN = 600;
const RESTART_COOLDOWN = 60;

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

	// сертификаты этих IP содержат IP-SAN, отдельный tls-hostname не нужен
	if (e.type == "dot")
		return trim(sh("dig @" + e.server + " google.com +tls +timeout=3 +tries=1 " +
			">/dev/null 2>&1 && echo ok")) == "ok";

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

// Живы ли узлы. Спрашиваем у самого podkop через Clash API: у нативной
// urltest-секции группа называется "<section>-urltest-out", у синтетической
// (outbound_json) — "<section>-out". Обе умеют мерить задержку.
// -1 — проверить не удалось, 0 — все мертвы, 1 — есть живой.
function clash_group_delay(tag) {
	let raw = trim(sh("/usr/bin/podkop clash_api get_group_latency '" + tag + "' 1500 2>/dev/null"));
	if (raw == "")
		return -1;
	try {
		let o = json(raw);
		return int(o.delay || 0);
	} catch (e) {
		return -1;
	}
}

function tunnel_groups() {
	let out = [];
	let c = uci.cursor();
	if (!c.load("podkop"))
		return out;
	c.foreach("podkop", "section", function (s) {
		if (substr(s[".name"], 0, 5) != "skop_")
			return;
		let pct = trim("" + (s.proxy_config_type || ""));
		push(out, s[".name"] + ((pct == "urltest") ? "-urltest-out" : "-out"));
	});
	return out;
}

function nodes_alive() {
	let groups = tunnel_groups();
	if (length(groups) == 0)
		return -1;
	let known = false;
	for (let g in groups) {
		let d = clash_group_delay(g);
		if (d > 0)
			return 1;
		if (d >= 0)
			known = true;
	}
	return known ? 0 : -1;
}

// Обновить подписку перед починкой: панель могла выдать другие узлы, а старые
// уже мертвы. Не чаще раза в 30 минут, чтобы не долбить панель. Сам update
// перезапускает podkop и ставит метку перезапуска — после него даём туннелю
// подняться, а не чиним сразу.
function refresh_subscription(l, actions) {
	let now = time();
	if (now - int(l.last_update || 0) < 1800)
		return false;
	l.last_update = now;
	limits_save(l);
	push(actions, "подписка: обновляю перед проверкой узлов");
	quiet("/usr/bin/shoulderkop update");
	return true;
}

function limits_load() {
	let l = read_json(LIMITS, null);
	if (type(l) != "object")
		l = {};
	l.restarts = l.restarts || [];
	l.last_dns = l.last_dns || 0;
	l.last_direct = l.last_direct || 0;
	l.last_restart = l.last_restart || 0;
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

// podkop мог перезапуститься не нами (update в cron): podkopctl пишет метку,
// по ней диагностика тоже выдерживает паузу после перезапуска
function restart_recently(l) {
	let now = time();
	if (now - podkopctl.restart_mark() < RESTART_COOLDOWN)
		return true;
	return (now - int("" + (l.last_restart || 0)) < RESTART_COOLDOWN);
}

function restart_podkop(l, actions, errors) {
	if (!init_exists("podkop"))
		return false;
	if (!can_restart(l)) {
		push(actions, "podkop: перезапуск не делаем — исчерпан лимит (" +
			RESTART_MAX + " за " + (RESTART_WINDOW / 60) + " мин)");
		return false;
	}
	let r = podkopctl.restart_and_wait({ wait_ms: 15000, attempts: 1 });
	took_restart(l);
	l.last_restart = time();
	limits_save(l);
	if (r.ok)
		push(actions, "podkop: перезапущен");
	else {
		push(actions, "podkop: перезапущен, но туннель не поднялся");
		for (let e in r.errors)
			push(errors, e);
	}
	return true;
}

// Перевод в direct: podkop выключен, DNS возвращён провайдеру, остатки сняты.
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
	// прямой stop нужен, когда procd-инстанса нет: он возвращает dnsmasq
	// провайдеру, иначе LAN останется без DNS
	quiet(PODKOP_BIN + " stop");

	let cl = podkopctl.cleanup({ force: true });
	for (let a in cl.actions)
		push(actions, a);
	for (let e in cl.errors)
		push(actions, "cleanup: " + e);

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

	if (!init_exists("podkop")) {
		cfg_set("direct_mode", "0");
		return false;
	}

	let r = podkopctl.restart_and_wait({ wait_ms: 15000, attempts: 1 });
	l.last_restart = time();
	limits_save(l);
	if (!r.ok) {
		for (let e in r.errors)
			push(actions, "podkop: " + e);
		push(actions, "direct: туннель не поднялся — остаёмся напрямую");
		return false;
	}

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

	// здесь меняется только конфиг sing-box: dnsmasq уже настроен podkop'ом,
	// поэтому reload достаточно (restart настраивал бы dnsmasq заново)
	if (init_exists("podkop"))
		quiet(PODKOP + " reload");
	return true;
}

function run_checks(quick, paused) {
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

	let box = podkopctl.singbox_running();
	let table = podkopctl.tunnel_up();

	// Пауза подписки: lifecycle штатно погасил podkop, sing-box и nft сняты,
	// а dnsmasq возвращён провайдеру. Автозапуск podkop при паузе не проверяем
	// и не включаем — иначе вернём туннель с истёкшей подпиской и оставим LAN
	// без интернета. Резолв проверяем глазами LAN-клиента: если dnsmasq всё
	// ещё указывает на мёртвый podkop, интернета у клиентов нет.
	if (paused) {
		add("sing-box", !box, box ? "процесс работает, а при паузе его быть не должно" : "процесс не найден");
		add("nft", !table, table ? "таблица PodkopTable есть, а при паузе её быть не должно" : "таблицы PodkopTable нет");

		let resolved = podkopctl.dns_ok();
		add("dns", resolved, resolved ? "резолв через 127.0.0.1 работает" : "резолв через 127.0.0.1 не работает");
		return checks;
	}

	add("podkop", podkop_enabled(), podkop_enabled() ? "автозапуск включён" : "автозапуск выключен");
	add("sing-box", box, box ? "процесс работает" : "процесс не найден");
	add("nft", table, table ? "таблица PodkopTable есть" : "таблицы PodkopTable нет");

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

// Починка при паузе: только снятие. Никакого enable/start — podkop должен
// остаться выключенным, пока подписка не станет активной снова. Кроме nft и
// sing-box возвращаем dnsmasq провайдеру: иначе LAN останется без DNS.
function repair_paused(actions, errors) {
	if (podkopctl.singbox_running() || podkopctl.tunnel_up()) {
		let r = podkopctl.cleanup({ force: true });
		for (let a in r.actions)
			push(actions, a);
		for (let e in r.errors)
			push(errors, e);
	}

	let rd = podkopctl.restore_dns();
	for (let a in rd.actions)
		push(actions, a);
	for (let e in rd.errors)
		push(errors, e);

	return true;
}

function check_ok(checks, name) {
	for (let c in checks)
		if (c.name == name)
			return c.ok == true;
	return false;
}

// В отчёт паузы кладём то, что видит клиент LAN: живой DNS и интернет.
function pause_fields(report, checks) {
	report.dns_ok = check_ok(checks, "dns");
	report.internet_ok = check_ok(checks, "internet");
	return report;
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

	// update/apply держит лок на всё время «конфиг podkop → restart → ожидание»:
	// в это окно мерить и чинить нечего, только мешать
	if (podkopctl.locked())
		return { skipped: true, reason: "apply lock busy" };

	let l = limits_load();
	let started = time();
	let actions = [];
	let errors = [];

	// подписка на паузе (истекла): lifecycle специально погасил podkop и снял
	// автозапуск — не «чиним» это обратно, иначе диагностика воевала бы с паузой
	let paused = (cfg("suspended", "0") == "1");

	// сразу после перезапуска podkop туннель ещё поднимается: 60 с не чиним
	// и не переводим всё в direct, иначе успешный update читается как авария
	let cooling = restart_recently(l);

	let checks = run_checks(quick, paused);
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
		if (paused && !quick)
			pause_fields(ok_report, checks);
		save(ok_report);
		return ok_report;
	}

	log_msg("проблема: " + join(", ", bad));

	if (!quick && cfg_bool("diag_repair", true) && !cooling) {
		if (paused) {
			// на паузе чиним только в сторону снятия (см. repair_paused)
			if (repair_paused(actions, errors)) {
				checks = run_checks(false, true);
				bad = failed(checks);
			}
		}
		else if (init_exists("podkop")) {
			let direct = cfg_bool("direct_mode", false);

			// 0. интернета нет, а мы в туннеле: возможно, панель уже выдала другие
			//    узлы — подтягиваем подписку (не чаще раза в 30 минут). Update сам
			//    перезапускает podkop, поэтому дальше даём туннелю подняться.
			if (!internet_ok() && !direct && refresh_subscription(l, actions))
				cooling = restart_recently(l);

			// 1. автозапуск podkop снят — возвращаем (это и есть «интернет пропал
			//    после ребута»), если не в direct-режиме
			if (!cooling && !podkop_enabled() && !direct) {
				quiet(PODKOP + " enable");
				push(actions, "podkop: автозапуск включён");
			}

			// 2. сервис не поднят / nft нет — перезапускаем и ждём готовности
			if (!cooling && (!podkopctl.singbox_running() || !podkopctl.tunnel_up()))
				if (restart_podkop(l, actions, errors))
					cooling = true;

			if (cooling) {
				push(actions, "podkop перезапущен: " + RESTART_COOLDOWN + " с не трогаем — туннель поднимается");
			}
			else {
				// 3. все узлы мертвы — держать podkop включённым нельзя: он душит
				//    интернет и ломает загрузку rule-set'ов podkop. Переводим всё
				//    в direct, пока не появятся живые серверы.
				if (!internet_ok() && !direct && (podkopctl.singbox_running() || podkopctl.tunnel_up())) {
					system("sleep 3");
					let na = nodes_alive();
					if (na == 0) {
						push(actions, "все узлы мертвы — перевожу всё в direct");
						to_direct(l, actions);
						direct = cfg_bool("direct_mode", false);
					} else if (na == 1) {
						push(actions, "узлы живы — проблема не в серверах");
					}
				}

				// 4. интернета всё ещё нет — спускаемся по DNS-лестнице до первой
				//    рабочей ступени (DoH → DoT → UDP 77.88.8.8)
				if (!internet_ok() && !direct) {
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

				// 5. последний рубеж — direct, чтобы LAN не остался без сети совсем
				if (!internet_ok() && !direct)
					to_direct(l, actions);

				// 6. direct и узлы снова живы — возвращаемся в туннель
				if (cfg_bool("direct_mode", false) && internet_ok() && opts.resume == true)
					from_direct(l, actions);
			}

			checks = run_checks(false, false);
			bad = failed(checks);
		}
	}

	let report = {
		ts: started,
		ok: length(bad) == 0,
		quick: quick,
		paused: paused,
		level: dns_level_get(),
		checks: checks,
		actions: actions,
		errors: errors
	};

	if (paused && !quick)
		pause_fields(report, checks);

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
