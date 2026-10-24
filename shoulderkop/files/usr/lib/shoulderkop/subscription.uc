// shoulderkop — парсер подписки (Xray JSON / список ссылок) → нормализованный список узлов.
//
// Вход: текст подписки. Поддерживаем:
//   - Xray JSON (массив клиентских конфигов, как от Remnawave по UA Happ);
//   - plain/base64 список ссылок vless://… (fallback, одна строка на ссылку).
// Выход: { nodes: [...], skipped: [...] } — nodes без дублей по полной identity;
//   skipped — узлы, отброшенные из-за неподдерживаемых xhttp-полей.
//
// Второй аргумент parse_subscription(text, allow_xhttp): если движок не
// sing-box-extended, передаём false — тогда все xhttp-узлы отбрасываются
// (обычный sing-box такой транспорт не умеет и podkop с ними не поднимется).

let convert = require("convert");

const XHTTP_REASON = "xhttp requires sing-box-extended";

function is_xhttp_net(net) {
	return net == "xhttp" || net == "splithttp";
}

function as_string(v) {
	return (v == null) ? "" : "" + v;
}

function is_xray_config(c) {
	return type(c) == "object" && type(c.outbounds) == "array";
}

function real_outbounds(config) {
	let result = [];
	for (let o in config.outbounds) {
		if (type(o) != "object")
			continue;
		let proto = lc(as_string(o.protocol));
		if (proto == "freedom" || proto == "blackhole" || proto == "direct" || proto == "block")
			continue;
		push(result, o);
	}
	return result;
}

function parse_xray_json(text, allow_xhttp) {
	if (allow_xhttp == null)
		allow_xhttp = true;
	let configs = json(text);
	if (type(configs) != "array")
		configs = [ configs ];

	let nodes = [];
	let skipped = [];
	let seen = {};
	for (let c in configs) {
		if (!is_xray_config(c))
			continue;
		for (let o in real_outbounds(c)) {
			// пометка неподдерживаемого xhttp (обфускация, как в steer)
			let ss = (type(o.streamSettings) == "object") ? o.streamSettings : {};
			let net = lc(as_string(ss.network || "tcp"));
			if (is_xhttp_net(net)) {
				// обычный sing-box xhttp не умеет — такие узлы в podkop не отдаём
				if (!allow_xhttp) {
					push(skipped, { name: convert.server_name(c, o),
						reason: XHTTP_REASON });
					continue;
				}
				let xs = (type(ss.xhttpSettings) == "object") ? ss.xhttpSettings
					: ((type(ss.splithttpSettings) == "object") ? ss.splithttpSettings : {});
				let reason = convert.xhttp_unsupported_reason(xs);
				if (reason != null) {
					push(skipped, { name: convert.server_name(c, o), reason: reason });
					continue;
				}
			}
			let ob = convert.build_outbound(c, o);
			if (ob == null) {
				// REALITY без валидного public_key → sing-box не примет конфиг
				push(skipped, { name: convert.server_name(c, o),
					reason: "reality without public key" });
				continue;
			}
			let id = convert.outbound_identity(ob);
			if (seen[id])
				continue;
			seen[id] = true;
			push(nodes, {
				name: ob.tag,
				group: convert.group_name(c),
				outbound: ob,
				link: convert.build_link(ob)
			});
		}
	}
	return { nodes: nodes, skipped: skipped };
}

function is_base64(s) {
	s = trim(s);
	if (s == "" || index(s, "\n") >= 0)
		return false;
	for (let i = 0; i < length(s); i++) {
		let c = ord(substr(s, i, 1));
		let ok = (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A) ||
			(c >= 0x30 && c <= 0x39) || c == 0x2B || c == 0x2F || c == 0x3D;
		if (!ok)
			return false;
	}
	return true;
}

function parse_links(text, allow_xhttp) {
	if (allow_xhttp == null)
		allow_xhttp = true;
	let nodes = [];
	let skipped = [];
	let seen = {};
	let lines = split(text, "\n");
	for (let line in lines) {
		let link = trim(line);
		if (link == "" || substr(link, 0, 1) == "#")
			continue;
		if (seen[link])
			continue;
		seen[link] = true;

		// подписка-список ссылок: разбираем ссылку в outbound сами
		let ob = convert.parse_link(link);
		if (ob == null) {
			push(skipped, { name: substr(link, 0, 60), reason: "unsupported link" });
			continue;
		}
		// xhttp в ссылке виден только внутри outbound.transport
		if (!allow_xhttp && type(ob.transport) == "object" &&
		    is_xhttp_net(lc(as_string(ob.transport.type)))) {
			push(skipped, { name: ob.tag, reason: XHTTP_REASON });
			continue;
		}
		push(nodes, { name: ob.tag, group: "", outbound: ob, link: link });
	}
	return { nodes: nodes, skipped: skipped };
}

function parse_subscription(text, allow_xhttp) {
	text = trim(as_string(text));
	if (text == "")
		return { nodes: [], skipped: [] };

	// Xray JSON?
	if (substr(text, 0, 1) == "[" || substr(text, 0, 1) == "{")
		return parse_xray_json(text, allow_xhttp);

	// base64?
	if (is_base64(text)) {
		let decoded = b64decode(trim(text));
		if (decoded != null && decoded != "") {
			let r = parse_subscription(decoded, allow_xhttp);
			if (length(r.nodes) > 0)
				return r;
		}
	}

	// plain-список ссылок
	return parse_links(text, allow_xhttp);
}

// ---- распознавание неактивной подписки ------------------------------------
//
// Remnawave на истёкшую/отключённую подписку отдаёт не пустой ответ, а «заглушку»:
// список из двух vless-узлов с нулевым UUID на 0.0.0.0:1 и remarks
// «Приложение не подходит» / «Рекомендуется Happ». Такой ответ нельзя раскладывать
// в podkop: туннель поднимется на несуществующий сервер и «умрёт».
//
// Кроме заглушки учитываем заголовки: subscription-userinfo (expire=<unix>) и
// HTTP 404/410. Но приоритет у реальных серверов: если панель отдала хотя бы один
// рабочий узел, подписка считается активной (иногда панель ещё отдаёт конфиг после
// формальной даты expire — тогда туннель продолжает работать).

const PLACEHOLDER_HOSTS = [ "0.0.0.0", "::", "0:0:0:0:0:0:0:0", "[::]" ];

function is_zero_uuid(u) {
	u = lc(trim(as_string(u)));
	let digits = 0;
	for (let i = 0; i < length(u); i++) {
		let ch = substr(u, i, 1);
		if (ch == "-" || ch == " ")
			continue;
		if (ch != "0")
			return false;
		digits++;
	}
	return digits >= 16;
}

function is_placeholder_host(host) {
	host = lc(trim(as_string(host)));
	for (let h in PLACEHOLDER_HOSTS)
		if (host == h)
			return true;
	return false;
}

function expired_name(s) {
	s = as_string(s);
	let low = lc(s);
	let markers = [
		"приложение не подходит", "Приложение не подходит",
		"рекомендуется happ", "Рекомендуется Happ",
		"подписка истекла", "Подписка истекла",
		"подписка неактивна", "Подписка неактивна"
	];
	for (let m in markers)
		if (index(s, m) >= 0 || index(low, lc(m)) >= 0)
			return true;
	return false;
}

function is_placeholder_node(n) {
	if (type(n) != "object")
		return false;
	let ob = n.outbound;
	if (type(ob) != "object")
		return false;

	let host = trim(as_string(ob.server));
	let port = int(as_string(ob.server_port == null ? "0" : ob.server_port));

	if (is_placeholder_host(host))
		return true;

	// 127.0.0.1:1 / localhost:1 — тоже заглушка, но только с явно
	// нерабочим портом: настоящий локальный outbound так не выглядит
	let low = lc(host);
	if ((low == "127.0.0.1" || low == "localhost" || low == "::1") && port <= 1)
		return true;

	// нулевой UUID + порт-заглушка (1) — служебный узел панели
	if (is_zero_uuid(ob.uuid) && port <= 1)
		return true;

	return expired_name(n.name) || expired_name(n.group);
}

// "active" — есть хотя бы один настоящий узел; "placeholder" — все узлы заглушки;
// "empty" — узлов нет.
function classify_nodes(nodes) {
	if (type(nodes) != "array" || length(nodes) == 0)
		return "empty";
	let real = 0;
	for (let n in nodes)
		if (!is_placeholder_node(n))
			real++;
	return (real > 0) ? "active" : "placeholder";
}

function header_value(headers, name) {
	let found = null;
	name = lc(as_string(name));
	for (let line in split(as_string(headers), "\n")) {
		line = rtrim(line);
		let colon = index(line, ":");
		if (colon <= 0)
			continue;
		if (lc(trim(substr(line, 0, colon))) != name)
			continue;
		found = trim(substr(line, colon + 1));
	}
	return found;
}

// subscription-userinfo: upload=0; download=0; total=0; expire=1792610400
// expire=0 — бессрочная подписка. Панели иногда отдают expire в миллисекундах.
function parse_userinfo(headers) {
	let ui = { upload: 0, download: 0, total: 0, expire: 0, present: false };
	let raw = header_value(headers, "subscription-userinfo");
	if (raw == null || raw == "")
		return ui;

	ui.present = true;
	for (let part in split(raw, ";")) {
		let eq = index(part, "=");
		if (eq <= 0)
			continue;
		let k = lc(trim(substr(part, 0, eq)));
		let v = trim(substr(part, eq + 1));
		if (k != "upload" && k != "download" && k != "total" && k != "expire")
			continue;
		ui[k] = int(v);
		if (ui[k] < 0)
			ui[k] = 0;
	}
	if (ui.expire > 100000000000)
		ui.expire = int(ui.expire / 1000);

	return ui;
}

function has_expired_marker(text) {
	let s = as_string(text);
	if (s == "")
		return false;
	let low = lc(s);
	let markers = [
		"приложение не подходит", "Приложение не подходит",
		"рекомендуется happ", "Рекомендуется Happ",
		"подписка истекла", "Подписка истекла",
		"подписка неактивна", "Подписка неактивна",
		"subscription expired", "subscription is expired",
		"no active subscription", "user not found",
		"subscription not found"
	];
	for (let m in markers)
		if (index(s, m) >= 0 || index(low, lc(m)) >= 0)
			return true;
	return false;
}

// Классификация одного ответа панели.
// p: { http, body, headers, nodes, skipped, now }
function classify_response(p) {
	let http = int(as_string(p.http == null ? "0" : p.http));
	let nodes = (type(p.nodes) == "array") ? p.nodes : [];
	let skipped = (type(p.skipped) == "array") ? p.skipped : [];
	let headers = as_string(p.headers);
	let ui = parse_userinfo(headers);
	let now = (p.now == null) ? time() : p.now;

	let real = 0;
	for (let n in nodes)
		if (!is_placeholder_node(n))
			real++;

	// HTTP-коды панели: 404/410 — подписки больше нет
	if (http == 404 || http == 410)
		return { status: "expired", reason: "HTTP " + http, userinfo: ui };

	// Серверы важнее заголовка expire: если панель реально отдала узлы,
	// подписка рабочая (бывает grace-период после даты окончания).
	if (real > 0)
		return { status: "active", reason: "", userinfo: ui, real: real };

	if (length(nodes) > 0)
		return { status: "expired", reason: "placeholder nodes", userinfo: ui };

	// Ни одного узла не разобрали, но что-то отбросили (xhttp на обычном
	// sing-box) — это не истёкшая подписка, а несовместимый движок:
	// туннель не трогаем.
	if (length(skipped) > 0)
		return { status: "error", reason: "all nodes are unsupported", userinfo: ui };

	if (ui.expire > 0 && ui.expire <= now)
		return { status: "expired", reason: "expire=" + ui.expire, userinfo: ui };

	if (has_expired_marker(p.body))
		return { status: "expired", reason: "panel says subscription is not active", userinfo: ui };

	let cd = header_value(headers, "content-disposition");
	if (cd != null && index(lc(cd), "expired") >= 0)
		return { status: "expired", reason: "content-disposition=expired", userinfo: ui };

	return { status: "error", reason: "no nodes", userinfo: ui };
}

return {
	parse_subscription: parse_subscription,
	parse_xray_json: parse_xray_json,
	parse_links: parse_links,
	is_placeholder_node: is_placeholder_node,
	classify_nodes: classify_nodes,
	classify_response: classify_response,
	parse_userinfo: parse_userinfo,
	header_value: header_value
};