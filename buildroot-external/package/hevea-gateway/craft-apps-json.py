#!/usr/bin/env python3
"""Craft the Supervisor apps.json pre-install entries for the Hevea add-ons.

The Supervisor cannot install add-ons while the host is offline (its install
job always pulls the image from the registry), so the add-ons are baked as
already installed in the data partition: this generates the apps.json entries
that Supervisor's AppsData.install() would have written on a successful
install:

- system[slug] = the parsed add-on config.yaml + repository
- user[slug]   = version + image + default options

The installed slug is "local_<slug>": the Supervisor prefixes store slugs with
the repository slug, and the baked add-on definitions live in the Supervisor
built-in "local" repository (its local apps directory).

Usage: craft-apps-json.py <addons-repo-dir> <output-apps.json>
"""
import json
import sys

import yaml

ADDONS = ["hassio-gateway", "hassio-access-point", "hassio-openvpn"]


def main() -> int:
    if len(sys.argv) != 3:
        print(__doc__, file=sys.stderr)
        return 2
    src, out_path = sys.argv[1], sys.argv[2]

    out = {"user": {}, "system": {}}
    for slug in ADDONS:
        with open(f"{src}/{slug}/config.yaml") as f:
            cfg = yaml.safe_load(f)
        key = f"local_{slug}"
        out["user"][key] = {
            "version": cfg["version"],
            "image": cfg["image"],
            "options": cfg.get("options") or {},
        }
        system = dict(cfg)
        system["repository"] = "local"
        out["system"][key] = system

    with open(out_path, "w") as f:
        json.dump(out, f, indent=2)
    print(f"craft-apps-json: wrote {out_path} ({', '.join(out['user'])})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
