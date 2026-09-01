# LiDAR Streamer

Стрим **задней камеры** и **LiDAR** с iPhone 14 Pro Max на ПК по Wi‑Fi. Телефон шлёт JPEG + depth; на ПК собирается цветное облако точек.

Собрать и поставить приложение на устройство можно только **на Mac с Xcode**. Этот репозиторий можно держать на Windows: исходники общие, `.xcodeproj` генерируется на Mac.

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

## 2. iOS-приложение (Mac)

1. Установите [Xcode](https://developer.apple.com/xcode/) и [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`).
2. Подключите iPhone 14 Pro Max, включите Developer Mode.
3. В каталоге `ios-app`:

```bash
xcodegen generate
open LiDARStreamer.xcodeproj
```

4. В Xcode: Signing & Capabilities → ваш Team. Bundle ID: `com.lidarstreamer.app`.
5. Run на устройстве (не на симуляторе).
6. Разрешите доступ к камере. Введите IP ПК и порт `9000`, нажмите **Старт**.

На экране: превью задней камеры, статус, fps и КБ/с.

## 3. Сборка в Codemagic

Конфиг: [`codemagic.yaml`](codemagic.yaml) в корне репозитория. Сборка идёт из `ios-app/` (`working_directory`); папка `pc-viewer/` в iOS-билд не входит. Изменения только в Python-просмотрщике сборку iOS не запускают.

1. В Codemagic: вкладка **Webhooks** → **Update webhook**.
2. Вкладка **codemagic.yaml** → ветка `main` → кнопка проверки конфига.
3. Start build → workflow **iOS compile (unsigned)**. Это проверка компиляции без Apple-подписи (симулятор). На телефон такой `.app` не ставится.

Подписанный IPA (**iOS IPA (signed)**) — только вручную, после [code signing](https://docs.codemagic.io/yaml-quick-start/building-a-native-ios-app/): Team settings → Code signing identities (сертификат + provisioning profile) с bundle id `com.lidarstreamer.app`. Нужен Apple Developer Program.

## Протокол

TCP, кадр: `uint32` BE (длина тела) + тело `LIDR` v1. В теле — JPEG RGB (~1280×720), raw-DEFLATE (не zlib-обёртка) depth Float32 в метрах, опционально confidence UInt8, intrinsics 3×3, pose 4×4 (camera→world, column-major). Частота около 12 fps.

## Ограничения этой версии

Нет записи на диск, нет накопления карты мира, нет передней камеры и HEVC/WebRTC. Задержка по Wi‑Fi обычно 80–200 мс.
