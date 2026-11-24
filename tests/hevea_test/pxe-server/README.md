# PXE + NBD boot server for RPi4 (Docker) — fully diskless

Sert les fichiers boot de l'image HAOS RPi4 via DHCP + TFTP, et exporte
**le disque entier** de l'image via NBD (qemu-nbd, TCP 10809). Le RPi4
boot sans SD avec l'image comme périphérique bloc racine : toutes les
partitions existent, donc **les mises à jour RAUC A/B fonctionnent**
(les écritures repartent dans `nbd/hevea_rpi4.img` sur le PC).

## Topologie validée (testée et fonctionnelle)

```
[RPi4] --ethernet--> [routeur] <--ethernet--> [groszordi 192.168.1.61 : serveur PXE/NBD]
                        |
              [lezordi en WiFi 192.168.1.104 : build + tests labgrid + stack app]
```

- Le **Pi4 ne boote en réseau que par son port Ethernet** (doc officielle).
- Seuls les **broadcasts DHCP/TFTP** exigent le même segment L2 filaire :
  le serveur PXE (dnsmasq/NBD) tourne donc sur une machine **filaire**
  dédiée (ici `groszordi`, atteignable en SSH). Le PC de test (`lezordi`)
  peut rester en WiFi : le trafic unicast (app :7030, VPN, SSH, NBD une
  fois booté) est routé normalement par le routeur.
- Le routeur ne doit PAS répondre aux requêtes PXE (chez nous il les
  ignore) : c'est notre dnsmasq qui attribuera 192.168.1.150 au RPi.
- Déploiement complet sur le RPi4 (extract + initramfs + rsync vers le
  serveur PXE + compose up + power-cycle via la prise HA + attente SSH) :
  `../../deploy-rpi4-image.sh` avec `PXE_SSH_HOST=groszordi` — voir
  `tests/README.md`. En local (serveur PXE sur le même PC), ne pas définir
  `PXE_SSH_HOST`.

## Prérequis hôte serveur PXE (groszordi, filaire)

```bash
# Interface filaire en IP fixe sur le LAN (réservation DHCP routeur pour le
# MAC de la carte, comme pour le RPi — ne PAS faire `ip addr add` à la main).
# Sur Fedora (lezordi) : aussi
sudo sysctl -w net.ipv4.conf.<iface>.rp_filter=0
sudo firewall-cmd --permanent --zone=trusted --add-interface=<iface>
sudo firewall-cmd --permanent --zone=trusted --add-port=10809/tcp
sudo firewall-cmd --reload
# Sur Ubuntu (groszordi) : ufw/firewalld inactifs par défaut, rien à faire.
# Ports à ouvrir dans tous les cas : 67/udp, 69/udp, 10809/tcp.
# docker + compose + rsync + mtools (mcopy) + sfdisk (util-linux).
```

Sans ça : `dnsmasq` démarre mais ne voit jamais les requêtes du RPi
(les DISCOVER sont vus par tcpdump mais jamais livrés aux sockets).

## Setup

```bash
cd tests/hevea_test/pxe-server

# 1. Extraire les fichiers boot depuis l'image RPi4 (pas besoin de root :
#    mtools/sfdisk suffisent)
#    -> tftp/ = partition boot + cmdline.txt diskless
#    -> nbd/hevea_rpi4.img = copie (reflink/sparse) de l'image, avec la
#       partition hassos-data growée à 8G (grow-data-partition.sh, appelé
#       automatiquement ; --no-grow pour sauter) : haos-expand ajuste l'ext4
#       au boot, 400MB ne suffiraient pas pour HA + les add-ons
./extract-boot-files.sh ../../../output_rpi4_64/images/hevea_rpi4-64-18.4.1.img

# 2. Construire l'initramfs diskless (build rpi4_64 terminé requis) :
#    busybox + nbd.ko + nbd-connect (cross-compilé) + /init -> tftp/initrd.gz
#    (2e arg = IP du serveur NBD, fallback compilé dans l'initramfs)
./make-initramfs.sh ../../../output_rpi4_64 192.168.1.61

# 3. dnsmasq.conf n'a plus besoin d'adaptation manuelle : interface= et
#    dhcp-option=66 sont passés en ligne de commande par entrypoint.sh qui
#    détecte l'IP de $PXE_IFACE (défaut enp6s0*, ex. enp0s31f6 sur groszordi)

# 4. Démarrer (down d'abord : un conteneur existant ne reprend pas les
#    nouveaux montages :z / user: "0:0")
PXE_IFACE=enp0s31f6 docker compose down && PXE_IFACE=enp0s31f6 docker compose up -d
# services : dnsmasq (DHCP+TFTP), nbd (nbdkit :10809), http (nginx :8880)

# 5. Power-cycle le RPi (prise HA) et suivre :
docker logs -f pxe-server-dnsmasq-1
# on doit voir : DHCPDISCOVER -> DHCPOFFER 192.168.1.150 (option 66)
#               -> DHCPREQUEST -> DHCPACK -> requêtes TFTP (start4.elf,
#               config.txt, cmdline.txt, Image, initrd.gz, dtb, overlays)
# puis du trafic TCP 10809 (NBD) quand l'initramfs se connecte.

# 6. Sur une autre machine (lezordi), pousser tout ça vers ce serveur et
#    power-cycler le RPi4 en une commande :
PXE_SSH_HOST=groszordi ../../deploy-rpi4-image.sh
```

> Disque plein sur le serveur PXE : l'image NBD fait 8G apparents mais est
> **sparse** (rsync --sparse, cp --sparse=always) — seules les écritures
> réelles du RPi4 (mises à jour RAUC, images docker) occupent du disque.

## Point clé : option 66, pas 67

Le ROM du Pi4 **ignore l'option 67 (bootfile)**. Il obtient le serveur
TFTP par, par ordre de priorité :
1. `TFTP_IP` dans la config EEPROM (`rpi-eeprom-config`)
2. **DHCP option 66 (tftp-server-name)** ← ce qu'on utilise
3. option 54 (server-id) si option 43 = « Raspberry Pi Boot »

Sans option 66, le Pi boucle sur DHCPDISCOVER sans jamais faire de
REQUEST ni de TFTP. Ensuite il fetch par TFTP, dans l'ordre :
`<serial>/start4.elf`, `<serial>/start.elf`, `config.txt`, `vl805.sig`,
`pieeprom.sig`, `recover4.elf`, `recovery.elf`, `start4.elf`, `start.elf`,
puis (via config.txt/cmdline.txt) `kernel8.img`, les dtbs, etc.

## Prérequis côté RPi4 (vérification headless, sans écran)

EEPROM **>= 2020-09-03** et `BOOT_ORDER` contenant `0x2` (NETWORK), lu de
droite à gauche : `0x1`=SD, `0x2`=NET, `0x4`=USB, `0xf`=restart. Défaut
usine `0xf41` = SD puis USB, **sans** réseau. Pour lire/modifier sans
écran, booter une fois depuis une SD avec Raspberry Pi OS Lite (SSH
préactivé) :

```bash
vcgencmd bootloader_version          # date de l'EEPROM (>= 2020-09-03)
vcgencmd bootloader_config           # contient BOOT_ORDER=...
sudo rpi-eeprom-config --out /tmp/boot.conf
sed -i 's/^BOOT_ORDER=.*/BOOT_ORDER=0xf21/' /tmp/boot.conf   # SD puis NET
sudo rpi-eeprom-config --apply /tmp/boot.conf
```

Debug headless : logs dnsmasq (`log-dhcp` + `log-queries`) et/ou UART
(GPIO14/15 = broches 8/10, adaptateur USB-TTL 3.3V,
`screen /dev/ttyUSB0 115200`, « Boot mode: NET (02) » avec `BOOT_UART=1`).

## Fichiers

| Fichier | Rôle |
|---------|------|
| `docker-compose.yml` | dnsmasq (DHCP+TFTP, host, `user: "0:0"`, `:z`) + nbd (qemu-nbd :10809, host) + nginx (HTTP, port hôte 8880) |
| `dnsmasq.conf` | DHCP (range, réservation MAC, `dhcp-option=66`) + TFTP ; `port=0` car 53 est pris par systemd-resolved |
| `extract-boot-files.sh` | copie la partition `hassos-boot` -> `tftp/` (+ cmdline.txt diskless + initramfs dans config.txt), image -> `nbd/hevea_rpi4.img` (growée), `hassos-system0` -> `http/` |
| `grow-data-partition.sh` | grow la partition `hassos-data` (GPT #8) pour remplir l'image (défaut 8G), sans root (sfdisk sur fichier) |
| `make-initramfs.sh` | assemble `tftp/initrd.gz` depuis le build rpi4_64 (busybox, `nbd.ko`, `nbd-connect` cross-compilé, `/init`) |
| `../../deploy-rpi4-image.sh` | déploiement complet : extract + initramfs + rsync vers `PXE_SSH_HOST` + compose up + power-cycle HA + attente SSH |
| `nbd-connect.c` | client NBD minimal (handshake newstyle + `NBD_SET_SOCK`/`NBD_DO_IT`) pour l'initramfs |
| `tftp/` | partition boot complète servie en TFTP + `initrd.gz` |
| `nbd/` | copie (reflink) de l'image disque exportée en NBD |
| `http/` | `hassos-system0.erofs` servi en HTTP (debug uniquement) |

## Comment boot le diskless complet

Le kernel HAOS rpi4 a tout en built-in sauf NBD : `CONFIG_BCMGENET=y`
(NIC), `CONFIG_IP_PNP_DHCP=y` (DHCP kernel via `ip=dhcp`),
`CONFIG_MSDOS_PARTITION=y` (les partitions du disque NBD sont vues,
`root=PARTUUID=...` marche), `CONFIG_EROFS_FS=y`, et
`CONFIG_BLK_DEV_NBD=m` (fourni dans l'initramfs).

Chaîne de boot :
```
ROM Pi4 --DHCP(option 66)--> dnsmasq --TFTP--> start4.elf, config.txt,
  cmdline.txt, Image, initrd.gz, dtb, overlays
kernel (ip=dhcp) -> /init de l'initramfs :
  insmod nbd.ko -> nbd-connect 192.168.1.101:10809 /dev/nbd0
  -> mount erofs /dev/nbd0pX -> switch_root /sbin/init
HAOS complet, racine sur le disque NBD (RAUC OK)
```

`extract-boot-files.sh` pose automatiquement dans `tftp/` :
- `config.txt` : ajout de `kernel=Image` + `initramfs initrd.gz followkernel`
  (original conservé dans `config.txt.haos`)
- `cmdline.txt` : `ip=dhcp root=/dev/nbd0p3 rootfstype=erofs ro rootwait ...`

Perf : via un dongle USB-Ethernet 100 Mb/s, compter quelques minutes de
boot (erofs compressé, seuls les blocs lus traversent le réseau). Un seul
RPi à la fois sur l'image (sinon corruption).

## Lancer les tests PXE

```bash
cd tests
source venv/bin/activate
export LG_HA_URL=http://raspberrypi4        # HA de la prise (on/off)
export LG_HA_TOKEN=<token HA longue durée>
export LG_RPI_SWITCH=switch.eve_energy
export LG_RPI_IP=192.168.1.150
pytest --lg-env hevea-rpi-pxe-strategy.yaml hevea_test/ -v
```
