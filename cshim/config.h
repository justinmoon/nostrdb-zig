#ifndef CCAN_CONFIG_H
#define CCAN_CONFIG_H
// Force conservative path: CCAN sha256 copies input into aligned buffer.
#define HAVE_UNALIGNED_ACCESS 0
#endif

