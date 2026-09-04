// CSevenZip.h — C façade over the in-process 7-Zip 7z-format engine.
//
// Double Finder links the 7z handler + codecs from the 7-Zip sources
// (Sources/CSevenZip/7zip, LGPL 2.1) straight into the executable, so
// encrypted / solid / multi-volume 7z archives need no external `7zz`.
// Everything below is plain C so Swift can call it directly.

#ifndef CSEVENZIP_H
#define CSEVENZIP_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct sz_archive sz_archive;

typedef enum {
    SZR_OK = 0,
    SZR_ERR_OPEN = 1,       // not a 7z archive, truncated, missing volume …
    SZR_ERR_ENCRYPTED = 2,  // a password is needed, or the given one is wrong
    SZR_ERR_IO = 3,         // couldn't read a volume / create an output file
    SZR_ERR_CANCELLED = 4,  // the cancel callback returned non-zero
    SZR_ERR_DATA = 5,       // corrupt payload (CRC / decoder failure)
    SZR_ERR_ARG = 6         // bad arguments (index out of range, empty list …)
} sz_status;

/// Progress in uncompressed bytes. `total` may be 0 when unknown.
typedef void (*sz_progress_fn)(void *ctx, uint64_t completed, uint64_t total);
/// Return non-zero to abort the running operation.
typedef int (*sz_cancel_fn)(void *ctx);

/// Opens a 7z archive made of `volume_count` files concatenated in order
/// (one path for a plain archive, `x.7z.001`, `x.7z.002`, … for a split set).
/// `password` may be NULL. With `SZR_ERR_ENCRYPTED` the header is encrypted
/// and no/wrong password was given.
sz_status sz_open(const char *const *volumes, int volume_count,
                  const char *password, sz_archive **out);
void sz_close(sz_archive *archive);

uint32_t sz_item_count(const sz_archive *archive);

typedef struct {
    const char *path;      // UTF-8, '/'-separated; valid until the next sz_item / sz_close
    uint64_t size;
    int64_t mtime;         // Unix seconds, -1 when the entry carries none
    int is_dir;
    int is_encrypted;
    uint32_t posix_mode;   // 0 when the entry carries no POSIX attributes
} sz_item_info;

sz_status sz_item(sz_archive *archive, uint32_t index, sz_item_info *out);

/// Extracts `indices` (NULL = every item) under `dest_dir`. `strip_prefix`
/// ("" or "dir/sub/") is removed from the front of each item path first, so a
/// single entry pulled out of a sub-folder lands flat under its own name.
/// Items whose path escapes `dest_dir` (".." components) are skipped.
/// `error_message` (may be NULL) receives a malloc'd description on failure;
/// free it with sz_free_string.
sz_status sz_extract(sz_archive *archive,
                     const uint32_t *indices, uint32_t index_count,
                     const char *dest_dir, const char *strip_prefix,
                     sz_progress_fn progress, sz_cancel_fn cancel, void *ctx,
                     char **error_message);

typedef struct {
    const char *disk_path;     // file or directory on disk
    const char *archive_path;  // UTF-8 path to store, '/'-separated
} sz_source;

/// Writes a new 7z archive from `items`. `level` is the 7-Zip level (0–9),
/// `volume_size` > 0 splits the output into `<archive_path>.001`, `.002`, …
/// (the archive file itself is then NOT created). `encrypt_headers` also
/// hides file names (`-mhe=on`); it is ignored without a password.
sz_status sz_create(const char *archive_path,
                    const sz_source *items, uint32_t item_count,
                    const char *password, int encrypt_headers,
                    int level, uint64_t volume_size,
                    sz_progress_fn progress, sz_cancel_fn cancel, void *ctx,
                    char **error_message);

void sz_free_string(char *s);

/// Version string of the bundled 7-Zip sources, e.g. "26.02".
const char *sz_engine_version(void);

#ifdef __cplusplus
}
#endif

#endif
