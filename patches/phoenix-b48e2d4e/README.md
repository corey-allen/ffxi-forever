# Phoenix temp patches for b48e2d4e

Verbatim (LF) copies of `modules/temp_patch/lsb-yaml.patch` and
`modules/temp_patch/phoenix-fishing.patch` from
[phoenixffxi/Phoenix](https://github.com/phoenixffxi/Phoenix) at commit
`b48e2d4ecb8a3b0fd5f4094cf86b76807e04840f` (GPL-3.0, © LandSandBoat / Phoenix XI contributors).

Phoenix applies these to its core before building; its own modules do not compile without them.
Kept here because Git for Windows' `core.autocrlf` breaks the working-tree copies.

| File | SHA-256 |
|---|---|
| `lsb-yaml.patch` | `94688F35FA7C3F49D3AE90FBB4ADB09A63EA140E36B9474D269A0B28D9747BAA` |
| `phoenix-fishing.patch` | `6DBCD861C0D0570D985BA8E88BCD0CFEC4326C82BF3F45C257800409EC4108E0` |

Apply (from the server checkout): `git apply <path>\lsb-yaml.patch` then
`git apply <path>\phoenix-fishing.patch`. Revert with `git apply -R` in reverse order.
See [docs/LOCAL_SERVER_INSTALL.md](../../docs/LOCAL_SERVER_INSTALL.md) §4.
