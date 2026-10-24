/* BlinxSetup.exe: the installer as one file to download and double-click.
 *
 * It carries BlinxSetup.ps1 (setup_script.h, made by build-setup.sh), writes
 * it to %TEMP% and runs it with Windows PowerShell in this console, which
 * shows the progress. Its arguments go on to the script (-InstallDir,
 * -Iso, -NoShortcuts). */
#include <windows.h>
#include <stdio.h>
#include <wchar.h>

#include "setup_script.h"   /* k_script[], k_script_len */

int wmain(int argc, wchar_t **argv)
{
    wchar_t tmp[MAX_PATH], ps1[MAX_PATH], ps[MAX_PATH], cmd[8192];
    STARTUPINFOW si;
    PROCESS_INFORMATION pi;
    DWORD code = 1, wrote;
    HANDLE f;
    int i;

    SetConsoleTitleW(L"Installation de Blinx");
    GetTempPathW(MAX_PATH, tmp);
    swprintf(ps1, MAX_PATH, L"%lsBlinxSetup-%lu.ps1", tmp, GetCurrentProcessId());
    f = CreateFileW(ps1, GENERIC_WRITE, 0, NULL, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL);
    if (f == INVALID_HANDLE_VALUE
            || !WriteFile(f, k_script, (DWORD)k_script_len, &wrote, NULL)
            || wrote != k_script_len) {
        MessageBoxW(NULL, L"Impossible d'écrire le script d'installation dans %TEMP%.",
                    L"Installation de Blinx", MB_ICONERROR);
        return 1;
    }
    CloseHandle(f);

    GetSystemDirectoryW(ps, MAX_PATH);
    wcscat(ps, L"\\WindowsPowerShell\\v1.0\\powershell.exe");
    swprintf(cmd, 8192, L"\"%ls\" -NoProfile -ExecutionPolicy Bypass -File \"%ls\"", ps, ps1);
    for (i = 1; i < argc; i++) {
        size_t n = wcslen(cmd);
        swprintf(cmd + n, 8192 - n, L" \"%ls\"", argv[i]);
    }

    memset(&si, 0, sizeof si);
    si.cb = sizeof si;
    if (!CreateProcessW(ps, cmd, NULL, NULL, FALSE, 0, NULL, NULL, &si, &pi)) {
        MessageBoxW(NULL, L"Windows PowerShell est introuvable.", L"Installation de Blinx",
                    MB_ICONERROR);
        DeleteFileW(ps1);
        return 1;
    }
    WaitForSingleObject(pi.hProcess, INFINITE);
    GetExitCodeProcess(pi.hProcess, &code);
    CloseHandle(pi.hThread);
    CloseHandle(pi.hProcess);
    DeleteFileW(ps1);
    if (code != 0) {
        wprintf(L"\nL'installation s'est arrêtée (code %lu). Appuyez sur Entrée.\n",
                (unsigned long)code);
        getchar();
    }
    return (int)code;
}
