// Minimal DXBC -> SM5 disassembly helper.
//
// Luma's development builds dump every shader the game binds into
// "<game>/Luma/<mod name>/Dump/<hash>.<stage>_<model>.cso" (see the dump code in
// core.hpp). Those dumps are plain DXBC containers, and D3DDisassemble is the
// only public API that turns them back into readable assembly, so this tool is
// the way to see what a game pass actually does without a GPU debugger.
//
// Usage:  disasm <file.cso> [profile]
//         disasm --batch <folder-with-cso-files> [profile]
//
// The profile only matters for the "%s" printf inside DXBC, so "ps_5_0" is a fine
// default for the pixel shaders Luma dumps.
//
// Build (x64, from a VS developer prompt or with the paths in build-mafiade.bat):
//   cl /nologo /EHsc /std:c++17 /O1 disasm.cpp /link d3dcompiler.lib

#include <d3dcompiler.h>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>
#include <filesystem>

namespace fs = std::filesystem;

static bool DisassembleOne(const std::string& path, const char* profile, FILE* out)
{
   (void)profile;   // D3DDisassemble takes no target profile, the DXBC already carries the model
   FILE* f = nullptr;
   if (fopen_s(&f, path.c_str(), "rb") != 0 || !f)
   {
      fprintf(out, "[X] cannot open %s\n", path.c_str());
      return false;
   }
   fseek(f, 0, SEEK_END);
   long size = ftell(f);
   fseek(f, 0, SEEK_SET);
   std::vector<char> code(static_cast<size_t>(size > 0 ? size : 0));
   if (size > 0 && fread(code.data(), 1, code.size(), f) != code.size())
   {
      fclose(f);
      fprintf(out, "[X] short read on %s\n", path.c_str());
      return false;
   }
   fclose(f);
   if (code.size() < 8 || memcmp(code.data(), "DXBC", 4) != 0)
   {
      fprintf(out, "[X] %s is not a DXBC container\n", path.c_str());
      return false;
   }

   ID3DBlob* disasm = nullptr;
   const HRESULT hr = D3DDisassemble(code.data(), code.size(), D3D_DISASM_ENABLE_DEFAULT_VALUE_PRINTS, path.c_str(), &disasm);
   if (FAILED(hr) || !disasm)
   {
      fprintf(out, "[X] D3DDisassemble failed (hr=0x%08lX) on %s\n", static_cast<unsigned long>(hr), path.c_str());
      return false;
   }
   fprintf(out, "==== %s (%zu bytes of DXBC, %zu bytes of assembly) ====\n",
           path.c_str(), code.size(), disasm->GetBufferSize());
   fwrite(disasm->GetBufferPointer(), 1, disasm->GetBufferSize(), out);
   fprintf(out, "\n");
   disasm->Release();
   return true;
}

int main(int argc, char** argv)
{
   const char* profile = "ps_5_0";
   if (argc < 2)
   {
      fprintf(stderr, "usage: disasm <file.cso> [profile] | disasm --batch <folder> [profile]\n");
      return 2;
   }
   const bool batch = strcmp(argv[1], "--batch") == 0;
   const char* target = batch ? argv[2] : argv[1];
   if (batch && argc >= 4) { profile = argv[3]; }
   if (!batch && argc >= 3) { profile = argv[2]; }

   if (!batch)
   {
      return DisassembleOne(target, profile, stdout) ? 0 : 1;
   }

   std::error_code ec;
   std::vector<fs::path> files;
   for (const auto& entry : fs::directory_iterator(target, ec))
   {
      if (entry.is_regular_file() && entry.path().extension() == ".cso") { files.push_back(entry.path()); }
   }
   // Deterministic order, so two runs produce comparable output.
   std::sort(files.begin(), files.end());
   int ok = 0;
   for (const auto& p : files)
   {
      if (DisassembleOne(p.string(), profile, stdout)) { ok++; }
   }
   fprintf(stdout, "==== %d of %zu shaders disassembled ====\n", ok, files.size());
   return ok > 0 ? 0 : 1;
}
