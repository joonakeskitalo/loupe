import Foundation
import CFFmpeg

/// Transcodes a video to a target resolution using the official FFmpeg
/// libraries (libavformat / libavcodec / libavutil / libswscale), the same C
/// API the rest of Loupe uses for probing and thumbnailing. There is no bundled
/// `ffmpeg` command-line binary (only the dylibs), and the app is sandboxed, so
/// shelling out is not an option — this reimplements the relevant parts of
///
///     ffmpeg -i in -vf "scale=-2:HEIGHT" -c:v libx264 -c:a copy out.mp4
///
/// against the C API: the video stream is decoded, rescaled to the target
/// height (width computed from the source aspect ratio and rounded to an even
/// number, since H.264 requires even dimensions — the `trunc(ow/a/2)*2` in the
/// example), and re-encoded as H.264; the audio stream is remuxed untouched
/// (the `-c:a copy`). The output is always an MP4.
///
/// Everything is synchronous C work with no shared mutable state, so it is safe
/// to run from a detached task off the main actor.
/// FFmpeg integer constants that come from C macros and aren't imported into
/// Swift by the module map. Recreated here with the same definitions FFmpeg
/// uses.
private enum AVConst {
    /// `AVERROR(EAGAIN)` — more input/output needed. EAGAIN is 35 on Darwin.
    static let eagain: Int32 = -35
    /// `AVERROR_EOF` = `-MKTAG('E','O','F',' ')`.
    static let eof: Int32 = {
        func mkTag(_ a: Character, _ b: Character, _ c: Character, _ d: Character) -> Int32 {
            let av = Int32(a.asciiValue!)
            let bv = Int32(b.asciiValue!) << 8
            let cv = Int32(c.asciiValue!) << 16
            let dv = Int32(d.asciiValue!) << 24
            return av | bv | cv | dv
        }
        return -mkTag("E", "O", "F", " ")
    }()
    /// `AV_NOPTS_VALUE` — the "no timestamp" sentinel, `INT64_MIN`.
    static let noPTS: Int64 = Int64.min
}

enum VideoTranscoder {
    /// A target output height. The width is derived from the source aspect
    /// ratio (even-rounded), so only the height is fixed — matching how a
    /// "1080p" / "720p" preset is normally understood.
    enum Resolution: String, CaseIterable, Sendable {
        case p1080 = "1080p"
        case p720 = "720p"

        var displayName: String { rawValue }

        /// A filename-safe token for this resolution (e.g. "1080p"), appended
        /// to exported file names.
        var fileNameToken: String { rawValue }

        /// The fixed output height in pixels.
        var height: Int {
            switch self {
            case .p1080: return 1080
            case .p720: return 720
            }
        }
    }

    /// Which encoder to use for the output video stream.
    ///
    /// `.h264` is the software x264 encoder — maximum compatibility, slower.
    /// `.hevcVideoToolbox` is Apple's hardware H.265 encoder (VideoToolbox),
    /// which is dramatically faster (and more power-efficient) on Apple Silicon
    /// and recent Intel Macs, at a smaller file size for similar quality. Its
    /// output is tagged `hvc1` so QuickTime / Finder preview it correctly.
    enum Codec: String, CaseIterable, Sendable {
        case h264 = "H.264 (x264)"
        case hevcVideoToolbox = "H.265 (VideoToolbox)"

        var displayName: String { rawValue }

        /// The FFmpeg encoder's registered name, looked up with
        /// `avcodec_find_encoder_by_name`.
        var encoderName: String {
            switch self {
            case .h264: return "libx264"
            case .hevcVideoToolbox: return "hevc_videotoolbox"
            }
        }

        /// A short filename-safe token for this codec (e.g. "h264", "h265"),
        /// appended to exported file names.
        var fileNameToken: String {
            switch self {
            case .h264: return "h264"
            case .hevcVideoToolbox: return "h265"
            }
        }

        /// Whether this is a hardware VideoToolbox encoder (affects which
        /// quality options apply).
        var isVideoToolbox: Bool { self == .hevcVideoToolbox }
    }

    /// How the encoder decides bit allocation.
    ///
    /// `.constantQuality(cq)` targets a fixed perceptual quality rather than a
    /// fixed size — the encoder spends whatever bits each frame needs to hit
    /// that quality. The `cq` scale is 0...100 (higher = better quality, bigger
    /// file), matching VideoToolbox's quality scale; for the software x264
    /// encoder it's mapped onto CRF.
    ///
    /// `.automaticBitrate` targets a bitrate derived from the output resolution
    /// and frame rate (the original behavior).
    enum RateControl: Sendable, Equatable {
        case constantQuality(Int)
        case automaticBitrate

        /// The default: constant quality at CQ 70.
        static let `default`: RateControl = .constantQuality(70)

        /// A short filename-safe token describing the rate control (e.g.
        /// "cq70" or "auto"), appended to exported file names.
        var fileNameToken: String {
            switch self {
            case .constantQuality(let cq): return "cq\(cq)"
            case .automaticBitrate: return "auto"
            }
        }
    }

    enum TranscodeError: Error {
        case openInput
        case streamInfo
        case noVideoStream
        case decoderInit
        case encoderUnavailable
        case encoderInit
        case openOutput
        case writeHeader
        case scaler
        case allocation
        case encode
        case cancelled
        /// Setting up the audio decode/encode/resample pipeline failed.
        case audioInit
    }

    /// Whether an audio codec can be stored in an MP4 by a straight stream copy
    /// (no re-encode). MP4 only permits a limited set of audio codecs — AAC,
    /// MP3, AC-3/E-AC-3, ALAC, Opus, and a couple of others. Raw PCM variants
    /// (notably A-law / µ-law, which some cameras and capture devices emit) are
    /// NOT valid in MP4, so copying them makes the muxer reject the file and the
    /// whole export fails. Those codecs are re-encoded to AAC instead.
    nonisolated private static func canCopyAudioToMP4(_ codecID: AVCodecID) -> Bool {
        switch codecID {
        case AV_CODEC_ID_AAC, AV_CODEC_ID_MP3, AV_CODEC_ID_AC3, AV_CODEC_ID_EAC3,
             AV_CODEC_ID_ALAC, AV_CODEC_ID_OPUS, AV_CODEC_ID_MP2,
             AV_CODEC_ID_MP1, AV_CODEC_ID_DTS:
            return true
        default:
            return false
        }
    }

    /// Transcodes `input` to `output` (an MP4), scaling the video to
    /// `resolution`'s height, encoding with `codec`, and copying the audio
    /// stream unchanged. Throws on any failure. `progress` is called
    /// periodically with a 0...1 fraction based on decoded-frame timestamps vs.
    /// the clip duration (best-effort; may stay at 0 for streams with no known
    /// duration/PTS).
    ///
    /// Synchronous and `nonisolated`: run it from a detached task.
    ///
    /// `isCancelled` is polled once per demuxed packet; when it returns true
    /// the transcode aborts promptly and throws `TranscodeError.cancelled`
    /// (the caller is responsible for deleting any partial output). This lets a
    /// queue cancel an in-flight export.
    nonisolated static func transcode(
        input: URL,
        output: URL,
        resolution: Resolution,
        codec: Codec = .h264,
        rateControl: RateControl = .default,
        isCancelled: (@Sendable () -> Bool)? = nil,
        progress: (@Sendable (Double) -> Void)? = nil
    ) throws {
        // MARK: Open input
        var inputCtx: UnsafeMutablePointer<AVFormatContext>? = nil
        guard avformat_open_input(&inputCtx, input.path, nil, nil) == 0 else {
            throw TranscodeError.openInput
        }
        defer { avformat_close_input(&inputCtx) }

        guard avformat_find_stream_info(inputCtx, nil) >= 0 else {
            throw TranscodeError.streamInfo
        }

        // Best video stream + its decoder.
        var decoder: UnsafePointer<AVCodec>? = nil
        let videoIndex = av_find_best_stream(inputCtx, AVMEDIA_TYPE_VIDEO, -1, -1, &decoder, 0)
        guard videoIndex >= 0, let decoder,
              let inVideoStream = inputCtx?.pointee.streams[Int(videoIndex)]
        else {
            throw TranscodeError.noVideoStream
        }

        // The best audio stream, if any — remuxed as a straight copy.
        let audioIndex = av_find_best_stream(inputCtx, AVMEDIA_TYPE_AUDIO, -1, -1, nil, 0)

        // MARK: Decoder
        guard let decCtx = avcodec_alloc_context3(decoder) else { throw TranscodeError.decoderInit }
        var decCtxOpt: UnsafeMutablePointer<AVCodecContext>? = decCtx
        defer { avcodec_free_context(&decCtxOpt) }
        guard avcodec_parameters_to_context(decCtx, inVideoStream.pointee.codecpar) >= 0 else {
            throw TranscodeError.decoderInit
        }
        decCtx.pointee.thread_count = 0
        guard avcodec_open2(decCtx, decoder, nil) >= 0 else { throw TranscodeError.decoderInit }

        // MARK: Target geometry
        let srcW = Int(decCtx.pointee.width)
        let srcH = Int(decCtx.pointee.height)
        guard srcW > 0, srcH > 0 else { throw TranscodeError.decoderInit }

        // Fixed target height; width scaled by the source aspect, rounded to an
        // even number (H.264 needs even dimensions — the example's
        // `trunc(ow/a/2)*2`). Never upscale: if the source is already shorter
        // than the target, keep the source size (still even-rounded).
        let dstH = min(srcH, resolution.height)
        let scaledW = Int((Double(srcW) * Double(dstH) / Double(srcH)).rounded())
        let dstW = max(2, scaledW - (scaledW % 2))
        let evenDstH = max(2, dstH - (dstH % 2))

        // MARK: Encoder (selected codec)
        // Look up by name so we can pick the hardware VideoToolbox HEVC encoder
        // when requested. If an encoder isn't available (e.g. VideoToolbox
        // missing), fall back to software H.264 so an export never hard-fails.
        var chosenCodec = codec
        var encoder = avcodec_find_encoder_by_name(codec.encoderName)
        if encoder == nil {
            chosenCodec = .h264
            encoder = avcodec_find_encoder_by_name(Codec.h264.encoderName)
                ?? avcodec_find_encoder(AV_CODEC_ID_H264)
        }
        guard let encoder else { throw TranscodeError.encoderUnavailable }

        guard let encCtx = avcodec_alloc_context3(encoder) else { throw TranscodeError.encoderInit }
        var encCtxOpt: UnsafeMutablePointer<AVCodecContext>? = encCtx
        defer { avcodec_free_context(&encCtxOpt) }

        encCtx.pointee.width = Int32(dstW)
        encCtx.pointee.height = Int32(evenDstH)
        encCtx.pointee.pix_fmt = AV_PIX_FMT_YUV420P
        // Use the source stream's time base / frame rate so timestamps stay
        // sensible. Fall back to a 1/30 base if the source reports none.
        let srcFrameRate = inVideoStream.pointee.avg_frame_rate
        let frameRate = (srcFrameRate.num > 0 && srcFrameRate.den > 0) ? srcFrameRate : AVRational(num: 30, den: 1)
        encCtx.pointee.time_base = AVRational(num: frameRate.den, den: frameRate.num)
        encCtx.pointee.framerate = frameRate

        encCtx.pointee.gop_size = 12
        // B-frames cost throughput (frame reordering + extra motion
        // estimation). On the hardware VideoToolbox path, encoding speed is the
        // priority, so disable them there; keep a couple for the software x264
        // path where they meaningfully improve compression.
        encCtx.pointee.max_b_frames = chosenCodec.isVideoToolbox ? 0 : 2

        var opts: OpaquePointer? = nil // AVDictionary*
        defer { av_dict_free(&opts) }

        // Average bitrate used by `.automaticBitrate` (and as a VideoToolbox
        // ceiling in constant-quality mode): scaled to the output pixels/sec
        // for roughly visually-transparent HEVC (~0.07 bits per pixel/frame).
        let fps = frameRate.den > 0 ? Double(frameRate.num) / Double(frameRate.den) : 30
        let autoBitrate = Int64(max(1_000_000.0, Double(dstW * evenDstH) * fps * 0.07))

        if chosenCodec.isVideoToolbox {
            // Allow the software fallback so machines without the hardware path
            // still succeed.
            av_dict_set(&opts, "allow_sw", "1", 0)
            av_dict_set(&opts, "realtime", "0", 0)

            switch rateControl {
            case .constantQuality(let cq):
                // VideoToolbox constant quality. FFmpeg's `-q:v N` convention is
                // `global_quality = N * FF_QP2LAMBDA` with the QSCALE flag set;
                // the encoder reads it back on its 0...100 quality scale (higher
                // is better). Clamp to that range.
                let q = max(0, min(100, cq))
                encCtx.pointee.flags |= AV_CODEC_FLAG_QSCALE
                encCtx.pointee.global_quality = Int32(q) * FF_QP2LAMBDA
            case .automaticBitrate:
                encCtx.pointee.bit_rate = autoBitrate
            }
        } else {
            // Software x264.
            av_dict_set(&opts, "preset", "medium", 0)
            switch rateControl {
            case .constantQuality(let cq):
                // Map the 0...100 quality scale onto x264 CRF (0...51, lower is
                // better): CQ 100 → CRF 0 (near-lossless), CQ 0 → CRF 51.
                let q = max(0, min(100, cq))
                let crf = Int((Double(100 - q) / 100.0 * 51.0).rounded())
                av_dict_set(&opts, "crf", String(crf), 0)
            case .automaticBitrate:
                encCtx.pointee.bit_rate = autoBitrate
            }
        }

        // MARK: Output context (MP4)
        var outputCtx: UnsafeMutablePointer<AVFormatContext>? = nil
        avformat_alloc_output_context2(&outputCtx, nil, "mp4", output.path)
        guard let outputCtx else { throw TranscodeError.openOutput }
        defer {
            // Free the output context and (if opened) its IO.
            if let pb = outputCtx.pointee.pb, (outputCtx.pointee.oformat?.pointee.flags ?? 0) & AVFMT_NOFILE == 0 {
                var pbOpt: UnsafeMutablePointer<AVIOContext>? = pb
                avio_closep(&pbOpt)
            }
            var outOpt: UnsafeMutablePointer<AVFormatContext>? = outputCtx
            avformat_free_context(outOpt)
            outOpt = nil
        }

        // If the muxer wants a global header, set the encoder flag before open.
        if (outputCtx.pointee.oformat?.pointee.flags ?? 0) & AVFMT_GLOBALHEADER != 0 {
            encCtx.pointee.flags |= AV_CODEC_FLAG_GLOBAL_HEADER
        }

        guard avcodec_open2(encCtx, encoder, &opts) >= 0 else { throw TranscodeError.encoderInit }

        // Output video stream.
        guard let outVideoStream = avformat_new_stream(outputCtx, nil) else {
            throw TranscodeError.openOutput
        }
        guard avcodec_parameters_from_context(outVideoStream.pointee.codecpar, encCtx) >= 0 else {
            throw TranscodeError.openOutput
        }
        outVideoStream.pointee.time_base = encCtx.pointee.time_base

        // Tag HEVC as `hvc1` (not the default `hev1`) so QuickTime, Finder
        // Quick Look, and AVFoundation recognize and play the MP4.
        if chosenCodec == .hevcVideoToolbox {
            func mkTag(_ a: Character, _ b: Character, _ c: Character, _ d: Character) -> UInt32 {
                UInt32(a.asciiValue!) | (UInt32(b.asciiValue!) << 8)
                    | (UInt32(c.asciiValue!) << 16) | (UInt32(d.asciiValue!) << 24)
            }
            outVideoStream.pointee.codecpar.pointee.codec_tag = mkTag("h", "v", "c", "1")
        }

        // Output audio stream, if a source audio stream exists.
        //
        // Fast path: when the source audio codec is valid in MP4 (AAC, MP3,
        // AC-3, …) we remux its packets untouched — a straight copy, no decode.
        //
        // Re-encode path: some sources carry audio MP4 can't store, notably raw
        // PCM A-law / µ-law from certain cameras and capture devices. Copying
        // those makes the muxer reject the file, failing the whole export. For
        // them we decode and re-encode to AAC via `AudioReencoder`.
        var outAudioStreamIndex: Int32 = -1       // set only on the copy path
        var inAudioStream: UnsafeMutablePointer<AVStream>? = nil
        var audioReencoder: AudioReencoder? = nil
        let wantsGlobalHeader = (outputCtx.pointee.oformat?.pointee.flags ?? 0) & AVFMT_GLOBALHEADER != 0

        if audioIndex >= 0, let aStream = inputCtx?.pointee.streams[Int(audioIndex)] {
            let srcAudioCodecID = aStream.pointee.codecpar.pointee.codec_id
            if canCopyAudioToMP4(srcAudioCodecID) {
                if let outAudio = avformat_new_stream(outputCtx, nil),
                   avcodec_parameters_copy(outAudio.pointee.codecpar, aStream.pointee.codecpar) >= 0 {
                    outAudio.pointee.codecpar.pointee.codec_tag = 0
                    outAudio.pointee.time_base = aStream.pointee.time_base
                    outAudioStreamIndex = Int32(outputCtx.pointee.nb_streams - 1)
                    inAudioStream = aStream
                }
            } else {
                // Incompatible codec (e.g. pcm_alaw): re-encode to AAC. If the
                // pipeline can't be built, fall through with no audio rather
                // than aborting — a silent export beats a failed one.
                audioReencoder = AudioReencoder(
                    sourceStream: aStream,
                    outputCtx: outputCtx,
                    globalHeader: wantsGlobalHeader)
            }
        }

        // MARK: Open output file + write header
        if (outputCtx.pointee.oformat?.pointee.flags ?? 0) & AVFMT_NOFILE == 0 {
            guard avio_open(&outputCtx.pointee.pb, output.path, AVIO_FLAG_WRITE) >= 0 else {
                throw TranscodeError.openOutput
            }
        }
        guard avformat_write_header(outputCtx, nil) >= 0 else {
            throw TranscodeError.writeHeader
        }

        // MARK: Scaler (source pix fmt -> YUV420P at target size)
        // Fast bilinear is the quickest swscale path; at the downscale ratios
        // used here the quality difference from plain bilinear is negligible,
        // and it cuts the per-frame CPU cost that the hardware encoder would
        // otherwise stall waiting on.
        guard let sws = sws_getContext(
            Int32(srcW), Int32(srcH), AVPixelFormat(decCtx.pointee.pix_fmt.rawValue),
            Int32(dstW), Int32(evenDstH), AV_PIX_FMT_YUV420P,
            Int32(SWS_FAST_BILINEAR.rawValue), nil, nil, nil
        ) else {
            throw TranscodeError.scaler
        }
        defer { sws_freeContext(sws) }

        // Reusable packet + frames.
        guard let packet = av_packet_alloc() else { throw TranscodeError.allocation }
        var packetOpt: UnsafeMutablePointer<AVPacket>? = packet
        defer { av_packet_free(&packetOpt) }

        guard let decFrame = av_frame_alloc() else { throw TranscodeError.allocation }
        var decFrameOpt: UnsafeMutablePointer<AVFrame>? = decFrame
        defer { av_frame_free(&decFrameOpt) }

        guard let scaledFrame = av_frame_alloc() else { throw TranscodeError.allocation }
        var scaledFrameOpt: UnsafeMutablePointer<AVFrame>? = scaledFrame
        defer { av_frame_free(&scaledFrameOpt) }
        scaledFrame.pointee.format = Int32(AV_PIX_FMT_YUV420P.rawValue)
        scaledFrame.pointee.width = Int32(dstW)
        scaledFrame.pointee.height = Int32(evenDstH)
        guard av_frame_get_buffer(scaledFrame, 32) >= 0 else { throw TranscodeError.allocation }

        // Progress bookkeeping.
        let durationSeconds: Double = {
            let d = inputCtx?.pointee.duration ?? 0
            return d > 0 ? Double(d) / Double(AV_TIME_BASE) : 0
        }()
        let videoTimeBase = inVideoStream.pointee.time_base
        var nextOutputPTS: Int64 = 0

        // MARK: Encode one scaled frame
        func encodeAndWrite(_ frame: UnsafeMutablePointer<AVFrame>?) throws {
            guard avcodec_send_frame(encCtx, frame) >= 0 else { throw TranscodeError.encode }
            while true {
                let ret = avcodec_receive_packet(encCtx, packet)
                if ret == AVConst.eagain || ret == AVConst.eof { break }
                guard ret >= 0 else { throw TranscodeError.encode }
                packet.pointee.stream_index = 0
                av_packet_rescale_ts(packet, encCtx.pointee.time_base, outVideoStream.pointee.time_base)
                _ = av_interleaved_write_frame(outputCtx, packet)
                av_packet_unref(packet)
            }
        }

        // MARK: Demux loop
        while av_read_frame(inputCtx, packet) >= 0 {
            // Cooperative cancellation: bail out between packets. Unref the
            // packet we just read so it isn't leaked, then throw.
            if isCancelled?() == true {
                av_packet_unref(packet)
                throw TranscodeError.cancelled
            }

            let streamIdx = packet.pointee.stream_index

            if streamIdx == videoIndex {
                // Decode -> scale -> encode.
                let sendRet = avcodec_send_packet(decCtx, packet)
                av_packet_unref(packet)
                guard sendRet >= 0 else { continue }

                while avcodec_receive_frame(decCtx, decFrame) == 0 {
                    guard av_frame_make_writable(scaledFrame) >= 0 else { continue }

                    // src planes -> scaled YUV420P
                    withUnsafePointer(to: &decFrame.pointee.data.0) { srcDataPtr in
                        withUnsafePointer(to: &decFrame.pointee.linesize.0) { srcLinePtr in
                            withUnsafeMutablePointer(to: &scaledFrame.pointee.data.0) { dstDataPtr in
                                withUnsafeMutablePointer(to: &scaledFrame.pointee.linesize.0) { dstLinePtr in
                                    _ = srcDataPtr.withMemoryRebound(to: UnsafePointer<UInt8>?.self, capacity: 8) { src in
                                        srcLinePtr.withMemoryRebound(to: Int32.self, capacity: 8) { srcLines in
                                            dstDataPtr.withMemoryRebound(to: UnsafeMutablePointer<UInt8>?.self, capacity: 8) { dst in
                                                dstLinePtr.withMemoryRebound(to: Int32.self, capacity: 8) { dstLines in
                                                    sws_scale(sws, src, srcLines, 0, Int32(srcH), dst, dstLines)
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }

                    // Monotonic output PTS in the encoder time base.
                    scaledFrame.pointee.pts = nextOutputPTS
                    nextOutputPTS += 1

                    // Report progress from the decoded frame's timestamp.
                    if let progress, durationSeconds > 0, videoTimeBase.den != 0 {
                        let framePTS = decFrame.pointee.best_effort_timestamp
                        if framePTS != AVConst.noPTS {
                            let seconds = Double(framePTS) * Double(videoTimeBase.num) / Double(videoTimeBase.den)
                            progress(min(1.0, max(0.0, seconds / durationSeconds)))
                        }
                    }

                    try encodeAndWrite(scaledFrame)
                }
            } else if streamIdx == audioIndex, outAudioStreamIndex >= 0,
                      let inAudioStream, let outAudio = outputCtx.pointee.streams[Int(outAudioStreamIndex)] {
                // Audio copy path. Rescale timestamps into the output stream's
                // time base, retag the stream index, and write.
                av_packet_rescale_ts(packet, inAudioStream.pointee.time_base, outAudio.pointee.time_base)
                packet.pointee.stream_index = outAudioStreamIndex
                _ = av_interleaved_write_frame(outputCtx, packet)
                av_packet_unref(packet)
            } else if streamIdx == audioIndex, let audioReencoder {
                // Audio re-encode path (incompatible source codec → AAC).
                audioReencoder.process(packet)
                av_packet_unref(packet)
            } else {
                av_packet_unref(packet)
            }
        }

        // MARK: Flush decoder, then encoder
        avcodec_send_packet(decCtx, nil)
        while avcodec_receive_frame(decCtx, decFrame) == 0 {
            guard av_frame_make_writable(scaledFrame) >= 0 else { continue }
            withUnsafePointer(to: &decFrame.pointee.data.0) { srcDataPtr in
                withUnsafePointer(to: &decFrame.pointee.linesize.0) { srcLinePtr in
                    withUnsafeMutablePointer(to: &scaledFrame.pointee.data.0) { dstDataPtr in
                        withUnsafeMutablePointer(to: &scaledFrame.pointee.linesize.0) { dstLinePtr in
                            _ = srcDataPtr.withMemoryRebound(to: UnsafePointer<UInt8>?.self, capacity: 8) { src in
                                srcLinePtr.withMemoryRebound(to: Int32.self, capacity: 8) { srcLines in
                                    dstDataPtr.withMemoryRebound(to: UnsafeMutablePointer<UInt8>?.self, capacity: 8) { dst in
                                        dstLinePtr.withMemoryRebound(to: Int32.self, capacity: 8) { dstLines in
                                            sws_scale(sws, src, srcLines, 0, Int32(srcH), dst, dstLines)
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
            scaledFrame.pointee.pts = nextOutputPTS
            nextOutputPTS += 1
            try encodeAndWrite(scaledFrame)
        }
        // Drain the video encoder.
        try encodeAndWrite(nil)

        // Flush the audio re-encoder (decoder/resampler/FIFO/encoder tails) so
        // the final audio samples aren't dropped. No-op on the copy path.
        audioReencoder?.finish()

        av_write_trailer(outputCtx)
        progress?(1.0)
    }
}

/// Decodes an MP4-incompatible audio stream (e.g. PCM A-law / µ-law) and
/// re-encodes it to AAC so the output MP4 is valid. Owns its own decoder,
/// AAC encoder, resampler (`SwrContext`, converting the source sample format /
/// rate / layout to what AAC wants), and an audio FIFO — AAC needs fixed-size
/// frames (typically 1024 samples), so decoded audio is buffered and drained in
/// encoder-frame-sized chunks.
///
/// All C work, no shared mutable state; created and driven from the same
/// detached task as the video transcode.
private final class AudioReencoder {
    private let decCtx: UnsafeMutablePointer<AVCodecContext>
    private var decCtxOpt: UnsafeMutablePointer<AVCodecContext>?
    private let encCtx: UnsafeMutablePointer<AVCodecContext>
    private var encCtxOpt: UnsafeMutablePointer<AVCodecContext>?
    private var swr: OpaquePointer?            // SwrContext*
    private var fifo: OpaquePointer?           // AVAudioFifo*
    private let outputCtx: UnsafeMutablePointer<AVFormatContext>
    private let outStreamIndex: Int32
    private let outTimeBase: AVRational

    private var decFrame: UnsafeMutablePointer<AVFrame>?
    private var encFrame: UnsafeMutablePointer<AVFrame>?
    private var packet: UnsafeMutablePointer<AVPacket>?

    /// Running sample count, used to stamp monotonic PTS on encoded frames.
    private var nextPTS: Int64 = 0
    private let frameSize: Int32

    /// Builds the decode→resample→encode pipeline for the source audio stream,
    /// adding an AAC output stream to `outputCtx`. Returns nil if any piece of
    /// the pipeline can't be set up (the caller then proceeds without audio
    /// rather than failing the whole export).
    init?(sourceStream: UnsafeMutablePointer<AVStream>,
          outputCtx: UnsafeMutablePointer<AVFormatContext>,
          globalHeader: Bool) {
        self.outputCtx = outputCtx

        guard let codecpar = sourceStream.pointee.codecpar else { return nil }
        guard let decoder = avcodec_find_decoder(codecpar.pointee.codec_id),
              let dec = avcodec_alloc_context3(decoder) else { return nil }
        self.decCtx = dec
        self.decCtxOpt = dec
        guard avcodec_parameters_to_context(dec, codecpar) >= 0,
              avcodec_open2(dec, decoder, nil) >= 0 else {
            avcodec_free_context(&decCtxOpt)
            return nil
        }

        guard let aacEncoder = avcodec_find_encoder(AV_CODEC_ID_AAC),
              let enc = avcodec_alloc_context3(aacEncoder) else {
            avcodec_free_context(&decCtxOpt)
            return nil
        }
        self.encCtx = enc
        self.encCtxOpt = enc

        // Encoder parameters: keep the source sample rate; use a sane channel
        // layout taken from the decoder (defaulting to stereo if the source
        // layout is unknown); AAC's native sample format is planar float.
        let sampleRate = dec.pointee.sample_rate > 0 ? dec.pointee.sample_rate : 48_000
        enc.pointee.sample_rate = sampleRate
        enc.pointee.sample_fmt = AV_SAMPLE_FMT_FLTP
        enc.pointee.bit_rate = 192_000

        // Channel layout (new AVChannelLayout API, FFmpeg 7/8). Copy the
        // decoder's layout; if it's unspecified, default by channel count.
        if dec.pointee.ch_layout.nb_channels > 0 {
            av_channel_layout_copy(&enc.pointee.ch_layout, &dec.pointee.ch_layout)
        } else {
            av_channel_layout_default(&enc.pointee.ch_layout, 2)
        }

        if globalHeader {
            enc.pointee.flags |= AV_CODEC_FLAG_GLOBAL_HEADER
        }

        guard avcodec_open2(enc, aacEncoder, nil) >= 0 else {
            avcodec_free_context(&decCtxOpt)
            avcodec_free_context(&encCtxOpt)
            return nil
        }

        // AAC reports a fixed frame size once opened; fall back to 1024.
        self.frameSize = enc.pointee.frame_size > 0 ? enc.pointee.frame_size : 1024

        // Output stream carrying the AAC parameters.
        guard let outStream = avformat_new_stream(outputCtx, nil),
              avcodec_parameters_from_context(outStream.pointee.codecpar, enc) >= 0 else {
            avcodec_free_context(&decCtxOpt)
            avcodec_free_context(&encCtxOpt)
            return nil
        }
        outStream.pointee.time_base = AVRational(num: 1, den: sampleRate)
        self.outStreamIndex = Int32(outputCtx.pointee.nb_streams - 1)
        self.outTimeBase = outStream.pointee.time_base

        // Resampler: source (fmt/rate/layout) -> AAC (fltp/sampleRate/layout).
        var swrPtr: OpaquePointer? = nil
        let setRet = swr_alloc_set_opts2(
            &swrPtr,
            &enc.pointee.ch_layout, AV_SAMPLE_FMT_FLTP, sampleRate,
            &dec.pointee.ch_layout, dec.pointee.sample_fmt, dec.pointee.sample_rate,
            0, nil)
        guard setRet >= 0, let swrPtr, swr_init(swrPtr) >= 0 else {
            if swrPtr != nil { var s: OpaquePointer? = swrPtr; swr_free(&s) }
            avcodec_free_context(&decCtxOpt)
            avcodec_free_context(&encCtxOpt)
            return nil
        }
        self.swr = swrPtr

        // FIFO holding resampled samples until a full encoder frame is ready.
        guard let fifo = av_audio_fifo_alloc(AV_SAMPLE_FMT_FLTP,
                                             enc.pointee.ch_layout.nb_channels, 1) else {
            var s: OpaquePointer? = swrPtr; swr_free(&s)
            avcodec_free_context(&decCtxOpt)
            avcodec_free_context(&encCtxOpt)
            return nil
        }
        self.fifo = fifo

        self.decFrame = av_frame_alloc()
        self.encFrame = av_frame_alloc()
        self.packet = av_packet_alloc()
        guard decFrame != nil, encFrame != nil, packet != nil else { return nil }
    }

    deinit {
        avcodec_free_context(&decCtxOpt)
        avcodec_free_context(&encCtxOpt)
        if swr != nil { swr_free(&swr) }
        if let fifo { av_audio_fifo_free(fifo); self.fifo = nil }
        if decFrame != nil { av_frame_free(&decFrame) }
        if encFrame != nil { av_frame_free(&encFrame) }
        if packet != nil { av_packet_free(&packet) }
    }

    /// Feeds one source audio packet through decode → resample → FIFO, then
    /// drains any full encoder frames out to the muxer.
    func process(_ inPacket: UnsafeMutablePointer<AVPacket>) {
        guard avcodec_send_packet(decCtx, inPacket) >= 0 else { return }
        while avcodec_receive_frame(decCtx, decFrame) == 0 {
            resampleIntoFIFO(decFrame)
            av_frame_unref(decFrame)
        }
        drainFIFO(flush: false)
    }

    /// Flushes the decoder, the resampler, and the FIFO, then the encoder, so
    /// the tail samples aren't dropped. Called once after the demux loop ends.
    func finish() {
        // Flush decoder.
        avcodec_send_packet(decCtx, nil)
        while avcodec_receive_frame(decCtx, decFrame) == 0 {
            resampleIntoFIFO(decFrame)
            av_frame_unref(decFrame)
        }
        // Flush any samples buffered inside the resampler.
        flushResampler()
        // Emit whatever remains, even a short final frame.
        drainFIFO(flush: true)
        // Flush the encoder.
        encodeFrame(nil)
    }

    private func resampleIntoFIFO(_ frame: UnsafeMutablePointer<AVFrame>?) {
        guard let swr, let fifo else { return }
        let outChannels = encCtx.pointee.ch_layout.nb_channels
        let inSamples = frame?.pointee.nb_samples ?? 0
        // Upper bound on output samples for this input chunk.
        let maxOut = swr_get_out_samples(swr, inSamples)
        guard maxOut > 0 else { return }

        var converted: UnsafeMutablePointer<UnsafeMutablePointer<UInt8>?>? = nil
        guard av_samples_alloc_array_and_samples(
            &converted, nil, outChannels, maxOut, AV_SAMPLE_FMT_FLTP, 0) >= 0,
              let converted else { return }
        defer {
            if let base = converted[0] { var b: UnsafeMutablePointer<UInt8>? = base; av_freep(&b) }
            var c: UnsafeMutablePointer<UnsafeMutablePointer<UInt8>?>? = converted
            av_freep(&c)
        }

        // swr_convert wants `const uint8_t **` for the input planes. The
        // frame's `extended_data` is the mutable form, so rebind it to the
        // const pointer type the call expects. Nil frame == drain (no input).
        let produced: Int32
        if let frame, let ext = frame.pointee.extended_data {
            produced = ext.withMemoryRebound(to: UnsafePointer<UInt8>?.self, capacity: Int(outChannels)) { inPlanes in
                swr_convert(swr, converted, maxOut, inPlanes, inSamples)
            }
        } else {
            produced = swr_convert(swr, converted, maxOut, nil, inSamples)
        }
        guard produced > 0 else { return }

        av_audio_fifo_realloc(fifo, av_audio_fifo_size(fifo) + produced)
        converted.withMemoryRebound(to: UnsafeMutableRawPointer?.self, capacity: Int(outChannels)) { raw in
            _ = av_audio_fifo_write(fifo, raw, produced)
        }
    }

    private func flushResampler() {
        guard let swr, let fifo else { return }
        let outChannels = encCtx.pointee.ch_layout.nb_channels
        while true {
            let maxOut = swr_get_out_samples(swr, 0)
            guard maxOut > 0 else { break }
            var converted: UnsafeMutablePointer<UnsafeMutablePointer<UInt8>?>? = nil
            guard av_samples_alloc_array_and_samples(
                &converted, nil, outChannels, maxOut, AV_SAMPLE_FMT_FLTP, 0) >= 0,
                  let converted else { break }
            let produced = swr_convert(swr, converted, maxOut, nil, 0)
            if produced > 0 {
                av_audio_fifo_realloc(fifo, av_audio_fifo_size(fifo) + produced)
                converted.withMemoryRebound(to: UnsafeMutableRawPointer?.self, capacity: Int(outChannels)) { raw in
                    _ = av_audio_fifo_write(fifo, raw, produced)
                }
            }
            if let base = converted[0] { var b: UnsafeMutablePointer<UInt8>? = base; av_freep(&b) }
            var c: UnsafeMutablePointer<UnsafeMutablePointer<UInt8>?>? = converted
            av_freep(&c)
            if produced <= 0 { break }
        }
    }

    /// Pulls full `frameSize` chunks (or, on `flush`, a short final chunk) out
    /// of the FIFO, wraps each in an `AVFrame`, and encodes it.
    private func drainFIFO(flush: Bool) {
        guard let fifo, let encFrame else { return }
        while true {
            let available = av_audio_fifo_size(fifo)
            if flush {
                if available <= 0 { break }
            } else if available < frameSize {
                break
            }
            let take = min(frameSize, available)

            av_frame_unref(encFrame)
            encFrame.pointee.nb_samples = take
            av_channel_layout_copy(&encFrame.pointee.ch_layout, &encCtx.pointee.ch_layout)
            encFrame.pointee.format = Int32(AV_SAMPLE_FMT_FLTP.rawValue)
            encFrame.pointee.sample_rate = encCtx.pointee.sample_rate
            guard av_frame_get_buffer(encFrame, 0) >= 0 else { break }

            let read = withUnsafeMutablePointer(to: &encFrame.pointee.data.0) { dataPtr in
                dataPtr.withMemoryRebound(to: UnsafeMutableRawPointer?.self, capacity: 8) { raw in
                    av_audio_fifo_read(fifo, raw, take)
                }
            }
            guard read > 0 else { break }
            encFrame.pointee.nb_samples = read
            encFrame.pointee.pts = nextPTS
            nextPTS += Int64(read)
            encodeFrame(encFrame)
        }
    }

    private func encodeFrame(_ frame: UnsafeMutablePointer<AVFrame>?) {
        guard let packet else { return }
        guard avcodec_send_frame(encCtx, frame) >= 0 else { return }
        while true {
            let ret = avcodec_receive_packet(encCtx, packet)
            if ret == -35 /* EAGAIN */ || ret < 0 { break }
            packet.pointee.stream_index = outStreamIndex
            av_packet_rescale_ts(packet, encCtx.pointee.time_base, outTimeBase)
            _ = av_interleaved_write_frame(outputCtx, packet)
            av_packet_unref(packet)
        }
    }
}
