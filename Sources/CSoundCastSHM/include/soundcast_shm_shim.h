#ifndef SOUNDCAST_SHM_SHIM_H
#define SOUNDCAST_SHM_SHIM_H

// Swift cannot call shm_open directly — it's declared variadic in
// Darwin's <sys/mman.h> (the third, mode_t argument only applies when
// O_CREAT is passed), and Swift refuses to bridge any variadic C
// function at all, even when the variadic argument is unused. This
// thin, fixed-signature wrapper is the workaround (same one used for
// the standalone C diagnostic tool, test_shm_flow.c, earlier).
int soundcast_shm_open_readonly(const char *name);
// Read-write, for the one header field the app writes (latencyFrames).
int soundcast_shm_open_readwrite(const char *name);

#endif
