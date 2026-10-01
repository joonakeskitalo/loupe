// Umbrella header exposing libmpv's client and OpenGL render APIs to Swift.
//
// Loupe embeds libmpv (mpv's client library, built on the same FFmpeg stack it
// already links) to play containers AVFoundation can't demux — notably
// Matroska (.mkv) and WebM (.webm). The client API drives playback state
// (pause, time-pos, duration, seeking, frame stepping); the OpenGL render API
// draws decoded frames into an NSOpenGLView embedded in the SwiftUI viewer.
#ifndef LOUPE_CMPV_H
#define LOUPE_CMPV_H

#include <mpv/client.h>
#include <mpv/render.h>
#include <mpv/render_gl.h>

#endif /* LOUPE_CMPV_H */
