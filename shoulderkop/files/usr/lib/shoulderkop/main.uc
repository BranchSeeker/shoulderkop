// shoulderkop — энтипоинт (CLI + rpcd через fs.exec).
//
// Команды:
//   convert <file>     — распарсить файл подписки и вывести узлы (отладка без устройства)
//   update             — скачать подписки, распарсить, разложить по секциям podkop;
//                        при истёкшей подписке — остановить podkop/sing-box
//   apply              — то же, но без скачивания: применить узлы из кэша
//   list_servers       — вывести узлы из кэша (при пустом кэше — сходить в подписку)
//   links              — outbounds подписки/секций podkop → vless:// ссылки
//   status             — вывести состояние последнего обновления и паузы
//   schedule [off]     — переустановить cron-задачу по enable_schedule/update_interval

'use strict';

let fs = require("fs");
let uci = require("uci");
let subscription = require("subscription");
let convert = require("convert");
let fetchmod = require("fetch");
let applymod = require("apply");
let lifecycle = require("lifecycle");
let diagmod = require("diag");
let selfupd = require("selfupdate");
let podkopctl = require("podkopctl");

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

function quiet(cmd) {
	system(cmd + " >/dev/null 2>&1");
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

	// uci отдаёт list-опцию одной строкой через пробел; иногда значения
	// попадают и с переводами строк. Делим по любому пробельному символу,
	// иначе два URL склеиваются в один и curl отвечает «URL rejected».
	raw = replace(replace(raw, "\n", " "), "\t", " ");
	let out = [];
	for (let part in split(raw, " ")) {
		part = trim(part);
		if (part != "")
			push(out, part);
	}
	return out;
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

// Остатки LTE (0.5.x): каталог кэша белых списков, его копия в /www и наша
// настройка podkop «качать списки через прокси». Вызывается один раз —
// migrate_settings по флагу lists_seeded.
function drop_lte_leftovers() {
	quiet("rm -rf /etc/shoulderkop/lists /www/shoulderkop-lists");

	let p = uci.cursor();
	if (!p.load("podkop"))
		return;
	let dirty = false;
	for (let opt in [ "download_lists_via_proxy", "download_lists_via_proxy_section" ]) {
		if (p.get("podkop", "settings", opt) != null) {
			p.delete("podkop", "settings", opt);
			dirty = true;
		}
	}
	if (dirty)
		p.commit("podkop");
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

	// Режим один — «Домашний интернет» (wifi): поля mode в конфиге больше нет,
	// а у обновившихся с LTE оно снимается.
	if (c.get("shoulderkop", "settings", "mode") != null) {
		c.delete("shoulderkop", "settings", "mode");
		changed = true;
	}

	// Миграция 0.6.0 ровно один раз (флаг lists_seeded): остатки LTE и дефолты
	// списков сообщества. Флаг, а не «опций нет», потому что пустой список в
	// конфиге — выбор пользователя, и roblox туда возвращаться не должен.
	if ("" + (c.get("shoulderkop", "settings", "lists_seeded") || "") != "1") {
		drop_lte_leftovers();
		if (c.get("shoulderkop", "settings", "wifi_yt_lists") == null)
			c.set("shoulderkop", "settings", "wifi_yt_lists", "youtube");
		if (c.get("shoulderkop", "settings", "wifi_eu_lists") == null)
			c.set("shoulderkop", "settings", "wifi_eu_lists",
				[ "russia_inside", "telegram", "meta", "cloudflare", "hodca", "roblox" ]);
		c.set("shoulderkop", "settings", "lists_seeded", "1");
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

	// Автообновление пакета. По умолчанию выключено: обновление меняет
	// установленную версию, это должно быть осознанным выбором.
	if (c.get("shoulderkop", "settings", "auto_update") == null) {
		c.set("shoulderkop", "settings", "auto_update", "0");
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

// Один HTTP-запрос через fetch.uc. Он сам перебирает обычный и прямой путь
// (WAN + DNS провайдера + обход nft-метки podkop), поэтому подписка
// обновляется, даже когда туннель поднят, но все серверы мертвы.
function fetch_one(url, ua, hwid) {
	let r = fetchmod.fetch(url, { ua: ua, headers: fetch_headers(hwid), proxy: true });
	return {
		http: r.http,
		body: r.body,
		headers: r.headers,
		via: r.via,
		ip: r.ip
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
				reason: "HTTP " + res.http, expire: ui.expire, via: res.via });
			continue;
		}

		if (res.http == 0) {
			failed++;
			push(errors, "request failed: " + url);
			push(checked, { url: url, http: 0, status: "error", reason: "request failed",
				via: res.via });
			continue;
		}

		if (res.http < 200 || res.http >= 300) {
			failed++;
			push(errors, "HTTP " + res.http + ": " + url);
			push(checked, { url: url, http: res.http, status: "error",
				reason: "HTTP " + res.http, via: res.via });
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
				reason: cls.reason, expire: cls.userinfo.expire, via: res.via });
			continue;
		}

		if (cls.status != "active") {
			failed++;
			push(errors, cls.reason + ": " + url);
			for (let n in parsed.skipped)
				push(errors, "skipped " + n.name + ": " + n.reason);
			push(checked, { url: url, http: res.http, status: "error",
				reason: cls.reason, expire: cls.userinfo.expire, via: res.via });
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
				reason: "no usable nodes", via: res.via });
			continue;
		}

		active++;
		userinfo = cls.userinfo;
		for (let n in parsed.skipped)
			push(errors, "skipped " + n.name + ": " + n.reason);
		push(checked, { url: url, http: res.http, status: "active",
			reason: "", expire: cls.userinfo.expire, via: res.via });
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

function write_state(result) {
	fs.writefile(STATE, sprintf("%J", result));
}

// лок на путь «запись конфига podkop → restart → ожидание»: берётся в
// cmd_update/cmd_apply и снимается здесь же, на любом выходе
let lock_held = false;

function finish(result, code) {
	if (lock_held) {
		podkopctl.lock_release();
		lock_held = false;
	}
	write_state(result);
	print(sprintf("%J", result));
	return code;
}

// Правда о туннеле в отчёте. tunnel_up/dns_* берём только из результатов
// restart_and_wait(), cleanup() или ожидания внутри resume(); пока действий не
// было — null, чтобы состояние «до» не выдавалось за результат (решение 11).
function tunnel_report(result, src, internet_ok) {
	let s = src || {};
	result.tunnel_up = (s.tunnel_up == null) ? null : (s.tunnel_up == true);
	result.dns_points_to_podkop = (s.dns_ok == null) ? null : (s.dns_ok == true);
	result.dns_ok = result.dns_points_to_podkop;
	result.internet_ok = (internet_ok == null) ? null : (internet_ok == true);
	return result;
}

// отчёт, когда применить настройки не дали: другой запуск уже держит лок.
// Ничего не измеряли и не трогали — поля туннеля остаются null.
function busy_report() {
	let r = {
		updated: time(),
		status: "busy",
		count: 0,
		mode: "wifi",
		lan: null,
		engine_decode_link: null,
		service: lifecycle.service_state(),
		reloaded: false,
		applied: [],
		removed: [],
		errors: [ "другой запуск shoulderkop уже применяет настройки — повторите позже" ],
		warnings: [],
		userinfo: null,
		checked: [],
		suspended: lifecycle.is_suspended(),
		suspended_at: lifecycle.suspended_info().at,
		restart_attempts: 0,
		paused_clean: null
	};
	return tunnel_report(r, null, null);
}

// применить узлы и вернуть отчёт; podkop здесь не перезапускается — это делает
// tunnel_restart() после раскладки, под тем же локом
function apply_nodes(nodes, errors, warnings, opts) {
	opts = opts || {};
	let applied = null;
	if (length(nodes) > 0) {
		applied = applymod.apply(nodes, { rebuild: opts.rebuild == true });
		if (applied.error != null)
			push(errors, applied.error);
	}

	let r = {
		count: length(nodes),
		mode: "wifi",
		lan: (applied != null) ? applied.lan : null,
		engine_decode_link: (applied != null) ? applied.engine_decode_link : null,
		// единый источник состояния: он же знает про паузу подписки
		service: lifecycle.service_state(),
		reloaded: false,
		applied: (applied != null) ? applied.report : [],
		removed: (applied != null) ? applied.removed : [],
		rebuilt: (applied != null) ? (applied.rebuilt == true) : false,
		errors: errors,
		warnings: warnings,
		restart_attempts: 0,
		// паузы в этом запуске не было — чистить было нечего: null, а не false
		// (false значит «пауза была, но чистка не удалась»)
		paused_clean: null
	};
	return tunnel_report(r, null, null);
}

// Перезапуск podkop после раскладки: restart (не reload) и ожидание готовности.
// Не стартуем podkop, который пользователь держит выключенным; на паузе
// вызывающий сам решает не поднимать туннель.
function tunnel_restart(result) {
	let st = podkopctl.state();
	if (!st.installed || (!st.enabled && !st.tunnel_up && !st.running))
		return result;

	let rs = podkopctl.restart_and_wait();
	result.reloaded = (rs.attempts > 0);
	result.restart_attempts = rs.attempts;
	tunnel_report(result, rs, null);
	for (let e in rs.errors)
		push(result.errors, e);
	return result;
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
		else if (substr(v, 0, 11) == "--interval=")
			a.interval = substr(v, 11);
		else if (substr(v, 0, 11) == "--urltest=")
			a.urltest = substr(v, 11);
		else if (substr(v, 0, 11) == "--schedule=")
			a.schedule = substr(v, 11);
		else if (substr(v, 0, 14) == "--auto-update=")
			a.auto_update = substr(v, 14);

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

	// UCI-список: пустой массив = опции нет, а значит и списка в podkop нет
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

	// file:// и прочие не-HTTP адреса — отладочные (--url=file:///…): в конфиг
	// их не пишем, иначе тестовый запуск затрёт настоящую подписку
	let http_urls = [];
	for (let u in a.urls) {
		let v = trim("" + u);
		if (substr(v, 0, 7) == "http://" || substr(v, 0, 8) == "https://")
			push(http_urls, v);
	}
	if (length(http_urls) > 0)
		put("subscription_url", http_urls);
	put("update_interval", a.interval);
	put("urltest_interval", a.urltest);
	put("enable_schedule", a.schedule);
	put("auto_update", a.auto_update);
	put_list("wifi_yt_lists", a.yt_lists);
	put_list("wifi_eu_lists", a.eu_lists);

	if (dirty > 0)
		c.commit("shoulderkop");

	return dirty;
}

function cmd_update(a) {
	// «Запись конфига podkop → restart → ожидание» идёт под файловым локом:
	// параллельный apply из LuCI или cron не должны перезапускать podkop
	// одновременно и видеть чужой restart как «туннель лёг».
	if (!podkopctl.lock_acquire()) {
		print(sprintf("%J", busy_report()));
		return 0;
	}
	lock_held = true;

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

	fs.writefile(CACHE, sprintf("%J", {
		updated: time(),
		status: fetched.status,
		nodes: (fetched.status == "active") ? nodes : [],
		errors: fetched.errors,
		warnings: fetched.warnings,
		userinfo: fetched.userinfo,
		checked: fetched.checked
	}));

	if (fetched.status == "expired") {
		let sus = lifecycle.suspend();
		let result = {
			updated: time(),
			status: "expired",
			count: 0,
			mode: "wifi",
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
			actions: sus.actions,
			restart_attempts: 0,
			paused_clean: sus.paused_clean == true
		};
		// tunnel_up и резолв — из проверенного результата cleanup() в suspend()
		tunnel_report(result, sus, sus.internet_ok == true);
		for (let e in sus.errors)
			push(result.errors, e);
		if (uci_get("shoulderkop", "settings", "enable_schedule") != "1")
			push(result.warnings, "расписание выключено: проверить активацию подписки автоматически не получится");
		return finish(result, 0);
	}

	if (fetched.status != "active") {
		// Сеть/панель/формат: туннель не трогаем, конфиг не применяем.
		let info = lifecycle.suspended_info();
		let result = {
			updated: time(),
			status: "error",
			count: 0,
			mode: "wifi",
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
			suspended_at: info.at,
			restart_attempts: 0,
			paused_clean: null
		};
		return finish(tunnel_report(result, null, null), 1);
	}

	// раскладка: rebuild = «Пересобрать секции» или подписок стало меньше
	let result = apply_nodes(nodes, fetched.errors, fetched.warnings,
		{ rebuild: (a.rebuild || shrink) });
	result.updated = time();
	result.status = "active";
	result.userinfo = fetched.userinfo;
	result.checked = fetched.checked;
	result.suspended = false;
	result.resumed = false;
	result.restart_attempts = 0;

	// предупреждение только в отчёте этого запуска: в кэш его не кладём, иначе
	// оно всплывёт в следующем «apply» без причины
	if (shrink && !a.rebuild && result.rebuilt)
		push(result.warnings, "подписок стало меньше: секции Podkop пересобраны, серверы исчезнувшей подписки удалены");

	// запоминаем число активных подписок для следующего сравнения; при ошибке
	// сети значение не трогаем, чтобы истёкшую ссылку не спутать с недоступной
	if (fetched.failed == 0)
		uci_set("shoulderkop", "settings", "last_active_subs", "" + fetched.active);

	if (suspended) {
		// подписка снова активна — resume() сам вернёт автозапуск и поднимет podkop
		let r = lifecycle.resume();
		result.resumed = r.resumed;
		result.resume_actions = r.actions;
		for (let e in r.errors)
			push(result.errors, e);
		result.suspended = r.suspended;
		result.service = lifecycle.service_state();
		// tunnel_up/dns_ok — из ожидания внутри resume(), а не из повторного опроса
		tunnel_report(result, r, null);
	} else {
		// сразу после раскладки: restart (не reload) и ожидание готовности
		tunnel_restart(result);
	}
	result.internet_ok = diagmod.internet_ok();

	// узлы снова появились — если сидели в direct, возвращаемся в туннель
	if (uci_get("shoulderkop", "settings", "direct_mode") == "1") {
		let dr = diagmod.after_update();
		result.direct_left = dr.left_direct;
		for (let a in dr.actions)
			push(result.warnings, a);
	}

	return finish(result, 0);
}

// применить без повторного скачивания (кнопка «Сохранить и применить» в LuCI)
function cmd_apply(a) {
	if (!podkopctl.lock_acquire()) {
		print(sprintf("%J", busy_report()));
		return 0;
	}
	lock_held = true;

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
			mode: "wifi",
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
			suspended_at: lifecycle.suspended_info().at,
			restart_attempts: 0,
			paused_clean: null
		};
		if (expired) {
			let sus = lifecycle.suspend();
			result.suspended = true;
			result.suspended_at = sus.at;
			result.actions = sus.actions;
			result.paused_clean = sus.paused_clean == true;
			// tunnel_up и резолв — из проверенного результата cleanup()
			tunnel_report(result, sus, sus.internet_ok == true);
			for (let e in sus.errors)
				push(result.errors, e);
			push(result.warnings, "подписка неактивна: узлов нет, туннель остаётся на паузе");
		}
		else {
			tunnel_report(result, null, null);
		}
		return finish(result, expired ? 0 : 1);
	}

	let result = apply_nodes(nodes,
		(cache.errors || []), (cache.warnings || []), { rebuild: a.rebuild });
	result.updated = time();
	result.status = "active";
	result.userinfo = (cache == null) ? null : cache.userinfo;
	result.checked = (cache == null) ? [] : (cache.checked || []);
	result.suspended = false;
	result.resumed = false;
	result.restart_attempts = 0;

	if (suspended) {
		let r = lifecycle.resume();
		result.resumed = r.resumed;
		result.resume_actions = r.actions;
		for (let e in r.errors)
			push(result.errors, e);
		result.suspended = r.suspended;
		result.service = lifecycle.service_state();
		// tunnel_up/dns_ok — из ожидания внутри resume()
		tunnel_report(result, r, null);
	} else {
		tunnel_restart(result);
	}
	result.internet_ok = diagmod.internet_ok();

	return finish(result, 0);
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

// ---- links: outbounds → vless:// -----------------------------------------
//
// Обратная операция к convert.uc: берём узлы подписки (из кэша, файла или
// URL) либо outbound_json уже разложенных секций podkop и печатаем vless-ссылки.
// Это то, что podkop кладёт в urltest_proxy_links для нативных urltest-секций.
//
//   shoulderkop links [--section=yt|eu] [--json] [--grouped]
//                     [--file=SUB] [--url=URL]
//   shoulderkop links --podkop [--section=yt|eu]

function as_array(v) {
	if (type(v) == "array")
		return v;
	if (v == null || "" + v == "")
		return [];
	return [ "" + v ];
}

function links_section_match(name, want) {
	if (want == null || want == "" || want == "all")
		return true;
	if (name == want)
		return true;
	return (name == "skop_" + want);
}

// имя узла из #fragment ссылки (для --podkop --json)
function link_tag(link) {
	let h = index(link, "#");
	return (h < 0) ? "" : convert.uri_decode(substr(link, h + 1));
}

// заглушки «Приложение не подходит» / «Рекомендуется Happ» — не серверы
function links_real_nodes(list) {
	let out = [];
	for (let n in list)
		if (!subscription.is_placeholder_node(n))
			push(out, n);
	return out;
}

function links_parse_file(file) {
	let text = fs.readfile(file);
	if (text == null || trim(text) == "")
		return null;
	try {
		return links_real_nodes(subscription.parse_subscription(text, engine_extended()).nodes);
	} catch (e) {
		return null;
	}
}

function links_parse_url(url) {
	let ua = uci_get("shoulderkop", "settings", "user_agent");
	if (ua == "")
		ua = UA;
	let res = fetch_one(url, ua, uci_get("shoulderkop", "settings", "hwid"));
	if (res.http < 200 || res.http >= 300)
		return null;
	try {
		return links_real_nodes(subscription.parse_subscription(res.body, engine_extended()).nodes);
	} catch (e) {
		return null;
	}
}

function links_cache_nodes() {
	let raw = fs.readfile(CACHE);
	if (raw != null && raw != "") {
		try {
			let cache = json(raw);
			if (type(cache) == "object" && length(cache.nodes || []) > 0)
				return cache.nodes;
		} catch (e) { }
	}

	// кэша нет — идём в подписку, как list_servers
	let fetched = fetch_nodes();
	return (fetched.status == "active") ? fetched.nodes : [];
}

// outbound_json секции (включая синтетическую urltest-группу) → ссылки
function podkop_outbound_links(c, sec, depth) {
	if (depth > 6)
		return [];

	let out = [];
	let pct = trim("" + (c.get("podkop", sec, "proxy_config_type") || ""));

	if (pct == "urltest" || pct == "selector") {
		let opt = (pct == "urltest") ? "urltest_proxy_links" : "selector_proxy_links";
		return as_array(c.get("podkop", sec, opt));
	}

	if (pct == "url") {
		let s = trim("" + (c.get("podkop", sec, "proxy_string") || ""));
		if (substr(s, 0, 8) == "vless://")
			push(out, s);
		return out;
	}

	let raw = c.get("podkop", sec, "outbound_json");
	if (raw == null || "" + raw == "")
		return out;

	let ob = null;
	try { ob = json(raw); } catch (e) { ob = null; }
	if (type(ob) != "object")
		return out;

	let t = lc("" + (ob.type || "vless"));
	if (t == "vless") {
		let link = convert.build_link(ob);
		if (link != null)
			push(out, link);
		return out;
	}

	// синтетическая группа: outbounds — теги дочерних секций <child>-out
	if (t == "urltest" || t == "selector") {
		for (let tag in as_array(ob.outbounds)) {
			let child = "" + tag;
			if (length(child) > 4 && substr(child, length(child) - 4) == "-out")
				child = substr(child, 0, length(child) - 4);
			if (child == sec)
				continue;
			for (let l in podkop_outbound_links(c, child, depth + 1))
				push(out, l);
		}
	}
	return out;
}

function podkop_links(section) {
	let c = uci.cursor();
	if (!c.load("podkop"))
		return [];

	let names = [];
	c.foreach("podkop", "section", function (s) {
		push(names, s[".name"]);
	});

	let rows = [];
	for (let sec in names) {
		if (substr(sec, 0, 5) != "skop_")
			continue;
		if (!links_section_match(sec, section))
			continue;
		if (trim("" + (c.get("podkop", sec, "connection_type") || "")) != "proxy")
			continue;

		for (let link in podkop_outbound_links(c, sec, 0))
			push(rows, { section: sec, name: link_tag(link), link: link });
	}
	return rows;
}

function cmd_links(argv) {
	let a = {
		json: false, grouped: false, podkop: false, duplicates: false,
		section: "", file: null, url: null
	};

	for (let i = 1; i < length(argv); i++) {
		let v = argv[i];
		if (v == "--json")
			a.json = true;
		else if (v == "--grouped")
			a.grouped = true;
		else if (v == "--podkop")
			a.podkop = true;
		else if (v == "--duplicates")
			a.duplicates = true;
		else if (substr(v, 0, 10) == "--section=")
			a.section = substr(v, 10);
		else if (substr(v, 0, 7) == "--file=")
			a.file = substr(v, 7);
		else if (substr(v, 0, 6) == "--url=")
			a.url = substr(v, 6);
	}

	let rows = [];

	if (a.podkop) {
		rows = podkop_links(a.section);
	} else {
		let nodes = null;
		if (a.file != null)
			nodes = links_parse_file(a.file);
		else if (a.url != null)
			nodes = links_parse_url(a.url);
		else
			nodes = links_cache_nodes();

		if (nodes == null) {
			print(sprintf("%J", { error: "cannot read or parse subscription" }));
			return 1;
		}
		if (length(nodes) == 0) {
			print(sprintf("%J", { error: "no nodes" }));
			return 1;
		}

		for (let g in applymod.plan_sections(nodes)) {
			if (!links_section_match(g.name, a.section))
				continue;
			for (let n in g.nodes) {
				if (n.link == null || n.link == "")
					continue;
				push(rows, { section: g.name, name: n.name, link: n.link });
			}
		}
	}

	if (length(rows) == 0) {
		print(sprintf("%J", { error: "no links", section: a.section }));
		return 1;
	}

	// по умолчанию уникальные ссылки: yt и eu могут пересекаться
	let out = [];
	let seen = {};
	for (let r in rows) {
		if (!a.duplicates && seen[r.link])
			continue;
		seen[r.link] = true;
		push(out, r);
	}

	if (a.json) {
		print(sprintf("%J", out));
		return 0;
	}

	let last = "";
	for (let r in out) {
		if (a.grouped && r.section != last) {
			if (last != "")
				print("\n");
			print("# " + r.section + "\n");
			last = r.section;
		}
		print(r.link + "\n");
	}
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

	// Набор полей отчёта одинаков в любом состоянии: LuCI и документация читают
	// их, не проверяя наличие ключей, а отчёт в /tmp мог остаться от прежней
	// версии пакета.
	if (st.mode == null)
		st.mode = "wifi";
	st.tunnel_up = (st.tunnel_up == null) ? null : (st.tunnel_up == true);
	st.dns_points_to_podkop = (st.dns_points_to_podkop == null) ? null : (st.dns_points_to_podkop == true);
	st.dns_ok = (st.dns_ok == null) ? null : (st.dns_ok == true);
	st.internet_ok = (st.internet_ok == null) ? null : (st.internet_ok == true);
	st.paused_clean = (st.paused_clean == null) ? null : (st.paused_clean == true);
	st.restart_attempts = int("" + (st.restart_attempts || 0));

	let ds = diagmod.state();
	st.diag = {
		enabled: ds.enabled,
		interval: ds.interval,
		level: ds.level,
		direct: ds.direct,
		last: ds.report,
		history_len: length(ds.history)
	};

	st.self_update = selfupd.status();

	print(sprintf("%J", st));
	return 0;
}

// Обновление пакета вручную: `shoulderkop upgrade` (короткая команда для SSH)
// и прежнее `self-update` — одна и та же функция. `update` занято обновлением
// подписки, поэтому апгрейд пакета называется upgrade.
// --check только проверяет, --force переустанавливает,
// --mirror=URL — тянуть GitHub через своё зеркало (когда github.com недоступен).
function cmd_selfupdate(argv) {
	let o = { check: false, force: false, quiet: false, json: false, mirror: "" };
	for (let i = 1; i < length(argv); i++) {
		if (argv[i] == "--check")
			o.check = true;
		else if (argv[i] == "--force")
			o.force = true;
		else if (argv[i] == "--quiet")
			o.quiet = true;
		else if (argv[i] == "--json")
			o.json = true;
		else if (substr(argv[i], 0, 9) == "--mirror=")
			o.mirror = substr(argv[i], 9);
	}

	// По SSH 10–20 секунд тишины выглядят как зависание.
	if (!o.json && !o.quiet) {
		let cur = selfupd.installed_version();
		print(((cur == "") ? "shoulderkop" : "shoulderkop " + cur) +
			": проверяю обновления на GitHub…\n");
	}

	let r = selfupd.run(o);
	if (o.json) {
		print(sprintf("%J", r));
		return (r.status == "error") ? 1 : 0;
	}
	if (o.quiet) {
		if (r.status == "error")
			system("logger -t shoulderkop 'self-update: " +
				replace(join("; ", r.errors || []), "'", "") + "'");
		return (r.status == "error") ? 1 : 0;
	}

	if (r.status == "error")
		print("обновление: ошибка — " + join("; ", r.errors || []) + "\n");
	else if (r.status == "latest")
		print("обновление: установлена последняя версия " + r.current + "\n");
	else if (r.status == "available")
		print("обновление: доступна " + r.latest + " (установлена " + r.current +
			")\nпоставить: shoulderkop upgrade\n");
	else if (r.status == "busy")
		print("обновление: уже идёт другой запуск — подождите и повторите\n");
	else if (r.status == "updated")
		print("обновление: " + r.previous + " → " + r.current +
			((r.mirror == "yes") ? " (через зеркало GitHub)\n" : "\n"));
	else
		print(sprintf("%J", r) + "\n");
	return (r.status == "error") ? 1 : 0;
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
	// автообновление пакета — раз в сутки, только если включено в настройках
	if (uci_get("shoulderkop", "settings", "auto_update") == "1" && !force_off)
		push(keep, "17 4 * * * /usr/bin/shoulderkop self-update --quiet");

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
		auto_update: (uci_get("shoulderkop", "settings", "auto_update") == "1"),
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

	if (r.skipped) {
		print("диагностика: пропущена" + ((r.reason != null) ? " (" + r.reason + ")" : "") + "\n");
		return r.ok ? 0 : 1;
	}

	print("диагностика: " + (r.ok ? "ok" : "есть проблемы") + "\n");
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
} else if (cmd == "links") {
	exit(cmd_links(ARGV));
} else if (cmd == "fetch_cmd") {
	exit(cmd_fetch_cmd(ARGV[1]));
} else if (cmd == "status") {
	exit(cmd_status());
} else if (cmd == "schedule") {
	exit(cmd_schedule(ARGV[1] == "off"));
} else if (cmd == "diag") {
	exit(cmd_diag(ARGV));
} else if (cmd == "upgrade" || cmd == "selfupdate" || cmd == "self-update") {
	exit(cmd_selfupdate(ARGV));
} else {
	print("usage: shoulderkop <convert|update|apply|list_servers|links|status|schedule|diag|upgrade|self-update> [--rebuild] [--url=..] [--interval=1h] [--urltest=30s] [--schedule=0|1] [--auto-update=0|1] [--yt-lists=youtube] [--eu-lists=russia_inside,telegram] [--section=yt|eu] [--file=..] [--json] [--grouped] [--podkop] [--force] [--mirror=https://gh-proxy.com/] [off]");
	exit(2);
}
