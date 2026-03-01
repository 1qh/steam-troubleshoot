/*
 * version.dll proxy — enables fullscreen without decorations on Wine Wayland.
 *
 * How it works:
 *   1. Placed in the game's bin/ directory as "version.dll"
 *   2. Wine loads it instead of the built-in version.dll (via WINEDLLOVERRIDES)
 *   3. All version.dll API calls are forwarded to the real system version.dll
 *   4. A background thread waits for the game's main window, then:
 *      - Strips window chrome (WS_CAPTION, borders)
 *      - Resizes to cover the entire screen
 *      - Calls ChangeDisplaySettings(CDS_FULLSCREEN)
 *   5. Wine's Wayland driver detects the fullscreen window and requests
 *      xdg_toplevel_set_fullscreen from the compositor — removing decorations
 *
 * Build: i686-w64-mingw32-gcc -shared -O2 -o version.dll fullscreen.c \
 *          -Wl,--subsystem,windows,--kill-at
 */
#include <windows.h>

static HMODULE g_real = NULL;

static void load_real(void) {
    if (g_real) return;
    WCHAR path[MAX_PATH];
    GetSystemDirectoryW(path, MAX_PATH);
    lstrcatW(path, L"\\version.dll");
    g_real = LoadLibraryW(path);
}

#define FORWARD(name, ret, args, callargs) \
    typedef ret (WINAPI *PFN_##name) args; \
    __declspec(dllexport) ret WINAPI name args { \
        load_real(); \
        PFN_##name fn = (PFN_##name)GetProcAddress(g_real, #name); \
        if (fn) return fn callargs; \
        return (ret)0; \
    }

FORWARD(GetFileVersionInfoA, BOOL, (LPCSTR a, DWORD b, DWORD c, LPVOID d), (a,b,c,d))
FORWARD(GetFileVersionInfoW, BOOL, (LPCWSTR a, DWORD b, DWORD c, LPVOID d), (a,b,c,d))
FORWARD(GetFileVersionInfoSizeA, DWORD, (LPCSTR a, LPDWORD b), (a,b))
FORWARD(GetFileVersionInfoSizeW, DWORD, (LPCWSTR a, LPDWORD b), (a,b))
FORWARD(VerQueryValueA, BOOL, (LPCVOID a, LPCSTR b, LPVOID *c, PUINT d), (a,b,c,d))
FORWARD(VerQueryValueW, BOOL, (LPCVOID a, LPCWSTR b, LPVOID *c, PUINT d), (a,b,c,d))
FORWARD(VerLanguageNameA, DWORD, (DWORD a, LPSTR b, DWORD c), (a,b,c))
FORWARD(VerLanguageNameW, DWORD, (DWORD a, LPWSTR b, DWORD c), (a,b,c))
FORWARD(VerFindFileA, DWORD, (DWORD a, LPSTR b, LPSTR c, LPSTR d, LPSTR e, PUINT f, LPSTR g, PUINT h), (a,b,c,d,e,f,g,h))
FORWARD(VerFindFileW, DWORD, (DWORD a, LPWSTR b, LPWSTR c, LPWSTR d, LPWSTR e, PUINT f, LPWSTR g, PUINT h), (a,b,c,d,e,f,g,h))
FORWARD(VerInstallFileA, DWORD, (DWORD a, LPSTR b, LPSTR c, LPSTR d, LPSTR e, LPSTR f, LPSTR g, PUINT h), (a,b,c,d,e,f,g,h))
FORWARD(VerInstallFileW, DWORD, (DWORD a, LPWSTR b, LPWSTR c, LPWSTR d, LPWSTR e, LPWSTR f, LPWSTR g, PUINT h), (a,b,c,d,e,f,g,h))

typedef BOOL (WINAPI *PFN_Ex)(DWORD,LPCVOID,DWORD,DWORD,LPVOID);
typedef DWORD (WINAPI *PFN_ExSz)(DWORD,LPCVOID,LPDWORD);

__declspec(dllexport) BOOL WINAPI GetFileVersionInfoExA(DWORD f, LPCSTR a, DWORD b, DWORD c, LPVOID d) {
    load_real();
    PFN_Ex fn = (PFN_Ex)GetProcAddress(g_real, "GetFileVersionInfoExA");
    return fn ? fn(f,a,b,c,d) : FALSE;
}
__declspec(dllexport) BOOL WINAPI GetFileVersionInfoExW(DWORD f, LPCWSTR a, DWORD b, DWORD c, LPVOID d) {
    load_real();
    PFN_Ex fn = (PFN_Ex)GetProcAddress(g_real, "GetFileVersionInfoExW");
    return fn ? fn(f,a,b,c,d) : FALSE;
}
__declspec(dllexport) DWORD WINAPI GetFileVersionInfoSizeExA(DWORD f, LPCSTR a, LPDWORD b) {
    load_real();
    PFN_ExSz fn = (PFN_ExSz)GetProcAddress(g_real, "GetFileVersionInfoSizeExA");
    return fn ? fn(f,a,b) : 0;
}
__declspec(dllexport) DWORD WINAPI GetFileVersionInfoSizeExW(DWORD f, LPCWSTR a, LPDWORD b) {
    load_real();
    PFN_ExSz fn = (PFN_ExSz)GetProcAddress(g_real, "GetFileVersionInfoSizeExW");
    return fn ? fn(f,a,b) : 0;
}

/* ═══════════════════════════════════════════════════════════════
 * Fullscreen thread — runs inside the game's process
 * ═══════════════════════════════════════════════════════════════ */
static DWORD WINAPI fullscreen_thread(LPVOID param) {
    HWND hwnd = NULL;
    int w, h, attempts;
    LONG style, exstyle;
    DEVMODEW dm;
    DWORD pid = GetCurrentProcessId();

    for (attempts = 0; attempts < 60; attempts++) {
        HWND h2 = NULL;
        while ((h2 = FindWindowExA(NULL, h2, NULL, NULL)) != NULL) {
            DWORD wpid = 0;
            GetWindowThreadProcessId(h2, &wpid);
            if (wpid == pid && IsWindowVisible(h2)) {
                style = GetWindowLongA(h2, GWL_STYLE);
                if ((style & WS_CAPTION) && !(style & WS_CHILD)) {
                    hwnd = h2;
                    break;
                }
            }
        }
        if (hwnd) break;
        Sleep(500);
    }
    if (!hwnd) return 1;

    Sleep(2000);

    w = GetSystemMetrics(SM_CXSCREEN);
    h = GetSystemMetrics(SM_CYSCREEN);

    style = GetWindowLongA(hwnd, GWL_STYLE);
    style &= ~(WS_CAPTION | WS_THICKFRAME | WS_BORDER | WS_DLGFRAME |
               WS_MINIMIZEBOX | WS_MAXIMIZEBOX | WS_SYSMENU);
    style |= WS_POPUP | WS_VISIBLE;
    SetWindowLongA(hwnd, GWL_STYLE, style);

    exstyle = GetWindowLongA(hwnd, GWL_EXSTYLE);
    exstyle &= ~(WS_EX_DLGMODALFRAME | WS_EX_CLIENTEDGE |
                 WS_EX_STATICEDGE | WS_EX_WINDOWEDGE);
    SetWindowLongA(hwnd, GWL_EXSTYLE, exstyle);

    SetWindowPos(hwnd, HWND_TOP, 0, 0, w, h,
                 SWP_FRAMECHANGED | SWP_SHOWWINDOW);

    memset(&dm, 0, sizeof(dm));
    dm.dmSize = sizeof(dm);
    EnumDisplaySettingsW(NULL, ENUM_CURRENT_SETTINGS, &dm);
    ChangeDisplaySettingsW(&dm, CDS_FULLSCREEN);

    while (IsWindow(hwnd)) {
        RECT rc;
        GetWindowRect(hwnd, &rc);
        if (rc.right - rc.left != w || rc.bottom - rc.top != h) {
            SetWindowPos(hwnd, HWND_TOP, 0, 0, w, h,
                         SWP_FRAMECHANGED | SWP_SHOWWINDOW);
        }
        Sleep(2000);
    }
    ChangeDisplaySettingsW(NULL, 0);
    return 0;
}

BOOL WINAPI DllMain(HINSTANCE hinstDLL, DWORD fdwReason, LPVOID lpvReserved) {
    if (fdwReason == DLL_PROCESS_ATTACH) {
        WCHAR path[MAX_PATH];
        GetModuleFileNameW(NULL, path, MAX_PATH);
        if (wcsstr(path, L"ShootersPool Online") ||
            wcsstr(path, L"shooterspool online")) {
            DisableThreadLibraryCalls(hinstDLL);
            CreateThread(NULL, 0, fullscreen_thread, NULL, 0, NULL);
        }
    } else if (fdwReason == DLL_PROCESS_DETACH) {
        if (g_real) FreeLibrary(g_real);
    }
    return TRUE;
}
