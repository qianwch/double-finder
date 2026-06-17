/*
 * Minimal vendored declarations for the subset of libarchive we use.
 * libarchive is BSD-licensed; macOS ships it as /usr/lib/libarchive.2.dylib
 * (currently 3.7.x), which bsdtar links against — so we link it directly and
 * need no external install. Apple does not ship <archive.h> in the SDK, hence
 * this hand-written shim. Signatures match libarchive 3.x exactly.
 */
#ifndef CLIBARCHIVE_SHIM_H
#define CLIBARCHIVE_SHIM_H

#include <sys/types.h>
#include <stdint.h>
#include <stddef.h>
#include <time.h>

struct archive;
struct archive_entry;

/* ---- lifecycle / errors ---- */
const char *archive_version_string(void);
const char *archive_error_string(struct archive *);
int archive_errno(struct archive *);

/* ---- reading (list / extract) ---- */
struct archive *archive_read_new(void);
int archive_read_support_filter_all(struct archive *);
int archive_read_support_format_all(struct archive *);
int archive_read_support_format_raw(struct archive *);
int archive_read_add_passphrase(struct archive *, const char *);
int archive_read_open_filename(struct archive *, const char *_filename, size_t _block_size);
int archive_read_next_header(struct archive *, struct archive_entry **);
int archive_read_data_skip(struct archive *);
ssize_t archive_read_data(struct archive *, void *, size_t);
int archive_read_close(struct archive *);
int archive_read_free(struct archive *);
int archive_read_has_encrypted_entries(struct archive *);
int archive_format(struct archive *);
int archive_filter_count(struct archive *);
int archive_filter_code(struct archive *, int);

/* ---- writing to disk (extraction) ---- */
struct archive *archive_write_disk_new(void);
int archive_write_disk_set_options(struct archive *, int);
int archive_write_disk_set_standard_lookup(struct archive *);

/* ---- writing archives (creation) ---- */
struct archive *archive_write_new(void);
int archive_write_set_format(struct archive *, int);
int archive_write_add_filter(struct archive *, int);
int archive_write_set_format_zip(struct archive *);
int archive_write_set_format_pax_restricted(struct archive *);
int archive_write_set_format_gnutar(struct archive *);
int archive_write_set_format_7zip(struct archive *);
int archive_write_add_filter_gzip(struct archive *);
int archive_write_add_filter_bzip2(struct archive *);
int archive_write_add_filter_xz(struct archive *);
int archive_write_add_filter_zstd(struct archive *);
int archive_write_add_filter_none(struct archive *);
int archive_write_set_options(struct archive *, const char *);
int archive_write_set_passphrase(struct archive *, const char *);
int archive_write_open_filename(struct archive *, const char *);
int archive_write_header(struct archive *, struct archive_entry *);
ssize_t archive_write_data(struct archive *, const void *, size_t);
int archive_write_finish_entry(struct archive *);
int archive_write_close(struct archive *);
int archive_write_free(struct archive *);

/* ---- archive_entry ---- */
struct archive_entry *archive_entry_new(void);
void archive_entry_free(struct archive_entry *);
void archive_entry_clear(struct archive_entry *);
const char *archive_entry_pathname(struct archive_entry *);
const char *archive_entry_pathname_utf8(struct archive_entry *);
void archive_entry_set_pathname(struct archive_entry *, const char *);
void archive_entry_set_pathname_utf8(struct archive_entry *, const char *);
mode_t archive_entry_filetype(struct archive_entry *);
void archive_entry_set_filetype(struct archive_entry *, unsigned int);
int64_t archive_entry_size(struct archive_entry *);
void archive_entry_set_size(struct archive_entry *, int64_t);
void archive_entry_set_perm(struct archive_entry *, mode_t);
time_t archive_entry_mtime(struct archive_entry *);
void archive_entry_set_mtime(struct archive_entry *, time_t, long);
int archive_entry_is_encrypted(struct archive_entry *);
const char *archive_entry_symlink(struct archive_entry *);
void archive_entry_set_symlink(struct archive_entry *, const char *);

#endif /* CLIBARCHIVE_SHIM_H */
