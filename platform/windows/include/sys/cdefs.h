#pragma once

#ifdef __cplusplus
#define __BEGIN_DECLS extern "C" {
#define __END_DECLS }
#else
#define __BEGIN_DECLS
#define __END_DECLS
#endif
#define __dead2 __attribute__((noreturn))
#define __pure2 __attribute__((const))
#define __unused __attribute__((unused))
#define __printflike(formatIndex, firstArgument) \
    __attribute__((format(printf, formatIndex, firstArgument)))
#define __DARWIN_ALIAS(symbol)
#define __DARWIN_ALIAS_C(symbol)
#define __DARWIN_INODE64(symbol)
