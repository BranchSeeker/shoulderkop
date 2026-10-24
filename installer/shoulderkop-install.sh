#!/bin/sh
# shoulderkop-install.sh — ставит shoulderkop вместе с podkop и sing-box-extended.
#
# Всё необходимое ставится само. При первом запуске спрашиваем:
#   1) ставить ли sing-box-extended (нужен для xhttp-узлов);
#   2) ссылку на подписку (можно пропустить и добавить позже в LuCI).
# При повторном запуске добавляются вопросы про обновление: если установленная
# версия shoulderkop/podkop старее последнего релиза, показываем обе версии и
# спрашиваем, обновлять ли (--yes отвечает «да», --force обновляет без вопросов).
#
# Запуск: sh shoulderkop-install.sh [--url=...] [--yes] [--dry-run]
# Требует OpenWrt 24.10+ (apk или opkg) и права root.
set -u

APP="ShoulderKop installer"
VER="2.0"
UA="shoulderkop-installer/$VER"

PODKOP_REPO="itdoginfo/podkop"
PODKOP_MIN="0.7.24"
SBE_REPO="shtorm-7/sing-box-extended"
SBE_PIN="v1.14.3-extended-2.7.3"
SBE_MIN="1.14.1-extended-2.7.2"
SK_REPO="${SK_REPO:-BranchSeeker/shoulderkop}"
MIRRORS="https://ghproxy.net/ https://gh-proxy.com/ https://ghfast.top/"

WORK=""
LOG="/tmp/shoulderkop-install.log"

ASSUME_YES=0
DRY=0
FORCE=0
INTERACTIVE=0
DO_PODKOP=1
DO_SINGBOX=1
DO_SK=1
WANT_EXTENDED=1

URL=""
MODE=""
INTERVAL=""
URLTEST=""
SCHEDULE=""
SB_FORMAT=""
PKG_FORCE=""
LOCAL_DIR=""
BASE_URL=""

DISTRIB_ID=""
DISTRIB_RELEASE=""
DISTRIB_ARCH=""
DISTRIB_TARGET=""
BOARD=""
HOSTNAME_=""
PKG=""
PKG_EXT=""
MEM_KB=0
OVERLAY_KB=0
TMP_KB=0
ROOT_KB=0

STOPPED=0
ZB_STOPPED=0
ENGINE_DIRTY=0
ENGINE_EXISTED=0
CORE_EXISTED=0
ENGINE_BACKUP=""
CORE_BACKUP=""

REMOVED_DNS=0
SUB_TRIED=0
SUB_OK=0
SUB_PAUSED=0
SUB_COUNT=""

# ---------- оформление ----------

init_colors() {
	if [ -t 1 ]; then
		_esc=$(printf '\033')
		C_GREEN="${_esc}[1;32m"
		C_YELLOW="${_esc}[1;33m"
		C_RED="${_esc}[1;31m"
		C_WHITE="${_esc}[1;37m"
		C_GRAY="${_esc}[0;90m"
		C_RESET="${_esc}[0m"
		unset _esc
	else
		C_GREEN=""
		C_YELLOW=""
		C_RED=""
		C_WHITE=""
		C_GRAY=""
		C_RESET=""
	fi
}

log() {
	printf '%s %s\n' "$(date +%H:%M:%S 2>/dev/null)" "$*" >>"$LOG" 2>/dev/null
}

blank() {
	printf '\n'
}

step() {
	printf '\n%s %s\n' "${C_YELLOW}[ * ]${C_RESET}" "${C_YELLOW}$*${C_RESET}"
	log "== $*"
}

ok() {
	printf '  %s %s\n' "${C_GREEN}[ ✓ ]${C_RESET}" "$*"
	log "ok: $*"
}

warn() {
	printf '  %s %s\n' "${C_YELLOW}[!]${C_RESET}" "$*"
	log "warn: $*"
}

err() {
	printf '  %s %s\n' "${C_RED}[x]${C_RESET}" "$*" >&2
	log "err: $*"
}

info() {
	printf '  %s %s\n' "${C_GRAY}·${C_RESET}" "$*"
	log "$*"
}

hint() {
	printf '    %s%s%s\n' "$C_GRAY" "$*" "$C_RESET"
}

question() {
	printf '%s %s' "${C_GREEN}[?]${C_RESET}" "${C_YELLOW}$*${C_RESET}"
}

mb() {
	printf '%s' "$(( ${1:-0} / 1024 ))"
}

have() {
	command -v "$1" >/dev/null 2>&1
}

trim() {
	printf '%s' "$1" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//'
}

timeout_run() {
	_tr_secs="$1"
	shift
	if have timeout; then
		timeout "$_tr_secs" "$@"
	else
		"$@"
	fi
}

show_log_tail() {
	[ -s "$LOG" ] || return 0
	printf '  %s\n' "${C_GRAY}Последние строки журнала:${C_RESET}" >&2
	tail -n 6 "$LOG" 2>/dev/null | sed 's/^/    /' >&2
}

# ---------- вопросы ----------

ask_yn() {
	_yn_q="$1"
	_yn_d="${2:-y}"
	if [ "$INTERACTIVE" -eq 0 ] || [ "$ASSUME_YES" -eq 1 ]; then
		[ "$_yn_d" = "y" ]
		return
	fi
	while :; do
		if [ "$_yn_d" = "y" ]; then
			_yn_h="Y/n"
		else
			_yn_h="y/N"
		fi
		printf ' %s %s ' "$(question "$_yn_q")" "${C_GRAY}($_yn_h)${C_RESET}"
		if ! read -r _yn_a; then
			printf '\n'
			# Ctrl+D — не отказ, а «нет ответа»: берём вариант по умолчанию
			[ "$_yn_d" = "y" ]
			return
		fi
		[ -z "$_yn_a" ] && _yn_a="$_yn_d"
		case "$_yn_a" in
			y|Y|yes|YES|Yes|да|Да|д|Д) return 0 ;;
			n|N|no|NO|No|нет|Нет|н|Н) return 1 ;;
			*) printf '  %s\n' "${C_RED}Введите y или n.${C_RESET}" ;;
		esac
	done
}

ask_url() {
	blank
	hint "Вставьте ссылку на подписку и нажмите Enter."
	hint "Пусто — пропустить: добавите позже в LuCI."
	while :; do
		printf ' %s ' "$(question 'Ссылка на подписку:')"
		if ! read -r _url_in; then
			printf '\n'
			return 0
		fi
		_url_in=$(trim "$_url_in")
		[ -z "$_url_in" ] && return 0
		case "$_url_in" in
			http://*|https://*) URL="$_url_in"; return 0 ;;
			*) printf '  %s\n' "${C_RED}Ссылка должна начинаться с http:// или https://${C_RESET}" ;;
		esac
	done
}

# ---------- сеть ----------

fetch() {
	_fetch_url="$1"
	if have curl; then
		curl -fsSL --connect-timeout 10 --max-time 30 -A "$UA" "$_fetch_url" 2>/dev/null
	elif have wget; then
		wget -q -T 15 -t 1 -U "$UA" -O - "$_fetch_url" 2>/dev/null
	elif have uclient-fetch; then
		uclient-fetch -q -O - "$_fetch_url" 2>/dev/null
	else
		return 1
	fi
}

dl() {
	_dl_url="$1"
	_dl_file="$2"
	for _dl_prefix in "" $MIRRORS; do
		_dl_src="${_dl_prefix}${_dl_url}"
		rm -f "$_dl_file" 2>/dev/null
		if have curl; then
			curl -fL --connect-timeout 15 --max-time 600 --retry 1 -A "$UA" -o "$_dl_file" "$_dl_src" 2>/dev/null \
				&& [ -s "$_dl_file" ] && return 0
		elif have wget; then
			wget -q -T 120 -t 1 -U "$UA" -O "$_dl_file" "$_dl_src" 2>/dev/null \
				&& [ -s "$_dl_file" ] && return 0
		else
			uclient-fetch -q -O "$_dl_file" "$_dl_src" 2>/dev/null \
				&& [ -s "$_dl_file" ] && return 0
		fi
	done
	rm -f "$_dl_file" 2>/dev/null
	return 1
}

latest_tag() {
	_lt_repo="$1"
	_lt_json=$(fetch "https://api.github.com/repos/$_lt_repo/releases/latest")
	_lt_tag=$(printf '%s' "$_lt_json" \
		| grep -o '"tag_name"[[:space:]]*:[[:space:]]*"[^"]*"' \
		| head -n 1 \
		| sed 's/.*"\([^"]*\)"$/\1/')
	if [ -z "$_lt_tag" ]; then
		_lt_html=$(fetch "https://github.com/$_lt_repo/releases/latest")
		_lt_tag=$(printf '%s' "$_lt_html" \
			| grep -o '/releases/tag/[^"]*' \
			| head -n 1 \
			| sed 's|.*/||')
	fi
	if [ -z "$_lt_tag" ] && have curl; then
		_lt_eff=$(curl -fsSL -o /dev/null -w '%{url_effective}' --max-time 20 \
			"https://github.com/$_lt_repo/releases/latest" 2>/dev/null)
		case "$_lt_eff" in
			*/releases/tag/*) _lt_tag="${_lt_eff##*/}" ;;
		esac
	fi
	printf '%s\n' "$_lt_tag"
}

release_assets() {
	_ra_repo="$1"
	_ra_tag="$2"
	_ra_json=$(fetch "https://api.github.com/repos/$_ra_repo/releases/tags/$_ra_tag")
	_ra_urls=$(printf '%s' "$_ra_json" \
		| grep -o 'https://[^"]*/releases/download/[^"]*' \
		| sort -u)
	if [ -n "$_ra_urls" ]; then
		printf '%s\n' "$_ra_urls"
		return 0
	fi
	fetch "https://github.com/$_ra_repo/releases/expanded_assets/$_ra_tag" \
		| grep -o "/$_ra_repo/releases/download/[^\"]*" \
		| sed 's|^|https://github.com|' \
		| sort -u
}

pick_asset() {
	printf '%s\n' "$1" | grep -E "/$2[-_][^/]*\.${PKG_EXT}\$" | head -n 1
}

# ---------- версии и место ----------

ver_ge() {
	_vg_a=$(printf '%s' "$1" | sed 's/^[^0-9]*//')
	_vg_b=$(printf '%s' "$2" | sed 's/^[^0-9]*//')
	[ -n "$_vg_a" ] && [ -n "$_vg_b" ] || return 1
	awk -v a="$_vg_a" -v b="$_vg_b" 'BEGIN {
		na = split(a, x, /[^0-9]+/);
		nb = split(b, y, /[^0-9]+/);
		n = (na > nb ? na : nb);
		for (i = 1; i <= n; i++) {
			u = (i <= na && x[i] != "") ? x[i] + 0 : 0;
			v = (i <= nb && y[i] != "") ? y[i] + 0 : 0;
			if (u > v) exit 0;
			if (u < v) exit 1;
		}
		exit 0;
	}'
}

podkop_version() {
	[ -x /usr/bin/podkop ] || return 1
	_pv=$(timeout_run 10 /usr/bin/podkop show_version 2>/dev/null | head -n 1)
	printf '%s\n' "$_pv" | sed 's/^v//'
}

singbox_version() {
	_sv=$(timeout_run 10 sing-box version 2>/dev/null | head -n 1)
	printf '%s\n' "$_sv" | awk 'NF {print $NF}'
}

singbox_extended() {
	case "$1" in
		*extended*) return 0 ;;
		*) return 1 ;;
	esac
}
# Установленная версия shoulderkop (без суффиксов -rN / -N): для проверки обновлений
sk_version() {
	case "$PKG" in
		apk)
			_skv=$(apk list --installed shoulderkop 2>/dev/null | awk 'NR == 1 { print $1 }')
			[ -n "$_skv" ] || _skv=$(apk info -e shoulderkop 2>/dev/null | head -n 1)
			_skv=$(printf '%s\n' "$_skv" | sed 's/^shoulderkop-//; s/-r[0-9]*$//')
			;;
		opkg)
			_skv=$(opkg status shoulderkop 2>/dev/null \
				| sed -n 's/^Version:[[:space:]]*//p' | head -n 1)
			_skv=$(printf '%s\n' "$_skv" | sed 's/-[0-9]*$//')
			;;
		*) _skv="" ;;
	esac
	printf '%s\n' "$_skv"
}

free_kb() {
	df -k "$1" 2>/dev/null | awk 'NR == 2 {print $4}'
}

mem_kb() {
	awk '/^MemTotal:/ {print $2}' /proc/meminfo 2>/dev/null
}

# subscription_url — это список, поэтому uci get может промолчать:
# проверяем и сам конфиг, чтобы не спрашивать ссылку повторно
sub_url_set() {
	[ -f /etc/config/shoulderkop ] || return 1
	_val=$(uci -q get shoulderkop.settings.subscription_url 2>/dev/null)
	[ -n "$_val" ] && return 0
	grep -q 'subscription_url' /etc/config/shoulderkop 2>/dev/null
}

# Первое вхождение ключа: sed с `.*` жадный и цеплял бы "count"/"status"
# из вложенных объектов (applied[], checked[]) вместо итоговых полей.
json_num() {
	printf '%s' "$1" | grep -o "\"$2\":[[:space:]]*[0-9][0-9]*" | head -n 1 \
		| sed 's/.*:[[:space:]]*//'
}

json_arr() {
	printf '%s' "$1" | sed -n "s/.*\"$2\":[[:space:]]*\[\([^]]*\)\].*/\1/p" | head -n 1
}

json_str() {
	printf '%s' "$1" | grep -o "\"$2\":[[:space:]]*\"[^\"]*\"" | head -n 1 \
		| sed 's/^[^:]*:[[:space:]]*"//; s/"$//'
}

# ---------- окружение ----------

detect_pkg() {
	if [ -n "$PKG_FORCE" ]; then
		case "$PKG_FORCE" in
			apk)
				have apk || die "--pkg=apk, но apk в системе не найден"
				PKG="apk"; PKG_EXT="apk"
				;;
			opkg)
				have opkg || die "--pkg=opkg, но opkg в системе не найден"
				PKG="opkg"; PKG_EXT="ipk"
				;;
		esac
		return 0
	fi
	if have apk; then
		PKG="apk"; PKG_EXT="apk"
	elif have opkg; then
		PKG="opkg"; PKG_EXT="ipk"
	else
		PKG=""; PKG_EXT=""
	fi
}

detect_env() {
	DISTRIB_ID=""; DISTRIB_RELEASE=""; DISTRIB_ARCH=""; DISTRIB_TARGET=""
	[ -f /etc/openwrt_release ] && . /etc/openwrt_release

	BOARD=""
	if [ -f /tmp/sysinfo/model ]; then
		BOARD=$(cat /tmp/sysinfo/model 2>/dev/null)
	fi
	if [ -z "$BOARD" ] && [ -f /tmp/sysinfo/board_name ]; then
		BOARD=$(cat /tmp/sysinfo/board_name 2>/dev/null)
	fi

	HOSTNAME_=$(uci -q get system.@system[0].hostname 2>/dev/null)
	[ -n "$HOSTNAME_" ] || HOSTNAME_=$(hostname 2>/dev/null)

	detect_pkg

	MEM_KB=$(mem_kb); MEM_KB=${MEM_KB:-0}
	OVERLAY_KB=$(free_kb /overlay); OVERLAY_KB=${OVERLAY_KB:-0}
	if [ "$OVERLAY_KB" -le 0 ] 2>/dev/null; then
		OVERLAY_KB=$(free_kb /); OVERLAY_KB=${OVERLAY_KB:-0}
	fi
	TMP_KB=$(free_kb /tmp); TMP_KB=${TMP_KB:-0}
	ROOT_KB=$(free_kb /); ROOT_KB=${ROOT_KB:-0}
}

pick_work() {
	if [ "$TMP_KB" -ge 20480 ]; then
		WORK="/tmp/sk-install-$$"
	else
		WORK="/root/sk-install-$$"
	fi
	rm -rf "$WORK" 2>/dev/null
	mkdir -p "$WORK" || die "не удалось создать рабочий каталог $WORK"
}

print_banner() {
	blank
	printf '%s\n' "${C_GREEN}  $APP $VER${C_RESET}"
	printf '%s\n' "${C_GRAY}  podkop + sing-box-extended + shoulderkop — всё за один проход${C_RESET}"
	blank
	printf '  %s %s\n' "${C_GRAY}Модель:${C_RESET}" "${BOARD:-неизвестно}"
	printf '  %s %s\n' "${C_GRAY}Хост:${C_RESET}" "${HOSTNAME_:-?}"
	printf '  %s %s\n' "${C_GRAY}Система:${C_RESET}" "OpenWrt ${DISTRIB_RELEASE:-?} (${DISTRIB_TARGET:-?})"
	printf '  %s %s\n' "${C_GRAY}Железо:${C_RESET}" "${DISTRIB_ARCH:-?} · $(mb "$MEM_KB") МБ ОЗУ"
	printf '  %s %s\n' "${C_GRAY}Место:${C_RESET}" "/overlay — $(mb "$OVERLAY_KB") МБ свободно"
	printf '  %s %s\n' "${C_GRAY}Пакеты:${C_RESET}" "${PKG:-не найдены}"
	blank
	if [ "$INTERACTIVE" -eq 1 ]; then
		printf '  %s\n' "${C_GRAY}Почти всё сделаю сам. Спрошу только:${C_RESET}"
		if [ "$DO_SINGBOX" -eq 1 ]; then
			printf '  %s\n' "${C_GRAY}  • ставить ли sing-box-extended — он нужен для xhttp;${C_RESET}"
		fi
		printf '  %s\n' "${C_GRAY}  • ссылку на подписку — её можно пропустить.${C_RESET}"
	else
		printf '  %s\n' "${C_GRAY}Вопросов не будет: недостающее поставлю сам.${C_RESET}"
	fi
}

# ---------- проверки ----------

preflight() {
	step "Шаг 1/6 · Проверяю окружение"

	[ "$(id -u)" = "0" ] || die "нужны права root — запустите установщик из-под root"
	ok "права root"

	[ -f /etc/openwrt_release ] || die "это не OpenWrt: нет /etc/openwrt_release"
	case "$DISTRIB_RELEASE" in
		""|SNAPSHOT|snapshot)
			ok "OpenWrt ${DISTRIB_RELEASE:-SNAPSHOT}"
			;;
		*)
			if ver_ge "$DISTRIB_RELEASE" "24.10"; then
				ok "OpenWrt $DISTRIB_RELEASE (24.10+)"
			else
				die "нужен OpenWrt 24.10 или новее: podkop $PODKOP_MIN не поддерживает 23.05 (тут $DISTRIB_RELEASE)"
			fi
			;;
	esac

	case "$PKG" in
		apk) ok "менеджер пакетов: apk" ;;
		opkg) ok "менеджер пакетов: opkg" ;;
		*) die "не найден ни apk, ни opkg" ;;
	esac

	DLTOOL=""
	if have curl; then
		DLTOOL="curl"
	elif have wget; then
		DLTOOL="wget"
	elif have uclient-fetch; then
		DLTOOL="uclient-fetch"
	else
		die "нет curl, wget или uclient-fetch — нечем скачивать пакеты"
	fi
	ok "чем качать: $DLTOOL"

	have uci || die "нет uci — это точно OpenWrt?"

	# время раньше сети: со сбитыми часами HTTPS падает ещё до скачивания
	if [ "$DRY" -eq 0 ] && have ntpd; then
		# по IP, а не по имени: DNS может быть сломан именно из-за старых часов
		timeout_run 20 ntpd -q -p 216.239.35.0 -p 194.190.168.1 >/dev/null 2>&1
	fi
	_year=$(date +%Y 2>/dev/null)
	if [ -n "$_year" ] && [ "$_year" -ge 2024 ] 2>/dev/null; then
		ok "время в порядке ($_year)"
	else
		warn "часы сбиты — HTTPS может не работать, проверьте время"
	fi

	if [ -n "$LOCAL_DIR" ]; then
		[ -d "$LOCAL_DIR" ] || die "нет каталога $LOCAL_DIR"
		ok "пакеты shoulderkop: локальный каталог"
	else
		_zen=$(fetch "https://api.github.com/zen" | head -n 1)
		if [ -n "$_zen" ]; then
			ok "сеть и DNS в порядке"
		elif fetch "https://github.com" >/dev/null 2>&1; then
			warn "api.github.com недоступен, но github.com отвечает"
		else
			die "нет доступа к github.com — проверьте интернет и DNS"
		fi
	fi

	if [ "$OVERLAY_KB" -lt 15360 ]; then
		die "мало места в /overlay: podkop требует минимум 15 МБ, свободно $(mb "$OVERLAY_KB") МБ"
	fi
	if [ "$OVERLAY_KB" -lt 25600 ]; then
		warn "в /overlay $(mb "$OVERLAY_KB") МБ — впритык, а подписка и кэш любят место"
	else
		ok "места в /overlay: $(mb "$OVERLAY_KB") МБ"
	fi

	if [ "$TMP_KB" -lt 10240 ]; then
		warn "в /tmp всего $(mb "$TMP_KB") МБ — для больших пакетов может не хватить"
	fi
}

collect_answers() {
	if [ "$DO_SINGBOX" -eq 0 ]; then
		WANT_EXTENDED=0
	else
		_cur=$(singbox_version)
		if [ -n "$_cur" ] && singbox_extended "$_cur" && ver_ge "$_cur" "$SBE_MIN" && [ "$FORCE" -eq 0 ]; then
			WANT_EXTENDED=1
		elif [ "$INTERACTIVE" -eq 1 ]; then
			blank
			hint "sing-box-extended нужен для xhttp-узлов."
			hint "Без него shoulderkop просто выкинет такие узлы — туннель будет работать."
			if ask_yn "Поставить sing-box-extended?" y; then
				WANT_EXTENDED=1
			else
				WANT_EXTENDED=0
			fi
		else
			WANT_EXTENDED=1
		fi
	fi

	if [ -n "$URL" ]; then
		ok "ссылка на подписку: из --url"
		return 0
	fi
	if sub_url_set; then
		ok "подписка уже задана — обновлю её"
		return 0
	fi
	if [ "$INTERACTIVE" -eq 1 ]; then
		ask_url
	fi
}

# ---------- пакеты ----------

pkg_installed() {
	case "$PKG" in
		apk)
			apk info -e "$1" >/dev/null 2>&1 && return 0
			apk list --installed 2>/dev/null | grep -q "^$1-[0-9]"
			;;
		opkg) opkg status "$1" 2>/dev/null | grep -q '^Package:' ;;
		*) return 1 ;;
	esac
}

pkg_update() {
	case "$PKG" in
		apk) apk update >>"$LOG" 2>&1 ;;
		opkg) opkg update >>"$LOG" 2>&1 ;;
	esac
}

pkg_install_name() {
	case "$PKG" in
		apk) apk add "$1" >>"$LOG" 2>&1 ;;
		opkg) opkg install "$1" >>"$LOG" 2>&1 ;;
		*) return 1 ;;
	esac
}

pkg_remove() {
	case "$PKG" in
		apk) apk del "$1" >>"$LOG" 2>&1 ;;
		opkg) opkg remove --force-depends "$1" >>"$LOG" 2>&1 ;;
		*) return 1 ;;
	esac
}

pkg_install_file() {
	case "$PKG" in
		apk)
			_pif="$1"
			case "$_pif" in
				*.apk) ;;
				*)
					rm -f "$_pif.apk" 2>/dev/null
					ln "$_pif" "$_pif.apk" 2>/dev/null \
						|| cp -f "$_pif" "$_pif.apk" 2>/dev/null \
						|| return 1
					_pif="$_pif.apk"
					;;
			esac
			for _pif_try in 1 2; do
				apk add --allow-untrusted "$_pif" >>"$LOG" 2>&1 && return 0
				if [ "$_pif_try" = 1 ]; then
					warn "apk не смог — обновляю индексы и пробую ещё раз"
					pkg_update
					sleep 1
				fi
			done
			return 1
			;;
		opkg)
			opkg install --force-reinstall "$1" >>"$LOG" 2>&1 && return 0
			warn "opkg не разрешил зависимости — пробую с --force-depends"
			opkg install --force-reinstall --force-depends "$1" >>"$LOG" 2>&1
			;;
		*) return 1 ;;
	esac
}

# ---------- конфликты podkop ----------

check_podkop_conflicts() {
	for _pc in nextdns luci-app-nextdns getdomains luci-app-getdomains \
		passwall passwall2 luci-app-passwall luci-app-passwall2; do
		if pkg_installed "$_pc"; then
			die "podkop несовместим с $_pc — удалите его вручную и запустите установщик снова"
		fi
	done
}

remove_https_dns_proxy() {
	REMOVED_DNS=0
	_found=""
	pkg_installed https-dns-proxy && _found="$_found https-dns-proxy"
	pkg_installed luci-app-https-dns-proxy && _found="$_found luci-app-https-dns-proxy"
	[ -n "$_found" ] || return 0

	warn "https-dns-proxy конфликтует с podkop — удаляю"
	if [ "$DRY" -eq 1 ]; then
		ok "dry-run: удалил бы$_found"
		return 0
	fi
	if [ -f /etc/config/https-dns-proxy ]; then
		mkdir -p /root/shoulderkop-backup 2>/dev/null
		cp -f /etc/config/https-dns-proxy /root/shoulderkop-backup/https-dns-proxy.config 2>/dev/null \
			&& info "конфиг сохранён: /root/shoulderkop-backup/https-dns-proxy.config"
	fi
	for _dp in $_found; do
		pkg_remove "$_dp" || warn "не удалось удалить $_dp"
	done
	if pkg_installed https-dns-proxy || pkg_installed luci-app-https-dns-proxy; then
		die "https-dns-proxy не удалился — без этого podkop не установится"
	fi
	REMOVED_DNS=1
	ok "https-dns-proxy удалён"
}

# ---------- шаг 2: podkop ----------

step_podkop() {
	step "Шаг 2/6 · podkop"
	if [ "$DO_PODKOP" -eq 0 ]; then
		warn "пропущен (--no-podkop)"
		return 0
	fi

	check_podkop_conflicts
	remove_https_dns_proxy

	_pv=$(podkop_version)

	info "ищу последний релиз podkop"
	_tag=$(latest_tag "$PODKOP_REPO")
	_latest=$(printf '%s' "$_tag" | sed 's/^v//')

	# повторный запуск: сообщаем, что уже стоит, и спрашиваем про обновление
	if [ -n "$_pv" ] && [ "$FORCE" -eq 0 ]; then
		if [ -n "$_latest" ] && ver_ge "$_pv" "$_latest"; then
			ok "podkop $_pv уже установлен — это последняя версия"
			return 0
		fi
		if [ -n "$_latest" ]; then
			info "установлен podkop $_pv, в релизе $_latest"
			ask_yn "Обновить podkop $_pv → $_latest?" "y" \
				|| { info "оставляю podkop $_pv"; return 0; }
		elif ver_ge "$_pv" "$PODKOP_MIN"; then
			warn "проверить обновления podkop не удалось (GitHub недоступен) — оставляю $_pv"
			return 0
		fi
	elif [ -n "$_pv" ]; then
		warn "переустанавливаю podkop $_pv по --force"
	else
		info "podkop не найден — ставлю"
	fi

	if [ "$PKG" = "opkg" ] && ! have sing-box; then
		info "opkg: сначала sing-box из репозитория (зависимость podkop)"
		if [ "$DRY" -eq 0 ]; then
			pkg_update
			if pkg_install_name sing-box; then
				ok "sing-box из репозитория установлен"
			else
				warn "sing-box из репозитория не встал — podkop поставлю с --force-depends"
			fi
		fi
	fi

	if [ -f /etc/config/podkop ] && [ ! -f /etc/config/podkop.bak ]; then
		cp -f /etc/config/podkop /etc/config/podkop.bak 2>/dev/null \
			&& info "конфиг podkop сохранён в /etc/config/podkop.bak"
	fi

	[ -n "$_tag" ] || die "не удалось узнать версию podkop: GitHub недоступен или исчерпан лимит API"
	ok "релиз podkop: $_tag"

	_urls=$(release_assets "$PODKOP_REPO" "$_tag" | grep -E "\.${PKG_EXT}\$")
	if [ -z "$_urls" ]; then
		# свежий релиз может быть только под apk — на 24.10 ищем тег с ipk
		info "в $_tag нет .${PKG_EXT} — ищу ближайший релиз с этим форматом"
		_all=$(fetch "https://api.github.com/repos/$PODKOP_REPO/releases?per_page=30")
		_tag_alt=$(printf '%s' "$_all" \
			| grep -o "https://[^\"]*/releases/download/[^\"]*\.${PKG_EXT}" \
			| sed 's|.*/releases/download/||; s|/.*||' \
			| head -n 1)
		if [ -n "$_tag_alt" ]; then
			_tag="$_tag_alt"
			_urls=$(printf '%s' "$_all" \
				| grep -o "https://[^\"]*/releases/download/$_tag/[^\"]*" \
				| sort -u \
				| grep -E "\.${PKG_EXT}\$")
			ok "релиз podkop: $_tag"
		fi
	fi
	[ -n "$_urls" ] || die "в релизе $_tag нет файлов .${PKG_EXT}"
	_u_main=$(pick_asset "$_urls" podkop)
	_u_luci=$(pick_asset "$_urls" luci-app-podkop)
	_u_i18n=$(pick_asset "$_urls" luci-i18n-podkop-ru)
	[ -n "$_u_main" ] || die "в релизе $_tag нет пакета podkop"
	[ -n "$_u_luci" ] || warn "в релизе $_tag нет luci-app-podkop"

	if [ "$DRY" -eq 1 ]; then
		ok "dry-run: поставил бы $(basename "$_u_main")"
		return 0
	fi

	info "качаю podkop"
	dl "$_u_main" "$WORK/podkop.$PKG_EXT" || die "podkop не скачался"
	ok "$(basename "$_u_main")"
	if [ -n "$_u_luci" ]; then
		dl "$_u_luci" "$WORK/luci-app-podkop.$PKG_EXT" \
			|| warn "luci-app-podkop не скачался — интерфейс будет неполным"
	fi

	info "устанавливаю podkop"
	pkg_update
	pkg_install_file "$WORK/podkop.$PKG_EXT" || die "podkop не установился"
	_pv=$(podkop_version)
	[ -n "$_pv" ] || die "podkop установился, но не отвечает на show_version"
	ok "podkop $_pv установлен"

	if [ -f "$WORK/luci-app-podkop.$PKG_EXT" ]; then
		if pkg_install_file "$WORK/luci-app-podkop.$PKG_EXT"; then
			ok "luci-app-podkop установлен"
		else
			warn "luci-app-podkop не установился — веб-интерфейс будет неполным"
		fi
	fi

	_ru_ok=0
	if [ -n "$_u_i18n" ] \
		&& dl "$_u_i18n" "$WORK/podkop-ru.$PKG_EXT" \
		&& pkg_install_file "$WORK/podkop-ru.$PKG_EXT"; then
		_ru_ok=1
	fi
	if [ "$_ru_ok" -eq 0 ] && pkg_install_name luci-i18n-podkop-ru; then
		_ru_ok=1
	fi
	if [ "$_ru_ok" -eq 1 ]; then
		ok "русский перевод podkop установлен"
	else
		warn "русский перевод podkop не установился (не критично)"
	fi
}

# ---------- шаг 3: sing-box-extended ----------

sbe_tar_arch() {
	case "$DISTRIB_ARCH" in
		x86_64) printf 'amd64\n' ;;
		i386_*) printf '386\n' ;;
		aarch64_*) printf 'arm64\n' ;;
		arm_cortex-a5*|arm_arm1176*) printf 'armv6\n' ;;
		arm_*) printf 'armv7\n' ;;
		mipsel_24kc|mipsel_74kc) printf 'mipsle-softfloat\n' ;;
		mipsel_*) printf 'mipsle\n' ;;
		mips_24kc) printf 'mips-softfloat\n' ;;
		mips_*) printf 'mips\n' ;;
		mips64el_*|mips64le_*) printf 'mips64le\n' ;;
		mips64_octeonplus|mips64_*) printf 'mips64\n' ;;
		riscv64_*) printf 'riscv64\n' ;;
		*) printf '\n' ;;
	esac
}

engine_backup() {
	ENGINE_BACKUP="$WORK/sing-box.orig"
	CORE_BACKUP="$WORK/sing-box-core.orig"
	ENGINE_EXISTED=0
	CORE_EXISTED=0
	ENGINE_DIRTY=1

	if [ -f /usr/bin/sing-box ]; then
		if ! cp -f /usr/bin/sing-box "$ENGINE_BACKUP" 2>/dev/null; then
			ENGINE_DIRTY=0
			return 1
		fi
		ENGINE_EXISTED=1
	fi
	if [ -f /usr/libexec/sing-box-core.gz ]; then
		if ! cp -f /usr/libexec/sing-box-core.gz "$CORE_BACKUP" 2>/dev/null; then
			ENGINE_DIRTY=0
			return 1
		fi
		CORE_EXISTED=1
	fi
	return 0
}

engine_restore() {
	if [ "$ENGINE_EXISTED" = 1 ] && [ -f "$ENGINE_BACKUP" ]; then
		if cp -f "$ENGINE_BACKUP" /usr/bin/sing-box 2>/dev/null; then
			chmod +x /usr/bin/sing-box 2>/dev/null
		else
			warn "не удалось вернуть прежний /usr/bin/sing-box"
		fi
	else
		rm -f /usr/bin/sing-box 2>/dev/null
	fi

	if [ "$CORE_EXISTED" = 1 ] && [ -f "$CORE_BACKUP" ]; then
		mkdir -p /usr/libexec 2>/dev/null
		cp -f "$CORE_BACKUP" /usr/libexec/sing-box-core.gz 2>/dev/null
	else
		rm -f /usr/libexec/sing-box-core.gz 2>/dev/null
	fi

	rm -f /tmp/sing-box-core 2>/dev/null
	rm -f "$ENGINE_BACKUP" "$CORE_BACKUP" 2>/dev/null
	ENGINE_BACKUP=""
	CORE_BACKUP=""
	ENGINE_DIRTY=0
}

engine_commit() {
	rm -f "$ENGINE_BACKUP" "$CORE_BACKUP" 2>/dev/null
	ENGINE_BACKUP=""
	CORE_BACKUP=""
	ENGINE_DIRTY=0
}

stop_tunnel() {
	info "останавливаю туннель на время замены"
	if [ -x /etc/init.d/podkop ]; then
		STOPPED=1
		/etc/init.d/podkop stop >/dev/null 2>&1
	elif [ -x /etc/init.d/sing-box ]; then
		STOPPED=1
		/etc/init.d/sing-box stop >/dev/null 2>&1
	fi
	if [ -x /etc/init.d/zeroblock ]; then
		ZB_STOPPED=1
		/etc/init.d/zeroblock stop >/dev/null 2>&1
	fi
	if have killall; then
		killall sing-box >/dev/null 2>&1
		killall sing-box-core >/dev/null 2>&1
	fi
	sleep 1
}

start_tunnel() {
	# подписка истекла — shoulderkop уже погасил туннель и снял автозапуск
	if [ "$SUB_PAUSED" = 1 ]; then
		STOPPED=0
		return 0
	fi
	if [ "$STOPPED" = 1 ]; then
		if [ -x /etc/init.d/podkop ]; then
			/etc/init.d/podkop start >/dev/null 2>&1
		elif [ -x /etc/init.d/sing-box ]; then
			/etc/init.d/sing-box start >/dev/null 2>&1
		fi
		STOPPED=0
	fi
	if [ "$ZB_STOPPED" = 1 ]; then
		/etc/init.d/zeroblock start >/dev/null 2>&1
		ZB_STOPPED=0
	fi
}

install_tar() {
	_it_file="$1"
	_it_dir="$WORK/sbe-x"
	rm -rf "$_it_dir" 2>/dev/null
	mkdir -p "$_it_dir" || { err "не удалось создать $_it_dir"; return 1; }
	[ -s "$_it_file" ] || { err "пустой архив sing-box"; return 1; }
	tar -xzf "$_it_file" -C "$_it_dir" >>"$LOG" 2>&1 \
		|| { err "архив sing-box не распаковался"; return 1; }

	_it_bin=$(find "$_it_dir" -type f -name 'sing-box' ! -name '*.gz' | head -n 1)
	[ -n "$_it_bin" ] || _it_bin=$(find "$_it_dir" -type f -name 'sing-box.gz' | head -n 1)
	if [ -z "$_it_bin" ]; then
		err "в архиве нет файла sing-box"
		return 1
	fi

	if have gzip && gzip -t "$_it_bin" >/dev/null 2>&1; then
		_core_kb=$(gzip -l "$_it_bin" 2>/dev/null | awk 'NR == 2 {print int($2 / 1024)}')
		_core_kb=${_core_kb:-0}
		_tmp_free=$(free_kb /tmp); _tmp_free=${_tmp_free:-0}
		if [ "$_core_kb" -gt 0 ] && [ "$_tmp_free" -lt "$((_core_kb + 4096))" ]; then
			err "в /tmp $(mb "$_tmp_free") МБ, для распаковки ядра нужно $(mb "$_core_kb") МБ"
			return 1
		fi
		mkdir -p /usr/libexec 2>/dev/null
		if ! cp -f "$_it_bin" /usr/libexec/sing-box-core.gz.new 2>/dev/null; then
			err "не удалось записать /usr/libexec/sing-box-core.gz"
			return 1
		fi
		mv -f /usr/libexec/sing-box-core.gz.new /usr/libexec/sing-box-core.gz 2>/dev/null \
			|| { err "не удалось заменить /usr/libexec/sing-box-core.gz"; return 1; }

		cat > /usr/bin/sing-box.new <<'WRAP'
#!/bin/sh
CORE=/usr/libexec/sing-box-core.gz
RUN=/tmp/sing-box-core
if [ ! -x "$RUN" ]; then
	TMP="$RUN.$$"
	if ! gzip -dc "$CORE" > "$TMP"; then
		rm -f "$TMP"
		exit 1
	fi
	if ! chmod +x "$TMP"; then
		rm -f "$TMP"
		exit 1
	fi
	mv -f "$TMP" "$RUN" || { rm -f "$TMP"; exit 1; }
fi
exec "$RUN" "$@"
WRAP
		chmod +x /usr/bin/sing-box.new || { err "не удалось сделать обёртку исполняемой"; return 1; }
		mv -f /usr/bin/sing-box.new /usr/bin/sing-box 2>/dev/null \
			|| { err "не удалось заменить /usr/bin/sing-box"; return 1; }
		rm -f /tmp/sing-box-core 2>/dev/null
		info "ядро сжато: /usr/libexec/sing-box-core.gz + обёртка"
	else
		chmod +x "$_it_bin" 2>/dev/null
		if ! timeout_run 10 "$_it_bin" version >/dev/null 2>&1; then
			err "ядро не запускается на этой архитектуре"
			return 1
		fi
		cp -f "$_it_bin" /usr/bin/sing-box.new 2>/dev/null \
			|| { err "не удалось записать /usr/bin/sing-box"; return 1; }
		chmod +x /usr/bin/sing-box.new 2>/dev/null \
			|| { err "не удалось сделать ядро исполняемым"; return 1; }
		mv -f /usr/bin/sing-box.new /usr/bin/sing-box 2>/dev/null \
			|| { err "не удалось заменить /usr/bin/sing-box"; return 1; }
		rm -f /usr/libexec/sing-box-core.gz 2>/dev/null
		info "ядро установлено в /usr/bin/sing-box"
	fi
	return 0
}

step_singbox() {
	step "Шаг 3/6 · sing-box-extended"
	if [ "$DO_SINGBOX" -eq 0 ]; then
		warn "пропущен (--no-singbox): xhttp-узлы будут выкинуты из подписки"
		return 0
	fi

	_sv=$(singbox_version)
	if [ -n "$_sv" ] && singbox_extended "$_sv" && ver_ge "$_sv" "$SBE_MIN" && [ "$FORCE" -eq 0 ]; then
		ok "sing-box $_sv уже extended"
		return 0
	fi

	if [ "$WANT_EXTENDED" -eq 0 ]; then
		if [ -n "$_sv" ]; then
			if singbox_extended "$_sv"; then
				warn "оставляю sing-box $_sv: обновление extended пропущено"
			else
				warn "оставляю штатный sing-box $_sv: xhttp-узлы будут выкинуты"
			fi
			if ! ver_ge "$_sv" "1.12.4"; then
				warn "podkop требует sing-box >= 1.12.4, а сейчас $_sv"
			fi
		else
			warn "sing-box-extended пропущен: xhttp-узлы будут выкинуты"
		fi
		return 0
	fi

	if [ -z "$_sv" ]; then
		info "sing-box не найден — поставлю extended"
	elif singbox_extended "$_sv"; then
		info "обновляю sing-box $_sv"
	else
		info "сейчас стоит обычный sing-box $_sv — заменю на extended"
	fi

	info "ищу последнюю сборку sing-box-extended"
	_tag="$SBE_PIN"
	_latest=$(latest_tag "$SBE_REPO")
	if [ -n "$_latest" ] && ver_ge "${_latest#v}" "$SBE_MIN"; then
		_tag="$_latest"
	fi
	ok "релиз: $_tag"

	_assets=$(release_assets "$SBE_REPO" "$_tag")
	if [ -z "$_assets" ]; then
		warn "не удалось получить список файлов релиза $_tag"
		return 0
	fi

	_tar_arch=$(sbe_tar_arch)
	if [ -z "$_tar_arch" ]; then
		warn "для архитектуры $DISTRIB_ARCH нет сборки sing-box"
		return 0
	fi

	_a_apk=""
	if [ "$PKG" = "apk" ]; then
		_a_apk=$(printf '%s\n' "$_assets" \
			| grep -E '\.apk$' \
			| grep -v 'SFA-' \
			| grep -v 'android' \
			| grep -F "$DISTRIB_ARCH" \
			| head -n 1)
	fi

	_a_cmp=$(printf '%s\n' "$_assets" \
		| grep -E "/sing-box-.*-linux-${_tar_arch}-musl-compressed\.tar\.gz$" \
		| head -n 1)
	[ -n "$_a_cmp" ] || _a_cmp=$(printf '%s\n' "$_assets" \
		| grep -E "/sing-box-.*-linux-${_tar_arch}-compressed\.tar\.gz$" \
		| head -n 1)
	_a_tar=$(printf '%s\n' "$_assets" \
		| grep -E "/sing-box-.*-linux-${_tar_arch}-musl\.tar\.gz$" \
		| head -n 1)
	[ -n "$_a_tar" ] || _a_tar=$(printf '%s\n' "$_assets" \
		| grep -E "/sing-box-.*-linux-${_tar_arch}\.tar\.gz$" \
		| head -n 1)

	_choice=""
	if [ -n "$SB_FORMAT" ]; then
		case "$SB_FORMAT" in
			apk)
				[ "$PKG" = "apk" ] || die "--singbox-format=apk не подходит для opkg"
				[ -n "$_a_apk" ] || die "--singbox-format=apk: в релизе нет apk для $DISTRIB_ARCH"
				;;
			compressed)
				[ -n "$_a_cmp" ] || die "--singbox-format=compressed: в релизе нет файла для $DISTRIB_ARCH"
				;;
			plain)
				[ -n "$_a_tar" ] || die "--singbox-format=plain: в релизе нет файла для $DISTRIB_ARCH"
				;;
		esac
		_choice="$SB_FORMAT"
	elif [ -n "$_a_apk" ] && [ "$OVERLAY_KB" -ge 102400 ]; then
		_choice="apk"
	elif [ -n "$_a_tar" ] && [ "$OVERLAY_KB" -ge 112640 ] && [ "$TMP_KB" -ge 174080 ]; then
		_choice="plain"
	elif [ -n "$_a_cmp" ] && [ "$OVERLAY_KB" -ge 30720 ] && [ "$TMP_KB" -ge 102400 ]; then
		_choice="compressed"
	fi

	if [ -z "$_choice" ]; then
		warn "для $DISTRIB_ARCH нет подходящей сборки или мало места"
		hint "оставляю штатный sing-box: xhttp-узлы будут выкинуты"
		return 0
	fi

	case "$_choice" in
		apk) _url="$_a_apk"; _kind="apk"; _need=51200 ;;
		compressed) _url="$_a_cmp"; _kind="compressed"; _need=92160 ;;
		plain) _url="$_a_tar"; _kind="plain"; _need=163840 ;;
	esac
	[ -n "$_url" ] || { warn "не выбран файл sing-box"; return 0; }

	case "$_kind" in
		apk)
			have apk || die "нет apk"
			[ "$OVERLAY_KB" -ge 51200 ] \
				|| die "для apk-пакета нужно ~50 МБ в /overlay, свободно $(mb "$OVERLAY_KB") МБ"
			;;
		compressed)
			have gzip || die "нет gzip — не смогу распаковать ядро"
			have tar || die "нет tar — не смогу распаковать архив"
			[ "$OVERLAY_KB" -ge 25600 ] \
				|| die "для сжатого ядра нужно ~25 МБ в /overlay, свободно $(mb "$OVERLAY_KB") МБ"
			;;
		plain)
			have tar || die "нет tar — не смогу распаковать архив"
			[ "$OVERLAY_KB" -ge 92160 ] \
				|| die "для обычного ядра нужно ~90 МБ в /overlay, свободно $(mb "$OVERLAY_KB") МБ"
			;;
	esac

	_wfree=$(free_kb "$WORK"); _wfree=${_wfree:-0}
	if [ "$_wfree" -lt "$_need" ]; then
		warn "в $(dirname "$WORK") $(mb "$_wfree") МБ, для загрузки нужно ~$(mb "$_need") МБ"
		hint "оставляю штатный sing-box: xhttp-узлы будут выкинуты"
		return 0
	fi

	if [ "$DRY" -eq 1 ]; then
		ok "dry-run: поставил бы $(basename "$_url") ($_choice)"
		return 0
	fi

	case "$_kind" in
		apk) _file="$WORK/sbe-dl.apk" ;;
		*) _file="$WORK/sbe-dl.tar.gz" ;;
	esac
	info "качаю $(basename "$_url")"
	dl "$_url" "$_file" || { warn "sing-box не скачался"; return 0; }
	ok "скачано: $(($(wc -c <"$_file") / 1024)) КБ"

	stop_tunnel
	if ! engine_backup; then
		warn "не удалось сохранить текущий sing-box — не рискую заменять"
		start_tunnel
		return 0
	fi

	if [ "$_kind" = "apk" ]; then
		pkg_install_file "$_file" || warn "apk вернул ошибку — проверяю бинарник"
	elif ! install_tar "$_file"; then
		warn "ядро не установилось — проверяю, что осталось"
	fi

	_nv=$(singbox_version)
	if [ -n "$_nv" ] && singbox_extended "$_nv"; then
		engine_commit
		ok "sing-box $_nv установлен"
		if ! ver_ge "$_nv" "$SBE_MIN"; then
			warn "версия ниже рекомендуемой $SBE_MIN"
		fi
	else
		warn "новая сборка не заработала — возвращаю прежнее состояние"
		engine_restore
		_nv=$(singbox_version)
		if [ -n "$_nv" ]; then
			info "вернул sing-box $_nv"
		fi
	fi

	rm -f "$_file" 2>/dev/null
	start_tunnel
}

# ---------- шаг 4: shoulderkop ----------

step_shoulderkop() {
	step "Шаг 4/6 · shoulderkop"
	if [ "$DO_SK" -eq 0 ]; then
		warn "пропущен (--no-shoulderkop)"
		return 0
	fi

	_m=""
	_l=""
	if [ -n "$LOCAL_DIR" ]; then
		_m=$(ls -1t "$LOCAL_DIR"/shoulderkop[-_]*."$PKG_EXT" 2>/dev/null | head -n 1)
		_l=$(ls -1t "$LOCAL_DIR"/luci-app-shoulderkop[-_]*."$PKG_EXT" 2>/dev/null | head -n 1)
		[ -n "$_m" ] || die "в $LOCAL_DIR нет shoulderkop*.${PKG_EXT}"
		ok "пакеты: локальный каталог"
	elif [ -n "$BASE_URL" ]; then
		info "смотрю каталог $BASE_URL"
		_names=$(fetch "$BASE_URL/" | grep -oE '[A-Za-z0-9._+-]*\.(apk|ipk)' | sort -u)
		[ -n "$_names" ] || die "в $BASE_URL нет .apk/.ipk (нужен листинг каталога)"
		_bm=$(printf '%s\n' "$_names" | grep -E "^shoulderkop[-_][^/]*\.${PKG_EXT}$" | head -n 1)
		_bl=$(printf '%s\n' "$_names" | grep -E "^luci-app-shoulderkop[-_][^/]*\.${PKG_EXT}$" | head -n 1)
		[ -n "$_bm" ] || die "в $BASE_URL нет shoulderkop*.${PKG_EXT}"
		_m="$BASE_URL/$_bm"
		[ -n "$_bl" ] && _l="$BASE_URL/$_bl"
		ok "пакеты: $BASE_URL"
	else
		info "ищу последний релиз shoulderkop"
		_tag=$(latest_tag "$SK_REPO")
		if [ -z "$_tag" ]; then
			if pkg_installed shoulderkop; then
				warn "не удалось проверить обновления shoulderkop — оставляю установленный"
				return 0
			fi
			die "не удалось найти релиз $SK_REPO — укажите --local=DIR или --base-url=URL"
		fi
		ok "релиз: $_tag"

		# повторный запуск: сравниваем установленную версию с релизом и спрашиваем
		_cur=$(sk_version)
		_latest=$(printf '%s' "$_tag" | sed 's/^v//')
		if [ -n "$_cur" ] && [ -n "$_latest" ] && [ "$FORCE" -eq 0 ]; then
			if [ -n "$_latest" ] && ver_ge "$_cur" "$_latest"; then
				ok "shoulderkop $_cur уже установлен — это последняя версия"
				return 0
			fi
			info "установлен shoulderkop $_cur, в релизе $_latest"
			ask_yn "Обновить shoulderkop $_cur → $_latest?" "y" \
				|| { info "оставляю shoulderkop $_cur"; return 0; }
		elif [ -n "$_cur" ]; then
			warn "переустанавливаю shoulderkop $_cur по --force"
		fi

		_urls=$(release_assets "$SK_REPO" "$_tag" | grep -E "\.${PKG_EXT}\$")
		[ -n "$_urls" ] || die "в релизе $_tag нет .${PKG_EXT}"
		_m=$(pick_asset "$_urls" shoulderkop)
		_l=$(pick_asset "$_urls" luci-app-shoulderkop)
		[ -n "$_m" ] || die "в релизе $_tag нет shoulderkop*.${PKG_EXT}"
		[ -n "$_l" ] || warn "в релизе $_tag нет luci-app-shoulderkop"
	fi

	if [ "$DRY" -eq 1 ]; then
		ok "dry-run: поставил бы $(basename "$_m")"
		return 0
	fi

	info "качаю shoulderkop"
	case "$_m" in
		*://*)
			dl "$_m" "$WORK/sk.$PKG_EXT" || die "shoulderkop не скачался"
			_fm="$WORK/sk.$PKG_EXT"
			;;
		*) _fm="$_m" ;;
	esac
	ok "$(basename "$_fm")"

	_fl=""
	if [ -n "$_l" ]; then
		case "$_l" in
			*://*)
				if dl "$_l" "$WORK/sk-luci.$PKG_EXT"; then
					_fl="$WORK/sk-luci.$PKG_EXT"
				else
					warn "luci-app-shoulderkop не скачался"
				fi
				;;
			*) _fl="$_l" ;;
		esac
	fi

	info "устанавливаю shoulderkop"
	if pkg_install_file "$_fm"; then
		ok "shoulderkop установлен"
	else
		if pkg_installed shoulderkop; then
			warn "не удалось обновить shoulderkop — оставляю установленный"
		else
			die "shoulderkop не установился"
		fi
	fi

	if [ -n "$_fl" ] && [ -f "$_fl" ]; then
		if pkg_install_file "$_fl"; then
			ok "luci-app-shoulderkop установлен"
		else
			warn "luci-app-shoulderkop не установился — CLI работает, LuCI может отсутствовать"
		fi
	fi

	[ -x /usr/bin/shoulderkop ] || die "нет /usr/bin/shoulderkop — пакет встал криво"
}

# ---------- шаг 5: настройка ----------

configure() {
	step "Шаг 5/6 · подписка и настройка"
	[ -x /etc/init.d/shoulderkop ] || die "нет /etc/init.d/shoulderkop — пакет встал криво"
	[ -x /usr/bin/shoulderkop ] || die "нет /usr/bin/shoulderkop — пакет встал криво"

	/etc/init.d/shoulderkop enable >/dev/null 2>&1 && ok "shoulderkop в автозапуске"
	if [ -x /etc/init.d/podkop ]; then
		/etc/init.d/podkop enable >/dev/null 2>&1
	fi

	_uci_changed=0
	if [ -n "$MODE" ]; then
		uci -q set "shoulderkop.settings.mode=$MODE" && _uci_changed=1
	fi
	if [ -z "$(uci -q get shoulderkop.settings.mode)" ]; then
		uci -q set "shoulderkop.settings.mode=wifi" && _uci_changed=1
	fi
	if [ -n "$INTERVAL" ]; then
		uci -q set "shoulderkop.settings.update_interval=$INTERVAL" && _uci_changed=1
	fi
	if [ -z "$(uci -q get shoulderkop.settings.update_interval)" ]; then
		uci -q set "shoulderkop.settings.update_interval=1h" && _uci_changed=1
	fi
	if [ -n "$URLTEST" ]; then
		uci -q set "shoulderkop.settings.urltest_interval=$URLTEST" && _uci_changed=1
	fi
	if [ -z "$(uci -q get shoulderkop.settings.urltest_interval)" ]; then
		uci -q set "shoulderkop.settings.urltest_interval=30s" && _uci_changed=1
	fi
	if [ -n "$SCHEDULE" ]; then
		uci -q set "shoulderkop.settings.enable_schedule=$SCHEDULE" && _uci_changed=1
	fi
	if [ -z "$(uci -q get shoulderkop.settings.enable_schedule)" ]; then
		uci -q set "shoulderkop.settings.enable_schedule=1" && _uci_changed=1
	fi
	if [ "$_uci_changed" -eq 1 ]; then
		if uci -q commit shoulderkop; then
			ok "настройки shoulderkop сохранены"
		else
			warn "не удалось сохранить настройки shoulderkop"
		fi
	fi

	_do_upd=0
	if [ -n "$URL" ]; then
		_do_upd=1
	elif sub_url_set; then
		_do_upd=1
		info "подписка уже есть в конфиге — обновляю по ней"
	fi

	if [ "$_do_upd" -eq 1 ]; then
		SUB_TRIED=1
		info "обрабатываю подписку — это может занять до минуты"
		set -- /usr/bin/shoulderkop update
		[ -n "$URL" ] && set -- "$@" "--url=$URL"
		[ -n "$MODE" ] && set -- "$@" "--mode=$MODE"
		[ -n "$INTERVAL" ] && set -- "$@" "--interval=$INTERVAL"
		[ -n "$URLTEST" ] && set -- "$@" "--urltest=$URLTEST"
		[ -n "$SCHEDULE" ] && set -- "$@" "--schedule=$SCHEDULE"
		_out=$("$@" 2>>"$LOG")
		_rc=$?
		printf '%s\n' "$_out" >>"$LOG"
		_count=$(json_num "$_out" count); _count=${_count:-0}
		_status=$(json_str "$_out" status)
		if [ "$_rc" -eq 0 ] && [ "$_status" != "expired" ] && [ "$_count" -eq 0 ]; then
			# панель иногда отдаёт список ссылок вместо JSON — со второго раза проходит
			info "узлов не нашлось — повторяю с --rebuild"
			set -- "$@" --rebuild
			_out=$("$@" 2>>"$LOG")
			_rc=$?
			printf '%s\n' "$_out" >>"$LOG"
			_count=$(json_num "$_out" count); _count=${_count:-0}
			_status=$(json_str "$_out" status)
		fi
		_errs=$(json_arr "$_out" errors)
		if [ "$_rc" -eq 0 ] && [ "$_status" = "expired" ]; then
			SUB_PAUSED=1
			warn "подписка неактивна (истекла) — podkop и sing-box остановлены, автозапуск выключен"
			hint "планировщик продолжит проверять подписку и сам поднимет туннель, когда она станет активной"
		elif [ "$_rc" -ne 0 ]; then
			warn "shoulderkop update завершился с кодом $_rc — смотрите $LOG"
			show_log_tail
		elif [ "$_count" -gt 0 ]; then
			SUB_OK=1
			SUB_COUNT="$_count"
			ok "подписка обработана: $_count узлов"
			if [ -n "$_errs" ]; then
				warn "часть узлов пропущена: $(printf '%s' "$_errs" | cut -c1-160)"
			fi
		else
			warn "подписка не дала узлов — проверьте ссылку и журнал"
			[ -n "$_errs" ] && warn "ошибки: $(printf '%s' "$_errs" | cut -c1-160)"
			show_log_tail
		fi
	else
		hint "подписка не задана — добавьте её в LuCI → Сервисы → ShoulderKop"
	fi

	if /usr/bin/shoulderkop schedule >/dev/null 2>&1; then
		ok "расписание обновления применено"
	else
		warn "не удалось применить расписание"
	fi

	if [ "$SUB_PAUSED" -eq 1 ]; then
		hint "podkop и sing-box оставлены остановленными до активации подписки"
	elif [ -x /etc/init.d/podkop ]; then
		if /etc/init.d/podkop restart >/dev/null 2>&1; then
			ok "podkop перезапущен"
		else
			warn "podkop не перезапустился — проверьте: logread -e podkop"
		fi
	fi

	if [ -x /etc/init.d/rpcd ]; then
		/etc/init.d/rpcd restart >/dev/null 2>&1
	fi
	if [ -x /etc/init.d/uhttpd ]; then
		/etc/init.d/uhttpd reload >/dev/null 2>&1
	fi
	ok "LuCI перечитал конфигурацию"
}

# ---------- шаг 6: проверка ----------

verify() {
	step "Шаг 6/6 · проверяю результат"

	_v=$(singbox_version)
	if [ -n "$_v" ]; then
		if singbox_extended "$_v"; then
			ok "sing-box $_v (extended)"
		else
			warn "sing-box $_v без xhttp"
		fi
	else
		warn "sing-box не отвечает"
	fi

	if [ "$DO_PODKOP" -eq 1 ]; then
		_p=$(podkop_version)
		if [ -n "$_p" ]; then
			ok "podkop $_p"
		else
			warn "podkop не отвечает"
		fi
	fi

	if [ -f /etc/config/shoulderkop ]; then
		ok "режим: $(uci -q get shoulderkop.settings.mode) · urltest: $(uci -q get shoulderkop.settings.urltest_interval)"
	else
		warn "нет /etc/config/shoulderkop"
	fi

	if [ "$DO_PODKOP" -eq 1 ] && [ -f /etc/config/podkop ]; then
		_nsec=$(uci show podkop 2>/dev/null | grep -c '=section')
		if [ "$_nsec" -gt 0 ]; then
			ok "секций в podkop: $_nsec"
		else
			warn "в podkop пока нет секций — они появятся после подписки"
		fi
	fi

	_susp=$(uci -q get shoulderkop.settings.suspended 2>/dev/null)
	if [ "$SUB_PAUSED" -eq 1 ] || [ "$_susp" = "1" ]; then
		warn "подписка неактивна: podkop и sing-box остановлены, автозапуск выключен"
		hint "после продления подписки shoulderkop поднимет туннель сам при следующей проверке"
	elif sub_url_set; then
		if have pgrep && pgrep -f 'sing-box' >/dev/null 2>&1; then
			ok "sing-box запущен"
		else
			warn "sing-box не запущен — проверьте: logread -e podkop"
		fi
	else
		hint "подписка ещё не задана — sing-box стартует после первого обновления"
	fi
}

summary() {
	blank
	printf '%s\n' "${C_GREEN}  Готово!${C_RESET}"
	blank
	printf '  %s %s\n' "${C_GRAY}LuCI:${C_RESET}" "Сервисы → ShoulderKop"
	if [ "$DO_SK" -eq 1 ]; then
		if [ "$SUB_TRIED" -eq 1 ] && [ "$SUB_PAUSED" -eq 1 ]; then
			printf '  %s %s\n' "${C_GRAY}Подписка:${C_RESET}" "истекла — туннель на паузе, проверка по расписанию"
		elif [ "$SUB_TRIED" -eq 1 ] && [ "$SUB_OK" -eq 1 ]; then
			printf '  %s %s\n' "${C_GRAY}Подписка:${C_RESET}" "задана, узлов: ${SUB_COUNT}"
		elif [ "$SUB_TRIED" -eq 1 ]; then
			printf '  %s %s\n' "${C_GRAY}Подписка:${C_RESET}" "задана, но применить не удалось"
		elif sub_url_set; then
			printf '  %s %s\n' "${C_GRAY}Подписка:${C_RESET}" "задана"
		else
			printf '  %s %s\n' "${C_GRAY}Подписка:${C_RESET}" "не задана — добавьте в LuCI"
		fi
	fi
	if [ "$DO_SK" -eq 1 ]; then
		printf '  %s %s\n' "${C_GRAY}Обновить:${C_RESET}" "shoulderkop update"
		printf '  %s %s\n' "${C_GRAY}Статус:${C_RESET}" "shoulderkop status"
	else
		printf '  %s %s\n' "${C_GRAY}ShoulderKop:${C_RESET}" "пропущен (--no-shoulderkop)"
	fi
	printf '  %s %s\n' "${C_GRAY}Журнал:${C_RESET}" "$LOG"
	blank

	if [ "$SUB_PAUSED" -eq 1 ]; then
		hint "Подписка истекла: продлите её — shoulderkop сам поднимет туннель при следующей проверке по расписанию."
	fi
	if [ "$DO_SK" -eq 1 ] && ! sub_url_set; then
		hint "Откройте LuCI → Сервисы → ShoulderKop, вставьте ссылку и нажмите «Обновить подписку»."
	fi
	if [ "$REMOVED_DNS" = 1 ]; then
		hint "https-dns-proxy удалён: он конфликтует с podkop."
	fi
	if [ "$DO_SINGBOX" -eq 1 ]; then
		_v=$(singbox_version)
		if [ -z "$_v" ] || ! singbox_extended "$_v"; then
			hint "xhttp-узлы пропускаются: для них нужен sing-box-extended."
		fi
	fi
}

# ---------- очистка ----------

cleanup() {
	if [ "$ENGINE_DIRTY" = 1 ]; then
		engine_restore
	fi
	if [ -n "$WORK" ] && [ -d "$WORK" ]; then
		rm -rf "$WORK" 2>/dev/null
	fi
	if [ "$STOPPED" = 1 ] && [ "$SUB_PAUSED" -ne 1 ]; then
		if [ -x /etc/init.d/podkop ]; then
			/etc/init.d/podkop start >/dev/null 2>&1
		elif [ -x /etc/init.d/sing-box ]; then
			/etc/init.d/sing-box start >/dev/null 2>&1
		fi
		STOPPED=0
	fi
	if [ "$ZB_STOPPED" = 1 ]; then
		[ -x /etc/init.d/zeroblock ] && /etc/init.d/zeroblock start >/dev/null 2>&1
		ZB_STOPPED=0
	fi
}

die() {
	err "$*"
	show_log_tail
	cleanup
	exit 1
}

trap 'err "прервано"; cleanup; exit 2' INT TERM

# ---------- аргументы ----------

usage() {
	cat <<EOF
$APP $VER — ставит shoulderkop, podkop и sing-box-extended.

Всё необходимое ставится само. Спрашиваем только:
  • ставить ли sing-box-extended (нужен для xhttp-узлов);
  • ссылку на подписку (можно пропустить).

Использование:
  sh shoulderkop-install.sh [опции]

Основное:
  --url=URL              ссылка на подписку — обработать сразу, без вопроса
  -y, --yes              не задавать вопросы (extended ставится, подписка — из --url)
  --dry-run              показать план и выйти, ничего не меняя
  --mode=lte|wifi        режим: lte — обход БС, wifi — домашний интернет (по умолчанию wifi)
  -h, --help             эта справка

Для автоматизации:
  --interval=1h          период обновления подписки
  --urltest=30s          интервал выбора сервера: 30s|1m|2m|3m|5m|10m
  --schedule=0|1         обновлять подписку по расписанию (по умолчанию 1)
  --force                переустановить podkop/sing-box, даже если уже стоят

Для отладки:
  --pkg=apk|opkg         принудительно выбрать менеджер пакетов
  --singbox-format=apk|compressed|plain
  --local=DIR            пакеты shoulderkop из локального каталога
  --base-url=URL         HTTP-каталог с .apk/.ipk
  --repo=OWNER/REPO      репозиторий shoulderkop (по умолчанию BranchSeeker/shoulderkop)
  --mirror=URL           зеркало для скачивания
  --no-podkop            не ставить podkop
  --no-singbox           не ставить sing-box-extended
  --no-shoulderkop       не ставить shoulderkop

Что делает:
  1. проверяет OpenWrt, место, сеть и время;
  2. ставит podkop (и luci-app-podkop), убирая конфликтный https-dns-proxy;
  3. ставит sing-box-extended — если он нужен и есть место;
  4. ставит shoulderkop и luci-app-shoulderkop;
  5. применяет режим, включает расписание и обрабатывает подписку;
  6. показывает версии и состояние.

Коды возврата: 0 — успех, 1 — ошибка, 2 — прервано.
EOF
}

parse_args() {
	while [ $# -gt 0 ]; do
		case "$1" in
			-y|--yes) ASSUME_YES=1 ;;
			--dry-run) DRY=1; ASSUME_YES=1 ;;
			--force) FORCE=1 ;;
			--url=*) URL="${1#*=}" ;;
			--mode=*) MODE="${1#*=}" ;;
			--interval=*) INTERVAL="${1#*=}" ;;
			--urltest=*) URLTEST="${1#*=}" ;;
			--schedule=*) SCHEDULE="${1#*=}" ;;
			--singbox-format=*) SB_FORMAT="${1#*=}" ;;
			--pkg=*) PKG_FORCE="${1#*=}" ;;
			--local=*) LOCAL_DIR="${1#*=}" ;;
			--base-url=*) BASE_URL="${1#*=}" ;;
			--repo=*) SK_REPO="${1#*=}" ;;
			--mirror=*) MIRRORS="${1#*=}" ;;
			--no-podkop) DO_PODKOP=0 ;;
			--no-singbox) DO_SINGBOX=0; WANT_EXTENDED=0 ;;
			--no-shoulderkop) DO_SK=0 ;;
			-h|--help) usage; exit 0 ;;
			*)
				err "неизвестный аргумент: $1"
				blank
				usage
				exit 1
				;;
		esac
		shift
	done

	case "$MODE" in
		''|lte|wifi) ;;
		*) err "неверный --mode=$MODE (lte или wifi)"; exit 1 ;;
	esac
	case "$SCHEDULE" in
		''|0|1) ;;
		*) err "неверный --schedule=$SCHEDULE (0 или 1)"; exit 1 ;;
	esac
	if [ -n "$URLTEST" ]; then
		case "$URLTEST" in
			30s|1m|2m|3m|5m|10m) ;;
			*) err "неверный --urltest=$URLTEST (30s|1m|2m|3m|5m|10m)"; exit 1 ;;
		esac
	fi
	case "$PKG_FORCE" in
		''|apk|opkg) ;;
		*) err "неверный --pkg=$PKG_FORCE (apk или opkg)"; exit 1 ;;
	esac
	case "$SB_FORMAT" in
		''|apk|compressed|plain) ;;
		*) err "неверный --singbox-format=$SB_FORMAT (apk|compressed|plain)"; exit 1 ;;
	esac
	if [ -n "$URL" ]; then
		case "$URL" in
			http://*|https://*) ;;
			*) err "--url должен начинаться с http:// или https://"; exit 1 ;;
		esac
	fi
	if [ -n "$BASE_URL" ]; then
		case "$BASE_URL" in
			http://*|https://*) ;;
			*) err "--base-url должен начинаться с http:// или https://"; exit 1 ;;
		esac
		case "$BASE_URL" in
			*/) BASE_URL="${BASE_URL%/}" ;;
		esac
	fi
	if [ -n "$MIRRORS" ]; then
		case "$MIRRORS" in
			*/) ;;
			*) MIRRORS="$MIRRORS/" ;;
		esac
	fi
}

# ---------- запуск ----------

main() {
	init_colors
	parse_args "$@"
	: >"$LOG" 2>/dev/null

	if [ -t 0 ] && [ -t 1 ] && [ "$ASSUME_YES" -eq 0 ] && [ "$DRY" -eq 0 ]; then
		INTERACTIVE=1
	fi

	detect_env
	pick_work

	print_banner
	preflight
	collect_answers

	step_podkop
	step_singbox
	step_shoulderkop

	if [ "$DRY" -eq 1 ]; then
		warn "dry-run: настройка пропущена"
	else
		if [ "$DO_SK" -eq 1 ]; then
			configure
		else
			warn "настройка shoulderkop пропущена"
		fi
	fi

	verify

	if [ "$DRY" -eq 1 ]; then
		blank
		printf '%s\n' "${C_YELLOW}Это был --dry-run: ничего не изменено.${C_RESET}"
		cleanup
		exit 0
	fi

	summary
	cleanup
	exit 0
}

main "$@"
