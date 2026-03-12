# GSA Frontend — Правила безопасного рефакторинга

> Документ описывает обязательные правила при изменении фронтенда GSA (`src/gmp/`, `src/web/`).
> Нарушение любого из них может сломать аутентификацию, API-интеграцию или рендеринг.

---

## 1. Неприкосновенные зоны (НЕЛЬЗЯ ТРОГАТЬ без глубокого понимания)

### 1.1 Провайдеры в `App.tsx`

Файл `src/web/App.tsx` содержит **всю DI-систему** приложения.

```
ThemeProvider
  └─ GmpContext.Provider   ← Глобальный GMP-клиент (gmp.ts)
       └─ QueryClientProvider  ← React Query (сетевой кеш)
            └─ StoreProvider    ← Redux Store
                 └─ LanguageProvider  ← Интернационализация
                      └─ Routes        ← Всё приложение
```

**Правила:**
- ❌ Нельзя переставлять порядок провайдеров — он определяет доступность контекстов.
- ❌ Нельзя создавать второй `QueryClient` или второй `store`.
- ❌ Нельзя убирать `GmpContext.Provider` — все хуки `useGmp()` перестанут работать.
- ✅ Можно добавлять новые провайдеры **снаружи** от `ThemeProvider` или **внутрь** перед `Routes`.

---

### 1.2 Слой `src/gmp/` — GMP Protocol Client

Это единственный способ **общения с бэкендом** (`gsad`, `gvmd`).

| Директория | Назначение | Что нельзя трогать |
|---|---|---|
| `gmp/gmp.ts` | Фасад всех команд | Сигнатуры публичных методов |
| `gmp/commands/*.ts` | По одному файлу на операцию GMP | `execute()` и типы параметров |
| `gmp/models/*.ts` | Парсинг XML-ответов в объекты | Поля, которые читают страницы |
| `gmp/http/` | HTTP-транспорт | Логика аутентификации, токенов |

**Правила:**
- ❌ Нельзя напрямую вызывать `fetch()`/`axios` в компонентах — только через GMP-команды.
- ❌ Нельзя переименовывать методы `gmp.*` без обновления всех потребителей.
- ❌ Нельзя менять формат URL (`/api/`, `/gmp`) — они жёстко завязаны на `gsad`.
- ✅ Можно добавлять новые команды — создай файл в `gmp/commands/`, зарегистрируй в `gmp.ts`.

---

### 1.3 Redux Store (`src/web/store/`)

| Файл/директория | Что хранит |
|---|---|
| `store/usersettings/` | Текущий пользователь, timezone, isLoggedIn |
| `store/actions.ts` | `clearStore` — вызывается при logout |
| `store/index.ts` | Конфигурация store + middleware |

**Правила:**
- ❌ Нельзя читать/писать в store через `store.getState()` напрямую вне Redux — только `useSelector`/`useDispatch`.
- ❌ Нельзя удалять `clearStore` — он вызывается при каждом выходе из системы.
- ❌ Нельзя изменять структуру `usersettings` без обновления всех вызовов `selectIsLoggedIn`.

---

### 1.4 Маршрутизация (`src/web/Routes.tsx`)

Все **48+ маршрутов** используют `lazy()` для code splitting. Каждый маршрут — отдельный JS-бандл.

**Правила:**
- ❌ Нельзя удалять старые URL-пути (`/tasks`, `/scanners`, и т.д.) — на них могут быть закладки и внешние ссылки. Вместо удаления — добавь `redirect`.
- ❌ Нельзя убирать `LoggedInLayout` — он содержит `Authorized`, `SessionTracker`, `SessionObserver`.
- ✅ Новые роуты добавляй только через `lazy()` — синхронные `import` сломают code splitting.
- ✅ Переименование маршрута: создай redirect от старого к новому, потом добавь новый.

```ts
// ✅ Правильно — добавить redirect при переименовании маршрута
{
  path: 'old-tasks',
  loader: () => { throw redirect('/tasks'); },
},
{
  path: 'tasks',
  lazy: async () => ({
    Component: (await import('web/pages/tasks/TaskListPage')).default,
  }),
},
```

---

## 2. Безопасные зоны для изменений (UI/UX)

### 2.1 Безопасно изменять

| Зона | Файлы | Что можно делать |
|---|---|---|
| **Стили и темы** | `App.tsx` → `ThemeProvider`, `GlobalStyles.tsx` | Цвета, шрифты, токены темы |
| **Страницы (`pages/`)** | Файлы внутри директорий маршрутов | Разметка, порядок секций |
| **Компоненты (`components/`)** | Всё кроме `provider/` | Визуальное представление |
| **Локализация** | `gmp/locale/` | Строки/переводы |
| **Иконки** | `components/icon/` | Замена SVG иконок |
| **Публичные ресурсы** | `public/` | Логотип, favicon |

### 2.2 Изменение с осторожностью

| Зона | Риск | Рекомендация |
|---|---|---|
| `index.html` | Меняет точку входа | Следи за мета-тегами и `config.js` |
| `components/form/` | Много переиспользований | Обновляй props interface, проверяй через TypeScript |
| `components/dialog/` | 20+ диалогов на этой базе | Сначала прогони регрессию vizually |
| `web/hooks/` | Бизнес-логика в хуках | Не меняй возвращаемые типы |
| `vite.config.ts` | Сборка | Не трогай `outDir: 'build'` — он жёстко прописан в docker-compose |

---

## 3. Процесс рефакторинга (workflow)

### Шаг 1 — Изолируй изменение
Перед редактированием убедись что понимаешь **всех потребителей** компонента:
```bash
# Найти все места использования компонента
grep -r "from 'web/components/form/Form'" src/

# Найти все импорты модели
grep -r "from 'gmp/models/task'" src/
```

### Шаг 2 — TypeScript строг
```bash
# После изменения обязательно проверь типы
cd gsa/ && npx tsc --noEmit
```
Никаких `@ts-ignore` и `as any` — они маскируют настоящие ошибки.

### Шаг 3 — Проверь сборку
```bash
cd gsa/ && npm run build
# Должно завершиться без ошибок — exit 0
```

### Шаг 4 — Ручная проверка в браузере
После каждого значимого изменения прогони чек-лист:
- [ ] Страница логина открывается
- [ ] Вход с `test/test` работает
- [ ] Дашборд загружается
- [ ] Список Tasks и Scans отображается
- [ ] Один из детальных просмотров открывается
- [ ] Выход из системы работает

### Шаг 5 — Пересбери и задеплой
```bash
cd gsa/ && npm run build
docker-compose -f docker-compose.full.yml restart gsa
```

---

## 4. Правила для брендинга / white-label

Это самые частые изменения при форке. Всё ниже безопасно:

| Что менять | Где |
|---|---|
| Заголовок страницы | `public/index.html` → `<title>` |
| Логотип в шапке | `src/web/components/img/` или `public/img/` |
| Favicon | `public/img/favicon.svg` |
| Цветовая схема | `App.tsx` → `<ThemeProvider>` props |
| Название приложения | `gmp/locale/` — языковые файлы |
| CSS переменные | `web/components/layout/GlobalStyles.tsx` |

---

## 5. Запрещённые паттерны

```ts
// ❌ Прямой HTTP-запрос из компонента
const data = await fetch('/api/tasks');

// ❌ Доступ к gmp вне GmpContext
import gmp from '../../../App'; // глобальная переменная

// ❌ Синхронный import в Routes
import TaskListPage from 'web/pages/tasks/TaskListPage';

// ❌ Мутация Redux state напрямую
store.getState().usersettings.username = 'test';

// ❌ Hardcoded URL gsad/gvmd
const resp = await fetch('http://localhost:9392/gmp');
```

---

## 6. Архитектурная схема (напоминалка)

```
Browser
  └─ GSA (React SPA, nginx, :9393)
       └─ /gmp, /api/*  → proxy → gsad (:9392)
                               └─ GMP socket → gvmd
                                                └─ PostgreSQL
                                                └─ ospd-openvas
                                                      └─ openvasd (Rust)
                                                           └─ Redis
```

Фронтенд **никогда** не общается с `gvmd`, `openvasd`, или `ospd-openvas` напрямую. Только через `gsad`.

---

*Документ актуален для GSA v26.14.1 / GVM Stack 24.10*
