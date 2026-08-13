/*
 * Bridge header for libmtp (LGPL-2.1-or-later, `brew install libmtp`).
 *
 * Unlike Clibarchive — where macOS ships the dylib but no header, so the
 * declarations there are hand-written — libmtp's *real* header is included
 * here on purpose: struct layouts (LIBMTP_file_t, LIBMTP_devicestorage_t,
 * LIBMTP_raw_device_t) must match the linked library exactly, and hand-copied
 * copies would break silently on a version bump.
 *
 * macOS has no MTP support of its own: ImageCaptureCore only speaks PTP (the
 * photo subset) and cannot see a phone's storage, so this is a genuine external
 * dependency. It is bundled into the packaged .app (see package_app.sh).
 */
#ifndef CLIBMTP_SHIM_H
#define CLIBMTP_SHIM_H

#include <libmtp.h>

#endif
