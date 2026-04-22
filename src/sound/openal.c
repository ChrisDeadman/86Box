/*
 * 86Box    A hypervisor and IBM PC system emulator that specializes in
 *          running old operating systems and software designed for IBM
 *          PC systems and compatibles from 1981 through fairly recent
 *          system designs based on the PCI bus.
 *
 *          This file is part of the 86Box distribution.
 *
 *          Interface to the OpenAL sound processing library.
 *
 * Authors: Sarah Walker, <https://pcem-emulator.co.uk/>
 *          Miran Grca, <mgrca8@gmail.com>
 *
 *          Copyright 2008-2019 Sarah Walker.
 *          Copyright 2016-2019 Miran Grca.
 */
#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <stdbool.h>
#include <string.h>
#undef AL_API
#undef ALC_API
#define AL_LIBTYPE_STATIC
#define ALC_LIBTYPE_STATIC

#include "AL/al.h"
#include "AL/alc.h"
#include "AL/alext.h"
#include <86box/86box.h>
#include <86box/midi.h>
#include <86box/sound.h>
#include <86box/thread.h>
#include <86box/plat_unused.h>

#define FREQ   SOUND_FREQ
#define BUFLEN SOUNDBUFLEN

#define AL_STREAM_BUFFER_COUNT         4
#define AL_DEFAULT_MIDI_FREQ           44100
#define AL_DEFAULT_MIDI_BUFFER_SAMPLES 4410

/* The async mailbox must hold the largest chunk any current producer can submit.
    OPL4 MIDI is the largest today: 48 kHz stereo rendered in 10 segments at 100 Hz. */
#define AL_STAGE_SAMPLES               ((FREQ_48000 / 100) * 2 * 10)

enum {
    I_NORMAL = 0,
    I_MUSIC,
    I_WT,
    I_CD,
    I_FDD,
    I_HDD,
    I_MIDI,
    AL_SOURCE_COUNT,
    AL_SOURCE_COUNT_NO_MIDI = I_MIDI,
};

ALuint        buffers[AL_STREAM_BUFFER_COUNT];       /* front and back buffers */
ALuint        buffers_music[AL_STREAM_BUFFER_COUNT]; /* front and back buffers */
ALuint        buffers_wt[AL_STREAM_BUFFER_COUNT];    /* front and back buffers */
ALuint        buffers_cd[AL_STREAM_BUFFER_COUNT];    /* front and back buffers */
ALuint        buffers_fdd[AL_STREAM_BUFFER_COUNT];   /* front and back buffers */
ALuint        buffers_hdd[AL_STREAM_BUFFER_COUNT];   /* front and back buffers */
ALuint        buffers_midi[AL_STREAM_BUFFER_COUNT];  /* front and back buffers */
static ALuint source[AL_SOURCE_COUNT];               /* audio sources */

static int         midi_freq     = AL_DEFAULT_MIDI_FREQ;
static int         midi_buf_size = AL_DEFAULT_MIDI_BUFFER_SAMPLES;
static int         initialized   = 0;
static int         sources       = AL_SOURCE_COUNT_NO_MIDI;
static int         midi_enabled  = 0;
static int         al_atexit_registered = 0;
static ALCcontext *Context;
static ALCdevice  *Device;

typedef struct {
    int          pending;
    int          size;
    int          freq;
    union {
        float   f[AL_STAGE_SAMPLES];
        int16_t i[AL_STAGE_SAMPLES];
    } data;
} al_stage_t;

static al_stage_t   al_stage[AL_SOURCE_COUNT];
static mutex_t     *al_stage_mutex[AL_SOURCE_COUNT];
static thread_t    *al_thread_h;
static event_t     *al_thread_event;
static event_t     *al_thread_start_event;
static volatile int al_thread_running;
static void         al_thread_func(void *param);

static int          al_sample_bytes(void);
static ALenum       al_buffer_format(void);
static void         al_configure_source(ALuint source_id);
static void         al_destroy_stage_mutexes(void);
static void         al_queue_source(const uint8_t src, ALuint *buffer_set);

void
al_set_midi(const int freq, const int buf_size)
{
    midi_freq     = freq;
    if (buf_size > 0)
        midi_buf_size = (buf_size <= AL_STAGE_SAMPLES) ? buf_size : AL_STAGE_SAMPLES;
}

const char *
sound_get_output_devices(void)
{
    if (alcIsExtensionPresent(NULL, "ALC_ENUMERATE_ALL_EXT"))
        return alcGetString(NULL, ALC_ALL_DEVICES_SPECIFIER);
    if (alcIsExtensionPresent(NULL, "ALC_ENUMERATION_EXT"))
        return alcGetString(NULL, ALC_DEVICE_SPECIFIER);
    return NULL;
}

static int
al_sample_bytes(void)
{
    return sound_is_float ? (int) sizeof(float) : (int) sizeof(int16_t);
}

static ALenum
al_buffer_format(void)
{
    return sound_is_float ? AL_FORMAT_STEREO_FLOAT32 : AL_FORMAT_STEREO16;
}

static void
al_configure_source(const ALuint source_id)
{
    alSource3f(source_id, AL_POSITION, 0.0f, 0.0f, 0.0f);
    alSource3f(source_id, AL_VELOCITY, 0.0f, 0.0f, 0.0f);
    alSource3f(source_id, AL_DIRECTION, 0.0f, 0.0f, 0.0f);
    alSourcef(source_id, AL_ROLLOFF_FACTOR, 0.0f);
    alSourcei(source_id, AL_SOURCE_RELATIVE, AL_TRUE);
}

static void
al_destroy_stage_mutexes(void)
{
    for (int i = 0; i < AL_SOURCE_COUNT; i++) {
        if (al_stage_mutex[i] != NULL) {
            thread_close_mutex(al_stage_mutex[i]);
            al_stage_mutex[i] = NULL;
        }
    }
}

static void
al_queue_source(const uint8_t src, ALuint *buffer_set)
{
    alSourceQueueBuffers(source[src], AL_STREAM_BUFFER_COUNT, buffer_set);
    alSourcePlay(source[src]);
}

ALvoid
alutInit(UNUSED(ALint *argc), UNUSED(ALbyte **argv))
{
    /* Open device: use the user-selected device, or NULL for system default */
    const ALCchar *dev_name = (sound_output_device[0] != '\0') ? sound_output_device : NULL;
    Context = NULL;
    Device  = NULL;

    Device = alcOpenDevice(dev_name);
    if (Device == NULL)
        return;

    /* Create context(s) */
    Context = alcCreateContext(Device, NULL);
    if (Context == NULL) {
        alcCloseDevice(Device);
        Device = NULL;
        return;
    }

    /* Set active context */
    if (!alcMakeContextCurrent(Context)) {
        alcDestroyContext(Context);
        Context = NULL;
        alcCloseDevice(Device);
        Device = NULL;
    }
}

ALvoid
alutExit(ALvoid)
{
    if (Context != NULL) {
        /* Disable context */
        alcMakeContextCurrent(NULL);

        /* Release context(s) */
        alcDestroyContext(Context);
        Context = NULL;
    }

    if (Device != NULL) {
        /* Close device */
        alcCloseDevice(Device);
        Device = NULL;
    }
}

void
closeal(void)
{
    if (!initialized)
        return;

    const int had_midi_enabled = midi_enabled;

    /* Block new submissions before producer threads are joined. */
    initialized = 0;

    sound_cd_thread_end();
    sound_fdd_thread_end();
    sound_hdd_thread_end();

    /* Stop the async audio thread first. */
    if (al_thread_running) {
        al_thread_running = 0;
        thread_set_event(al_thread_event);
        thread_wait(al_thread_h);
        thread_destroy_event(al_thread_event);
        thread_destroy_event(al_thread_start_event);
        al_thread_h           = NULL;
        al_thread_event       = NULL;
        al_thread_start_event = NULL;
    }

    al_destroy_stage_mutexes();

    /* Re-acquire the context for cleanup. */
    alcMakeContextCurrent(Context);

    alSourceStopv(sources, source);
    alDeleteSources(sources, source);

    if (had_midi_enabled)
        alDeleteBuffers(AL_STREAM_BUFFER_COUNT, buffers_midi);
    alDeleteBuffers(AL_STREAM_BUFFER_COUNT, buffers_fdd);
    alDeleteBuffers(AL_STREAM_BUFFER_COUNT, buffers_hdd);
    alDeleteBuffers(AL_STREAM_BUFFER_COUNT, buffers_cd);
    alDeleteBuffers(AL_STREAM_BUFFER_COUNT, buffers_wt);
    alDeleteBuffers(AL_STREAM_BUFFER_COUNT, buffers_music);
    alDeleteBuffers(AL_STREAM_BUFFER_COUNT, buffers);

    alutExit();

    midi_enabled = 0;
}

void
inital(void)
{
    float   *buf             = NULL;
    float   *music_buf       = NULL;
    float   *wt_buf          = NULL;
    float   *cd_buf          = NULL;
    float   *midi_buf        = NULL;
    float   *fdd_buf         = NULL;
    float   *hdd_buf         = NULL;
    int16_t *buf_int16       = NULL;
    int16_t *music_buf_int16 = NULL;
    int16_t *wt_buf_int16    = NULL;
    int16_t *cd_buf_int16    = NULL;
    int16_t *midi_buf_int16  = NULL;
    int16_t *fdd_buf_int16   = NULL;
    int16_t *hdd_buf_int16   = NULL;

    if (initialized)
        return;

    alutInit(0, 0);

    if (Context == NULL)
        return;

    if (!al_atexit_registered) {
        atexit(closeal);
        al_atexit_registered = 1;
    }

    const char *mdn = midi_out_device_get_internal_name(midi_output_device_current);
    midi_enabled = (strcmp(mdn, "none") != 0) && (strcmp(mdn, SYSTEM_MIDI_INTERNAL_NAME) != 0);

    sources = midi_enabled ? AL_SOURCE_COUNT : AL_SOURCE_COUNT_NO_MIDI;
    if (sound_is_float) {
        buf       = (float *) calloc((BUFLEN << 1), sizeof(float));
        music_buf = (float *) calloc((MUSICBUFLEN << 1), sizeof(float));
        wt_buf    = (float *) calloc((WTBUFLEN << 1), sizeof(float));
        cd_buf    = (float *) calloc((CD_BUFLEN << 1), sizeof(float));
        fdd_buf   = (float *) calloc((BUFLEN << 1), sizeof(float));
        hdd_buf   = (float *) calloc((BUFLEN << 1), sizeof(float));
        if (midi_enabled)
            midi_buf = (float *) calloc(midi_buf_size, sizeof(float));
    } else {
        buf_int16       = (int16_t *) calloc((BUFLEN << 1), sizeof(int16_t));
        music_buf_int16 = (int16_t *) calloc((MUSICBUFLEN << 1), sizeof(int16_t));
        wt_buf_int16    = (int16_t *) calloc((WTBUFLEN << 1), sizeof(int16_t));
        cd_buf_int16    = (int16_t *) calloc((CD_BUFLEN << 1), sizeof(int16_t));
        fdd_buf_int16   = (int16_t *) calloc((BUFLEN << 1), sizeof(int16_t));
        hdd_buf_int16   = (int16_t *) calloc((BUFLEN << 1), sizeof(int16_t));
        if (midi_enabled)
            midi_buf_int16 = (int16_t *) calloc(midi_buf_size, sizeof(int16_t));
    }

    alGenBuffers(AL_STREAM_BUFFER_COUNT, buffers);
    alGenBuffers(AL_STREAM_BUFFER_COUNT, buffers_cd);
    alGenBuffers(AL_STREAM_BUFFER_COUNT, buffers_fdd);
    alGenBuffers(AL_STREAM_BUFFER_COUNT, buffers_hdd);
    alGenBuffers(AL_STREAM_BUFFER_COUNT, buffers_music);
    alGenBuffers(AL_STREAM_BUFFER_COUNT, buffers_wt);
    if (midi_enabled)
        alGenBuffers(AL_STREAM_BUFFER_COUNT, buffers_midi);

    alGenSources(sources, source);

    for (int i = 0; i < sources; i++)
        al_configure_source(source[i]);

    if (sound_is_float) {
        memset(buf, 0, BUFLEN * 2 * sizeof(float));
        memset(cd_buf, 0, CD_BUFLEN * 2 * sizeof(float));
        memset(music_buf, 0, MUSICBUFLEN * 2 * sizeof(float));
        memset(wt_buf, 0, WTBUFLEN * 2 * sizeof(float));
        memset(fdd_buf, 0, BUFLEN * 2 * sizeof(float));
        memset(hdd_buf, 0, BUFLEN * 2 * sizeof(float));
        if (midi_enabled)
            memset(midi_buf, 0, midi_buf_size * sizeof(float));
    } else {
        memset(buf_int16, 0, BUFLEN * 2 * sizeof(int16_t));
        memset(cd_buf_int16, 0, CD_BUFLEN * 2 * sizeof(int16_t));
        memset(music_buf_int16, 0, MUSICBUFLEN * 2 * sizeof(int16_t));
        memset(wt_buf_int16, 0, WTBUFLEN * 2 * sizeof(int16_t));
        memset(fdd_buf_int16, 0, BUFLEN * 2 * sizeof(int16_t));
        memset(hdd_buf_int16, 0, BUFLEN * 2 * sizeof(int16_t));
        if (midi_enabled)
            memset(midi_buf_int16, 0, midi_buf_size * sizeof(int16_t));
    }

    for (uint8_t c = 0; c < AL_STREAM_BUFFER_COUNT; c++) {
        if (sound_is_float) {
            alBufferData(buffers[c], AL_FORMAT_STEREO_FLOAT32, buf, BUFLEN * 2 * sizeof(float), FREQ);
            alBufferData(buffers_music[c], AL_FORMAT_STEREO_FLOAT32, music_buf, MUSICBUFLEN * 2 * sizeof(float), MUSIC_FREQ);
            alBufferData(buffers_wt[c], AL_FORMAT_STEREO_FLOAT32, wt_buf, WTBUFLEN * 2 * sizeof(float), WT_FREQ);
            alBufferData(buffers_cd[c], AL_FORMAT_STEREO_FLOAT32, cd_buf, CD_BUFLEN * 2 * sizeof(float), CD_FREQ);
            alBufferData(buffers_fdd[c], AL_FORMAT_STEREO_FLOAT32, fdd_buf, BUFLEN * 2 * sizeof(float), FREQ);
            alBufferData(buffers_hdd[c], AL_FORMAT_STEREO_FLOAT32, hdd_buf, BUFLEN * 2 * sizeof(float), FREQ);
            if (midi_enabled)
                alBufferData(buffers_midi[c], AL_FORMAT_STEREO_FLOAT32, midi_buf, midi_buf_size * (int) sizeof(float), midi_freq);
        } else {
            alBufferData(buffers[c], AL_FORMAT_STEREO16, buf_int16, BUFLEN * 2 * sizeof(int16_t), FREQ);
            alBufferData(buffers_music[c], AL_FORMAT_STEREO16, music_buf_int16, MUSICBUFLEN * 2 * sizeof(int16_t), MUSIC_FREQ);
            alBufferData(buffers_wt[c], AL_FORMAT_STEREO16, wt_buf_int16, WTBUFLEN * 2 * sizeof(int16_t), WT_FREQ);
            alBufferData(buffers_cd[c], AL_FORMAT_STEREO16, cd_buf_int16, CD_BUFLEN * 2 * sizeof(int16_t), CD_FREQ);
            alBufferData(buffers_fdd[c], AL_FORMAT_STEREO16, fdd_buf_int16, BUFLEN * 2 * sizeof(int16_t), FREQ);
            alBufferData(buffers_hdd[c], AL_FORMAT_STEREO16, hdd_buf_int16, BUFLEN * 2 * sizeof(int16_t), FREQ);
            if (midi_enabled)
                alBufferData(buffers_midi[c], AL_FORMAT_STEREO16, midi_buf_int16, midi_buf_size * (int) sizeof(int16_t), midi_freq);
        }
    }

    al_queue_source(I_NORMAL, buffers);
    al_queue_source(I_MUSIC, buffers_music);
    al_queue_source(I_WT, buffers_wt);
    al_queue_source(I_CD, buffers_cd);
    al_queue_source(I_FDD, buffers_fdd);
    al_queue_source(I_HDD, buffers_hdd);
    if (midi_enabled)
        al_queue_source(I_MIDI, buffers_midi);

    if (sound_is_float) {
        if (midi_enabled)
            free(midi_buf);
        free(cd_buf);
        free(wt_buf);
        free(music_buf);
        free(buf);
        free(fdd_buf);
        free(hdd_buf);
    } else {
        if (midi_enabled)
            free(midi_buf_int16);
        free(cd_buf_int16);
        free(wt_buf_int16);
        free(music_buf_int16);
        free(buf_int16);
        free(fdd_buf_int16);
        free(hdd_buf_int16);
    }

    /* Start the async audio submission thread.
       Release the OpenAL context from this thread — the audio thread
       will make it current on its own thread. */
    memset(al_stage, 0, sizeof(al_stage));
    for (int i = 0; i < AL_SOURCE_COUNT; i++)
        al_stage_mutex[i] = thread_create_mutex();
    al_thread_running     = 1;
    al_thread_start_event = thread_create_event();
    al_thread_event       = thread_create_event();
    alcMakeContextCurrent(NULL);
    al_thread_h           = thread_create(al_thread_func, NULL);

    thread_wait_event(al_thread_start_event, -1);
    thread_reset_event(al_thread_start_event);

    initialized = 1;
}

extern bool fast_forward;

/* --- Async audio submission thread ---
 *
 * All OpenAL buffer operations are offloaded here so the emulation
 * timer thread never blocks on the audio driver.  Each source has a
 * single-slot mailbox: the emulation thread writes new audio data
 * into the staging buffer and sets a flag; the audio thread picks it
 * up and does the actual alBufferData / alSourceQueueBuffers work.
 */

/* The actual OpenAL submission — runs on the audio thread only. */
static void
al_submit(const uint8_t src, const void *buf, const int size, const int freq)
{
    ALint  processed;
    ALint  state;

    alGetSourcei(source[src], AL_SOURCE_STATE, &state);
    alGetSourcei(source[src], AL_BUFFERS_PROCESSED, &processed);

    if (processed < 1) {
        if (state == AL_STOPPED)
            alSourcePlay(source[src]);
        return;
    }

    alListenerf(AL_GAIN, sound_muted ? 0.0f
                       : (float) pow(10.0, (double) sound_gain / 20.0));

    const ALenum fmt = al_buffer_format();
    const int    bps = al_sample_bytes();

    if (state == AL_STOPPED) {
        /* Underrun recovery — drain all stale buffers and refill with current
           audio so alSourcePlay doesn't replay old data.  A brief repeated
           chunk is far less audible than stale content from the past. */
        ALuint buf_ids[AL_STREAM_BUFFER_COUNT];
        alSourceUnqueueBuffers(source[src], processed, buf_ids);
        for (int i = 0; i < processed; i++)
            alBufferData(buf_ids[i], fmt, buf, size * bps, freq);
        alSourceQueueBuffers(source[src], processed, buf_ids);
        alSourcePlay(source[src]);
    } else {
        /* Normal operation — swap exactly one buffer.  Any additional
           processed buffers are left for the next call; dequeuing more
           than one would duplicate the same audio chunk → stutter. */
        ALuint buf_id;
        alSourceUnqueueBuffers(source[src], 1, &buf_id);
        alBufferData(buf_id, fmt, buf, size * bps, freq);
        alSourceQueueBuffers(source[src], 1, &buf_id);
    }
}

static void
al_thread_func(UNUSED(void *param))
{
    al_stage_t stage;

    /* OpenAL requires the context to be current on the calling thread. */
    alcMakeContextCurrent(Context);

    thread_set_event(al_thread_start_event);

    while (al_thread_running) {
        thread_wait_event(al_thread_event, -1);
        thread_reset_event(al_thread_event);

        if (!al_thread_running)
            break;

        for (int i = 0; i < AL_SOURCE_COUNT; i++) {
            thread_wait_mutex(al_stage_mutex[i]);
            if (!al_stage[i].pending) {
                thread_release_mutex(al_stage_mutex[i]);
                continue;
            }

            stage.pending = 0;
            stage.size    = al_stage[i].size;
            stage.freq    = al_stage[i].freq;
            if (sound_is_float)
                memcpy(stage.data.f, al_stage[i].data.f, stage.size * sizeof(float));
            else
                memcpy(stage.data.i, al_stage[i].data.i, stage.size * sizeof(int16_t));
            al_stage[i].pending = 0;
            thread_release_mutex(al_stage_mutex[i]);

            al_submit((uint8_t) i,
                      sound_is_float ? (const void *) stage.data.f
                                     : (const void *) stage.data.i,
                      stage.size,
                      stage.freq);
        }
    }

    alcMakeContextCurrent(NULL);
}

/* Called by emulation threads — copies data into staging and returns immediately. */
static void
givealbuffer_common(const void *buf, const uint8_t src, const int size, const int freq)
{
    if (!initialized || fast_forward || (size <= 0) || (size > AL_STAGE_SAMPLES))
        return;

    al_stage_t *s = &al_stage[src];

    thread_wait_mutex(al_stage_mutex[src]);

    /* Copy audio data into the staging slot. */
    if (sound_is_float)
        memcpy(s->data.f, buf, size * sizeof(float));
    else
        memcpy(s->data.i, buf, size * sizeof(int16_t));

    s->size = size;
    s->freq = freq;
    s->pending = 1;  /* publish — audio thread will pick this up */

    thread_release_mutex(al_stage_mutex[src]);

    thread_set_event(al_thread_event);
}

void
givealbuffer(const void *buf)
{
    givealbuffer_common(buf, I_NORMAL, BUFLEN << 1, FREQ);
}

void
givealbuffer_music(const void *buf)
{
    givealbuffer_common(buf, I_MUSIC, MUSICBUFLEN << 1, MUSIC_FREQ);
}

void
givealbuffer_wt(const void *buf)
{
    givealbuffer_common(buf, I_WT, WTBUFLEN << 1, WT_FREQ);
}

void
givealbuffer_cd(const void *buf)
{
    givealbuffer_common(buf, I_CD, CD_BUFLEN << 1, CD_FREQ);
}

void
givealbuffer_midi(const void *buf, const uint32_t size)
{
    givealbuffer_common(buf, I_MIDI, (int) size, midi_freq);
}

void
givealbuffer_fdd(const void *buf, const uint32_t size)
{
    givealbuffer_common(buf, I_FDD, (int) size, FREQ);
}

void
givealbuffer_hdd(const void *buf, const uint32_t size)
{
    givealbuffer_common(buf, I_HDD, (int) size, FREQ);
}