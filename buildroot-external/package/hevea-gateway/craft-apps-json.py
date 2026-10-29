#!/usr/bin/env python3
"""Craft the Supervisor apps.json pre-install entries for the Hevea add-ons.

The Supervisor cannot install add-ons while the host is offline (its
install job always pulls the image from the registry), so the add-ons are
baked as already installed in the data partition: this generates the
apps.json entries that Supervisor's AppsData.install() would have written
on a successful install:

- system[slug] = the parsed add-on config.yaml + repository
- user[slug]   = version + image + default options

The installed slug is "<repo-slug>_<addon>": the Supervisor prefixes store
slugs with the repository slug, which it derives from the repository URL
(sha1 of the lowercased URL, first 8 hex chars). Baking under the GitHub
repository slug means the pre-installed add-ons are the same as the ones
the GitHub repository provides: once the repository is added (first online
boot), they are known to the store and can be updated.

Usage: craft-apps-json.py <addons-repo-dir> <output-apps.json> <repo-url>
"""
import hashlib
import json
import sys

import yaml

ADDONS = ["hassio-gateway", "hassio-access-point", "hassio-openvpn"]


def main() -> int:
    if len(sys.argv) != 4:
        print(__doc__, file=sys.stderr)
        return 2
    src, out_path, repo_url = sys.argv[1], sys.argv[2], sys.argv[3]
    repo_slug = hashlib.sha1(repo_url.lower().encode()).hexdigest()[:8]

    out = {"user": {}, "system": {}}
    for slug in ADDONS:
        with open(f"{src}/{slug}/config.yaml") as f:
            cfg = yaml.safe_load(f)
        key = f"{repo_slug}_{slug}"
        out["user"][key] = {
            "version": cfg["version"],
            "image": cfg["image"],
            "options": cfg.get("options") or {},
        }
        system = dict(cfg)
        system["repository"] = repo_slug
        out["system"][key] = system

    with open(out_path, "w") as f:
        json.dump(out, f, indent=2)
    print(f"craft-apps-json: wrote {out_path} ({', '.join(out['user'])})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
