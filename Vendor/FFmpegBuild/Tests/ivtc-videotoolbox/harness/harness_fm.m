// Compares the kernels of metal/vf_fieldmatch_videotoolbox.metal against FFmpeg's CPU
// fieldmatch (vf_fieldmatch.c, compiled in below), number by number:
//   - compare_fields' six sums (Pc, Pm, Pml, Nc, Nm, Nml) for every match pair and field,
//   - calc_combed_score for every candidate weave,
//   - luma_abs_diff.
// The only change to vf_fieldmatch.c is one added line that copies the six sums out
// (see build.sh); the arithmetic is untouched.
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <stdlib.h>

#include "libavutil/internal.h"
static uint64_t g_acc[6];
#include "vf_fieldmatch_instrumented.c"

// ---- the GPU side: the same parameter structs and dispatch shapes as the wrapper ----
struct fmvt_diff_map_params { uint32_t width, height, channels, pbase, nbase, nk; };
struct fmvt_match_sums_params { uint32_t width, channels, fbase1, fbase2, nk, startx, stopx; int32_t y0a, y1a; uint32_t seg, nseg; };
struct fmvt_comb_params { uint32_t width, height, alt_parity; int32_t cthresh; uint32_t xhalf, yhalf, nhx, nhy; };
struct fmvt_luma_diff_params { uint32_t width, height, seg, nseg; };
#define SEG 64

static id<MTLDevice> dev;
static id<MTLCommandQueue> queue;
static id<MTLComputePipelineState> pso[5];
enum { K_DIFF_MAP, K_MATCH_SUMS, K_COMB_MASK, K_COMB_COUNT, K_LUMA_DIFF };

static void run(int k, void (^bind)(id<MTLComputeCommandEncoder>), NSUInteger w, NSUInteger h)
{
    id<MTLCommandBuffer> cb = [queue commandBuffer];
    id<MTLComputeCommandEncoder> e = [cb computeCommandEncoder];
    [e setComputePipelineState:pso[k]];
    bind(e);
    NSUInteger tw = pso[k].threadExecutionWidth, th = pso[k].maxTotalThreadsPerThreadgroup / tw;
    [e dispatchThreads:MTLSizeMake(w, h, 1) threadsPerThreadgroup:MTLSizeMake(tw, th, 1)];
    [e endEncoding];
    [cb commit];
    [cb waitUntilCompleted];
}

// One frame as the wrapper sees it: Y as R8Uint, UV interleaved as RG8Uint.
typedef struct { id<MTLTexture> t[2]; } GTex;

static GTex upload(const AVFrame *f)
{
    GTex g;
    int w = f->width, h = f->height, cw = (w + 1) / 2, ch = (h + 1) / 2;
    MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatR8Uint width:w height:h mipmapped:NO];
    d.usage = MTLTextureUsageShaderRead;
    g.t[0] = [dev newTextureWithDescriptor:d];
    [g.t[0] replaceRegion:MTLRegionMake2D(0, 0, w, h) mipmapLevel:0 withBytes:f->data[0] bytesPerRow:f->linesize[0]];
    d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRG8Uint width:cw height:ch mipmapped:NO];
    d.usage = MTLTextureUsageShaderRead;
    g.t[1] = [dev newTextureWithDescriptor:d];
    uint8_t *uv = malloc(cw * ch * 2);
    for (int y = 0; y < ch; y++)
        for (int x = 0; x < cw; x++) {
            uv[(y * cw + x) * 2    ] = f->data[1][y * f->linesize[1] + x];
            uv[(y * cw + x) * 2 + 1] = f->data[2][y * f->linesize[2] + x];
        }
    [g.t[1] replaceRegion:MTLRegionMake2D(0, 0, cw, ch) mipmapLevel:0 withBytes:uv bytesPerRow:cw * 2];
    free(uv);
    return g;
}

static int frame_of(int match) { return (match == mP || match == mB) ? 0 : match == mC ? 1 : 2; }
static int weave_alt_parity(int match, int field) { return (match == mP || match == mN) ? field : 1 - field; }

// compare_fields' sums on the GPU, set up exactly as measure() in the wrapper.
static void gpu_compare(FieldMatchContext *fm, GTex g[3], int match1, int match2, int field, uint64_t acc[6])
{
    const int fbase1 = get_field_base(match1, field), fbase2 = get_field_base(match2, field);
    const int prvbranch = (match1 >= 3 && field == 1) || (match1 < 3 && field != 1);
    const int w = fm->src->width, h = fm->src->height;
    memset(acc, 0, 6 * sizeof(*acc));
    for (int p = 0; p < (fm->mchroma ? 2 : 1); p++) {
        const int pw = p ? (w + 1) / 2 : w, ph = p ? (h + 1) / 2 : h, chn = p ? 2 : 1;
        const int startx = p ? 4 : 8, stopx = pw - startx, nk = (ph - 3) / 2;
        const int nseg = stopx > startx ? (stopx - startx + SEG - 1) / SEG : 0;
        id<MTLBuffer> map = [dev newBufferWithLength:pw * ph * chn options:MTLResourceStorageModePrivate];
        id<MTLBuffer> part = [dev newBufferWithLength:MAX(nk * nseg, 1) * 6 * 4 options:MTLResourceStorageModeShared];
        struct fmvt_diff_map_params dp = { pw, ph, chn, prvbranch ? fbase1 - 2 : fbase1, prvbranch ? fbase2 - 2 : fbase2, nk };
        id<MTLTexture> a = g[frame_of(match1)].t[p], b = g[frame_of(match2)].t[p], s = g[1].t[p];
        run(K_DIFF_MAP, ^(id<MTLComputeCommandEncoder> e) {
            [e setTexture:a atIndex:0]; [e setTexture:b atIndex:1];
            [e setBuffer:map offset:0 atIndex:0]; [e setBytes:&dp length:sizeof(dp) atIndex:1]; }, pw, ph);
        if (!nseg || !nk)
            continue;
        struct fmvt_match_sums_params mp = { pw, chn, fbase1, fbase2, nk, startx, stopx,
                                             fm->y0 >> (p ? 1 : 0), fm->y1 >> (p ? 1 : 0), SEG, nseg };
        run(K_MATCH_SUMS, ^(id<MTLComputeCommandEncoder> e) {
            [e setTexture:s atIndex:0]; [e setTexture:a atIndex:1]; [e setTexture:b atIndex:2];
            [e setBuffer:map offset:0 atIndex:0]; [e setBuffer:part offset:0 atIndex:1];
            [e setBytes:&mp length:sizeof(mp) atIndex:2]; }, nseg, nk);
        const uint32_t *v = part.contents;
        for (int i = 0; i < nk * nseg; i++)
            for (int j = 0; j < 6; j++)
                acc[j] += v[i * 6 + j];
    }
}

// calc_combed_score of one candidate on the GPU, then the wrapper's block reconstruction.
static int gpu_comb(FieldMatchContext *fm, GTex g[3], int match, int field)
{
    const int w = fm->src->width, h = fm->src->height;
    const int xhalf = fm->blockx / 2, yhalf = fm->blocky / 2;
    const int nhx = (w + xhalf - 1) / xhalf, nhy = (h + yhalf - 1) / yhalf;
    const int xblocks = ((w + xhalf) / fm->blockx) + 1, yblocks = ((h + yhalf) / fm->blocky) + 1;
    const int xblocks4 = xblocks << 2, size = (xblocks * yblocks) << 2;
    id<MTLBuffer> mask = [dev newBufferWithLength:w * h options:MTLResourceStorageModePrivate];
    id<MTLBuffer> half = [dev newBufferWithLength:nhx * nhy * 4 options:MTLResourceStorageModeShared];
    struct fmvt_comb_params cp = { w, h, match == mC ? 0 : weave_alt_parity(match, field), fm->cthresh, xhalf, yhalf, nhx, nhy };
    id<MTLTexture> s = g[1].t[0], alt = g[frame_of(match)].t[0];
    run(K_COMB_MASK, ^(id<MTLComputeCommandEncoder> e) {
        [e setTexture:s atIndex:0]; [e setTexture:alt atIndex:1];
        [e setBuffer:mask offset:0 atIndex:0]; [e setBytes:&cp length:sizeof(cp) atIndex:1]; }, w, h);
    run(K_COMB_COUNT, ^(id<MTLComputeCommandEncoder> e) {
        [e setBuffer:mask offset:0 atIndex:0]; [e setBuffer:half offset:0 atIndex:1];
        [e setBytes:&cp length:sizeof(cp) atIndex:2]; }, nhx, nhy);
    int *c = calloc(size, sizeof(int)), max_v = 0;
    const uint32_t *hv = half.contents;
    for (int hy = 0; hy < nhy; hy++)
        for (int hx = 0; hx < nhx; hx++) {
            int v = hv[hy * nhx + hx], t1 = (hy >> 1) * xblocks4, t2 = ((hy + 1) >> 1) * xblocks4;
            int b1 = (hx >> 1) * 4, b2 = ((hx + 1) >> 1) * 4;
            c[t1 + b1] += v; c[t1 + b2 + 1] += v; c[t2 + b1 + 2] += v; c[t2 + b2 + 3] += v;
        }
    for (int i = 0; i < size; i++)
        if (c[i] > max_v)
            max_v = c[i];
    free(c);
    return max_v;
}

static int64_t gpu_luma_diff(GTex *a, GTex *b, int w, int h)
{
    const int nseg = (w + SEG - 1) / SEG;
    id<MTLBuffer> part = [dev newBufferWithLength:nseg * h * 4 options:MTLResourceStorageModeShared];
    struct fmvt_luma_diff_params lp = { w, h, SEG, nseg };
    id<MTLTexture> ta = a->t[0], tb = b->t[0];
    run(K_LUMA_DIFF, ^(id<MTLComputeCommandEncoder> e) {
        [e setTexture:ta atIndex:0]; [e setTexture:tb atIndex:1];
        [e setBuffer:part offset:0 atIndex:0]; [e setBytes:&lp length:sizeof(lp) atIndex:1]; }, nseg, h);
    int64_t sum = 0;
    const uint32_t *v = part.contents;
    for (int i = 0; i < nseg * h; i++)
        sum += v[i];
    return sum;
}

// ---- content ----
static uint32_t rng = 12345;
static uint32_t rnd(void) { rng = rng * 1664525u + 1013904223u; return rng >> 8; }

static AVFrame *new_frame(int w, int h)
{
    AVFrame *f = av_frame_alloc();
    f->width = w; f->height = h; f->format = AV_PIX_FMT_YUV420P;
    av_frame_get_buffer(f, 32);
    return f;
}

// Styles: 0 noise, 1 still gradient, 2 moving hard edges, 3 telecine-like (fields from two
// moving pictures), 4 flat with sparse spikes (the 3 / 19 / 23 / 42 thresholds), 5 low noise.
static void fill(AVFrame *f, int style, int t)
{
    for (int p = 0; p < 3; p++) {
        int w = p ? (f->width + 1) / 2 : f->width, h = p ? (f->height + 1) / 2 : f->height;
        for (int y = 0; y < h; y++)
            for (int x = 0; x < w; x++) {
                int v;
                switch (style) {
                case 0: v = rnd() & 255; break;
                case 1: v = (x * 3 + y * 2 + p * 40) & 255; break;
                case 2: v = (((x + t * 7) / 9 + (y + t * 3) / 5) & 1) ? 220 : 30; break;
                case 3: { int tt = (y & 1) ? t : t + 1; v = (((x + tt * 11) / 13) & 1) ? 200 : 50; v += (rnd() & 15); break; }
                case 4: v = 128 + ((rnd() % 20 == 0) ? (int)(rnd() % 120) - 60 : 0); break;
                default: v = 100 + (int)(rnd() % 9); break;
                }
                f->data[p][y * f->linesize[p] + x] = av_clip_uint8(v);
            }
    }
}

static void cpu_weave(FieldMatchContext *fm, AVFrame *dst, int match, int field)
{
    switch (match) {
    case mP: copy_fields(fm, dst, fm->src, 1-field, INPUT_MAIN); copy_fields(fm, dst, fm->prv,   field, INPUT_MAIN); break;
    case mN: copy_fields(fm, dst, fm->src, 1-field, INPUT_MAIN); copy_fields(fm, dst, fm->nxt,   field, INPUT_MAIN); break;
    case mB: copy_fields(fm, dst, fm->src,   field, INPUT_MAIN); copy_fields(fm, dst, fm->prv, 1-field, INPUT_MAIN); break;
    case mU: copy_fields(fm, dst, fm->src,   field, INPUT_MAIN); copy_fields(fm, dst, fm->nxt, 1-field, INPUT_MAIN); break;
    }
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
        const char *names[5] = { "diff_map", "match_sums", "comb_mask", "comb_count", "luma_diff" };
        for (int i = 0; i < 5; i++)
            pso[i] = [dev newComputePipelineStateWithFunction:[lib newFunctionWithName:@(names[i])] error:&err];

        static const int sizes[][2] = { {32,16}, {37,16}, {40,20}, {64,24}, {100,36}, {176,144}, {333,100}, {720,480}, {720,576}, {1920,1080} };
        static const int cthr[] = { -1, 0, 4, 9, 20 };
        static const int blocks[][2] = { {16,16}, {4,4}, {8,32}, {32,8} };
        long cases = 0, values = 0, diffs = 0;

        for (int si = 0; si < (int)(sizeof(sizes) / sizeof(sizes[0])); si++) {
            const int w = sizes[si][0], h = sizes[si][1];
            for (int style = 0; style < 6; style++) {
                FieldMatchContext fmc = { 0 }, *fm = &fmc;
                AVFrame *fr[3];
                for (int i = 0; i < 3; i++) { fr[i] = new_frame(w, h); fill(fr[i], style, i); }
                if (style == 1) { av_frame_copy(fr[0], fr[1]); av_frame_copy(fr[2], fr[1]); }   // nothing moves
                fm->prv = fr[0]; fm->src = fr[1]; fm->nxt = fr[2];
                fm->hsub[0] = fm->vsub[0] = 1; fm->bpc = 1;
                av_image_alloc(fm->map_data, fm->map_linesize, w, h, AV_PIX_FMT_YUV420P, 32);
                av_image_alloc(fm->cmask_data, fm->cmask_linesize, w, h, AV_PIX_FMT_YUV420P, 32);
                fm->tpitchy = FFALIGN(w, 16); fm->tpitchuv = FFALIGN(w >> 1, 16);
                fm->tbuffer = av_calloc((h/2 + 4) * fm->tpitchy, 1);
                GTex g[3] = { upload(fr[0]), upload(fr[1]), upload(fr[2]) };

                // compare_fields: every ordered pair of p, c and n, both fields, chroma on and
                // off, with and without an exclusion band. vf_fieldmatch.c only ever calls it
                // with these (c against p or n, and in the pcn modes p against n). A pair that
                // mixes p/c/n with b/u makes the CPU code read the row above the plane
                // (nxtp -= nxt_linesize with a field base of 1), so it has no fixed answer.
                for (int mc = 0; mc < 2; mc++)
                for (int band = 0; band < 2; band++)
                for (int field = 0; field < 2; field++)
                for (int m1 = 0; m1 < 3; m1++)
                for (int m2 = 0; m2 < 3; m2++) {
                    if (m1 == m2) continue;
                    uint64_t acc[6];
                    fm->mchroma = mc; fm->y0 = band ? h / 4 : 0; fm->y1 = band ? h / 2 : 0;
                    compare_fields(fm, m1, m2, field);
                    gpu_compare(fm, g, m1, m2, field, acc);
                    cases++;
                    for (int j = 0; j < 6; j++, values++)
                        if (acc[j] != g_acc[j]) {
                            if (diffs++ < 10)
                                printf("DIFF compare %dx%d style %d mchroma %d band %d field %d %d/%d sum %d: cpu %llu gpu %llu\n",
                                       w, h, style, mc, band, field, m1, m2, j, (unsigned long long)g_acc[j], (unsigned long long)acc[j]);
                        }
                }

                // calc_combed_score: every candidate weave, field, cthresh and block size.
                for (int bi = 0; bi < 4; bi++) {
                    fm->blockx = blocks[bi][0]; fm->blocky = blocks[bi][1];
                    fm->c_array = av_malloc_array((((w + fm->blockx/2)/fm->blockx)+1) * (((h + fm->blocky/2)/fm->blocky)+1), 4 * sizeof(int));
                    for (int ci = 0; ci < 5; ci++)
                    for (int field = 0; field < 2; field++)
                    for (int m = 0; m < 5; m++) {
                        fm->cthresh = cthr[ci]; fm->chroma = 0;
                        AVFrame *wv = fm->src;
                        if (m != mC) { wv = new_frame(w, h); cpu_weave(fm, wv, m, field); }
                        int cpu = calc_combed_score(fm, wv), gpu = gpu_comb(fm, g, m, field);
                        if (m != mC) av_frame_free(&wv);
                        cases++; values++;
                        if (cpu != gpu && diffs++ < 10)
                            printf("DIFF comb %dx%d style %d block %dx%d cthresh %d field %d match %d: cpu %d gpu %d\n",
                                   w, h, style, fm->blockx, fm->blocky, fm->cthresh, field, m, cpu, gpu);
                    }
                    av_freep(&fm->c_array);
                }

                // luma_abs_diff
                for (int i = 0; i < 2; i++) {
                    int64_t cpu = luma_abs_diff(fr[i], fr[i + 1]), gpu = gpu_luma_diff(&g[i], &g[i + 1], w, h);
                    cases++; values++;
                    if (cpu != gpu && diffs++ < 10)
                        printf("DIFF luma %dx%d style %d: cpu %lld gpu %lld\n", w, h, style, (long long)cpu, (long long)gpu);
                }

                for (int i = 0; i < 3; i++) av_frame_free(&fr[i]);
                av_freep(&fm->map_data[0]); av_freep(&fm->cmask_data[0]); av_freep(&fm->tbuffer);
            }
            printf("%dx%d done\n", w, h);
            fflush(stdout);
        }
        printf("fieldmatch kernels: %ld cases, %ld values compared, %ld differences\n", cases, values, diffs);
        return diffs != 0;
    }
}
