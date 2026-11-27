// podkopctl.uc — единственное место, где shoulderkop трогает службу podkop.
//
// podkop 0.7.24 различает reload и restart: reload() — это stop_main + start_main,
// он поднимает nft и sing-box, но не зовёт start(), а значит не настраивает
// dnsmasq; stop() же гасит туннель через procd только если инстансом владеет
// procd (после reload его нет). Отсюда:
//   - restart_and_wait() перезапускает podkop и ждёт таблицу inet PodkopTable,
//     процесс sing-box и живой DNS на 127.0.0.42, повторяя попытку;
//   - cleanup() снимает остатки туннеля явно (sing-box, nft, ip rule и таблица
//     маршрутов podkop) и проверяет результат, чтобы LAN сразу получил интернет;
//   - lock_*() сериализуют «запись конфига podkop → restart → ожидание»: podkop
//     сам перезапускается на config.change, а LuCI может позвать apply вторым.
//
// Все внешние команды — через sh()/quiet() (временный файл, абсолютные пути).

'use strict';

let fs = require("fs");
let uci = require("uci");

const PODKOP_INIT = "/etc/init.d/podkop";
const PODKOP_BIN = "/usr/bin/podkop";
const SINGBOX_INIT = "/etc/init.d/sing-box";
const NFT_TABLE = "PodkopTable";
const RT_TABLE = "podkop";        // RT_TABLE_NAME в podkop
const DNS_ADDR = "127.0.0.42";    // SB_DNS_INBOUND_ADDRESS в podkop
const LOCK = "/tmp/shoulderkop.apply.lock";
const LOCK_STALE_FRESH = 15;      // столько секунд лок без pid считается живым
const RESTART_MARK = "/tmp/shoulderkop.restart";

// что podkop оставляет в @dnsmasq[0] на время работы (кроме server=127.0.0.42)
const PODKOP_DNS_BACKUPS = [ "podkop_noresolv", "podkop_cachesize", "podkop_server" ];

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
	let tmp = "/tmp/.shoulderkop.podkopctl." + own_pid() + "." + sh_seq;
	system(cmd + " > " + tmp + " 2>/dev/null");
	let out = fs.readfile(tmp);
	fs.unlink(tmp);
	return (out == null) ? "" : out;
}

function quiet(cmd) {
	system(cmd + " >/dev/null 2>&1");
}

function as_list(v) {
	if (type(v) == "array")
		return v;
	if (v == null || v == "")
		return [];
	return [ "" + v ];
}

function digits(s) {
	if (s == "")
		return false;
	for (let i = 0; i < length(s); i++) {
		let c = ord(substr(s, i, 1));
		if (c < 0x30 || c > 0x39)
			return false;
	}
	return true;
}

function installed() {
	return fs.stat(PODKOP_INIT) != null;
}

// rc.common enabled: ищем S-симлинк в /etc/rc.d (START у podkop = 99)
function service_enabled() {
	return trim(sh("ls /etc/rc.d/S*podkop 2>/dev/null")) != "";
}

// [s]ing-box — иначе pgrep находит сам себя в командной строке `sh -c`;
// pidof — запасной путь: на части сборок pgrep выключен в busybox.
function singbox_running() {
	if (trim(sh("pgrep -f '[s]ing-box[^ ]* run' 2>/dev/null")) != "")
		return true;
	return trim(sh("pidof sing-box 2>/dev/null")) != "" ||
		trim(sh("pidof sing-box-core 2>/dev/null")) != "";
}

// Таблица podkop в nft. Проверяем код возврата, а не текст: пустая таблица
// тоже существует, а «таблицы нет» — это успех, а не ошибка.
function tunnel_up() {
	return trim(sh("nft list table inet " + NFT_TABLE + " >/dev/null 2>&1 && echo yes")) == "yes";
}

let dig_checked = false;
let dig_ok = false;

function have_dig() {
	if (!dig_checked) {
		dig_ok = (trim(sh("command -v dig 2>/dev/null")) != "");
		dig_checked = true;
	}
	return dig_ok;
}

// Подсказка из конфига: dnsmasq получил 127.0.0.42. Это list-опция, поэтому
// сравниваем элементы, а не строку целиком (`uci get` вернёт «a 127.0.0.42»).
function dns_config_points_to_podkop() {
	let c = uci.cursor();
	if (!c.load("dhcp"))
		return false;
	let found = false;
	c.foreach("dhcp", "dnsmasq", function (s) {
		for (let v in as_list(s.server))
			if (trim("" + v) == DNS_ADDR)
				found = true;
	});
	return found;
}

// Живой резолв через dnsmasq на 127.0.0.1 (dig, если он есть, иначе nslookup).
function dns_resolves() {
	if (have_dig())
		return trim(sh("dig @127.0.0.1 www.gstatic.com +timeout=3 +tries=1 +short 2>/dev/null")) != "";
	let out = sh("nslookup www.gstatic.com 127.0.0.1 2>/dev/null");
	return index(out, "Name:") >= 0 && index(out, "can't find") < 0;
}

// Резолв через dnsmasq на 127.0.0.1. Подсказки из конфига мало (клиенты могут
// остаться на DNS провайдера), одного резолва тоже мало (до настройки dnsmasq
// отвечает и без podkop) — поэтому нужны оба признака.
function dns_points_to_podkop() {
	if (!dns_config_points_to_podkop())
		return false;
	return dns_resolves();
}

// Живой DNS без требования 127.0.0.42: после паузы dnsmasq должен отвечать
// через провайдера, и это единственный признак, который видит клиент LAN.
function dns_ok() {
	return dns_resolves();
}

// Слепок @dnsmasq[0]: server со 127.0.0.42, резервные копии podkop_* и
// noresolv. Нужен и до, и после dnsmasq_restore: по резервной копии видно,
// был ли noresolv=1 настройкой пользователя (тогда его и надо вернуть).
function dns_state() {
	let st = { server: false, backups: false, noresolv: "", backup_noresolv: "" };
	let c = uci.cursor();
	if (!c.load("dhcp"))
		return st;
	c.foreach("dhcp", "dnsmasq", function (s) {
		for (let v in as_list(s.server))
			if (trim("" + v) == DNS_ADDR)
				st.server = true;
		for (let opt in PODKOP_DNS_BACKUPS)
			if (s[opt] != null && trim("" + s[opt]) != "")
				st.backups = true;
		st.noresolv = trim("" + (s.noresolv || ""));
		st.backup_noresolv = trim("" + (s.podkop_noresolv || ""));
	});
	return st;
}

// Осталось ли что-то от podkop: server 127.0.0.42, резервные копии или
// noresolv=1, которого не было у пользователя до podkop.
function dns_dirty(before, now) {
	if (now.server || now.backups)
		return true;
	if (now.noresolv == "1" && before.backup_noresolv != "1")
		return true;
	return false;
}

// Вернуть dnsmasq провайдеру: `/usr/bin/podkop stop` вызывает dnsmasq_restore —
// убирает server со 127.0.0.42, возвращает noresolv/cachesize и перезапускает
// dnsmasq. Потом проверяем, что следов podkop не осталось и резолв живой.
function restore_dns() {
	let actions = [];
	let errors = [];

	let before = dns_state();
	// трогаем dnsmasq, только если в нём действительно есть podkop
	let touched = (before.server || before.backups);
	let after = before;

	if (touched) {
		if (fs.stat(PODKOP_BIN) != null) {
			quiet(PODKOP_BIN + " stop");
			after = dns_state();
			if (!dns_dirty(before, after))
				push(actions, "dnsmasq: возвращён провайдеру");
		}
		else {
			push(errors, "/usr/bin/podkop не найден: dnsmasq не вернуть провайдеру");
		}
	}

	let ok = !touched || !dns_dirty(before, after);
	if (!ok)
		push(errors, "dnsmasq всё ещё указывает на podkop (127.0.0.42, podkop_* или noresolv=1)");

	let resolved = dns_resolves();
	if (!resolved)
		push(errors, "dnsmasq на 127.0.0.1 не резолвит имена");

	return { ok: ok, dns_ok: resolved, actions: actions, errors: errors };
}

function state() {
	let inst = installed();
	return {
		installed: inst,
		enabled: inst && service_enabled(),
		running: singbox_running(),
		tunnel_up: tunnel_up(),
		dns_ok: dns_points_to_podkop()
	};
}

// --- файловый лок ----------------------------------------------------------
//
// flock в busybox есть не во всех сборках, поэтому лок — атомарный mkdir:
// каталог создаёт ровно один процесс, внутри лежит pid владельца. Умерший
// владелец (kill -0) делает лок устаревшим, чтобы падение не блокировало
// обновления навсегда.

function lock_state() {
	let st = fs.stat(LOCK);
	if (st == null)
		return "free";

	let raw = fs.readfile(LOCK + "/pid");
	let pid = (raw == null) ? "" : trim(raw);
	if (digits(pid)) {
		if (trim(sh("kill -0 " + pid + " 2>/dev/null && echo ok")) == "ok")
			return "held";
		return "stale";
	}
	if (time() - int("" + (st.mtime || 0)) > LOCK_STALE_FRESH)
		return "stale";
	return "held";
}

function locked() {
	return lock_state() == "held";
}

function lock_acquire() {
	for (let i = 0; i < 3; i++) {
		let now_state = lock_state();
		if (now_state == "held")
			return false;
		if (now_state == "stale")
			quiet("rm -rf " + LOCK);

		// mkdir — единственная атомарная проверка «свободно/занято»
		if (trim(sh("mkdir " + LOCK + " 2>/dev/null && echo ok")) != "ok")
			continue;

		fs.writefile(LOCK + "/pid", own_pid());
		return true;
	}
	return false;
}

function lock_release() {
	let raw = fs.readfile(LOCK + "/pid");
	if (raw != null && trim(raw) == own_pid())
		quiet("rm -rf " + LOCK);
}

// Метка перезапуска: diag не чинит и не уводит в direct, пока туннель поднимается.
function mark_restart() {
	fs.writefile(RESTART_MARK, "" + time());
}

function restart_mark() {
	let raw = fs.readfile(RESTART_MARK);
	return (raw == null) ? 0 : int(trim(raw));
}

// --- перезапуск ------------------------------------------------------------

function up_now() {
	return tunnel_up() && singbox_running();
}

// restart + ожидание готовности. opts: { wait_ms = 25000, step_ms = 1000, attempts = 2 }
function restart_and_wait(opts) {
	opts = opts || {};
	let wait_ms = int("" + (opts.wait_ms == null ? 25000 : opts.wait_ms));
	let step_ms = int("" + (opts.step_ms == null ? 1000 : opts.step_ms));
	let attempts = int("" + (opts.attempts == null ? 2 : opts.attempts));
	if (wait_ms < step_ms)
		wait_ms = step_ms;
	if (attempts < 1)
		attempts = 1;

	let result = {
		ok: false,
		attempts: 0,
		waited: 0,
		tunnel_up: false,
		singbox_running: false,
		dns_ok: false,
		actions: [],
		errors: []
	};

	if (!installed()) {
		push(result.errors, "podkop не установлен: перезапускать нечего");
		return result;
	}

	for (let i = 0; i < attempts; i++) {
		result.attempts = i + 1;
		push(result.actions, "podkop: restart (попытка " + result.attempts + ")");
		quiet(PODKOP_INIT + " restart");
		mark_restart();

		// ждём таблицу и процесс; шаг округляем до секунд, потому что
		// busybox sleep не обязан понимать доли секунды
		let step_s = (step_ms >= 1000) ? int(step_ms / 1000) : 1;
		let waited = 0;
		while (waited < wait_ms) {
			if (up_now())
				break;
			system("sleep " + step_s);
			waited += step_s * 1000;
		}

		// подъём podkop не мгновенный: два замера подряд с паузой ≥3 с, иначе
		// ловим «только что появилось» и рапортуем готовность раньше времени
		if (up_now()) {
			system("sleep 3");
			waited += 3000;
		}

		result.waited = waited;
		result.tunnel_up = tunnel_up();
		result.singbox_running = singbox_running();
		result.dns_ok = dns_points_to_podkop();

		if (result.tunnel_up && result.singbox_running && result.dns_ok) {
			result.ok = true;
			break;
		}
	}

	if (!result.ok) {
		if (!result.tunnel_up)
			push(result.errors, "podkop не создал таблицу inet " + NFT_TABLE);
		if (!result.singbox_running)
			push(result.errors, "sing-box не запущен после restart");
		if (!result.dns_ok)
			push(result.errors, "dnsmasq не отвечает через podkop: нет 127.0.0.42 или резолв не работает");
	}

	return result;
}

// --- чистка ----------------------------------------------------------------

// Правила podkop в ip rule: podkop ставит fwmark-правило на таблицу `podkop`
// с priority 105. Читаем вывод, чтобы снять их, даже если приоритет не 105.
function podkop_rules() {
	let out = [];
	for (let line in split(sh("ip rule show 2>/dev/null"), "\n")) {
		line = trim(line);
		if (line == "" || index(lc(line), RT_TABLE) < 0)
			continue;
		let colon = index(line, ":");
		let prio = (colon > 0) ? trim(substr(line, 0, colon)) : "";
		let spec = (colon > 0) ? trim(substr(line, colon + 1)) : line;
		push(out, { prio: prio, spec: spec });
	}
	return out;
}

function del_podkop_rules(actions) {
	for (let round = 0; round < 5; round++) {
		let list = podkop_rules();
		if (length(list) == 0)
			return;
		let before = length(list);
		let r = list[0];
		quiet("ip rule del " + r.spec);
		if (length(podkop_rules()) >= before && r.prio != "") {
			// запасные формы: у busybox ip и iproute2 разный набор ключей
			quiet("ip rule del priority " + r.prio);
			if (length(podkop_rules()) >= before)
				quiet("ip rule del prio " + r.prio);
		}
		if (length(podkop_rules()) < before)
			push(actions, "ip rule: снято правило podkop (priority " + r.prio + ")");
	}
}

function route_table_has_entries() {
	return trim(sh("ip route list table " + RT_TABLE + " 2>/dev/null")) != "";
}

// Гасим sing-box только если он наш: записан в снимке паузы или таблица podkop
// существовала на входе. Чужой sing-box (не из podkop) не трогаем. «podkop» в
// снимке тоже означает «наш»: podkop поднимает sing-box сам, отдельного
// процесса у него нет.
function singbox_is_ours(table_existed) {
	if (table_existed)
		return true;
	let c = uci.cursor();
	if (!c.load("shoulderkop"))
		return false;
	for (let opt in [ "suspended_init", "suspended_running" ]) {
		for (let v in as_list(c.get("shoulderkop", "settings", opt))) {
			let name = trim("" + v);
			if (name == "sing-box" || name == "podkop")
				return true;
		}
	}
	return false;
}

function wait_singbox_gone(sec) {
	for (let i = 0; i < sec; i++) {
		if (!singbox_running())
			return true;
		system("sleep 1");
	}
	return !singbox_running();
}

// cleanup: снять остатки туннеля. opts: { force = true } — проверять и чистить
// даже если podkop уже «остановлен».
function cleanup(opts) {
	opts = opts || {};
	let force = (opts.force == true);

	let actions = [];
	let errors = [];

	let table_existed = tunnel_up();
	let box_was_running = singbox_running();
	let had_rules = length(podkop_rules()) > 0;
	let had_routes = route_table_has_entries();

	if (!force && !table_existed && !box_was_running && !had_rules && !had_routes)
		return { ok: true, actions: actions, errors: errors };

	// 1. sing-box: только штатный stop и только если процесс наш, иначе
	//    на паузе можно погасить чужой sing-box
	if (box_was_running && singbox_is_ours(table_existed)) {
		if (fs.stat(SINGBOX_INIT) != null)
			quiet(SINGBOX_INIT + " stop");
		wait_singbox_gone(10);
		if (singbox_running())
			push(errors, "sing-box продолжает работать после паузы");
		else
			push(actions, "sing-box: остановлен");
	}

	// 2. nft-таблица podkop: удаляем, только если она есть; её отсутствие — успех
	if (table_existed) {
		quiet("nft delete table inet " + NFT_TABLE);
		if (tunnel_up())
			push(errors, "таблица inet " + NFT_TABLE + " не удалена");
		else
			push(actions, "nft: таблица inet " + NFT_TABLE + " удалена");
	}

	// 3. ip rule podkop
	if (length(podkop_rules()) > 0) {
		del_podkop_rules(actions);
		if (length(podkop_rules()) > 0)
			push(errors, "ip rule podkop не сняты");
	}

	// 4. таблица маршрутов podkop
	if (route_table_has_entries()) {
		quiet("ip route flush table " + RT_TABLE);
		if (route_table_has_entries())
			push(errors, "таблица маршрутов " + RT_TABLE + " не очищена");
		else
			push(actions, "ip route: таблица " + RT_TABLE + " очищена");
	}

	return { ok: length(errors) == 0, actions: actions, errors: errors };
}

return {
	installed: installed,
	tunnel_up: tunnel_up,
	singbox_running: singbox_running,
	dns_points_to_podkop: dns_points_to_podkop,
	dns_ok: dns_ok,
	restore_dns: restore_dns,
	state: state,
	restart_and_wait: restart_and_wait,
	cleanup: cleanup,
	locked: locked,
	lock_acquire: lock_acquire,
	lock_release: lock_release,
	restart_mark: restart_mark
};
