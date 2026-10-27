#pragma once
#include <stdint.h>
typedef struct {
    int available;
    uint64_t resident_bytes, virtual_bytes, cpu_user_ns, cpu_system_ns;
    uint32_t threads;
} FRMetrics;
FRMetrics fr_metrics(void);
double fr_process_start(void);
int fr_binary_uuid(char out[37]);
