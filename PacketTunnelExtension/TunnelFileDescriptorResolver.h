#ifndef WLOC_TUNNEL_FILE_DESCRIPTOR_RESOLVER_H
#define WLOC_TUNNEL_FILE_DESCRIPTOR_RESOLVER_H

#include <stdint.h>

/// Finds the utun control socket owned by the Packet Tunnel process.
/// Returns -1 when no matching descriptor can be found.
int32_t WLOCFindPacketTunnelFileDescriptor(void);

#endif
