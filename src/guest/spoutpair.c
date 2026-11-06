// spoutpair.exe — an independent Spout-shaped sender/receiver, so the guest half of the bridge can be
// tested without VRChat.
//
// It reproduces exactly what Spout2's SpoutDX does for a sender: a D3D11 texture created with
// D3D11_RESOURCE_MISC_SHARED, its legacy IDXGIResource::GetSharedHandle value published through a named
// file mapping, which the receiver opens with ID3D11Device::OpenSharedResource. Two separate processes
// therefore exercise the same cross-process path VRChat's KlakSpout uses.
//
//   spoutpair.exe --send [--width W] [--height H] [--format rgba|bgra] [--alpha] [--seconds S]
//   spoutpair.exe --recv [--seconds S] [--dump FILE]
//
// Build (macOS host): x86_64-w64-mingw32-g++ -O2 -static -o spoutpair.exe spoutpair.c -ld3d11 -ldxgi -luuid
#define COBJMACROS
#include <windows.h>
#include <d3d11.h>
#include <dxgi.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define MAP_NAME "SpoutBridgeTest"
#define MAP_MAGIC 0x53505431u  // "SPT1"

#pragma pack(push, 1)
struct shared_hdr {
  unsigned magic;
  unsigned width, height, dxgi_format;
  unsigned long long handle;  // IDXGIResource::GetSharedHandle value
  unsigned frame;             // sender increments per published frame
  unsigned reserved;
};
#pragma pack(pop)

static int g_fail;
static void check(int ok, const char *what, HRESULT hr) {
  printf("%s %-52s hr=0x%08lx\n", ok ? "ok  " : "FAIL", what, (unsigned long)hr);
  fflush(stdout);
  if (!ok) g_fail++;
}

static ID3D11Device *make_device(void) {
  ID3D11Device *d = NULL;
  D3D_FEATURE_LEVEL fl;
  HRESULT hr = D3D11CreateDevice(NULL, D3D_DRIVER_TYPE_HARDWARE, NULL, 0, NULL, 0, D3D11_SDK_VERSION, &d, &fl, NULL);
  check(SUCCEEDED(hr) && d, "D3D11CreateDevice", hr);
  if (d) {
    IDXGIDevice *dxdev = NULL;
    if (SUCCEEDED(ID3D11Device_QueryInterface(d, &IID_IDXGIDevice, (void **)&dxdev))) {
      IDXGIAdapter *ad = NULL;
      if (SUCCEEDED(IDXGIDevice_GetAdapter(dxdev, &ad))) {
        DXGI_ADAPTER_DESC ad_desc;
        if (SUCCEEDED(IDXGIAdapter_GetDesc(ad, &ad_desc)))
          printf("     adapter: %ls (vendor %04x device %04x)\n", ad_desc.Description, ad_desc.VendorId,
                 ad_desc.DeviceId);
        IDXGIAdapter_Release(ad);
      }
      IDXGIDevice_Release(dxdev);
    }
  }
  return d;
}

// ---- pattern: unambiguous for orientation / colour / alpha / motion
static void paint(unsigned char *px, int W, int H, unsigned frame, int rgba, int alpha) {
  for (int y = 0; y < H; y++) {
    for (int x = 0; x < W; x++) {
      unsigned char *p = px + ((size_t)y * W + x) * 4;
      unsigned char r, g, b, a = 255;
      if (x < W / 2 && y < H / 2)      { r = 255; g = 0;   b = 0;   }  // top-left  red
      else if (x >= W / 2 && y < H / 2){ r = 0;   g = 255; b = 0;   }  // top-right green
      else if (x < W / 2)              { r = 0;   g = 0;   b = 255; }  // bottom-left blue
      else                             { r = 255; g = 255; b = 255; }  // bottom-right white
      int bar = (int)((frame * 7u) % (unsigned)W);
      if (x >= bar && x < bar + 40) { r = 255; g = 255; b = 0; }       // moving yellow bar
      if (x < 4 || y < 4 || x >= W - 4 || y >= H - 4) { r = 0; g = 0; b = 0; }  // black border
      if (alpha) {
        a = (unsigned char)((x * 255) / (W - 1));                       // horizontal alpha ramp
        if (x < 4 || y < 4 || x >= W - 4 || y >= H - 4) a = 255;
      }
      if (rgba) { p[0] = r; p[1] = g; p[2] = b; p[3] = a; }
      else      { p[0] = b; p[1] = g; p[2] = r; p[3] = a; }
    }
  }
}

static int do_send(int W, int H, int rgba, int alpha, double seconds) {
  ID3D11Device *dev = make_device();
  ID3D11DeviceContext *ctx = NULL;
  if (!dev) return 1;
  ID3D11Device_GetImmediateContext(dev, &ctx);

  D3D11_TEXTURE2D_DESC d = {0};
  d.Width = W; d.Height = H; d.MipLevels = 1; d.ArraySize = 1;
  d.Format = rgba ? DXGI_FORMAT_R8G8B8A8_UNORM : DXGI_FORMAT_B8G8R8A8_UNORM;
  d.SampleDesc.Count = 1;
  d.Usage = D3D11_USAGE_DEFAULT;
  d.BindFlags = D3D11_BIND_RENDER_TARGET | D3D11_BIND_SHADER_RESOURCE;
  d.MiscFlags = D3D11_RESOURCE_MISC_SHARED;  // exactly what SpoutDX/KlakSpout use

  ID3D11Texture2D *tex = NULL;
  HRESULT hr = ID3D11Device_CreateTexture2D(dev, &d, NULL, &tex);
  check(SUCCEEDED(hr) && tex, "CreateTexture2D MISC_SHARED (sender)", hr);
  printf("     %dx%d %s\n", W, H, rgba ? "R8G8B8A8_UNORM" : "B8G8R8A8_UNORM");
  if (!tex) return 1;

  IDXGIResource *res = NULL;
  HANDLE shared = NULL;
  hr = ID3D11Texture2D_QueryInterface(tex, &IID_IDXGIResource, (void **)&res);
  check(SUCCEEDED(hr) && res, "QueryInterface(IDXGIResource)", hr);
  if (res) {
    hr = IDXGIResource_GetSharedHandle(res, &shared);
    check(SUCCEEDED(hr) && shared, "IDXGIResource::GetSharedHandle", hr);
    IDXGIResource_Release(res);
  }
  if (!shared) {
    printf("RESULT: FAIL (no shared handle: this is what a DXMT/wmtr gap would look like)\n");
    return 1;
  }
  printf("     shared handle = 0x%llx\n", (unsigned long long)(uintptr_t)shared);

  HANDLE map = CreateFileMappingA(INVALID_HANDLE_VALUE, NULL, PAGE_READWRITE, 0, sizeof(struct shared_hdr), MAP_NAME);
  check(map != NULL, "CreateFileMappingA(" MAP_NAME ")", map ? S_OK : HRESULT_FROM_WIN32(GetLastError()));
  struct shared_hdr *h = map ? (struct shared_hdr *)MapViewOfFile(map, FILE_MAP_ALL_ACCESS, 0, 0, sizeof *h) : NULL;
  check(h != NULL, "MapViewOfFile", h ? S_OK : HRESULT_FROM_WIN32(GetLastError()));
  if (!h) return 1;

  unsigned char *px = (unsigned char *)malloc((size_t)W * H * 4);
  LARGE_INTEGER freq, t0, now;
  QueryPerformanceFrequency(&freq);
  QueryPerformanceCounter(&t0);
  unsigned frame = 0;
  for (;;) {
    paint(px, W, H, frame, rgba, alpha);
    D3D11_BOX box = {0, 0, 0, (UINT)W, (UINT)H, 1};
    ID3D11DeviceContext_UpdateSubresource(ctx, (ID3D11Resource *)tex, 0, &box, px, W * 4, 0);
    ID3D11DeviceContext_Flush(ctx);
    h->magic = MAP_MAGIC;
    h->width = W; h->height = H; h->dxgi_format = rgba ? 28 : 87;
    h->handle = (unsigned long long)(uintptr_t)shared;
    h->frame = ++frame;
    QueryPerformanceCounter(&now);
    double t = (double)(now.QuadPart - t0.QuadPart) / freq.QuadPart;
    if (seconds > 0 && t >= seconds) break;
    if ((frame % 30) == 0) printf("     sent frame %u t=%.1fs\n", frame, t);
    Sleep(33);
  }
  printf("RESULT: PASS (sender published %u frames)\n", frame);
  return g_fail ? 1 : 0;
}

static int do_recv(double seconds, const char *dump) {
  ID3D11Device *dev = make_device();
  ID3D11DeviceContext *ctx = NULL;
  if (!dev) return 1;
  ID3D11Device_GetImmediateContext(dev, &ctx);

  HANDLE map = OpenFileMappingA(FILE_MAP_ALL_ACCESS, FALSE, MAP_NAME);
  check(map != NULL, "OpenFileMappingA(" MAP_NAME ")", map ? S_OK : HRESULT_FROM_WIN32(GetLastError()));
  struct shared_hdr *h = map ? (struct shared_hdr *)MapViewOfFile(map, FILE_MAP_ALL_ACCESS, 0, 0, sizeof *h) : NULL;
  check(h != NULL, "MapViewOfFile", h ? S_OK : HRESULT_FROM_WIN32(GetLastError()));
  if (!h) return 1;
  check(h->magic == MAP_MAGIC, "shared registry magic", h->magic == MAP_MAGIC ? S_OK : E_FAIL);
  printf("     sender says %ux%u dxgi_format=%u handle=0x%llx frame=%u\n", h->width, h->height, h->dxgi_format,
         (unsigned long long)h->handle, h->frame);

  ID3D11Texture2D *opened = NULL;
  HANDLE shared = (HANDLE)(uintptr_t)h->handle;
  HRESULT hr = ID3D11Device_OpenSharedResource(dev, shared, &IID_ID3D11Texture2D, (void **)&opened);
  check(SUCCEEDED(hr) && opened, "OpenSharedResource on a second device (cross-process)", hr);
  if (!opened) {
    printf("RESULT: FAIL (cross-process shared texture could not be opened)\n");
    return 1;
  }
  D3D11_TEXTURE2D_DESC od;
  ID3D11Texture2D_GetDesc(opened, &od);
  printf("     opened: %ux%u fmt=%u bind=0x%x misc=0x%x\n", od.Width, od.Height, od.Format, od.BindFlags,
         od.MiscFlags);

  D3D11_TEXTURE2D_DESC sd = od;
  sd.BindFlags = 0; sd.MiscFlags = 0; sd.Usage = D3D11_USAGE_STAGING; sd.CPUAccessFlags = D3D11_CPU_ACCESS_READ;
  ID3D11Texture2D *stage = NULL;
  hr = ID3D11Device_CreateTexture2D(dev, &sd, NULL, &stage);
  check(SUCCEEDED(hr) && stage, "staging texture", hr);
  if (!stage) return 1;

  unsigned last_frame = 0, changed = 0, samples = 0;
  LARGE_INTEGER freq, t0, now;
  QueryPerformanceFrequency(&freq);
  QueryPerformanceCounter(&t0);
  for (;;) {
    if (h->frame != last_frame) {
      ID3D11DeviceContext_CopyResource(ctx, (ID3D11Resource *)stage, (ID3D11Resource *)opened);
      D3D11_MAPPED_SUBRESOURCE m = {0};
      hr = ID3D11DeviceContext_Map(ctx, (ID3D11Resource *)stage, 0, D3D11_MAP_READ, 0, &m);
      if (SUCCEEDED(hr)) {
        unsigned char *p = (unsigned char *)m.pData;
        unsigned w = od.Width, hh = od.Height;
        unsigned char tl[4] = {p[0], p[1], p[2], p[3]};
        unsigned char tr[4], bl[4], br[4];
        unsigned char *q;
        q = p + 4 * (w - 20); memcpy(tr, q, 4);
        q = p + (size_t)(hh - 20) * m.RowPitch + 4 * 20; memcpy(bl, q, 4);
        q = p + (size_t)(hh - 20) * m.RowPitch + 4 * (w - 20); memcpy(br, q, 4);
        printf("     frame %u corners TL=%02x%02x%02x%02x TR=%02x%02x%02x%02x BL=%02x%02x%02x%02x BR=%02x%02x%02x%02x\n",
               h->frame, tl[0], tl[1], tl[2], tl[3], tr[0], tr[1], tr[2], tr[3], bl[0], bl[1], bl[2], bl[3], br[0],
               br[1], br[2], br[3]);
        if (dump && samples == 0) {
          FILE *f = fopen(dump, "wb");
          if (f) { fwrite(p, 1, (size_t)m.RowPitch * hh, f); fclose(f); }
          printf("     raw frame -> %s\n", dump);
        }
        ID3D11DeviceContext_Unmap(ctx, (ID3D11Resource *)stage, 0);
        changed++;
      }
      samples++;
      last_frame = h->frame;
    }
    QueryPerformanceCounter(&now);
    double t = (double)(now.QuadPart - t0.QuadPart) / freq.QuadPart;
    if (seconds > 0 && t >= seconds) break;
    Sleep(20);
  }
  printf("RESULT: %s (%u distinct frames received in %.1fs)\n", changed > 5 ? "PASS" : "FAIL", changed, seconds);
  return changed > 5 ? 0 : 1;
}

int main(int argc, char **argv) {
  int send = 0, recv = 0, W = 1280, H = 720, rgba = 1, alpha = 0;
  double seconds = 0;
  const char *dump = NULL;
  for (int i = 1; i < argc; i++) {
    if (!strcmp(argv[i], "--send")) send = 1;
    else if (!strcmp(argv[i], "--recv")) recv = 1;
    else if (!strcmp(argv[i], "--width") && i + 1 < argc) W = atoi(argv[++i]);
    else if (!strcmp(argv[i], "--height") && i + 1 < argc) H = atoi(argv[++i]);
    else if (!strcmp(argv[i], "--format") && i + 1 < argc) rgba = strcmp(argv[++i], "bgra") != 0;
    else if (!strcmp(argv[i], "--alpha")) alpha = 1;
    else if (!strcmp(argv[i], "--seconds") && i + 1 < argc) seconds = atof(argv[++i]);
    else if (!strcmp(argv[i], "--dump") && i + 1 < argc) dump = argv[++i];
    else { printf("usage: %s --send|--recv [--width W] [--height H] [--format rgba|bgra] [--alpha] [--seconds S] [--dump F]\n", argv[0]); return 2; }
  }
  if (send) return do_send(W, H, rgba, alpha, seconds);
  if (recv) return do_recv(seconds, dump);
  printf("usage: %s --send|--recv ...\n", argv[0]);
  return 2;
}
