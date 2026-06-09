#ifndef SINGULARITY_VKBD_H
#define SINGULARITY_VKBD_H

/* Type a UTF-8 string into the focused window via a Wayland virtual keyboard.
 * Each codepoint is mapped to a one-key xkb keymap (wtype style) and pressed,
 * so arbitrary characters (emoji included) are inserted directly. */
void singularity_type_text(const char *utf8);

#endif
