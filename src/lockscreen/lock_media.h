#ifndef SINGULARITY_LOCK_MEDIA_H
#define SINGULARITY_LOCK_MEDIA_H

#include <stdbool.h>
#include <cairo/cairo.h>

typedef struct {
    bool has_player;       /* a player is connected and Playing or Paused */
    bool playing;          /* PlaybackStatus == "Playing" */
    bool can_next;
    bool can_prev;
    char title[256];
    char artist[256];
    cairo_surface_t *cover; /* owned by lock_media, may be NULL */
} LockMediaState;

/* Connect to MPRIS over the session bus. `on_change` is invoked (from the
 * GLib main context) whenever the displayed state changes, so the caller can
 * repaint. Requires the GLib default main context to be iterated. */
void lock_media_init(void (*on_change)(void));

const LockMediaState *lock_media_get(void);

void lock_media_play_pause(void);
void lock_media_next(void);
void lock_media_prev(void);

#endif
