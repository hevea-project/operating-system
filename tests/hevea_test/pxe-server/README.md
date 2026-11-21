# PXE boot server for RPi4 (Docker)

Sert les fichiers boot de l'image HAOS RPi4 via DHCP + TFTP + HTTP, pour
booter un RPi4 sans SD (diskless).

## Setup

```bash
cd tests/hevea_test/pxe-server

# 1. Extraire les fichiers boot depuis l'image RPi4 (nécessite sudo pour losetup)
sudo ./extract-boot-files.sh ../../../../output_rpi4/images/haos_rpi4-18.4.img

# 2. Éditer dnsmasq.conf :
#      - interface=... -> TA vraie interface LAN (ip addr ; ex. wlp3s0 en WiFi)
#      - dhcp-range=... -> une plage de TON sous-réseau, sans l'IP du routeur
#        ni celle de ton PC (ici 192.168.1.100)
#      - dhcp-host=... -> réserve l'IP du RPi (MAC dc:a6:32:14:63:44)
#    Astuce : si ton routeur fait aussi serveur DHCP, désactive-le pendant
#    les tests ou exclut la plage 192.168.1.150-200 de son pool (sinon il
#    peut répondre au RPi sans option PXE).

# 3. Démarrer le serveur
docker compose up -d

# 4. Booter le RPi4 (pas de SD, boot réseau dans l'EEPROM) et suivre :
docker logs -f pxe-server-dnsmasq-1     # DHCPDISCOVER du RPi + requêtes TFTP
```

> Le conteneur dnsmasq tourne en root (`user: "0:0"`) pour pouvoir lire
> `dnsmasq.conf` même s'il est en 0600 chez toi — sinon : « cannot read
> /etc/dnsmasq.conf: Permission denied » en boucle.

## Limitation connue : boot diskless complet de HAOS

Le `cmdline.txt` stock de HAOS monte la racine avec
`root=PARTUUID=... rootfstype=erofs` : il attend la carte SD. Le kernel ne
peut pas monter un erofs/ext4 servi en HTTP, donc un boot 100% diskless
nécessite un **initramfs custom** qui télécharge `hassos-system0.erofs`
(servi dans `http/`) et le monte en loop. En attendant, ce serveur PXE
sert à valider le boot réseau (DHCP → TFTP → kernel) ; pour la suite de
tests complète sur RPi4, utiliser le boot SD + prise HA (on/off) :
`hevea-rpi-strategy.yaml`.

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
| `extract-boot-files.sh` | extrait kernel/dtbs/cmdline/config + l'erofs system depuis le .img |
| `tftp/` | fichiers servis en TFTP (kernel8.img, *.dtb, overlays/, cmdline.txt, config.txt) |
| `http/` | `hassos-system0.erofs` servi en HTTP (pour un futur initramfs diskless) |

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
