#include "soundcast_shm_shim.h"
#include <fcntl.h>
#include <sys/mman.h>

int soundcast_shm_open_readonly(const char *name)
{
    return shm_open(name, O_RDONLY);
}

int soundcast_shm_open_readwrite(const char *name)
{
    return shm_open(name, O_RDWR);
}
