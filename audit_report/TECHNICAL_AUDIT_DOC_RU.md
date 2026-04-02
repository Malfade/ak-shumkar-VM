# Полный технический аудит проекта `ak-shumkar-VM` (OpenVAS Scanner + openvasd + GSA)

## 1. Цель и рамки аудита

Этот документ описывает фактическое устройство репозитория, его исполняемые контуры, роли файлов и связи между подсистемами.

Что покрыто:
- Legacy C-сканер (`src/`, `misc/`, `nasl/`) и его жизненный цикл.
- Rust-стек (`rust/`): `openvasd`, `scannerctl`, `scanner`, `storage`, `feed`, `osp`, Rust NASL.
- Веб-интерфейс GSA (`gsa/`) и его связь с `gsad`/`gvmd`.
- Контейнерная оркестрация (`docker-compose.full.yml`, `compose/`).
- Хранилища и схемы данных (Redis/SQLite) на уровне кода и миграций.

Важно:
- Документ основан на текущем состоянии файлов в рабочем дереве.
- В репозитории есть артефакты сборки и внешние зависимости (`node_modules`, `target`, `build*`), они не являются исходной логикой.

---

## 2. Инвентаризация репозитория

### 2.1 Масштаб
- Всего файлов в дереве: `59357`.
- Файлов без служебных/сгенерированных директорий (`.git`, `node_modules`, `target`, `build`, `build-old`): `5310`.

### 2.2 Основные зоны
- `src/` (`27` файлов): ядро C-сканера (оркестрация сканирования, процессы, планировщик VT).
- `misc/` (`41` файл): вспомогательная C-библиотека (`openvas_misc`) — IPC, network, KB, pcap, heartbeat.
- `nasl/` (`117` файлов): C NASL-интерпретатор и built-in функции.
- `rust/src/` (`474` файла): новый Rust-стек сканера.
- `gsa/src/` (`1963` файла): React/TS фронтенд.
- `doc/` (`420` файлов): man/doxygen/manual и сопутствующие скрипты.
- `compose/` (`13` файлов): отдельные compose-сценарии для `openvasd` (HTTP/TLS/mTLS).

### 2.3 Rust-подмодули (`rust/src/*`)
- `openvasd` (`49`), `nasl` (`317`), `scannerctl` (`24`), `storage` (`18`), `scanner` (`10`), `openvas` (`11`), `osp` (`7`), `feed` (`6`), `notus` (`17`), `alive_test` (`6`) и др.

---

## 3. Архитектура верхнего уровня

Проект содержит **два параллельных сканерных контура**:

1. Legacy контур (C):
- исполняемый файл `openvas`;
- C NASL-интерпретатор и VT-движок;
- Redis как KB/кэш VT;
- обычно управляется через `ospd-openvas`.

2. Новый контур (Rust):
- `openvasd` (HTTP Scanner API);
- `scannerctl` (CLI утилита);
- собственная Rust-реализация NASL, feed-обновления, scheduling, storage;
- в зависимости от конфигурации работает через OSPD, через wrapper `openvas`, либо через собственные Rust-эндпоинты/сканер.

Плюс внешний контур управления:
- `gvmd` (manager),
- `gsad` (HTTP API proxy),
- `gsa` (web UI).

---

## 4. Build-граф (C часть)

### 4.1 Корневой `CMakeLists.txt`
Собирает подпроекты:
- `misc` -> shared lib `openvas_misc_shared`
- `nasl` -> shared lib `openvas_nasl_shared` + бинари `openvas-nasl`, `openvas-nasl-lint`
- `src` -> бинарь `openvas`

### 4.2 Бинарные цели
- `openvas` (`src/main.c` -> `openvas()` в `src/openvas.c`)
- `openvas-nasl` (standalone интерпретатор)
- `openvas-nasl-lint`

### 4.3 Связывание
- `openvas` зависит от `openvas_nasl_shared` и `openvas_misc_shared`.
- `openvas_nasl_shared` зависит от `openvas_misc_shared`.
- Оба контура завязаны на `libgvm_base/util/boreas`, `glib`, `pcap`, `gcrypt`, `gnutls`, `redis`-доступ через gvm libs.

---

## 5. Legacy C-сканер: поток выполнения

## 5.1 Точка входа
- `src/main.c`: только проксирует в `openvas(argc, argv, env)`.
- `src/openvas.c`: полноценный CLI и lifecycle:
  - `--update-vt-info` -> загрузка VT метаданных,
  - `--scan-start <id>` -> запуск скана,
  - `--scan-stop <id>` -> остановка,
  - `--cfg-specs`, `--version` и др.

## 5.2 Инициализация перед сканом (`attack_network_init`)
Ключевые шаги:
- установка дефолтных prefs (`set_default_openvas_prefs`),
- чтение конфигурации (`prefs_config`),
- применение глобальных лимитов (`set_globals_from_preferences`),
- `plugins_cache_init()` (инициализация NVT cache),
- выбор канала LSC (`openvasd_server` или MQTT),
- установка signal handlers,
- подтягивание scan prefs из Redis (`overwrite_openvas_prefs_with_prefs_from_client`).

## 5.3 Основной цикл атаки (`src/attack.c`, `attack_network`)
Логика:
- проверка доступа к KB, чтение `TARGET`;
- валидация `port_range`;
- инициализация scheduler по `plugin_set`;
- резолв и фильтрация хостов (`exclude_hosts`, reverse-lookup, allow/deny);
- опциональный alive-detection thread (Boreas через `start_alive_detection`);
- на каждый хост:
  - создание host KB,
  - fork host-процесса (`create_ipc_process` + `attack_start`),
  - запуск VT по dependency-aware scheduler,
  - контроль завершения дочерних процессов.

В конце:
- ожидание завершения host-процессов,
- освобождение scheduler/host list,
- установка scan status `finished`.

## 5.4 Запуск VT
Цепочка:
- `plugins_scheduler_next()` -> выбирает готовый VT с учетом зависимостей и статусов.
- `plugin_launch()` (`src/pluginlaunch.c`) -> слот, timeout, fork NASL процесса.
- `nasl_plugin_launch()` (`src/nasl_plugins.c`) -> фактический запуск NASL script.
- `pluginlaunch_wait*()` -> контроль лимитов по параллелизму/памяти/loadavg и cleanup.

## 5.5 Управление хост-процессами
`src/hosts.c`:
- список активных хостов,
- ограничение `max_hosts`,
- установка PID, сбор завершившихся процессов,
- массовая остановка при сигнале.

## 5.6 Процессы и IPC
- `src/processes.c` + `misc/ipc*.c`:
  - создание дочерних процессов с IPC-контекстом,
  - передача сообщений parent/child,
  - очистка child resources,
  - групповая остановка по сигналам.

---

## 6. NASL в C: структура и роль файлов

### 6.1 Исполняемые сценарии
- `nasl/nasl.c`: standalone интерпретатор (`openvas-nasl`), CLI режимы (`description`, `parse`, `lint`, target/KB и т.д.).
- `nasl/exec.c`: execution engine AST/выражений.
- `nasl/nasl_grammar.y`: грамматика (bison), генерирует parser.

### 6.2 Регистрация built-in
- `nasl/nasl_init.c`: огромная таблица `NASL name -> C function`.
- Включает группы: scanner glue, network/socket, http/http2, crypto, ssh/smb/snmp, packet forgery, report functions и др.

### 6.3 Связка сканера и NASL
- `nasl/nasl_scanner_glue.c`: `script_*`, KB операции, scanner_* функции, публикация результатов.

### 6.4 Ключевые тематические модули NASL
- `nasl_socket.c`, `nasl_http.c`, `nasl_http2.c`, `nasl_ssh.c`, `nasl_snmp.c`, `nasl_wmi.c`
- `nasl_packet_forgery*.c`, `nasl_frame_forgery.c`, `nasl_builtin_synscan.c`
- `nasl_crypto*.c`, `nasl_cert.c`, `nasl_isotime.c`, `nasl_misc_funcs.c`

---

## 7. `misc/` (C utility library) — что за что отвечает

Критически важные файлы:
- `network.c/.h`: TCP/UDP/TLS соединения, SSL negotiation, stream helpers.
- `plugutils.c/.h`: KB-операции, порт-стейты, posting результатов (ALARM/LOG/ERRMSG).
- `kb_cache.c/.h`: кэш `main_kb`.
- `pcap.c`, `bpf_share.c`: pcap/BPF функции для сетевых проверок.
- `heartbeat.c`: проверки живости хоста.
- `ipc.c`, `ipc_openvas.c`, `ipc_pipe.c`: IPC-абстракция.
- `table_driven_lsc.c/.h`: table-driven LSC / Notus related processing.
- `openvas-krb5.c/.h`: Kerberos вспомогательный слой.
- `scan_id.c/.h`: глобальный scan id контекст.

---

## 8. Rust-стек: назначение и реальная архитектура

## 8.1 Cargo workspace и бинари
Определены бинари:
- `openvasd` (`rust/src/openvasd/main.rs`)
- `scannerctl` (`rust/src/scannerctl/main.rs`)
- `feed-verifier`, `feed-filter`

## 8.2 `openvasd` startup sequence
`rust/src/openvasd/main.rs`:
1. Загрузка конфигурации (`Config::load`).
2. Инициализация логирования.
3. Создание SQLite pool + применение миграций (`sqlx::migrate!`).
4. Инициализация VT subsystem (`vts::init`).
5. Инициализация scan subsystem (`scans::init`).
6. Инициализация Notus endpoints.
7. Конфигурация HTTP runtime (`RuntimeBuilder`) + TLS/mTLS.
8. Подключение handler-ов и запуск `run_blocking()`.

## 8.3 Конфигурация openvasd
`rust/src/openvasd/config/mod.rs`:
- feed/notus пути и интервалы;
- scanner type: `ospd | openvas | openvasd`;
- storage mode: `inmemory | fs | redis` (+ SQLite config v2);
- scheduler limits (`max_running_scans`, `min_free_mem`, interval);
- TLS/mTLS и endpoint policy (API key, доступные endpoints).

## 8.4 Scan orchestration в openvasd
`rust/src/openvasd/scans/*`:
- REST endpoints для CRUD/статусов/результатов;
- scheduler loop в `scheduling.rs`:
  - перевод состояний (`stored -> requested -> running -> done/failed`),
  - запуск scanner backend,
  - импорт результатов,
  - контроль feed sync lock.
- `state_change.rs`: централизованный state-controller поверх SQLite.

## 8.5 VT feed orchestration в openvasd
`rust/src/openvasd/vts/*`:
- `orchestrator.rs`: механизм Need/Allow/Synced для безопасной синхронизации фида.
- `mod.rs`: выбор backend по scanner type (`redis` vs `sql`).
- plugin/advisory ingestion с hash-сравнением и периодической синхронизацией.

---

## 9. Rust scanner engine (`rust/src/scanner`)

Модель слоев (по `scanner/mod.rs`):
- `OpenvasdScanner` (менеджер всех активных scan run),
- `RunningScan` (жизненный цикл одного скана),
- `ScanRunner` (выполнение VT по хостам),
- `VTRunner` (выполнение одного VT).

Трейты API:
- `ScanStarter`, `ScanStopper`, `ScanDeleter`, `ScanResultFetcher`.

---

## 10. Rust wrapper для legacy OpenVAS (`rust/src/openvas`)

`openvas/openvas.rs` реализует `Scanner` поверх внешнего процесса `openvas`:
- хранит карту running child process (`scan_id -> (Child, dbid)`),
- подготавливает prefs в Redis перед стартом,
- вызывает `cmd::start/stop` для запуска/остановки,
- собирает результаты через Redis helper/result collector,
- применяет resource-checker (CPU/RAM границы).

Это bridge-слой между новым API и старым C scan engine.

---

## 11. Rust NASL subsystem (`rust/src/nasl`)

Компоненты:
- `syntax`: tokenizer + parser + metadata extraction;
- `interpreter`: исполнение AST, register/scopes, forking interpreter;
- `builtin`: модули функций (network, http, ssh, snmp, crypto, host, report, raw_ip и др.);
- `utils`: scan context, function adapters, executor.

Текущее состояние проекта: Rust NASL очень большой, но legacy C NASL все еще присутствует и используется в ряде контуров.

---

## 12. Storage и базы данных

## 12.1 SQLite миграции (`rust/migrations`)
Базовая схема (`20250711070445_init.sql`):
- `client_scan_map`, `scans`, `preferences`, `ports`, `alive_methods`, `hosts`, `vts`, `vt_parameters`, `results`, `feed`, `plugins`, `resolved_hosts`, `knowledge_base_items`.
- триггеры для `start_time`/`end_time` при смене `status`.

Дополнительная миграция (`20251120114645_add_scanning_to_scans.sql`):
- таблица `host_scanning` (прогресс по хостам).

## 12.2 Scanner runtime миграции (`rust/scanner-migrations`)
Отдельная легковесная схема для runtime storage scannerlib (`scans`, `resolved_hosts`, `knowledge_base_items`, `results`).

## 12.3 Redis
Используется в двух ролях:
- legacy KB/scanprefs/status/results для C/OpenVAS/OSPD;
- часть Rust backends и bridge-логики (`openvas` wrapper, feed sync варианты).

---

## 13. OSP, feed, notus, alive-test

- `rust/src/osp`: клиент к OSPD socket (start/stop/get/delete).
- `rust/src/feed`: verification/loader для feed (`sha256sums`, signature check).
- `rust/src/notus`: Rust implementation Notus scanner.
- `rust/src/alive_test`: Rust реализация Boreas (ICMP/TCP ACK/SYN/ARP, IPv4/IPv6).

---

## 14. GSA (frontend)

## 14.1 Стек
- React 18 + TypeScript + Vite.
- Redux Toolkit, React Query, styled-components, i18next.
- Вход: `gsa/src/index.tsx` -> `web/App.tsx`.

## 14.2 Архитектурные зоны
- `src/gmp/*`: клиентский слой протокола/моделей/парсинга.
- `src/web/*`: UI компоненты, pages, store, hooks, routes.

## 14.3 Runtime связь
- GSA общается с `gsad` API.
- `gsad` общается с `gvmd` через сокет.
- `gvmd` управляет сканером через OSP/ospd-openvas.

---

## 15. Контейнерная оркестрация

## 15.1 `docker-compose.full.yml`
Определяет полный стенд:
- feed data containers,
- infra (`redis-server`, `pg-gvm`),
- scanner/services (`openvas`, `ospd-openvas`, `openvasd`),
- manager (`gvmd`),
- web (`gsad`, `gsa` nginx).

Файл описывает гибридную архитектуру, где одновременно присутствуют legacy и новый контур.

## 15.2 `start.sh`
Автоматизирует локальный подъем:
1. build GSA (`npm install && npm run build` в node:22 контейнере),
2. чистка postgres socket lock,
3. `docker-compose down && up -d`.

## 15.3 `compose/`
Отдельные минимальные compose-сценарии для `openvasd`:
- `base.yaml` (HTTP),
- `tls.yaml`,
- `mtls.yaml`.

## 15.4 Какие конфиги использует GVM и как их менять (в рамках этого репозитория)

Ниже перечислены **фактически задействованные точки конфигурации** в двух сценариях этого репозитория:
- полный стек: `docker-compose.full.yml`;
- минимальный стенд scanner API: `compose/*.yaml`.

### 15.4.1 `openvas.conf` (legacy OpenVAS scanner preferences)

Что это:
- Файл предпочтений/настроек legacy C-сканера (`openvas`), который влияет на runtime (лимиты, поведение проверок, интеграции вроде `openvasd_server`, опции alive-test и т.д.).

Где берется в full stack:
- В [docker-compose.full.yml](/home/malfade/Worl/cybersecurity/888000131/ak-shumkar-VM/docker-compose.full.yml) файл **генерируется** oneshot-сервисом `configure-openvas` и сохраняется в named volume `openvas_data_vol` (монтируется как `/etc/openvas` в контейнеры `openvas` и `ospd-openvas`).
- В этом compose он создается командой вида:
  - `printf "table_driven_lsc = yes\nopenvasd_server = http://openvasd:80\n" > /mnt/openvas.conf`

Где берется в `compose/`:
- В [compose/base.yaml](/home/malfade/Worl/cybersecurity/888000131/ak-shumkar-VM/compose/base.yaml) и override-файлах ([compose/tls.yaml](/home/malfade/Worl/cybersecurity/888000131/ak-shumkar-VM/compose/tls.yaml), [compose/mtls.yaml](/home/malfade/Worl/cybersecurity/888000131/ak-shumkar-VM/compose/mtls.yaml)) `openvas.conf` также **генерируется** сервисом `configure-openvas`, но параметры берутся из env `OPENVASD_PROTOCOL`/`OPENVASD_PORT`.

Как поменять:
- Править генерацию: изменить команду/переменные у `configure-openvas` (в `docker-compose.full.yml` или в `compose/*.yaml`).
- Подложить свой файл: смонтировать bind-mount *файла* на `/etc/openvas/openvas.conf` (он перекроет файл из volume).

### 15.4.2 `ospd-openvas.conf` (OSPd bridge configuration)

Что это:
- Конфиг демона `ospd-openvas` (OSPd-обертки), который управляет запуском `openvas`, доступом к feed/Notus, сокетами и прочими параметрами OSP/OSPd.

Где берется в full stack:
- В [docker-compose.full.yml](/home/malfade/Worl/cybersecurity/888000131/ak-shumkar-VM/docker-compose.full.yml) сервис `ospd-openvas` запускается с:
  - `--config /etc/gvm/ospd-openvas.conf`
- При этом **в compose нет volume-mount на этот путь**, значит конфиг берется **изнутри образа** `registry.community.greenbone.net/community/ospd-openvas:stable` (дефолтный конфиг образа).

Как поменять (практически):
- Добавить mount своего файла, например:
  - `./my-ospd-openvas.conf:/etc/gvm/ospd-openvas.conf:ro`

### 15.4.3 Redis (KB/кэш для legacy сканера, storage для части Rust)

Что это:
- Redis используется как временное хранилище/KB (knowledge base) и кэш для VT/скан-данных (особенно для legacy C-сканера). В Rust-части также присутствует режим storage через Redis для некоторых компонент.

Где берется в full stack:
- В [docker-compose.full.yml](/home/malfade/Worl/cybersecurity/888000131/ak-shumkar-VM/docker-compose.full.yml) сервис `redis-server` — это готовый образ `community/redis-server` и общий сокет в volume `redis_socket_vol:/run/redis/`.
- Файл [config/redis-openvas.conf](/home/malfade/Worl/cybersecurity/888000131/ak-shumkar-VM/config/redis-openvas.conf) в full stack compose **не подключен** напрямую: он предназначен в первую очередь для нативной установки (systemd) или кастомного запуска redis (см. `INSTALL.md`/`doc/full_installation_guide.md`).

Как поменять:
- Если нужен свой `redis.conf`: смонтировать файл и поменять `command` redis-контейнера (или использовать образ/entrypoint, который это поддерживает).
- Если достаточно дефолтов образа: менять параметры через поддерживаемые env/аргументы образа (если предоставлены).

### 15.4.4 `gvmd` (Manager) и хранилища (PostgreSQL)

Что это:
- `gvmd` хранит конфигурацию задач/сканов/объектов (targets, tasks, configs, credentials) и результаты в БД (PostgreSQL).

Где берется в full stack:
- В [docker-compose.full.yml](/home/malfade/Worl/cybersecurity/888000131/ak-shumkar-VM/docker-compose.full.yml) сервис `gvmd` запускается на дефолтах образа `community/gvmd:stable`.
- В compose явно подключены только volume’ы данных и сокеты:
  - `/var/lib/gvm` (данные),
  - `/var/run/postgresql` (сокет к Postgres),
  - `/run/ospd` (сокет к OSPD),
  - `/run/gvmd` (сокет gvmd для gsad).
- Явного `gvmd.conf`/`GVMD_ARGS` в этом compose нет, поэтому конфигурация `gvmd` в основном определяется образом и тем, что хранится в БД.

Как поменять:
- В контейнерном сценарии обычно делается одним из способов:
  - добавить `command`/env (если образ `gvmd` поддерживает параметризацию через переменные окружения);
  - монтировать конфиг-файл, если вы точно знаете путь, который читает конкретный образ;
  - менять поведение/объекты через интерфейсы `gvmd` (GMP через `gsad`, `gvm-tools`, UI GSA), т.к. значимая часть “настроек” хранится в БД.

### 15.4.5 `gsad` (HTTP API proxy)

Где берется в full stack:
- В [docker-compose.full.yml](/home/malfade/Worl/cybersecurity/888000131/ak-shumkar-VM/docker-compose.full.yml) `gsad` настраивается переменной окружения `GSAD_ARGS`.
- Указанные флаги (`--http-only`, `--api-only`, `--listen=0.0.0.0`, `-v -f`) непосредственно определяют режим работы и доступность API.

Как поменять:
- Править `GSAD_ARGS` в compose.

### 15.4.6 `openvasd` (Rust HTTP Scanner API) и его конфиги

Важно:
- В full stack [docker-compose.full.yml](/home/malfade/Worl/cybersecurity/888000131/ak-shumkar-VM/docker-compose.full.yml) сервис `openvasd` помечен как `image: openvasd-local` и получает env вроде `LISTENING=0.0.0.0:80`. То есть конфигурация передается **через переменные окружения/CLI** (в зависимости от того, как собран образ).
- В минимальном стенде `compose/` используется `community/openvas-scanner:stable` как образ `openvasd` и задаются env для TLS/mTLS.

Какие ключевые env/CLI ожидает `openvasd` (по коду):
- Реализовано в [rust/src/openvasd/config/mod.rs](/home/malfade/Worl/cybersecurity/888000131/ak-shumkar-VM/rust/src/openvasd/config/mod.rs).
- Поддерживаются как минимум:
  - `OPENVASD_CONFIG` (путь к TOML конфигу),
  - `LISTENING`, `API_KEY`, `SCANNER_TYPE`, `OPENVASD_MODE`,
  - `STORAGE_TYPE`, `STORAGE_PATH`, `REDIS_URL`,
  - `FEED_PATH`, `NOTUS_PRODUCTS`, `NOTUS_ADVISORIES`,
  - `TLS_CERTS`, `TLS_KEY`, `TLS_CLIENT_CERTS`,
  - `OSPD_SOCKET`, `READ_TIMEOUT` и др.

Как поменять:
- Самый прямой путь: добавить/изменить env у сервиса `openvasd` в compose.
- Для больших конфигураций: смонтировать TOML и указать `OPENVASD_CONFIG=/path/to/config.toml`.

---

## 16. Карта ответственности ключевых файлов

### 16.1 Legacy C (ядро)
- `src/openvas.c`: главный runtime lifecycle сканера.
- `src/attack.c`: orchestration хостов и VT запуска.
- `src/pluginscheduler.c`: DAG/зависимости VT.
- `src/pluginlaunch.c`: управление процессами VT и лимитами.
- `src/pluginload.c`: загрузка `.nasl` и nvt cache.
- `src/hosts.c`: трекинг host child processes.
- `src/processes.c`: общий процессный менеджмент/IPC.

### 16.2 Legacy C (NASL)
- `nasl/nasl.c`: standalone NASL CLI.
- `nasl/exec.c`: evaluation engine.
- `nasl/nasl_init.c`: registry built-in.
- `nasl/nasl_scanner_glue.c`: bridge NASL <-> scanner/KB.
- `nasl/nasl_grammar.y`: grammar/parser generation.

### 16.3 Rust core
- `rust/src/openvasd/main.rs`: daemon bootstrap.
- `rust/src/openvasd/scans/mod.rs`: scans API + DB CRUD.
- `rust/src/openvasd/scans/scheduling.rs`: scheduler loop.
- `rust/src/openvasd/vts/orchestrator.rs`: feed sync coordinator.
- `rust/src/scanner/mod.rs`: OpenvasdScanner abstraction.
- `rust/src/openvas/openvas.rs`: bridge к legacy openvas process.
- `rust/src/storage/mod.rs`: dispatcher/retriever/remover contracts.

### 16.4 GSA
- `gsa/src/index.tsx`: frontend entrypoint.
- `gsa/src/web/App.tsx`: root providers, store, routing bootstrap.
- `gsa/src/gmp/*`: protocol/client data model.

---

## 17. Межмодульные связи (как именно сцеплены файлы)

## 17.1 C runtime цепочка
`src/main.c` -> `src/openvas.c` -> `src/attack.c` -> `src/pluginlaunch.c`/`src/pluginscheduler.c` -> `src/nasl_plugins.c` -> `nasl/*.c` -> `misc/*.c` -> KB/результаты.

## 17.2 Rust openvasd цепочка
`openvasd/main.rs` -> `openvasd/config` + DB migrate -> `openvasd/vts` + `openvasd/scans` -> backend scanner (`osp`/`openvas`/`openvasd`) -> storage/results.

## 17.3 Full platform chain
`GSA` -> `gsad` -> `gvmd` -> `ospd-openvas`/`openvasd` -> `openvas` + `NASL VT` -> Redis/SQLite -> результаты обратно вверх.

---

## 18. Зафиксированные технические особенности и риски

1. Репозиторий гибридный: одновременно поддерживает legacy и новый стек, что усложняет сопровождение и трассировку инцидентов.
2. Часть документации в дереве явно отмечена как WIP (`doc/README.md`), не все исторические пути/референсы присутствуют в этом checkout.
3. В корне уже существует `TECHNICAL_AUDIT_DOC.md`, но его содержимое не полностью соответствует текущему состоянию файлов; использовать как справочный, а не как источник истины.
4. Большие каталоги артефактов (`node_modules`, `target`, `build*`) маскируют реальную структуру кода и должны исключаться из инженерной аналитики.

---

## 19. Рекомендованный порядок чтения кода для онбординга

1. `README.md` -> `INSTALL.md` -> `docker-compose.full.yml`.
2. Legacy path: `src/openvas.c` -> `src/attack.c` -> `src/pluginlaunch.c` -> `src/pluginscheduler.c` -> `nasl/nasl_init.c`.
3. Rust path: `rust/src/openvasd/main.rs` -> `openvasd/config` -> `openvasd/scans` -> `openvasd/vts` -> `scanner` -> `storage`.
4. UI path: `gsa/src/index.tsx` -> `web/App.tsx` -> `gmp/*` + `web/pages/*`.

---

## 20. Вывод

Проект представляет собой крупный многоязычный монорепозиторий с переходной архитектурой:
- зрелый C-сканер и C NASL рантайм,
- активно развиваемый Rust daemon/scanner stack,
- отдельный фронтенд GSA,
- контейнерный orchestration-слой, объединяющий все компоненты.

Критический инженерный факт: **в продуктивной логике одновременно живут несколько поколений сканерной инфраструктуры**, поэтому любые изменения нужно проектировать с учетом совместимости C/OpenVAS/OSPD/Rust/openvasd контуров.

---

## 21. Приложение A: полный перечень C-файлов ядра

### 21.1 `src/`
- `src/CMakeLists.txt`
- `src/attack.c`
- `src/attack.h`
- `src/attack_tests.c`
- `src/debug_utils.c`
- `src/debug_utils.h`
- `src/hosts.c`
- `src/hosts.h`
- `src/main.c`
- `src/nasl_plugins.c`
- `src/openvas.c`
- `src/openvas.h`
- `src/openvas_log_conf.cmake_in`
- `src/pluginlaunch.c`
- `src/pluginlaunch.h`
- `src/pluginload.c`
- `src/pluginload.h`
- `src/pluginscheduler.c`
- `src/pluginscheduler.h`
- `src/plugs_req.c`
- `src/plugs_req.h`
- `src/processes.c`
- `src/processes.h`
- `src/sighand.c`
- `src/sighand.h`
- `src/utils.c`
- `src/utils.h`

### 21.2 `misc/`
- `misc/bpf_share.c`, `misc/bpf_share.h`
- `misc/ftp_funcs.c`, `misc/ftp_funcs.h`
- `misc/heartbeat.c`, `misc/heartbeat.h`
- `misc/ipc.c`, `misc/ipc.h`
- `misc/ipc_openvas.c`, `misc/ipc_openvas.h`, `misc/ipc_openvas_tests.c`
- `misc/ipc_pipe.c`, `misc/ipc_pipe.h`
- `misc/kb_cache.c`, `misc/kb_cache.h`
- `misc/network.c`, `misc/network.h`
- `misc/nvt_categories.h`
- `misc/openvas-krb5.c`, `misc/openvas-krb5.h`
- `misc/pcap.c`, `misc/pcap_openvas.h`, `misc/pcap_tests.c`
- `misc/plugutils.c`, `misc/plugutils.h`
- `misc/scan_id.c`, `misc/scan_id.h`
- `misc/scanneraux.c`, `misc/scanneraux.h`
- `misc/strutils.c`, `misc/strutils.h`
- `misc/support.h`
- `misc/table_driven_lsc.c`, `misc/table_driven_lsc.h`, `misc/table_driven_lsc_tests.c`
- `misc/user_agent.c`, `misc/user_agent.h`
- `misc/vendorversion.c`, `misc/vendorversion.h`

### 21.3 `nasl/` (верхний уровень)
- parser/runtime: `nasl.c`, `exec.c`, `nasl_grammar.y`, `nasl_tree.c`, `nasl_var.c`, `nasl_lex_ctxt.c`
- scanner glue: `nasl_scanner_glue.c`, `nasl_host.c`, `nasl_init.c`
- network/http/socket: `nasl_socket.c`, `nasl_http.c`, `nasl_http2.c`, `nasl_ssh.c`, `nasl_snmp.c`, `nasl_wmi.c`
- packet/raw: `nasl_packet_forgery.c`, `nasl_packet_forgery_v6.c`, `nasl_frame_forgery.c`, `capture_packet.c`, `nasl_builtin_synscan.c`
- crypto/cert/auth: `nasl_crypto.c`, `nasl_crypto2.c`, `nasl_cert.c`, `nasl_signature.c`, `nasl_krb5.c`, `nasl_smb.c`
- util: `nasl_misc_funcs.c`, `nasl_text_utils.c`, `nasl_cmd_exec.c`, `nasl_debug.c`, `nasl_isotime.c`

---

## 22. Приложение B: ключевые файлы Rust-контуров

### 22.1 `rust/src/openvasd/`
- `main.rs` — bootstrap и запуск runtime.
- `config/mod.rs` — типы конфигурации.
- `scans/mod.rs`, `scans/scheduling.rs`, `scans/state_change.rs` — API/планировщик/состояния сканов.
- `vts/mod.rs`, `vts/orchestrator.rs`, `vts/sql.rs`, `vts/redis.rs` — обработка VT feed.
- `database/sqlite.rs` — контейнер соединений SQLite.
- `container_image_scanner/*` — отдельный контейнерный сканерный подпоток.

### 22.2 `rust/src/scanner/`
- `mod.rs`, `scanner.rs` — базовые трейты и фасад сканера.
- `running_scan.rs`, `scan_runner.rs`, `vt_runner.rs` — execution pipeline.
- `preferences/*` — scanner preferences.

### 22.3 `rust/src/openvas/`
- `openvas.rs` — управление legacy `openvas` как backend.
- `openvas_redis.rs`, `result_collector.rs`, `pref_handler.rs`, `cmd.rs`.

### 22.4 `rust/src/nasl/`
- `syntax/*`, `interpreter/*`, `builtin/*`, `utils/*`.
- Наиболее объемный модуль проекта (`317` файлов в дереве `rust/src/nasl`).

---

## 23. Детализированные последовательности выполнения (runtime sequences)

## 23.1 Sequence: запуск `openvas --scan-start <scan_id>`

1. **CLI разбор в `src/openvas.c`**
- считываются флаги, `scan_id`, `config_file`.
- инициализируется логирование и sentry.

2. **Инициализация скана (`attack_network_init`)**
- дефолтные prefs -> `prefs_config` -> глобальные лимиты.
- проверка/инициализация NVT cache (`plugins_cache_init`).
- выбор LSC backend (`openvasd_server` или MQTT).
- установка signal handlers (`SIGTERM/SIGINT/SIGQUIT/SIGCHLD`).
- перенос scan-specific preferences из Redis в локальные prefs.

3. **Запуск атакующего контура (`attack_network`)**
- чтение `TARGET`, `plugin_set`, `port_range`.
- построение scheduler и загрузка зависимостей VT.
- нормализация/фильтрация списка хостов.
- опциональный alive-test.

4. **Per-host execution**
- создание host KB.
- fork host-process (`create_ipc_process` -> `attack_start`).
- host-process запускает VT через `plugin_launch` и ждет завершения всех VT.

5. **Завершение**
- ожидание завершения всех host-process.
- сбор статуса/логов/метрик.
- установка scan state `finished` в KB.

## 23.2 Sequence: обновление VT метаданных (`openvas -u`)

1. `openvas.c` входит в ветку `--update-vt-info`.
2. `plugins_init()`:
- `plugins_cache_init()`:
  - `nvticache_init(plugins_folder, db_address)`
  - `include_dirs()`
  - проверка `plugin_feed_info.inc`
- `plugins_reload_from_dir()`:
  - рекурсивный сбор `.nasl`
  - `nasl_plugin_add()` на каждый VT
  - очистка leftovers
- `nvticache_save()`
3. завершение процесса.

## 23.3 Sequence: запуск `openvasd`

1. `openvasd/main.rs`: загрузка `Config`.
2. `setup_sqlite()` и `MIGRATOR.run(...)`.
3. `vts::init(...)`:
- выбор sync backend (`redis`/`sql`) по `scanner_type`.
- запуск orchestrator loop проверки hash feed.
4. `scans::init(...)`:
- запуск scheduler loop сканов.
5. сбор `RuntimeBuilder`:
- TLS/mTLS wiring,
- scans endpoints,
- VTs endpoints,
- notus handlers,
- container-image endpoints.
6. запуск `run_blocking()`.

## 23.4 Sequence: openvasd scheduler loop (обобщенно)

На каждом тике:
1. проверка `feed_sync_in_progress`; если true, новые сканы не стартуют.
2. `stored -> requested` по входящим командам.
3. `requested -> running` (с учетом лимитов и `can_start_scan`).
4. `fetch_results` у backend scanner.
5. сохранение результатов в SQLite.
6. обновление host progress/status.
7. если scan done: удаление/cleanup у backend.

---

## 24. Конфигурационные точки и их влияние на поведение

## 24.1 Legacy C scanner (`openvas.conf` + prefs)

Ключевые параметры, влияющие на интенсивность скана:
- `max_hosts`: число одновременно сканируемых хостов.
- `max_checks`: число параллельных VT на хост.
- `plugins_timeout` / `scanner_plugins_timeout`: таймауты VT.
- `test_alive_hosts_only`: включение alive-detection перед VT.
- `allow_simultaneous_ips`: параллелизм по IP.
- `table_driven_lsc`: включение table-driven LSC (Notus-путь).
- `openvasd_server` / `mqtt_server_uri`: канал LSC интеграции.

Ключевые параметры выбора VT:
- `plugin_set`: OID-список VT для scheduler.
- `auto_enable_dependencies`: автозагрузка dependency VT.
- `exclude_hosts`, `reverse_lookup_*`, `hosts_*_allow/deny`.

## 24.2 `openvasd` (Rust, `openvasd.toml`)

Ключевые группы:
- `feed.*`: путь, интервал проверки, signature-check.
- `notus.*`: пути advisories/products.
- `scanner.type`: `ospd | openvas | openvasd`.
- `scheduler.*`: очередь/параллелизм/ограничения по памяти.
- `storage.*`: тип и параметры хранилища.
- `tls.*`: cert/key/client certs (mTLS).
- `endpoints.*`: API key, включение отдельных endpoint-ов.

## 24.3 Практический эффект `scanner.type`

- `ospd`: openvasd выступает как API-слой к OSPD backend.
- `openvas`: openvasd управляет внешним процессом `openvas` через Rust wrapper.
- `openvasd`: целевой путь к полноценному Rust scanner stack.

---

## 25. Диагностика и отладка: symptom -> where to inspect

## 25.1 Симптом: “скан завис на старте”

Проверить:
1. C path:
- `src/openvas.c` (`attack_network_init`, `overwrite_openvas_prefs_with_prefs_from_client`)
- доступность Redis KB и наличие `internal/<scan_id>/scanprefs`.
2. Rust path:
- `openvasd/scans/scheduling.rs` (state transitions)
- `openvasd/vts/orchestrator.rs` (не ожидает ли Allow feed sync)
- SQLite state в `scans.status`.

## 25.2 Симптом: “много VT timeout”

Проверить:
- `src/pluginlaunch.c`: timeout enforcement, `max_vts_timeouts`.
- лимиты `max_checks`, `max_hosts`, системная загрузка, `min_free_mem`.
- transport-level проблемы в `misc/network.c`.

## 25.3 Симптом: “слишком много SSH коннектов”

Проверить:
- профиль VT (`plugin_set`), LSC/NASL покрытие.
- `max_checks` и host parallelism.
- credential quality и повторные auth-попытки.
- backend mode (`ospd/openvas/openvasd`) и policy скана.

## 25.4 Симптом: “feed не синхронизируется”

Проверить:
- `rust/src/openvasd/vts/orchestrator.rs` (Need/Allow/Synced цикл).
- hash/cached_hash consistency.
- signature validation (`feed::check_signature`) и `GNUPGHOME`.
- наличие ожидаемых feed файлов (`sha256sums`, `vt-metadata.json`, advisories).

## 25.5 Симптом: “результаты пустые или неполные”

Проверить:
- состояние хостов (`host_dead/host_alive/host_scanning`).
- `results` insert path в `openvasd/scans/mod.rs`.
- для C-контура: публикация в `internal/results` через `plugutils`/`attack`.
- наличие root-привилегий для raw/packet-forgery VT.

---

## 26. Безопасность и доверительные границы

## 26.1 Границы доверия

1. **Внешний клиент** -> `openvasd` API (HTTP/TLS/mTLS).
2. `openvasd` -> backend scanner (`ospd`, `openvas` или internal).
3. scanner -> target hosts (network trust boundary).
4. scanner <-> Redis/SQLite (data integrity boundary).
5. feed source -> feed files -> verifier/signer checks.

## 26.2 Критичные security-моменты

- Feed integrity: hash + подпись (при включенной проверке).
- Credential handling: в openvasd auth_data хранится в шифруемом blob-поле.
- Root-required VT: без root часть сетевых проверок неполная.
- mTLS режим для openvasd предпочтительнее чистого API-key.

## 26.3 Риск-паттерны

- Отключенная signature check на feed.
- Избыточный scanner parallelism в перегруженной среде.
- Неполная настройка TLS/mTLS.
- Смешение legacy/new стека без ясного operational ownership.

---

## 27. Матрица модулей и ответственных за данные

| Данные | Где создаются | Где хранятся | Кто читает |
|---|---|---|---|
| VT metadata (legacy) | `plugins_init`/NASL description | Redis nvticache | OSPD/openvas/scanner paths |
| VT metadata (rust) | `vts` sync (`sql`/`redis`) | SQLite `plugins` или Redis | openvasd VTs endpoints/scanner |
| Scan prefs | client -> scanner/openvasd | Redis (legacy), SQLite (rust) | scanner runtime |
| Host progress | scanner runtime | SQLite `host_scanning`/status fields | openvasd status endpoints |
| Findings/results | VT execution | Redis `internal/results` и/или SQLite `results` | gvmd/openvasd clients |
| KB items | NASL/runtime writes | Redis (legacy), SQLite `knowledge_base_items` (rust path) | dependent VT / result collectors |

---

## 28. Технический debt и предложения по эволюции

1. **Single source of truth doc**
- объединить разрозненные audit/doc markdown в один канонический набор (architecture + ops + troubleshooting).

2. **Явная карта режимов**
- зафиксировать в отдельной таблице поддерживаемость режимов `scanner.type` и expected production topology.

3. **Унификация наблюдаемости**
- привести C и Rust контуры к единому формату событий/метрик (scan_id/host/vt correlation id).

4. **Де-дубликация feed pathways**
- документировать и постепенно сокращать перекрывающиеся pathways (`openvas -u`, `scannerctl feed update`, openvasd vts sync).

5. **Контроль concurrency профилей**
- добавить преднастроенные безопасные/агрессивные performance-профили с явными лимитами.

---

## 29. Операционная памятка (краткая)

1. Перед запуском сканов проверить:
- feed актуален и валиден,
- Redis/SQLite доступны,
- scanner mode (`ospd/openvas/openvasd`) ожидаемый,
- creds и target policy корректны.

2. При инциденте “скан не идет”:
- сначала state machine (`stored/requested/running/...`),
- затем feed sync lock,
- затем backend scanner connectivity,
- затем target/network-level reachability.

3. При инциденте “результатов мало”:
- проверить host status (alive/dead/excluded),
- проверить timeouts и resource limits,
- проверить привилегии запуска (root-dependent VT).

---

## 30. Заключительное резюме по текущему состоянию

Система уже функционально насыщена и пригодна для enterprise-level сценариев, но остается архитектурно переходной. Текущий репозиторий требует дисциплины эксплуатации: явного выбора режима сканера, прозрачного контроля feed-процедур и строгой диагностики по state-machine.

Практически это означает, что надежность и предсказуемость зависят не только от кода, но и от того, насколько четко в инфраструктуре разделены роли legacy и нового Rust-контуров.

---

## 31. File-by-file: `rust/src/openvasd/*`

Ниже перечислены файлы openvasd-контура и их роль в системе.

## 31.1 Корневые файлы openvasd

- `openvasd/main.rs`
  - Точка входа демона.
  - Инициализирует runtime, SQLite pool, миграции, VT/scans/notus endpoints, TLS/mTLS.

- `openvasd/README.md`
  - Эксплуатационная документация по конфигурации, auth, TLS/mTLS, mode.

- `openvasd/crypt.rs`
  - Абстракции шифрования/дешифрования (`Crypt`) для чувствительных данных (например, credentials blob).

- `openvasd/json_stream.rs`
  - Потоковый парсинг JSON-массивов (важно для больших feed/metadata без чрезмерного потребления RAM).

## 31.2 `openvasd/config/*`

- `openvasd/config/mod.rs`
  - Главная модель конфигурации openvasd.
  - Типы: feed/notus/scanner/scheduler/storage/tls/endpoints/listener/mode.

- `openvasd/config/logging.rs`
  - Инициализация и адаптация уровней логирования.

- `openvasd/config/snapshots/*.snap`
  - Snapshot-тесты дефолтов/парсинга конфигурации.

## 31.3 `openvasd/database/*`

- `openvasd/database/mod.rs`
  - Публичный модуль БД openvasd.

- `openvasd/database/sqlite.rs`
  - Контейнер единого активного SQLite соединения с retry/replace при IO-ошибках.
  - Используется для сериализованных критичных операций state-machine.

## 31.4 `openvasd/scans/*`

- `openvasd/scans/mod.rs`
  - Реализация scan endpoint-логики (CRUD и связанная DB-логика).
  - Вставка scan-конфига в SQLite: hosts, ports, prefs, vts, vt params, credentials.

- `openvasd/scans/scheduling.rs`
  - Периодический scheduler loop.
  - Переходы состояний, запуск backend scanner, сбор результатов, финализация сканов.
  - Координация с VT feed sync (блокировки запуска во время sync).

- `openvasd/scans/state_change.rs`
  - Центр управления status-машиной и host-progress.
  - Query helpers + `ScanStateController`.

## 31.5 `openvasd/vts/*`

- `openvasd/vts/mod.rs`
  - Точка инициализации VT endpoints и feed sync backend (`redis` или `sql`).

- `openvasd/vts/orchestrator.rs`
  - Координатор синхронизации feed.
  - Протокол сообщений `Need -> Allow -> Synced` между sync worker и scheduler.

- `openvasd/vts/sql.rs`
  - SQL backend хранения/обновления VT metadata в SQLite (`feed`, `plugins`, advisory blobs).

- `openvasd/vts/redis.rs`
  - Redis backend для VT feed path (legacy-compatible сценарии).

## 31.6 `openvasd/notus/*`

- `openvasd/notus/mod.rs`
  - Notus endpoint wiring для openvasd API.

## 31.7 `openvasd/container_image_scanner/*`

- `container_image_scanner/mod.rs`
  - Инициализация подподсистемы container image scanning.

- `container_image_scanner/config/mod.rs`
  - Конфигурация container-scanner, пути DB/image extraction, runtime policy.

- `container_image_scanner/detection.rs`
  - Логика детекции пакетов/артефактов в образах.

- `container_image_scanner/messages.rs`
  - Типы сообщений и обмена между endpoint/scheduler/worker.

- `container_image_scanner/benchy.rs`
  - Утилиты/инструменты перф-профилирования container scanner.

- `container_image_scanner/image/mod.rs`
  - Работа с образом/слоями/извлечением содержимого.

- `container_image_scanner/notus/mod.rs`
  - Привязка Notus анализа к container image потоку.

- `container_image_scanner/endpoints/mod.rs`
  - Регистрация endpoint-ов контейнерного сканирования.

- `container_image_scanner/endpoints/scans.rs`
  - API operations для container-scans.

- `container_image_scanner/endpoints/vts.rs`
  - API operations по VT/capability view контейнерного сканера.

- `container_image_scanner/scheduling/mod.rs`
  - Планировщик контейнерных задач (очередь, состояние, polling).

- `container_image_scanner/scheduling/scanner.rs`
  - Исполнитель container image scan задачи.

- `container_image_scanner/scheduling/image.rs`
  - Image-level scheduling primitives.

- `container_image_scanner/migrations/*.sql`
  - Схема SQLite для container-scanner сущностей/таймтреков.

- `container_image_scanner/snapshots/*.snap`
  - Snapshot-тесты конфигурации и аргументов.

---

## 32. File-by-file: legacy C-ядро (`src/`, `misc/`, `nasl/`)

## 32.1 `src/*` — scanner runtime orchestration

- `src/main.c`
  - Минимальный entrypoint, проксирует в `openvas()`.

- `src/openvas.c`
  - Главный lifecycle-оркестратор процесса `openvas`.
  - CLI режимы: scan-start/stop, update-vt-info, print specs/version.

- `src/attack.c`
  - Core run-loop сканирования хостов.
  - Host queue, alive detection, fork host processes, VT launch loop.

- `src/hosts.c`
  - Управление списком активных host-process, PID tracking, завершение.

- `src/pluginload.c`
  - Загрузка feed `.nasl` и построение nvt cache.

- `src/pluginscheduler.c`
  - Dependency-aware выбор следующего VT.
  - Контроль циклов зависимостей.

- `src/pluginlaunch.c`
  - Старт/ожидание VT процессов, timeout enforcement, ресурсные проверки.

- `src/plugs_req.c`
  - Проверки requirements/mandatory/excluded ключей VT.

- `src/nasl_plugins.c`
  - Адаптер между scheduler/pluginlaunch и NASL запуском.

- `src/processes.c`
  - Универсальный management child processes + IPC context store.

- `src/sighand.c`
  - Signal handlers для child cleanup/аварийного завершения.

- `src/utils.c`
  - Общие scanner utility-функции (`process_alive`, file store, stats writes).

- `src/debug_utils.c`
  - Интеграция debug/telemetry hooks (включая sentry init).

- `src/*_tests.c`
  - Unit/functional тесты для отдельных модулей (`attack_tests.c`).

## 32.2 `misc/*` — shared utility library

- `misc/network.c/.h`
  - Низкоуровневые соединения, TLS negotiation, stream API.

- `misc/plugutils.c/.h`
  - KB wrappers и публикация scanner results в стандартном формате.

- `misc/kb_cache.c/.h`
  - Кэш `main_kb` link/handle.

- `misc/ipc.c/.h`, `misc/ipc_pipe.c/.h`, `misc/ipc_openvas.c/.h`
  - IPC abstractions и JSON-представление сообщений.

- `misc/pcap.c`, `misc/pcap_openvas.h`, `misc/bpf_share.c/.h`
  - Сетевое захватывание/маршрутизация/BPF helpers.

- `misc/heartbeat.c/.h`
  - Liveness checks и heartbeat-related helpers.

- `misc/table_driven_lsc.c/.h`
  - Table-driven LSC (Notus/Skiron advisories parsing/evaluation path).

- `misc/user_agent.c/.h`
  - User-Agent формирование/получение для HTTP-проверок.

- `misc/openvas-krb5.c/.h`
  - Kerberos helper API.

- `misc/scan_id.c/.h`
  - Глобальный scan id store/get.

- `misc/scanneraux.c/.h`
  - Общие структуры scanner runtime (`scan_globals`, `script_infos`).

- `misc/strutils.c/.h`
  - Строковые utility-функции.

- `misc/vendorversion.c/.h`
  - Vendor version accessors.

- `misc/ftp_funcs.c/.h`
  - FTP login/PASV helpers для NASL функций.

- `misc/support.h`
  - Платформенные compatibility macros.

- `misc/*_tests.c`
  - Тесты для pcap/ipc/lsc модулей.

## 32.3 `nasl/*` — C NASL interpreter and built-ins

### 32.3.1 Parser/AST/Execution core
- `nasl/nasl.c` — standalone interpreter binary.
- `nasl/nasl_grammar.y` — bison grammar.
- `nasl/exec.c` — AST execution engine.
- `nasl/nasl_tree.c/.h` — AST nodes.
- `nasl/nasl_var.c/.h` — NASL variables/scopes.
- `nasl/nasl_lex_ctxt.c/.h` — lexical context.
- `nasl/lint.c`, `nasl/nasl-lint.c`, `nasl/lint.h` — lint mode.

### 32.3.2 Initialization and scanner glue
- `nasl/nasl_init.c/.h` — регистрация встроенных NASL функций.
- `nasl/nasl_scanner_glue.c/.h` — bridge scanner/NASL/KB.
- `nasl/nasl_builtin_plugins.h` — prototypes for plugin builtins.

### 32.3.3 Network, host, service, protocol built-ins
- `nasl/nasl_socket.c/.h`
- `nasl/nasl_http.c/.h`
- `nasl/nasl_http2.c/.h`
- `nasl/nasl_host.c/.h`
- `nasl/nasl_ssh.c/.h`
- `nasl/nasl_snmp.c/.h`
- `nasl/nasl_wmi.c/.h`
- `nasl/nasl_builtin_find_service.c`
- `nasl/nasl_builtin_openvas_tcp_scanner.c`

### 32.3.4 Packet forging/raw path
- `nasl/nasl_packet_forgery.c/.h`
- `nasl/nasl_packet_forgery_v6.c/.h`
- `nasl/nasl_frame_forgery.c/.h`
- `nasl/capture_packet.c/.h`
- `nasl/nasl_builtin_synscan.c`
- `nasl/nasl_raw.h`

### 32.3.5 Crypto/cert/auth
- `nasl/nasl_crypto.c/.h`
- `nasl/nasl_crypto2.c/.h`
- `nasl/nasl_crypt_helper.c`, `nasl/nasl_crypto_helper.h`
- `nasl/nasl_cert.c/.h`
- `nasl/nasl_signature.c/.h`
- `nasl/nasl_krb5.c/.h`
- `nasl/nasl_smb.c/.h`

### 32.3.6 SMB/NTLM and classic crypto support files
- `nasl/ntlmssp.c/.h`
- `nasl/smb_crypt.c/.h`, `nasl/smb_crypt2.c`
- `nasl/smb_signing.c/.h`
- `nasl/hmacmd5.c/.h`, `nasl/md4.c/.h`, `nasl/md5.c/.h`, `nasl/arc4.c`
- `nasl/genrand.c`, `nasl/time.c`, `nasl/charcnv.c`, `nasl/iconv.c/.h`

### 32.3.7 Text/misc utilities
- `nasl/nasl_misc_funcs.c/.h`
- `nasl/nasl_text_utils.c/.h`
- `nasl/nasl_cmd_exec.c/.h`
- `nasl/nasl_debug.c/.h`
- `nasl/nasl_isotime.c/.h`
- `nasl/nasl_func.c/.h`

### 32.3.8 Interfaces and stubs
- `nasl/openvas_smb_interface.h`, `nasl/openvas_wmi_interface.h`
- `nasl/smb_interface_stub.c`, `nasl/wmi_interface_stub.c`

### 32.3.9 Test scripts
- `nasl/tests/*.nasl`, `testsuiteinit.nasl`, `testsuitesummary.nasl`.

---

## 33. Производительность и тюнинг сканирования

## 33.1 Основные регуляторы throughput

1. `max_hosts` — горизонтальный параллелизм по хостам.
2. `max_checks` — вертикальный параллелизм VT на хост.
3. `plugins_timeout` и `scanner_plugins_timeout` — time-budget для VT.
4. `test_alive_hosts_only` — уменьшает waste на dead hosts, но добавляет pre-scan фазу.
5. feed/profile размер (`plugin_set`) — главный драйвер объема работы.

## 33.2 Риски агрессивного тюнинга

- высокий `max_checks` -> spikes SSH/TCP, рост timeout и ложных ошибок.
- высокий `max_hosts` -> saturation сети/таргетов и scanner-side contention.
- слишком жесткие timeout -> неполные результаты.
- слишком мягкие timeout -> медленный общий SLA.

## 33.3 Практические профили

### Профиль A: “Стабильный прод”
- умеренный `max_hosts`, `max_checks`;
- строгий alive-detection;
- conservative timeout;
- минимизация destructive VT.

### Профиль B: “Быстрый triage”
- уменьшенный `plugin_set` (discovery + high-value checks);
- сокращенные timeout;
- минимальный LSC и тяжёлых credentialed проверок.

### Профиль C: “Глубокий аудит”
- полный `plugin_set`;
- credentialed checks + LSC;
- увеличенные timeout;
- окно запуска в low-traffic периоде.

## 33.4 Где смотреть узкие места

1. `pluginlaunch.c`: waiting loops, timeout kills, saturation max_running_processes.
2. `attack.c`: host queue progression и alive-detection latency.
3. `network.c`/socket funcs: transport retries/errors.
4. `openvasd/scans/scheduling.rs`: backlog requested scans, slow transitions.
5. SQLite: growth `results`, slow queries/status updates.

## 33.5 Практические меры снижения нагрузки

- Сужать `plugin_set` под целевой use-case.
- Ограничивать `max_checks` при SSH-heavy сканах.
- Разделять крупные target-диапазоны на батчи.
- Использовать отдельные окна для credentialed и uncredentialed фаз.
- Следить за feed/scan mode consistency (без лишнего смешения контуров).

---

## 34. Матрица соответствия “задача -> модуль -> ключевые файлы”

| Задача | Модуль | Ключевые файлы |
|---|---|---|
| Запуск скана (C) | openvas runtime | `src/openvas.c`, `src/attack.c` |
| Планирование VT | plugin scheduler | `src/pluginscheduler.c`, `src/plugs_req.c` |
| Запуск VT процессов | launcher | `src/pluginlaunch.c`, `src/nasl_plugins.c` |
| NASL исполнение (C) | interpreter | `nasl/exec.c`, `nasl/nasl_init.c`, `nasl/nasl_scanner_glue.c` |
| Feed update (C) | plugin loader | `src/pluginload.c`, `nasl/*.c` |
| API daemon (Rust) | openvasd | `rust/src/openvasd/main.rs`, `openvasd/scans/*` |
| Feed sync (Rust) | vts orchestrator | `openvasd/vts/orchestrator.rs`, `vts/sql.rs`, `vts/redis.rs` |
| Scanner backend bridge | rust openvas | `rust/src/openvas/openvas.rs`, `openvas_redis.rs` |
| Host progress/status | state controller | `openvasd/scans/state_change.rs` |
| UI | GSA | `gsa/src/index.tsx`, `gsa/src/web/App.tsx` |

---

## 35. Чек-лист ревью изменений (для разработчиков)

Перед merge в scanner-контур:
1. Проверено, какой режим затрагивается: `ospd`, `openvas`, `openvasd`.
2. Проверены state transitions (`stored/requested/running/...`).
3. Проверено влияние на feed sync lock.
4. Проверена совместимость с Redis/SQLite схемой.
5. Проверено, не растет ли неконтролируемо SSH/network fanout.
6. Добавлены/обновлены тесты snapshot/unit/integration.
7. Обновлена документация (этот файл + эксплуатационные notes).


---

## 36. Пошаговая логика сканирования: кто что делает, что отправляет и куда передает

Ниже описан полный путь C‑контура (legacy) от запуска до завершения скана, включая alive‑detection и запуск VT. Если включен другой режим (`openvasd`/`ospd`), фактический старт отличается только уровнем управления, но внутри все равно упирается в эти же модули `openvas` + NASL.

## 36.1 Старт процесса

1. **`openvas` (CLI) получает `scan_id`**
- Файл: `src/openvas.c`.
- Действия: парсит аргументы, включает логирование, подготавливает окружение.
- Передача: сохраняет `scan_id` глобально (`scan_id.c`), переходит к `attack_network_init()`.

2. **`attack_network_init()` готовит скан**
- Файл: `src/openvas.c`.
- Действия:
  - Загружает prefs из конфигурации и дефолтов.
  - Инициализирует NVT cache (`plugins_cache_init`).
  - Настраивает канал LSC (`openvasd_server` или MQTT).
  - Подтягивает scan‑prefs из Redis (`overwrite_openvas_prefs_with_prefs_from_client`).
- Передача: возвращает управление в `openvas`, затем вызывает `attack_network()`.

## 36.2 Формирование цели и план VT

3. **`attack_network()` читает `TARGET` и `plugin_set`**
- Файл: `src/attack.c`.
- Действия:
  - Проверяет порт‑лист (`port_range`).
  - Строит scheduler (`plugins_scheduler_init` по `plugin_set`).
  - Резолвит/фильтрует хосты (exclude, reverse lookup, allow/deny).
- Передача: готовит список хостов и входит в основной цикл по хостам.

## 36.3 Alive‑detection (если включен)

4. **Запуск alive‑detection**
- Файл: `src/attack.c`.
- Условие: `test_alive_hosts_only = true`.
- Действия:
  - Создает отдельный поток `start_alive_detection(hosts)`.
  - Основной поток читает “живые” хосты через `get_host_from_queue()`.
- Что отправляет:
  - ICMP/TCP/ARP probes отправляет **Boreas** из `gvm-libs` (не в этом репозитории).
- Сколько отправляет:
  - Зависит от настроек Boreas (методы, порты, retries, таймауты).
- Передача:
  - Boreas кладет результаты в очередь (KB‑based queue), `attack.c` извлекает хосты.

### 36.3.1 Принцип работы Boreas (как именно “пингуются” хосты и как результат попадает в scan loop)

**Ключевой факт:** в C‑контуре alive‑detection не “NASL‑плагин”, а отдельный поток (pthread) из `libgvm_boreas`, который работает параллельно основному `attack_network()` и передает результаты через очередь в KB (Redis).

#### A) Старт потока и источник входных данных
- Место старта: `src/attack.c` внутри `attack_network()`:
  - происходит `pthread_create(&tid, NULL, start_alive_detection, (void*)hosts)`;
  - `hosts` — это `gvm_hosts_t*` (список/итератор целей, уже после resolve/exclude/reverse lookup/allow deny).
- Важно: перед передачей `hosts` в Boreas код сбрасывает итератор: `hosts->current = 0;` чтобы alive‑thread прошел по целям с начала.

#### B) Что именно делает Boreas на сети (на уровне методов)
Boreas выполняет **alive test** с набором методов (по настройкам), а не только “ICMP ping”:
- ICMP;
- TCP‑SYN ping;
- TCP‑ACK ping;
- ARP;
- комбинации методов.

Параметры, которые влияют на количество/частоту пакетов:
- `icmp_retries` — сколько ICMP‑пакетов посылается на хост в alive test;
- `icmp_grace_period` — пауза между ICMP‑пакетами;
- `test_alive_wait_timeout` — сколько ждать ответов после последнего пакета;
- `alive_test_ports` — порт‑лист для TCP SYN/ACK alive‑test.

Эти параметры документированы в `doc/man/openvas.8.in` и `doc/manual/openvas/openvas.md` и в рантайме приходят в `openvas` через prefs (`openvas.conf` и scan‑prefs из Redis).

#### C) Канал передачи результатов: очередь в main KB (Redis)
- Основной поток `attack_network()` открывает соединение с main KB и затем читает результаты через API Boreas IO:
  - `get_host_from_queue(alive_hosts_kb, &ad_finished)`.
- Семантика:
  - Boreas кладет “живые” хосты в очередь в KB.
  - `get_host_from_queue()` возвращает следующий `gvm_host_t*` из этой очереди.
  - Через `ad_finished` основной поток получает сигнал “alive‑detection завершен” (Boreas выставляет в очереди специальный finish‑marker).

Это типичный producer/consumer:
- producer: alive‑thread (Boreas) “пингует” и пушит найденные alive‑адреса;
- consumer: основной scan loop читает alive‑адреса и только их реально сканирует.

#### D) Как `attack_network()` превращает “строку/адрес” из очереди обратно в “объект цели”
В `src/attack.c` после чтения `host` из очереди есть нормализация:
- полученный объект сопоставляется с исходным списком целей `hosts` по IPv6‑адресу (`gvm_host_get_addr6` + `gvm_host_find_in_hosts`), чтобы сканер работал с оригинальным `gvm_host_t` из списка.

#### E) Что происходит при `allow_simultaneous_ips = no`
В режиме “не сканировать одновременно несколько IP одной сущности” есть отдельная логика:
- если из alive‑очереди пришел хост, который “уже сейчас” сканируется (`host_is_currently_scanned(host)`),
- то `attack_network()` **перекладывает его обратно в конец очереди**, чтобы не блокировать скан:
  - используются функции Boreas IO (`put_host_on_queue()`, `finish_signal_on_queue()`, `realloc_finish_signal_on_queue()`), которые работают с той же KB‑очередью.

Смысл: очередь остается “живой”, и хост просто “переедет” вниз, пока не станет допустимо начать его скан.

#### F) Остановка/завершение alive‑thread
Есть два ключевых механизма завершения:
1. Нормальное завершение:
   - в конце `attack_network()` вызывается `pthread_join(alive_detection_tid, ...)` и выставляется флаг “thread joined”.
2. Принудительная остановка при стоп‑сигнале скана:
   - в обработчике стопа (в `src/attack.c`) при включенном `test_alive_hosts_only` выполняется `pthread_cancel(alive_detection_tid)`, если поток еще не был joined.

Итоговая гарантия: основной поток не завершает скан “в середине” alive‑потока, и при stop‑scan не оставляет живущую фоновую активность.

### 36.3.2 Heartbeat во время скана (пере‑проверка живости)

Alive‑detection “до скана” решает задачу фильтрации dead hosts на старте, но во время длительного скана хост может умереть. Для этого есть heartbeat:
- Файл: `misc/heartbeat.c`.
- Функция: `check_host_still_alive(kb_t kb, const char *hostname)`.
- Условия:
  - heartbeat работает только если Boreas включен (`test_alive_hosts_only = yes`);
  - и если `ALIVE_TEST` задан валидно (иначе heartbeat отключается).
- Реализация:
  - вызывает Boreas CLI API `is_host_alive(hostname, &is_alive)`;
  - если `is_alive == 0`, то ставит `Host/dead = 1` в KB.

Эта часть предотвращает массовые таймауты VT при внезапно “отвалившемся” хосте.

## 36.4 Host‑процесс и запуск VT

5. **Создание host‑KB и fork host‑процесса**
- Файл: `src/attack.c`.
- Действия:
  - Создает отдельный KB для хоста (`kb_new`).
  - Форкает host‑процесс через `create_ipc_process()`.
- Передача:
  - `attack_start()` исполняется в child‑процессе.

6. **`attack_start()` (host‑процесс)**
- Файл: `src/attack.c`.
- Действия:
  - Регистрирует host‑KB в main‑KB.
  - Делает reverse‑lookup/vhost‑обработку.
  - Передает управление в `attack_host()`.

7. **`attack_host()` запускает VT**
- Файл: `src/attack.c`.
- Действия:
  - Инициализирует `pluginlaunch`.
  - Запрашивает следующий VT у `plugins_scheduler_next()`.
  - Для каждого VT вызывает `plugin_launch()`.
- Передача:
  - VT передается в `pluginlaunch.c` и далее в NASL executor.

## 36.5 Запуск NASL VT

8. **`plugin_launch()` создает процесс VT**
- Файл: `src/pluginlaunch.c`.
- Действия:
  - Проверяет доступные слоты, память и loadavg.
  - Вызывает `nasl_plugin_launch()`.
- Передача:
  - Старт NASL процесса -> `src/nasl_plugins.c`.

9. **`nasl_plugin_launch()`**
- Файл: `src/nasl_plugins.c`.
- Действия:
  - Загружает NASL скрипт.
  - Инициализирует NASL контекст.
  - Вызывает NASL интерпретатор.
- Передача:
  - Управление в `nasl/exec.c` (AST execution), built‑ins регистрируются через `nasl/nasl_init.c`.

10. **NASL выполняет сетевые действия**
- Файлы: `nasl/nasl_*`.
- Что отправляет:
  - ICMP/RAW пакеты: `nasl_packet_forgery*.c`, `nasl_builtin_synscan.c`.
  - TCP/UDP соединения: `nasl_socket.c`, `nasl_http.c`.
  - SSH/SMB/SNMP: `nasl_ssh.c`, `nasl_smb.c`, `nasl_snmp.c`.
- Сколько отправляет:
  - Определяет конкретный VT (скрипт). Количество пакетов/запросов зависит от логики VT.
- Передача результатов:
  - Через `plugutils` в Redis (`internal/results`, KB keys).

## 36.6 Завершение VT и host

11. **`pluginlaunch_wait*()` контролирует завершение VT**
- Файл: `src/pluginlaunch.c`.
- Действия:
  - Ждет child‑процессы, убивает по timeout.
  - Обновляет статус VT.

12. **Host‑процесс завершает работу**
- Файл: `src/attack.c`.
- Действия:
  - Логирует HOST_END.
  - Пишет host stats.
  - Освобождает scheduler.

## 36.7 Завершение скана

13. **Главный процесс ждет все host‑процессы**
- Файл: `src/attack.c`.
- Действия:
  - `hosts_read()` до завершения всех процессов.
  - Финальные метрики.

14. **Скан помечается `finished`**
- Файл: `src/attack.c`.
- Действия:
  - Запись статуса в KB (`set_scan_status("finished")`).

---

## 36.8 Что именно “пингует” и куда идут результаты

- Pre‑scan alive‑pings:
  - Отправляет Boreas (`gvm-libs`), запускается через `start_alive_detection()`.
  - Результаты -> очередь в main KB (Redis) -> читаются `src/attack.c` через `get_host_from_queue()` (producer/consumer модель).
  - Завершение alive‑фазы сигнализируется флагом `ad_finished` (finish‑marker в очереди).
  - При `allow_simultaneous_ips = no` хост может быть re‑queue’нут обратно в очередь (чтобы не блокировать scan loop).

- VT‑уровневые пинги:
  - Отправляют NASL built‑ins (packet forgery и synscan).
  - Результаты -> `plugutils` -> Redis `internal/results` + KB keys.

- Heartbeat‑alive checks (во время скана):
  - Отправляет Boreas (`is_host_alive()`), вызывается из `misc/heartbeat.c`.
  - Результаты -> KB key `Host/dead=1` (остановка/ускорение завершения хоста при массовых таймаутах).

---

## 36.9 Передача задач между модулями (сводка)

- `openvas.c` -> `attack.c` (start scan)
- `attack.c` -> `pluginscheduler.c` (выбор VT)
- `attack.c` -> `pluginlaunch.c` (запуск VT)
- `pluginlaunch.c` -> `nasl_plugins.c` (старт NASL)
- `nasl_plugins.c` -> `nasl/exec.c` + `nasl/nasl_init.c` (исполнение VT)
- `nasl/*` -> `misc/plugutils.c` -> Redis results/KB

---

## 36.10 Redis KB: ключи, статусы, очереди и формат scanprefs

В C‑контуре Redis используется как “шина состояния” и KB (knowledge base). Практически все модули сходятся в Redis через `kb_*` API.

### 36.10.1 Главные ключи уровня скана (main KB)

Используются в `src/openvas.c`, `src/attack.c`, `misc/plugutils.c`:
- `internal/<scan_id>/scanprefs`
  - список строк формата `pref_key|||pref_value`, которые до старта `openvas` кладет управляющая сторона (обычно `ospd-openvas` как OSPD клиент);
  - считывается и применяется в `overwrite_openvas_prefs_with_prefs_from_client()` (см. `src/openvas.c`), затем очищается `kb_del_items()`.
- `internal/<scan_id>`
  - строковый статус скана;
  - после загрузки scanprefs выставляется `ready`;
  - по завершению выставляется `finished` (см. `set_scan_status()` в `src/attack.c` и `send_message_to_client_and_finish_scan()` в `src/openvas.c`).
- `internal/ovas_pid`
  - PID лидера process-group openvas, используется для `scan-stop` (stop‑сигнал посылается через `killpg(pid, SIGUSR1)`).
- `internal/status`
  - прогресс‑строка для клиента, форматы см. ниже (36.11).
- `internal/results`
  - поток “событий/результатов” в виде строк с разделителем `|||` (форматы см. 36.11).

### 36.10.2 Host KB и доступность для OSPD

На каждый хост создается отдельная KB (Redis DB‑индекс):
- `kb_new(&host_kb, db_address)` создает host‑KB.
- Индекс host‑KB добавляется в main KB ключ `internal/dbindex` через `set_kb_readable()` (`src/attack.c`), чтобы управляющая сторона могла читать host‑KB.
- В host‑KB выставляются и используются ключи вроде:
  - `internal/scan_id=<scan_id>` (в `attack_start()`);
  - `Host/dead=1` (heartbeat/алгоритмы остановки хоста при dead host);
  - `general/script_stats` (если включен `log_whole_attack`).

### 36.10.3 Очередь alive‑detection (Boreas) в Redis

Когда включен `test_alive_hosts_only=yes`, Boreas живет как отдельный pthread и использует KB‑очередь:
- producer: alive‑thread (`start_alive_detection()`) пушит “живые” хосты;
- consumer: основной scan loop читает через `get_host_from_queue(alive_hosts_kb, &ad_finished)`.

Реализация очереди и finish‑marker находится в `gvm-libs` (не в этом репозитории), но семантика полностью видна на уровне вызовов в `src/attack.c`:
- `ad_finished` сигнализирует завершение alive‑фазы;
- при `allow_simultaneous_ips=no` возможен re‑queue хоста обратно (через Boreas IO API).

### 36.10.4 Формат scanprefs (`internal/<scan_id>/scanprefs`)

Загрузка выполняется в `src/openvas.c`:
- каждое значение из списка — строка `pref_key|||pref_value`;
- `pref_key` часто имеет форму, совместимую с “NVT preference”:
  - `OID:pref_id:<type>:<human_name>` (пример: `1.3.6...:3:checkbox:Do an ICMP ping`);
- для file‑prefs:
  - если третий компонент `:file...` и `pref_value` не пустой, то `pref_value` трактуется как base64;
  - `openvas` генерирует UUID, сохраняет файл в `globals->files_translation` через `store_file()`, а в prefs кладет UUID вместо base64.

Дополнительно:
- scanner‑only prefs (например те, что не должны задаваться клиентом) детектятся через `is_scanner_only_pref()` и игнорируются.
- после применения prefs список scanprefs удаляется: `kb_del_items(kb, key)`.
- затем выставляются:
  - `internal/<scan_id>=ready`,
  - `internal/ovas_pid=<pid>`.

---

## 36.11 Форматы сообщений в `internal/results` и `internal/status`

`internal/results` — главный канал “событий” к управляющей стороне (OSP/OSPd/Manager). Он пополняется из разных мест:
- `misc/plugutils.c`: функции `proto_post_*` (ALARM/LOG/ERRMSG/NOTE/WARNING и т.д.);
- `src/attack.c`: `message_to_client()`, ошибки валидации target/ports, сообщения alive/host‑deny;
- `src/pluginlaunch.c`: таймауты VT и “too many NVT_TIMEOUTs”;
- `misc/table_driven_lsc.c`: результаты Notus/table-driven LSC.

### 36.11.1 “Нормализованный” формат (через `proto_post_*`)

Генерируется в `misc/plugutils.c` (`proto_post_wrapped()`):
- `TYPE|||IP|||HOSTNAME|||PORT/PROTO|||OID|||ACTION|||URI`

Где:
- `TYPE`: `ALARM`, `LOG`, `ERRMSG`, `WARNING`, ...
- `IP`: IP хоста (строка)
- `HOSTNAME`: vhost/hostname (если есть)
- `PORT/PROTO`: например `443/tcp` или `general/tcp`
- `OID`: OID VT/NVT
- `ACTION`: текст результата (обычно с `\\n` в конце)
- `URI`: источник/путь/URL (иногда пусто)

### 36.11.2 Сообщения Notus/table-driven LSC

В `misc/table_driven_lsc.c` результат Notus публикуется также в `internal/results` совместимо с `TYPE|||...`:
- пример структуры: `ALARM|||<ip>|||<hostname>|||package|||<advisory_oid>|||<text>|||<uri>`
  - поле “порт/протокол” заменено на строку `package`.

### 36.11.3 `message_to_client()` (legacy/вспомогательные сообщения)

`src/attack.c:message_to_client()` формирует строку с `|||`, но поля частично дублируются (используется для быстрых ERRMSG/служебных сообщений):
- `TYPE|||IP|||IP|||PORT|||MSG||| |||MSG`

Практически это “диагностический канал” в том же `internal/results`. Управляющая сторона должна быть готова к тому, что не все источники сообщений строго следуют единому контракту.

### 36.11.4 Прогресс: `internal/status`

`src/attack.c` пушит прогресс‑строки:
- обычный формат: `<ip>/<curr>/<max>`
  - где `curr` — сколько VT уже запущено для текущего хоста,
  - `max` — сколько VT планируется запустить.
- специальная кодировка “host dead”:
  - `<ip>/0/-1`
  - используется, чтобы сигнализировать “хост мертв/не сканируется”.

---

## 36.12 Управление процессами VT (per-host) и условия остановки

Эта часть определяет “сколько параллельных действий” реально выполняется на хосте и почему скан может резко замедляться/ускоряться.

### 36.12.1 Параллелизм VT на хост

Файл: `src/pluginlaunch.c`:
- “жесткий потолок” параллельных VT‑процессов на хост: `MAX_PROCESSES = 32`.
- мягкий потолок из настроек: `max_checks` (читает `get_max_checks_number()`, зависит от `openvas.conf`).
- если `max_checks >= MAX_PROCESSES`, код принудительно ограничит до `MAX_PROCESSES - 1`.

### 36.12.2 Таймауты VT и убийство процессов

Файл: `src/pluginlaunch.c`:
- таймаут VT берется так:
  - сначала preference `timeout` у конкретного VT (`get_plugin_preference(oid, "timeout", 0)`),
  - иначе глобальные prefs:
    - `scanner_plugins_timeout` для `ACT_SCANNER`,
    - `plugins_timeout` для остальных.
- если VT жив и превысил timeout:
  - отправляется `ERRMSG` в `internal/results` (“NVT timed out after ... seconds”);
  - процесс убивается `terminate_process(pid)` и дополнительно `terminate_process(-pid)` (убить process-group, чтобы прибить дочерние процессы VT).

### 36.12.3 “Слишком много VT таймаутов” и heartbeat

Файл: `src/pluginlaunch.c`:
- если включен `max_vts_timeouts` и счетчик таймаутов достиг порога:
  - вызывается heartbeat: `check_host_still_alive(host_kb, hostname)` (`misc/heartbeat.c`);
  - если хост признан dead:
    - выставляется `Host/dead=1` в KB,
    - в `internal/results` добавляется сообщение “Host has been marked as dead. Too many NVT_TIMEOUTs.”

---

## 36.13 Table-driven LSC и Notus: как появляется “пакетный аудит” и куда уходят результаты

### 36.13.1 Откуда берутся `package_list_notus` и `release_notus`

Файл: `src/attack.c` (`call_lsc()`):
- `call_lsc()` читает из host‑KB:
  - `ssh/login/release_notus`
  - `ssh/login/package_list_notus`
- Эти ключи появляются после credentialed фазы (обычно VT вроде `gather-package-list.nasl` через SSH), которая:
  - логинится на хост,
  - собирает список пакетов,
  - кладет в KB данные для Notus/table-driven LSC.

### 36.13.2 Кто запускает Notus/table-driven LSC

Файл: `src/attack.c`:
- после получения package list / os release вызывается `run_table_driven_lsc(scan_id, ip, hostname, package_list, os_release)` из `misc/table_driven_lsc.c`.

### 36.13.3 Два режима доставки Notus: через `openvasd_server` или через MQTT

Файл: `src/openvas.c` (`attack_network_init()`):
- если в prefs задан `openvasd_server`:
  - включается `openvasd_lsc_enabled=yes`;
  - `run_table_driven_lsc()` пойдет “через openvasd” (режим RS Notus).
- иначе, если задан `mqtt_server_uri`:
  - выполняется `mqtt_init(...)` и выставляется `mqtt_enabled=yes`;
  - `run_table_driven_lsc()` пойдет через MQTT.

Файл: `misc/table_driven_lsc.c`:
- режим openvasd:
  - вызывает `call_rs_notus(...)` и публикует ALARM/LOG в `internal/results`.
- режим MQTT:
  - `mqtt_subscribe("scanner/status")`
  - `mqtt_publish("scanner/package/cmd/notus", <json_payload>)`
  - затем ожидает статусы (timeout 60s на сообщение):
    - сначала статус `running`,
    - затем статус `finished`;
  - иначе ошибка и завершение с `-1`.

### 36.13.4 Куда публикуются результаты Notus

Файл: `misc/table_driven_lsc.c`:
- результаты advisories транслируются в строки `ALARM|||...` и пушатся в `internal/results`.
- payload содержит список уязвимых пакетов и версии (installed/fixed), формируется в текстовом виде и отправляется управляющей стороне как обычный result-event.

---

## 36.14 Plugin Scheduler (`pluginscheduler.c`): как выбирается следующий VT и почему порядок именно такой

Сканер не “просто запускает все NASL подряд”: он строит scheduler на основе `plugin_set` и метаданных VT (NVTI), учитывая зависимости, категории и ограничения параллелизма.

### 36.14.1 Вход: список VT (`plugin_set`)

Источник:
- `src/attack.c`: `plugins_scheduler_init(prefs_get("plugin_set"), prefs_get_bool("auto_enable_dependencies"), &plugins_init_error);`

Формат:
- `plugin_set` — строка OID’ов, разделенных `;` (см. `plugins_scheduler_enable()` в `src/pluginscheduler.c`).

### 36.14.2 Добавление VT в scheduler (`plugin_add`)

Файл: `src/pluginscheduler.c`.

Порядок действий для каждого OID:
1. Дедупликация через `oids_table` (если уже добавлен — пропуск).
2. Чтение NVTI из кэша: `nvticache_get_nvt(oid)`.
3. Фильтр deprecated:
   - проверяется тег `deprecated` (если `"1"`, VT ни в scheduler, ни в deps не пойдет).
4. Определение категории: `nvti_category(nvti)`.
   - если категория вне `[ACT_INIT..ACT_END]`, это фатальная аномалия NVTI cache (ошибка “outdated/corrupted”).
5. Создание `struct scheduler_plugin`:
   - `plugin->oid = g_strdup(oid)`;
   - `plugin->running_state = PLUGIN_STATUS_UNRUN`;
   - вставка в `oids_table`.
6. Вставка в список категории: `sched->list[category] = g_slist_prepend(...)`.

### 36.14.3 Зависимости VT: автоподгрузка и заполнение deps list

Два режима:
- `autoload = true` (когда включен `auto_enable_dependencies`):
  - `plugin_add()` читает `nvti_dependencies(nvti)` как строку имен зависимостей;
  - резолвит имя -> OID через `names_table` и `nvticache_get_oid(name)`;
  - рекурсивно добавляет зависимость в scheduler (`plugin_add(...)`);
  - заполняет `plugin->deps` указателями на `dep_plugin`.
- `autoload = false`:
  - scheduler сначала добавляет только явно перечисленные OID;
  - затем отдельным проходом `plugins_scheduler_fill_deps()` строит `deps` для каждого VT через `nvticache_get_dependencies(plugin->oid)` и резолв в scheduler-объекты.

Практический смысл:
- при `autoload=true` scheduler расширяет `plugin_set` до “замкнутого” множества VT с зависимостями;
- при `autoload=false` зависимости учитываются только в порядке запуска, но сами VT не добавляются автоматически.

### 36.14.4 Проверка циклов зависимостей

Файл: `src/pluginscheduler.c`.

Перед началом скана выполняется `check_dependency_cycles()`:
- DFS-поиск циклов через `find_plugin_in_deps(...)`.
- При обнаружении цикла логируются имена/oid цепочки и scheduler не стартует (возврат `NULL` из `plugins_scheduler_init`).

### 36.14.5 Фазы запуска по категориям (`plugins_scheduler_next`)

Scheduler работает фазами (static `scheduler_phase`):
1. `ACT_INIT`
2. `ACT_SCANNER`
3. `ACT_SETTINGS .. ACT_GATHER_INFO`
4. `ACT_ATTACK .. ACT_FLOOD`
5. `ACT_END`

После завершения фазы выполняется `scheduler_phase_cleanup(...)`:
- освобождает `plugin->oid` и `plugin->deps` внутри уже пройденной фазы (экономия памяти на длинных сканах).

### 36.14.6 Почему иногда “вдруг” становится `max_checks = 1`

Файл: `src/pluginscheduler.c`, функция `get_next_in_range()`:
- для категорий `ACT_SCANNER`, `ACT_KILL_HOST`, `ACT_FLOOD`, `ACT_DENIAL` scheduler вызывает `pluginlaunch_disable_parallel_checks()`.
- это принудительно сереализует запуск VT на хосте (важно для тяжелых/опасных проверок и некоторых scanner‑плагинов).
- после выбора кандидата scheduler возвращает параллелизм в исходное значение через `pluginlaunch_enable_parallel_checks()` (если не вернул VT раньше).

### 36.14.7 Выбор конкретного “следующего” VT: deps-first и `PLUG_RUNNING`

Файл: `src/pluginscheduler.c`, функция `plugins_next_unrun()`:
- если VT имеет `PLUGIN_STATUS_UNRUN`, scheduler сначала пытается вернуть невыполненную зависимость из `plugin->deps`.
- если зависимостей нет или они уже завершены, VT сам становится `PLUGIN_STATUS_RUNNING` и возвращается.
- если по дереву зависимостей есть “кто-то еще RUNNING”, возвращается специальный sentinel `PLUG_RUNNING` (значение `((struct scheduler_plugin*)0x02)`).

Это и объясняет ветку в `src/attack.c`:
- если `plugins_scheduler_next()` вернул `PLUG_RUNNING`, host loop делает `usleep(50000)` и продолжает ждать.

### 36.14.8 Жизненный цикл `running_state`

Связка модулей:
- `pluginscheduler.c` выставляет `PLUGIN_STATUS_RUNNING` в момент выдачи VT “на запуск”.
- `src/attack.c` может выставить `PLUGIN_STATUS_DONE`, если VT пропускается (safe_checks, missing mandatory key, requirements не выполнены).
- `src/pluginlaunch.c` выставляет `PLUGIN_STATUS_DONE`, когда VT процесс реально завершен или убит по timeout.

---

## 36.15 Процессы, IPC и управление жизненным циклом дочерних процессов

В C‑контуре есть три уровня “родительства”:
- main scan process (`openvas --scan-start`);
- host processes (по одному на сканируемый хост);
- VT/NASL processes (по одному на запускаемый VT).

Все они создаются единым механизмом `create_ipc_process()` и общаются через IPC pipe‑контексты.

### 36.15.1 `create_ipc_process()` и IPC context cache

Файл: `src/processes.c`.

`create_ipc_process(func, args)` делает:
- лениво инициализирует глобальный список IPC контекстов `ipcc` (кэш активных pipe‑каналов);
- чистит “мертвые” контексты через `procs_cleanup_children()` (waitpid WNOHANG + `ipc_close`);
- форкает через `ipc_exec_as_process(IPC_PIPE, ec)`, где `ec` включает:
  - `pre_fn_call` (выполняется в child перед основной функцией),
  - `func` (основная функция child),
  - `post_fn_call` (выполняется в child после основной функции).

Есть retry при проблемах ресурсов:
- если fork/IPC не удался с `EMFILE` или `EAGAIN`, выполняется повтор после попытки закрыть fd (loop `retry:`).

### 36.15.2 Что делает child в `pre_fn_call()` (важно для корректности)

Файл: `src/processes.c`.

`pre_fn_call()` выполняется в дочернем процессе и делает:
- очищает наследованные IPC контексты и заново инициализирует локальные (чтобы child не держал лишние fd);
- настраивает child‑signal‑handlers (`SIGTERM/SIGINT/SIGQUIT -> make_em_die`, `SIGSEGV -> sighand_segv`, `SIGPIPE -> ignore`);
- сбрасывает MQTT состояние `mqtt_reset()` (чтобы fork не унаследовал некорректный клиент);
- включает/переинициализирует sentry `init_sentry()`;
- инициализирует RNG seed.

### 36.15.3 Завершение и убийство процессов

Файл: `src/processes.c`:
- `terminate_process(pid)`:
  - шлет `SIGTERM`, ждет, затем при необходимости шлет `SIGKILL`;
  - может вызываться с отрицательным PID, чтобы сигнал ушел в process-group (это активно используется в `pluginlaunch.c`).
- `procs_terminate_childs()`:
  - проходит по кэшу `ipcc` и завершает все не закрытые child‑процессы.

### 36.15.4 Как host loop “собирает” сообщения от VT (IPC consumer)

Файл: `src/attack.c`:
- перед запуском очередного VT вызывается чтение IPC:
  - `for each ctx in procs_get_ipc_contexts()->ctxs: read_ipc(args, &ctx);`
- `read_ipc()` дергает `ipc_retrieve(ctx, IPC_MAIN)` в цикле и получает строку.

Особенность реализации:
- строка может содержать несколько JSON-объектов подряд;
- код режет поток по символу `}` и каждую “JSON-часть” отдаёт в `process_ipc_data()`.

### 36.15.5 Что делает `process_ipc_data()` (перенос данных “вверх”)

Файл: `src/attack.c`.

В зависимости от типа сообщения:
- `IPC_DT_HOSTNAME`:
  - добавляет vhost в `host_vhosts` через `append_vhost(hostname, source)`;
  - тем самым влияет на список vhost’ов, который передается в последующие VT.
- `IPC_DT_USER_AGENT`:
  - обновляет глобальный User-Agent через `user_agent_set(...)` (из `misc/user_agent.c`);
  - это влияет на последующие HTTP-запросы.
- `IPC_DT_LSC`:
  - выставляет “LSC ready” флаг;
  - если `table_driven_lsc` включен и включен `mqtt_enabled` или `openvasd_lsc_enabled`, вызывает `call_lsc()` для текущего хоста.

---

## 36.16 OpenVAS IPC protocol (`ipc_openvas.*`): типы сообщений и кто их генерирует

IPC‑сообщения — это JSON-объекты с полем `type` и полезной нагрузкой. Кодировка/декодировка реализована в `misc/ipc_openvas.c` (через json-glib).

### 36.16.1 Типы IPC сообщений

Определено в [ipc_openvas.h](/home/malfade/Worl/cybersecurity/888000131/ak-shumkar-VM/misc/ipc_openvas.h):
- `IPC_DT_HOSTNAME` (1): `{type, source, hostname}`
- `IPC_DT_USER_AGENT` (2): `{type, user-agent}`
- `IPC_DT_LSC` (4): `{type, data_ready}`

### 36.16.2 Источник `IPC_DT_HOSTNAME`: NASL builtin `add_hostname()`

Файл: `nasl/nasl_host.c`.

NASL-скрипт может добавить vhost через builtin `add_hostname`:
- в текущем VT процессе вызывается `plug_add_host_fqdn(script_infos, lower, source)` (обновление локального списка vhost’ов);
- затем формируется IPC json:
  - `ipc_data_type_from_hostname(...)` -> `ipc_data_to_json(...)`;
- затем отправляется в host process:
  - `ipc_send(script_infos->ipc_context, IPC_MAIN, json, strlen(json))`.

Результат:
- host process получает `IPC_DT_HOSTNAME` и добавляет vhost в `host_vhosts`;
- последующие VT запускаются уже с расширенным списком vhost’ов.

### 36.16.3 Источник `IPC_DT_USER_AGENT`: первая попытка HTTP-запроса

User-Agent нужен NASL HTTP built-in’ам. В момент первого HTTP запроса:
- `nasl/nasl_http.c` и `nasl/nasl_http2.c` вызывают `user_agent_get(script_infos->ipc_context, &ua)`.
- `misc/user_agent.c:user_agent_get()`:
  - если глобальный UA еще не создан, он создается из preference “HTTP User-Agent” (для `globals_settings.nasl`) или формируется из vendor_version;
  - один раз отправляется IPC сообщение вверх через `ipc_data_type_from_user_agent()` -> `ipc_send(...)`.

Consumer:
- host process принимает `IPC_DT_USER_AGENT` и делает `user_agent_set(...)`.

Смысл:
- UA становится общим для всех последующих VT (новые VT процессы наследуют значение при fork).

### 36.16.4 Источник `IPC_DT_LSC`: NASL builtin `update_table_driven_lsc_data()`

Файл: `nasl/nasl_scanner_glue.c`.

Скрипт `gather-package-list.nasl` (или аналог) после сбора данных:
- пишет в host‑KB:
  - `ssh/login/package_list_notus`
  - `ssh/login/release_notus`
- отправляет IPC-флаг `LSC ready`:
  - `ipc_data_type_from_lsc(TRUE)` -> `ipc_send(...)`.

Consumer:
- host process получает `IPC_DT_LSC` и может немедленно запустить `run_table_driven_lsc()` (через `call_lsc()`), не дожидаясь окончания всех VT.

### 36.16.5 Где описан протокол

Файл: `doc/manual/openvas/openvas_ipc_protocol.md` содержит референсные примеры форматов JSON и общий принцип “pipes + ipc_send/ipc_retrieve”.

---

## 36.17 NASL VT lifecycle: от `plugins_scheduler_next()` до `exec_nasl_script()`

### 36.17.1 Старт VT: `plugin_launch()` -> `nasl_plugin_launch()`

Цепочка вызовов:
- `src/attack.c:launch_plugin()` выбирает VT и вызывает `src/pluginlaunch.c:plugin_launch(...)`.
- `plugin_launch()`:
  - ждет слот (`pluginlaunch_wait_for_free_process()`),
  - выделяет слот `processes[p]`,
  - считает timeout,
  - запускает VT через `src/nasl_plugins.c:nasl_plugin_launch(...)`.

### 36.17.2 `nasl_plugin_launch()` создает VT‑процесс с IPC

Файл: `src/nasl_plugins.c`.

Действия:
- формирует `struct script_infos`:
  - `ip`, `vhosts`, `globals`, `key` (host‑KB), `oid`, `name = nvticache_get_src(oid)`,
  - `ipc_context` будет установлен уже в child.
- форкает через `create_ipc_process(nasl_thread, &infos)`.

### 36.17.3 `nasl_thread()` (child) подготавливает окружение и запускает интерпретатор

Файл: `src/nasl_plugins.c`.

Ключевые шаги:
- делает VT процесс leader’ом группы: `setpgid(0,0)` (упрощает убийство VT дерева);
- сбрасывает/изолирует `nvticache` (`nvticache_reset`);
- сбрасывает ссылки на KB (`kb_lnk_reset(kb)` и `kb_lnk_reset(get_main_kb())`);
- устанавливает `setproctitle("openvas: testing <ip> (<script>)")`;
- (опционально) `drop_privileges`, если включено в prefs;
- запускает NASL: `exec_nasl_script(args, nasl_mode)`.

### 36.17.4 Где VT пишет результаты и как они уходят в Manager

VT (NASL) может:
- писать KB keys (в host‑KB) через `plug_set_key`/KB API;
- публиковать “сообщения результата” через `security_message/log_message/error_message2`:
  - это в итоге приводит к `misc/plugutils.c:proto_post_wrapped()` и пушу строки в `internal/results`.

### 36.17.5 Как VT влияет на последующие VT (динамические данные во время хоста)

Критические каналы влияния:
- vhost расширение: `add_hostname()` -> IPC_DT_HOSTNAME -> `append_vhost()` -> обновление `host_vhosts` -> следующие VT получат расширенный список vhost’ов.
- User-Agent: первый HTTP VT -> `user_agent_get()` -> IPC_DT_USER_AGENT -> `user_agent_set()` -> последующие HTTP VT используют тот же UA.
- Notus/table-driven LSC: `update_table_driven_lsc_data()` -> IPC_DT_LSC -> host process запускает `call_lsc()` и публикует результаты через `internal/results`.
