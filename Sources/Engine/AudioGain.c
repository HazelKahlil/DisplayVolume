#include "AudioGain.h"

#include <math.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>

#define DV_MAX_CHANNELS 8

struct GainState {
    atomic_int target;
    atomic_bool outputEnabled;
    atomic_bool sawSignal;
    atomic_bool layoutError;
    atomic_uint callbackCount;
    unsigned expectedChannels;
    float gain;
    float step;
    float destination;
    unsigned rampLength;
    unsigned remaining;
};

GainState *GainCreate(double sampleRate, unsigned expectedChannels) {
    if (expectedChannels == 0 || expectedChannels > DV_MAX_CHANNELS) return NULL;
    GainState *state = calloc(1, sizeof(*state));
    if (!state) return NULL;
    atomic_init(&state->target, 0);
    atomic_init(&state->outputEnabled, false);
    atomic_init(&state->sawSignal, false);
    atomic_init(&state->layoutError, false);
    atomic_init(&state->callbackCount, 0);
    state->expectedChannels = expectedChannels;
    state->rampLength = (unsigned)fmax(1.0, sampleRate * 0.010);
    return state;
}

void GainDestroy(GainState *state) { free(state); }
void GainEnableOutput(GainState *state) { atomic_store(&state->outputEnabled, true); }
bool GainSawSignal(GainState *state) { return atomic_load(&state->sawSignal); }
bool GainHasLayoutError(GainState *state) { return atomic_load(&state->layoutError); }
unsigned GainCallbackCount(GainState *state) { return atomic_load(&state->callbackCount); }

void GainSetVolume(GainState *state, float fraction) {
    float volume = fminf(1.0f, fmaxf(0.0f, fraction));
    atomic_store(&state->target, (int)lroundf(volume * volume * 1000000.0f));
}

typedef struct {
    const AudioBuffer *buffers[DV_MAX_CHANNELS];
    unsigned channels;
    unsigned frames;
    unsigned stride;
} AudioLayout;

static AudioLayout parseLayout(const AudioBufferList *list, unsigned expectedChannels) {
    AudioLayout empty = {{0}, 0, 0, 0};
    if (!list || list->mNumberBuffers == 0) return empty;
    const AudioBuffer *buffers = list->mBuffers;

    // Interleaved: 1 buffer containing `channels` interleaved Float32 channels.
    if (list->mNumberBuffers == 1) {
        unsigned ch = buffers[0].mNumberChannels;
        if (ch == 0 || ch > DV_MAX_CHANNELS || ch != expectedChannels) return empty;
        if (!buffers[0].mData) return empty;
        size_t frameBytes = (size_t)ch * sizeof(float);
        if (buffers[0].mDataByteSize % frameBytes != 0) return empty;
        AudioLayout layout = {{0}, ch, (unsigned)(buffers[0].mDataByteSize / frameBytes), ch};
        for (unsigned c = 0; c < ch; c++) layout.buffers[c] = &buffers[0];
        return layout;
    }

    // Planar: `channels` separate mono Float32 buffers of equal frame length.
    if (list->mNumberBuffers == expectedChannels && list->mNumberBuffers <= DV_MAX_CHANNELS) {
        unsigned ch = list->mNumberBuffers;
        unsigned refBytes = buffers[0].mDataByteSize;
        if (refBytes % sizeof(float) != 0) return empty;
        AudioLayout layout = {{0}, ch, (unsigned)(refBytes / sizeof(float)), 1};
        for (unsigned c = 0; c < ch; c++) {
            if (buffers[c].mNumberChannels != 1 || !buffers[c].mData || buffers[c].mDataByteSize != refBytes) {
                return empty;
            }
            layout.buffers[c] = &buffers[c];
        }
        return layout;
    }

    return empty;
}

static inline void zeroOutputBuffers(AudioBufferList *output) {
    if (!output) return;
    for (unsigned i = 0; i < output->mNumberBuffers; i++) {
        AudioBuffer *buffer = &output->mBuffers[i];
        if (buffer->mData) memset(buffer->mData, 0, buffer->mDataByteSize);
    }
}

static OSStatus render(
    AudioDeviceID device,
    const AudioTimeStamp *now,
    const AudioBufferList *input,
    const AudioTimeStamp *inputTime,
    AudioBufferList *output,
    const AudioTimeStamp *outputTime,
    void *context
) {
    (void)device; (void)now; (void)inputTime; (void)outputTime;
    GainState *state = context;
    atomic_fetch_add_explicit(&state->callbackCount, 1, memory_order_relaxed);

    AudioLayout source = parseLayout(input, state->expectedChannels);
    AudioLayout sink = parseLayout(output, state->expectedChannels);

    if (!sink.frames || (input && input->mNumberBuffers && !source.stride)) {
        zeroOutputBuffers(output);
        atomic_store(&state->layoutError, true);
        return noErr;
    }
    if (!source.frames) {
        zeroOutputBuffers(output);
        return noErr;
    }

    unsigned frames = source.frames < sink.frames ? source.frames : sink.frames;
    unsigned channels = state->expectedChannels;

    // Hoist per-channel base pointers once per callback (avoid inner-loop pointer arithmetic).
    const float *inBases[DV_MAX_CHANNELS];
    float *outBases[DV_MAX_CHANNELS];
    for (unsigned c = 0; c < channels; c++) {
        inBases[c] = (const float *)source.buffers[c]->mData + (source.stride > 1 ? c : 0);
        outBases[c] = (float *)sink.buffers[c]->mData + (sink.stride > 1 ? c : 0);
    }

    if (!atomic_load_explicit(&state->outputEnabled, memory_order_relaxed)) {
        zeroOutputBuffers(output);
        if (atomic_load_explicit(&state->sawSignal, memory_order_relaxed)) return noErr;
        unsigned inStride = source.stride;
        for (unsigned c = 0; c < channels; c++) {
            const float *inPtr = inBases[c];
            for (unsigned i = 0; i < frames; i++) {
                if (fabsf(inPtr[i * inStride]) > 0.0001f) {
                    atomic_store(&state->sawSignal, true);
                    return noErr;
                }
            }
        }
        return noErr;
    }

    float target = (float)atomic_load_explicit(&state->target, memory_order_relaxed) / 1000000.0f;
    if (target != state->destination) {
        state->destination = target;
        state->remaining = state->rampLength;
        state->step = (target - state->gain) / (float)state->remaining;
    }

    unsigned inStride = source.stride;
    unsigned outStride = sink.stride;

    if (state->remaining == 0) {
        // Steady-state fast path: zero unnecessary memset + SIMD auto-vectorizable loops.
        float g = state->gain;
        if (g == 0.0f) {
            zeroOutputBuffers(output);
            return noErr;
        }
        if (inStride == 1 && outStride == 1) {
            for (unsigned c = 0; c < channels; c++) {
                const float *inPtr = inBases[c];
                float *outPtr = outBases[c];
                for (unsigned i = 0; i < frames; i++) {
                    outPtr[i] = inPtr[i] * g;
                }
            }
        } else if (inStride == channels && outStride == channels) {
            const float *inInterleaved = (const float *)source.buffers[0]->mData;
            float *outInterleaved = (float *)sink.buffers[0]->mData;
            unsigned totalSamples = frames * channels;
            for (unsigned s = 0; s < totalSamples; s++) {
                outInterleaved[s] = inInterleaved[s] * g;
            }
        } else {
            for (unsigned c = 0; c < channels; c++) {
                const float *inPtr = inBases[c];
                float *outPtr = outBases[c];
                for (unsigned i = 0; i < frames; i++) {
                    outPtr[i * outStride] = inPtr[i * inStride] * g;
                }
            }
        }
    } else {
        for (unsigned i = 0; i < frames; i++) {
            if (state->remaining) {
                state->gain += state->step;
                if (--state->remaining == 0) state->gain = state->destination;
            }
            float g = state->gain;
            for (unsigned c = 0; c < channels; c++) {
                outBases[c][i * outStride] = inBases[c][i * inStride] * g;
            }
        }
    }

    // Only zero unmatched tail frames if sink is larger than source.
    if (sink.frames > frames) {
        for (unsigned c = 0; c < channels; c++) {
            float *outPtr = outBases[c];
            for (unsigned i = frames; i < sink.frames; i++) {
                outPtr[i * outStride] = 0.0f;
            }
        }
    }
    return noErr;
}

OSStatus GainInstallIOProc(AudioDeviceID device, GainState *state, AudioDeviceIOProcID *id) {
    return AudioDeviceCreateIOProcID(device, render, state, id);
}

bool GainSelfTest(void) {
    // 1. Stereo interleaved -> planar probe, quadratic scaling, mute, and layout rejection
    GainState *state = GainCreate(100, 2);
    if (!state) return false;
    float input[] = {0.8f, -0.4f, -0.2f, 0.5f};
    float left[3] = {1, 1, 1}, right[3] = {1, 1, 1};
    AudioBufferList source = {1, {{2, sizeof(input), input}}};
    struct { UInt32 count; AudioBuffer buffers[2]; } sink = {
        2, {{1, sizeof(left), left}, {1, sizeof(right), right}}
    };
    AudioBufferList *destination = (AudioBufferList *)&sink;

    render(0, NULL, &source, NULL, destination, NULL, state);
    bool probe = GainSawSignal(state) && left[0] == 0 && right[0] == 0;

    GainEnableOutput(state);
    GainSetVolume(state, 0.5f); // gain = 0.25
    render(0, NULL, &source, NULL, destination, NULL, state);
    bool scaled = fabsf(left[0] - 0.2f) < 0.000001f && fabsf(right[0] + 0.1f) < 0.000001f &&
        fabsf(left[1] + 0.05f) < 0.000001f && fabsf(right[1] - 0.125f) < 0.000001f &&
        left[2] == 0 && right[2] == 0;

    GainSetVolume(state, 0.0f);
    render(0, NULL, &source, NULL, destination, NULL, state);
    bool muted = left[0] == 0 && right[0] == 0 && left[1] == 0 && right[1] == 0;

    source.mBuffers[0].mNumberChannels = 1;
    render(0, NULL, &source, NULL, destination, NULL, state);
    bool rejected = GainHasLayoutError(state);
    GainDestroy(state);

    // 2. Multichannel (4ch) interleaved -> interleaved & ramp smoothness + steady-state SIMD fast path
    GainState *quad = GainCreate(400, 4); // rampLength = 4 frames
    if (!quad) return false;
    float qIn[16];
    float qOut[16];
    for (int i = 0; i < 16; i++) qIn[i] = 1.0f;
    AudioBufferList qSrc = {1, {{4, sizeof(qIn), qIn}}};
    AudioBufferList qDst = {1, {{4, sizeof(qOut), qOut}}};
    GainEnableOutput(quad);
    GainSetVolume(quad, 1.0f);
    render(0, NULL, &qSrc, NULL, &qDst, NULL, quad);
    bool quadRampOK = !GainHasLayoutError(quad)
        && fabsf(qOut[0] - 0.25f) < 0.001f
        && fabsf(qOut[4] - 0.50f) < 0.001f
        && fabsf(qOut[8] - 0.75f) < 0.001f
        && fabsf(qOut[12] - 1.0f) < 0.001f
        && fabsf(qOut[15] - 1.0f) < 0.001f;

    // Second render hits steady-state (remaining == 0) interleaved fast path without prior memset.
    for (int i = 0; i < 16; i++) { qIn[i] = 0.6f; qOut[i] = -99.0f; }
    render(0, NULL, &qSrc, NULL, &qDst, NULL, quad);
    bool quadSteadyOK = fabsf(qOut[0] - 0.6f) < 0.001f && fabsf(qOut[15] - 0.6f) < 0.001f;

    // Zero-gain steady-state silence path.
    GainSetVolume(quad, 0.0f);
    render(0, NULL, &qSrc, NULL, &qDst, NULL, quad); // ramp down to 0
    for (int i = 0; i < 16; i++) qOut[i] = 42.0f;
    render(0, NULL, &qSrc, NULL, &qDst, NULL, quad); // steady-state g == 0
    bool quadMuteOK = qOut[0] == 0.0f && qOut[15] == 0.0f;
    GainDestroy(quad);

    // 3. Steady-state planar path with tail-zeroing when sink.frames > source.frames
    GainState *planar = GainCreate(100, 2); // rampLength = 1 frame
    if (!planar) return false;
    float pInL[2] = {0.8f, -0.4f}, pInR[2] = {-0.2f, 0.5f};
    float pOutL[3] = {9, 9, 9}, pOutR[3] = {9, 9, 9};
    struct { UInt32 count; AudioBuffer buffers[2]; } pSrcS = {
        2, {{1, sizeof(pInL), pInL}, {1, sizeof(pInR), pInR}}
    };
    struct { UInt32 count; AudioBuffer buffers[2]; } pDstS = {
        2, {{1, sizeof(pOutL), pOutL}, {1, sizeof(pOutR), pOutR}}
    };
    GainEnableOutput(planar);
    GainSetVolume(planar, 0.5f); // gain = 0.25
    render(0, NULL, (AudioBufferList *)&pSrcS, NULL, (AudioBufferList *)&pDstS, NULL, planar);
    pOutL[2] = 7.0f; pOutR[2] = 7.0f;
    render(0, NULL, (AudioBufferList *)&pSrcS, NULL, (AudioBufferList *)&pDstS, NULL, planar);
    bool planarSteadyTailOK = fabsf(pOutL[0] - 0.2f) < 0.0001f
        && fabsf(pOutR[1] - 0.125f) < 0.0001f
        && pOutL[2] == 0.0f && pOutR[2] == 0.0f;
    GainDestroy(planar);

    return probe && scaled && muted && rejected && quadRampOK && quadSteadyOK && quadMuteOK && planarSteadyTailOK;
}
