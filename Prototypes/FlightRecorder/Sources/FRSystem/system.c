#include "FRSystem.h"
#include <libproc.h>
#include <unistd.h>
#include <mach-o/dyld.h>
#include <mach-o/loader.h>
#include <string.h>
#include <uuid/uuid.h>
#include <sys/resource.h>
FRMetrics fr_metrics(void) {
    FRMetrics m = {0}; struct proc_taskinfo t;
    if (proc_pidinfo(getpid(), PROC_PIDTASKINFO, 0, &t, sizeof(t)) != sizeof(t)) return m;
    m.available = 1; m.resident_bytes = t.pti_resident_size; m.virtual_bytes = t.pti_virtual_size;
    struct rusage usage;
    if (getrusage(RUSAGE_SELF, &usage) != 0) return (FRMetrics){0};
    m.cpu_user_ns = (uint64_t)usage.ru_utime.tv_sec * 1000000000ULL + (uint64_t)usage.ru_utime.tv_usec * 1000ULL;
    m.cpu_system_ns = (uint64_t)usage.ru_stime.tv_sec * 1000000000ULL + (uint64_t)usage.ru_stime.tv_usec * 1000ULL;
    m.threads = t.pti_threadnum;
    return m;
}
double fr_process_start(void) {
    struct proc_bsdinfo p;
    if (proc_pidinfo(getpid(), PROC_PIDTBSDINFO, 0, &p, sizeof(p)) != sizeof(p)) return 0;
    return (double)p.pbi_start_tvsec + (double)p.pbi_start_tvusec / 1000000.;
}
int fr_binary_uuid(char out[37]) {
    const struct mach_header *h = _dyld_get_image_header(0);
    if (!h || h->magic != MH_MAGIC_64) return 0;
    const uint8_t *p = (const uint8_t *)h + sizeof(struct mach_header_64), *end = p + h->sizeofcmds;
    for (uint32_t n = 0; n < h->ncmds && p + sizeof(struct load_command) <= end; n++) {
        const struct load_command *c = (const struct load_command *)p;
        if (c->cmdsize < sizeof(*c) || c->cmdsize > (uint64_t)(end - p)) return 0;
        if (c->cmd == LC_UUID && c->cmdsize >= sizeof(struct uuid_command)) {
            uuid_unparse_upper(((const struct uuid_command *)p)->uuid, out); return 1;
        }
        p += c->cmdsize;
    }
    return 0;
}
