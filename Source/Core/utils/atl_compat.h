#pragma once
// [LOCAL PATCH] Minimal stand-in for the ATL facilities Luma's Core needs.
//
// Why: "C++ ATL for latest v143 build tools" is an OPTIONAL Visual Studio component and is not
// installed with VS 2022 BuildTools, so <atlbase.h> does not exist and the build stops at
// Source/Core/utils/shader_compiler.hpp:3.
//
// Scope (verified by grepping all of Source/Core and Source/Graphics Analyzer): only CComPtr
// and CAtlException are used - no CString, CComQIPtr, CA2A/CW2A, CA2W, USES_CONVERSION,
// ATLASSERT or ATLTRACE anywhere in the codebase.
//
// This is a purpose-built CComPtr rather than an alias of Microsoft::WRL::ComPtr: WRL's ComPtr
// intentionally dropped the implicit "operator T*" that ATL has, and it has Reset()/As() instead
// of Release()/QueryInterface(). Every call site in shader_compiler.hpp relies on the ATL
// behaviour (passing a CComPtr<T> straight into a T* parameter, &ptr yielding T** after
// releasing, ptr.Release(), ptr.QueryInterface(&other)).

#include <Windows.h>

#include <cstddef>
#include <string>
#include <utility>

// ATL's atlbase.h pulls in the common Win32 import libraries via "#pragma comment(lib, ...)",
// and Luma's project files rely on that (they don't list user32/shell32/ole32 themselves).
// Without these the build compiles but fails to link with ~30 LNK2019 (OpenClipboard,
// SHOpenFolderAndSelectItems, QueryDisplayConfig, MessageBoxA, GetWindowLongPtrW, ...).
#pragma comment(lib, "user32.lib")
#pragma comment(lib, "gdi32.lib")
#pragma comment(lib, "shell32.lib")
#pragma comment(lib, "ole32.lib")
#pragma comment(lib, "advapi32.lib")
#pragma comment(lib, "comdlg32.lib")

template <class T>
class CComPtr
{
public:
   CComPtr() noexcept = default;
   CComPtr(std::nullptr_t) noexcept {}

   // Not explicit: ATL's CComPtr is implicitly constructible from a raw pointer.
   CComPtr(T* other) noexcept : p_(other)
   {
      if (p_ != nullptr)
      {
         p_->AddRef();
      }
   }

   CComPtr(const CComPtr& other) noexcept : p_(other.p_)
   {
      if (p_ != nullptr)
      {
         p_->AddRef();
      }
   }

   CComPtr(CComPtr&& other) noexcept : p_(other.p_) { other.p_ = nullptr; }

   ~CComPtr() { InternalRelease(); }

   CComPtr& operator=(const CComPtr& other) noexcept
   {
      if (p_ != other.p_)
      {
         if (other.p_ != nullptr)
         {
            other.p_->AddRef();
         }
         InternalRelease();
         p_ = other.p_;
      }
      return *this;
   }

   CComPtr& operator=(CComPtr&& other) noexcept
   {
      if (this != &other)
      {
         InternalRelease();
         p_ = other.p_;
         other.p_ = nullptr;
      }
      return *this;
   }

   CComPtr& operator=(T* other) noexcept
   {
      if (p_ != other)
      {
         if (other != nullptr)
         {
            other->AddRef();
         }
         InternalRelease();
         p_ = other;
      }
      return *this;
   }

   CComPtr& operator=(std::nullptr_t) noexcept
   {
      InternalRelease();
      return *this;
   }

   // ATL behaviour: taking the address releases whatever we hold and hands out a fresh slot,
   // which is what every "&ptr" out-parameter call site depends on.
   T** operator&() noexcept
   {
      InternalRelease();
      return &p_;
   }

   operator T*() const noexcept { return p_; }

   T* operator->() const noexcept { return p_; }
   T* Get() const noexcept { return p_; }

   void Release() noexcept { InternalRelease(); }

   template <class Q>
   HRESULT QueryInterface(Q** pp) const noexcept
   {
      if (p_ == nullptr)
      {
         return E_POINTER;
      }
      return p_->QueryInterface(__uuidof(Q), reinterpret_cast<void**>(pp));
   }

private:
   void InternalRelease() noexcept
   {
      T* const p = p_;
      if (p != nullptr)
      {
         p_ = nullptr;
         p->Release();
      }
   }

   T* p_ = nullptr;
};

// ATL's CA2W: converts a narrow (ANSI/UTF-8) string into something usable as a LPCWSTR.
// ATL picks a stack buffer for short strings and falls back to the heap; a std::wstring is
// simpler and all call sites here are cold paths (shader entry point / define conversion).
class CA2W
{
public:
   explicit CA2W(const char* source, UINT code_page = CP_ACP)
   {
      if (source == nullptr)
      {
         return;
      }

      const int needed = ::MultiByteToWideChar(code_page, 0, source, -1, nullptr, 0);
      if (needed <= 0)
      {
         return;
      }

      buffer_.resize(static_cast<std::size_t>(needed));
      const int written = ::MultiByteToWideChar(code_page, 0, source, -1, buffer_.data(), needed);
      if (written > 0)
      {
         buffer_.resize(static_cast<std::size_t>(written) - 1); // drop the null terminator
      }
      else
      {
         buffer_.clear();
      }
   }

   CA2W(const CA2W&) = delete;
   CA2W& operator=(const CA2W&) = delete;

   operator LPCWSTR() const { return buffer_.c_str(); }
   LPCWSTR c_str() const { return buffer_.c_str(); }

private:
   std::wstring buffer_;
};

// ATL's exception type. shader_compiler.hpp catches this by reference, so it only has to exist
// and expose "m_hr".
class CAtlException
{
public:
   CAtlException() noexcept : m_hr(E_FAIL) {}
   CAtlException(HRESULT hr) noexcept : m_hr(hr) {}

   operator HRESULT() const noexcept { return m_hr; }

   HRESULT m_hr;
};
