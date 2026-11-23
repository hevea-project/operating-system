# Hevea Integration Tests

Tests d'intégration pour valider que l'image HAOS Hevea fonctionne correctement,
sur QEMU (émulation x86_64) et sur Raspberry Pi 4 physique.

## Prérequis

```bash
cd tests
python3 -m venv venv
source venv/bin/activate
pip3 install -r requirements.txt
```

Générer le `usb.img` avec la clé SSH de test (pour QEMU) :

```bash
sudo ./hevea_test/make_usb_img.sh
```

## Lancer les tests sur QEMU (émulation x86_64)

```bash
# Depuis le dossier tests/
pytest --lg-env hevea-strategy.yaml hevea_test/ -v
```

L'image QCOW2 doit exister à `output_ova/images/hevea_ova-18.4.1.qcow2`
(relatif au dossier `tests/`).

## Lancer les tests sur Raspberry Pi 4 (physique)

1. Flasher l'image RPi4 sur une carte SD :
   ```bash
   # Adapter le chemin de l'image
   sudo dd if=output_rpi4_64/images/hevea_rpi4-64-18.4.1.img of=/dev/sdX bs=4M status=progress
   ```

2. Créer un `usb.img` avec la clé SSH de test et le monter sur le RPi
   (ou ajouter la clé manuellement dans `/mnt/data/tmp/authorized_keys`)

3. Configurer le DHCP pour donner une IP fixe au RPi

4. Lancer les tests :
   ```bash
   LG_RPI_IP=192.168.1.100 pytest --lg-env hevea-rpi-strategy.yaml hevea_test/ -v
   ```

> Note : labgrid ne substitue que les variables d'environnement préfixées
> `LG_` (via `!template` dans le YAML). Utiliser `LG_RPI_IP`, pas `RPI_IP`.

## Lancer uniquement les tests WiFi (RPi physique uniquement)

```bash
LG_RPI_IP=192.168.1.100 pytest --lg-env hevea-rpi-strategy.yaml hevea_test/test_wifi_rpi.py -v
```

## Structure des tests

| Fichier | Description | QEMU | RPi4 |
|---------|-------------|------|------|
| `test_hevea_bootstrap.py` | Boot, service hevea-gateway, repo, addons | oui | oui |
| `test_wifi_rpi.py` | WiFi scan, AP add-on, chipset Broadcom | non (skip) | oui |

## Clés SSH de test

- `test_ssh_key` : clé privée (ne pas commiter en prod)
- `test_ssh_key.pub` : clé publique injectée dans `usb.img`

## RPi4 physique — PXE (diskless, 100% automatisé)

Prérequis host PC :
1. Serveur DHCP+TFTP+HTTP (ex: dnsmasq) qui sert les fichiers boot de l'image RPi4
   (kernel, dtbs, cmdline.txt, config.txt, rootfs)
2. RPi4 sans SD, EEPROM en boot order réseau (ou boot SD d'abord)
3. Prise Matter dans Home Assistant pour l'alim du RPi

Lancement :
```bash
cd tests
source venv/bin/activate
export LG_HA_URL=http://homeassistant.local:8123
export LG_HA_TOKEN=<long-lived token HA>
export LG_RPI_SWITCH=switch.prise_rpi4
export LG_RPI_IP=192.168.1.100
pytest --lg-env hevea-rpi-pxe-strategy.yaml hevea_test/ -v
```

La stratégie : power off (HA) → power on (HA) → PXE boot → attente SSH → tests.
