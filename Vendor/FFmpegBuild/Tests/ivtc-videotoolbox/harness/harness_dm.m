// Compares the kernel of metal/vf_decimate_videotoolbox.metal against FFmpeg's CPU
// decimate metric (calc_diffs in vf_decimate.c, compiled in unchanged below):
// maxbdiff and totdiff for every frame pair, block size and chroma setting.
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <stdlib.h>

#include "libavutil/internal.h"
#include "libavfilter/vf_decimate.c"

struct dmvt_block_diff_params { uint32_t width, height, channels, hblockx, hblocky, ncx, ncy, stride; };

static id<MTLDevice> dev;
static id<MTLCommandQueue> queue;
static id<MTLComputePipelineState> pso;

static uint32_t rng = 777;
static uint32_t rnd(void) { rng = rng * 1664525u + 1013904223u; return rng >> 8; }

static AVFrame *new_frame(int w, int h, int style, int t)
{
    AVFrame *f = av_frame_alloc();
    f->width = w; f->height = h; f->format = AV_PIX_FMT_YUV420P;
    av_frame_get_buffer(f, 32);
    for (int p = 0; p < 3; p++) {
        int pw = p ? (w + 1) / 2 : w, ph = p ? (h + 1) / 2 : h;
        for (int y = 0; y < ph; y++)
            for (int x = 0; x < pw; x++) {
                int v = style == 0 ? (int)(rnd() & 255)
                      : style == 1 ? (x + y + p * 50) & 255
                      : (((x + t * 5) / 7) & 1) ? 230 : 20;
                f->data[p][y * f->linesize[p] + x] = v;
            }
    }
    return f;
}

static id<MTLTexture> plane_tex(const AVFrame *f, int p)
{
    int w = p ? (f->width + 1) / 2 : f->width, h = p ? (f->height + 1) / 2 : f->height;
    MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:p ? MTLPixelFormatRG8Uint : MTLPixelFormatR8Uint
                                                                                 width:w height:h mipmapped:NO];
    id<MTLTexture> t = [dev newTextureWithDescriptor:d];
    if (!p) {
        [t replaceRegion:MTLRegionMake2D(0, 0, w, h) mipmapLevel:0 withBytes:f->data[0] bytesPerRow:f->linesize[0]];
    } else {
        uint8_t *uv = malloc(w * h * 2);
        for (int y = 0; y < h; y++)
            for (int x = 0; x < w; x++) {
                uv[(y * w + x) * 2] = f->data[1][y * f->linesize[1] + x];
                uv[(y * w + x) * 2 + 1] = f->data[2][y * f->linesize[2] + x];
            }
        [t replaceRegion:MTLRegionMake2D(0, 0, w, h) mipmapLevel:0 withBytes:uv bytesPerRow:w * 2];
        free(uv);
    }
    return t;
}

// The wrapper's submit_diffs + collect_metrics, inline.
static void gpu_diffs(DecimateContext *dm, const AVFrame *f1, const AVFrame *f2, int64_t *maxbdiff, int64_t *totdiff)
{
    const int w = f1->width, h = f1->height, np = dm->chroma ? 2 : 1;
    int64_t *bd = calloc(dm->bdiffsize, sizeof(int64_t)), maxdiff = -1;
    for (int p = 0; p < np; p++) {
        int pw = p ? (w + 1) / 2 : w, ph = p ? (h + 1) / 2 : h;
        int hbx = p ? (dm->blockx / 2) >> dm->hsub : dm->blockx / 2, hby = p ? (dm->blocky / 2) >> dm->vsub : dm->blocky / 2;
        struct dmvt_block_diff_params bp = { pw, ph, p ? 2 : 1, hbx, hby, (pw + hbx - 1) / hbx, (ph + hby - 1) / hby, dm->nxblocks };
        id<MTLBuffer> out = [dev newBufferWithLength:dm->bdiffsize * 4 options:MTLResourceStorageModeShared];
        id<MTLCommandBuffer> cb = [queue commandBuffer];
        id<MTLComputeCommandEncoder> e = [cb computeCommandEncoder];
        [e setComputePipelineState:pso];
        [e setTexture:plane_tex(f1, p) atIndex:0]; [e setTexture:plane_tex(f2, p) atIndex:1];
        [e setBuffer:out offset:0 atIndex:0]; [e setBytes:&bp length:sizeof(bp) atIndex:1];
        NSUInteger tw = pso.threadExecutionWidth, th = pso.maxTotalThreadsPerThreadgroup / tw;
        [e dispatchThreads:MTLSizeMake(bp.ncx, bp.ncy, 1) threadsPerThreadgroup:MTLSizeMake(tw, th, 1)];
        [e endEncoding]; [cb commit]; [cb waitUntilCompleted];
        const uint32_t *v = out.contents;
        for (uint32_t cy = 0; cy < bp.ncy; cy++)
            for (uint32_t cx = 0; cx < bp.ncx; cx++)
                bd[cy * dm->nxblocks + cx] += v[cy * dm->nxblocks + cx];
    }
    for (int i = 0; i < dm->nyblocks - 1; i++)
        for (int j = 0; j < dm->nxblocks - 1; j++) {
            int64_t tmp = bd[i * dm->nxblocks + j] + bd[i * dm->nxblocks + j + 1]
                        + bd[(i + 1) * dm->nxblocks + j] + bd[(i + 1) * dm->nxblocks + j + 1];
            if (tmp > maxdiff) maxdiff = tmp;
        }
    *totdiff = 0;
    for (int i = 0; i < dm->bdiffsize; i++) *totdiff += bd[i];
    *maxbdiff = maxdiff;
    free(bd);
}

int main(int argc, char **argv)
{
    @autoreleasepool {
        dev = MTLCreateSystemDefaultDevice();
        queue = [dev newCommandQueue];
        NSError *err = nil;
        NSString *src = [NSString stringWithContentsOfFile:@(argv[1]) encoding:NSUTF8StringEncoding error:&err];
        id<MTLLibrary> lib = [dev newLibraryWithSource:src options:nil error:&err];
        if (!lib) { fprintf(stderr, "metal: %s\n", err.description.UTF8String); return 1; }
        pso = [dev newComputePipelineStateWithFunction:[lib newFunctionWithName:@"block_diff"] error:&err];

        static const int sizes[][2] = { {16,16}, {17,9}, {37,23}, {64,48}, {333,101}, {720,480}, {720,576}, {1920,1080} };
        static const int blocks[][2] = { {32,32}, {4,4}, {8,16}, {16,8}, {64,64}, {512,512} };
        long cases = 0, diffs = 0;
        for (int si = 0; si < 8; si++)
        for (int style = 0; style < 3; style++) {
            const int w = sizes[si][0], h = sizes[si][1];
            AVFrame *a = new_frame(w, h, style, 0), *b = new_frame(w, h, style, 1);
            for (int bi = 0; bi < 6; bi++)
            for (int chroma = 0; chroma < 2; chroma++) {
                DecimateContext dmc = { 0 }, *dm = &dmc;
                struct qitem q;
                int64_t gmax, gtot;
                dm->blockx = blocks[bi][0]; dm->blocky = blocks[bi][1]; dm->chroma = chroma;
                dm->hsub = dm->vsub = 1; dm->depth = 8;
                dm->nxblocks = (w + dm->blockx/2 - 1) / (dm->blockx/2);
                dm->nyblocks = (h + dm->blocky/2 - 1) / (dm->blocky/2);
                dm->bdiffsize = dm->nxblocks * dm->nyblocks;
                dm->bdiffs = av_malloc_array(dm->bdiffsize, sizeof(*dm->bdiffs));
                calc_diffs(dm, &q, a, b);
                gpu_diffs(dm, a, b, &gmax, &gtot);
                cases++;
                if ((q.maxbdiff != gmax || q.totdiff != gtot) && diffs++ < 10)
                    printf("DIFF %dx%d style %d block %dx%d chroma %d: cpu %lld/%lld gpu %lld/%lld\n", w, h, style,
                           dm->blockx, dm->blocky, chroma, (long long)q.maxbdiff, (long long)q.totdiff, (long long)gmax, (long long)gtot);
                av_freep(&dm->bdiffs);
            }
            av_frame_free(&a); av_frame_free(&b);
        }
        printf("decimate kernel: %ld cases (maxbdiff and totdiff each), %ld differences\n", cases, diffs);
        return diffs != 0;
    }
}
