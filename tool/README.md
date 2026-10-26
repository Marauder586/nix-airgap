# nix-airgap-tool

The build-time half of [nix-airgap](../README.md). It writes a store closure as a
`file://` binary cache (for `nix copy --from`) inside the Nix build sandbox, and
writes the tar/sh polyglot bundle.

```
nix-airgap-tool cache --out DIR [--registration FILE]... [--drv DRV]... [--stats FILE]
nix-airgap-tool polyglot --entry LINE --out FILE NAME=PATH...
```
