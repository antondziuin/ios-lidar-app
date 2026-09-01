# LiDAR Streamer

Стрим **задней камеры** и **LiDAR** с iPhone 14 Pro Max на ПК по Wi‑Fi. Телефон шлёт JPEG + depth; на ПК собирается цветное облако точек.

Собрать IPA можно в Codemagic; на свой iPhone без платной подписки ставится через Sideloadly (7 дней) или через Xcode на Mac.

Нужен реальный iPhone с задним LiDAR. Симулятор не подойдёт.

## Что в репозитории

- `ios-app/` — SwiftUI + ARKit, TCP-клиент
- `pc-viewer/` — Python TCP-сервер: окно RGB (OpenCV) и облако точек (Open3D)

Порт по умолчанию: `9000`. Телефон и ПК должны быть в одной сети (не гостевой Wi‑Fi с изоляцией клиентов).

## 1. Просмотрщик на ПК

Python 3.10–3.12 (Open3D на 3.13 может не ставиться):

```powershell
cd pc-viewer
python -m venv .venv
.\.venv\Scripts\activate
pip install -r requirements.txt
python test_protocol.py
python viewer.py --port 9000
```

Узнать IPv4 ПК: `ipconfig`. В приложении на телефоне укажите этот адрес.

Разрешить входящий TCP 9000 в брандмауэре Windows:

```powershell
netsh advfirewall firewall add rule name="LiDAR Streamer" dir=in action=allow protocol=TCP localport=9000
```

Выход из просмотрщика: `q` или `Esc`.

## 2. Поставить на свой iPhone (без платного Developer Program)

IPA из Codemagic **не подписан**. На телефон его ставит [Sideloadly](https://sideloadly.io/) с обычным Apple ID. Срок **7 дней**, потом поставить заново.

1. В Codemagic запустите workflow **iOS device IPA (unsigned)** (или дождитесь автосборки после пуша в `main`).
2. Скачайте артефакт `LiDARStreamer-unsigned.ipa`.
3. На iPhone: **Настройки → Конфиденциальность и безопасность → Режим разработчика** — включить, перезагрузить.
4. На Windows установите [Sideloadly](https://sideloadly.io/) и [Apple Devices](https://apps.microsoft.com/detail/9np83lwlpz9k) (или iTunes).
5. Подключите iPhone кабелем, в Sideloadly: IPA, свой Apple ID, Start.
6. На телефоне: **Настройки → Основные → VPN и управление устройством** — доверить своему Apple ID. При первом запуске разрешить камеру.

Дальше: ПК и телефон в одной Wi‑Fi, на ПК `python viewer.py --port 9000`, в приложении IP компьютера и **Старт**.

Если есть Mac, надёжнее Xcode: `cd ios-app && xcodegen generate && open LiDARStreamer.xcodeproj` → Signing = ваш Apple ID (Personal Team) → Run на устройстве. Тоже 7 дней.

## 3. Сборка в Codemagic

Конфиг: [`codemagic.yaml`](codemagic.yaml) в корне. Сборка из `ios-app/`; `pc-viewer/` не собирается.

Нужный workflow для телефона: **iOS device IPA (unsigned)** — IPA под реальное устройство, без Apple Developer Program. На iPhone ставится через Sideloadly (см. выше).

**iOS IPA (signed)** — только если есть платный Developer Program и сертификаты в Codemagic.

## Протокол

TCP, кадр: `uint32` BE (длина тела) + тело `LIDR` v1. В теле — JPEG RGB (~1280×720), raw-DEFLATE (не zlib-обёртка) depth Float32 в метрах, опционально confidence UInt8, intrinsics 3×3, pose 4×4 (camera→world, column-major). Частота около 12 fps.

## Ограничения этой версии

Нет записи на диск, нет накопления карты мира, нет передней камеры и HEVC/WebRTC. Задержка по Wi‑Fi обычно 80–200 мс.
