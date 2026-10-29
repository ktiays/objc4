#pragma once
#ifdef __cplusplus
extern "C" {
#endif
int backtrace(void **buffer, int count);
void backtrace_symbols_fd(void *const *buffer, int count, int fd);
#ifdef __cplusplus
}
#endif
