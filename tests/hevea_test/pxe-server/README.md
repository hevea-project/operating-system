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
export HA_TOKEN=<token HA>
export RPI_SWITCH=switch.prise_rpi4
export RPI_IP=<IP réservée pour le RPi>
pytest --lg-env hevea-rpi-pxe-strategy.yaml hevea_test/ -v
```
