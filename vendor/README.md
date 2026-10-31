# vendor/ - bring-your-own artefacts

Anything you drop here is copied into the build context and consumed by the
Dockerfile *only* when the matching build arg allows it. Nothing in this
directory is ever committed (see `.gitignore`).

| Path                        | Consumed by              | Effect                                                    |
| --------------------------- | ------------------------ | --------------------------------------------------------- |
| `vendor/*.deb`              | Hopper install step      | your **licensed** Hopper package replaces the public demo |
| `vendor/ida/*.run`          | IDA step (`INSTALL_IDA=1`)| unattended install of IDA into `/opt/ida`                |
| `vendor/ida/*.hexlic`       | IDA step                 | copied to `~/.idapro/ida.hexlic` inside the image         |
| `vendor/hopper-state/`      | compose bind mount       | Hopper application support (licence/activation state)      |
| `vendor/ida/` (empty)       | compose bind mount       | default (empty) IDA install mount at `/opt/ida`            |

## Licensed Hopper

```bash
# You own a Hopper licence and downloaded the licensed DEB:
cp ~/Downloads/Hopper-6.6.1-Linux.deb vendor/
make build            # or: make build-hopper for the Hopper-only image
# (equivalent to scripts/build.sh --engine all, which passes REA_UID/REA_GID too)
```

The build prints which package it used. Verify with:

```bash
docker compose --profile hopper up -d rea-hopper
docker compose exec rea-hopper /opt/hopper/bin/Hopper --version || true
docker compose exec rea-hopper rea doctor --provider hopper --json
```

Hopper activation on Linux is interactive and operator-owned (REA deliberately
never touches licence credentials). Persist the activation in
`vendor/hopper-state/` - see `docs/BYO-LICENSES.md`.

## IDA Pro / IDA Home

Preferred: bind-mount an existing installation instead of baking it in.

```bash
echo "IDA_INSTALL_DIR=$HOME/ida-pro-9.4" >> .env
mkdir -p config/ida && cp ~/ida.hexlic config/ida/
make build-ida
docker compose -f docker-compose.yml -f compose.ida.yml --profile ida up -d rea-ida
```

Baking in is supported for reproducibility, but the resulting image must stay
private - Hex-Rays' terms do not allow redistributing IDA:

```bash
mkdir -p vendor/ida
cp ~/Downloads/ida-pro_94_x64linux.run vendor/ida/
cp ~/ida.hexlic vendor/ida/
echo "INSTALL_IDA=1" >> .env
make build-ida            # or ENGINE=all, which also gains IDA
```

Which IDA edition can drive REA headlessly (and which cannot) is in
`docs/ida-variants.md`.
