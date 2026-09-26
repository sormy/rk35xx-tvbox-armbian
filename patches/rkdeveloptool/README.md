# rkdeveloptool — patches

`rkdeveloptool pack` builds a maskrom loader, but only in the old RC4-on `BOOT` format. RK3528's
BootROM accepts that file over USB and then ignores it without a word. The format it answers is
new-IDB with RC4 off, magic `LDR `, which Rockchip's own `rkbin/RKBOOT/RK3528MINIALL.ini` asks for
through `[SYSTEM] NEWIDB=true` and `[FLAG] RC4_OFF=true` — sections the stock parser rejects
outright with `unknown sec: [SYSTEM]!`.

`../../build-rktools.sh` fetches rkdeveloptool, applies these, and builds to `tools/rktools/`. It
then packs each board's loader from that same rkbin ini, so the flags come from Rockchip's file
rather than from anything this repo invents.

| Patch  | Fixes                                                                          |
| ------ | ------------------------------------------------------------------------------ |
| `0001` | `[SYSTEM]`/`[FLAG]` rejected; `LOADER<n>` off-by-one; tag and RC4 hardcoded    |
| `0002` | progress escapes printed as text on a Windows console, and buffered when piped |

`0001` also fixes an out-of-bounds write: `parseLoader` indexed `gOpts.loader[]` with the number in
the `LOADER<n>=` key, while `[CODE471_OPTION]` decrements it. Rockchip's 1-based `LOADER1`/`LOADER2`
therefore wrote one past a two-element array.

✅ Verified on the H96 Max 3518D, 2026-09-12, loader packed on macOS arm64: `db` succeeded, `rfi`
reported 30777344 sectors, and `rl 64 1024` came back byte-identical to the repo's factory
idbloader. The `UsbHead`/`FlashHead` entries that `CREATE_IDB=true` adds are not needed for this.

## Cross-building for Windows

`0002` only matters off Linux and macOS. A Windows host cannot run the recovery kit's shell scripts,
so the exe ships prebuilt alongside a packed loader; the BootROM does not care which host packed it.

```sh
brew install mingw-w64                                     # on the macOS host
./configure --host=x86_64-w64-mingw32 \
  CXXFLAGS="-O2 -D_FILE_OFFSET_BITS=64 -Wno-error" \
  LDFLAGS="-static -static-libgcc -static-libstdc++" \
  LIBS="-lsetupapi -lole32 -ladvapi32 -lwinmm -luuid"
```

libusb-1.0 has to be cross-built static into the same prefix first; nothing else needs patching.
`-static` leaves the exe importing only UCRT and `KERNEL32`, both of which Windows 10 and 11 carry,
so no DLL ships beside it. On Windows the device needs the WinUSB driver bound to VID `2207`, which
Zadig does — Rockchip's own DriverAssistant binds a driver libusb cannot open.

✅ Verified under Wine on macOS arm64, 2026-09-20: `ld` enumerated and reported no device, `unpack`
round-tripped a packed RK322X loader, and `ftello` returned 7752122368 on a 7.22 GiB image, so the
32-bit `long` Win64 uses does not truncate a `wl` of a full eMMC dump. 🟡 The USB transfer itself
has not been run from a Windows host.
