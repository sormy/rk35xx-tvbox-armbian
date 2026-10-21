# gst-plugins-good — VC-1 through V4L2 on GStreamer 1.26.2

GStreamer maps no caps to `V4L2_PIX_FMT_VC1_ANNEX_G` before 1.26.6: `v4l2vc1dec` registers, and
every stream fails with "Invalid caps". Debian trixie ships 1.26.2. `0001` is the 1.26.6 change; the
recipe rebuilds trixie's v4l2 plugin with it and puts it in place of the packaged one.

| Patch  | Fixes                                                 |
| ------ | ----------------------------------------------------- |
| `0001` | `video/x-wmv` to `VC1_ANNEX_G` and `VC1_ANNEX_L` caps |

## Install

On the box, as root, with `0001-v4l2-vc1-caps.patch` copied to `/root`:

```bash
apt-get install -y --no-install-recommends meson ninja-build pkg-config libgstreamer1.0-dev libgstreamer-plugins-base1.0-dev libgudev-1.0-dev libv4l-dev
cd /root && curl -fsSL https://gstreamer.freedesktop.org/src/gst-plugins-good/gst-plugins-good-1.26.2.tar.xz | tar -xJ
patch -d gst-plugins-good-1.26.2 -p1 < /root/0001-v4l2-vc1-caps.patch
meson setup gst-plugins-good-1.26.2/build gst-plugins-good-1.26.2 -Dauto_features=disabled -Dv4l2=enabled
ninja -C gst-plugins-good-1.26.2/build sys/v4l2/libgstvideo4linux2.so
P=/usr/lib/aarch64-linux-gnu/gstreamer-1.0/libgstvideo4linux2.so
dpkg-divert --local --rename --divert $P.distrib --add $P
install -m 0644 gst-plugins-good-1.26.2/build/sys/v4l2/libgstvideo4linux2.so $P
rm -rf ~/.cache/gstreamer-1.0
```

The divert keeps apt from overwriting the plugin; an upgrade of `gstreamer1.0-plugins-good` to
1.26.6 or later makes it unnecessary.

## Remove

On the box, as root:

```bash
P=/usr/lib/aarch64-linux-gnu/gstreamer-1.0/libgstvideo4linux2.so
rm $P && dpkg-divert --local --rename --remove $P
rm -rf ~/.cache/gstreamer-1.0
```

## Alternative: rebuild the Debian package

❓ Not run here. A packaged build instead of a diverted file: apt knows every file, and trixie's
next `gst-plugins-good1.0` update replaces it, patch and all. On the box, as root, with `deb-src`
added to the trixie entry's `Types:` and the patch in `/root`:

```bash
apt-get update && apt-get install -y build-essential devscripts && apt-get build-dep -y gst-plugins-good1.0
cd /root && apt-get source gst-plugins-good1.0 && cd gst-plugins-good1.0-1.26.2
cp /root/0001-v4l2-vc1-caps.patch debian/patches/ && echo 0001-v4l2-vc1-caps.patch >> debian/patches/series
dch --local +tvb "v4l2: map video/x-wmv to the VC-1 formats" && dpkg-buildpackage -b -uc -us
apt-get install -y ../gstreamer1.0-plugins-good_*+tvb*_arm64.deb
```
