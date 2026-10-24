// lifecycle.uc — пауза туннеля на время неактивной подписки.
//
// Когда подписка истекла, shoulderkop:
//   1. запоминает, что было включено/запущено (podkop, sing-box);
//   2. снимает автозапуск podkop и sing-box (rc.d-симлинки);
//   3. останавливает podkop (он сам гасит sing-box, nft и возвращает dnsmasq);
//   4. ставит в UCI settings.suspended=1.
//
// Cron-задача shoulderkop при этом остаётся: следующий `update` снова сходит
// в подписку. Как только панель отдаст настоящие серверы, resume() вернёт
// автозапуск и поднимет podkop (sing-box стартует внутри podkop).
//
// Настройки podkop и секции skop_* не удаляются: конфиг ждёт активации.

'use strict';

let fs = require("fs");
let uci = require("uci");

const PODKOP = "/etc/init.d/podkop";
const SINGBOX = "/etc/init.d/sing-box";
const CONFIG = "shoulderkop";
const SECTION = "settings";

// Свой pid: в ucode нет getpid(), берём первое поле /proc/self/stat.
function own_pid() {
	let s = fs.readfile("/proc/self/stat");
	if (s == null || s == "")
		return "" + time();
	let sp = index(s, " ");
	return (sp > 0) ? substr(s, 0, sp) : "" + time();
}

let sh_seq = 0;

function sh(cmd) {
	sh_seq++;
	let tmp = "/tmp/.shoulderkop.life." + own_pid() + "." + sh_seq;
	system(cmd + " > " + tmp + " 2>/dev/null");
	let out = fs.readfile(tmp);
	fs.unlink(tmp);
	return (out == null) ? "" : out;
}

function quiet(cmd) {
	system(cmd + " >/dev/null 2>&1");
}

function init_exists(name) {
	return fs.stat("/etc/init.d/" + name) != null;
}

// rc.common enabled: ищем S-симлинк в /etc/rc.d (START может быть разным)
function is_enabled(name) {
	return trim(sh("ls /etc/rc.d/S*" + name + " 2>/dev/null")) != "";
}

// [s]ing-box — чтобы pgrep не нашёл сам себя и `sh -c`, в чьей командной
// строке иначе был бы тот же шаблон (иначе проверка всегда давала бы true).
// Запасной вариант — pidof: на некоторых сборках busybox pgrep выключен,
// а ядро из compressed-сборки называется sing-box-core.
function is_running() {
	if (trim(sh("pgrep -f '[s]ing-box[^ ]* run' 2>/dev/null")) != "")
		return true;
	return trim(sh("pidof sing-box 2>/dev/null")) != "" ||
		trim(sh("pidof sing-box-core 2>/dev/null")) != "";
}

// Правила podkop в nft живут, пока туннель поднят
function tunnel_up() {
	return trim(sh("nft list table inet PodkopTable 2>/dev/null")) != "";
}

function as_list(v) {
	if (type(v) == "array")
		return v;
	if (v == null || v == "")
		return [];
	return [ "" + v ];
}

function in_list(list, value) {
	for (let v in as_list(list))
		if ("" + v == "" + value)
			return true;
	return false;
}

function load_settings() {
	let c = uci.cursor();
	if (!c.load(CONFIG))
		return null;
	return c;
}

function is_suspended() {
	let c = load_settings();
	if (c == null)
		return false;
	return "" + (c.get(CONFIG, SECTION, "suspended") || "0") == "1";
}

function suspended_info() {
	let c = load_settings();
	if (c == null)
		return { suspended: false, at: 0, init: [], running: [] };
	return {
		suspended: "" + (c.get(CONFIG, SECTION, "suspended") || "0") == "1",
		at: int("" + (c.get(CONFIG, SECTION, "suspended_at") || "0")),
		init: as_list(c.get(CONFIG, SECTION, "suspended_init")),
		running: as_list(c.get(CONFIG, SECTION, "suspended_running"))
	};
}

// Остановить туннель и снять автозапуск. Идемпотентно: повторный вызов
// только добивает сервисы, если их подняли вручную.
function suspend() {
	let c = load_settings();
	let already = (c != null) && ("" + (c.get(CONFIG, SECTION, "suspended") || "0") == "1");

	let init_list = already ? as_list(c.get(CONFIG, SECTION, "suspended_init")) : [];
	let run_list = already ? as_list(c.get(CONFIG, SECTION, "suspended_running")) : [];
	let actions = [];
	let errors = [];

	let changed = !already;

	// Снимок состояния делаем до disable: по нему решаем, что именно
	// запускалось. podkop сам поднимает sing-box, поэтому отдельный sing-box
	// восстанавливаем только если podkop не использовался.
	let podkop_on = init_exists("podkop") && is_enabled("podkop");
	let singbox_on = init_exists("sing-box") && is_enabled("sing-box");
	let running = is_running();
	let tunnel = tunnel_up();
	let used_podkop = init_exists("podkop") && (tunnel || (running && podkop_on));
	let used_singbox = !used_podkop && init_exists("sing-box") && running;

	// Помним, что было включено/запущено, и снимаем автозапуск. Повторный
	// вызов тоже проверяет: если сервис подняли вручную, его надо погасить.
	if (podkop_on) {
		if (!in_list(init_list, "podkop")) {
			push(init_list, "podkop");
			changed = true;
		}
		quiet(PODKOP + " disable");
		push(actions, "podkop: автозапуск выключен");
	}
	if (singbox_on) {
		if (!in_list(init_list, "sing-box")) {
			push(init_list, "sing-box");
			changed = true;
		}
		quiet(SINGBOX + " disable");
		push(actions, "sing-box: автозапуск выключен");
	}
	if (used_podkop) {
		if (!in_list(run_list, "podkop")) {
			push(run_list, "podkop");
			changed = true;
		}
	}
	else if (used_singbox) {
		if (!in_list(run_list, "sing-box")) {
			push(run_list, "sing-box");
			changed = true;
		}
	}

	// Флаг паузы фиксируем до остановки: если процесс прервётся между stop
	// и commit, cron всё равно будет знать, что туннель надо вернуть.
	if (c != null && changed) {
		if (!already) {
			c.set(CONFIG, SECTION, "suspended", "1");
			c.set(CONFIG, SECTION, "suspended_at", "" + time());
		}
		if (length(init_list) > 0)
			c.set(CONFIG, SECTION, "suspended_init", init_list);
		else
			c.delete(CONFIG, SECTION, "suspended_init");
		if (length(run_list) > 0)
			c.set(CONFIG, SECTION, "suspended_running", run_list);
		else
			c.delete(CONFIG, SECTION, "suspended_running");
		c.commit(CONFIG);
	}

	// Сначала podkop: его stop сам останавливает sing-box и чистит nft
	if (used_podkop) {
		quiet(PODKOP + " stop");
		push(actions, "podkop: остановлен");
	}
	else if (used_singbox) {
		quiet(SINGBOX + " stop");
		push(actions, "sing-box: остановлен");
	}

	// Гашение идёт через procd и может быть не мгновенным — ждём до ~10 секунд,
	// иначе статус врал бы «sing-box всё ещё работает».
	if (used_podkop || used_singbox) {
		for (let i = 0; i < 10; i++) {
			if (!is_running())
				break;
			system("sleep 1");
		}
	}

	// Если sing-box всё ещё жив (например, запускался не через podkop) — добиваем
	if (init_exists("sing-box") && is_running()) {
		quiet(SINGBOX + " stop");
		push(actions, "sing-box: остановлен");
		system("sleep 1");
	}

	// Страховка: если sing-box уже нет, а nft-правила остались, трафик
	// уходил бы в мёртвый tproxy — сносим таблицу
	if (!is_running() && tunnel_up()) {
		quiet("nft delete table inet PodkopTable");
		push(actions, "nft: таблица PodkopTable удалена");
	}

	if (is_running())
		push(errors, "sing-box всё ещё работает после паузы");

	let info = suspended_info();
	return {
		suspended: true,
		changed: changed,
		actions: actions,
		errors: errors,
		at: info.at,
		init: init_list,
		running: run_list
	};
}

// Вернуть автозапуск и поднять то, что было остановлено.
function resume() {
	let c = load_settings();
	if (c == null || !is_suspended())
		return { resumed: false, suspended: false, actions: [], errors: [] };

	let init_list = as_list(c.get(CONFIG, SECTION, "suspended_init"));
	let run_list = as_list(c.get(CONFIG, SECTION, "suspended_running"));
	let actions = [];
	let errors = [];

	let want_podkop = in_list(init_list, "podkop") || in_list(run_list, "podkop");
	let want_singbox = in_list(init_list, "sing-box") || in_list(run_list, "sing-box");

	if (want_podkop && init_exists("podkop") && !is_enabled("podkop")) {
		quiet(PODKOP + " enable");
		push(actions, "podkop: автозапуск включён");
	}
	// Если поднимаем podkop, sing-box стартует внутри него; podkop при этом
	// сам снимает S99sing-box, поэтому отдельный автозапуск ему не нужен.
	if (!want_podkop && want_singbox && init_exists("sing-box") && !is_enabled("sing-box")) {
		quiet(SINGBOX + " enable");
		push(actions, "sing-box: автозапуск включён");
	}

	let started = [];
	if (want_podkop && init_exists("podkop")) {
		quiet(PODKOP + " start");
		push(actions, "podkop: запущен");
		push(started, "podkop");
	}
	else if (want_singbox && init_exists("sing-box")) {
		quiet(SINGBOX + " start");
		push(actions, "sing-box: запущен");
		push(started, "sing-box");
	}

	// podkop поднимает sing-box не мгновенно (скачивание списков, сборка
	// конфига), поэтому ждём до ~15 секунд: иначе статус врал бы «не
	// поднялись», хотя туннель появился чуть позже.
	if (length(started) > 0) {
		for (let i = 0; i < 15; i++) {
			system("sleep 1");
			if (is_running() || tunnel_up())
				break;
		}
		if (!is_running() && !tunnel_up())
			push(errors, "podkop/sing-box не поднялись после активации подписки");
	}

	if (length(errors) > 0) {
		// оставляем suspended=1: следующий cron попробует ещё раз
		return { resumed: false, suspended: true, actions: actions, errors: errors };
	}

	c.set(CONFIG, SECTION, "suspended", "0");
	c.set(CONFIG, SECTION, "suspended_at", "");
	c.delete(CONFIG, SECTION, "suspended_init");
	c.delete(CONFIG, SECTION, "suspended_running");
	c.commit(CONFIG);

	// podkop при старте сам снимает S99sing-box — это его штатное поведение.
	// resumed=false, если возвращать было нечего (пауза была пустой) — тогда
	// и хвастаться в интерфейсе нечем.
	return { resumed: (length(started) > 0 || length(actions) > 0),
		suspended: false, actions: actions, errors: errors };
}

// Текущее состояние сервисов для отчёта/LuCI
function service_state() {
	return {
		suspended: is_suspended(),
		podkop_installed: init_exists("podkop"),
		podkop_enabled: is_enabled("podkop"),
		singbox_installed: init_exists("sing-box"),
		singbox_enabled: is_enabled("sing-box"),
		singbox_running: is_running(),
		tunnel_up: tunnel_up()
	};
}

return {
	suspend: suspend,
	resume: resume,
	is_suspended: is_suspended,
	suspended_info: suspended_info,
	service_state: service_state
};
