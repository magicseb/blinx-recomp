/* The title's Sofdec movies (media\movie\*.sfd), decoded on the host.
 *
 * CRI's decoder does not run under the recompiler (recomp_manual.c says
 * why), so PlayMovie hands the file to ffmpeg instead: one process decodes
 * the MPEG-1 video, another the ADX audio to 48 kHz PCM. The audio goes out
 * through waveOut and is the clock. Each video frame, decoded to YUY2 at the
 * size the title asked for, is kept until the title's movie update copies
 * it into the title's own movie texture, which the title draws as it always
 * did: full screen for the intros, behind the menu on the title screen.
 *
 * ffmpeg is looked up on PATH; BLINX_FFMPEG names another one. Without it
 * the movies are skipped. */
#ifndef BLINX_MOVIE_PLAYER_H
#define BLINX_MOVIE_PLAYER_H

#include <stdint.h>

/* Start the movie at guest_path (relative to the disc root, as the title
 * names it, or D:\...), decoded to w x h; loop: start over at the end, for
 * as long as it is not stopped. 0 when it is playing, -1 when it cannot
 * be. */
int  movie_host_start(const char *guest_path, unsigned w, unsigned h, int loop);

/* Copy the latest frame due, if not copied yet, to dst (YUY2, pitch bytes
 * a row): 1 when one was copied. */
int  movie_host_take_frame(uint8_t *dst, unsigned pitch);

/* 1 while a movie started here has frames or sound left. */
int  movie_host_playing(void);

/* Stop the movie, if one is playing. */
void movie_host_stop(void);

#endif
