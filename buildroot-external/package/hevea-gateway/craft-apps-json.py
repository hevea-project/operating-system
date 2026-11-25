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

Usage: craft-apps-json.py <addons-repo-dir> <core-repo-dir> <output-apps.json> <repo-url>

The Hevea add-ons (addons-repo-dir) are baked under the GitHub repository
slug derived from repo-url. The add-ons from the official repository
(core-repo-dir, one subdirectory per add-on slug) are baked under the
built-in "core" repository slug ("core"), which the Supervisor always has
pre-configured, so e.g. openthread_border_router becomes
"core_openthread_border_router" and can be updated once the official
repository is synced.
"""
import hashlib
import json
import sys
from pathlib import Path

import yaml

ADDONS = ["hassio-gateway", "hassio-access-point", "hassio-openvpn"]

# Built-in repository slug of the official add-ons (supervisor store
# built-in.json), not derived from a URL.
CORE_REPO_SLUG = "core"


def entry_from_config(cfg: dict, repo_slug: str) -> tuple[str, dict, dict]:
    key = f"{repo_slug}_{cfg['slug']}"
    user = {
        "version": cfg["version"],
        "image": cfg["image"],
        "options": cfg.get("options") or {},
    }
    system = dict(cfg)
    system["repository"] = repo_slug
    return key, user, system


def main() -> int:
    if len(sys.argv) != 5:
        print(__doc__, file=sys.stderr)
        return 2
    src, core_src, out_path, repo_url = sys.argv[1:5]
    repo_slug = hashlib.sha1(repo_url.lower().encode()).hexdigest()[:8]

    out = {"user": {}, "system": {}}
    for slug in ADDONS:
        with open(f"{src}/{slug}/config.yaml") as f:
            cfg = yaml.safe_load(f)
        key, user, system = entry_from_config(cfg, repo_slug)
        out["user"][key] = user
        out["system"][key] = system

    # Official add-ons (OpenThread Border Router, Matter Server, ...):
    # one subdirectory per add-on slug in core_src.
    for addon_dir in sorted(Path(core_src).iterdir()):
        cfg_file = addon_dir / "config.yaml"
        if not cfg_file.is_file():
            continue
        with open(cfg_file) as f:
            cfg = yaml.safe_load(f)
        key, user, system = entry_from_config(cfg, CORE_REPO_SLUG)
        out["user"][key] = user
        out["system"][key] = system

    with open(out_path, "w") as f:
        json.dump(out, f, indent=2)
    print(f"craft-apps-json: wrote {out_path} ({', '.join(out['user'])})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
