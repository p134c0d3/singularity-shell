#ifndef SINGULARITY_XWL_ICON_H
#define SINGULARITY_XWL_ICON_H

#include <gdk/gdk.h>

/* Return the _NET_WM_ICON of the XWayland window matching app_id (WM_CLASS) or
 * title (_NET_WM_NAME) as a GdkTexture, or NULL if none. Transfer: full. */
GdkTexture *singularity_xwayland_icon(const char *app_id, const char *title);

#endif
