#!/bin/sh
# On the box: ffmpeg with the V4L2 mem2mem patches, static, into /opt/ffmpeg-9.
#   usage: build.sh [workdir]
set -e
VER=9.0.2
HERE="$(cd "$(dirname "$0")" && pwd)"
WORK="${1:-/root/ffmpeg-build}"
mkdir -p "$WORK" && cd "$WORK"
[ -s ffmpeg-$VER.tar.xz ] || curl -fsSL -o ffmpeg-$VER.tar.xz https://ffmpeg.org/releases/ffmpeg-$VER.tar.xz
rm -rf ffmpeg-$VER && tar -xJf ffmpeg-$VER.tar.xz && cd ffmpeg-$VER
for p in "$HERE"/patches/*.patch; do patch -p1 < "$p"; done
./configure --prefix=/opt/ffmpeg-9 --disable-shared --enable-static --disable-doc \
  --disable-everything --enable-ffmpeg --enable-ffprobe --enable-v4l2-m2m --enable-libdrm \
  --enable-decoder=h264,hevc,vp9,mpeg1video,mpeg2video,mpeg4,mjpeg,vc1,wmv3,rawvideo \
  --enable-decoder=h264_v4l2m2m,hevc_v4l2m2m,vp9_v4l2m2m,mpeg1_v4l2m2m,mpeg2_v4l2m2m,mpeg4_v4l2m2m,mjpeg_v4l2m2m,vc1_v4l2m2m \
  --enable-encoder=h264_v4l2m2m,hevc_v4l2m2m,rawvideo,wrapped_avframe \
  --enable-demuxer=h264,hevc,ivf,m4v,mpegvideo,mjpeg,matroska,mov,asf,avi,rawvideo \
  --enable-muxer=rawvideo,matroska,mp4,null,framemd5,h264,hevc \
  --enable-parser=h264,hevc,vp9,mpeg4video,mpegvideo,mjpeg,vc1 \
  --enable-bsf=h264_mp4toannexb,hevc_mp4toannexb,vp9_superframe_split,extract_extradata \
  --enable-protocol=file,pipe --enable-indev=lavfi \
  --enable-filter=scale,format,null,testsrc2,psnr,buffer,buffersink,fps,copy
make -j"$(nproc)"
make install
/opt/ffmpeg-9/bin/ffmpeg -hide_banner -decoders 2>/dev/null | grep v4l2m2m
