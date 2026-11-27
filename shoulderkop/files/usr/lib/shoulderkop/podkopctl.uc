// podkopctl.uc — единственное место, где shoulderkop трогает службу podkop.
//
// podkop 0.7.24 различает reload и restart: reload() — это stop_main + start_main,
// он поднимает nft и sing-box, но не зовёт start(), а значит не настраивает
// dnsmasq; stop() же гасит туннель через procd только если инстансом владеет
// procd (после reload его нет). Отсюда:
//   - restart_and_wait() перезапускает podkop и ждёт таблицу inet PodkopTable,
//     процесс sing-box и живой резолв через dnsmasq на 127.0.0.1, повторяя
//     попытку в пределах общего бюджета ожидания (50 с);
//   - cleanup() снимает остатки туннеля явно (sing-box, nft, ip rule и таблица
//     маршрутов podkop) и проверяет результат, чтобы LAN сразу получил интернет;
//   - lock_*() сериализуют «запись конфига podkop → restart → ожидание»: podkop
//     сам перезапускается на config.change, а LuCI может позвать apply вторым.
//     Тот же лок берут restart_and_wait(), cleanup() и restore_dns(), поэтому
//     cron-диагностика не перезапустит и не погасит podkop посреди чужой
//     раскладки.
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

// Резолв через dnsmasq на 127.0.0.1 — единственный критерий «DNS смотрит в
// туннель» (решение 10): dnsmasq держит состояние и в /tmp, поэтому по
// /etc/config/dhcp судить нельзя. Наличие 127.0.0.42 в dhcp — подсказка для
// текста отчёта (dns_config_points_to_podkop), на равенство не сравниваем.
function dns_points_to_podkop() {
	return dns_resolves();
}

// Живой DNS без требования 127.0.0.42: после паузы dnsmasq должен отвечать
// через провайдера, и это единственный признак, который видит клиент LAN.
// Критерий тот же, что у туннеля, — резолв имени через 127.0.0.1.
function dns_ok() {
	return dns_points_to_podkop();
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
// `/usr/bin/podkop stop` — действие над podkop, поэтому идёт под общим локом.
function restore_dns() {
	let actions = [];
	let errors = [];

	if (!lock_acquire())
		return { ok: false, busy: true, dns_ok: false, actions: actions,
			errors: [ "другой запуск shoulderkop применяет настройки: dnsmasq не трогаю" ] };

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

	lock_release();
	return { ok: ok, busy: false, dns_ok: resolved, actions: actions, errors: errors };
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

// Сколько раз этот процесс взял лок: update/apply держат его на весь путь и
// зовут restart_and_wait()/cleanup()/restore_dns() изнутри, а повторный mkdir
// провалился бы на собственном локе.
let lock_depth = 0;

function lock_acquire() {
	if (lock_depth > 0) {
		lock_depth++;
		return true;
	}

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
		lock_depth = 1;
		return true;
	}
	return false;
}

function lock_release() {
	if (lock_depth > 1) {
		lock_depth--;
		return;
	}
	lock_depth = 0;

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

// --- ожидание готовности ----------------------------------------------------

const READY_WAIT_MS = 25000;    // ожидание подъёма в одной попытке restart
const READY_STEP_MS = 1000;     // шаг опроса
const READY_STABLE_MS = 3000;   // столько готовность держится, чтобы ей поверить
const READY_BUDGET_MS = 50000;  // общий бюджет ожидания: решение «не больше 50 с»
const READY_ATTEMPTS = 2;       // больше двух перезапусков подряд — уже шторм

function up_now() {
	return tunnel_up() && singbox_running();
}

// Ожидание готовности: два стабильных замера подряд (таблица + процесс) с
// паузой ≥3 с — одиночный замер ловит «только что появилось». Резолв через
// dnsmasq проверяем в том же бюджете: он включается позже таблицы, но бюджет
// ожидания не растягивает.
// По умолчанию ждёт весь бюджет restart_and_wait() — этим же ожиданием
// lifecycle.resume() поднимает туннель после продления подписки, и ждать
// меньше, чем занимает перезапуск, нельзя.
// opts: { wait_ms = READY_BUDGET_MS, step_ms = READY_STEP_MS }
function wait_ready(opts) {
	opts = opts || {};
	let wait_ms = int("" + (opts.wait_ms == null ? READY_BUDGET_MS : opts.wait_ms));
	let step_ms = int("" + (opts.step_ms == null ? READY_STEP_MS : opts.step_ms));
	// busybox sleep не обязан понимать доли секунды
	if (step_ms < 1000)
		step_ms = 1000;
	let step_s = int(step_ms / 1000);
	if (wait_ms < step_ms)
		wait_ms = step_ms;

	let wait_s = int(wait_ms / 1000);
	if (wait_s < 1)
		wait_s = 1;

	let t0 = int("" + time());
	let deadline = t0 + wait_s;
	// Сколько максимум занимает проверка резолва: dig ограничен +timeout=3, а
	// nslookup — две попытки по 5 с. Начинать её, не оставив этого запаса,
	// значит вылезти за бюджет ожидания.
	let probe_s = have_dig() ? 3 : 10;
	let ready_at = -1;
	let dns = false;

	while (int("" + time()) < deadline) {
		if (up_now()) {
			// запоминаем, когда туннель впервые увидели; пропал — начинаем заново
			if (ready_at < 0)
				ready_at = int("" + time());
			else if (int("" + time()) - ready_at >= int(READY_STABLE_MS / 1000)) {
				// резолв проверяем, только если на него хватает остатка бюджета
				if (deadline - int("" + time()) < probe_s)
					break;
				dns = dns_points_to_podkop();
				if (dns)
					break;
			}
		}
		else {
			ready_at = -1;
		}

		// и спим не дольше остатка: иначе последний шаг вылезет за дедлайн
		let left_s = deadline - int("" + time());
		if (left_s <= 0)
			break;
		system("sleep " + ((step_s < left_s) ? step_s : left_s));
	}

	return {
		ok: (ready_at >= 0 && dns),
		waited: (int("" + time()) - t0) * 1000,
		tunnel_up: tunnel_up(),
		singbox_running: singbox_running(),
		dns_ok: dns
	};
}

// restart + ожидание готовности. opts: { wait_ms = 25000, step_ms = 1000,
// attempts = 2, budget_ms = 50000 }. Общий бюджет ожидания (по умолчанию 50 с)
// общий на все попытки: две попытки по 25 с — это уже предел, а не 56–62 с.
// Лок берётся здесь же: пока update/apply пишет конфиг и перезапускает podkop,
// диагностика не имеет права перезапустить его второй раз.
function restart_and_wait(opts) {
	opts = opts || {};
	let wait_ms = int("" + (opts.wait_ms == null ? READY_WAIT_MS : opts.wait_ms));
	let step_ms = int("" + (opts.step_ms == null ? READY_STEP_MS : opts.step_ms));
	let attempts = int("" + (opts.attempts == null ? READY_ATTEMPTS : opts.attempts));
	let budget_ms = int("" + (opts.budget_ms == null ? READY_BUDGET_MS : opts.budget_ms));
	if (attempts < 1)
		attempts = 1;
	if (budget_ms < 1000)
		budget_ms = 1000;

	let result = {
		ok: false,
		busy: false,
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

	// лок занят — не делаем ничего: ни restart, ни nft, ни sing-box
	if (!lock_acquire()) {
		result.busy = true;
		push(result.errors, "другой запуск shoulderkop применяет настройки: podkop не перезапускаю");
		return result;
	}

	let t0 = int("" + time());
	for (let i = 0; i < attempts; i++) {
		if (budget_ms - (int("" + time()) - t0) * 1000 < 1000)
			break;

		result.attempts = i + 1;
		push(result.actions, "podkop: restart (попытка " + result.attempts + ")");
		quiet(PODKOP_INIT + " restart");
		mark_restart();

		// остаток бюджета считаем после restart: сам restart тоже занимает время
		let left_ms = budget_ms - (int("" + time()) - t0) * 1000;
		if (left_ms < 1000)
			left_ms = 1000;

		let w = wait_ready({
			wait_ms: (wait_ms < left_ms) ? wait_ms : left_ms,
			step_ms: step_ms
		});

		result.tunnel_up = w.tunnel_up;
		result.singbox_running = w.singbox_running;
		result.dns_ok = w.dns_ok;
		if (w.ok && w.tunnel_up && w.singbox_running) {
			result.ok = true;
			break;
		}
	}
	result.waited = (int("" + time()) - t0) * 1000;

	if (!result.ok) {
		if (!result.tunnel_up)
			push(result.errors, "podkop не создал таблицу inet " + NFT_TABLE);
		if (!result.singbox_running)
			push(result.errors, "sing-box не запущен после restart");
		if (!result.dns_ok)
			push(result.errors, "dnsmasq на 127.0.0.1 не резолвит имена" +
				(dns_config_points_to_podkop()
					? " (127.0.0.42 в dhcp прописан, ответа нет)"
					: " (127.0.0.42 в dhcp не прописан)"));
	}

	lock_release();
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
// даже если podkop уже «остановлен». Лок тот же, что у update/apply: иначе
// cron-диагностика погасит sing-box и снесёт таблицу посреди чужой раскладки.
// Возвращает проверенное состояние после чистки (tunnel_up, singbox_running).
function cleanup(opts) {
	opts = opts || {};
	let force = (opts.force == true);

	let actions = [];
	let errors = [];

	// лок занят — не трогаем ни podkop, ни nft, ни sing-box
	if (!lock_acquire())
		return { ok: false, busy: true, actions: actions,
			errors: [ "другой запуск shoulderkop применяет настройки: остатки туннеля не трогаю" ],
			tunnel_up: null, singbox_running: null };

	let table_existed = tunnel_up();
	let box_was_running = singbox_running();
	let had_rules = length(podkop_rules()) > 0;
	let had_routes = route_table_has_entries();

	if (!force && !table_existed && !box_was_running && !had_rules && !had_routes) {
		lock_release();
		return { ok: true, busy: false, actions: actions, errors: errors,
			tunnel_up: table_existed, singbox_running: box_was_running };
	}

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

	// 5. что осталось на самом деле — это и есть paused_clean в отчёте
	let after_table = tunnel_up();
	let after_box = singbox_running();

	lock_release();
	return { ok: length(errors) == 0, busy: false, actions: actions, errors: errors,
		tunnel_up: after_table, singbox_running: after_box };
}

return {
	installed: installed,
	tunnel_up: tunnel_up,
	singbox_running: singbox_running,
	dns_points_to_podkop: dns_points_to_podkop,
	dns_ok: dns_ok,
	restore_dns: restore_dns,
	state: state,
	wait_ready: wait_ready,
	restart_and_wait: restart_and_wait,
	cleanup: cleanup,
	locked: locked,
	lock_acquire: lock_acquire,
	lock_release: lock_release,
	restart_mark: restart_mark
};
