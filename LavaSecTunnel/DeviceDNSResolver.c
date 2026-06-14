#include <arpa/inet.h>
#include <netinet/in.h>
#include <resolv.h>
#include <string.h>

static int LavaSecAppendDNSServer(char *buffer, int bufferLength, const char *address) {
    if (bufferLength <= 0 || address == NULL || address[0] == '\0') {
        return 0;
    }

    int currentLength = (int)strnlen(buffer, (size_t)bufferLength);
    if (currentLength >= bufferLength - 1) {
        return 0;
    }

    int separatorLength = currentLength == 0 ? 0 : 1;
    int addressLength = (int)strnlen(address, INET6_ADDRSTRLEN);
    if (currentLength + separatorLength + addressLength >= bufferLength) {
        return 0;
    }

    if (separatorLength == 1) {
        buffer[currentLength] = '\n';
        currentLength += 1;
        buffer[currentLength] = '\0';
    }

    strlcat(buffer, address, (size_t)bufferLength);
    return 1;
}

int LavaSecCopySystemDNSServers(char *buffer, int bufferLength) {
    if (bufferLength <= 0) {
        return 0;
    }

    buffer[0] = '\0';

    struct __res_state state;
    memset(&state, 0, sizeof(state));
    if (res_ninit(&state) != 0) {
        return 0;
    }

    union res_sockaddr_union servers[MAXNS];
    memset(servers, 0, sizeof(servers));
    int serverCount = res_getservers(&state, servers, MAXNS);
    int appendedCount = 0;

    for (int index = 0; index < serverCount; index += 1) {
        char address[INET6_ADDRSTRLEN];
        memset(address, 0, sizeof(address));

        if (servers[index].sin.sin_family == AF_INET) {
            if (inet_ntop(AF_INET, &servers[index].sin.sin_addr, address, sizeof(address)) == NULL) {
                continue;
            }
        } else if (servers[index].sin6.sin6_family == AF_INET6) {
            if (inet_ntop(AF_INET6, &servers[index].sin6.sin6_addr, address, sizeof(address)) == NULL) {
                continue;
            }
        } else {
            continue;
        }

        appendedCount += LavaSecAppendDNSServer(buffer, bufferLength, address);
    }

    res_ndestroy(&state);
    return appendedCount;
}
