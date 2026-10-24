# Сборка и релиз

Два пакета: `shoulderkop` (бэкенд) и `luci-app-shoulderkop` (страница в LuCI). Ставятся
после podkop: своего туннеля shoulderkop не поднимает, только раскладывает серверы по его
секциям.

Требования: **podkop > 0.7.24**; для xhttp-узлов — **sing-box > 1.14.1-extended-2.7.2**.

## Почему podkop не в зависимостях

`DEPENDS` у `shoulderkop` — только `+ucode +ucode-mod-fs +ucode-mod-uci +curl +ca-bundle`.
podkop живёт не в официальных фидах, и жёсткая зависимость ломает сборку и установку
(«missing dependency»). Поэтому podkop — требование времени выполнения, оно описано в
`Package/shoulderkop/description` и в README.

## Сборка (OpenWrt SDK)

SDK под Windows не работает — нужен Linux, WSL или контейнер. Пример для 25.12.6 (apk);
для 24.10.8 (ipk) отличается только версия SDK:

```sh
wget https://downloads.openwrt.org/releases/25.12.6/targets/x86/64/\
openwrt-sdk-25.12.6-x86-64_gcc-14.3.0_musl.Linux-x86_64.tar.zst
mkdir -p sdk && tar --zstd -xf openwrt-sdk-25.12.6-*.tar.zst -C sdk --strip-components=1
cd sdk

./scripts/feeds update luci        # нужен luci.mk
./scripts/feeds install luci-base

ln -s /path/to/repo/shoulderkop          package/shoulderkop
ln -s /path/to/repo/luci-app-shoulderkop package/luci-app-shoulderkop

make defconfig
make package/shoulderkop/compile V=s -j2
make package/luci-app-shoulderkop/compile V=s -j2
```

Оба пакета помечены `PKGARCH:=all`, поэтому попадают в `bin/packages/x86_64/base/` и годятся
для любой архитектуры роутера.

## CI

[`.github/workflows/build.yml`](.github/workflows/build.yml): на push и PR — `lint` (`sh -n`,
`node --check`, JSON, ucode) и сборка обеих матриц; на тег `v*` — ещё и GitHub Release.

| Формат | SDK |
| --- | --- |
| `apk` | 25.12.6 |
| `ipk` | 24.10.8 |

## Релиз

Собирается из артефактов обеих матриц и содержит пять файлов: `shoulderkop-*.apk`,
`luci-app-shoulderkop-*.apk`, `shoulderkop_*_all.ipk`, `luci-app-shoulderkop_*_all.ipk`
и `SHA256SUMS`.

Установщик `installer/shoulderkop-install.sh` в релиз **не попадает**: он живёт в репозитории
и всегда скачивается по одной и той же ссылке (ветка `main`):

```sh
wget -O /tmp/sk-install.sh https://raw.githubusercontent.com/BranchSeeker/shoulderkop/main/installer/shoulderkop-install.sh
```

Из `bin/packages` копируются только файлы своих пакетов: рядом лежат зависимости из фидов,
собранные как побочный эффект, и в релиз они попадать не должны.

Перед тегом поднимите `PKG_VERSION`/`PKG_RELEASE` в обоих `Makefile`, затем
`git tag v0.4.1 && git push origin v0.4.1`.
