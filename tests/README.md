# Tests d'intégration HAOS Hevea (labgrid)

Tests labgrid qui valident que l'image HAOS Hevea fonctionne de bout en bout :
boot, service `hevea-gateway`, ajout du repo d'add-ons, installation des add-ons,
API Home Assistant, commissionnement (certificats OpenVPN, tunnel VPN), login HA
via le provider `command_line`, et WiFi (RPi4 uniquement).

Deux cibles :

| Cible | Stratégie | Comment |
|-------|-----------|---------|
| QEMU x86_64 (émulation) | `hevea-strategy.yaml` | image `output_ova/images/hevea_ova-*.qcow2` + `usb.img` (clé SSH) |
| Raspberry Pi 4 physique, **diskless (PXE + NBD)** | `hevea-rpi-pxe-strategy.yaml` | serveur PXE/NBD sur une machine **filaire dédiée** (`groszordi`, SSH) + prise Matter HA pour l'alim ; le PC de test peut être en WiFi |

## Setup

```bash
cd tests
python3 -m venv venv
source venv/bin/activate
pip3 install -r requirements.txt
```

Clé SSH de test (déjà commitée, usage tests uniquement) : `hevea_test/test_ssh_key`.

## QEMU (x86_64)

Prérequis : build OVA terminé (`output_ova/images/hevea_ova-18.4.1.qcow2`) et
`hevea_test/usb.img` généré (contient la clé publique de test) :

```bash
sudo ./hevea_test/make_usb_img.sh
pytest --lg-env hevea-strategy.yaml hevea_test/ -v --timeout=900
```

La stratégie QEMU démarre elle-même la VM (QMP), avec redirection des ports
80/8123/9000/22222 vers 8000/8123/19000/22222 sur l'hôte.

## Raspberry Pi 4 physique — boot PXE diskless (100 % automatisé)

Le RPi4 démarre **sans carte SD** : une machine **filaire dédiée** (ici
`groszordi`, 192.168.1.61, accessible en SSH) fait serveur DHCP + TFTP + NBD
(dossier `hevea_test/pxe-server/`, voir son README pour le détail) et exporte
**le disque entier** de l'image RPi4 en NBD. L'initramfs custom se connecte
en NBD (netlink `NBD_CMD_CONNECT`), expose chaque partition GPT en loop device
(read-write) et monte la racine erofs : les mises à jour RAUC A/B fonctionnent.

Seuls les broadcasts DHCP/TFTP doivent être sur le même segment L2 filaire :
le serveur PXE tourne donc sur `groszordi` (Ethernet), et le PC de test
(`lezordi`) peut rester en **WiFi** — le trafic unicast (app, VPN, SSH, NBD)
est routé par le routeur.

### Déployer une image sur le RPi4 (une commande)

```bash
cd tests
export LG_HA_URL=http://raspberrypi4 LG_RPI_SWITCH=switch.eve_energy LG_RPI_IP=192.168.1.150
export PXE_SSH_HOST=groszordi
./deploy-rpi4-image.sh                 # dernière image de output_rpi4_64/images/
./deploy-rpi4-image.sh --flash-sd ...   # en plus, dd l'image sur une SD depuis le RPi
./deploy-rpi4-image.sh --no-boot ...    # juste resynchroniser/démarrer le serveur PXE
```

Le script : power-off du RPi (prise HA) → `extract-boot-files.sh` (tftp/ +
copie NBD growée à 8G via `grow-data-partition.sh`) → `make-initramfs.sh`
(avec l'IP de groszordi) → `rsync --sparse -z` vers `groszordi` →
`docker compose up -d --force-recreate` en SSH → power-on → attente SSH
(22222) → affiche `/etc/os-release` + `rauc status`. `--flash-sd` sert
ensuite l`.img` sur le HTTP :8880 du serveur PXE et le `dd` sur `/dev/mmcblk0`
depuis le RPi4 lui-même.

Prérequis :

1. `groszordi` : filaire, IP fixe (réservation DHCP routeur), docker + compose,
   rsync, mtools ; ports 67/udp, 69/udp, 10809/tcp ouverts (ufw/firewalld
   inactifs). Le RPi4 a une réservation DHCP (MAC `dc:a6:32:14:63:44` →
   192.168.1.150, aussi dans `dnsmasq.conf`).
2. Une prise connectée dans Home Assistant pour alimenter le RPi4
   (ex. `switch.eve_energy`), plus un long-lived access token HA
   (fichier local `hevea_test/token`, **non commité**).
3. Build rpi4_64 terminé sur le PC de test (`output_rpi4_64/`).

### Lancer les tests

```bash
cd tests
source venv/bin/activate
# IP du PC de test vue par le RPi4 (WiFi OK, ex. 192.168.1.104) :
PC_IP=$(ip -4 -o addr show | awk '/wlp|enp/ && !/docker/ {print $4}' | cut -d/ -f1 | head -1)
export LG_RPI_IP=192.168.1.150            # IP fixe du RPi (réservation DHCP MAC)
export LG_HA_URL=http://raspberrypi4     # HA sur le réseau du RPi
export LG_HA_TOKEN=$(cat hevea_test/token)
export LG_RPI_SWITCH=switch.eve_energy    # prise Matter de l'alim du RPi
# Commissionnement e2e : la stack docker-compose du repo hevea (dossier docker/)
# doit tourner sur le PC de test, et le RPi doit pouvoir l'atteindre :
export HEVEA_APP_URL=http://$PC_IP:7030         # app, vue du PC
export HEVEA_GATEWAY_VM_URL=http://$LG_RPI_IP:9000 # portail gateway du RPi
export HEVEA_VM_APP_ADDR=http://$PC_IP:7030    # app_addr injecté dans l'addon
pytest --lg-env hevea-rpi-pxe-strategy.yaml hevea_test/ -v --timeout=900
```

> **Piège classique** : si l'IP du serveur PXE a changé depuis le démarrage
> du conteneur `dnsmasq`, le `cmdline.txt` servi au RPi contient l'ancienne IP
> du serveur NBD et le boot échoue (SSH jamais up). Le script de déploiement
> recrée toujours les conteneurs (`--force-recreate`), donc ce piège n'existe
> plus en passant par `deploy-rpi4-image.sh` ; en manuel :
> `ssh groszordi 'cd .../pxe-server && docker compose restart dnsmasq'`
> (l'entrypoint régénère `tftp/cmdline.txt` avec l'IP détectée courante).

La stratégie : power off via la prise HA → power on → boot PXE → attente SSH
(port 22222) → tests. Résultat constaté : **18/18 tests passent** (boot, SSH,
bootstrap gateway, repo + add-ons, HA API, commissionnement, VPN up, login
HA avec les credentials Hevea, WiFi + add-on AP). Sur QEMU, les tests WiFi
sont skippés (pas de chipset WiFi émulé).

> Labgrid ne substitue que les variables préfixées `LG_` (via `!template`).

## Commissionnement e2e

`test_commission_e2e.py` : login sur l'app (`admin@hevea.io` / `changeme` en
local), `POST /api/v1/commission` sur le portail gateway (port 9000), puis
vérification de l'add-on OpenVPN configuré, du tunnel up (IP 10.8.x.x, ping du
serveur VPN) et du login HA via `hevea-auth.py`. Le test reset l'onboarding HA
(stop → nettoyage de `.storage` → start) pour pouvoir recommissionner une
image déjà utilisée.

`test_commission_offline.py` : même flux de commissionnement, mais avec toute
la sortie Internet publique bloquée sur la cible (iptables : seules les plages
privées 10/8, 172.16/12, 192.168/16, 169.254/16 et lo passent, route par défaut
supprimée). Le commissionnement (portail → app → zip de config → add-on
OpenVPN → tunnel 10.8.x.x → login HA) ne doit utiliser que des adresses privées
— dans notre lab, l'app et le serveur VPN sont sur le LAN du PC hôte. Le bloc
est levé dans un `finally` même en cas d'échec. Note : le pull des images
d'add-ons au premier boot (ghcr.io) exige lui Internet ; le test bloque donc
après le bootstrap. Helpers partagés : `hevea_test/commission_common.py`.

## Fichiers

| Fichier | Rôle |
|---------|------|
| `conftest.py` | fixtures labgrid (target `main`, shell, helpers) |
| `hevea-strategy.yaml` | cible QEMU x86_64 |
| `hevea-rpi-pxe-strategy.yaml` | cible RPi4 physique en PXE (SSH + power HA) |
| `qemu_shell_strategy.py`, `hevea_rpi_pxe_strategy.py`, `hevea_rpi_power_driver.py`, `custom_timeout_ssh_driver.py` | drivers/stratégies custom |
| `hevea_test/` | les tests + `pxe-server/` (serveur DHCP/TFTP/NBD) |
| `hevea_test/token` | token HA local — **ne pas commiter** |

Non commités (générés) : `pxe-server/tftp/`, `pxe-server/nbd/`,
`pxe-server/http/`, `hevea_test/usb.img`.

## Debug

- RPi4 sans console série : le noyau envoie ses logs (et ceux de systemd via
  `systemd.log_target=kmsg`) en **netconsole UDP 6666** vers le PC :
  `docker exec pxecap tcpdump -i any -nn -l -A -s0 udp port 6666`
  (`pxecap` = conteneur netshoot en netns hôte, voir `docker-compose.yml` du pxe-server).
- Journaux des tests labgrid : `--lg-log=lg_logs`.
