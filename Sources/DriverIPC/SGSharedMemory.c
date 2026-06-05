// SGSharedMemory.c
// Wrappers for shm_open / shm_unlink — see SGSharedMemory.h for rationale.

#include "include/SGSharedMemory.h"
#include <sys/mman.h>
#include <fcntl.h>

int sg_shm_open(const char *name, int oflag, unsigned short mode)
{
    return shm_open(name, oflag, (mode_t)mode);
}

int sg_shm_unlink(const char *name)
{
    return shm_unlink(name);
}
