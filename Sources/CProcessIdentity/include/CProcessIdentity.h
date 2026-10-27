#include <stdint.h>
#include <sys/types.h>
uint64_t explorer_process_generation(pid_t pid);
pid_t explorer_process_parent(pid_t pid);
int explorer_owned_group(pid_t group, const char *marker);
/* Caller must prove it is the leader of this private process group. Unknown is nonzero. */
int explorer_group_has_other_live_members(pid_t group, pid_t leader);
/* 1 = same live process, 0 = gone/replaced/zombie, -1 = inspection unavailable. */
int explorer_process_identity_live(pid_t pid, uint64_t generation);
