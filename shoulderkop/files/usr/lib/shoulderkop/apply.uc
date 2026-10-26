// apply.uc — раскладка узлов подписки по секциям podkop по выбранному режиму.
//
// Режимы:
//   lte  → skop_lte (proxy, все LTE-узлы группой, fully_routed_ips = LAN + 127.0.0.1)
//          skop_lte_direct (exclusion, rkn-списки .srs → direct)
//   wifi → skop_yt (urltest, community_lists из wifi_yt_lists; по умолчанию youtube)
//          skop_eu (urltest, community_lists из wifi_eu_lists; по умолчанию
//                   russia_inside,telegram,meta,cloudflare,hodca,roblox)
//          Обе секции — urltest_proxy_links со vless-ссылками, никаких
//          outbound-секций и балансировщиков. xhttp-узлы отсеиваются: без
//          `tools decode-link` podkop такие ссылки не разбирает.
//          Списки сообщества редактируются в LuCI; пока опций в конфиге нет,
//          действуют захардкоженные значения по умолчанию.
//
// Сервера в секции:
//   - 1 узел       → одиночный outbound_json (кроме WiFi: там всегда urltest);
//   - ссылки podkop умеет декодировать сама (vless tcp/ws/grpc, либо любой
//     транспорт при наличии tools decode-link)
//                  → proxy_config_type=urltest + urltest_proxy_links;
//   - иначе        → «синтетическая группа»: дочерние секции skop_<режим>_NN
//                    (outbound) + urltest-JSON на их теги <child>-out.
//     Оба варианта — urltest, никаких балансировщиков.
//
// Всё, что начинается с `skop_`, считаем своим и удаляем, если оно больше не нужно.
// Секцию без подходящих серверов НЕ создаём: пустой proxy-секции podkop не переварит
// («Outbound section not found») и упадёт целиком.

'use strict';

let fs = require("fs");
let uci = require("uci");

const GEOSITE = "https://github.com/BranchSeeker/rkn-whitelist-srs/releases/latest/download/geosite.srs";
const GEOIP = "https://github.com/BranchSeeker/rkn-whitelist-srs/releases/latest/download/geoip.srs";
const PREFIX = "skop_";

// Списки сообщества podkop для WiFi-секций. Пока в конфиге нет своих значений,
// используются эти: поведение по умолчанию остаётся прежним (YouTube отдельно,
// остальные сервисы через russia_inside).
const WIFI_YT_LISTS_DEFAULT = [ "youtube" ];
const WIFI_EU_LISTS_DEFAULT = [
	"russia_inside", "telegram", "meta", "cloudflare", "hodca", "roblox"
];

// podkop падает целиком на неизвестном community list («Invalid service ... Aborted»),
// поэтому чужие/опечатанные значения отбрасываем. Набор — как COMMUNITY_SERVICES
// в podkop; russia_inside уже включает youtube, geoblock, block и т.д.
const COMMUNITY_LISTS = [
	"russia_inside", "russia_outside", "ukraine_inside", "geoblock", "block",
	"porn", "news", "anime", "youtube", "hdrezka", "tiktok", "google_ai",
	"google_play", "hodca", "discord", "meta", "twitter", "cloudflare",
	"cloudfront", "digitalocean", "hetzner", "ovh", "telegram", "roblox"
];

// --- утилиты ---------------------------------------------------------------

// Свой pid (в ucode нет getpid()) — чтобы параллельные запуски не затирали вывод.
function own_pid() {
	let s = fs.readfile("/proc/self/stat");
	if (s == null || s == "")
		return "" + time();
	let sp = index(s, " ");
	return (sp > 0) ? substr(s, 0, sp) : "" + time();
}

// fs.popen().read() в этой сборке ucode не отдаёт вывод → через временный файл
let sh_seq = 0;

function sh(cmd) {
	sh_seq++;
	let tmp = "/tmp/.shoulderkop.apply." + own_pid() + "." + sh_seq;
	system(cmd + " > " + tmp + " 2>/dev/null");
	let out = fs.readfile(tmp);
	fs.unlink(tmp);
	return (out == null) ? "" : out;
}

function uci_get(cfg, sec, opt) {
	return trim(sh("uci -q get " + cfg + "." + sec + "." + opt));
}

// интервал проверки серверов в группе — «Интервал выбора лучшего сервера»
const URLTEST_DEFAULT = "30s";
const URLTEST_ALLOWED = [ "30s", "1m", "2m", "3m", "5m", "10m" ];

function urltest_interval() {
	let v = uci_get("shoulderkop", "settings", "urltest_interval");
	for (let a in URLTEST_ALLOWED)
		if (a == v)
			return v;
	return URLTEST_DEFAULT;
}

// UCI-список (option ... / list ...) → массив значений
function uci_list_get(cfg, sec, opt) {
	let out = [];
	for (let v in split(uci_get(cfg, sec, opt), "\n")) {
		v = trim(v);
		if (v != "")
			push(out, v);
	}
	return out;
}

// community_lists для секции: значения из конфига, иначе — захардкоженный
// набор по умолчанию. Неизвестные podkop имена отбрасываем (он на них падает).
function community_lists(opt, defaults) {
	let allowed = {};
	for (let v in COMMUNITY_LISTS)
		allowed[v] = true;

	let out = [];
	let seen = {};
	for (let v in uci_list_get("shoulderkop", "settings", opt)) {
		if (allowed[v] && !seen[v]) {
			seen[v] = true;
			push(out, v);
		}
	}

	return (length(out) > 0) ? out : defaults;
}

function wifi_lists() {
	return {
		yt: community_lists("wifi_yt_lists", WIFI_YT_LISTS_DEFAULT),
		eu: community_lists("wifi_eu_lists", WIFI_EU_LISTS_DEFAULT)
	};
}

function has(hay, needle) {
	return index(lc("" + hay), lc("" + needle)) >= 0;
}

function has_any(hay, needles) {
	for (let nd in needles)
		if (has(hay, nd))
			return true;
	return false;
}

function pad2(n) {
	return (n < 10) ? "0" + n : "" + n;
}

function as_list(v) {
	if (type(v) == "array")
		return v;
	if (v == null || v == "")
		return [];
	return [ "" + v ];
}

function same_list(a, b) {
	a = as_list(a);
	b = as_list(b);
	if (length(a) != length(b))
		return false;
	for (let i = 0; i < length(a); i++)
		if ("" + a[i] != "" + b[i])
			return false;
	return true;
}

function node_server(n) {
	return (n.outbound == null) ? "" : ("" + (n.outbound.server || ""));
}

function transport_of(n) {
	if (n.outbound == null)
		return "tcp";
	let tr = n.outbound.transport;
	return (type(tr) == "object") ? ("" + (tr.type || "tcp")) : "tcp";
}

// xhttp podkop без `tools decode-link` не разбирает. В WiFi-секциях такие узлы
// отбрасываем жёстко: иначе urltest_proxy_links не собрать и секция уедет в
// синтетическую группу из outbound-секций. LTE этим не трогаем.
function is_xhttp_node(n) {
	let t = lc(transport_of(n));
	return t == "xhttp" || t == "splithttp";
}

// podkop сам декодирует vless-ссылки (tcp/ws/grpc) без tools.decode-link.
// xhttp, http/h2 и httpupgrade он так не умеет — для них нужен decode-link
// или синтетическая группа из outbound_json.
const LINK_TRANSPORTS = { tcp: true, ws: true, grpc: true };

function native_links_ok(nodes, decode_ok) {
	if (decode_ok)
		return true;

	for (let n in nodes) {
		if (n.link == null || n.link == "")
			return false;
		if (!LINK_TRANSPORTS[transport_of(n)])
			return false;
	}
	return true;
}

// --- LAN-подсеть -----------------------------------------------------------

const MASKBITS = { "255": 8, "254": 7, "252": 6, "248": 5, "240": 4, "224": 3,
	"192": 2, "128": 1, "0": 0 };

function netmask_bits(nm) {
	let parts = split("" + nm, ".");
	if (length(parts) != 4)
		return 0;
	let bits = 0;
	for (let p in parts) {
		let v = MASKBITS[trim(p)];
		if (v == null)
			return 0;
		bits += v;
	}
	return bits;
}

// 192.168.1.1 + 24 → 192.168.1.0/24 (адрес сети, а не хоста)
function cidr_of(addr, bits) {
	let parts = split("" + addr, ".");
	if (length(parts) != 4)
		return null;
	bits = int("" + bits);
	if (bits < 1 || bits > 32)
		return null;

	let v = (int(parts[0]) << 24) | (int(parts[1]) << 16) | (int(parts[2]) << 8) | int(parts[3]);
	let m = (bits >= 32) ? 0xffffffff : ((0xffffffff << (32 - bits)) & 0xffffffff);
	v = v & m;

	return sprintf("%d.%d.%d.%d/%d",
		(v >> 24) & 255, (v >> 16) & 255, (v >> 8) & 255, v & 255, bits);
}

// Интерфейсы из podkop.source_network_interfaces, иначе network.interface.lan
function lan_cidr() {
	let devs = [];
	let sp = trim(sh("uci -q get podkop.settings.source_network_interfaces 2>/dev/null"));
	for (let d in split(sp, "\n")) {
		d = trim(d);
		if (d != "")
			push(devs, d);
	}

	let names = split(trim(sh("ubus list network.interface.* 2>/dev/null")), "\n");
	let first = null;

	for (let full in names) {
		full = trim(full);
		if (full == "")
			continue;
		let raw = trim(sh("ubus call " + full + " status 2>/dev/null"));
		if (raw == "")
			continue;
		let st = null;
		try { st = json(raw); } catch (e) { st = null; }
		if (st == null)
			continue;

		let list = st["ipv4-address"];
		if (type(list) != "array" || length(list) == 0 || type(list[0]) != "object")
			continue;
		let c = cidr_of("" + (list[0].address || ""), list[0].mask);
		if (c == null)
			continue;

		let dev = "" + (st.device || st["l3_device"] || "");
		for (let want_dev in devs)
			if (dev != "" && want_dev == dev)
				return c;

		if (full == "network.interface.lan")
			return c;
		if (first == null)
			first = c;
	}

	if (first != null)
		return first;

	let ip = trim(uci_get("network", "lan", "ipaddr"));
	let nm = trim(uci_get("network", "lan", "netmask"));
	if (ip != "" && nm != "") {
		let bits = netmask_bits(nm);
		if (bits > 0)
			return cidr_of(ip, bits);
	}
	return null;
}

// --- возможности движка ----------------------------------------------------

// podkop умеет xhttp в urltest только если sing-box отдаёт tools.decode-link
function engine_decode_link() {
	let v = sh("sing-box version 2>&1");
	for (let line in split(v, "\n"))
		if (index(line, "tools.decode-link") >= 0)
			return true;
	let t = sh("sing-box tools 2>&1");
	return index(t, "decode-link") >= 0;
}

// --- секции podkop ---------------------------------------------------------

function snapshot(p) {
	let snap = {};
	p.foreach("podkop", "section", function (s) {
		let o = {};
		for (let k in s) {
			if (substr(k, 0, 1) == ".")
				continue;
			o[k] = s[k];
		}
		snap[s[".name"]] = o;
	});
	return snap;
}

function ensure_section(p, cur, name) {
	if (cur[name] != null)
		return name;
	let created = p.add("podkop", "section");
	if (created == null)
		return null;
	if (created != name && p.rename("podkop", created, name) == false)
		return null;
	cur[name] = {};
	return name;
}

// записать опцию только если она отличается; вернуть 1, если было изменение
function want(p, cur, sec, opt, value) {
	let have = (cur[sec] == null) ? null : cur[sec][opt];

	if (type(value) == "array") {
		if (same_list(have, value))
			return 0;
		if (length(value) > 0)
			p.set("podkop", sec, opt, value);
		else
			p.delete("podkop", sec, opt);
		return 1;
	}

	if (value == null || value == "") {
		if (have == null || have == "")
			return 0;
		p.delete("podkop", sec, opt);
		return 1;
	}

	if (have != null && "" + have == "" + value)
		return 0;
	p.set("podkop", sec, opt, "" + value);
	return 1;
}

// свои дочерние секции группы: <name>_NN
function own_children(cur, name) {
	let out = [];
	let pre = name + "_";
	for (let n in cur) {
		if (substr(n, 0, length(pre)) != pre)
			continue;
		let tail = substr(n, length(pre));
		if (tail == "")
			continue;
		let digits = true;
		for (let i = 0; i < length(tail); i++) {
			let code = ord(substr(tail, i, 1));
			if (code < 0x30 || code > 0x39) {
				digits = false;
				break;
			}
		}
		if (digits)
			push(out, n);
	}
	return out;
}

// --- режимы ----------------------------------------------------------------

// Подписка Remnawave отдаёт по одному клиентскому конфигу на «хост», и именно
// remarks этого конфига содержит метку («🇪🇺📱LTE ❯ Обход Белых списков»,
// «🇷🇺 WiFi ❯ Россия (YouTube)»). У самих узлов в name — только их tag, поэтому
// режимы отбирают серверы по группе, а name/адрес оставляем как запасной путь.
function group_of(n) {
	return "" + (n.group || "");
}

function is_lte(n) {
	return has(group_of(n), "lte") || has(n.name, "lte") || has(node_server(n), "lte");
}

function is_wifi(n) {
	// link-list subscription: no group labels at all, nodes are still wifi-family
	if (group_of(n) == "")
		return true;
	return has(group_of(n), "wifi") || has(n.name, "wifi");
}

function is_yt(n) {
	// lc() в ucode не сворачивает кириллицу: «Россия» и «россия» — разные байты
	let s = group_of(n) + " " + ("" + (n.name || ""));
	return has_any(s, [ "youtube", "YouTube", "Россия", "россия", "РОССИЯ" ]);
}

function plan(mode) {
	let out = [];

	if (mode == "wifi") {
		let lists = wifi_lists();
		// Обе WiFi-секции — urltest: podkop сам выбирает лучший сервер по задержке.
		// xhttp отбрасываем жёстко: без decode-link podkop не умеет такие ссылки,
		// и секция вместо urltest_proxy_links уехала бы в outbound-группу.
		push(out, {
			name: "skop_yt",
			kind: "proxy",
			urltest: true,
			community: lists.yt,
			select: function (n) {
				return is_wifi(n) && !is_xhttp_node(n);
			}
		});
		push(out, {
			name: "skop_eu",
			kind: "proxy",
			urltest: true,
			primary: true,
			community: lists.eu,
			select: function (n) {
				return is_wifi(n) && !is_yt(n) && !is_xhttp_node(n);
			}
		});
		return out;
	}

	// lte (по умолчанию)
	push(out, {
		name: "skop_lte",
		kind: "proxy",
		primary: true,
		fully_routed: true,
		select: function (n) {
			return is_lte(n);
		}
	});
	push(out, {
		name: "skop_lte_direct",
		kind: "exclusion",
		remote_domain: [ GEOSITE ],
		remote_subnet: [ GEOIP ]
	});
	return out;
}

// какие узлы попадут в proxy-секции режима — для `shoulderkop links`.
// Повторяет отбор apply(): если в подписке нет меток LTE/WiFi, все узлы идут
// в основную секцию режима.
function plan_sections(mode, nodes) {
	if (mode != "wifi")
		mode = "lte";

	let list = plan(mode);
	let any_hit = false;
	for (let d in list)
		if (d.kind == "proxy" && d.select != null)
			for (let n in nodes)
				if (d.select(n)) {
					any_hit = true;
					break;
				}

	let out = [];
	for (let d in list) {
		if (d.kind != "proxy")
			continue;

		let matched = [];
		if (d.select != null)
			for (let n in nodes)
				if (d.select(n))
					push(matched, n);

		if (length(matched) == 0 && d.primary && !any_hit)
			matched = nodes;

		if (length(matched) > 0)
			push(out, { name: d.name, nodes: matched });
	}
	return out;
}

// --- запись серверов в секцию ---------------------------------------------

// вернуть { mode, node?, count, children[], xhttp?, changed }
function write_servers(p, cur, name, nodes, decode_ok, urltest_iv, force_urltest) {
	let n = length(nodes);
	let changed = 0;

	// Один узел обычно кладём одиночным outbound. Но WiFi-секции должны быть
	// именно urltest-секциями, поэтому для них force_urltest=true и даже один
	// сервер уходит в urltest_proxy_links (группа из одной ссылки).
	if (n == 1 && !force_urltest) {
		changed += want(p, cur, name, "proxy_config_type", "outbound");
		changed += want(p, cur, name, "outbound_json", sprintf("%J", nodes[0].outbound));
		changed += want(p, cur, name, "urltest_proxy_links", []);
		return { mode: "outbound", node: nodes[0].name, count: 1, changed: changed };
	}

	if (native_links_ok(nodes, decode_ok)) {
		let links = [];
		for (let node in nodes) {
			// xhttp в WiFi-секции отсеивается ещё в plan(); здесь страховка,
			// чтобы в urltest_proxy_links не попала ссылка, которую podkop
			// без tools.decode-link не разберёт.
			if (is_xhttp_node(node))
				continue;
			push(links, node.link);
		}
		if (length(links) > 0) {
			changed += want(p, cur, name, "proxy_config_type", "urltest");
			changed += want(p, cur, name, "urltest_proxy_links", links);
			changed += want(p, cur, name, "outbound_json", null);
			changed += want(p, cur, name, "urltest_check_interval", urltest_iv);
			changed += want(p, cur, name, "urltest_tolerance", "50");
			changed += want(p, cur, name, "urltest_testing_url", "https://www.gstatic.com/generate_204");
			return { mode: "urltest", count: length(links), changed: changed };
		}
	}

	// синтетическая группа: дочерние секции + urltest-JSON на их теги
	let tags = [];
	let children = [];
	let i = 0;
	for (let node in nodes) {
		i++;
		let child = name + "_" + pad2(i);
		if (ensure_section(p, cur, child) == null)
			continue;
		changed += want(p, cur, child, "connection_type", "proxy");
		changed += want(p, cur, child, "proxy_config_type", "outbound");
		changed += want(p, cur, child, "outbound_json", sprintf("%J", node.outbound));
		push(children, child);
		push(tags, child + "-out");
	}

	if (length(tags) == 0)
		return { mode: "group", count: n, children: [], error: "cannot create child sections", changed: changed };

	changed += want(p, cur, name, "proxy_config_type", "outbound");
	changed += want(p, cur, name, "outbound_json", sprintf("%J", {
		type: "urltest",
		outbounds: tags,
		interval: urltest_iv,
		tolerance: 50
	}));
	changed += want(p, cur, name, "urltest_proxy_links", []);

	return { mode: "group", count: n, children: children, changed: changed };
}

// удалить свои (`skop_*`) секции, которых нет в keep
function cleanup(p, cur, keep) {
	let removed = [];
	for (let name in cur) {
		if (substr(name, 0, length(PREFIX)) != PREFIX)
			continue;
		if (keep[name])
			continue;
		p.delete("podkop", name);
		push(removed, name);
	}
	return removed;
}

// --- настройки podkop ------------------------------------------------------

function list_str(v) {
	if (type(v) == "array") {
		let out = "";
		for (let x in v)
			out += ((out == "") ? "" : " ") + ("" + x);
		return trim(out);
	}
	return trim("" + (v == null ? "" : v));
}

// устройство LAN (br-lan) — для source_network_interfaces
function lan_device() {
	let raw = trim(sh("ubus call network.interface.lan status 2>/dev/null"));
	if (raw != "") {
		let st = null;
		try { st = json(raw); } catch (e) { st = null; }
		if (st != null) {
			let dev = trim("" + (st["l3_device"] || st.device || ""));
			if (dev != "")
				return dev;
		}
	}
	let dev = trim(uci_get("network", "lan", "device"));
	if (dev != "")
		return dev;
	for (let d in [ "br-lan", "br-lan1" ])
		if (trim(sh("ls -d /sys/class/net/" + d + " 2>/dev/null")) != "")
			return d;
	return "";
}

// podkop не перехватывает трафик, если не знает интерфейсы → заполняем пустое
function podkop_auto(p) {
	let cur = list_str(p.get("podkop", "settings", "source_network_interfaces"));
	if (cur != "")
		return { changed: 0 };
	let dev = lan_device();
	if (dev == "")
		return { changed: 0, error: "cannot detect LAN interface" };
	p.set("podkop", "settings", "source_network_interfaces", dev);
	return { changed: 1, dev: dev };
}

// podkop ставит в свой конфиг по умолчанию секцию main: connection_type=proxy,
// proxy_config_type=url и пустой proxy_string. podkop обходит ВСЕ секции типа
// section и на пустой строке падает «Proxy string is not set» — конфиг не
// собирается, sing-box не стартует. Раскладку делают наши skop_*-секции,
// поэтому заводскую пустую main убираем (тронутую пользователем — не трогаем).
function is_pristine_main(cur) {
	let s = cur["main"];
	if (s == null)
		return false;
	if (trim("" + (s.connection_type || "")) != "proxy")
		return false;
	if (trim("" + (s.proxy_config_type || "")) != "url")
		return false;
	for (let k in [ "proxy_string", "urltest_proxy_links", "selector_proxy_links", "outbound_json", "interface" ])
		if (list_str(s[k]) != "")
			return false;
	return true;
}

function podkop_state() {
	return {
		enabled: trim(sh("ls /etc/rc.d/[SK]*podkop 2>/dev/null")) != "",
		// [s]ing-box — иначе pgrep находит `sh -c` с этим же шаблоном в cmdline
		running: trim(sh("pgrep -f '[s]ing-box[^ ]* run' 2>/dev/null")) != ""
	};
}

// --- точка входа -----------------------------------------------------------

// nodes — массив узлов из subscription.uc
function apply(nodes) {
	let mode = trim(uci_get("shoulderkop", "settings", "mode"));
	if (mode != "wifi")
		mode = "lte";

	let decode_ok = engine_decode_link();
	let urltest_iv = urltest_interval();
	let plan_list = plan(mode);

	let p = uci.cursor();

	// чистый роутер: podkop может быть не установлен — не создаём ему конфиг и не падаем
	if (!p.load("podkop") || p.get("podkop", "settings") == null)
		return {
			mode: mode,
			lan: null,
			engine_decode_link: decode_ok,
			changed: false,
			service: podkop_state(),
			report: [],
			removed: [],
			error: "podkop не установлен: в /etc/config/podkop нет секции settings — секции раскладывать некуда"
		};

	// секции podkop настраиваются всегда автоматически: переключателя в LuCI больше нет
	let auto_changed = 0;
	let auto_error = null;
	{
		let r = podkop_auto(p);
		auto_changed = r.changed;
		auto_error = r.error;
	}

	let cur = snapshot(p);

	let report = [];
	let keep = {};
	let changed = auto_changed;
	let cidr = null;
	let any_hit = false;
	if (length(nodes) > 0)
		for (let d in plan_list)
			if (d.select != null)
				for (let n in nodes)
					if (d.select(n)) {
						any_hit = true;
						break;
					}

	for (let desc in plan_list) {
		let matched = [];
		if (desc.select != null)
			for (let n in nodes)
				if (desc.select(n))
					push(matched, n);

		// в подписке-списке ссылок нет меток LTE/WiFi: тогда все серверы идут
		// в основную секцию режима, иначе настройка осталась бы пустой
		if (desc.kind == "proxy" && length(matched) == 0 && desc.primary && !any_hit) {
			matched = nodes;
			push(report, { warn: "no mode labels in subscription, all servers put into " + desc.name });
		}

		if (desc.kind == "proxy" && length(matched) == 0) {
			if (cur[desc.name] == null) {
				push(report, { section: desc.name, count: 0,
					error: "no matched nodes, section not created" });
				continue;
			}
			keep[desc.name] = true;
			for (let c in own_children(cur, desc.name))
				keep[c] = true;
			push(report, { section: desc.name, count: 0,
				error: "no matched nodes, left unchanged" });
			continue;
		}

		let sec = ensure_section(p, cur, desc.name);
		if (sec == null) {
			push(report, { section: desc.name, error: "cannot create podkop section" });
			continue;
		}
		keep[sec] = true;
		changed += want(p, cur, sec, "connection_type", desc.kind);

		if (desc.kind == "exclusion") {
			changed += want(p, cur, sec, "remote_domain_lists", desc.remote_domain || []);
			changed += want(p, cur, sec, "remote_subnet_lists", desc.remote_subnet || []);
			push(report, {
				section: sec,
				kind: "exclusion",
				lists: length(desc.remote_domain || []) + length(desc.remote_subnet || [])
			});
			continue;
		}

		changed += want(p, cur, sec, "community_lists", desc.community || []);
		changed += want(p, cur, sec, "remote_domain_lists", desc.remote_domain || []);
		changed += want(p, cur, sec, "remote_subnet_lists", desc.remote_subnet || []);

		if (desc.fully_routed) {
			if (cidr == null)
				cidr = lan_cidr();
			if (cidr != null)
				changed += want(p, cur, sec, "fully_routed_ips", [ cidr, "127.0.0.1" ]);
			else
				push(report, { section: sec, warn: "lan subnet not detected" });
		}
		else
			changed += want(p, cur, sec, "fully_routed_ips", []);

		let r = write_servers(p, cur, sec, matched, decode_ok, urltest_iv, desc.urltest == true);
		changed += r.changed;
		for (let c in (r.children || []))
			keep[c] = true;
		r.section = sec;
		r.kind = "proxy";
		push(report, r);
	}

	let removed = cleanup(p, cur, keep);

	// без своих секций main трогать не будем — иначе оставим podkop без прокси
	if (length(keys(keep)) > 0 && is_pristine_main(cur)) {
		p.delete("podkop", "main");
		push(removed, "main");
	}

	p.commit("podkop");

	if (auto_error != null)
		push(report, { warn: auto_error });

	return {
		mode: mode,
		lan: cidr,
		engine_decode_link: decode_ok,
		changed: changed > 0,
		service: podkop_state(),
		report: report,
		removed: removed
	};
}

return { apply: apply, lan_cidr: lan_cidr, engine_decode_link: engine_decode_link,
	plan_sections: plan_sections };
