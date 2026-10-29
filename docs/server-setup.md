# Конфигурация виртуальной машины devops-vm

Документ описывает, как восстановить конфигурацию сервера со снимка `01-clean-install`.
Команды с пометкой **[Хост]** выполняются на хостовой системе (Git Bash в Windows), с пометкой **[VM]** — на сервере.

## 1. Параметры машины

| Параметр | Значение |
|---|---|
| Гипервизор | Oracle VirtualBox 7.1.8 (Windows 11, работает через Hyper-V/NEM) |
| Имя ВМ | devops-vm |
| Гостевая ОС | Ubuntu Server 24.04.5 LTS (64-bit), без графической подсистемы |
| Оперативная память | 2048 МБ |
| Процессор | 1 vCPU (по таблице 2 требуется 2; с 2 vCPU гость под Hyper-V/NEM зависал, см. «Замечания по стенду») |
| Диск | 25 ГБ, VDI, динамически расширяемый |
| Прошивка | BIOS (UEFI не загружал вспомогательный ISO автоустановки) |
| Имя узла | devops-vm (FQDN `devops-vm.devops.local`) |

## 2. Сетевые интерфейсы

| Адаптер | Тип | Интерфейс в ВМ | Адрес | Назначение |
|---|---|---|---|---|
| 1 | NAT | enp0s3 | 10.0.2.15/24 (DHCP) | выход в Интернет, репозитории пакетов; SSH через проброс порта |
| 2 | Host-only («VirtualBox Host-Only Ethernet Adapter», 192.168.56.0/24) | enp0s8 | 192.168.56.102/24 (DHCP VirtualBox) | доступ с хоста напрямую: веб-сервер, имя devops.local |

Имя `devops.local` на хосте задаётся статической записью в `C:\Windows\System32\drivers\etc\hosts`:
```
192.168.56.102   devops.local
```
После правки выполнить `ipconfig /flushdns`.

## 3. Правило проброса портов

| Имя | Протокол | Адрес хоста | Порт хоста | Адрес гостя | Порт гостя |
|---|---|---|---|---|---|
| ssh | TCP | 127.0.0.1 | 2222 | — | **2222** (до усиления SSH было 22) |

```
# [Хост] при выключенной ВМ
VBoxManage modifyvm devops-vm --natpf1 delete ssh
VBoxManage modifyvm devops-vm --natpf1 "ssh,tcp,127.0.0.1,2222,,2222"
# при работающей ВМ то же через: VBoxManage controlvm devops-vm natpf1 ...
```
Внимание: на снимке `01-clean-install` sshd ещё слушает 22, поэтому до шага 5 правило должно вести на гостевой порт 22.

## 4. Учётные записи

| Имя | Группы | Аутентификация по SSH | Назначение |
|---|---|---|---|
| student | student, sudo | вход по SSH запрещён (`AllowUsers devops`); только консоль ВМ, пароль | учётная запись установки |
| devops | devops, sudo, docker | только ключ Ed25519 `~/.ssh/devops_vm` (хост), пароль нужен лишь для sudo | администрирование и деплой |
| root | — | вход запрещён (`PermitRootLogin no`), пароль заблокирован | — |

```
# [VM] от student
sudo adduser --gecos "" devops          # задать пароль devops
sudo usermod -aG sudo devops
# [Хост]
ssh-keygen -t ed25519 -C "devops-vm-key" -f ~/.ssh/devops_vm
ssh-copy-id -i ~/.ssh/devops_vm.pub -p 2222 devops@127.0.0.1
# [VM] проверка прав: ~/.ssh = 700, authorized_keys = 600
stat -c '%a %n' ~/.ssh ~/.ssh/authorized_keys
```
Блок для `~/.ssh/config` на хосте:
```
Host devops
    HostName 127.0.0.1
    Port 2222
    User devops
    IdentityFile ~/.ssh/devops_vm
    IdentitiesOnly yes
```

## 5. Служба SSH

Основной файл `/etc/ssh/sshd_config` не изменяется (эталонная копия `/etc/ssh/sshd_config.backup`).
Изменения вносятся в дополняющий файл `/etc/ssh/sshd_config.d/99-hardening.conf`:
```
Port 2222
PermitRootLogin no
PasswordAuthentication no
PubkeyAuthentication yes
PermitEmptyPasswords no
MaxAuthTries 3
LoginGraceTime 30
AllowUsers devops
X11Forwarding no
ClientAliveInterval 300
ClientAliveCountMax 2
```
Конфликтующие файлы: в `/etc/ssh/sshd_config.d/50-cloud-init.conf` (права 600, без sudo `grep` его не читает) была строка `PasswordAuthentication yes`. Файлы читаются по алфавиту, действует первое значение, поэтому строка закомментирована:
```
sudo sed -i "s/^PasswordAuthentication yes/#PasswordAuthentication yes/" /etc/ssh/sshd_config.d/50-cloud-init.conf
sudo sshd -T | grep passwordauthentication     # passwordauthentication no
```

Порядок применения (не закрывать текущую сессию!):
```
sudo cp /etc/ssh/sshd_config /etc/ssh/sshd_config.backup
sudo nano /etc/ssh/sshd_config.d/99-hardening.conf
sudo grep -r "PasswordAuthentication" /etc/ssh/sshd_config.d/ /etc/ssh/sshd_config
sudo sshd -t && echo "Конфигурация корректна"
sudo systemctl disable --now ssh.socket       # иначе порт задаёт юнит сокета (22)
sudo systemctl enable --now ssh.service
sudo systemctl restart ssh
sudo ss -tlnp | grep sshd                     # 0.0.0.0:2222
# затем изменить проброс порта (раздел 3) и проверить в НОВОМ терминале: ssh devops
```

## 6. Правила межсетевого экрана

Политики: `deny (incoming)`, `allow (outgoing)`, `deny (routed)`; журналирование `medium`.

| Порт | Действие | Комментарий |
|---|---|---|
| 2222/tcp (v4, v6) | LIMIT IN | SSH rate-limited (≥6 соединений за 30 с с одного адреса — блок) |
| 80/tcp (v4, v6) | ALLOW IN | HTTP (Nginx, ПР № 6) |
| 443/tcp (v4, v6) | ALLOW IN | HTTPS |

```
sudo ufw default deny incoming
sudo ufw default allow outgoing
sudo ufw limit 2222/tcp comment 'SSH rate-limited'   # правило ДО включения!
sudo ufw allow 80/tcp  comment 'HTTP'
sudo ufw allow 443/tcp comment 'HTTPS'
sudo ufw enable
sudo ufw logging medium
sudo ufw status verbose
```
Не использовать `ufw allow ssh`: имя `ssh` берётся из `/etc/services` и означает порт 22.

Полное доменное имя узла. Внимание: после автоустановки `/etc/hosts` оказался пустым, `sed` ничего не заменял; сначала нужно восстановить строки `127.0.0.1 localhost` и `127.0.1.1 devops-vm`, затем выполнить:
```
sudo hostnamectl set-hostname devops-vm
sudo sed -i 's/^127.0.1.1.*/127.0.1.1 devops-vm.devops.local devops-vm/' /etc/hosts
hostname -f                                    # devops-vm.devops.local
```

## 7. Снимки состояния

| Снимок | Момент создания | Состояние |
|---|---|---|
| 01-clean-install | 2026-10-30 01:17, ВМ выключена | чистая установка + apt upgrade, sshd на 22, только student |
| 02-keys-configured | 2026-10-30 01:20, live | учётная запись devops, ключ devops_vm, sshd ещё с паролями на 22 |
| 03-ssh-hardened | 2026-10-30 01:33, ВМ выключена | sshd усилен (2222, только ключи), NAT 2222→2222, UFW ещё выключен |
| pr5-final | 2026-10-30 01:46, ВМ выключена | резерв: итог ПР № 5 перед проверкой документации |
| 04-nginx-https | 2026-10-30 01:52, ВМ выключена | конфигурация восстановлена по документу с 01-clean-install; Nginx, HTTPS |
| 05-docker-compose | 2026-10-30 02:09, ВМ выключена | Docker Engine, проект ~/app (приложение + PostgreSQL), до настройки прокси |

Проверка конфигурации: `scripts/audit.sh` (код возврата 0 — конфигурация соответствует документу).

## 8. Веб-сервер

| Параметр | Значение |
|---|---|
| Пакет | `nginx` из репозитория Ubuntu (`sudo apt install -y nginx`), версия 1.24.0 |
| Конфигурация ресурса | `/etc/nginx/sites-available/devops-site`, ссылка в `/etc/nginx/sites-enabled/`; ссылка `default` удалена (файл сохранён) |
| Каталог ресурса | `/var/www/devops-site`, владелец `devops:devops`, каталог 755, файлы 644 (модель «владелец пишет, веб-сервер читает») |
| Сертификат | `/etc/ssl/certs/devops.crt`, `root:root`, 644, самоподписанный, CN и SAN `DNS:devops.local`, срок 365 дней |
| Закрытый ключ | `/etc/ssl/private/devops.key`, `root:root`, **600** (каталог `/etc/ssl/private` — 700) |
| Журналы | `/var/log/nginx/devops-site.access.log`, `/var/log/nginx/devops-site.error.log`; запросы блока перенаправления (порт 80) — в общем `/var/log/nginx/access.log` |
| Порты | 80 (только `return 301` на HTTPS), 443 (`ssl`, TLSv1.2 и TLSv1.3); правила UFW из раздела 6 уже их разрешают |

Восстановление:
```
sudo apt update && sudo apt install -y nginx
sudo mkdir -p /var/www/devops-site && sudo chown -R devops:devops /var/www/devops-site
sudo openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
  -keyout /etc/ssl/private/devops.key -out /etc/ssl/certs/devops.crt \
  -subj "/CN=devops.local" -addext "subjectAltName=DNS:devops.local"
sudo tee /etc/nginx/sites-available/devops-site >/dev/null <<'CONF'
server {
    listen 80;
    listen [::]:80;
    server_name devops.local;
    return 301 https://$host$request_uri;
}
server {
    listen 443 ssl;
    listen [::]:443 ssl;
    server_name devops.local;
    ssl_certificate     /etc/ssl/certs/devops.crt;
    ssl_certificate_key /etc/ssl/private/devops.key;
    ssl_protocols       TLSv1.2 TLSv1.3;
    root /var/www/devops-site;
    index index.html;
    location / {
        try_files $uri $uri/ =404;
    }
    error_page 404 /404.html;
    access_log /var/log/nginx/devops-site.access.log;
    error_log  /var/log/nginx/devops-site.error.log;
}
CONF
sudo ln -s /etc/nginx/sites-available/devops-site /etc/nginx/sites-enabled/
sudo rm /etc/nginx/sites-enabled/default
sudo nginx -t && sudo systemctl reload nginx
# [Хост] доверие к сертификату и доставка содержимого
scp devops:/etc/ssl/certs/devops.crt ~/devops.crt
scripts/deploy.sh
```
HSTS не включается: при самоподписанном сертификате браузер заблокирует ресурс без возможности продолжить.
Хост Windows: rsync запускается из MSYS2 (`C:\msys64`, `pacman -S rsync`), у которого свой `~/.ssh` — ключ `devops_vm`, `config` и `known_hosts` копируются туда, а `devops.crt` — в `~` MSYS2.

## 9. Контейнеризация

| Параметр | Значение |
|---|---|
| Docker Engine | 29.9.2 из официального репозитория `download.docker.com` (пакеты `docker-ce`, `docker-ce-cli`, `containerd.io`, `docker-buildx-plugin`, `docker-compose-plugin`), Compose v5.6.1; `docker.io` из Ubuntu не используется |
| Группа docker | только `devops` (имеет sudo; членство в docker равносильно root) |
| Проект | `/home/devops/app` (доставляется `rsync -avz --delete --exclude=.env app/ devops:app/` из `app/` репозитория) |
| Секреты | `/home/devops/app/.env`, владелец devops, права **600**, `POSTGRES_PASSWORD` = `openssl rand -hex 16`, создаётся только на сервере, в Git и образ не попадает |
| Сервисы | `app` — образ `devops-app:1.0` (python:3.12-slim, пользователь `app`, gunicorn :5000); `db` — `postgres:16-alpine` с healthcheck `pg_isready` |
| Публикуемые порты | `127.0.0.1:5000 -> app:5000`; порт 5432 не публикуется (доступ только из сети `app_backend`) |
| Сети и тома | сеть `app_backend` (bridge), именованный том `app_db_data` → `/var/lib/postgresql/data` |
| Перезапуск | `restart: unless-stopped` — после перезагрузки сервера оба контейнера поднимаются сами |
| Обратный прокси | в блоке 443 `/etc/nginx/sites-available/devops-site` — `location /app/` → `proxy_pass http://127.0.0.1:5000/` с заголовками Host, X-Real-IP, X-Forwarded-For, X-Forwarded-Proto |

Восстановление:
```
# [VM] Docker Engine по https://docs.docker.com/engine/install/ubuntu/
sudo install -m 0755 -d /etc/apt/keyrings
sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
sudo chmod a+r /etc/apt/keyrings/docker.asc
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | sudo tee /etc/apt/sources.list.d/docker.list
sudo apt-get update && sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
sudo usermod -aG docker devops          # затем новая SSH-сессия
# [Хост, MSYS2]
rsync -avz --delete --exclude=.env app/ devops:app/
# [VM]
cd ~/app && cp .env.example .env && chmod 600 .env
sed -i "s/^POSTGRES_PASSWORD=.*/POSTGRES_PASSWORD=$(openssl rand -hex 16)/" .env
docker compose up -d --build
# [VM] Nginx: добавить в блок 443 перед error_page
    location /app/ {
        proxy_pass http://127.0.0.1:5000/;
        proxy_set_header Host              $host;
        proxy_set_header X-Real-IP         $remote_addr;
        proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
sudo nginx -t && sudo systemctl reload nginx
```
Внимание: порт, опубликованный на `0.0.0.0` (`"5000:5000"`), доступен из сети в обход UFW — Docker добавляет DNAT в цепочки, которые обрабатываются раньше правил UFW. Публиковать только на `127.0.0.1`. `docker compose down -v` удаляет том с базой данных.

## Замечания по стенду

- Хост: Windows 11 с включённой VBS/Virtual Machine Platform, поэтому VirtualBox работает через Hyper-V (режим NEM). С 2 vCPU гость периодически зависал (`soft lockup`, отставание таймера до 290 с), поэтому ВМ работает с **1 vCPU**.
- Снимки на работающей машине (`--live`) под NEM приводили к зависанию гостя, поэтому снимки создаются на выключенной ВМ: `sudo poweroff`, `VBoxManage snapshot devops-vm take <имя>`.
- Пароли учётных записей student и devops хранятся вне репозитория.
