// unitycam_feed.c — feed frames into the UnityCapture virtual camera from the Mac's webcam.
//
// The DirectShow filter (UnityCaptureFilter64.dll, registered in the VRChat prefix) reads RGBA frames
// from a shared mapping and the two events declared in its own shared.inl:
//
//     mapping "UnityCapture_Data0"  struct SharedMemHeader { maxSize; width; height; stride;
//                                     format; resizemode; mirrormode; timeout; data[]; }
//     mutex   "UnityCapture_Mutx0"
//     events  "UnityCapture_Want0" (consumer -> producer)  "UnityCapture_Sent0" (producer -> consumer)
//
// This program listens on TCP, receives raw BGRA frames from cam_send.m on the Mac (through a gvproxy
// forward), and publishes them. format 0 = FORMAT_UINT8.
//
//   unitycam_feed.exe [--port 9123] [--flip] [--once]
//
// Build: x86_64-w64-mingw32-gcc -O2 -static -o unitycam_feed.exe unitycam_feed.c -lws2_32
#define WIN32_LEAN_AND_MEAN
#define STB_IMAGE_IMPLEMENTATION
#include "stb_image.h"
#include <winsock2.h>
#include <ws2tcpip.h>
#include <windows.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define SHM_DATA   "UnityCapture_Data0"
#define SHM_MUTEX  "UnityCapture_Mutx0"
#define SHM_WANT   "UnityCapture_Want0"
#define SHM_SENT   "UnityCapture_Sent0"
#define MAX_SHARED_IMAGE_SIZE (3840u * 2160u * 4u * 2u)

#pragma pack(push, 4)
struct frame_hdr {
    uint32_t magic;   // 'UCAJ' (JPEG) or 'UCAM' (raw BGRA)
    uint32_t width;
    uint32_t height;
    uint32_t length;  // payload bytes that follow
};
struct shm_header {
    DWORD maxSize;
    int32_t width, height, stride, format, resizemode, mirrormode, timeout;
    uint8_t data[1];
};
#pragma pack(pop)

static HANDLE g_mutex, g_want, g_sent, g_map;
static struct shm_header *g_shm;
static int g_flip = 0;

static int open_shm(void) {
    if (g_shm) return 1;
    DWORD e1 = 0, e2 = 0, e3 = 0, e4 = 0;
    if (!g_mutex) { g_mutex = OpenMutexA(SYNCHRONIZE, FALSE, SHM_MUTEX); if (!g_mutex) e1 = GetLastError(); }
    if (!g_want)  g_want  = CreateEventA(NULL, FALSE, FALSE, SHM_WANT);
    if (!g_sent)  { g_sent = OpenEventA(EVENT_MODIFY_STATE, FALSE, SHM_SENT); if (!g_sent) e2 = GetLastError(); }
    if (!g_map)   { g_map  = OpenFileMappingA(FILE_MAP_WRITE, FALSE, SHM_DATA); if (!g_map) e3 = GetLastError(); }
    if (!g_mutex || !g_want || !g_sent || !g_map) {
        static int warned;
        if (!warned) {
            warned = 1;
            printf("unitycam_feed: UnityCapture not open yet (mutex err=%lu sent err=%lu data err=%lu) - "
                   "VRChat has not started the capture graph; toggle Selfie Expression off/on\n",
                   (unsigned long)e1, (unsigned long)e2, (unsigned long)e4 ? (unsigned long)e4 : (unsigned long)e3);
            fflush(stdout);
        }
        return 0;
    }
    g_shm = (struct shm_header *)MapViewOfFile(g_map, FILE_MAP_WRITE, 0, 0, 0);
    if (!g_shm) return 0;
    printf("unitycam_feed: attached (maxSize=%lu)\n", (unsigned long)g_shm->maxSize);
    fflush(stdout);
    return 1;
}

static int publish(const uint8_t *bgra, uint32_t w, uint32_t h) {
    size_t bytes = (size_t)w * h * 4;
    if (!open_shm()) return 0;
    if (g_shm->maxSize && bytes > g_shm->maxSize) return 0;

    WaitForSingleObject(g_mutex, INFINITE);
    g_shm->width = (int32_t)w;
    g_shm->height = (int32_t)h;
    g_shm->stride = (int32_t)(w * 4);
    g_shm->format = 0;       // FORMAT_UINT8 (RGBA order in memory: B,G,R,A on little endian)
    g_shm->resizemode = 0;
    g_shm->mirrormode = 0;
    g_shm->timeout = 100;
    if (g_flip) {
        for (uint32_t y = 0; y < h; y++)
            memcpy(g_shm->data + (size_t)(h - 1 - y) * w * 4, bgra + (size_t)y * w * 4, (size_t)w * 4);
    } else {
        memcpy(g_shm->data, bgra, bytes);
    }
    ReleaseMutex(g_mutex);
    SetEvent(g_sent);
    WaitForSingleObject(g_want, 0);
    return 1;
}

static int recv_all(SOCKET s, void *buf, size_t len) {
    uint8_t *p = (uint8_t *)buf;
    while (len) {
        int n = recv(s, (char *)p, (int)len, 0);
        if (n <= 0) return 0;
        p += n;
        len -= (size_t)n;
    }
    return 1;
}

int main(int argc, char **argv) {
    int port = 9123;
    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--port") && i + 1 < argc) port = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--flip")) g_flip = 1;
    }

    WSADATA wsa;
    WSAStartup(MAKEWORD(2, 2), &wsa);

    SOCKET srv = socket(AF_INET, SOCK_STREAM, 0);
    int on = 1;
    setsockopt(srv, SOL_SOCKET, SO_REUSEADDR, (char *)&on, sizeof on);
    struct sockaddr_in a = {0};
    a.sin_family = AF_INET;
    a.sin_addr.s_addr = htonl(INADDR_ANY);
    a.sin_port = htons((u_short)port);
    if (bind(srv, (struct sockaddr *)&a, sizeof a) != 0) {
        printf("unitycam_feed: bind %d failed (%d)\n", port, WSAGetLastError());
        return 1;
    }
    listen(srv, 1);
    printf("unitycam_feed: listening on 0.0.0.0:%d, waiting for cam_send\n", port);
    fflush(stdout);

    uint8_t *buf = (uint8_t *)malloc(MAX_SHARED_IMAGE_SIZE * 2);
    uint64_t frames = 0;
    DWORD t0 = GetTickCount();

    for (;;) {
        SOCKET c = accept(srv, NULL, NULL);
        if (c == INVALID_SOCKET) continue;
        printf("unitycam_feed: sender connected\n");
        fflush(stdout);
        for (;;) {
            struct frame_hdr h;
            if (!recv_all(c, &h, sizeof h)) break;
            if (h.length > MAX_SHARED_IMAGE_SIZE * 2) {
                printf("unitycam_feed: frame too large (%lu)\n", (unsigned long)h.length);
                break;
            }
            if (!recv_all(c, buf, h.length)) break;
            uint32_t fw = h.width, fh = h.height;
            uint8_t *pixels = buf;
            if (h.magic == 0x4a414355u /* "UCAJ" */) {
                int jw = 0, jh = 0, jc = 0;
                static unsigned char *jpeg;
                if (!jpeg) jpeg = (unsigned char *)malloc(MAX_SHARED_IMAGE_SIZE * 2);
                pixels = stbi_load_from_memory(buf, (int)h.length, &jw, &jh, &jc, 4);
                if (!pixels) { printf("unitycam_feed: jpeg decode failed\n"); continue; }
                fw = (uint32_t)jw;
                fh = (uint32_t)jh;
            } else if (h.length != h.width * h.height * 4) {
                printf("unitycam_feed: bad raw frame (%ux%u len=%lu)\n", h.width, h.height,
                       (unsigned long)h.length);
                break;
            }
            if (!publish(pixels, fw, fh)) {
                static int warned;
                if (!warned) { printf("unitycam_feed: UnityCapture shared memory not available yet\n"); warned = 1; }
            }
            if (h.magic == 0x4a414355u) stbi_image_free(pixels);
            frames++;
            DWORD now = GetTickCount();
            if (now - t0 >= 1000) {
                printf("unitycam_feed: %llu frames (%ux%u), %lu fps\n",
                       (unsigned long long)frames, fw, fh,
                       (unsigned long)(frames * 1000 / (now - t0)));
                fflush(stdout);
                frames = 0;
                t0 = now;
            }
        }
        closesocket(c);
        printf("unitycam_feed: sender disconnected\n");
        fflush(stdout);
    }
}
