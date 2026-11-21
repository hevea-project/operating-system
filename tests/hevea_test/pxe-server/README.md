# PXE boot server for RPi4 (Docker)

Sert les fichiers boot de l'image HAOS RPi4 via DHCP + TFTP + HTTP, pour
booter un RPi4 sans SD (diskless).

## Topologie validée (testée et fonctionnelle)

```
[RPi4] --ethernet--> [routeur] <--ethernet(dongle USB)-- [PC 192.168.1.101]
                        |
                   (WiFi aussi, mais les broadcasts WiFi->eth ne passent pas)
```

- Le **Pi4 ne boote en réseau que par son port Ethernet** (doc officielle).
- Le PC doit être sur le **même segment L2 filaire** que le RPi (via le
  routeur) : les broadcasts DHCP PXE doivent passer dans les deux sens.
  Un PC uniquement en WiFi ne convient pas (le routeur ne forward pas les
  broadcasts WiFi->Ethernet).
- Le routeur ne doit PAS répondre aux requêtes PXE (chez nous il les
  ignore) : c'est notre dnsmasq qui attribuera 192.168.1.150 au RPi.

## Prérequis hôte (PC serveur PXE)

```bash
# Interface filaire du PC en IP fixe sur le LAN (ex. dongle USB enp6s0f4u1).
# /!\ ne PAS faire `ip addr add` à la main : NetworkManager la supprime au
# renouvellement DHCP. Faire une RESERVATION DHCP sur le routeur pour le MAC
# du dongle (58:ef:68:7d:2f:ca -> 192.168.1.101), comme pour le RPi.
# Sinon le RPi ARP pour l'IP de l'option 66 sans réponse -> pas de TFTP.
sudo sysctl -w net.ipv4.conf.enp6s0f4u1.rp_filter=0

# firewalld : autoriser DHCP(67)/TFTP(69) en entrée sur l'interface filaire
sudo firewall-cmd --permanent --zone=trusted --add-interface=enp6s0f4u1
# (ou --zone=<zone de l'iface> --add-port=67/udp --add-port=69/udp)
sudo firewall-cmd --reload
# sinon les DISCOVER du RPi sont vus par tcpdump mais jamais livrés
# aux sockets (vérifié avec des compteurs nft).
```

Sans ça : `dnsmasq` démarre mais ne voit jamais les requêtes du RPi.

## Setup

```bash
cd tests/hevea_test/pxe-server

# 1. Extraire les fichiers boot depuis l'image RPi4 (sudo pour losetup)
#    -> tftp/ = partition boot complète, http/ = hassos-system0.erofs
sudo ./extract-boot-files.sh ../../../../output_rpi4/images/haos_rpi4-18.4.img

# 2. Adapter dnsmasq.conf :
#      interface=...      -> interface filaire du PC (ip addr)
#      dhcp-option=66,... -> IP filaire du PC (192.168.1.101)
#      dhcp-host=...      -> réservation MAC du RPi -> 192.168.1.150

# 3. Démarrer (down d'abord : un conteneur existant ne reprend pas les
#    nouveaux montages :z / user: "0:0")
docker compose down && docker compose up -d

# 4. Power-cycle le RPi (prise HA) et suivre :
docker logs -f pxe-server-dnsmasq-1
# on doit voir : DHCPDISCOVER -> DHCPOFFER 192.168.1.150 (option 66)
#               -> DHCPREQUEST -> DHCPACK -> requêtes TFTP
```

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
| `docker-compose.yml` | dnsmasq (DHCP+TFTP, network_mode: host, `user: "0:0"`, mounts `:z`) + nginx (HTTP, port hôte 8880) |
| `dnsmasq.conf` | DHCP (range, réservation MAC, `dhcp-option=66`) + TFTP ; `port=0` car 53 est pris par systemd-resolved |
| `extract-boot-files.sh` | copie la partition `hassos-boot` -> `tftp/`, `hassos-system0` -> `http/hassos-system0.erofs` |
| `tftp/` | partition boot complète servie en TFTP |
| `http/` | `hassos-system0.erofs` servi en HTTP (port 8880) pour un futur initramfs diskless |

## Limitation connue : boot diskless complet de HAOS

Le `cmdline.txt` stock monte la racine avec `root=PARTUUID=... rootfstype=erofs`
: il attend la carte SD. Le kernel ne peut pas monter un erofs servi en
HTTP ; un boot 100% diskless nécessite un **initramfs custom** qui
télécharge `http://192.168.1.101:8880/hassos-system0.erofs` et le monte en
loop. En attendant, ce serveur PXE valide le boot réseau (DHCP -> TFTP ->
kernel) ; pour la suite de tests complète sur RPi4, utiliser le boot SD +
prise HA (on/off) : `hevea-rpi-strategy.yaml` avec `LG_RPI_IP=192.168.1.150`.

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
