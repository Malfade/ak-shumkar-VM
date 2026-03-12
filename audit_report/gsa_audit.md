# Полный аудит: Greenbone Security Assistant (GSA)

**Дата аудита:** 2026-03-10  
**Версия:** 26.14.1-dev1  
**Репозиторий:** https://github.com/greenbone/gsa  
**Лицензия:** AGPL-3.0-or-later  
**Путь на диске:** `/home/malfade/Worl/cybersecurity/888000131/ak-shumkar-VM/gsa/`

---

## 1. Что такое GSA и его роль в экосистеме

**Greenbone Security Assistant (GSA)** — это полноценный веб-интерфейс для управления системой сканирования уязвимостей.  
GSA является **фронтендом для GVM (Greenbone Vulnerability Manager)**, который в свою очередь управляет `openvasd` (движком сканера).

### Схема взаимодействия компонентов

```
[Browser]
    │
    ▼
[GSA — React SPA]       ← репозиторий, который мы клонировали
    │  (XML/HTTP запросы по GMP-протоколу)
    ▼
[gsad — C-сервер HTTP-прокси]   ← отдельный репозиторий greenbone/gsad
    │  (GMP-сокет)
    ▼
[gvmd — GVM Daemon]    ← управляет сканами через планировщик
    │  (OSP-сокет или REST API)
    ▼
[openvasd / ospd-openvas]    ← тот самый движок в ak-shumkar-VM
    │
    ▼
[NASL-скрипты + OV Feed]
```

> **Ключевой момент**: GSA общается с `gsad` по HTTP, `gsad` выступает прокси, транслируя запросы в GMP-протокол (XML over Unix socket). GSA **не** общается напрямую с `openvasd` REST API из этого репозитория.

---

## 2. Стек технологий (Technology Stack)

| Категория | Технология | Версия | Описание |
|---|---|---|---|
| **Фреймворк** | React | 18.3 | UI-фреймворк (Class + Functional components) |
| **Язык** | TypeScript | 5.9 | Строгая типизация |
| **Бандлер** | Vite | 7.x | Сборка и dev-сервер |
| **UI-компоненты** | Mantine | 8.x | Система React-компонентов (кнопки, формы, таблицы) |
| **Глобальный стиль** | @greenbone/ui-lib + styled-components | 6.3 | Фирменная тема + CSS-in-JS |
| **State** | Redux Toolkit + react-redux | 2.x / 9.x | Глобальное состояние |
| **Данные/Запросы** | @tanstack/react-query | 5.x | Кэш и синхронизация с сервером |
| **Роутинг** | react-router | 7.x | SPA-навигация |
| **Графики** | @visx/axis, @visx/shape + D3.js | 3.x | Чарты, графики, диаграммы |
| **Перетаскивание** | @dnd-kit | 6.x | Drag-and-drop виджеты дашборда |
| **Интернационализация** | i18next + react-i18next | 25.x | Локализация UI |
| **Дата/время** | dayjs | 1.x | Работа с датами |
| **Парсинг XML** | fast-xml-parser | 5.x | Разбор GMP XML-ответов |
| **XSS-защита** | dompurify | 3.x | Санация HTML-содержимого |
| **Тесты** | vitest + @testing-library/react | 4.x | Unit + Component тесты |
| **Линтер** | eslint + typescript-eslint | 9.x | Контроль качества кода |

---

## 3. Архитектура и структура файлов (Directory Layout)

```
gsa/
├── index.html                 # Входная HTML-точка SPA, монтирует React
├── vite.config.ts             # Конфиг Vite: алиасы, плагины, API-proxy
├── vitest.config.ts           # Конфиг тестов
├── tsconfig.json              # TypeScript конфигурация
├── eslint.config.js           # Конфиг линтера
├── i18next.config.ts          # Конфиг локализации
├── package.json               # Зависимости и npm-скрипты
│
├── public/                    # Статические файлы: логотипы, переводы (i18n JSON), favicon
│   └── locales/               # ← JSON-файлы переводов (en, de, ...)
│
└── src/
    ├── index.tsx              # Точка входа React: ReactDOM.createRoot + <App />
    │
    ├── gmp/                   # ═══ СЛОЙ ПРОТОКОЛА (GMP Client) ════════════════
    │   ├── gmp.ts             # Главный класс Gmp — фасад для всех команд
    │   ├── http/              # HTTP-клиент для запросов к gsad
    │   │   ├── http.ts        # fetch-обертка, обработка ошибок, access token
    │   │   └── utils.ts       # buildServerUrl, buildUrlParams
    │   ├── commands/          # 50+ GMP-команд (по одноименному ресурсу)
    │   │   ├── tasks.ts       # CRUD задач сканирования
    │   │   ├── targets.ts     # Управление целями
    │   │   ├── results.ts     # Получение результатов
    │   │   ├── reports.ts     # Отчеты
    │   │   ├── login.ts       # Аутентификация
    │   │   └── ...            # (alerts, credentials, nvts, scanners, users, ...)
    │   ├── models/            # TypeScript-модели сущностей (Task, Result, NVT, ...)
    │   ├── parser.ts          # Разбор XML-ответов GMP в JS-объекты
    │   ├── settings.ts        # Управление конфигурацией (localStorage, window.config)
    │   └── utils/             # Утилиты: identity, string, array, date
    │
    └── web/                   # ═══ СЛОЙ ПРЕДСТАВЛЕНИЯ (UI) ════════════════════
        ├── App.tsx            # Корневой компонент: провайдеры + Router
        ├── Routes.tsx         # Полная карта маршрутов SPA
        │
        ├── pages/             # Страницы по ресурсам (48 разделов)
        │   ├── start/         # Дашборд (Стартовая страница)
        │   ├── tasks/         # Управление задачами сканирования
        │   ├── reports/       # Просмотр и фильтрация отчетов
        │   ├── results/       # Результаты сканирований (уязвимости)
        │   ├── vulns/         # База уязвимостей (NVTs/CVEs)
        │   ├── targets/       # Цели сканирования
        │   ├── credentials/   # Учетные данные (SSH, SMB, SNMP, ...)
        │   ├── scanconfigs/   # Конфигурации сканирования
        │   ├── scanners/      # Управление сканерами
        │   ├── policies/      # Политики аудита
        │   ├── alerts/        # Уведомления/триггеры
        │   ├── schedules/     # Расписание сканирования
        │   ├── users/         # Управление пользователями
        │   ├── roles/         # Роли и права доступа
        │   ├── groups/        # Группы
        │   ├── reports/       # Отчеты + форматы отчетов
        │   ├── nvts/          # База проверок NVT
        │   ├── cves/          # База CVE
        │   ├── cpes/          # БД CPE (продукты)
        │   ├── hosts/         # Управление хостами
        │   ├── login/         # Страница входа
        │   ├── performance/   # Мониторинг производительности
        │   └── ...            # + audits, notes, overrides, tickets, ...
        │
        ├── components/        # Переиспользуемые UI-компоненты (38 групп)
        │   ├── chart/         # Графики (bar, donut, bubble, wordcloud, ...)
        │   ├── dashboard/     # Виджеты дашборда + DnD
        │   ├── form/          # Формы ввода (TextField, Checkbox, Select, ...)
        │   ├── dialog/        # Модальные диалоги
        │   ├── table/         # Таблицы + сортировка
        │   ├── icon/          # 90+ SVG иконок
        │   ├── powerfilter/   # Мощный UI фильтрации ресурсов
        │   ├── layout/        # Layout-компоненты (Flex, Grid, GlobalStyles)
        │   ├── bar/           # Верхняя навигация + тулбар
        │   ├── menu/          # Навигационное меню
        │   ├── error/         # ErrorBoundary + страницы ошибок
        │   ├── provider/      # Context-провайдеры (Gmp, Language)
        │   └── ...
        │
        ├── store/             # Redux-хранилище
        │   ├── index.js       # configureStore (RTK)
        │   ├── reducers.js    # Корневой reducer
        │   ├── usersettings/  # Настройки пользователя (timezone, username, filters)
        │   ├── entities/      # Кэш и CRUD-состояние для каждого ресурса
        │   ├── dashboard/     # Состояние виджетов дашборда
        │   └── feedStatus/    # Состояние фидов (версия, дата обновления)
        │
        ├── hooks/             # React-хуки (58 файлов)
        │   ├── useGmp.ts      # Хук для доступа к контексту Gmp
        │   ├── useFilters.ts  # Хук для управления фильтрами
        │   └── ...
        │
        ├── queries/           # React Query (TanStack) определения запросов
        ├── entities/          # HOC-компоненты с логикой загрузки для сущностей
        ├── entity/            # Общие компоненты для страниц единичной сущности
        ├── utils/             # Утилиты UI (форматирование, сортировка, ...)
        └── wizard/            # Мастер создания задачи (Task Wizard)
```

---

## 4. Ключевые архитектурные паттерны

### 4.1 GMP-клиент (Фасад + Команда)
Класс `Gmp` (`src/gmp/gmp.ts`) является **фасадом** над 50+ команд. Каждая команда — это класс для работы с одним типом ресурсов (Task, Report, NVT и т.д.), все они наследуются от `BaseCommand` и используют один HTTP-клиент. Этот паттерн **Command** изолирует бизнес-логику работы с API от UI.

### 4.2 Провайдеры контекста (Context API)
`GmpContext.Provider` прокидывает экземпляр `Gmp` через дерево компонентов. Хук `useGmp()` позволяет любому компоненту получить доступ к API-клиенту без prop-drilling.

### 4.3 Двухуровневый стейт-менеджмент
- **Redux** (RTK): для долгоживущего глобального состояния — авторизация пользователя, настройки, фильтры, конфигурация дашборда.
- **React Query**: для серверного состояния — кэш запросов, фоновое обновление данных, инвалидация кэша при мутациях.

### 4.4 Страница = Container + Presenter
Каждая страница (`pages/tasks/`, `pages/results/` и т.д.) как правило содержит:
- `ListPage`/`EntityPage` (загрузка данных, подписка на стор, обработка фильтров)
- `Component`/`Table`/`Row` (чистая презентация)

---

## 5. Безопасность (Security Audit)

| Аспект | Статус | Детали |
|---|---|---|
| **XSS защита** | ✅ | `dompurify` подключен для санации HTML из GMP-ответов |
| **Аутентификация** | ✅ | Token-based через `X-Token` заголовок, хранится в `localStorage` |
| **HTTP-proxy** | ✅ | Все запросы идут через `gsad` (C-прокси), не напрямую к gvmd |
| **CSP** | ⚠️ | Content-Security-Policy не управляется в GSA, зависит от `gsad` |
| **Авторизация** | ✅ | Проверка `capabilities` (прав) перед рендером UI-элементов |
| **Зависимости** | ⚠️ | 50+ npm-зависимостей, требует регулярного `npm audit` |
| **Секреты в коде** | ✅ | Нет хардкоженных секретов, конфигурация через `window.config` |
| **i18n XSS** | ✅ | Переводы из JSON-файлов (не из API), риск минимальный |

---

## 6. Как редактировать GSA для White-label

### Первоочередные изменения (бренд)
1. **Логотип и иконки**: `gsa/public/` — содержит `favicon.svg`, `greenbone-banner.svg`, `greenbone-login.png`. Здесь меняете бренд.
2. **Название в браузере**: `gsa/index.html` — строка `<title>`.
3. **Цветовая схема**: `@greenbone/ui-lib` → Mantine `ThemeProvider` в `App.tsx`. Можно переопределить через `theme` prop.
4. **Переводы**: `gsa/public/locales/` — JSON файлы переводов.
5. **Глобальные стили**: `web/components/layout/GlobalStyles.tsx`.

### Осторожно (ядро)
- Изменение `src/gmp/` требует понимания GMP-протокола.
- Добавление новых страниц через `web/Routes.tsx` → `web/pages/`.

---

## 7. Команды для разработки

```bash
# Установить зависимости
npm install

# Запустить dev-сервер (с указанием адреса gsad)
GSAD_HOST=http://localhost:9392 npm run dev

# Сборка production bundle
npm run build

# Запустить тесты
npm run test

# Lint
npm run lint
```

---

## 8. Резюме: где что лежит

| Что вам нужно изменить | Где это лежит |
|---|---|
| Логотип, favicon | `public/` |
| Название, lang | `index.html`, `public/locales/` |
| Цвета, тема | `App.tsx` → `ThemeProvider` / `@greenbone/ui-lib` |
| Навигация / маршруты | `src/web/Routes.tsx` |
| Страница X | `src/web/pages/X/` |
| Переиспользуемый компонент | `src/web/components/` |
| Запросы к API | `src/gmp/commands/` |
| Типы/модели данных | `src/gmp/models/` |
| Глобальный стор | `src/web/store/` |
| Хуки | `src/web/hooks/` |
