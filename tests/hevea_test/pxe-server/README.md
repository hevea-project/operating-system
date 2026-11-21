# PXE boot server for RPi4 (Docker)

Sert les fichiers boot de l'image HAOS RPi4 via DHCP + TFTP + HTTP, pour
booter un RPi4 sans SD (diskless).

## Setup

```bash
cd tests/hevea_test/pxe-server

# 1. Extraire les fichiers boot depuis l'image RPi4 (nécessite sudo pour losetup)
sudo ./extract-boot-files.sh ../../../../output_rpi4/images/haos_rpi4-18.4.img

# 2. Éditer dnsmasq.conf : remplacer l'interface et la plage DHCP par ton LAN

# 3. Démarrer le serveur
docker compose up -d

# 4. Booter le RPi4 (pas de SD insérée, ou EEPROM en boot réseau)
```

## Prérequis côté RPi4 (vérification headless, sans écran)

Le boot réseau du Pi4 est dans l'EEPROM (2e étage) : il faut une EEPROM
**>= 2020-09-03** (tous les Pi4 vendus après ~2021 l'ont). Le `BOOT_ORDER`
doit contenir `0x2` (NETWORK) — lu de droite à gauche : `0x1`=SD, `0x2`=NET,
`0x4`=USB, `0xf`=restart. Le défaut usine `0xf41` = SD puis USB, **sans**
réseau.

Pour vérifier/modifier sans écran, booter une fois depuis une SD avec
Raspberry Pi OS Lite (SSH préactivé), puis en SSH :

```bash
vcgencmd bootloader_version          # date de l'EEPROM (>= 2020-09-03)
vcgencmd bootloader_config           # contient BOOT_ORDER=...
sudo rpi-eeprom-config --out /tmp/boot.conf
sed -i 's/^BOOT_ORDER=.*/BOOT_ORDER=0xf21/' /tmp/boot.conf   # SD puis NET
sudo rpi-eeprom-config --apply /tmp/boot.conf
# (si l'EEPROM est trop vieille : sudo rpi-eeprom-update -a, reboot)
```

Sans aucun OS, le debug se fait côté serveur PXE (`log-dhcp` dans dnsmasq :
on voit le DHCPDISCOVER du MAC du RPi, vendor-class `PXEClient:...`, puis
les requêtes TFTP) ou via l'UART (GPIO14/15 = broches 8/10, adaptateur
USB-TTL 3.3V, `screen /dev/ttyUSB0 115200`, messages « Boot mode: NET (02) »
avec `BOOT_UART=1` dans la config EEPROM).

## Fichiers

| Fichier | Rôle |
|---------|------|
| `docker-compose.yml` | dnsmasq (DHCP+TFTP) + nginx (HTTP), network_mode: host |
| `dnsmasq.conf` | config DHCP/TFTP/PXE |
| `extract-boot-files.sh` | extrait kernel/dtbs/cmdline/rootfs depuis le .img |
| `tftp/` | fichiers servis en TFTP (kernel8.img, *.dtb, cmdline.txt, config.txt) |
| `http/` | rootfs servie en HTTP (référencée par cmdline.txt) |

## Lancer les tests PXE

```bash
cd tests
source venv/bin/activate
export LG_HA_URL=http://homeassistant.local:8123
export LG_HA_TOKEN=<token HA longue durée>
export LG_RPI_SWITCH=switch.prise_rpi4
export LG_RPI_IP=<IP réservée pour le RPi>
pytest --lg-env hevea-rpi-pxe-strategy.yaml hevea_test/ -v
```
