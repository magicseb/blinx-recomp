/* The title's Sofdec movies (media\movie\*.sfd), played on the host.
 *
 * CRI's decoder does not run under the recompiler (recomp_manual.c says
 * why), so PlayMovie hands the file to ffmpeg instead: one process decodes
 * the MPEG-1 video to BGRA, another the ADX audio to 48 kHz PCM. The audio
 * goes out through waveOut and is the clock; each video frame is handed to
 * the D3D11 backend when its time comes, and shown in place of the guest
 * frame at every flip until the movie ends.
 *
 * ffmpeg is looked up on PATH; BLINX_FFMPEG names another one. Without it
 * the movies are skipped, as they were before. */
#ifndef BLINX_MOVIE_PLAYER_H
#define BLINX_MOVIE_PLAYER_H

/* Start the movie at guest_path (relative to the disc root, as the title
 * names it, or D:\...). 0 when it is playing, -1 when it cannot be. */
int  movie_host_start(const char *guest_path);

/* 1 while a movie started here has frames or sound left. */
int  movie_host_playing(void);

/* Stop the movie, if one is playing, and give the screen back to the game. */
void movie_host_stop(void);

#endif
