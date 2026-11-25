#ifndef DISPLAY_VOLUME_AUDIO_GAIN_H
#define DISPLAY_VOLUME_AUDIO_GAIN_H

#include <CoreAudio/CoreAudio.h>
#include <stdbool.h>

typedef struct GainState GainState;

GainState *GainCreate(double sampleRate, unsigned expectedChannels);
void GainDestroy(GainState *state);
void GainSetVolume(GainState *state, float fraction);
void GainEnableOutput(GainState *state);
bool GainSawSignal(GainState *state);
bool GainHasLayoutError(GainState *state);
unsigned GainCallbackCount(GainState *state);
unsigned GainRenderedCallbackCount(GainState *state);
OSStatus GainInstallIOProc(AudioDeviceID device, GainState *state, AudioDeviceIOProcID *id);
bool GainSelfTest(void);

#endif
