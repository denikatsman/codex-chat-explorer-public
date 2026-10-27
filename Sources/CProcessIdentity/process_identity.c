#include "CProcessIdentity.h"
#include <libproc.h>
#include <sys/proc_info.h>
#include <sys/sysctl.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <signal.h>

uint64_t explorer_process_generation(pid_t pid) {
    struct proc_bsdinfo info;
    if (proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, sizeof info) != sizeof info) return 0;
    return (uint64_t)info.pbi_start_tvsec * 1000000u + info.pbi_start_tvusec;
}
pid_t explorer_process_parent(pid_t pid) {
    struct proc_bsdinfo info;
    if (proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, sizeof info) != sizeof info) return -1;
    return (pid_t)info.pbi_ppid;
}
static int has_marker(pid_t pid, const char *marker) {
    int mib[3] = {CTL_KERN, KERN_PROCARGS2, pid}; size_t size = 0;
    if (sysctl(mib, 3, NULL, &size, NULL, 0) || size > 1024*1024 || size < sizeof(int)) return 0;
    char *bytes = malloc(size); if (!bytes) return 0;
    if (sysctl(mib, 3, bytes, &size, NULL, 0)) { free(bytes); return 0; }
    size_t wanted = strlen(marker); int found = 0;
    for (size_t i = sizeof(int); i < size;) {
        size_t count = strnlen(bytes+i, size-i);
        if (count == wanted && !memcmp(bytes+i, marker, wanted)) { found=1; break; }
        i += count + 1;
    }
    free(bytes); return found;
}
int explorer_owned_group(pid_t group, const char *marker) {
    if (group <= 1 || !marker || !*marker) return 0;
    pid_t pids[1024]; int bytes = proc_listpids(PROC_PGRP_ONLY, (uint32_t)group, pids, sizeof pids);
    if (bytes <= 0) return 0;
    for (int i=0; i < bytes/(int)sizeof(pid_t); i++) {
        struct proc_bsdinfo info;
        if (pids[i] <= 0 || proc_pidinfo(pids[i], PROC_PIDTBSDINFO, 0, &info, sizeof info) != sizeof info) continue;
        if (info.pbi_status == 5) continue; /* zombie: no work can continue */
        if (has_marker(pids[i], marker)) return 1;
    }
    return 0;
}

int explorer_group_has_other_live_members(pid_t group, pid_t leader) {
    if (group <= 1 || group != leader) return 1;
    pid_t pids[1024]; int bytes = proc_listpids(PROC_PGRP_ONLY, (uint32_t)group, pids, sizeof pids);
    if (bytes <= 0) return 1;
    for (int i = 0; i < bytes/(int)sizeof(pid_t); i++) {
        if (pids[i] <= 0 || pids[i] == leader) continue;
        struct proc_bsdinfo info;
        if (proc_pidinfo(pids[i], PROC_PIDTBSDINFO, 0, &info, sizeof info) != sizeof info) return 1;
        if (info.pbi_status != 5) return 1;
    }
    return 0;
}

int explorer_process_identity_live(pid_t pid, uint64_t generation) {
    struct proc_bsdinfo info;
    if (proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, sizeof info) != sizeof info) {
        if (kill(pid, 0) == -1 && errno == ESRCH) return 0;
        return -1;
    }
    uint64_t current = (uint64_t)info.pbi_start_tvsec * 1000000u + info.pbi_start_tvusec;
    return current == generation && info.pbi_status != 5 ? 1 : 0;
}
