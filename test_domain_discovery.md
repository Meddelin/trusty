# Улучшенный алгоритм поиска связанных доменов

## Что было исправлено

### Проблема
Старый алгоритм искал только в атрибутах `src` и `href` в HTML, что не находило домены, загружаемые динамически через JavaScript (например, `dpm-io-l44.dpm.lol`, `dpm-io-l64.dpm.lol`).

### Решение
Обновлённый `DomainDiscoveryService` теперь ищет домены в **5 разных местах**:

1. **HTML атрибуты**: `src=` и `href=`
2. **JavaScript строки**: `"https://domain.com"`, `'https://domain.com'`, `` `https://domain.com` ``
3. **Protocol-relative URLs**: `//cdn.example.com/file.js`
4. **Голые домены в JS**: `api.example.com` внутри JavaScript кода
5. **API вызовы**: `fetch()`, `axios()`, `XMLHttpRequest`

## Примеры найденных паттернов

### До обновления (только HTML атрибуты):
```html
<script src="https://cdn.example.com/app.js"></script>
<link href="https://fonts.example.com/style.css" rel="stylesheet">
```
✅ Найдёт: `cdn.example.com`, `fonts.example.com`

### После обновления (JS + HTML):
```javascript
// Теперь также находит из JavaScript:
fetch("https://api.example.com/data");
const domain = "analytics.example.com";
axios.get("//images.example.com/pic.jpg");
const cdn = 'cdn-' + region + '.example.com';
```
✅ Найдёт: `api.example.com`, `analytics.example.com`, `images.example.com`, `cdn-*.example.com`

## Для сайта dpm.lol

Теперь приложение сможет найти:
- `dpm-io-l44.dpm.lol`
- `dpm-io-l64.dpm.lol`
- `dpm-io-l13.dpm.lol`
- И другие поддомены, используемые в JavaScript

## Дополнительные улучшения

### Расширенный список игнорируемых доменов
Добавлены в игнор:
- Аналитика: Google Analytics, Tag Manager, DoubleClick
- Социальные сети: Facebook, Twitter, LinkedIn, Instagram, Pinterest, Reddit
- Реклама: Google Ads, AdRoll, Taboola, Outbrain
- CDN: Cloudflare, Akamai, Fastly
- Шрифты: Google Fonts, TypeKit

### Обработка поддоменов
Теперь находит **и** корневой домен **и** конкретные поддомены:
- Если найден `cdn.api.example.com` → добавит `example.com` И `api.example.com`
- Это помогает создать полную группу связанных доменов

## Как использовать

1. Откройте раздел **Split Tunneling**
2. Введите домен (например, `dpm.lol`)
3. Нажмите **Добавить**
4. Приложение автоматически:
   - Загрузит страницу
   - Проанализирует HTML и JavaScript
   - Найдёт все связанные домены
   - Предложит создать группу

## Тестирование

Чтобы протестировать:
1. Запустите приложение
2. Добавьте домен `dpm.lol` в Split Tunneling
3. Проверьте, какие домены были найдены в диалоге Discovery
4. Сравните с запросами в Network инспекторе браузера

## Известные ограничения

- Не может найти домены, генерируемые **после** выполнения JavaScript (нужен headless browser)
- Лучший способ найти ВСЕ домены - использовать мониторинг логов VPN (уже реализован в `_onLogLine`)
- Для максимальной точности: подключитесь к VPN, откройте сайт в браузере, и приложение автоматически предложит найденные домены из логов
