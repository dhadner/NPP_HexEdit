#include "NppPluginInterfaceMac.h"

#include <dlfcn.h>

#include <array>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>

namespace {

int g_assertions = 0;
int g_failures = 0;

void hexExpect(bool condition, const std::string &message)
{
    ++g_assertions;
    if (!condition) {
        ++g_failures;
        std::fprintf(stderr, "FAIL: %s\n", message.c_str());
    }
}

void *resolve(void *handle, const char *symbol)
{
    void *sym = dlsym(handle, symbol);
    hexExpect(sym != nullptr, std::string("dlsym(\"") + symbol + "\") returned NULL");
    return sym;
}

}

int main(int argc, char **argv)
{
    if (argc < 2) {
        std::fprintf(stderr, "usage: %s <path-to-HexEditor.dylib>\n", argv[0]);
        return 2;
    }

    const char *dylibPath = argv[1];
    void *handle = dlopen(dylibPath, RTLD_NOW | RTLD_LOCAL);
    if (!handle) {
        std::fprintf(stderr, "FAIL: dlopen(%s) failed: %s\n", dylibPath, dlerror());
        return 1;
    }

    void *setInfoSym = resolve(handle, "setInfo");
    void *getNameSym = resolve(handle, "getName");
    void *getFuncsArraySym = resolve(handle, "getFuncsArray");
    void *beNotifiedSym = resolve(handle, "beNotified");
    void *messageProcSym = resolve(handle, "messageProc");

    if (g_failures > 0) {
        std::fprintf(stderr, "Required exports missing — aborting further checks.\n");
        dlclose(handle);
        return 1;
    }

    auto setInfo = reinterpret_cast<PFUNCSETINFO>(setInfoSym);
    auto getName = reinterpret_cast<PFUNCGETNAME>(getNameSym);
    auto getFuncsArray = reinterpret_cast<PFUNCGETFUNCSARRAY>(getFuncsArraySym);
    (void)beNotifiedSym;
    (void)messageProcSym;

    // The plugin populates funcItem[] inside setInfo. The struct is just stored — no host
    // calls are made through it during setInfo — so a zeroed value is safe for this smoke
    // check (we never invoke the menu commands themselves, which is where handles matter).
    NppData zeroedData = {};
    setInfo(zeroedData);

    const char *name = getName();
    hexExpect(name != nullptr, "getName() returned NULL");
    if (name) {
        hexExpect(std::strcmp(name, "HEX-Editor") == 0,
                  std::string("getName() returned \"") + name + "\", expected \"HEX-Editor\"");
    }

    int nbF = -1;
    FuncItem *items = getFuncsArray(&nbF);
    hexExpect(items != nullptr, "getFuncsArray() returned NULL");
    hexExpect(nbF == 8, std::string("getFuncsArray() set nbF=") + std::to_string(nbF) + ", expected 8");

    if (items && nbF == 8) {
        const std::array<const char *, 8> expectedNames = {
            "View in HEX",
            "Compare HEX",
            "Clear Compare Result",
            "Insert Columns...",
            "Pattern Replace...",
            "Options...",
            "Copy HEX Dump",
            "Help...",
        };

        for (int i = 0; i < nbF; ++i) {
            const char *itemName = items[i]._itemName;
            hexExpect(std::strcmp(itemName, expectedNames[i]) == 0,
                      std::string("funcItem[") + std::to_string(i) + "]._itemName=\"" + itemName +
                      "\", expected \"" + expectedNames[i] + "\"");
            hexExpect(items[i]._pFunc != nullptr,
                      std::string("funcItem[") + std::to_string(i) + "]._pFunc is NULL");
        }
    }

    dlclose(handle);

    if (g_failures == 0) {
        std::printf("PASS: HexEditor.dylib smoke test (%d assertions)\n", g_assertions);
        return 0;
    }
    std::fprintf(stderr, "FAIL: %d/%d assertions failed\n", g_failures, g_assertions);
    return 1;
}
