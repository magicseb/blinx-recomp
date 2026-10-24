/* Blinx.exe: the game's launcher, what the desktop shortcut starts.
 *
 * blinx_recomp.exe is a console program (its log goes to stdout/stderr).
 * This starts it beside itself without a console window, its output in
 * logs\blinx.log (the previous run's kept as blinx.old.log), with the
 * variables of launcher.cfg set first (KEY=VALUE lines, # comments; the
 * installer writes BLINX_FFMPEG there). If the game ends with an error
 * within its first seconds, the log's last lines are shown.
 *
 * Built by the installer with llvm-mingw:
 *   clang -O2 -municode -mwindows launcher.c launcher.res -o Blinx.exe */
#include <windows.h>
#include <stdio.h>
#include <string.h>
#include <wchar.h>

#define GAME_EXE L"blinx_recomp.exe"

static void here(wchar_t *dir, DWORD n)
{
    wchar_t *s;
    GetModuleFileNameW(NULL, dir, n);
    s = wcsrchr(dir, L'\\');
    if (s)
        *s = 0;
}

/* launcher.cfg: KEY=VALUE per line, UTF-8, # starts a comment. */
static void load_cfg(const wchar_t *dir)
{
    wchar_t path[MAX_PATH];
    char line[2048];
    FILE *f;

    swprintf(path, MAX_PATH, L"%ls\\launcher.cfg", dir);
    f = _wfopen(path, L"rb");
    if (!f)
        return;
    while (fgets(line, sizeof line, f)) {
        char *eq, *e;
        wchar_t k[256], v[1800];
        if (line[0] == '#' || !(eq = strchr(line, '=')))
            continue;
        *eq = 0;
        for (e = eq + 1 + strlen(eq + 1); e > eq + 1 && (e[-1] == '\n' || e[-1] == '\r'); )
            *--e = 0;
        if (!MultiByteToWideChar(CP_UTF8, 0, line, -1, k, 256)
                || !MultiByteToWideChar(CP_UTF8, 0, eq + 1, -1, v, 1800))
            continue;
        SetEnvironmentVariableW(k, v);
    }
    fclose(f);
}

/* The last ~1500 bytes of the log, for the error box. */
static void log_tail(const wchar_t *path, wchar_t *out, size_t n)
{
    char buf[1600];
    size_t got = 0;
    FILE *f = _wfopen(path, L"rb");

    out[0] = 0;
    if (!f)
        return;
    if (fseek(f, -1500, SEEK_END) != 0)
        fseek(f, 0, SEEK_SET);
    got = fread(buf, 1, sizeof buf - 1, f);
    fclose(f);
    buf[got] = 0;
    MultiByteToWideChar(CP_UTF8, 0, buf, -1, out, (int)n);
}

int WINAPI wWinMain(HINSTANCE inst, HINSTANCE prev, LPWSTR cmd, int show)
{
    wchar_t dir[MAX_PATH], exe[MAX_PATH], logs[MAX_PATH], log[MAX_PATH], old[MAX_PATH];
    wchar_t cmdline[MAX_PATH * 2];
    SECURITY_ATTRIBUTES sa = {sizeof sa, NULL, TRUE};
    STARTUPINFOW si;
    PROCESS_INFORMATION pi;
    HANDLE out;
    DWORD code = 0, t0;
    (void)inst; (void)prev; (void)show;

    here(dir, MAX_PATH);
    swprintf(exe, MAX_PATH, L"%ls\\%ls", dir, GAME_EXE);
    swprintf(logs, MAX_PATH, L"%ls\\logs", dir);
    swprintf(log, MAX_PATH, L"%ls\\blinx.log", logs);
    swprintf(old, MAX_PATH, L"%ls\\blinx.old.log", logs);
    if (GetFileAttributesW(exe) == INVALID_FILE_ATTRIBUTES) {
        MessageBoxW(NULL, L"blinx_recomp.exe est introuvable à côté du lanceur.\n"
                    L"Relancez l'installation (BlinxSetup.exe).", L"Blinx", MB_ICONERROR);
        return 1;
    }
    load_cfg(dir);
    CreateDirectoryW(logs, NULL);
    MoveFileExW(log, old, MOVEFILE_REPLACE_EXISTING);
    out = CreateFileW(log, GENERIC_WRITE, FILE_SHARE_READ, &sa, CREATE_ALWAYS,
                      FILE_ATTRIBUTE_NORMAL, NULL);

    memset(&si, 0, sizeof si);
    si.cb = sizeof si;
    if (out != INVALID_HANDLE_VALUE) {
        si.dwFlags = STARTF_USESTDHANDLES;
        si.hStdInput = GetStdHandle(STD_INPUT_HANDLE);
        si.hStdOutput = out;
        si.hStdError = out;
    }
    /* The arguments given to the launcher go on to the game. */
    swprintf(cmdline, MAX_PATH * 2, L"\"%ls\" %ls", exe, cmd ? cmd : L"");
    t0 = GetTickCount();
    if (!CreateProcessW(exe, cmdline, NULL, NULL, TRUE, CREATE_NO_WINDOW, NULL, dir, &si, &pi)) {
        MessageBoxW(NULL, L"Le jeu n'a pas pu démarrer.", L"Blinx", MB_ICONERROR);
        return 1;
    }
    if (out != INVALID_HANDLE_VALUE)
        CloseHandle(out);
    CloseHandle(pi.hThread);
    WaitForSingleObject(pi.hProcess, INFINITE);
    GetExitCodeProcess(pi.hProcess, &code);
    CloseHandle(pi.hProcess);
    if (code != 0 && GetTickCount() - t0 < 15000) {
        wchar_t tail[1600], msg[2200];
        log_tail(log, tail, 1600);
        swprintf(msg, 2200, L"Le jeu s'est arrêté au démarrage (code %lu).\n"
                 L"Journal : %ls\n\n...%ls", (unsigned long)code, log, tail);
        MessageBoxW(NULL, msg, L"Blinx", MB_ICONWARNING);
    }
    return (int)code;
}
