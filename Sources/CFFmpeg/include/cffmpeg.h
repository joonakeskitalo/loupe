// Umbrella header exposing the subset of the official FFmpeg libraries
// (libavformat / libavcodec / libavutil / libswscale) that Loupe uses to
// decode a single frame from containers QuickLook/AVFoundation can't handle
// (notably Matroska .mkv and WebM .webm).
#ifndef LOUPE_CFFMPEG_H
#define LOUPE_CFFMPEG_H

#include <libavformat/avformat.h>
#include <libavcodec/avcodec.h>
#include <libavutil/display.h>
#include <libavutil/imgutils.h>
#include <libavutil/pixdesc.h>
#include <libswscale/swscale.h>

#endif /* LOUPE_CFFMPEG_H */
