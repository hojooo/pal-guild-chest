# Third-party test tooling

`lua-5.4.8/` is the unmodified Lua 5.4.8 source distribution, downloaded from
<https://www.lua.org/ftp/lua-5.4.8.tar.gz>.

- SHA-256: `4f18ddae154e793e46eeab727c59ef1c0c2b744e7b94219710d76f530629ae`
- Verification: `shasum -a 256 lua-5.4.8.tar.gz`
- Local build: `make -C third_party/lua-5.4.8 all`

This runtime exists only to execute the repository's Lua tests. It is not part
of the Crossplay Guild Chest Expander release package. The source distribution
contains its own license information in `lua-5.4.8/doc/readme.html`.
