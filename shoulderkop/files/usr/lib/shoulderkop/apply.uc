// apply.uc — раскладка узлов подписки по секциям podkop. Режим один —
// «Домашний интернет» (wifi):
//   skop_yt — urltest, community_lists из wifi_yt_lists;
//   skop_eu — urltest, community_lists из wifi_eu_lists;
// обе секции — urltest_proxy_links со vless-ссылками, xhttp-узлы отсеиваются:
// без `tools decode-link` podkop такие ссылки не разбирает.
//
// Списки сообщества — настоящий редактор секций: что в конфиге, то и в podkop,
// пусто — значит пусто. Дефолты один раз пишет migrate_settings (main.uc),
// здесь подстановок нет.
//
// Сервера в секции:
//   - ссылки podkop умеет декодировать сама (vless tcp/ws/grpc, либо любой
//     транспорт при наличии tools decode-link)
//                  → proxy_config_type=urltest + urltest_proxy_links;
//   - иначе        → «синтетическая группа»: дочерние секции skop_<имя>_NN
//                    (outbound) + urltest-JSON на их теги <child>-out.
//
// Всё, что начинается с `skop_`, считаем своим и удаляем, если оно больше не нужно.
// Секцию без подходящих серверов НЕ создаём: пустой proxy-секции podkop не
// переварит («Outbound section not found») и упадёт целиком.
//
// podkop здесь не перезапускается: раскладка пишет конфиг, а перезапуск и
// ожидание готовности делает main.uc через podkopctl.

'use strict';

let fs = require("fs");
let uci = require("uci");
let podkopctl = require("podkopctl");

const MODE = "wifi";
const PREFIX = "skop_";

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

// UCI-список (option ... / list ...) → массив значений. `uci get` отдаёт
// list-опцию одной строкой, элементы разделены любым пробельным символом
// (пробел, таб, перевод строки). Делим по всем сразу: иначе «a b» приходит
// одним значением и не проходит фильтр COMMUNITY_LISTS.
function uci_list_get(cfg, sec, opt) {
	let raw = uci_get(cfg, sec, opt);
	raw = replace(replace(raw, "\n", " "), "\t", " ");

	let out = [];
	for (let v in split(raw, " ")) {
		v = trim(v);
		if (v != "")
			push(out, v);
	}
	return out;
}

// community_lists для секции: ровно то, что в конфиге. Порядок сохраняем,
// повторы и неизвестные podkop имена отбрасываем. Пустой список = пусто:
// подстановок дефолтов здесь больше нет (их один раз пишет migrate_settings).
function community_lists(opt) {
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
	return out;
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

function transport_of(n) {
	if (n.outbound == null)
		return "tcp";
	let tr = n.outbound.transport;
	return (type(tr) == "object") ? ("" + (tr.type || "tcp")) : "tcp";
}

// xhttp podkop без `tools decode-link` не разбирает. В wifi-секциях такие узлы
// отбрасываем жёстко: иначе urltest_proxy_links не собрать и секция уедет в
// синтетическую группу из outbound-секций.
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

// --- отбор серверов --------------------------------------------------------

// Подписка Remnawave отдаёт по одному клиентскому конфигу на «хост», и именно
// remarks этого конфига содержит метку («🇷🇺 WiFi ❯ Россия (YouTube)»).
// У самих узлов в name — только их tag, поэтому режимы отбирают серверы по
// группе, а name/адрес оставляем как запасной путь.
function group_of(n) {
	return "" + (n.group || "");
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

// План wifi-раскладки. Обе секции — urltest: podkop сам выбирает лучший сервер
// по задержке. skop_eu — основная: если в подписке нет меток WiFi/Youtube,
// все серверы уходят в неё (иначе настройка осталась бы пустой).
function plan() {
	return [
		{
			name: "skop_yt",
			community: community_lists("wifi_yt_lists"),
			select: function (n) {
				return is_wifi(n) && !is_xhttp_node(n);
			}
		},
		{
			name: "skop_eu",
			primary: true,
			community: community_lists("wifi_eu_lists"),
			select: function (n) {
				return is_wifi(n) && !is_yt(n) && !is_xhttp_node(n);
			}
		}
	];
}

// какие узлы попадут в proxy-секции — для `shoulderkop links`.
// Повторяет отбор apply(): если в подписке нет меток WiFi, все узлы идут
// в основную секцию.
function plan_sections(nodes) {
	let list = plan();
	let any_hit = false;
	for (let d in list)
		if (d.select != null)
			for (let n in nodes)
				if (d.select(n)) {
					any_hit = true;
					break;
				}

	let out = [];
	for (let d in list) {
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

// вернуть { mode, node?, count, children[], changed }
function write_servers(p, cur, name, nodes, decode_ok, urltest_iv, force_urltest) {
	let n = length(nodes);
	let changed = 0;

	// Один узел обычно кладём одиночным outbound. Но wifi-секции должны быть
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
			// xhttp в wifi-секции отсеивается ещё в plan(); здесь страховка,
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

// снести все свои секции — для `update --rebuild`, когда план уже проверен
function wipe_own(p, cur) {
	let gone = [];
	for (let name in cur) {
		if (substr(name, 0, length(PREFIX)) != PREFIX)
			continue;
		p.delete("podkop", name);
		push(gone, name);
	}
	return gone;
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

// --- точка входа -----------------------------------------------------------

// nodes — массив узлов из subscription.uc; opts.rebuild — пересобрать секции
// с нуля (снос только после проверки, что новый план не пустой).
function apply(nodes, opts) {
	opts = opts || {};
	let rebuild = (opts.rebuild == true);

	let decode_ok = engine_decode_link();
	let urltest_iv = urltest_interval();
	let plan_list = plan();

	let p = uci.cursor();

	// чистый роутер: podkop может быть не установлен — не создаём ему конфиг и не падаем
	if (!p.load("podkop") || p.get("podkop", "settings") == null)
		return {
			mode: MODE,
			lan: null,
			engine_decode_link: decode_ok,
			changed: false,
			service: podkopctl.state(),
			rebuilt: false,
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

	// Сначала считаем план, ничего не записывая: при --rebuild нельзя сносить
	// секции, если подходящих серверов нет — иначе podkop останется без outbound.
	let any_hit = false;
	for (let d in plan_list)
		for (let n in nodes)
			if (d.select(n)) {
				any_hit = true;
				break;
			}

	let prepared = [];
	let total = 0;
	for (let d in plan_list) {
		let matched = [];
		for (let n in nodes)
			if (d.select(n))
				push(matched, n);

		// в подписке-списке ссылок нет меток WiFi: тогда все серверы идут
		// в основную секцию, иначе настройка осталась бы пустой
		if (length(matched) == 0 && d.primary && !any_hit)
			matched = nodes;

		push(prepared, { desc: d, nodes: matched });
		total += length(matched);
	}

	let rebuilt = false;
	let removed = [];

	if (rebuild) {
		if (total == 0)
			return {
				mode: MODE,
				lan: null,
				engine_decode_link: decode_ok,
				changed: false,
				service: podkopctl.state(),
				rebuilt: false,
				report: [],
				removed: [],
				error: "пересборка отменена: подходящих серверов нет — секции podkop не тронуты"
			};
		removed = wipe_own(p, cur);
		cur = snapshot(p);
		rebuilt = true;
	}

	let report = [];
	let keep = {};
	let changed = auto_changed;

	for (let it in prepared) {
		let desc = it.desc;
		let matched = it.nodes;

		if (length(matched) == 0) {
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
		changed += want(p, cur, sec, "connection_type", "proxy");
		changed += want(p, cur, sec, "community_lists", desc.community || []);

		let r = write_servers(p, cur, sec, matched, decode_ok, urltest_iv, true);
		changed += r.changed;
		for (let c in (r.children || []))
			keep[c] = true;
		r.section = sec;
		r.kind = "proxy";
		push(report, r);
	}

	// всё, что начинается с skop_ и не нужно текущей wifi-раскладке, — наше:
	// сюда же попадают lte-секции прежних версий
	let gone = cleanup(p, cur, keep);
	for (let name in gone)
		push(removed, name);

	// без своих секций main трогать не будем — иначе оставим podkop без прокси
	if (length(keys(keep)) > 0 && is_pristine_main(cur)) {
		p.delete("podkop", "main");
		push(removed, "main");
	}

	p.commit("podkop");

	if (auto_error != null)
		push(report, { warn: auto_error });

	return {
		mode: MODE,
		lan: null,
		engine_decode_link: decode_ok,
		changed: changed > 0,
		service: podkopctl.state(),
		rebuilt: rebuilt,
		report: report,
		removed: removed
	};
}

return { apply: apply, lan_cidr: lan_cidr, engine_decode_link: engine_decode_link,
	plan_sections: plan_sections };
