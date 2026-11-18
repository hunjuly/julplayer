#define GL_SILENCE_DEPRECATION
#import "VideoEngine.h"
#import <OpenGL/OpenGL.h>
#import <OpenGL/gl3.h>
#import <OpenGL/CGLIOSurface.h>
#import <IOSurface/IOSurface.h>
#import <dlfcn.h>
#import <mpv/client.h>
#import <mpv/render_gl.h>

static void *resolveGL(void *context, const char *name) { return dlsym(RTLD_DEFAULT, name); }
static void frameAvailable(void *context) {
    dispatch_source_merge_data((__bridge dispatch_source_t)context, 1);
}
static id nodeValue(const mpv_node *n) {
    switch (n->format) {
        case MPV_FORMAT_STRING: return @(n->u.string ?: "");
        case MPV_FORMAT_INT64: return @(n->u.int64);
        case MPV_FORMAT_DOUBLE: return @(n->u.double_);
        case MPV_FORMAT_FLAG: return @(n->u.flag != 0);
        case MPV_FORMAT_NODE_ARRAY: {
            NSMutableArray *a = [NSMutableArray array];
            for (int i = 0; i < n->u.list->num; ++i) [a addObject:nodeValue(&n->u.list->values[i])];
            return a;
        }
        case MPV_FORMAT_NODE_MAP: {
            NSMutableDictionary *d = [NSMutableDictionary dictionary];
            for (int i = 0; i < n->u.list->num; ++i)
                d[@(n->u.list->keys[i])] = nodeValue(&n->u.list->values[i]);
            return d;
        }
        default: return NSNull.null;
    }
}

@implementation VideoEngine {
    mpv_handle *_mpv;
    mpv_render_context *_render;
    CGLContextObj _gl;
    GLuint _fbo, _texture;
    dispatch_queue_t _queue;
    dispatch_source_t _frames;
    AVSampleBufferDisplayLayer *_pictureInPictureLayer;
    CVPixelBufferPoolRef _pool;
    CMVideoFormatDescriptionRef _format;
    CMTimebaseRef _clock;
    int _width, _height;
    int64_t _entry;
    BOOL _loaded;
    NSString *_requestedPath;
}

+ (instancetype)makeWithError:(NSError **)error { return [[self alloc] initWithError:error]; }

- (instancetype)initWithError:(NSError **)error {
    if (!(self = [super init])) return nil;
    _displayLayer = [AVSampleBufferDisplayLayer layer];
    _displayLayer.videoGravity = AVLayerVideoGravityResizeAspect;
    _displayLayer.backgroundColor = CGColorGetConstantColor(kCGColorBlack);
    _displayLayer.opaque = YES;
    CMTimebaseCreateWithSourceClock(NULL, CMClockGetHostTimeClock(), &_clock);
    _displayLayer.controlTimebase = _clock;
    _queue = dispatch_queue_create("JulPlayer.video", DISPATCH_QUEUE_SERIAL);
    _mpv = mpv_create();
    int status = MPV_ERROR_NOMEM;
    if (_mpv) {
        NSDictionary *opts = @{@"vo":@"libmpv", @"hwdec":@"videotoolbox-copy", @"config":@"no",
            @"idle":@"yes", @"keep-open":@"yes", @"pause":@"yes", @"osc":@"no",
            @"terminal":@"no", @"load-scripts":@"no", @"sub-auto":@"no", @"audio-file-auto":@"no",
            @"sub-font":@"Apple SD Gothic Neo", @"sub-font-size":@"36", @"sub-margin-y":@"66",
            @"osd-level":@"0", @"input-default-bindings":@"no"};
        for (NSString *key in opts) mpv_set_option_string(_mpv,key.UTF8String,[opts[key] UTF8String]);
        status = mpv_initialize(_mpv);
        if (status >= 0) {
            __block int result;
            dispatch_sync(_queue, ^{ result = [self prepareRenderer]; });
            status = result;
        }
    }
    if (status < 0) {
        if (error) *error = [NSError errorWithDomain:@"JulPlayer" code:status userInfo:@{
            NSLocalizedDescriptionKey: [NSString stringWithFormat:@"영상 출력 초기화 실패 (%s)",mpv_error_string(status)]}];
        [self shutdown];
        return nil;
    }
    _frames = dispatch_source_create(DISPATCH_SOURCE_TYPE_DATA_ADD, 0, 0, _queue);
    __weak VideoEngine *weakSelf = self;
    dispatch_source_set_event_handler(_frames, ^{ @autoreleasepool { [weakSelf renderFrame:NO]; } });
    dispatch_resume(_frames);
    mpv_render_context_set_update_callback(_render, frameAvailable, (__bridge void *)_frames);
    mpv_observe_property(_mpv, 1, "track-list", MPV_FORMAT_NONE);
    mpv_observe_property(_mpv, 2, "sid", MPV_FORMAT_NONE);
    mpv_observe_property(_mpv, 3, "aid", MPV_FORMAT_NONE);
    return self;
}

- (int)prepareRenderer {
    CGLPixelFormatAttribute attrs[] = {kCGLPFAAccelerated, kCGLPFAAllowOfflineRenderers, kCGLPFAOpenGLProfile,
        (CGLPixelFormatAttribute)kCGLOGLPVersion_3_2_Core, (CGLPixelFormatAttribute)0};
    CGLPixelFormatObj fmt = NULL;
    GLint count = 0;
    if (CGLChoosePixelFormat(attrs,&fmt,&count) != kCGLNoError || !fmt) return MPV_ERROR_UNSUPPORTED;
    CGLError result = CGLCreateContext(fmt, NULL, &_gl);
    CGLReleasePixelFormat(fmt);
    if (result != kCGLNoError) return MPV_ERROR_UNSUPPORTED;
    CGLSetCurrentContext(_gl);
    mpv_opengl_init_params glParams = {.get_proc_address = resolveGL};
    mpv_render_param params[] = {
        {MPV_RENDER_PARAM_API_TYPE, (void *)MPV_RENDER_API_TYPE_OPENGL},
        {MPV_RENDER_PARAM_OPENGL_INIT_PARAMS, &glParams}, {0}
    };
    int rc = mpv_render_context_create(&_render, _mpv, params);
    if (rc >= 0) {
        glGenFramebuffers(1, &_fbo);
        glGenTextures(1, &_texture);
    }
    CGLSetCurrentContext(NULL);
    return rc;
}

- (void)sizeToWidth:(int)w height:(int)h {
    if (w <= 0 || h <= 0 || (_width == w && _height == h)) return;
    _width = w; _height = h;
    if (_pool) { CFRelease(_pool); _pool = NULL; }
    if (_format) { CFRelease(_format); _format = NULL; }
    NSDictionary *props = @{
        (id)kCVPixelBufferWidthKey:@(w), (id)kCVPixelBufferHeightKey:@(h),
        (id)kCVPixelBufferPixelFormatTypeKey:@(kCVPixelFormatType_32BGRA),
        (id)kCVPixelBufferIOSurfacePropertiesKey:@{}, (id)kCVPixelBufferOpenGLCompatibilityKey:@YES};
    CVPixelBufferPoolCreate(NULL, NULL, (__bridge CFDictionaryRef)props, &_pool);
}

- (void)renderFrame:(BOOL)forced {
    if (!_render) return;
    CGLSetCurrentContext(_gl);
    uint64_t flags = mpv_render_context_update(_render);
    if ((!forced && !(flags & MPV_RENDER_UPDATE_FRAME)) || !_pool) {
        CGLSetCurrentContext(NULL);
        return;
    }
    if (_displayLayer.status == AVQueuedSampleBufferRenderingStatusFailed) [_displayLayer flush];
    if (_pictureInPictureLayer.status == AVQueuedSampleBufferRenderingStatusFailed) [_pictureInPictureLayer flush];
    CVPixelBufferRef buffer = NULL;
    if (CVPixelBufferPoolCreatePixelBuffer(NULL, _pool, &buffer) != kCVReturnSuccess) {
        CGLSetCurrentContext(NULL);
        return;
    }
    glBindTexture(GL_TEXTURE_RECTANGLE,_texture);
    CGLError err = CGLTexImageIOSurface2D(_gl,GL_TEXTURE_RECTANGLE,GL_RGBA,_width,_height,
                                          GL_BGRA,GL_UNSIGNED_INT_8_8_8_8_REV,CVPixelBufferGetIOSurface(buffer),0);
    glBindFramebuffer(GL_FRAMEBUFFER,_fbo);
    glFramebufferTexture2D(GL_FRAMEBUFFER,GL_COLOR_ATTACHMENT0,GL_TEXTURE_RECTANGLE,_texture,0);
    if (err == kCGLNoError && glCheckFramebufferStatus(GL_FRAMEBUFFER) == GL_FRAMEBUFFER_COMPLETE) {
        mpv_opengl_fbo target = {(int)_fbo,_width,_height,GL_RGBA8};
        int flip = 0, block = 0;
        mpv_render_param params[] = {{MPV_RENDER_PARAM_OPENGL_FBO,&target},{MPV_RENDER_PARAM_FLIP_Y,&flip},
            {MPV_RENDER_PARAM_BLOCK_FOR_TARGET_TIME,&block},{0}};
        if (mpv_render_context_render(_render,params) >= 0) {
            glFinish();
            if (!_format) CMVideoFormatDescriptionCreateForImageBuffer(NULL, buffer, &_format);
            CMSampleTimingInfo timing = {kCMTimeInvalid, CMTimebaseGetTime(_clock), kCMTimeInvalid};
            CMSampleBufferRef sample = NULL;
            if (_format && CMSampleBufferCreateReadyWithImageBuffer(NULL,buffer,_format,&timing,&sample) == noErr) {
                CFArrayRef attachments = CMSampleBufferGetSampleAttachmentsArray(sample,true);
                CFDictionarySetValue((CFMutableDictionaryRef)CFArrayGetValueAtIndex(attachments,0),
                                     kCMSampleAttachmentKey_DisplayImmediately,kCFBooleanTrue);
                [_displayLayer enqueueSampleBuffer:sample];
                [_pictureInPictureLayer enqueueSampleBuffer:sample];
                CFRelease(sample);
            }
        }
    }
    glBindFramebuffer(GL_FRAMEBUFFER,0);
    glBindTexture(GL_TEXTURE_RECTANGLE,0);
    CVPixelBufferRelease(buffer);
    CGLSetCurrentContext(NULL);
}

- (void)setPictureInPictureDisplayLayer:(AVSampleBufferDisplayLayer *)layer {
    dispatch_async(_queue, ^{
        if (self->_pictureInPictureLayer == layer) return;
        [self->_pictureInPictureLayer flushAndRemoveImage];
        self->_pictureInPictureLayer = layer;
        if (layer) [self renderFrame:YES];
    });
}

- (void)clearDisplayedImages {
    [_displayLayer flushAndRemoveImage];
    [_pictureInPictureLayer flushAndRemoveImage];
}

- (BOOL)load:(NSString *)path paused:(BOOL)paused {
    if (!_mpv) return NO;
    _loaded = NO;
    _requestedPath = [path copy];
    while (mpv_wait_event(_mpv,0)->event_id != MPV_EVENT_NONE) {}
    dispatch_async(_queue, ^{ [self clearDisplayedImages]; });
    [self setPaused:paused];
    [self setNumber:0 forOption:@"sub-delay"];
    [self setNumber:0 forOption:@"audio-delay"];
    const char *cmd[] = {"loadfile",path.fileSystemRepresentation,"replace",NULL};
    int rc = mpv_command(_mpv,cmd);
    _entry = -1;
    mpv_get_property(_mpv,"playlist/0/id",MPV_FORMAT_INT64,&_entry);
    return rc >= 0;
}

- (NSDictionary *)poll {
    if (!_mpv) return @{};
    NSMutableDictionary *out = [NSMutableDictionary dictionary];
    BOOL dirty = NO, resize = NO;
    mpv_event *event;
    while ((event = mpv_wait_event(_mpv,0))->event_id != MPV_EVENT_NONE) {
        switch (event->event_id) {
            case MPV_EVENT_FILE_LOADED: {
                char *path = mpv_get_property_string(_mpv,"path");
                NSString *actual = path ? [NSFileManager.defaultManager stringWithFileSystemRepresentation:path length:strlen(path)] : nil;
                BOOL matches = actual && [_requestedPath.precomposedStringWithCanonicalMapping isEqualToString:actual.precomposedStringWithCanonicalMapping];
                if (path) mpv_free(path);
                if (matches) { _loaded = YES; out[@"loaded"] = @YES; dirty = YES; resize = YES; }
                break;
            }
            case MPV_EVENT_END_FILE: {
                mpv_event_end_file *end = event->data;
                if (end->playlist_entry_id != _entry) break;
                if (end->reason == MPV_END_FILE_REASON_EOF) {
                    _loaded = NO;
                    out[@"fileEnded"] = @YES;
                    out[@"playing"] = @NO;
                } else if (end->reason == MPV_END_FILE_REASON_ERROR) {
                    _loaded = NO;
                    out[@"error"] = @(mpv_error_string(end->error));
                }
                break;
            }
            case MPV_EVENT_VIDEO_RECONFIG: resize = YES; break;
            case MPV_EVENT_PROPERTY_CHANGE: dirty = YES; break;
            default: break;
        }
    }
    if (!_loaded) return out;
    if (resize) {
        int64_t w = 0, h = 0;
        mpv_get_property(_mpv,"dwidth",MPV_FORMAT_INT64,&w);
        mpv_get_property(_mpv,"dheight",MPV_FORMAT_INT64,&h);
        if (w > 0 && h > 0) {
            // mpv reports display dimensions before applying the output rotation.
            int64_t rotation = 0;
            mpv_get_property(_mpv,"video-out-params/rotate",MPV_FORMAT_INT64,&rotation);
            if (llabs(rotation % 180) == 90) {
                int64_t unrotatedWidth = w;
                w = h;
                h = unrotatedWidth;
            }
            out[@"displayWidth"] = @(w);
            out[@"displayHeight"] = @(h);
            double scale = fmin(1.0, 4096.0 / MAX(w,h));
            int width = MAX(2,(int)round(w*scale)), height = MAX(2,(int)round(h*scale));
            dispatch_async(_queue, ^{ [self sizeToWidth:width height:height]; [self renderFrame:YES]; });
        }
    }
    if (dirty) out[@"tracks"] = [self trackList];
    double time = 0, duration = 0;
    int paused = 1, eof = 0;
    if (mpv_get_property(_mpv,"time-pos",MPV_FORMAT_DOUBLE,&time) >= 0) out[@"position"] = @(time);
    if (mpv_get_property(_mpv,"duration",MPV_FORMAT_DOUBLE,&duration) >= 0) out[@"duration"] = @(duration);
    mpv_get_property(_mpv,"pause",MPV_FORMAT_FLAG,&paused);
    if (mpv_get_property(_mpv,"eof-reached",MPV_FORMAT_FLAG,&eof) >= 0) out[@"eof"] = @(eof != 0);
    out[@"playing"] = @(!paused && !eof);
    double rate = paused || eof ? 0 : 1;
    if (fabs(CMTimeGetSeconds(CMTimebaseGetTime(_clock)) - time) > 0.20 || CMTimebaseGetRate(_clock) != rate) {
        CMTimebaseSetTime(_clock,CMTimeMakeWithSeconds(time,1000000));
        CMTimebaseSetRate(_clock,rate);
    }
    return out;
}

- (NSArray<NSDictionary<NSString *, id> *> *)trackList {
    mpv_node tracks;
    if (!_mpv || !_loaded || mpv_get_property(_mpv,"track-list",MPV_FORMAT_NODE,&tracks) < 0) return nil;
    NSArray *rows = nodeValue(&tracks);
    mpv_free_node_contents(&tracks);
    return rows;
}

- (void)setPaused:(BOOL)paused {
    if (!_mpv) return;
    int flag = paused;
    mpv_set_property(_mpv,"pause",MPV_FORMAT_FLAG,&flag);
}
- (void)seek:(double)seconds {
    if (!_mpv) return;
    const char *args[] = {"seek",[@(seconds).stringValue UTF8String],"absolute+exact",NULL};
    mpv_command_async(_mpv,0,args);
    CMTimebaseSetTime(_clock,CMTimeMakeWithSeconds(seconds,1000000));
}
- (BOOL)setNumber:(double)value forOption:(NSString *)option {
    if (!_mpv) return NO;
    return mpv_set_property(_mpv,option.UTF8String,MPV_FORMAT_DOUBLE,&value) >= 0;
}
- (BOOL)selectTrack:(NSInteger)track property:(NSString *)property {
    if (!_mpv) return NO;
    NSString *value = track < 0 ? @"no" : @(track).stringValue;
    return mpv_set_property_string(_mpv,property.UTF8String,value.UTF8String) >= 0;
}
- (BOOL)addSubtitle:(NSString *)path select:(BOOL)select {
    if (!_mpv) return NO;
    const char *args[] = {"sub-add",path.fileSystemRepresentation,select ? "cached" : "auto",NULL};
    return mpv_command(_mpv,args) >= 0;
}
- (void)stop {
    if (!_mpv) return;
    _loaded = NO; _requestedPath = nil;
    const char *cmd[] = {"stop",NULL}; mpv_command(_mpv,cmd);
    dispatch_async(_queue, ^{ [self clearDisplayedImages]; });
    CMTimebaseSetRate(_clock,0);
}
- (void)shutdown {
    if (_render) mpv_render_context_set_update_callback(_render,NULL,NULL);
    if (_frames) dispatch_source_cancel(_frames);
    if (_queue) dispatch_sync(_queue, ^{
        if (self->_gl) CGLSetCurrentContext(self->_gl);
        if (self->_render) { mpv_render_context_free(self->_render); self->_render = NULL; }
        if (self->_gl) {
            glDeleteFramebuffers(1,&self->_fbo); glDeleteTextures(1,&self->_texture);
            CGLSetCurrentContext(NULL); CGLReleaseContext(self->_gl); self->_gl = NULL;
        }
        if (self->_pool) { CFRelease(self->_pool); self->_pool = NULL; }
        if (self->_format) { CFRelease(self->_format); self->_format = NULL; }
    });
    if (_mpv) { mpv_terminate_destroy(_mpv); _mpv = NULL; }
    if (_clock) { CFRelease(_clock); _clock = NULL; }
}
@end
