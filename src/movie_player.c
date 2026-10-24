/* The SFD movies on the host: ffmpeg decodes, waveOut plays the sound and
 * keeps the time, and the latest frame waits here for the game to copy it
 * into its movie texture. movie_player.h has the why. */
#include <windows.h>
#include <mmsystem.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "movie_player.h"

#ifndef BLINX_GAME_DIR
#define BLINX_GAME_DIR "game"
#endif

/* ffmpeg delivers YUY2 (yuyv422, the title's texture format) at the size
 * the title asked for and at 29.97, the rate of every Blinx movie: a frame
 * is a fixed number of bytes and its index is its time. */
#define MV_FPS      (30000.0 / 1001.0)
#define AU_RATE     48000u
#define AU_NBUF     6
#define AU_FRAMES   4800u            /* 100 ms a buffer */
#define AU_BYTES    (AU_FRAMES * 4u) /* s16 stereo */

static struct {
    HANDLE           vproc, aproc;   /* the two ffmpeg */
    HANDLE           vpipe, apipe;   /* their stdout, our end */
    HANDLE           vthread, athread;
    HWAVEOUT         wo;
    WAVEHDR          hdr[AU_NBUF];
    char            *abuf[AU_NBUF];
    uint8_t         *frame;          /* the one being read */
    uint8_t         *shown;          /* the latest one due, for the game */
    unsigned         w, h, bytes;
    SRWLOCK          lock;           /* shown, fresh */
    int              fresh;          /* shown not taken yet */
    LARGE_INTEGER    qpf, t0;        /* t0: the start, for the silent clock */
    volatile LONG    stop;
    volatile LONG    video_done, audio_done;
    volatile LONG    audio_none;     /* the file has no sound: QPC is the clock */
    double           audio_end_s;    /* the clock when the sound ran out */
    LARGE_INTEGER    audio_end_t;
    int              active;
} mv;

static double qpc_s(LARGE_INTEGER since)
{
    LARGE_INTEGER now;
    QueryPerformanceCounter(&now);
    return (double)(now.QuadPart - since.QuadPart) / (double)mv.qpf.QuadPart;
}

/* The movie's clock in seconds: the samples the device has played; after
 * the sound ends (or without any), wall time from there. */
static double movie_clock(void)
{
    MMTIME t;

    if (mv.audio_none)
        return qpc_s(mv.t0);
    if (mv.audio_done)
        return mv.audio_end_s + qpc_s(mv.audio_end_t);
    memset(&t, 0, sizeof t);
    t.wType = TIME_SAMPLES;
    if (waveOutGetPosition(mv.wo, &t, sizeof t) != MMSYSERR_NOERROR || t.wType != TIME_SAMPLES)
        return 0.0;
    return (double)t.u.sample / AU_RATE;
}

static const char *ffmpeg_exe(void)
{
    const char *e = getenv("BLINX_FFMPEG");
    return e && *e ? e : "ffmpeg";
}

/* ffmpeg with args, its stdout a pipe returned in *out, stdin and stderr
 * nowhere. */
static HANDLE spawn(const char *args, HANDLE *out)
{
    SECURITY_ATTRIBUTES sa = {sizeof sa, NULL, TRUE};
    STARTUPINFOA si;
    PROCESS_INFORMATION pi;
    HANDLE rd, wr, nul;
    char cmd[1024];
    BOOL ok;

    *out = NULL;
    if (!CreatePipe(&rd, &wr, &sa, 1u << 20))
        return NULL;
    SetHandleInformation(rd, HANDLE_FLAG_INHERIT, 0);
    nul = CreateFileA("NUL", GENERIC_READ | GENERIC_WRITE, FILE_SHARE_READ | FILE_SHARE_WRITE,
                      &sa, OPEN_EXISTING, 0, NULL);
    memset(&si, 0, sizeof si);
    si.cb = sizeof si;
    si.dwFlags = STARTF_USESTDHANDLES;
    si.hStdInput = nul;
    si.hStdOutput = wr;
    si.hStdError = nul;
    snprintf(cmd, sizeof cmd, "\"%s\" %s", ffmpeg_exe(), args);
    ok = CreateProcessA(NULL, cmd, NULL, NULL, TRUE, CREATE_NO_WINDOW, NULL, NULL, &si, &pi);
    CloseHandle(wr);
    if (nul != INVALID_HANDLE_VALUE)
        CloseHandle(nul);
    if (!ok) {
        CloseHandle(rd);
        return NULL;
    }
    CloseHandle(pi.hThread);
    *out = rd;
    return pi.hProcess;
}

/* Fill buf from the pipe; the bytes read, short only at the end. */
static DWORD read_full(HANDLE pipe, void *buf, DWORD n)
{
    DWORD got = 0, k;

    while (got < n && !mv.stop) {
        if (!ReadFile(pipe, (char *)buf + got, n - got, &k, NULL) || !k)
            break;
        got += k;
    }
    return got;
}

static DWORD WINAPI video_thread(LPVOID unused)
{
    uint64_t index = 0;
    (void)unused;

    while (!mv.stop && read_full(mv.vpipe, mv.frame, mv.bytes) == mv.bytes) {
        double due = (double)index / MV_FPS;
        double now;
        /* Sound that has not started yet holds the clock at 0: the first
         * frame goes up at once, the next waits for it. */
        while (!mv.stop && (now = movie_clock()) < due) {
            DWORD ms = (DWORD)((due - now) * 1000.0);
            Sleep(ms > 5 ? 5 : ms ? ms : 1);
        }
        if (mv.stop)
            break;
        AcquireSRWLockExclusive(&mv.lock);
        memcpy(mv.shown, mv.frame, mv.bytes);
        mv.fresh = 1;
        ReleaseSRWLockExclusive(&mv.lock);
        index++;
    }
    fprintf(stderr, "[movie] video: %llu frames\n", (unsigned long long)index);
    InterlockedExchange(&mv.video_done, 1);
    return 0;
}

static DWORD WINAPI audio_thread(LPVOID unused)
{
    uint64_t total = 0;
    int eof = 0, i;
    (void)unused;

    while (!mv.stop && !eof) {
        WAVEHDR *h = NULL;
        DWORD got;
        for (i = 0; i < AU_NBUF; i++)
            if (!(mv.hdr[i].dwFlags & WHDR_PREPARED) || (mv.hdr[i].dwFlags & WHDR_DONE)) {
                h = &mv.hdr[i];
                break;
            }
        if (!h) {
            Sleep(5);
            continue;
        }
        if (h->dwFlags & WHDR_PREPARED)
            waveOutUnprepareHeader(mv.wo, h, sizeof *h);
        got = read_full(mv.apipe, h->lpData, AU_BYTES);
        got &= ~3u;
        eof = got < AU_BYTES;
        if (!got)
            break;
        total += got;
        h->dwBufferLength = got;
        h->dwFlags = 0;
        waveOutPrepareHeader(mv.wo, h, sizeof *h);
        waveOutWrite(mv.wo, h, sizeof *h);
    }
    if (!total) {
        /* No sound in the file (or no audio ffmpeg): the wall clock leads. */
        QueryPerformanceCounter(&mv.t0);
        InterlockedExchange(&mv.audio_none, 1);
    } else {
        /* Played out: every buffer handed back. */
        for (;;) {
            int busy = 0;
            for (i = 0; i < AU_NBUF; i++)
                if ((mv.hdr[i].dwFlags & WHDR_PREPARED) && !(mv.hdr[i].dwFlags & WHDR_DONE))
                    busy = 1;
            if (!busy || mv.stop)
                break;
            Sleep(5);
        }
        mv.audio_end_s = (double)(total / 4u) / AU_RATE;
        QueryPerformanceCounter(&mv.audio_end_t);
    }
    fprintf(stderr, "[movie] audio: %.2f s\n", (double)(total / 4u) / AU_RATE);
    InterlockedExchange(&mv.audio_done, 1);
    return 0;
}

/* A looping movie, to start over when it ends: what it was started with. */
static char     s_loop_path[MAX_PATH];
static unsigned s_loop_w, s_loop_h;
static int      s_loop;

int movie_host_start(const char *guest_path, unsigned w, unsigned h, int loop)
{
    char host[MAX_PATH], args[1024];
    WAVEFORMATEX wf;
    const char *p;
    int i;

    movie_host_stop();
    if (guest_path != s_loop_path)
        snprintf(s_loop_path, sizeof s_loop_path, "%s", guest_path);
    s_loop_w = w;
    s_loop_h = h;
    s_loop = loop;
    p = s_loop_path;
    if ((p[0] == 'D' || p[0] == 'd') && p[1] == ':')
        p += 2;
    while (*p == '\\' || *p == '/')
        p++;
    snprintf(host, sizeof host, "%s\\%s", BLINX_GAME_DIR, p);
    if (getenv("BLINX_NO_MOVIES")) {   /* straight to the title, for profiling */
        fprintf(stderr, "[movie] %s: BLINX_NO_MOVIES, skipped\n", host);
        return -1;
    }
    if (GetFileAttributesA(host) == INVALID_FILE_ATTRIBUTES) {
        fprintf(stderr, "[movie] %s: no such file, skipped\n", host);
        return -1;
    }

    memset(&mv, 0, sizeof mv);
    QueryPerformanceFrequency(&mv.qpf);
    QueryPerformanceCounter(&mv.t0);
    InitializeSRWLock(&mv.lock);
    mv.w = w & ~1u;
    mv.h = h;
    mv.bytes = mv.w * mv.h * 2u;
    mv.frame = (uint8_t *)malloc(mv.bytes ? mv.bytes : 1);
    mv.shown = (uint8_t *)malloc(mv.bytes ? mv.bytes : 1);
    snprintf(args, sizeof args,
             "-nostdin -v quiet -i \"%s\" -an -f rawvideo -pix_fmt yuyv422"
             " -s %ux%u -r 30000/1001 pipe:1", host, mv.w, mv.h);
    if (mv.bytes && mv.frame && mv.shown)
        mv.vproc = spawn(args, &mv.vpipe);
    if (!mv.vproc) {
        fprintf(stderr, "[movie] cannot run %s: %s skipped\n", ffmpeg_exe(), host);
        free(mv.frame);
        free(mv.shown);
        memset(&mv, 0, sizeof mv);
        return -1;
    }

    memset(&wf, 0, sizeof wf);
    wf.wFormatTag = WAVE_FORMAT_PCM;
    wf.nChannels = 2;
    wf.nSamplesPerSec = AU_RATE;
    wf.wBitsPerSample = 16;
    wf.nBlockAlign = 4;
    wf.nAvgBytesPerSec = AU_RATE * 4;
    if (waveOutOpen(&mv.wo, WAVE_MAPPER, &wf, 0, 0, CALLBACK_NULL) == MMSYSERR_NOERROR) {
        snprintf(args, sizeof args,
                 "-nostdin -v quiet -i \"%s\" -vn -f s16le -ar %u -ac 2 pipe:1", host, AU_RATE);
        mv.aproc = spawn(args, &mv.apipe);
    } else {
        mv.wo = NULL;
    }
    if (mv.aproc) {
        for (i = 0; i < AU_NBUF; i++) {
            mv.abuf[i] = (char *)malloc(AU_BYTES);
            mv.hdr[i].lpData = mv.abuf[i];
        }
        mv.athread = CreateThread(NULL, 0, audio_thread, NULL, 0, NULL);
    } else {
        mv.audio_none = 1;
        mv.audio_done = 1;
    }
    mv.vthread = CreateThread(NULL, 0, video_thread, NULL, 0, NULL);
    mv.active = 1;
    fprintf(stderr, "[movie] playing %s (%ux%u)\n", host, mv.w, mv.h);
    return 0;
}

int movie_host_take_frame(uint8_t *dst, unsigned pitch)
{
    unsigned y;
    int got;

    if (!mv.active)
        return 0;
    AcquireSRWLockExclusive(&mv.lock);
    got = mv.fresh;
    if (got)
        for (y = 0; y < mv.h; y++)
            memcpy(dst + (size_t)y * pitch, mv.shown + (size_t)y * mv.w * 2u, mv.w * 2u);
    mv.fresh = 0;
    ReleaseSRWLockExclusive(&mv.lock);
    return got;
}

int movie_host_playing(void)
{
    if (!mv.active)
        return 0;
    if (!(mv.video_done && mv.audio_done))
        return 1;
    /* Two fresh decoders at each pass, rather than ffmpeg's -stream_loop:
     * sound and picture start over together, and never drift apart. */
    if (s_loop)
        return movie_host_start(s_loop_path, s_loop_w, s_loop_h, 1) == 0;
    return 0;
}

void movie_host_stop(void)
{
    int i;

    if (!mv.active)
        return;
    InterlockedExchange(&mv.stop, 1);
    /* Ending the decoders breaks the pipes, and with them any read. */
    if (mv.vproc)
        TerminateProcess(mv.vproc, 0);
    if (mv.aproc)
        TerminateProcess(mv.aproc, 0);
    if (mv.vthread) {
        WaitForSingleObject(mv.vthread, 2000);
        CloseHandle(mv.vthread);
    }
    if (mv.athread) {
        WaitForSingleObject(mv.athread, 2000);
        CloseHandle(mv.athread);
    }
    if (mv.wo) {
        waveOutReset(mv.wo);
        for (i = 0; i < AU_NBUF; i++)
            if (mv.hdr[i].dwFlags & WHDR_PREPARED)
                waveOutUnprepareHeader(mv.wo, &mv.hdr[i], sizeof mv.hdr[i]);
        waveOutClose(mv.wo);
    }
    for (i = 0; i < AU_NBUF; i++)
        free(mv.abuf[i]);
    if (mv.vpipe) CloseHandle(mv.vpipe);
    if (mv.apipe) CloseHandle(mv.apipe);
    if (mv.vproc) CloseHandle(mv.vproc);
    if (mv.aproc) CloseHandle(mv.aproc);
    free(mv.frame);
    free(mv.shown);
    memset(&mv, 0, sizeof mv);
    fprintf(stderr, "[movie] stopped\n");
}
