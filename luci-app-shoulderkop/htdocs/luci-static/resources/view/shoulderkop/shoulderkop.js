'use strict';
'require view';
'require form';
'require uci';
'require fs';
'require ui';
'require dom';

// Shoulderkop v2 — одна страница, минимум настроек:
//   ссылка подписки + режим (LTE / WiFi) → остальное пакет настраивает в podkop сам.
//   Для WiFi — списки сообщества podkop (как в редакторе секции podkop); в LTE их нет.
//   «Обновить подписку» — сохранить настройки, скачать подписку и разложить секции.
//   «Обновить конфигурацию» (появляется при смене режима) — то же самое, но с полной
//   пересборкой секций podkop: старые удаляются, новые создаются с нуля.

var MODE_LTE = 'lte';
var MODE_WIFI = 'wifi';

var SETTINGS = 'settings';

// Списки сообщества podkop (github.com/itdoginfo/allow-domains) — те же значения
// и подписи, что в podkop: DOMAIN_LIST_OPTIONS / COMMUNITY_SERVICES.
var DOMAIN_LIST_OPTIONS = [
	[ 'russia_inside', 'Russia inside' ],
	[ 'russia_outside', 'Russia outside' ],
	[ 'ukraine_inside', 'Ukraine' ],
	[ 'geoblock', 'Geo Block' ],
	[ 'block', 'Block' ],
	[ 'porn', 'Porn' ],
	[ 'news', 'News' ],
	[ 'anime', 'Anime' ],
	[ 'youtube', 'Youtube' ],
	[ 'discord', 'Discord' ],
	[ 'meta', 'Meta' ],
	[ 'twitter', 'Twitter (X)' ],
	[ 'hdrezka', 'HDRezka' ],
	[ 'tiktok', 'Tik-Tok' ],
	[ 'telegram', 'Telegram' ],
	[ 'cloudflare', 'Cloudflare' ],
	[ 'google_ai', 'Google AI' ],
	[ 'google_play', 'Google Play' ],
	[ 'hodca', 'H.O.D.C.A' ],
	[ 'roblox', 'Roblox' ],
	[ 'hetzner', 'Hetzner ASN' ],
	[ 'ovh', 'OVH ASN' ],
	[ 'digitalocean', 'Digital Ocean ASN' ],
	[ 'cloudfront', 'CloudFront ASN' ]
];

var DOMAIN_LIST_LABELS = {};

DOMAIN_LIST_OPTIONS.forEach(function (p) {
	DOMAIN_LIST_LABELS[p[0]] = p[1];
});

var REGIONAL_OPTIONS = [ 'russia_inside', 'russia_outside', 'ukraine_inside' ];

// Как в podkop: russia_inside уже включает YouTube, Geo Block, Block и т.д.,
// поэтому с ним остаются только совместимые списки (у части из них отдельные
// подсети). Остальные значения при выборе russia_inside удаляются.
var ALLOWED_WITH_RUSSIA_INSIDE = [
	'russia_inside', 'meta', 'twitter', 'discord', 'telegram', 'cloudflare',
	'google_ai', 'google_play', 'hetzner', 'ovh', 'hodca', 'roblox',
	'digitalocean', 'cloudfront'
];

// Значения по умолчанию повторяют прежнее захардкоженное поведение:
// skop_yt → youtube, skop_eu → russia_inside,telegram,meta,cloudflare,hodca,roblox.
var WIFI_LIST_DEFAULTS = {
	yt: [ 'youtube' ],
	eu: [ 'russia_inside', 'telegram', 'meta', 'cloudflare', 'hodca', 'roblox' ]
};

// После «Сохранить и применить» пересобираем секции (мог смениться режим) и
// переставляем cron: расписание живёт в /etc/crontabs/root, а не в UCI.
// Кнопки страницы этот хук не ждут — они ходят в бэкенд напрямую.
var appliedHooked = false;

function hookAfterApply() {
	if (appliedHooked)
		return;
	appliedHooked = true;

	document.addEventListener('uci-applied', function () {
		fs.exec('/usr/bin/shoulderkop', [ 'apply' ]).then(function () {
			return fs.exec('/usr/bin/shoulderkop', [ 'schedule' ]);
		}).catch(function (e) {
			ui.addNotification(null, E('p', {}, _('Не удалось обновить секции: ') + errText(e)), 'error');
		});
	});
}

function errText(e) {
	if (e == null)
		return _('неизвестная ошибка');
	if (typeof e === 'object' && e.message)
		return e.message;
	return '' + e;
}

function modeLabel(mode) {
	return (mode === MODE_WIFI) ? _('Домашний интернет') : _('Обход БС');
}

// ---- списки сообщества (WiFi) ---------------------------------------------

function listValues(o, section_id) {
	var v = o.formvalue(section_id);
	if (!Array.isArray(v))
		v = (v != null && v !== '') ? [ v ] : [];
	return v.filter(function (x) { return x != null && ('' + x).trim() !== ''; });
}

function listLabel(v) {
	return DOMAIN_LIST_LABELS[v] || v;
}

function listLabelText(values) {
	return (values || []).map(listLabel).join(', ');
}

// Поле как в podkop: DynamicList с предопределёнными списками и кнопкой
// «Service list». При выборе russia_inside несовместимые списки убираются.
function communityListOption(s, name, title, description, defaults) {
	var o = s.option(form.DynamicList, name, title, description);

	o.placeholder = 'Service list';
	o.rmempty = false;
	o.default = defaults.slice();
	o.depends('mode', MODE_WIFI);

	DOMAIN_LIST_OPTIONS.forEach(function (p) {
		o.value(p[0], _(p[1]));
	});

	o.validate = function (section_id, value) {
		var vals = Array.isArray(value) ? value
			: ((value != null && value !== '') ? [ value ] : []);
		if (!vals.length)
			return _('Выберите хотя бы один список сообщества.');
		for (var i = 0; i < vals.length; i++)
			if (!DOMAIN_LIST_LABELS[vals[i]])
				return _('Неизвестный список: ') + vals[i];
		return true;
	};

	var isProcessing = false;

	o.onchange = function (ev, section_id, value) {
		if (isProcessing)
			return;
		isProcessing = true;

		try {
			var values = Array.isArray(value) ? value.slice()
				: ((value != null && value !== '') ? [ value ] : []);
			var next = values.slice();
			var notifications = [];

			var regional = REGIONAL_OPTIONS.filter(function (v) {
				return next.indexOf(v) >= 0;
			});
			if (regional.length > 1) {
				var last = regional[regional.length - 1];
				var removedRegions = regional.slice(0, -1);
				next = next.filter(function (v) {
					return v === last || REGIONAL_OPTIONS.indexOf(v) < 0;
				});
				notifications.push(E('p', {}, [
					E('strong', {}, _('Нельзя использовать несколько региональных списков')),
					E('br'),
					_('Убраны: ') + listLabelText(removedRegions) + _('; оставлен: ') + listLabel(last) + '.'
				]));
			}

			if (next.indexOf('russia_inside') >= 0) {
				var removedServices = next.filter(function (v) {
					return ALLOWED_WITH_RUSSIA_INSIDE.indexOf(v) < 0;
				});
				if (removedServices.length > 0) {
					next = next.filter(function (v) {
						return ALLOWED_WITH_RUSSIA_INSIDE.indexOf(v) >= 0;
					});
					notifications.push(E('p', { class: 'alert-message warning' }, [
						E('strong', {}, _('Russia inside уже включает эти списки')),
						E('br'),
						_('Убраны: ') + listLabelText(removedServices) + '.'
					]));
				}
			}

			if (next.join('\n') !== values.join('\n')) {
				var el = this.getUIElement(section_id);
				if (el)
					el.setValue(next);
			}

			notifications.forEach(function (n) {
				ui.addNotification(null, n);
			});
		} catch (e) {
			console.error('community list onchange:', e);
		} finally {
			isProcessing = false;
		}
	};

	return o;
}

// ---- отображение состояния подписки ---------------------------------------

function fmtDate(ts) {
	if (!ts || ts <= 0)
		return '—';
	return new Date(ts * 1000).toLocaleString();
}

function fmtBytes(n) {
	n = Number(n) || 0;
	if (n <= 0)
		return '0';
	var units = [ 'Б', 'КБ', 'МБ', 'ГБ', 'ТБ' ];
	var i = 0;
	while (n >= 1024 && i < units.length - 1) {
		n /= 1024;
		i++;
	}
	return ((n < 10) ? n.toFixed(1) : Math.round(n)) + ' ' + units[i];
}

function noteBox(kind, text) {
	return E('div', { class: 'alert-message ' + kind, style: 'margin:0 0 8px 0' }, text);
}

function expireText(ui, active) {
	if (!ui || !ui.expire || ui.expire <= 0)
		return null;
	if ((ui.expire * 1000) > Date.now())
		return _('Подписка активна до: ') + fmtDate(ui.expire);
	// дата прошла, но панель ещё отдаёт серверы (grace-период)
	return (active ? _('Срок подписки истёк: ') : _('Подписка истекла: ')) + fmtDate(ui.expire);
}

function trafficText(ui) {
	if (!ui || !ui.total || ui.total <= 0)
		return null;
	return _('Трафик: ') + fmtBytes((ui.upload || 0) + (ui.download || 0)) + ' / ' + fmtBytes(ui.total);
}

function serviceText(s) {
	s = s || {};
	var parts = [];

	if (s.podkop_installed) {
		parts.push('podkop: ' + (s.podkop_enabled
			? _('автозапуск включён')
			: _('автозапуск выключен')) +
			(s.singbox_running ? _(' · работает') : _(' · остановлен')));
	}
	else {
		parts.push('podkop: ' + _('не установлен'));
	}

	if (s.singbox_installed) {
		var sb = 'sing-box: ' + (s.singbox_running ? _('работает') : _('остановлен'));
		// подкоп сам поднимает sing-box — отдельный автозапуск ему не нужен
		if (!s.singbox_running && !s.podkop_enabled)
			sb += _(' · автозапуск выключен');
		parts.push(sb);
	}

	return parts.join('; ');
}

function listBlock(title, items) {
	items = (items || []).filter(function (x) { return x != null && ('' + x) !== ''; });
	if (!items.length)
		return null;
	return E('div', {}, [
		E('strong', {}, title),
		E('ul', {}, items.map(function (x) { return E('li', {}, '' + x); }))
	]);
}

// ---- несколько подписок ---------------------------------------------------
//
// Ссылок может быть несколько: активные складываются в общий пул серверов,
// истёкшие просто пропускаются. Здесь показываем статус каждой ссылки, чтобы
// было видно, которая именно отвалилась (токен в списке обрезаем).

function shortUrl(u) {
	u = '' + (u || '');
	var m = u.match(/^[a-z][a-z0-9+.-]*:\/\/([^\/?#]+)([^?#]*)/i);
	if (!m)
		return (u.length > 40) ? u.substr(0, 37) + '…' : u;
	var host = m[1];
	var path = m[2] || '';
	var s = host + path;
	if (s.length > 36)
		s = host + path.substr(0, Math.max(0, 36 - host.length - 1)) + '…';
	return s;
}

function reasonText(r) {
	r = '' + (r || '');
	if (r === '')
		return '';
	if (/^HTTP \d+$/.test(r))
		return r;
	if (r === 'request failed')
		return _('запрос не выполнен');
	if (r === 'no usable nodes')
		return _('нет рабочих узлов');
	if (r === 'placeholder nodes')
		return _('панель отдала заглушку');
	if (r === 'all nodes are unsupported')
		return _('все узлы неподдерживаемые');
	if (r === 'no nodes')
		return _('узлов нет');
	if (r === 'panel says subscription is not active')
		return _('панель: подписка неактивна');
	if (r === 'content-disposition=expired')
		return _('панель: подписка истекла');
	if (r.indexOf('expire=') === 0)
		return _('срок истёк: ') + fmtDate(Number(r.substr(7)));
	return r;
}

function linkStatusLabel(st) {
	if (st === 'active')
		return _('активна');
	if (st === 'expired')
		return _('истекла');
	return _('ошибка');
}

function linksBlock(list) {
	list = (list || []).filter(function (x) { return x != null; });
	if (!list.length)
		return null;

	var active = 0, expired = 0, bad = 0;
	var items = list.map(function (c) {
		var st = c.status || 'error';
		if (st === 'active')
			active++;
		else if (st === 'expired')
			expired++;
		else
			bad++;

		var extra = reasonText(c.reason);
		if (c.http === 0 && st !== 'active')
			extra = _('нет связи');
		else if (st === 'active' && c.expire > 0)
			extra = ((c.expire * 1000) <= Date.now() ? _('срок истёк: ') : _('до ')) + fmtDate(c.expire);
		else if (st === 'expired' && c.expire > 0 && extra === '')
			extra = _('срок: ') + fmtDate(c.expire);

		return E('li', { title: '' + (c.url || '') }, [
			E('strong', {}, shortUrl(c.url)),
			' — ' + linkStatusLabel(st),
			extra ? ' (' + extra + ')' : ''
		]);
	});

	var head = _('Подписки: ') + list.length +
		' (' + _('активных: ') + active +
		(expired ? _(' · истекло: ') + expired : '') +
		(bad ? _(' · с ошибкой: ') + bad : '') + ')';

	return E('div', {}, [ E('strong', {}, head), E('ul', {}, items) ]);
}

function closeBtn(after) {
	return E('div', { class: 'right', style: 'margin-top:8px' }, [
		E('button', {
			class: 'cbi-button',
			click: function () {
				ui.hideModal();
				if (after)
					after();
			}
		}, _('Закрыть'))
	]);
}

// ---- аргументы для бэкенда -------------------------------------------------
//
// Кнопка не требует «Сохранить и применить»: значения виджетов уходят аргументами,
// конфиг пишет сам shoulderkop (uci.cursor). Через rpcd (uci.save/uci.apply) не ходим:
// в этой сборке запись отбивалась -32002 Access denied, и update работал бы по старым
// ссылке и режиму.

function flagValue(v) {
	return (v === true || v === '1' || v === 1) ? '1' : '0';
}

// ---- диагностика ----------------------------------------------------------

function diagTime(ts) {
	if (!ts)
		return _('ещё не запускалась');
	var d = new Date(ts * 1000);
	return d.toLocaleString();
}

function diagLine(c) {
	return E('li', { style: c.ok ? '' : 'color:#c00' },
		(c.ok ? '\u2714 ' : '\u2718 ') + c.name + (c.detail ? ' — ' + c.detail : ''));
}

function refreshDiag(el) {
	return fs.exec('/usr/bin/shoulderkop', [ 'status' ]).then(function (r) {
		var st = null;
		try { st = JSON.parse(r.stdout || '{}'); } catch (e) { st = null; }
		var d = (st && st.diag) ? st.diag : null;
		var last = d ? d.last : null;
		var out = [];

		if (!d || !d.enabled) {
			out.push(E('div', {}, _('Диагностика выключена.')));
		} else if (!last) {
			out.push(E('div', {}, _('Ещё не запускалась.') + ' ' + _('Интервал:') + ' ' + (d.interval || '5m')));
		} else {
			out.push(E('div', {}, _('Последняя проверка: ') + diagTime(last.ts)));
			out.push(E('div', {}, (last.ok ? '\u2714 ' + _('сеть в порядке') : '\u2718 ' + _('есть проблемы')) +
				(d.direct ? ' ' + _('(сейчас direct: podkop остановлен)') : '')));
			if (last.checks && last.checks.length)
				out.push(E('ul', { style: 'margin:.3em 0 .3em 1.2em' }, last.checks.map(diagLine)));
			if (last.actions && last.actions.length)
				out.push(E('ul', { style: 'margin:.3em 0 .3em 1.2em' },
					last.actions.map(function (a) { return E('li', {}, _('починка: ') + a); })));
			out.push(E('div', {}, _('Интервал: ') + (d.interval || '5m') +
				(d.history_len ? ', ' + _('история: ') + d.history_len : '')));
		}

		out.push(E('div', { class: 'cbi-button-row', style: 'margin-top:.5em' }, [
			E('button', {
				class: 'cbi-button cbi-button-action',
				click: function (ev) {
					ev.preventDefault();
					var btn = ev.currentTarget;
					btn.disabled = true;
					btn.textContent = _('проверяю…');
					return fs.exec('/usr/bin/shoulderkop', [ 'diag', '--json' ]).then(function () {
						return refreshDiag(el);
					}).catch(function () {
						btn.disabled = false;
						btn.textContent = _('Проверить сейчас');
					});
				}
			}, _('Проверить сейчас'))
		]));

		dom.content(el, out);
		return el;
	}).catch(function (e) {
		dom.content(el, E('em', {}, _('не удалось получить статус: ') + e));
		return el;
	});
}

function updateArgs(ctx, rebuild) {
	var urls = ctx.url.formvalue(SETTINGS);
	if (!Array.isArray(urls))
		urls = (urls != null && urls !== '') ? [ urls ] : [];
	urls = urls.filter(function (u) { return u != null && ('' + u).trim() !== ''; });

	if (urls.length === 0)
		return Promise.reject(new Error(_('Укажите ссылку подписки.')));

	var mode = ctx.mode.formvalue(SETTINGS) || MODE_LTE;
	var ytLists = [];
	var euLists = [];

	if (mode === MODE_WIFI) {
		ytLists = listValues(ctx.ytLists, SETTINGS);
		euLists = listValues(ctx.euLists, SETTINGS);

		if (!ytLists.length || !euLists.length)
			return Promise.reject(new Error(_('Выберите хотя бы один список сообщества для каждой WiFi-секции.')));
	}

	var args = [ 'update' ];
	if (rebuild)
		args.push('--rebuild');
	urls.forEach(function (u) { args.push('--url=' + ('' + u).trim()); });

	args.push('--mode=' + mode);
	args.push('--interval=' + (ctx.interval.formvalue(SETTINGS) || '1h'));
	args.push('--urltest=' + (ctx.urltest.formvalue(SETTINGS) || '30s'));
	args.push('--schedule=' + flagValue(ctx.sched.formvalue(SETTINGS)));

	// Свои списки сообщества передаём только для WiFi: в LTE секции свои,
	// а сохранённые значения не трогаем, чтобы они пережили переключение режима.
	if (mode === MODE_WIFI) {
		args.push('--yt-lists=' + ytLists.join(','));
		args.push('--eu-lists=' + euLists.join(','));
	}

	return Promise.resolve(args);
}

// ---- отчёт update ---------------------------------------------------------

function appliedLine(a) {
	if (a.error)
		return E('li', {}, (a.section || '?') + ': ' + _('ошибка: ') + a.error);
	if (a.kind === 'exclusion')
		return E('li', {}, a.section + ': ' + _('списки → напрямую') + ' (' + (a.lists || 0) + ')');
	if (a.mode === 'group')
		return E('li', {}, a.section + ': ' + _('группа из ') + (a.children ? a.children.length : 0) + _(' серверов'));
	if (a.mode === 'urltest')
		return E('li', {}, a.section + ': ' + (a.count || 0) + _(' серверов (urltest)'));
	if (a.mode === 'outbound')
		return E('li', {}, a.section + ': ' + _('один сервер → ') + a.node);
	if (!a.section)
		return null;
	return E('li', {}, a.section + ': ' + (a.count || 0) + _(' серверов'));
}

function reportNodes(r) {
	var out = [];
	var status = r.status || ((r.count || 0) > 0 ? 'active' : null);
	var warnings = r.warnings || [];
	var errors = r.errors || [];
	var ui = r.userinfo || null;

	if (status === 'expired') {
		out.push(noteBox('warning', _('Подписка неактивна (истекла). Podkop и sing-box остановлены, автозапуск выключен. Планировщик продолжает проверять подписку: как только панель отдаст серверы, туннель запустится автоматически.')));

		var et = expireText(ui);
		if (et)
			out.push(E('p', {}, E('strong', {}, et)));
		var tr = trafficText(ui);
		if (tr)
			out.push(E('p', {}, tr));

		var act = listBlock(_('Что сделано:'), r.actions);
		if (act)
			out.push(act);

		if (r.suspended_at)
			out.push(E('p', {}, E('strong', {}, _('Пауза с: ')) + fmtDate(r.suspended_at)));

		var lk = linksBlock(r.checked);
		if (lk)
			out.push(lk);

		var wl = listBlock(_('Предупреждения:'), warnings.concat(errors));
		if (wl)
			out.push(wl);

		return out;
	}

	if (status === 'error') {
		out.push(noteBox('warning', _('Не удалось проверить подписку — podkop оставлен как есть, туннель не трогали.')));
		var lk2 = linksBlock(r.checked);
		if (lk2)
			out.push(lk2);
		var el = listBlock(_('Ошибки:'), errors);
		if (el)
			out.push(el);
		var wl2 = listBlock(_('Предупреждения:'), warnings);
		if (wl2)
			out.push(wl2);
		return out;
	}

	out.push(E('p', {}, [
		E('strong', {}, _('Режим: ')), r.mode ? modeLabel(r.mode) : '—',
		E('br'),
		E('strong', {}, _('Серверов: ')), '' + (r.count || 0)
	]));

	var et2 = expireText(ui, true);
	if (et2)
		out.push(E('p', {}, E('strong', {}, et2)));
	var tr2 = trafficText(ui);
	if (tr2)
		out.push(E('p', {}, tr2));

	if (r.resumed) {
		out.push(noteBox('success', _('Подписка активна — podkop и sing-box запущены снова.')));
		var ract = listBlock(_('Что сделано:'), r.resume_actions);
		if (ract)
			out.push(ract);
	}
	else if (r.suspended) {
		out.push(noteBox('warning', _('Подписка активна, но туннель не удалось запустить. Следующая проверка попробует ещё раз.')));
	}

	if (r.lan)
		out.push(E('p', {}, E('strong', {}, _('LAN: ')) + r.lan));

	var lk3 = linksBlock(r.checked);
	if (lk3)
		out.push(lk3);

	var lines = (r.applied || []).map(appliedLine).filter(function (x) { return x != null; });
	if (lines.length) {
		out.push(E('p', {}, E('strong', {}, _('Секции podkop:'))));
		out.push(E('ul', {}, lines));
	}

	if (r.removed && r.removed.length)
		out.push(E('p', {}, E('strong', {}, _('Удалено: ')) + r.removed.join(', ')));

	var wl3 = listBlock(_('Предупреждения:'), warnings);
	if (wl3)
		out.push(wl3);
	var el2 = listBlock(_('Ошибки:'), errors);
	if (el2)
		out.push(el2);

	return out;
}

// Сохранить настройки и обновить конфигурацию.
// rebuild = true — сначала удалить все секции skop_* из podkop и создать заново.
function doUpdate(ctx, rebuild) {
	var title = rebuild ? _('Обновить конфигурацию') : _('Обновить подписку');

	ui.showModal(title, [ E('p', { class: 'spinning' }, _('Применяю настройки…')) ]);

	updateArgs(ctx, rebuild).then(function (args) {
		ui.showModal(title, [ E('p', { class: 'spinning' },
			rebuild ? _('Заново собираю секции Podkop…') : _('Скачиваю подписку и раскладываю секции…')) ]);

		return fs.exec('/usr/bin/shoulderkop', args).then(function (res) {
			return fs.exec('/usr/bin/shoulderkop', [ 'schedule' ]).then(function () { return res; });
		});
	}).then(function (res) {
		var text = (res.stdout || '').trim();
		var body;

		try {
			body = reportNodes(JSON.parse(text));
		}
		catch (e) {
			body = [
				E('p', {}, _('Код выхода: ') + res.code),
				E('pre', {}, text || (res.stderr || '') || _('нет вывода'))
			];
		}

		ui.showModal(title, body.concat([ closeBtn(function () { location.reload(); }) ]));
	}).catch(function (e) {
		ui.showModal(title, [
			E('p', {}, _('Не удалось обновить: ') + errText(e)),
			closeBtn()
		]);
	});
}

// ---- состояние ------------------------------------------------------------

function statusNodes(st) {
	if (st == null || (st.updated == null && !st.suspended && st.status !== 'error'))
		return [ E('em', {}, _('Данных пока нет — нажмите «Обновить подписку».')) ];

	var out = [];
	var warnings = st.warnings || [];
	var errors = st.errors || [];
	var ui = st.userinfo || null;

	if (st.suspended) {
		if (st.status === 'active') {
			out.push(noteBox('warning', _('Подписка активна, но туннель на паузе: последняя попытка запуска не удалась. Следующая проверка попробует снова.')));
		}
		else if (st.status === 'error') {
			out.push(noteBox('warning', _('Туннель на паузе. Последняя проверка подписки не удалась (сеть или панель) — пауза сохраняется, следующая попытка по расписанию.')));
		}
		else {
			out.push(noteBox('warning', _('Подписка неактивна (истекла). Podkop и sing-box остановлены, автозапуск выключен. Планировщик продолжает проверять подписку и запустит туннель, когда панель отдаст серверы.')));
		}
		if (st.suspended_at)
			out.push(E('p', {}, E('strong', {}, _('Пауза с: ')) + fmtDate(st.suspended_at)));
	}
	else if (st.status === 'error') {
		out.push(noteBox('warning', _('Последняя проверка не удалась — podkop оставлен как есть, туннель не трогали.')));
	}

	var et = expireText(ui, st.status === 'active');
	if (et)
		out.push(E('p', {}, E('strong', {}, et)));
	var tr = trafficText(ui);
	if (tr)
		out.push(E('p', {}, tr));

	out.push(E('p', {}, [
		E('strong', {}, _('Серверов: ')), '' + (st.count || 0),
		E('br'),
		E('strong', {}, _('Последняя проверка: ')), st.updated ? fmtDate(st.updated) : '—',
		E('br'),
		E('strong', {}, _('Режим: ')), st.mode ? modeLabel(st.mode) : '—'
	]));

	if (st.services) {
		var svc = serviceText(st.services);
		if (svc)
			out.push(E('p', {}, E('strong', {}, _('Сервисы: ')) + svc));
	}

	var lines = (st.applied || []).map(appliedLine).filter(function (x) { return x != null; });
	if (lines.length) {
		out.push(E('p', {}, E('strong', {}, _('Секции podkop:'))));
		out.push(E('ul', {}, lines));
	}

	var lk = linksBlock(st.checked);
	if (lk)
		out.push(lk);

	var wl = listBlock(_('Предупреждения:'), warnings);
	if (wl)
		out.push(wl);

	var el2 = listBlock(_('Ошибки:'), errors);
	if (el2)
		out.push(el2);

	return out;
}

function refreshStatus(el) {
	fs.exec('/usr/bin/shoulderkop', [ 'status' ]).then(function (res) {
		var st = null;
		try { st = JSON.parse((res.stdout || '').trim()); } catch (e) { st = null; }
		dom.content(el, statusNodes(st));
	}).catch(function () {
		dom.content(el, statusNodes(null));
	});
}

// ---- страница -------------------------------------------------------------

return view.extend({
	load: function () {
		return uci.load('shoulderkop');
	},

	render: function () {
		var map = new form.Map('shoulderkop', _('Shoulderkop'),
			_('Вставьте ссылку подписки и выберите режим — секции Podkop настроятся сами.'));

		var savedMode = uci.get('shoulderkop', SETTINGS, 'mode') || MODE_LTE;

		// контекст для сохранения формы: ссылки на виджеты
		var ctx = {};

		// строка с кнопкой «Обновить конфигурацию», появляется при смене режима
		var hintEl = E('div', {});

		// прятать нужно всю строку .cbi-value: у пустой ячейки остаётся margin-bottom
		function hintRow() {
			var n = hintEl.parentNode;
			while (n != null && n.nodeType === 1) {
				if (n.classList && n.classList.contains('cbi-value'))
					return n;
				n = n.parentNode;
			}
			return null;
		}

		function showHint(on) {
			var row = hintRow();
			if (row)
				row.style.display = on ? '' : 'none';
		}

		function spawnHint(value) {
			if (value === savedMode) {
				dom.content(hintEl, []);
				showHint(false);
				return;
			}
			dom.content(hintEl, [
				E('p', { style: 'margin:0 0 6px 0' },
					_('Режим изменён на «') + modeLabel(value) + _('». Нажмите «Обновить конфигурацию» — секции Podkop будут собраны заново.')),
				E('button', {
					class: 'cbi-button cbi-button-action',
					click: function () { doUpdate(ctx, true); }
				}, _('Обновить конфигурацию'))
			]);
			showHint(true);
		}

		// без заголовка секции: у NamedSection h3 не рисуется при title = null
		var s = map.section(form.NamedSection, SETTINGS, 'settings', null);
		s.addremove = false;
		s.anonymous = false;

		var o;

		o = s.option(form.DummyValue, '_about', _('Описание'));
		o.rawhtml = true;
		o.cfgvalue = function () {
			return E('div', { style: 'max-width:60em' }, [
				E('p', { style: 'margin:0 0 6px 0' }, [
					_('Пакет сделан как дополнение к podkop: сам туннель он не поднимает, а только раскладывает серверы из подписки по секциям podkop. Написан для личного использования — пользоваться можно свободно, но на свой страх и риск. Адаптирован под формат подписки сервиса '),
					E('a', { href: 'https://fast4g.ru', target: '_blank', rel: 'noopener' }, 'https://fast4g.ru'),
					'.'
				]),
				E('p', { style: 'margin:0 0 6px 0' },
					_('Если подписка истекла, podkop и sing-box останавливаются, их автозапуск выключается, а планировщик продолжает проверять подписку. Когда в ней снова появятся серверы, всё запустится автоматически. Для этого должно быть включено «Обновлять по расписанию».')),
				E('p', { style: 'margin:0' },
					_('Требуется podkop > 0.7.24, а для серверов xhttp — sing-box > 1.14.1-extended-2.7.2.'))
			]);
		};

		o = s.option(form.DynamicList, 'subscription_url', _('Ссылка подписки'),
			_('Одна или несколько ссылок (Xray JSON, список ссылок или base64).'));
		o.placeholder = 'https://…';
		o.rmempty = false;
		ctx.url = o;

		o = s.option(form.ListValue, 'mode', _('Режим'));
		o.value(MODE_LTE, _('Обход БС'));
		o.value(MODE_WIFI, _('Домашний интернет'));
		o.default = MODE_WIFI;
		o.rmempty = false;
		o.onchange = function (ev, section_id, value) {
			spawnHint(value);
		};
		ctx.mode = o;

		// пояснение к режимам отдельной строкой: в description перенос не сделать,
		// там строка рендерится текстовым узлом и \n схлопывается
		o = s.option(form.DummyValue, '_modehelp', '\u00a0');
		o.rawhtml = true;
		o.cfgvalue = function () {
			return E('div', { class: 'cbi-value-description', style: 'max-width:60em' }, [
				E('div', {}, _('«Обход БС» — весь трафик через туннель, кроме белого списка РКН (белые списки — напрямую).')),
				E('div', {}, _('«Домашний интернет» — трафик по умолчанию напрямую, заблокированные сервисы через туннель.'))
			]);
		};

		// Списки сообщества podkop для WiFi-секций. Пока значения не меняли,
		// действуют прежние захардкоженные: youtube и russia_inside+telegram+…
		// В LTE поля скрыты и на раскладку не влияют.
		o = communityListOption(s, 'wifi_yt_lists',
			_('Списки сообщества — YouTube'),
			_('Что направлять через серверы YouTube (секция skop_yt).'),
			WIFI_LIST_DEFAULTS.yt);
		ctx.ytLists = o;

		o = communityListOption(s, 'wifi_eu_lists',
			_('Списки сообщества — остальные сервисы'),
			_('Что направлять через остальные WiFi-серверы (секция skop_eu).'),
			WIFI_LIST_DEFAULTS.eu);
		ctx.euLists = o;

		o = s.option(form.DummyValue, '_listshelp', '\u00a0');
		o.rawhtml = true;
		o.depends('mode', MODE_WIFI);
		o.cfgvalue = function () {
			return E('div', { class: 'cbi-value-description', style: 'max-width:60em' }, [
				E('div', {}, [
					_('Списки берутся из '),
					E('a', {
						href: 'https://github.com/itdoginfo/allow-domains',
						target: '_blank',
						rel: 'noopener'
					}, 'github.com/itdoginfo/allow-domains'),
					_('. Russia inside уже включает YouTube, Geo Block и другие списки — отдельно их добавлять не нужно.')
				]),
				E('div', {}, _('По умолчанию: YouTube — youtube; остальные сервисы — russia_inside, telegram, meta, cloudflare, hodca, roblox.')),
				E('div', {}, _('Изменения применяются кнопкой «Обновить подписку» или «Сохранить и применить».'))
			]);
		};

		// title = nbsp (не null и не пустая строка) — иначе LuCI не резервирует колонку
		// подписи и блок уезжает влево, под названия пунктов.
		o = s.option(form.DummyValue, '_modehint', '\u00a0');
		o.rawhtml = true;
		o.cfgvalue = function () {
			return hintEl;
		};

		// как часто sing-box в группе проверяет серверы и выбирает лучший
		o = s.option(form.ListValue, 'urltest_interval', _('Интервал выбора лучшего сервера'),
			_('Как часто группа серверов проверяет узлы и переключается на лучший.'));
		o.value('30s', _('30 секунд'));
		o.value('1m', _('1 минута'));
		o.value('2m', _('2 минуты'));
		o.value('3m', _('3 минуты'));
		o.value('5m', _('5 минут'));
		o.value('10m', _('10 минут'));
		o.default = '30s';
		ctx.urltest = o;

		o = s.option(form.DummyValue, '_actions', _('Действия'));
		o.rawhtml = true;
		o.cfgvalue = function () {
			return E('div', { class: 'cbi-button-row' }, [
				E('button', {
					class: 'cbi-button cbi-button-action',
					click: function () { doUpdate(ctx, false); }
				}, _('Обновить подписку')),
				' ',
				E('a', { class: 'cbi-button', href: L.url('admin/services/podkop') }, _('Открыть podkop'))
			]);
		};

		o = s.option(form.DummyValue, '_status', _('Состояние'));
		o.rawhtml = true;
		o.cfgvalue = function () {
			var el = E('div', {}, E('em', {}, _('загрузка…')));
			refreshStatus(el);
			return el;
		};

		o = s.option(form.ListValue, 'update_interval', _('Интервал обновления'));
		o.value('30m', _('Каждые 30 минут'));
		o.value('1h', _('Каждый час'));
		o.value('3h', _('Каждые 3 часа'));
		o.value('6h', _('Каждые 6 часов'));
		o.value('12h', _('Каждые 12 часов'));
		o.value('1d', _('Каждый день'));
		o.default = '1h';
		ctx.interval = o;

		o = s.option(form.Flag, 'enable_schedule', _('Обновлять по расписанию'),
			_('Поставить cron-задание, которое обновляет подписку.'));
		o.default = '1';
		ctx.sched = o;

		o = s.option(form.Flag, 'diag_enabled', _('Проверять сеть и чинить'),
			_('Раз в несколько минут проверять интернет и при поломке возвращать автозапуск podkop, перезапускать его, переключать DNS, а при мёртвых узлах переводить всё в direct.'));
		o.default = '1';
		ctx.diag = o;

		o = s.option(form.ListValue, 'diag_interval', _('Интервал диагностики'));
		o.value('5m', _('5 минут'));
		o.value('10m', _('10 минут'));
		o.value('15m', _('15 минут'));
		o.value('30m', _('30 минут'));
		o.default = '5m';
		o.depends('diag_enabled', '1');
		ctx.diagInterval = o;

		o = s.option(form.DummyValue, '_diag', _('Диагностика'));
		o.rawhtml = true;
		o.cfgvalue = function () {
			var el = E('div', {}, E('em', {}, _('загрузка…')));
			refreshDiag(el);
			return el;
		};

		hookAfterApply();

		return map.render().then(function (node) {
			// прячем пустую строку и сразу, и после вставки в документ
			showHint(false);
			window.setTimeout(function () { showHint(false); }, 0);
			return node;
		});
	}
});
