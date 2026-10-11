#include "TunnelFileDescriptorResolver.h"

#include <stdint.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/socket.h>
#include <unistd.h>

#ifndef AF_SYSTEM
#define AF_SYSTEM 32
#endif

#define WLOC_CTLIOCGINFO 0xc0644e03UL
#define WLOC_UTUN_CONTROL_NAME "com.apple.net.utun_control"

struct wloc_ctl_info {
    uint32_t ctl_id;
    char ctl_name[96];
};

struct wloc_sockaddr_ctl {
    uint8_t sc_len;
    uint8_t sc_family;
    uint16_t ss_sysaddr;
    uint32_t sc_id;
    uint32_t sc_unit;
    uint32_t sc_reserved[5];
};

int32_t WLOCFindPacketTunnelFileDescriptor(void)
{
    struct wloc_ctl_info control_info = {0};
    strlcpy(
        control_info.ctl_name,
        WLOC_UTUN_CONTROL_NAME,
        sizeof(control_info.ctl_name)
    );

    for (int32_t descriptor = 0; descriptor <= 1024; descriptor++) {
        struct wloc_sockaddr_ctl address = {0};
        socklen_t address_length = sizeof(address);
        int result = getpeername(
            descriptor,
            (struct sockaddr *)&address,
            &address_length
        );
        if (result != 0 || address.sc_family != AF_SYSTEM) {
            continue;
        }

        if (control_info.ctl_id == 0) {
            result = ioctl(descriptor, WLOC_CTLIOCGINFO, &control_info);
            if (result != 0) {
                continue;
            }
        }
        if (address.sc_id == control_info.ctl_id) {
            return descriptor;
        }
    }
    return -1;
}
