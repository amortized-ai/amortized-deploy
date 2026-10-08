# Pinned releases

Each `<release>.yaml` here pins the **entire** stack — the core chart version plus every image —
to one validated set of shas, for a reproducible install:

```bash
# from helm/amortized-rhoai
./install.sh amortized-gateway -f releases/<release>.yaml
```

Without `-f`, `install.sh` tracks **latest** (`main`) — newer, but may be unstable. See the repo
README ("Latest vs pinned installs").

## What a release file pins

```yaml
studio-gateway:
  chart:
    version: "<core-chart-version>"   # per-user core chart (server + studio) pulled from OCI
  image:
    tag: sha-<gateway>                # studio-gateway
  serverImageTag: sha-<server>        # per-user server (overrides the core chart default)
  jobImageTag: sha-<jobs>             # eval, SDG (data-designer), document job images
  trainingImageTag: <tag>             # training image — built upstream, its own tag (e.g. dev-embedding)
  morty:
    image: ghcr.io/amortized-ai/morty:sha-<morty>
pluginFrontend:
  image:
    tag: sha-<plugin>                 # dashboard plugin (amortized-studio)
```

Each amortized-CI image (server, jobs, studio-gateway) is pinned to the sha built from the release
commit. Path-filtered CI means components can rebuild at different commits, so the shas may differ
per image (a future unified release-tag workflow will collapse these to one version). The
**training** image is the exception — it is built upstream (training-hub), so it is pinned to its
own published tag (e.g. `dev-embedding`), not a release-commit sha.
