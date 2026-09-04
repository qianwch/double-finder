// SevenZipShim.cpp — the C façade declared in include/CSevenZip.h.
//
// Drives the 7-Zip 7z handler (NArchive::N7z::CHandler) directly through its
// COM-style interfaces: open (plain or concatenated volumes, optional
// password), list, extract with progress/cancel, create with password /
// header encryption / volume splitting. Modelled on 7-Zip's own
// CPP/7zip/UI/Client7z sample, minus the DLL loading and console output.

#include "../7zip/CPP/Common/Common.h"

#include <errno.h>
#include <fcntl.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <limits.h>
#include <sys/time.h>
#include <unistd.h>

#include "../7zip/C/7zVersion.h"

#include "../7zip/CPP/Common/MyWindows.h"
#include "../7zip/CPP/Common/MyCom.h"
#include "../7zip/CPP/Common/MyString.h"
#include "../7zip/CPP/Common/MyVector.h"
#include "../7zip/CPP/Common/UTFConvert.h"

#include "../7zip/CPP/Windows/FileDir.h"
#include "../7zip/CPP/Windows/FileFind.h"
#include "../7zip/CPP/Windows/PropVariant.h"
#include "../7zip/CPP/Windows/PropVariantConv.h"
#include "../7zip/CPP/Windows/TimeUtils.h"

#include "../7zip/CPP/7zip/IPassword.h"
#include "../7zip/CPP/7zip/IStream.h"
#include "../7zip/CPP/7zip/Common/FileStreams.h"
#include "../7zip/CPP/7zip/Common/MultiOutStream.h"
#include "../7zip/CPP/7zip/Common/StreamObjects.h"
#include "../7zip/CPP/7zip/Archive/IArchive.h"
#include "../7zip/CPP/7zip/Archive/Common/MultiStream.h"
#include "../7zip/CPP/7zip/Archive/7z/7zHandler.h"

#include "CSevenZip.h"

using namespace NWindows;
using namespace NWindows::NFile;

// MARK: - Small helpers

static UString utf8ToU(const char *s)
{
    UString u;
    ConvertUTF8ToUnicode(AString(s ? s : ""), u);
    return u;
}

static AString uToUtf8(const UString &u)
{
    AString a;
    ConvertUnicodeToUTF8(u, a);
    return a;
}

static void setError(char **out, const char *msg)
{
    if (out && !*out) *out = strdup(msg);
}

static void setError(char **out, const AString &msg)
{
    setError(out, msg.Ptr());
}

/// "a/b/../c" or "/abs" must never escape the destination directory.
static bool isSafeRelativePath(const AString &p)
{
    if (p.IsEmpty() || p[0] == '/') return false;
    unsigned start = 0;
    for (unsigned i = 0; i <= p.Len(); i++) {
        if (i == p.Len() || p[i] == '/') {
            const unsigned len = i - start;
            if (len == 2 && p[start] == '.' && p[start + 1] == '.') return false;
            start = i + 1;
        }
    }
    return true;
}

static void setTimes(const char *path, const timespec &mtime)
{
    timespec ts[2];
    ts[0].tv_sec = mtime.tv_sec; ts[0].tv_nsec = mtime.tv_nsec; // atime
    ts[1] = ts[0];
    utimensat(AT_FDCWD, path, ts, AT_SYMLINK_NOFOLLOW);
}

// MARK: - Password state shared by the callbacks

struct CPasswordState {
    bool defined;
    UString password;
    bool wasAsked;     // the handler needed one at least once
    CPasswordState() : defined(false), wasAsked(false) {}
    HRESULT provide(BSTR *out)
    {
        wasAsked = true;
        if (!defined) return E_ABORT;   // no password available: stop, don't guess
        return StringToBstr(password, out);
    }
};

// MARK: - Open callback

class COpenCallback Z7_final :
    public IArchiveOpenCallback,
    public ICryptoGetTextPassword,
    public CMyUnknownImp
{
    Z7_IFACES_IMP_UNK_2(IArchiveOpenCallback, ICryptoGetTextPassword)
public:
    CPasswordState *pw;
    COpenCallback() : pw(NULL) {}
};

Z7_COM7F_IMF(COpenCallback::SetTotal(const UInt64 *, const UInt64 *)) { return S_OK; }
Z7_COM7F_IMF(COpenCallback::SetCompleted(const UInt64 *, const UInt64 *)) { return S_OK; }
Z7_COM7F_IMF(COpenCallback::CryptoGetTextPassword(BSTR *password)) { return pw->provide(password); }

// MARK: - The archive handle

struct sz_archive {
    CMyComPtr<IInArchive> archive;
    CMyComPtr<IInStream> stream;     // one file, or a CMultiStream over the volume set
    CPasswordState pw;
    UInt32 count;
    AString lastPath;   // backing store for sz_item_info.path
    sz_archive() : count(0) {}
};

// MARK: - Symlink capture stream

/// Buffers an entry's payload in memory so it can be turned into a symlink.
class CMemOutStream Z7_final :
    public ISequentialOutStream,
    public CMyUnknownImp
{
    Z7_IFACES_IMP_UNK_1(ISequentialOutStream)
public:
    AString data;
};

Z7_COM7F_IMF(CMemOutStream::Write(const void *buf, UInt32 size, UInt32 *processed))
{
    if (size) {
        AString chunk;
        chunk.SetFrom((const char *)buf, size);
        data += chunk;
    }
    if (processed) *processed = size;
    return S_OK;
}

// MARK: - Extract callback

class CExtractCallback Z7_final :
    public IArchiveExtractCallback,
    public ICryptoGetTextPassword,
    public CMyUnknownImp
{
    Z7_IFACES_IMP_UNK_2(IArchiveExtractCallback, ICryptoGetTextPassword)
    Z7_IFACE_COM7_IMP(IProgress)

    IInArchive *_archive;
    AString _destDir;       // with trailing '/'
    AString _stripPrefix;
    // Per-item state
    AString _diskPath;
    bool _isDir;
    bool _isSymlink;
    bool _hasMTime;
    timespec _mtime;
    UInt32 _posixMode;
    COutFileStream *_fileSpec;
    CMemOutStream *_memSpec;
    CMyComPtr<ISequentialOutStream> _out;

    struct CDirTime { AString path; timespec mtime; };
    CObjectVector<CDirTime> _dirTimes;

public:
    CPasswordState *pw;
    sz_progress_fn progress;
    sz_cancel_fn cancel;
    void *ctx;
    UInt64 total;
    bool cancelled;
    Int32 firstFailure;     // NExtract::NOperationResult, or -1
    AString firstFailurePath;
    AString ioError;

    CExtractCallback() :
        _archive(NULL), _isDir(false), _isSymlink(false), _hasMTime(false), _posixMode(0),
        _fileSpec(NULL), _memSpec(NULL), pw(NULL), progress(NULL), cancel(NULL), ctx(NULL),
        total(0), cancelled(false), firstFailure(-1) {}

    void Init(IInArchive *archive, const char *destDir, const char *stripPrefix)
    {
        _archive = archive;
        _destDir = destDir;
        if (!_destDir.IsEmpty() && _destDir.Back() != '/') _destDir.Add_Char('/');
        _stripPrefix = stripPrefix ? stripPrefix : "";
    }

    /// Directory timestamps go last: writing files into a folder bumps its mtime.
    void ApplyDirTimes()
    {
        for (unsigned i = _dirTimes.Size(); i > 0; i--) {
            const CDirTime &d = _dirTimes[i - 1];
            setTimes(d.path.Ptr(), d.mtime);
        }
    }

private:
    void discardCurrentOutput()
    {
        if (_fileSpec) { _fileSpec->Close(); }
        _out.Release();
        _fileSpec = NULL;
        _memSpec = NULL;
        if (!_isDir && !_diskPath.IsEmpty()) unlink(_diskPath.Ptr());
    }
};

Z7_COM7F_IMF(CExtractCallback::SetTotal(UInt64 size))
{
    total = size;
    return S_OK;
}

Z7_COM7F_IMF(CExtractCallback::SetCompleted(const UInt64 *completeValue))
{
    if (cancel && cancel(ctx)) { cancelled = true; return E_ABORT; }
    if (progress && completeValue) progress(ctx, *completeValue, total);
    return S_OK;
}

Z7_COM7F_IMF(CExtractCallback::GetStream(UInt32 index, ISequentialOutStream **outStream, Int32 askExtractMode))
{
    *outStream = NULL;
    _out.Release();
    _fileSpec = NULL;
    _memSpec = NULL;
    _diskPath.Empty();
    _isDir = false;
    _isSymlink = false;
    _hasMTime = false;
    _posixMode = 0;

    if (askExtractMode != NArchive::NExtract::NAskMode::kExtract) return S_OK;
    if (cancel && cancel(ctx)) { cancelled = true; return E_ABORT; }

    AString path;
    {
        NCOM::CPropVariant prop;
        RINOK(_archive->GetProperty(index, kpidPath, &prop))
        if (prop.vt == VT_BSTR) path = uToUtf8(UString(prop.bstrVal));
        else if (prop.vt != VT_EMPTY) return E_FAIL;
    }
    if (path.IsEmpty()) path = "[Content]";

    {
        NCOM::CPropVariant prop;
        RINOK(_archive->GetProperty(index, kpidIsDir, &prop))
        _isDir = (prop.vt == VT_BOOL && VARIANT_BOOLToBool(prop.boolVal));
    }
    {
        NCOM::CPropVariant prop;
        RINOK(_archive->GetProperty(index, kpidAttrib, &prop))
        if (prop.vt == VT_UI4 && (prop.ulVal & FILE_ATTRIBUTE_UNIX_EXTENSION))
            _posixMode = prop.ulVal >> 16;
    }
    {
        NCOM::CPropVariant prop;
        RINOK(_archive->GetProperty(index, kpidMTime, &prop))
        if (prop.vt == VT_FILETIME) {
            _hasMTime = FILETIME_To_timespec(prop.filetime, _mtime);
        }
    }

    // Strip the requested prefix; anything that doesn't carry it is skipped.
    AString rel = path;
    if (!_stripPrefix.IsEmpty()) {
        if (!rel.IsPrefixedBy(_stripPrefix)) return S_OK;
        rel.DeleteFrontal(_stripPrefix.Len());
    }
    if (!isSafeRelativePath(rel)) return S_OK;   // "../" escape attempt: skip

    _diskPath = _destDir + rel;

    if (_isDir) {
        if (!NDir::CreateComplexDir(_diskPath.Ptr())) {
            ioError = AString("Can't create directory ") + _diskPath;
            return E_ABORT;
        }
        if (_hasMTime) {
            CDirTime &d = _dirTimes.AddNew();
            d.path = _diskPath;
            d.mtime = _mtime;
        }
        return S_OK;
    }

    {
        const int slash = rel.ReverseFind_PathSepar();
        if (slash >= 0) {
            AString parent = _destDir + rel.Left((unsigned)slash);
            if (!NDir::CreateComplexDir(parent.Ptr())) {
                ioError = AString("Can't create directory ") + parent;
                return E_ABORT;
            }
        }
    }

    // Replace whatever is there (file, symlink, empty dir).
    struct stat st;
    if (lstat(_diskPath.Ptr(), &st) == 0) {
        if (S_ISDIR(st.st_mode)) rmdir(_diskPath.Ptr()); else unlink(_diskPath.Ptr());
    }

    _isSymlink = (_posixMode & S_IFMT) == S_IFLNK;
    if (_isSymlink) {
        _memSpec = new CMemOutStream;
        _out = _memSpec;
    } else {
        _fileSpec = new COutFileStream;
        _out = _fileSpec;
        if (!_fileSpec->Create_ALWAYS(_diskPath.Ptr())) {
            ioError = AString("Can't create file ") + _diskPath;
            _out.Release();
            _fileSpec = NULL;
            return E_ABORT;
        }
    }
    *outStream = _out;
    (*outStream)->AddRef();
    return S_OK;
}

Z7_COM7F_IMF(CExtractCallback::PrepareOperation(Int32)) { return S_OK; }

Z7_COM7F_IMF(CExtractCallback::SetOperationResult(Int32 opRes))
{
    if (opRes != NArchive::NExtract::NOperationResult::kOK) {
        if (firstFailure < 0) { firstFailure = opRes; firstFailurePath = _diskPath; }
        discardCurrentOutput();
        return S_OK;
    }
    if (_isSymlink && _memSpec) {
        const AString target = _memSpec->data;
        _out.Release();
        _memSpec = NULL;
        if (symlink(target.Ptr(), _diskPath.Ptr()) != 0) {
            ioError = AString("Can't create symlink ") + _diskPath;
            return E_ABORT;
        }
        if (_hasMTime) setTimes(_diskPath.Ptr(), _mtime);
        return S_OK;
    }
    if (_fileSpec) {
        if (_hasMTime) _fileSpec->SetMTime(&_mtime);
        RINOK(_fileSpec->Close())
        _out.Release();
        _fileSpec = NULL;
        if (_posixMode & 07777) chmod(_diskPath.Ptr(), _posixMode & 07777);
    }
    return S_OK;
}

Z7_COM7F_IMF(CExtractCallback::CryptoGetTextPassword(BSTR *password)) { return pw->provide(password); }

// MARK: - Update (create) callback

struct CSourceItem {
    AString diskPath;
    UString archivePath;
    NFind::CFileInfo info;   // lstat: a symlink shows up as S_IFLNK
    AString linkTarget;      // stored as the entry's data for a symlink
    bool isSymlink;
    CSourceItem() : isSymlink(false) {}
};

class CUpdateCallback Z7_final :
    public IArchiveUpdateCallback2,
    public ICryptoGetTextPassword2,
    public CMyUnknownImp
{
    Z7_IFACES_IMP_UNK_2(IArchiveUpdateCallback2, ICryptoGetTextPassword2)
    Z7_IFACE_COM7_IMP(IProgress)
    Z7_IFACE_COM7_IMP(IArchiveUpdateCallback)
public:
    const CObjectVector<CSourceItem> *items;
    CPasswordState *pw;
    sz_progress_fn progress;
    sz_cancel_fn cancel;
    void *ctx;
    UInt64 total;
    bool cancelled;
    AString ioError;

    CUpdateCallback() : items(NULL), pw(NULL), progress(NULL), cancel(NULL), ctx(NULL),
                        total(0), cancelled(false) {}
};

Z7_COM7F_IMF(CUpdateCallback::SetTotal(UInt64 size)) { total = size; return S_OK; }

Z7_COM7F_IMF(CUpdateCallback::SetCompleted(const UInt64 *completeValue))
{
    if (cancel && cancel(ctx)) { cancelled = true; return E_ABORT; }
    if (progress && completeValue) progress(ctx, *completeValue, total);
    return S_OK;
}

Z7_COM7F_IMF(CUpdateCallback::GetUpdateItemInfo(UInt32, Int32 *newData, Int32 *newProps, UInt32 *indexInArchive))
{
    if (newData) *newData = BoolToInt(true);
    if (newProps) *newProps = BoolToInt(true);
    if (indexInArchive) *indexInArchive = (UInt32)(Int32)-1;
    return S_OK;
}

Z7_COM7F_IMF(CUpdateCallback::GetProperty(UInt32 index, PROPID propID, PROPVARIANT *value))
{
    NCOM::CPropVariant prop;
    if (propID == kpidIsAnti) {
        prop = false;
        prop.Detach(value);
        return S_OK;
    }
    const CSourceItem &it = (*items)[index];
    switch (propID) {
        case kpidPath:  prop = it.archivePath; break;
        case kpidIsDir: prop = it.info.IsDir(); break;
        case kpidSize:  prop = (UInt64)(it.info.IsDir() ? 0 : it.isSymlink ? it.linkTarget.Len() : it.info.Size); break;
        case kpidCTime: PropVariant_SetFrom_FiTime(prop, it.info.CTime); break;
        case kpidATime: PropVariant_SetFrom_FiTime(prop, it.info.ATime); break;
        case kpidMTime: PropVariant_SetFrom_FiTime(prop, it.info.MTime); break;
        case kpidAttrib: prop = (UInt32)it.info.GetWinAttrib(); break;
        case kpidPosixAttrib: prop = (UInt32)it.info.GetPosixAttrib(); break;
        default: break;
    }
    prop.Detach(value);
    return S_OK;
}

Z7_COM7F_IMF(CUpdateCallback::GetStream(UInt32 index, ISequentialInStream **inStream))
{
    *inStream = NULL;
    if (cancel && cancel(ctx)) { cancelled = true; return E_ABORT; }
    const CSourceItem &it = (*items)[index];
    if (it.info.IsDir()) return S_OK;
    if (it.isSymlink) {
        // 7-Zip's convention (-snl): a symlink entry's payload is its target path.
        CBufInStream *buf = new CBufInStream;
        CMyComPtr<ISequentialInStream> stream(buf);
        buf->Init((const Byte *)it.linkTarget.Ptr(), it.linkTarget.Len(), NULL);
        *inStream = stream.Detach();
        return S_OK;
    }
    CInFileStream *spec = new CInFileStream;
    CMyComPtr<ISequentialInStream> stream(spec);
    if (!spec->Open(it.diskPath.Ptr())) {
        ioError = AString("Can't read ") + it.diskPath;
        return E_ABORT;
    }
    *inStream = stream.Detach();
    return S_OK;
}

Z7_COM7F_IMF(CUpdateCallback::SetOperationResult(Int32)) { return S_OK; }
Z7_COM7F_IMF(CUpdateCallback::GetVolumeSize(UInt32, UInt64 *)) { return S_FALSE; }
Z7_COM7F_IMF(CUpdateCallback::GetVolumeStream(UInt32, ISequentialOutStream **)) { return S_FALSE; }

Z7_COM7F_IMF(CUpdateCallback::CryptoGetTextPassword2(Int32 *passwordIsDefined, BSTR *password))
{
    *passwordIsDefined = BoolToInt(pw->defined);
    return StringToBstr(pw->password, password);
}

// MARK: - C API

extern "C" {

const char *sz_engine_version(void) { return MY_VERSION_NUMBERS; }

void sz_free_string(char *s) { free(s); }

sz_status sz_open(const char *const *volumes, int volumeCount, const char *password, sz_archive **out)
{
    if (!out) return SZR_ERR_ARG;
    *out = NULL;
    if (!volumes || volumeCount <= 0) return SZR_ERR_ARG;

    sz_archive *a = new sz_archive;
    if (password) { a->pw.defined = true; a->pw.password = utf8ToU(password); }

    if (volumeCount == 1) {
        CInFileStream *spec = new CInFileStream;
        a->stream = spec;
        if (!spec->Open(volumes[0])) { delete a; return SZR_ERR_IO; }
    } else {
        // A 7-Zip split set is the archive byte stream cut into pieces:
        // present the pieces as one seekable stream.
        CMultiStream *multi = new CMultiStream;
        a->stream = multi;
        for (int i = 0; i < volumeCount; i++) {
            CInFileStream *spec = new CInFileStream;
            CMyComPtr<IInStream> s(spec);
            if (!spec->Open(volumes[i])) { delete a; return SZR_ERR_IO; }
            UInt64 size = 0;
            if (spec->GetSize(&size) != S_OK) { delete a; return SZR_ERR_IO; }
            CMultiStream::CSubStreamInfo &info = multi->Streams.AddNew();
            info.Stream = s;
            info.Size = size;
        }
        multi->Init();
    }

    NArchive::N7z::CHandler *handler = new NArchive::N7z::CHandler;
    a->archive = handler;

    COpenCallback *cbSpec = new COpenCallback;
    CMyComPtr<IArchiveOpenCallback> cb(cbSpec);
    cbSpec->pw = &a->pw;

    const UInt64 maxCheckStart = 1 << 23;
    const HRESULT res = a->archive->Open(a->stream, &maxCheckStart, cb);
    if (res != S_OK) {
        const bool encrypted = a->pw.wasAsked;
        delete a;
        return encrypted ? SZR_ERR_ENCRYPTED : SZR_ERR_OPEN;
    }
    if (a->archive->GetNumberOfItems(&a->count) != S_OK) { delete a; return SZR_ERR_OPEN; }
    *out = a;
    return SZR_OK;
}

void sz_close(sz_archive *a)
{
    if (!a) return;
    if (a->archive) a->archive->Close();
    delete a;
}

uint32_t sz_item_count(const sz_archive *a) { return a ? a->count : 0; }

sz_status sz_item(sz_archive *a, uint32_t index, sz_item_info *info)
{
    if (!a || !info || index >= a->count) return SZR_ERR_ARG;
    memset(info, 0, sizeof(*info));
    info->mtime = -1;

    IInArchive *arc = a->archive;
    {
        NCOM::CPropVariant prop;
        if (arc->GetProperty(index, kpidPath, &prop) != S_OK) return SZR_ERR_DATA;
        a->lastPath = (prop.vt == VT_BSTR) ? uToUtf8(UString(prop.bstrVal)) : AString("[Content]");
        info->path = a->lastPath.Ptr();
    }
    {
        NCOM::CPropVariant prop;
        if (arc->GetProperty(index, kpidIsDir, &prop) == S_OK && prop.vt == VT_BOOL)
            info->is_dir = VARIANT_BOOLToBool(prop.boolVal) ? 1 : 0;
    }
    {
        NCOM::CPropVariant prop;
        UInt64 size = 0;
        if (arc->GetProperty(index, kpidSize, &prop) == S_OK && ConvertPropVariantToUInt64(prop, size))
            info->size = size;
    }
    {
        NCOM::CPropVariant prop;
        if (arc->GetProperty(index, kpidMTime, &prop) == S_OK && prop.vt == VT_FILETIME)
            info->mtime = NTime::FileTime_To_UnixTime64(prop.filetime);
    }
    {
        NCOM::CPropVariant prop;
        if (arc->GetProperty(index, kpidEncrypted, &prop) == S_OK && prop.vt == VT_BOOL)
            info->is_encrypted = VARIANT_BOOLToBool(prop.boolVal) ? 1 : 0;
    }
    {
        NCOM::CPropVariant prop;
        if (arc->GetProperty(index, kpidAttrib, &prop) == S_OK && prop.vt == VT_UI4
            && (prop.ulVal & FILE_ATTRIBUTE_UNIX_EXTENSION))
            info->posix_mode = prop.ulVal >> 16;
    }
    return SZR_OK;
}

sz_status sz_extract(sz_archive *a, const uint32_t *indices, uint32_t indexCount,
                     const char *destDir, const char *stripPrefix,
                     sz_progress_fn progress, sz_cancel_fn cancel, void *ctx,
                     char **errorMessage)
{
    if (errorMessage) *errorMessage = NULL;
    if (!a || !destDir) return SZR_ERR_ARG;
    if (indices) {
        for (uint32_t i = 0; i < indexCount; i++) if (indices[i] >= a->count) return SZR_ERR_ARG;
    }
    if (!NDir::CreateComplexDir(destDir)) {
        setError(errorMessage, AString("Can't create directory ") + destDir);
        return SZR_ERR_IO;
    }

    CExtractCallback *cbSpec = new CExtractCallback;
    CMyComPtr<IArchiveExtractCallback> cb(cbSpec);
    cbSpec->Init(a->archive, destDir, stripPrefix);
    cbSpec->pw = &a->pw;
    cbSpec->progress = progress;
    cbSpec->cancel = cancel;
    cbSpec->ctx = ctx;
    a->pw.wasAsked = false;

    const HRESULT res = a->archive->Extract(indices, indices ? indexCount : (UInt32)(Int32)-1, 0, cb);
    cbSpec->ApplyDirTimes();

    if (cbSpec->cancelled) return SZR_ERR_CANCELLED;
    if (!cbSpec->ioError.IsEmpty()) { setError(errorMessage, cbSpec->ioError); return SZR_ERR_IO; }
    if (res == E_ABORT && a->pw.wasAsked && !a->pw.defined) {
        setError(errorMessage, "The archive is encrypted");
        return SZR_ERR_ENCRYPTED;
    }
    if (cbSpec->firstFailure >= 0) {
        using namespace NArchive::NExtract::NOperationResult;
        const Int32 f = cbSpec->firstFailure;
        if (f == kWrongPassword || (a->pw.wasAsked && (f == kCRCError || f == kDataError))) {
            setError(errorMessage, "Wrong password");
            return SZR_ERR_ENCRYPTED;
        }
        AString msg;
        switch (f) {
            case kUnsupportedMethod: msg = "Unsupported method"; break;
            case kCRCError: msg = "CRC failed"; break;
            case kUnexpectedEnd: msg = "Unexpected end of data"; break;
            case kUnavailable: msg = "Unavailable data"; break;
            case kHeadersError: msg = "Headers error"; break;
            default: msg = "Data error"; break;
        }
        if (!cbSpec->firstFailurePath.IsEmpty()) msg += ": " + cbSpec->firstFailurePath;
        setError(errorMessage, msg);
        return SZR_ERR_DATA;
    }
    if (res != S_OK) {
        setError(errorMessage, "Extraction failed");
        return SZR_ERR_DATA;
    }
    return SZR_OK;
}

sz_status sz_create(const char *archivePath, const sz_source *sources, uint32_t sourceCount,
                    const char *password, int encryptHeaders, int level, uint64_t volumeSize,
                    sz_progress_fn progress, sz_cancel_fn cancel, void *ctx,
                    char **errorMessage)
{
    if (errorMessage) *errorMessage = NULL;
    if (!archivePath || !sources || sourceCount == 0) return SZR_ERR_ARG;

    CObjectVector<CSourceItem> items;
    for (uint32_t i = 0; i < sourceCount; i++) {
        CSourceItem &it = items.AddNew();
        it.diskPath = sources[i].disk_path;
        it.archivePath = utf8ToU(sources[i].archive_path);
        if (!it.info.Find(it.diskPath.Ptr())) {
            setError(errorMessage, AString("Can't find ") + it.diskPath);
            return SZR_ERR_IO;
        }
        if (S_ISLNK(it.info.GetPosixAttrib())) {
            char target[PATH_MAX + 1];
            const ssize_t n = readlink(it.diskPath.Ptr(), target, PATH_MAX);
            if (n < 0) {
                setError(errorMessage, AString("Can't read symlink ") + it.diskPath);
                return SZR_ERR_IO;
            }
            it.isSymlink = true;
            it.linkTarget.SetFrom(target, (unsigned)n);
        }
    }

    CPasswordState pw;
    if (password && *password) { pw.defined = true; pw.password = utf8ToU(password); }

    NArchive::N7z::CHandler *handler = new NArchive::N7z::CHandler;
    CMyComPtr<IOutArchive> outArchive = handler;
    {
        CMyComPtr<ISetProperties> setProps;
        outArchive->QueryInterface(IID_ISetProperties, (void **)&setProps);
        if (!setProps) { setError(errorMessage, "ISetProperties unsupported"); return SZR_ERR_DATA; }
        const wchar_t *names[2] = { L"x", L"he" };
        NCOM::CPropVariant values[2];
        UInt32 n = 0;
        if (level >= 0) { values[n] = (UInt32)level; names[n] = L"x"; n++; }
        if (pw.defined) { values[n] = encryptHeaders ? true : false; names[n] = L"he"; n++; }
        if (n && setProps->SetProperties(names, values, n) != S_OK) {
            setError(errorMessage, "SetProperties failed");
            return SZR_ERR_DATA;
        }
    }

    CUpdateCallback *cbSpec = new CUpdateCallback;
    CMyComPtr<IArchiveUpdateCallback2> cb(cbSpec);
    cbSpec->items = &items;
    cbSpec->pw = &pw;
    cbSpec->progress = progress;
    cbSpec->cancel = cancel;
    cbSpec->ctx = ctx;

    COutFileStream *fileSpec = NULL;
    CMultiOutStream *multiSpec = NULL;
    CMyComPtr<IOutStream> outStream;
    if (volumeSize > 0) {
        multiSpec = new CMultiOutStream;
        outStream = multiSpec;
        multiSpec->Prefix = archivePath;
        multiSpec->Prefix.Add_Dot();
        CRecordVector<UInt64> sizes;
        sizes.Add(volumeSize);
        multiSpec->Init(sizes);
    } else {
        fileSpec = new COutFileStream;
        outStream = fileSpec;
        if (!fileSpec->Create_ALWAYS(archivePath)) {
            setError(errorMessage, AString("Can't create ") + archivePath);
            return SZR_ERR_IO;
        }
    }

    HRESULT res = outArchive->UpdateItems(outStream, items.Size(), cb);
    if (res == S_OK) {
        if (fileSpec) res = fileSpec->Close();
        else if (multiSpec) {
            unsigned n = 0;
            res = multiSpec->FinalFlush_and_CloseFiles(n);
            // Init() arms NeedDelete so an aborted pack leaves nothing behind;
            // a finished one must keep its volumes when the stream goes away.
            if (res == S_OK) multiSpec->NeedDelete = false;
        }
    } else {
        if (fileSpec) { fileSpec->Close(); unlink(archivePath); }
        else if (multiSpec) { multiSpec->NeedDelete = true; multiSpec->Destruct(); }
    }

    if (cbSpec->cancelled) return SZR_ERR_CANCELLED;
    if (!cbSpec->ioError.IsEmpty()) { setError(errorMessage, cbSpec->ioError); return SZR_ERR_IO; }
    if (res != S_OK) {
        setError(errorMessage, res == E_OUTOFMEMORY ? "Out of memory" : "Compression failed");
        return SZR_ERR_DATA;
    }
    return SZR_OK;
}

} // extern "C"
