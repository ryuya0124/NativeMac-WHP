#pragma once
#include <stddef.h>
#include <stdbool.h>
#ifdef __cplusplus
extern "C" {
#endif
void NativeMacVideoPrimeBroker(void);
int NativeMacVideoOpenSocket(int *writer);
bool NativeMacVideoTransfer(int fd,void *data,size_t size,bool writing);
#ifdef __cplusplus
}
#endif
