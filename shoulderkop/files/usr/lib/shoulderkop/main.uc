// shoulderkop — энтипоинт (CLI + rpcd через fs.exec).
//
// Команды:
//   convert <file>     — распарсить файл подписки и вывести узлы (отладка без устройства)
//   update             — скачать подписки, распарсить, разложить по секциям podkop;
//                        при истёкшей подписке — остановить podkop/sing-box
//   apply              — то же, но без скачивания: применить узлы из кэша
//   list_servers       — вывести узлы из кэша (при пустом кэше — сходить в подписку)
//   status             — вывести состояние последнего обновления и паузы
//   schedule [off]     — переустановить cron-задачу по enable_schedule/update_interval

'use strict';

let fs = require("fs");
let uci = require("uci");
let subscription = require("subscription");
let applymod = require("apply");
let lifecycle = require("lifecycle");
let diagmod = require("diag");

const CACHE = "/tmp/shoulderkop.cache.json";
const STATE = "/tmp/shoulderkop.state.json";
const CRONTAB = "/etc/crontabs/root";
const CRON_LINE = "/usr/bin/shoulderkop update";
const DIAG_CRON_LINE = "/usr/bin/shoulderkop diag --quiet";
const RCLINK = "/etc/rc.d/S99shoulderkop";

// UA захардкожен: Remnawave отдаёт Xray JSON (а не заглушку) только для Happ.
// Пишется в конфиг при установке/запуске, из интерфейса не редактируется.
const UA = "Happ/2.7.0";

// Свой pid: в ucode нет getpid(), берём первое поле /proc/self/stat.
function own_pid() {
	let s = fs.readfile("/proc/self/stat");
	if (s == null || s == "")
		return "" + time();
	let sp = index(s, " ");
	return (sp > 0) ? substr(s, 0, sp) : "" + time();
}

// Захват stdout команды. fs.popen().read() в этой сборке ucode не отдаёт вывод,
// поэтому пишем во временный файл и читаем его. Имя уникально для процесса:
// cron и LuCI могут запустить shoulderkop одновременно.
let sh_seq = 0;

function sh(cmd) {
	sh_seq++;
	let tmp = "/tmp/.shoulderkop.cmd." + own_pid() + "." + sh_seq;
	system(cmd + " > " + tmp + " 2>/dev/null");
	let out = fs.readfile(tmp);
	fs.unlink(tmp);
	return (out == null) ? "" : out;
}

// Умеет ли движок xhttp. Обычный sing-box — нет: такие узлы надо выкинуть из
// подписки, иначе podkop/sing-box не поднимется (транспорт неизвестен).
function engine_extended() {
	let v = lc(trim(sh("sing-box version 2>/dev/null | head -n 1")));
	return index(v, "extended") >= 0;
}

function uci_get(config, section, option) {
	return trim(sh("uci -q get " + config + "." + section + "." + option + " 2>/dev/null"));
}

function uci_list(config, section, option) {
	let raw = trim(sh("uci -q get " + config + "." + section + "." + option + " 2>/dev/null"));
	if (raw == "")
		return [];
	return split(raw, "\n");
}

function uci_set(config, section, option, value) {
	let c = uci.cursor();
	c.load(config);
	let cur = c.get(config, section, option);
	if (cur != null && "" + cur == "" + value)
		return 0;
	c.set(config, section, option, value);
	c.commit(config);
	return 1;
}

// MAC роутера → стабильный HWID. Панель привязывает устройство по заголовку x-hwid,
// поэтому значение не должно меняться от запуска к запуску.
function mac_of(dev) {
	let raw = trim(sh("cat /sys/class/net/" + dev + "/address 2>/dev/null"));
	if (raw == "" || raw == "00:00:00:00:00:00")
		return "";
	let out = "";
	for (let i = 0; i < length(raw); i++) {
		let ch = substr(raw, i, 1);
		if (ch != ":")
			out += uc(ch);
	}
	return (length(out) == 12) ? out : "";
}

function hwid_from_mac() {
	let devs = [ "br-lan", "br-lan1", "eth0", "wan", "lan" ];
	for (let d in devs) {
		let h = mac_of(d);
		if (h != "")
			return h;
	}
	// последний шанс: любой не-loopback интерфейс
	for (let d in split(trim(sh("ls /sys/class/net 2>/dev/null")), "\n")) {
		d = trim(d);
		if (d == "" || d == "lo")
			continue;
		let h = mac_of(d);
		if (h != "")
			return h;
	}
	return "";
}

// Старая схема v1 (`config shoulder`) больше не используется: убираем её один раз,
// чтобы не было двух источников правды, и выставляем значения по умолчанию.
function migrate_settings() {
	let c = uci.cursor();
	c.load("shoulderkop");

	let old = [];
	c.foreach("shoulderkop", "shoulder", function (s) {
		push(old, s[".name"]);
	});
	for (let n in old)
		c.delete("shoulderkop", n);

	let changed = length(old) > 0;

	if (c.get("shoulderkop", "settings", "mode") == null) {
		c.set("shoulderkop", "settings", "mode", "wifi");
		changed = true;
	}
	if (c.get("shoulderkop", "settings", "urltest_interval") == null) {
		c.set("shoulderkop", "settings", "urltest_interval", "30s");
		changed = true;
	}

	// переключателя «настраивать podkop автоматически» больше нет: секции всегда авто
	if (c.get("shoulderkop", "settings", "auto_configure_podkop") != null) {
		c.delete("shoulderkop", "settings", "auto_configure_podkop");
		changed = true;
	}

	// диагностика сети: включена, раз в 5 минут, с починкой
	if (c.get("shoulderkop", "settings", "diag_enabled") == null) {
		c.set("shoulderkop", "settings", "diag_enabled", "1");
		changed = true;
	}
	if (c.get("shoulderkop", "settings", "diag_repair") == null) {
		c.set("shoulderkop", "settings", "diag_repair", "1");
		changed = true;
	}
	if (c.get("shoulderkop", "settings", "diag_interval") == null) {
		c.set("shoulderkop", "settings", "diag_interval", "5m");
		changed = true;
	}
	if (c.get("shoulderkop", "settings", "direct_mode") == null) {
		c.set("shoulderkop", "settings", "direct_mode", "0");
		changed = true;
	}


	// Пауза туннеля при истёкшей подписке. 0 — обычный режим.
	if (c.get("shoulderkop", "settings", "suspended") == null) {
		c.set("shoulderkop", "settings", "suspended", "0");
		changed = true;
	}

	// Сколько подписок было активных в прошлый раз: если станет меньше,
	// секции podkop один раз пересобираются (серверы ушедшей подписки мертвы).
	if (c.get("shoulderkop", "settings", "last_active_subs") == null) {
		c.set("shoulderkop", "settings", "last_active_subs", "0");
		changed = true;
	}

	// UA захардкожен: Remnawave отдаёт Xray JSON только для Happ
	if ("" + (c.get("shoulderkop", "settings", "user_agent") || "") != UA) {
		c.set("shoulderkop", "settings", "user_agent", UA);
		changed = true;
	}

	// HWID пустой (первая установка) — выводим из MAC роутера и больше не трогаем
	let hwid = "" + (c.get("shoulderkop", "settings", "hwid") || "");
	if (trim(hwid) == "") {
		let gen = hwid_from_mac();
		if (gen != "") {
			c.set("shoulderkop", "settings", "hwid", gen);
			changed = true;
		}
	}

	if (changed)
		c.commit("shoulderkop");
}

function cmd_convert(file) {
	let text = fs.readfile(file);
	if (text == null || trim(text) == "") {
		print(sprintf("%J", { error: "cannot read file: " + file }));
		return 1;
	}
	let r = null;
	try {
		r = subscription.parse_subscription(text);
	} catch (e) {
		print(sprintf("%J", { error: "cannot parse subscription: " + "" + e }));
		return 1;
	}
	let cls = subscription.classify_nodes(r.nodes);
	print(sprintf("%J", {
		status: (cls == "placeholder") ? "expired" : ((cls == "empty") ? "empty" : "active"),
		placeholder: (cls == "placeholder"),
		count: length(r.nodes),
		skipped: length(r.skipped),
		skipped_nodes: r.skipped,
		nodes: r.nodes
	}));
	return 0;
}

// Device info for the panel (it shows Platform / Version / Model per device):
// x-device-os, x-ver-os, x-device-model. Without them the panel shows "Unknown".
function board_info() {
	let info = { os: "OpenWrt", ver: "", model: "" };

	let rel = fs.readfile("/etc/openwrt_release");
	if (rel != null) {
		for (let line in split(rel, "\n")) {
			line = trim(line);
			let eq = index(line, "=");
			if (eq <= 0)
				continue;
			let k = substr(line, 0, eq);
			let v = trim(replace(substr(line, eq + 1), "'", ""));
			if (k == "DISTRIB_ID" && v != "")
				info.os = v;
			else if (k == "DISTRIB_RELEASE" && v != "")
				info.ver = v;
		}
	}

	let model = fs.readfile("/tmp/sysinfo/model");
	if (model != null)
		info.model = trim(model);
	if (info.model == "")
		info.model = "router";

	return info;
}

// header values go through a single-quoted shell string: strip quotes/newlines
function hdr_val(v) {
	return trim(replace(replace("" + (v == null ? "" : v), "'", ""), "\n", " "));
}

function fetch_headers(hwid) {
	let b = board_info();
	return [
		[ "x-hwid", hwid ],
		[ "x-device-os", b.os ],
		[ "x-ver-os", b.ver ],
		[ "x-device-model", b.model ]
	];
}

// Один HTTP-запрос: тело и заголовки — в отдельные файлы, код ответа — в stdout.
// sh() пишет stdout команды в свой tmp, поэтому код читаем оттуда.
function fetch_one(url, ua, hwid) {
	sh_seq++;
	let base = "/tmp/.shoulderkop.fetch." + own_pid() + "." + sh_seq;
	let bodyf = base + ".body";
	let headf = base + ".head";

	let cmd = "curl -s -L -m 30 -A '" + hdr_val(ua) + "'";
	for (let h in fetch_headers(hwid))
		if (hdr_val(h[1]) != "")
			cmd += " -H '" + h[0] + ": " + hdr_val(h[1]) + "'";
	cmd += " -D " + headf + " -o " + bodyf + " -w '%{http_code}' '" + url + "'";

	let raw_code = trim(sh(cmd));
	let code = (raw_code == "") ? 0 : int(raw_code);
	let body = fs.readfile(bodyf);
	let head = fs.readfile(headf);
	try { fs.unlink(bodyf); } catch (e) {}
	try { fs.unlink(headf); } catch (e) {}

	return {
		http: code,
		body: (body == null) ? "" : body,
		headers: (head == null) ? "" : head
	};
}

// Скачать все подписки и собрать уникальные узлы (дедуп по полной identity).
// status:
//   active   — есть настоящие серверы, можно раскладывать;
//   expired  — панель отдала заглушку/404: туннель надо остановить;
//   error    — сеть/панель/формат: конфиг и сервисы не трогаем.
function fetch_nodes() {
	let urls = uci_list("shoulderkop", "settings", "subscription_url");
	let ua = uci_get("shoulderkop", "settings", "user_agent");
	if (ua == "")
		ua = UA;
	let hwid = uci_get("shoulderkop", "settings", "hwid");

	let nodes = [];
	let seen = {};
	let errors = [];
	let warnings = [];
	let checked = [];
	let expired = 0;
	let active = 0;
	let failed = 0;
	let attempted = 0;
	let userinfo = null;
	let expired_userinfo = null;
	let allow_xhttp = engine_extended();
	let now = time();

	for (let url in urls) {
		url = trim(url);
		if (url == "")
			continue;
		attempted++;

		let res = fetch_one(url, ua, hwid);

		if (res.http == 404 || res.http == 410) {
			let ui = subscription.parse_userinfo(res.headers);
			expired++;
			if (ui.present)
				expired_userinfo = ui;
			push(checked, { url: url, http: res.http, status: "expired",
				reason: "HTTP " + res.http, expire: ui.expire });
			continue;
		}

		if (res.http == 0) {
			failed++;
			push(errors, "request failed: " + url);
			push(checked, { url: url, http: 0, status: "error", reason: "request failed" });
			continue;
		}

		if (res.http < 200 || res.http >= 300) {
			failed++;
			push(errors, "HTTP " + res.http + ": " + url);
			push(checked, { url: url, http: res.http, status: "error",
				reason: "HTTP " + res.http });
			continue;
		}

		// Пустой ответ не считаем ошибкой сразу: панель может отдать
		// expire в заголовке subscription-userinfo без тела — тогда это
		// истёкшая подписка. classify_response разберётся.
		let parsed = null;
		try {
			parsed = subscription.parse_subscription(res.body, allow_xhttp);
		} catch (e) {
			parsed = { nodes: [], skipped: [] };
		}

		let cls = subscription.classify_response({
			http: res.http,
			body: res.body,
			headers: res.headers,
			nodes: parsed.nodes,
			skipped: parsed.skipped,
			now: now
		});

		if (cls.status == "expired") {
			expired++;
			if (cls.userinfo.present)
				expired_userinfo = cls.userinfo;
			push(checked, { url: url, http: res.http, status: "expired",
				reason: cls.reason, expire: cls.userinfo.expire });
			continue;
		}

		if (cls.status != "active") {
			failed++;
			push(errors, cls.reason + ": " + url);
			for (let n in parsed.skipped)
				push(errors, "skipped " + n.name + ": " + n.reason);
			push(checked, { url: url, http: res.http, status: "error",
				reason: cls.reason, expire: cls.userinfo.expire });
			continue;
		}

		// Заглушки из смешанного ответа не раскладываем
		let real = 0;
		for (let n in parsed.nodes) {
			if (subscription.is_placeholder_node(n))
				continue;
			real++;
			let id = n.link;
			if (seen[id])
				continue;
			seen[id] = true;
			push(nodes, n);
		}

		if (real == 0) {
			failed++;
			push(errors, "no usable nodes: " + url);
			push(checked, { url: url, http: res.http, status: "error",
				reason: "no usable nodes" });
			continue;
		}

		active++;
		userinfo = cls.userinfo;
		for (let n in parsed.skipped)
			push(errors, "skipped " + n.name + ": " + n.reason);
		push(checked, { url: url, http: res.http, status: "active",
			reason: "", expire: cls.userinfo.expire });
	}

	if (attempted == 0)
		push(errors, "no subscription url configured");

	let status;
	if (active > 0) {
		status = "active";
		if (expired > 0)
			push(warnings, "часть подписок неактивна (истекла или отключена) — их узлы пропущены");
	}
	else if (expired > 0 && failed == 0) {
		status = "expired";
	}
	else {
		status = "error";
	}

	return {
		nodes: nodes,
		errors: errors,
		warnings: warnings,
		status: status,
		checked: checked,
		active: active,
		failed: failed,
		userinfo: (userinfo == null) ? expired_userinfo : userinfo
	};
}

function reload_podkop() {
	// на чистом роутере podkop может отсутствовать — просто нечего перезагружать
	if (fs.stat("/etc/init.d/podkop") == null)
		return;
	system("/etc/init.d/podkop reload >/dev/null 2>&1");
}

function write_state(result) {
	fs.writefile(STATE, sprintf("%J", result));
}

// применить узлы и вернуть отчёт; opts.no_reload — не дёргать podkop,
// пока он на паузе (после resume его старт сам прочитает новый конфиг)
function apply_nodes(nodes, errors, warnings, opts) {
	opts = opts || {};
	let applied = null;
	if (length(nodes) > 0) {
		applied = applymod.apply(nodes);
		if (applied.error != null)
			push(errors, applied.error);
		if (applied.changed && !opts.no_reload)
			reload_podkop();
	}

	return {
		count: length(nodes),
		mode: (applied != null) ? applied.mode : uci_get("shoulderkop", "settings", "mode"),
		lan: (applied != null) ? applied.lan : null,
		engine_decode_link: (applied != null) ? applied.engine_decode_link : null,
		// единый источник состояния: он же знает про паузу подписки
		service: lifecycle.service_state(),
		reloaded: (applied != null && applied.changed && !opts.no_reload) ? true : false,
		applied: (applied != null) ? applied.report : [],
		removed: (applied != null) ? applied.removed : [],
		errors: errors,
		warnings: warnings
	};
}

// full rebuild: drop all skop_* sections, apply recreates them from scratch
function wipe_sections() {
	let c = uci.cursor();
	c.load("podkop");

	let names = [];
	c.foreach("podkop", "section", function (s) {
		if (substr(s[".name"], 0, 5) == "skop_")
			push(names, s[".name"]);
	});
	for (let n in names)
		c.delete("podkop", n);
	if (length(names) > 0)
		c.commit("podkop");

	return length(names);
}

// ---- настройки из командной строки ---------------------------------------
//
// LuCI-страница не полагается на «Сохранить и применить»: она передаёт текущие
// значения виджетов аргументами, а конфиг пишем здесь (uci.cursor), потому что
// путь uci.save()/uci.apply() через rpcd на этой прошивке отдаёт Access denied.

// --yt-lists=youtube,telegram → [ "youtube", "telegram" ]
function split_arg_list(s) {
	let out = [];
	for (let v in split("" + s, ",")) {
		v = trim(v);
		if (v != "")
			push(out, v);
	}
	return out;
}

function parse_args(argv) {
	let a = { urls: [], rebuild: false };

	for (let i = 1; i < length(argv); i++) {
		let v = argv[i];

		if (v == "--rebuild")
			a.rebuild = true;
		else if (substr(v, 0, 6) == "--url=")
			push(a.urls, substr(v, 6));
		else if (substr(v, 0, 7) == "--mode=")
			a.mode = substr(v, 7);
		else if (substr(v, 0, 11) == "--interval=")
			a.interval = substr(v, 11);
		else if (substr(v, 0, 11) == "--urltest=")
			a.urltest = substr(v, 11);
		else if (substr(v, 0, 11) == "--schedule=")
			a.schedule = substr(v, 11);

		else if (substr(v, 0, 11) == "--yt-lists=")
			a.yt_lists = split_arg_list(substr(v, 11));
		else if (substr(v, 0, 11) == "--eu-lists=")
			a.eu_lists = split_arg_list(substr(v, 11));
	}

	return a;
}

function save_settings(a) {
	if (a == null)
		return 0;

	let c = uci.cursor();
	c.load("shoulderkop");
	if (!c.get("shoulderkop", "settings"))
		return 0;

	let dirty = 0;

	function put(opt, val) {
		if (val == null)
			return;
		if (sprintf("%J", c.get("shoulderkop", "settings", opt)) == sprintf("%J", val))
			return;
		c.set("shoulderkop", "settings", opt, val);
		dirty++;
	}

	// UCI-список: пустой массив = опции нет (apply тогда берёт значения по умолчанию)
	function put_list(opt, val) {
		if (val == null)
			return;

		let cur = c.get("shoulderkop", "settings", opt);
		if (type(cur) != "array")
			cur = (cur == null || cur == "") ? [] : [ "" + cur ];

		if (length(cur) == length(val)) {
			let same = true;
			for (let i = 0; i < length(val); i++)
				if ("" + cur[i] != "" + val[i])
					same = false;
			if (same)
				return;
		}

		if (length(val) == 0)
			c.delete("shoulderkop", "settings", opt);
		else
			c.set("shoulderkop", "settings", opt, val);
		dirty++;
	}

	if (length(a.urls) > 0)
		put("subscription_url", a.urls);
	put("mode", a.mode);
	put("update_interval", a.interval);
	put("urltest_interval", a.urltest);
	put("enable_schedule", a.schedule);
	put_list("wifi_yt_lists", a.yt_lists);
	put_list("wifi_eu_lists", a.eu_lists);

	if (dirty > 0)
		c.commit("shoulderkop");

	return dirty;
}

function cmd_update(a) {
	migrate_settings();
	save_settings(a);

	let fetched = fetch_nodes();
	let nodes = fetched.nodes;
	let suspended = lifecycle.is_suspended();

	// Сначала узнаём статус подписки — и только потом трогаем секции.
	// При истёкшей/недоступной подписке старая раскладка остаётся на месте.
	//
	// Если активных подписок стало меньше (одна истекла или её убрали из
	// списка), серверы из неё уже мертвы: панель удаляет клиента вместе с
	// uuid. Поэтому один раз пересобираем секции, чтобы мёртвые серверы не
	// остались в секции, которую оставшаяся подписка не заполняет.
	// Не делаем этого, когда часть ссылок ответила ошибкой сети: тогда
	// непонятно, подписка кончилась или панель временно недоступна.
	let prev_subs = int("" + (uci_get("shoulderkop", "settings", "last_active_subs") || "0"));
	let shrink = (fetched.status == "active" && prev_subs > 0 &&
		fetched.active < prev_subs && fetched.failed == 0);

	let wiped = 0;
	if (fetched.status == "active" && (a.rebuild || shrink))
		wiped = wipe_sections();

	fs.writefile(CACHE, sprintf("%J", {
		updated: time(),
		status: fetched.status,
		nodes: (fetched.status == "active") ? nodes : [],
		errors: fetched.errors,
		warnings: fetched.warnings,
		userinfo: fetched.userinfo,
		checked: fetched.checked
	}));

	// предупреждение только в отчёте этого запуска: в кэш его не кладём, иначе
	// оно всплывёт в следующем «apply» без причины
	if (shrink && !a.rebuild && wiped > 0)
		push(fetched.warnings, "подписок стало меньше: секции Podkop пересобраны, серверы исчезнувшей подписки удалены");

	if (fetched.status == "expired") {
		let sus = lifecycle.suspend();
		let result = {
			updated: time(),
			status: "expired",
			count: 0,
			mode: uci_get("shoulderkop", "settings", "mode"),
			lan: null,
			engine_decode_link: null,
			service: lifecycle.service_state(),
			reloaded: false,
			applied: [],
			removed: [],
			errors: fetched.errors,
			warnings: fetched.warnings,
			userinfo: fetched.userinfo,
			checked: fetched.checked,
			suspended: true,
			suspended_at: sus.at,
			actions: sus.actions
		};
		for (let e in sus.errors)
			push(result.errors, e);
		if (uci_get("shoulderkop", "settings", "enable_schedule") != "1")
			push(result.warnings, "расписание выключено: проверить активацию подписки автоматически не получится");
		write_state(result);
		print(sprintf("%J", result));
		return 0;
	}

	if (fetched.status != "active") {
		// Сеть/панель/формат: туннель не трогаем, конфиг не применяем.
		let info = lifecycle.suspended_info();
		let result = {
			updated: time(),
			status: "error",
			count: 0,
			mode: uci_get("shoulderkop", "settings", "mode"),
			lan: null,
			engine_decode_link: null,
			service: lifecycle.service_state(),
			reloaded: false,
			applied: [],
			removed: [],
			errors: fetched.errors,
			warnings: fetched.warnings,
			userinfo: fetched.userinfo,
			checked: fetched.checked,
			suspended: suspended,
			suspended_at: info.at
		};
		write_state(result);
		print(sprintf("%J", result));
		return 1;
	}

	let result = apply_nodes(nodes, fetched.errors, fetched.warnings, { no_reload: suspended });
	result.updated = time();
	result.status = "active";
	result.userinfo = fetched.userinfo;
	result.checked = fetched.checked;
	result.suspended = false;
	result.resumed = false;
	result.rebuilt = (shrink && wiped > 0);

	// запоминаем число активных подписок для следующего сравнения; при ошибке
	// сети значение не трогаем, чтобы истёкшую ссылку не спутать с недоступной
	if (fetched.failed == 0)
		uci_set("shoulderkop", "settings", "last_active_subs", "" + fetched.active);

	if (suspended) {
		let r = lifecycle.resume();
		result.resumed = r.resumed;
		result.resume_actions = r.actions;
		for (let e in r.errors)
			push(result.errors, e);
		result.suspended = r.suspended;
		result.service = lifecycle.service_state();
	}

	// узлы снова появились — если сидели в direct, возвращаемся в туннель
	if (uci_get("shoulderkop", "settings", "direct_mode") == "1") {
		let dr = diagmod.after_update();
		result.direct_left = dr.left_direct;
		for (let a in dr.actions)
			push(result.warnings, a);
	}

	write_state(result);
	print(sprintf("%J", result));
	return 0;
}

// применить без повторного скачивания (кнопка «Сохранить и применить» в LuCI)
function cmd_apply(a) {
	migrate_settings();
	save_settings(a);

	let raw = fs.readfile(CACHE);
	let cache = null;
	if (raw != null && raw != "") {
		try { cache = json(raw); } catch (e) { cache = null; }
	}
	let nodes = (cache == null) ? [] : (cache.nodes || []);
	let suspended = lifecycle.is_suspended();

	if (length(nodes) == 0) {
		let expired = (cache != null && cache.status == "expired") || suspended;
		let result = {
			updated: time(),
			status: expired ? "expired" : "error",
			count: 0,
			mode: uci_get("shoulderkop", "settings", "mode"),
			lan: null,
			engine_decode_link: null,
			service: lifecycle.service_state(),
			reloaded: false,
			applied: [],
			removed: [],
			errors: expired ? [] : [ "no cached nodes, run update first" ],
			warnings: [],
			userinfo: (cache == null) ? null : cache.userinfo,
			checked: (cache == null) ? [] : (cache.checked || []),
			suspended: suspended,
			suspended_at: lifecycle.suspended_info().at
		};
		if (expired) {
			let sus = lifecycle.suspend();
			result.suspended = true;
			result.suspended_at = sus.at;
			result.actions = sus.actions;
			for (let e in sus.errors)
				push(result.errors, e);
			push(result.warnings, "подписка неактивна: узлов нет, туннель остаётся на паузе");
		}
		write_state(result);
		print(sprintf("%J", result));
		return expired ? 0 : 1;
	}

	if (a.rebuild)
		wipe_sections();

	let result = apply_nodes(nodes,
		(cache.errors || []), (cache.warnings || []), { no_reload: suspended });
	result.updated = time();
	result.status = "active";
	result.userinfo = (cache == null) ? null : cache.userinfo;
	result.checked = (cache == null) ? [] : (cache.checked || []);
	result.suspended = false;
	result.resumed = false;

	if (suspended) {
		let r = lifecycle.resume();
		result.resumed = r.resumed;
		result.resume_actions = r.actions;
		for (let e in r.errors)
			push(result.errors, e);
		result.suspended = r.suspended;
		result.service = lifecycle.service_state();
	}

	write_state(result);
	print(sprintf("%J", result));
	return 0;
}

// Кэша нет (свежая установка, ребут) — не заставляем пользователя сначала жать
// «Обновить сейчас», а просто идём в подписку и наполняем кэш.
function cmd_list_servers() {
	let raw = fs.readfile(CACHE);
	let cache = null;
	if (raw != null && raw != "") {
		try { cache = json(raw); } catch (e) { cache = null; }
	}

	if (cache == null || length(cache.nodes || []) == 0) {
		let fetched = fetch_nodes();
		if (fetched.status == "active" || fetched.status == "expired") {
			cache = {
				updated: time(),
				status: fetched.status,
				nodes: (fetched.status == "active") ? fetched.nodes : [],
				errors: fetched.errors,
				warnings: fetched.warnings,
				userinfo: fetched.userinfo,
				checked: fetched.checked
			};
			fs.writefile(CACHE, sprintf("%J", cache));
		}
	}

	let out = [];
	for (let n in ((cache == null) ? [] : (cache.nodes || [])))
		push(out, { name: n.name, link: n.link });
	print(sprintf("%J", out));
	return 0;
}

function cmd_status() {
	let raw = fs.readfile(STATE);
	let st = null;
	if (raw != null && raw != "") {
		try { st = json(raw); } catch (e) { st = null; }
	}
	if (type(st) != "object")
		st = {};

	let info = lifecycle.suspended_info();
	st.suspended = info.suspended;
	st.suspended_at = info.at;
	st.suspended_init = info.init;
	st.suspended_running = info.running;
	st.services = lifecycle.service_state();

	st.errors = st.errors || [];
	st.warnings = st.warnings || [];
	st.applied = st.applied || [];
	st.removed = st.removed || [];
	st.checked = st.checked || [];

	if (st.updated == null) {
		st.updated = null;
		st.status = info.suspended ? "expired" : "unknown";
		st.count = 0;
	}

	let ds = diagmod.state();
	st.diag = {
		enabled: ds.enabled,
		interval: ds.interval,
		level: ds.level,
		direct: ds.direct,
		last: ds.report,
		history_len: length(ds.history)
	};

	print(sprintf("%J", st));
	return 0;
}

// cron-выражение под выбранный интервал (минуты разнесены, чтобы не все роутеры
// мира стучались в панель в одну и ту же минуту)
function cron_spec(iv) {
	switch (iv) {
	case "30m":
		return "17,47 * * * *";
	case "3h":
		return "13 */3 * * *";
	case "6h":
		return "13 */6 * * *";
	case "12h":
		return "13 */12 * * *";
	case "1d":
		return "13 9 * * *";
	default:
		return "13 * * * *";
	}
}

// cron для диагностики: свой интервал, отличный от обновления подписки
function diag_cron_spec(iv) {
	switch (iv) {
	case "10m":
		return "*/10 * * * *";
	case "15m":
		return "*/15 * * * *";
	case "30m":
		return "*/30 * * * *";
	default:
		return "*/5 * * * *";
	}
}

function cmd_schedule(force_off) {
	// вызывается при установке и на каждом старте: здесь же добиваем UA и HWID
	migrate_settings();

	let enabled = (uci_get("shoulderkop", "settings", "enable_schedule") == "1") && !force_off;

	// переписываем crontab, выкидывая только свои строки
	let keep = [];
	let raw = fs.readfile(CRONTAB);
	if (raw != null && raw != "") {
		for (let l in split(raw, "\n")) {
			let line = rtrim(l);
			if (line == "")
				continue;
			if (index(line, "shoulderkop") >= 0)
				continue;
			push(keep, line);
		}
	}
	if (enabled)
		push(keep, cron_spec(uci_get("shoulderkop", "settings", "update_interval")) + " " + CRON_LINE);
	// диагностика живёт своей строкой: не блокирует обновление подписки
	if (uci_get("shoulderkop", "settings", "diag_enabled") == "1" && !force_off)
		push(keep, diag_cron_spec(uci_get("shoulderkop", "settings", "diag_interval")) + " " + DIAG_CRON_LINE);

	let body = (length(keep) > 0) ? join("\n", keep) + "\n" : "";
	system("mkdir -p /etc/crontabs");
	fs.writefile(CRONTAB, body);
	system("/etc/init.d/cron restart >/dev/null 2>&1");

	// при включённом расписании нужен и автозапуск при загрузке
	if (enabled)
		system("ln -sf ../init.d/shoulderkop " + RCLINK);
	else
		system("rm -f " + RCLINK);

	print(sprintf("%J", {
		enabled: enabled,
		interval: uci_get("shoulderkop", "settings", "update_interval"),
		crontab: body,
		rclink: enabled
	}));
	return 0;
}

// печать команды скачивания — отладка заголовков устройства (x-device-os и т.п.)
function cmd_fetch_cmd(url) {
	let u = (url != null && url != "") ? url : "URL";
	let ua = uci_get("shoulderkop", "settings", "user_agent");
	if (ua == "")
		ua = UA;
	let out = "curl -s -m 30 -A '" + hdr_val(ua) + "'";
	for (let h in fetch_headers(uci_get("shoulderkop", "settings", "hwid")))
		if (hdr_val(h[1]) != "")
			out += " -H '" + h[0] + ": " + hdr_val(h[1]) + "'";
	out += " '" + hdr_val(u) + "'";
	print(out + "\n");
	return 0;
}

// Сетевая диагностика: быстро (только gstatic) или полная с починкой.
// --quiet — ничего не печатать (для cron), --json — машинный отчёт (LuCI).
function cmd_diag(argv) {
	let opts = { quick: false, force: false, resume: false, quiet: false };
	let as_json = false;
	for (let i = 1; i < length(argv); i++) {
		let v = argv[i];
		if (v == "--quick")
			opts.quick = true;
		else if (v == "--force")
			opts.force = true;
		else if (v == "--resume")
			opts.resume = true;
		else if (v == "--quiet")
			opts.quiet = true;
		else if (v == "--json")
			as_json = true;
	}
	if (as_json)
		opts.quick = false;

	let r = diagmod.run(opts);

	if (opts.quiet)
		return r.ok ? 0 : 1;

	if (as_json) {
		print(sprintf("%J", r));
		return r.ok ? 0 : 1;
	}

	print("диагностика: " + (r.skipped ? "выключена" : (r.ok ? "ok" : "есть проблемы")) + "\n");
	for (let c in (r.checks || []))
		print((c.ok ? "  [ok] " : "  [!]  ") + c.name + ": " + c.detail + "\n");
	for (let a in (r.actions || []))
		print("  починка: " + a + "\n");
	for (let e in (r.errors || []))
		print("  ошибка: " + e + "\n");
	return r.ok ? 0 : 1;
}

let cmd = ARGV[0] || "help";

if (cmd == "convert") {
	exit(cmd_convert(ARGV[1]));
} else if (cmd == "update") {
	exit(cmd_update(parse_args(ARGV)));
} else if (cmd == "apply") {
	exit(cmd_apply(parse_args(ARGV)));
} else if (cmd == "list_servers") {
	exit(cmd_list_servers());
} else if (cmd == "fetch_cmd") {
	exit(cmd_fetch_cmd(ARGV[1]));
} else if (cmd == "status") {
	exit(cmd_status());
} else if (cmd == "schedule") {
	exit(cmd_schedule(ARGV[1] == "off"));
} else if (cmd == "diag") {
	exit(cmd_diag(ARGV));
} else {
	print("usage: shoulderkop <convert|update|apply|list_servers|status|schedule|diag> [--rebuild] [--url=..] [--mode=lte|wifi] [--interval=1h] [--urltest=30s] [--schedule=0|1] [--yt-lists=youtube] [--eu-lists=russia_inside,telegram] [off]");
	exit(2);
}
