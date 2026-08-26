/* kb_ort.c — thin shim over the onnxruntime C API.
 *
 * The runtime is dlopen'd at runtime (KOKORO_ONNX_LIB env, then
 * <exe>/vendor/libonnxruntime.so.1.28.0, then the soname), so the Nim
 * binary links against nothing onnx-specific. All housekeeping (env,
 * session options, tensor I/O) lives here; Nim sees 4 plain functions.
 */
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <unistd.h>
#include "onnxruntime_c_api.h"

static const OrtApi* api = NULL;
static OrtEnv* env = NULL;
static OrtSession* sess = NULL;
static char errbuf[512];

typedef const OrtApiBase* (*OrtGetApiBaseFn)(void);

static void* open_runtime(void) {
    char self[1024], base[1024], cand[1100];
    const char* envp = getenv("KOKORO_ONNX_LIB");
    if (envp && *envp) {
        void* h = dlopen(envp, RTLD_NOW | RTLD_GLOBAL);
        if (h) return h;
        snprintf(errbuf, sizeof errbuf, "KOKORO_ONNX_LIB %s: %s", envp, dlerror());
        return NULL;
    }
    ssize_t n = readlink("/proc/self/exe", self, sizeof(self) - 1);
    if (n > 0) {
        self[n] = 0;
        char* slash = strrchr(self, '/');
        if (slash) {
            /* try <exedir>/vendor and <exedir>/../vendor (bin/ -> project root) */
            static const char* names[] = {
                "/vendor/libonnxruntime.so.1.28.0",
                "/vendor/libonnxruntime.so.1",
                "/libonnxruntime.so.1.28.0",
                "/libonnxruntime.so.1",
                NULL };
            int d = (int)(slash - self);
            if (d < (int)sizeof(base)) { memcpy(base, self, (size_t)d); base[d] = 0; }
            for (int hop = 0; hop < 2; hop++) {
                if (hop == 1) {
                    /* one level up */
                    char* s2 = strrchr(base, '/');
                    if (!s2) break;
                    *s2 = 0;
                }
                for (int i = 0; names[i]; i++) {
                    snprintf(cand, sizeof cand, "%s%s", base, names[i]);
                    if (access(cand, R_OK) == 0) {
                        void* h = dlopen(cand, RTLD_NOW | RTLD_GLOBAL);
                        if (h) return h;
                    }
                }
            }
        }
    }
    void* h = dlopen("libonnxruntime.so.1", RTLD_NOW | RTLD_GLOBAL);
    if (h) return h;
    snprintf(errbuf, sizeof errbuf, "onnxruntime not found (KOKORO_ONNX_LIB, exe vendor/, soname): %s", dlerror());
    return NULL;
}

static void set_status(OrtStatus* st) {
    const char* msg = api ? api->GetErrorMessage(st) : "no api";
    snprintf(errbuf, sizeof errbuf, "%s", msg ? msg : "?");
}

/* debug env: KB_DEBUG=1 prints feed diagnostics to stderr */
static int dbg_on(void) {
    static int cached = -1;
    if (cached < 0) cached = (getenv("KB_DEBUG") != NULL);
    return cached;
}

int kb_ort_init(const char* model_path, int threads) {
    errbuf[0] = 0;
    if (api) return 0;                    /* already initialized */
    void* h = open_runtime();
    if (!h) return -1;
    OrtGetApiBaseFn gainit = (OrtGetApiBaseFn)dlsym(h, "OrtGetApiBase");
    if (!gainit) {
        snprintf(errbuf, sizeof errbuf, "OrtGetApiBase missing");
        return -1;
    }
    api = gainit()->GetApi(ORT_API_VERSION);
    if (!api) {
        snprintf(errbuf, sizeof errbuf, "GetApi(%d) returned NULL", ORT_API_VERSION);
        return -1;
    }
    OrtStatus* st = api->CreateEnv(ORT_LOGGING_LEVEL_WARNING, "kokoro-beater", &env);
    if (st) { set_status(st); return -1; }
    OrtSessionOptions* opts = NULL;
    st = api->CreateSessionOptions(&opts);
    if (st) { set_status(st); return -1; }
    if (threads > 0) api->SetIntraOpNumThreads(opts, threads);
    api->SetSessionGraphOptimizationLevel(opts, ORT_ENABLE_ALL);
    st = api->CreateSession(env, model_path, opts, &sess);
    api->ReleaseSessionOptions(opts);
    if (st) { set_status(st); return -1; }
    if (dbg_on()) {
        /* dump the session's input names */
        OrtAllocator* alloc = NULL;
        api->GetAllocatorWithDefaultOptions(&alloc);
        size_t n = 0;
        api->SessionGetInputCount(sess, &n);
        fprintf(stderr, "[kb] input count=%zu\n", n);
        for (size_t i = 0; i < n; i++) {
            char* nm = NULL;
            OrtStatus* st2 = api->SessionGetInputName(sess, i, alloc, &nm);
            if (!st2) {
                fprintf(stderr, "  input %zu: %s\n", i, nm);
                api->AllocatorFree(alloc, nm);
            } else {
                api->ReleaseStatus(st2);
            }
        }
        /* runtime input type/shape */
        for (size_t i = 0; i < n; i++) {
            OrtTypeInfo* ti = NULL;
            OrtStatus* st3 = api->SessionGetInputTypeInfo(sess, i, &ti);
            if (st3) { api->ReleaseStatus(st3); continue; }
            const OrtTensorTypeAndShapeInfo* tsi = NULL;
            api->CastTypeInfoToTensorInfo(ti, &tsi);
            if (tsi) {
                ONNXTensorElementDataType dt = ONNX_TENSOR_ELEMENT_DATA_TYPE_UNDEFINED;
                api->GetTensorElementType(tsi, &dt);
                size_t nd = 0;
                api->GetDimensionsCount(tsi, &nd);
                int64_t dvals[8] = {0};
                size_t readn = nd < 8 ? nd : 8;
                api->GetDimensions(tsi, dvals, readn);
                fprintf(stderr, "  type %zu: elem=%d ndim=%zu dims=", i, (int)dt, nd);
                for (size_t d2 = 0; d2 < readn; d2++) {
                    fprintf(stderr, "%lld%s", (long long)dvals[d2], d2 + 1 < readn ? "," : "");
                }
                fprintf(stderr, "\n");
            }
            api->ReleaseTypeInfo(ti);
        }
    }
    return 0;
}

int kb_ort_synth(const int64_t* tokens, int ntok,
                 const float* style,        /* [256] */
                 float speed,
                 float** out, int64_t* out_n) {
    OrtValue *in_toks = NULL, *in_style = NULL, *in_speed = NULL, *outv = NULL;
    OrtMemoryInfo* mem = NULL;
    OrtStatus* st = NULL;
    *out = NULL; *out_n = 0;
    if (!api || !sess) { snprintf(errbuf, sizeof errbuf, "kb_ort not initialized"); return -1; }

    st = api->CreateCpuMemoryInfo(OrtArenaAllocator, OrtMemTypeDefault, &mem);
    if (st) goto fail;

    { int64_t shape[2] = {1, ntok};
      st = api->CreateTensorWithDataAsOrtValue(mem, (void*)tokens, (size_t)ntok * 8,
          shape, 2, ONNX_TENSOR_ELEMENT_DATA_TYPE_INT64, &in_toks);
      if (st) goto fail; }
    { int64_t shape[2] = {1, 256};
      st = api->CreateTensorWithDataAsOrtValue(mem, (void*)style, 256 * 4,
          shape, 2, ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT, &in_style);
      if (st) goto fail; }
    { int64_t shape[1] = {1};
      st = api->CreateTensorWithDataAsOrtValue(mem, (void*)&speed, 4,
          shape, 1, ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT, &in_speed);
      if (st) goto fail; }

    {
      if (dbg_on()) {
        fprintf(stderr, "[kb] feed tokens[0..%d]=", ntok);
        for (int i = 0; i < (ntok < 20 ? ntok : 20); i++) fprintf(stderr, "%lld,", (long long)tokens[i]);
        fprintf(stderr, " style[0]=%f speed=%f\n", style[0], (double)speed);
      }
      const char* names[3] = {"tokens", "style", "speed"};
      const OrtValue* inputs[3] = {in_toks, in_style, in_speed};
      const char* oname = "audio";
      st = api->Run(sess, NULL, names, inputs, 3, &oname, 1, &outv);
      if (st) {
        /* augment the error with what we fed */
        const char* em = api->GetErrorMessage(st);
        snprintf(errbuf, sizeof errbuf, "%s [fed tokens=%d style=%d speed=%d]", em, ntok, 256, 1);
        goto fail;
      }
    }

    {
      OrtTensorTypeAndShapeInfo* ti = NULL;
      st = api->GetTensorTypeAndShape(outv, &ti);
      if (st) goto fail;
      size_t n = 0;
      api->GetTensorShapeElementCount(ti, &n);
      api->ReleaseTensorTypeAndShapeInfo(ti);
      void* p = NULL;
      st = api->GetTensorMutableData(outv, &p);
      if (st) goto fail;
      float* copy = (float*)malloc(n * sizeof(float));
      if (!copy) { snprintf(errbuf, sizeof errbuf, "oom"); goto fail; }
      memcpy(copy, p, n * sizeof(float));
      *out = copy;
      *out_n = (int64_t)n;
    }

    api->ReleaseMemoryInfo(mem);
    api->ReleaseValue(in_toks);
    api->ReleaseValue(in_style);
    api->ReleaseValue(in_speed);
    if (outv) api->ReleaseValue(outv);
    return 0;

fail:
    if (st) set_status(st);
    if (mem) api->ReleaseMemoryInfo(mem);
    if (in_toks) api->ReleaseValue(in_toks);
    if (in_style) api->ReleaseValue(in_style);
    if (in_speed) api->ReleaseValue(in_speed);
    if (outv) api->ReleaseValue(outv);
    return -1;
}

const char* kb_ort_error(void) { return errbuf; }
void kb_ort_free(void* p) { free(p); }