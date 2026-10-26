// shoulderkop — конвертация Xray outbound → sing-box outbound JSON + vless:// link
//
// Логика сверена с forkop (parser.uc `xray_transport_from_stream`, share_link.uc
// `add_xhttp_extra_query`) и провалидирована на реальной подписке Remnawave (Happ).

// ---- утилиты ---------------------------------------------------------------

function as_string(v) {
	return (v == null) ? "" : "" + v;
}

function obj_or_empty(v) {
	return (type(v) == "object") ? v : {};
}

// percent-encoding по байтам (ucode-строки — байтовые)
function uri_encode(s) {
	s = as_string(s);
	let out = "";
	for (let i = 0; i < length(s); i++) {
		let c = ord(substr(s, i, 1));
		let keep = (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A) ||
			(c >= 0x30 && c <= 0x39) ||
			c == 0x2D || c == 0x2E || c == 0x5F || c == 0x7E;
		out += keep ? substr(s, i, 1) : sprintf("%%%02X", c);
	}
	return out;
}

// срезаем числовой префикс "NN | " в начале tag
function strip_tag_prefix(tag) {
	tag = as_string(tag);
	let pos = index(tag, " | ");
	if (pos < 0)
		return tag;
	let prefix = substr(tag, 0, pos);
	let numeric = length(prefix) > 0;
	for (let i = 0; i < length(prefix); i++) {
		let c = ord(substr(prefix, i, 1));
		if (c < 0x30 || c > 0x39) { numeric = false; break; }
	}
	return numeric ? substr(tag, pos + 3) : tag;
}

// имя сервера: remarks для «generic»-узла, иначе tag без "NN | "
function server_name(config, outbound) {
	let tag = trim(as_string(outbound.tag));
	if (tag == "" || tag == "proxy" || tag == "proxy-out") {
		let n = trim(as_string(config.remarks || config.remark || config.name || config.ps));
		return n != "" ? n : tag;
	}
	return strip_tag_prefix(tag);
}

// имя группы = remarks всего конфига («🇪🇺📱LTE ❯ Обход Белых списков» и т.п.).
// Именно по нему режимы выбирают серверы: у самих узлов в name остаётся tag.
function group_name(config) {
	return trim(as_string(config.remarks || config.remark || config.name ||
		config.ps || config.description));
}

// ---- xhttp ----------------------------------------------------------------

// читаем значение настройки xhttp из: xs напрямую → xs.extra → xs.extra.xhttpSettings
function xhttp_setting(xs, camel, snake, defv) {
	function from(c) {
		if (type(c) != "object")
			return null;
		let v = c[camel];
		if (v == null || as_string(v) == "")
			v = c[snake];
		return (v == null || as_string(v) == "") ? null : v;
	}
	let v = from(xs);
	if (v == null)
		v = from(obj_or_empty(xs.extra));
	if (v == null)
		v = from(obj_or_empty(obj_or_empty(xs.extra).xhttpSettings));
	return (v == null) ? defv : v;
}

function xhttp_xmux(xs) {
	let xm = xs.xmux;
	if (type(xm) != "object")
		xm = obj_or_empty(xs.extra).xmux;
	if (type(xm) != "object")
		return null;
	let result = {};
	let pairs = [
		[ "max_concurrency",     "maxConcurrency"     ],
		[ "max_connections",     "maxConnections"     ],
		[ "c_max_reuse_times",   "cMaxReuseTimes"     ],
		[ "h_max_request_times", "hMaxRequestTimes"   ],
		[ "h_max_reusable_secs", "hMaxReusableSecs"   ],
		[ "h_keep_alive_period", "hKeepAlivePeriod"   ]
	];
	for (let p in pairs) {
		let snake = p[0], camel = p[1];
		let v = xm[camel];
		if (v == null || as_string(v) == "")
			v = xm[snake];
		if (v != null && as_string(v) != "")
			result[snake] = v;
	}
	return length(keys(result)) > 0 ? result : null;
}

// режим xhttp нужен, чтобы понять, допустим ли uplink_data_placement=header
function xhttp_mode(xs) {
	return lc(as_string(xhttp_setting(xs, "mode", "mode", "auto")));
}

// «сырые»/обфускационные поля xhttp. Возвращает причину пропуска или null
// (подход steer `xh_extra_bad`).
//
// Проверено на sing-box-extended 1.14.1-extended-2.7.2:
//   uplink_data_placement: auto и body — всегда; header — только в packet-up;
//   x_padding_method:      принимается только tokenish (none/repeat/random/long
//                          движок отвергает), остальные значения — пропуск.
function xhttp_unsupported_reason(xs) {
	let extra = obj_or_empty(xs.extra);

	function has(container, camel) {
		return type(container) == "object" && container[camel] != null && as_string(container[camel]) != "";
	}
	function pick(camel) {
		let v = xs[camel];
		if (v == null || as_string(v) == "")
			v = extra[camel];
		return (v == null) ? "" : as_string(v);
	}

	let udp = lc(pick("uplinkDataPlacement"));
	if (udp != "" && udp != "auto" && udp != "body" &&
	    !(udp == "header" && xhttp_mode(xs) == "packet-up"))
		return "xhttp uplinkDataPlacement=" + pick("uplinkDataPlacement");

	let padm = lc(pick("xPaddingMethod"));
	if (padm != "" && padm != "tokenish")
		return "xhttp xPaddingMethod=" + pick("xPaddingMethod");

	if (has(xs, "xPaddingObfsMode") || has(extra, "xPaddingObfsMode"))
		return "xhttp xPaddingObfsMode";
	if (has(xs, "seqPlacement") || has(extra, "seqPlacement"))
		return "xhttp seqPlacement";

	return null;
}

// ---- outbound JSON --------------------------------------------------------

function build_outbound(config, o) {
	let proto = lc(as_string(o.protocol || "vless"));
	let settings = obj_or_empty(o.settings);
	let stream = obj_or_empty(o.streamSettings);
	let network = lc(as_string(stream.network || "tcp"));
	let security = lc(as_string(stream.security || "none"));

	// vless: единственный vnext-объект
	let vnext = {};
	let users = {};
	if (type(settings.vnext) == "array" && length(settings.vnext) > 0)
		vnext = obj_or_empty(settings.vnext[0]);
	if (type(vnext.users) == "array" && length(vnext.users) > 0)
		users = obj_or_empty(vnext.users[0]);

	let enc = as_string(users.encryption || "none");
	let ob = {
		type: proto,
		tag: server_name(config, o),
		server: as_string(vnext.address),
		server_port: vnext.port,
		uuid: as_string(users.id)
	};
	// sing-box 1.13 (штатный) поля encryption не знает и падает с
	// "unknown field encryption" — а значение none и так по умолчанию
	if (enc != "" && enc != "none")
		ob.encryption = enc;
	let flow = as_string(users.flow);
	if (flow != "")
		ob.flow = flow;

	// tls / reality
	if (security == "tls") {
		let ts = obj_or_empty(stream.tlsSettings);
		let tls = { enabled: true, server_name: as_string(ts.serverName) };
		let alpn = type(ts.alpn) == "array" ? ts.alpn : [];
		if (length(alpn) == 0 && network == "xhttp")
			alpn = [ "h2", "http/1.1" ];
		if (length(alpn) > 0)
			tls.alpn = alpn;
		if (ts.allowInsecure)
			tls.insecure = true;
		if (as_string(ts.fingerprint) != "")
			tls.utls = { enabled: true, fingerprint: as_string(ts.fingerprint) };
		ob.tls = tls;
	} else if (security == "reality") {
		let rs = obj_or_empty(stream.realitySettings);
		let rs2 = obj_or_empty(rs.settings);

		// publicKey лежит в разных местах у разных панелей; Remnawave иногда
		// кладёт его в `password`. Пустой/битый ключ = невалидный конфиг
		// sing-box («initialize outbound: invalid public_key»), поэтому такой
		// узел лучше пропустить (см. subscription.uc).
		let cands = [ rs.publicKey, rs.public_key, rs2.publicKey, rs2.public_key, rs.password ];
		let key = "";
		for (let c in cands) {
			let s = trim("" + (c || ""));
			while (length(s) > 0 && substr(s, length(s) - 1, 1) == "=")
				s = substr(s, 0, length(s) - 1);
			if (length(s) < 40 || length(s) > 44)
				continue;
			let ok = true;
			for (let i = 0; i < length(s); i++) {
				let code = ord(substr(s, i, 1));
				if (!((code >= 0x41 && code <= 0x5a) || (code >= 0x61 && code <= 0x7a) ||
					(code >= 0x30 && code <= 0x39) || code == 0x2d || code == 0x5f)) {
					ok = false;
					break;
				}
			}
			if (ok) { key = s; break; }
		}

		if (key == "")
			return null;

		let tls = {
			enabled: true,
			server_name: as_string(rs.serverName),
			reality: {
				enabled: true,
				public_key: key,
				short_id: as_string(rs.shortId || rs.short_id)
			}
		};
		if (as_string(rs.fingerprint) != "")
			tls.utls = { enabled: true, fingerprint: as_string(rs.fingerprint) };
		ob.tls = tls;
	}

	// transport (splithttp — старое имя xhttp)
	if (network == "splithttp")
		network = "xhttp";

	if (network == "grpc") {
		let gs = obj_or_empty(stream.grpcSettings);
		let tr = { type: "grpc" };
		let sn = as_string(gs.serviceName || gs.service_name);
		if (sn != "")
			tr.service_name = sn;
		ob.transport = tr;
	} else if (network == "xhttp") {
		let xs = obj_or_empty(stream.xhttpSettings);
		if (type(stream.splithttpSettings) == "object" && length(keys(xs)) == 0)
			xs = stream.splithttpSettings;
		let tr = {
			type: "xhttp",
			mode: as_string(xhttp_setting(xs, "mode", "mode", "auto")),
			path: as_string(xhttp_setting(xs, "path", "path", "/")),
			x_padding_bytes: xhttp_setting(xs, "xPaddingBytes", "x_padding_bytes", "100-1000"),
			no_grpc_header: xhttp_setting(xs, "noGRPCHeader", "no_grpc_header", false),
			sc_max_each_post_bytes: xhttp_setting(xs, "scMaxEachPostBytes", "sc_max_each_post_bytes", 1000000),
			sc_min_posts_interval_ms: xhttp_setting(xs, "scMinPostsIntervalMs", "sc_min_posts_interval_ms", 30)
		};
		let host = as_string(xs.host);
		if (host != "")
			tr.host = host;
		let scs = xhttp_setting(xs, "scStreamUpServerSecs", "sc_stream_up_server_secs", null);
		if (scs != null)
			tr.sc_stream_up_server_secs = scs;
		let xmux = xhttp_xmux(xs);
		if (xmux != null)
			tr.xmux = xmux;
		// поля, которые extended принимает (см. xhttp_unsupported_reason)
		let udp = xhttp_setting(xs, "uplinkDataPlacement", "uplink_data_placement", null);
		if (udp != null && as_string(udp) != "")
			tr.uplink_data_placement = as_string(udp);
		let padm = xhttp_setting(xs, "xPaddingMethod", "x_padding_method", null);
		if (padm != null && as_string(padm) != "")
			tr.x_padding_method = as_string(padm);
		ob.transport = tr;
	} else if (network == "ws") {
		let ws = obj_or_empty(stream.wsSettings);
		let tr = { type: "ws", path: as_string(ws.path || "/") };
		let h = obj_or_empty(ws.headers);
		let host = as_string(h.Host || h.host);
		if (host != "")
			tr.headers = { Host: host };
		ob.transport = tr;
	} else if (network == "httpupgrade") {
		let hu = obj_or_empty(stream.httpupgradeSettings);
		let tr = { type: "httpupgrade", path: as_string(hu.path || "/") };
		let host = as_string(hu.host);
		if (host != "")
			tr.host = host;
		ob.transport = tr;
	} else if (network == "http" || network == "h2") {
		let hs = obj_or_empty(stream.httpSettings);
		let tr = { type: "http" };
		if (type(hs.path) == "array" && length(hs.path) > 0)
			tr.path = as_string(hs.path[0]);
		else if (as_string(hs.path) != "")
			tr.path = as_string(hs.path);
		if (type(hs.host) == "array")
			tr.host = hs.host;
		else if (as_string(hs.host) != "")
			tr.host = split(as_string(hs.host), ",");
		ob.transport = tr;
	}
	// tcp — transport не добавляем

	return ob;
}

// ---- vless:// link --------------------------------------------------------

function xhttp_extra_json(tr) {
	let extra = {};
	if (tr.x_padding_bytes != null)
		extra.xPaddingBytes = tr.x_padding_bytes;
	if (tr.no_grpc_header != null)
		extra.noGRPCHeader = tr.no_grpc_header;
	if (tr.sc_max_each_post_bytes != null)
		extra.scMaxEachPostBytes = tr.sc_max_each_post_bytes;
	if (tr.sc_min_posts_interval_ms != null)
		extra.scMinPostsIntervalMs = tr.sc_min_posts_interval_ms;
	if (tr.sc_stream_up_server_secs != null)
		extra.scStreamUpServerSecs = tr.sc_stream_up_server_secs;
	if (tr.x_padding_method != null)
		extra.xPaddingMethod = tr.x_padding_method;
	if (tr.uplink_data_placement != null)
		extra.uplinkDataPlacement = tr.uplink_data_placement;
	if (type(tr.xmux) == "object") {
		let xmux = {};
		let pairs = [
			[ "maxConcurrency",     "max_concurrency"     ],
			[ "maxConnections",     "max_connections"     ],
			[ "cMaxReuseTimes",     "c_max_reuse_times"   ],
			[ "hMaxRequestTimes",   "h_max_request_times" ],
			[ "hMaxReusableSecs",   "h_max_reusable_secs" ],
			[ "hKeepAlivePeriod",   "h_keep_alive_period" ]
		];
		for (let p in pairs) {
			let camel = p[0], snake = p[1];
			if (tr.xmux[snake] != null)
				xmux[camel] = tr.xmux[snake];
		}
		if (length(keys(xmux)) > 0)
			extra.xmux = xmux;
	}
	return length(keys(extra)) > 0 ? extra : null;
}

function build_link(ob) {
	if (type(ob) != "object")
		return null;

	// podkop-секции могут содержать и не-vless outbound (например, urltest-
	// группу). Ссылку из такого объекта не собрать — пусть решает вызывающий.
	let proto = lc(as_string(ob.type || "vless"));
	if (proto != "vless")
		return null;

	let params = [];

	function add(k, v) {
		if (v != null && as_string(v) != "")
			push(params, [ k, as_string(v) ]);
	}

	add("encryption", ob.encryption);
	add("flow", ob.flow);

	let tls = obj_or_empty(ob.tls);
	if (tls.enabled) {
		let reality = obj_or_empty(tls.reality);
		if (reality.enabled) {
			add("security", "reality");
			add("pbk", reality.public_key);
			add("sid", reality.short_id);
		} else {
			add("security", "tls");
		}
		add("sni", tls.server_name);
		if (tls.insecure)
			add("allowInsecure", "1");
		let utls = obj_or_empty(tls.utls);
		if (utls.enabled && as_string(utls.fingerprint) != "")
			add("fp", utls.fingerprint);
		if (type(tls.alpn) == "array" && length(tls.alpn) > 0)
			add("alpn", join(",", tls.alpn));
	} else {
		add("security", "none");
	}

	let tr = obj_or_empty(ob.transport);
	if (tr.type != null && as_string(tr.type) != "" && as_string(tr.type) != "tcp") {
		let t = as_string(tr.type);
		add("type", t);
		if (t == "grpc") {
			add("serviceName", tr.service_name);
		} else if (t == "xhttp") {
			add("path", tr.path);
			add("host", tr.host);
			add("mode", tr.mode);
			let extra = xhttp_extra_json(tr);
			if (extra != null)
				add("extra", sprintf("%J", extra));
		} else if (t == "ws") {
			add("path", tr.path);
			let h = obj_or_empty(tr.headers);
			add("host", as_string(h.Host || h.host));
		} else if (t == "httpupgrade") {
			add("path", tr.path);
			add("host", tr.host);
		} else if (t == "http") {
			add("path", tr.path);
			if (type(tr.host) == "array")
				add("host", join(",", tr.host));
			else
				add("host", tr.host);
		}
	} else {
		add("type", "tcp");
	}

	let qs = "";
	for (let p in params) {
		qs += (qs == "" ? "" : "&") + uri_encode(p[0]) + "=" + uri_encode(p[1]);
	}

	return "vless://" + ob.uuid + "@" + ob.server + ":" + ob.server_port +
		(qs != "" ? "?" + qs : "") + "#" + uri_encode(as_string(ob.tag));
}

// полная identity узла (для дедупликации): outbound без tag
function outbound_identity(ob) {
	let d = {};
	for (let k in keys(ob))
		if (k != "tag")
			d[k] = ob[k];
	return sprintf("%J", d);
}

// ---- ссылка → outbound ----------------------------------------------------
//
// Часть панелей отдаёт не Xray JSON, а список ссылок (`vless://…`). Разбираем
// ссылку в тот же «xray-подобный» объект, что приходит в подписке, и отдаём
// его в build_outbound — так правила конвертации остаются в одном месте.

function hexval(ch) {
	let c = ord(ch);
	if (c >= 0x30 && c <= 0x39)
		return c - 0x30;
	if (c >= 0x41 && c <= 0x46)
		return c - 0x37;
	if (c >= 0x61 && c <= 0x66)
		return c - 0x57;
	return -1;
}

function uri_decode(s) {
	let out = "";
	let i = 0;
	while (i < length(s)) {
		let ch = substr(s, i, 1);
		if (ch == "%" && i + 2 < length(s)) {
			let h1 = hexval(substr(s, i + 1, 1));
			let h2 = hexval(substr(s, i + 2, 1));
			if (h1 >= 0 && h2 >= 0) {
				out += chr(h1 * 16 + h2);
				i += 3;
				continue;
			}
		}
		out += (ch == "+") ? " " : ch;
		i++;
	}
	return out;
}

function parse_params(query) {
	let p = {};
	for (let kv in split(query, "&")) {
		kv = trim(kv);
		if (kv == "")
			continue;
		let eq = index(kv, "=");
		let k = (eq >= 0) ? substr(kv, 0, eq) : kv;
		let v = (eq >= 0) ? uri_decode(substr(kv, eq + 1)) : "";
		p[lc(k)] = v;
	}
	return p;
}

// vless://uuid@host:port?params#name → outbound (или null, если не разобрали)
function parse_link(link) {
	let s = trim(as_string(link));
	let sep = index(s, "://");
	if (sep <= 0)
		return null;

	let scheme = lc(substr(s, 0, sep));
	if (scheme != "vless")
		return null;

	let rest = substr(s, sep + 3);
	let name = "";

	let hash = index(rest, "#");
	if (hash >= 0) {
		name = uri_decode(substr(rest, hash + 1));
		rest = substr(rest, 0, hash);
	}

	let query = "";
	let qm = index(rest, "?");
	if (qm >= 0) {
		query = substr(rest, qm + 1);
		rest = substr(rest, 0, qm);
	}

	let at = rindex(rest, "@");
	if (at <= 0)
		return null;

	let uuid = substr(rest, 0, at);
	let hostport = substr(rest, at + 1);
	let host = hostport;
	let port = 443;
	let colon = rindex(hostport, ":");
	if (colon > 0) {
		host = substr(hostport, 0, colon);
		port = int(substr(hostport, colon + 1));
	}
	if (host == "" || uuid == "")
		return null;

	let p = parse_params(query);
	let net = lc(p.type || "tcp");
	if (net == "splithttp")
		net = "xhttp";
	else if (net == "h2")
		net = "http";

	let sec = lc(p.security || "none");
	let stream = { network: net, security: sec };

	if (sec == "tls") {
		let ts = { serverName: p.sni || "", fingerprint: p.fp || "" };
		if (p.allowinsecure == "1" || p.insecure == "1")
			ts.allowInsecure = true;
		if (p.alpn)
			ts.alpn = split(p.alpn, ",");
		stream.tlsSettings = ts;
	}
	else if (sec == "reality") {
		stream.realitySettings = {
			serverName: p.sni || "",
			fingerprint: p.fp || "",
			publicKey: p.pbk || "",
			shortId: p.sid || "",
			spiderX: p.spx || ""
		};
	}

	let path = (p.path != "") ? p.path : "/";
	let hostHeader = p.host || "";

	if (net == "xhttp") {
		stream.xhttpSettings = { path: path, host: hostHeader };
		if (p.mode != "")
			stream.xhttpSettings.mode = p.mode;
		// xray кладёт тонкие настройки xhttp в extra=<json>
		if (p.extra != "") {
			let ex = null;
			try { ex = json(p.extra); } catch (e) { ex = null; }
			if (type(ex) == "object")
				for (let k in [ "xPaddingBytes", "xPaddingMethod", "uplinkDataPlacement",
						"noGRPCHeader", "scMaxEachPostBytes", "scMinPostsIntervalMs",
						"scStreamUpServerSecs" ])
					if (ex[k] != null && as_string(ex[k]) != "")
						stream.xhttpSettings[k] = ex[k];
		}
	}
	else if (net == "ws") {
		stream.wsSettings = { path: path };
		if (hostHeader != "")
			stream.wsSettings.headers = { Host: hostHeader };
	}
	else if (net == "grpc") {
		stream.grpcSettings = { serviceName: p.servicename || "" };
		if (p.mode != "")
			stream.grpcSettings.multiMode = (p.mode == "multi");
	}
	else if (net == "httpupgrade") {
		stream.httpupgradeSettings = { path: path, host: hostHeader };
	}
	else if (net == "http") {
		stream.httpSettings = { path: path };
		if (hostHeader != "")
			stream.httpSettings.host = [ hostHeader ];
	}
	else if (net == "tcp" && lc(p.headertype || "") == "http") {
		stream.tcpSettings = { header: { type: "http",
			request: { path: [ path ], headers: { Host: [ hostHeader ] } } } };
	}

	let obj = {
		protocol: "vless",
		tag: "",
		settings: { vnext: [ { address: host, port: port, users: [ {
			id: uuid,
			encryption: p.encryption || "none",
			flow: p.flow || ""
		} ] } ] },
		streamSettings: stream
	};

	return build_outbound({ remarks: name }, obj);
}

return {
	build_outbound: build_outbound,
	build_link: build_link,
	server_name: server_name,
	group_name: group_name,
	outbound_identity: outbound_identity,
	uri_encode: uri_encode,
	uri_decode: uri_decode,
	parse_link: parse_link,
	xhttp_unsupported_reason: xhttp_unsupported_reason
};