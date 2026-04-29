# naive-proxy

Минимальная обвязка для запуска [NaïveProxy](https://github.com/klzgrad/naiveproxy)
сервера в Docker: Caddy + плагин `forwardproxy@naive` с автоматическими
TLS‑сертификатами Let's Encrypt.

Предоставляется один скрипт `setup.sh`, который:

1. Устанавливает Docker и плагин Compose, если их нет.
2. Запрашивает параметры (домен, e‑mail, логин, пароль).
3. Генерирует `.env` и `Caddyfile`.
4. Поднимает контейнер `naive-proxy` через `docker compose`.
5. Печатает строку подключения вида `naive+quic://USER:PASS@DOMAIN:443?padding=true`.

## Требования

- VPS с Linux (Ubuntu 20.04+/Debian 11+/CentOS 8+/Alpine).
- Свободные порты `80/tcp`, `443/tcp`, `443/udp` (UDP — для HTTP/3 / QUIC).
- Публичный IP **или** A‑запись DNS, указывающая на сервер.
- Права root (или возможность `sudo`).

> Для быстрого старта без своего домена скрипт использует
> [`nip.io`](https://nip.io) — wildcard‑DNS, который превращает
> `1.2.3.4.nip.io` в IP `1.2.3.4`. Этого достаточно для Let's Encrypt.

## Быстрая установка

```bash
curl -fsSL https://raw.githubusercontent.com/vmhlov/naive-proxy/main/setup.sh -o setup.sh
sudo bash setup.sh
```

Либо клонировать и запустить локально:

```bash
git clone https://github.com/vmhlov/naive-proxy.git
cd naive-proxy
sudo bash setup.sh
```

В неинтерактивном режиме параметры можно передать через окружение:

```bash
sudo DOMAIN=proxy.example.com \
     EMAIL=admin@example.com \
     PROXY_USER=alice \
     PROXY_PASS='S3cret_pass' \
     bash setup.sh
```

## Параметры (`.env`)

| Переменная   | Назначение                                                                 |
|--------------|----------------------------------------------------------------------------|
| `DOMAIN`     | FQDN, на который выпускается сертификат (`example.com` или `1.2.3.4.nip.io`). |
| `EMAIL`      | Контакт для Let's Encrypt (используется для уведомлений об истечении).     |
| `PROXY_USER` | Логин Basic‑Auth. Без `:`, `@`, `/`, `\`, пробелов.                        |
| `PROXY_PASS` | Пароль Basic‑Auth. Те же ограничения, что и для логина.                    |
| `TZ`         | Опционально, часовой пояс контейнера. По умолчанию `Etc/UTC`.              |

## Управление

```bash
docker compose ps                # статус
docker compose logs -f           # логи
docker compose pull && docker compose up -d   # обновить образ
docker compose down              # остановить
```

Конфигурация Caddy лежит в `Caddyfile` (создаётся `setup.sh` из
`Caddyfile.example`). После ручного редактирования примените изменения:

```bash
docker compose restart
```

## Подключение клиентом

Скрипт после успешного запуска печатает ссылку формата

```
naive+quic://USER:PASS@DOMAIN:443?padding=true#Naive
```

Эту ссылку понимают официальные клиенты [naiveproxy](https://github.com/klzgrad/naiveproxy/releases),
[NekoBox](https://github.com/MatsuriDayo/NekoBoxForAndroid) и большинство
других клиентов на базе sing‑box. Логин/пароль в ссылке URL‑encoded — копировать
строку **целиком**.

## Локальная сборка образа (опционально)

Если хочется не зависеть от внешнего реестра, в репозитории есть `Dockerfile`,
собирающий Caddy + naive плагин через [xcaddy](https://github.com/caddyserver/xcaddy).
В `docker-compose.yml` достаточно раскомментировать секцию `build:` и
закомментировать `image:`:

```yaml
services:
  naive-proxy:
    # image: pocat/naiveproxy:latest
    build: .
    # ...
```

Затем:

```bash
docker compose build
docker compose up -d
```

## Безопасность

- `.env` и `Caddyfile` содержат пароль — `setup.sh` ставит на них `chmod 600`.
  Не коммитьте их (см. `.gitignore`).
- Caddy включает `hide_ip`, `hide_via` и `probe_resistance` — стандартные
  меры NaïveProxy против активного зондирования.
- Для смены пароля отредактируйте `.env`, запустите `setup.sh` повторно
  (он пересоздаст `Caddyfile`) и выполните `docker compose restart`.

## Лицензия

См. upstream проекты:
[NaïveProxy (BSD‑3)](https://github.com/klzgrad/naiveproxy/blob/master/LICENSE),
[Caddy (Apache‑2.0)](https://github.com/caddyserver/caddy/blob/master/LICENSE).
Скрипты этого репозитория распространяются под MIT (см. `LICENSE`).
