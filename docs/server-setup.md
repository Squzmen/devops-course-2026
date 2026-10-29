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
| devops | devops, sudo (+ docker с ПР № 7) | только ключ Ed25519 `~/.ssh/devops_vm` (хост), пароль нужен лишь для sudo | администрирование и деплой |
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

Проверка конфигурации: `scripts/audit.sh` (код возврата 0 — конфигурация соответствует документу).

## Замечания по стенду

- Хост: Windows 11 с включённой VBS/Virtual Machine Platform, поэтому VirtualBox работает через Hyper-V (режим NEM). С 2 vCPU гость периодически зависал (`soft lockup`, отставание таймера до 290 с), поэтому ВМ работает с **1 vCPU**.
- Снимки на работающей машине (`--live`) под NEM приводили к зависанию гостя, поэтому снимки создаются на выключенной ВМ: `sudo poweroff`, `VBoxManage snapshot devops-vm take <имя>`.
- Пароли учётных записей student и devops хранятся вне репозитория.
