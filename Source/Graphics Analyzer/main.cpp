#define GRAPHICS_ANALYZER 1

// Always true in the graphics analyzer
#ifdef DEVELOPMENT
#undef DEVELOPMENT
#define DEVELOPMENT 1
#endif // DEVELOPMENT

#define CHECK_GRAPHICS_API_COMPATIBILITY 1

#include "..\Core\core.hpp"

struct GraphicsAnalyzerDeviceData final : public GameDeviceData
{
};

// Graphics analyzer project.
// This is not meant to be a separate devkit for mods, but an alternative tool that uses the same features that Luma mods have to analyze graphics in games,
// so if you want to make a new game mod, just make a new project for it, after potentially testing the game out with this (it's not necessary, but this is less invasive than a whole mod).
class GraphicsAnalyzer final : public Game
{
   static GraphicsAnalyzerDeviceData& GetGameDeviceData(DeviceData& device_data)
   {
      return *static_cast<GraphicsAnalyzerDeviceData*>(device_data.game);
   }

public:
   void OnInit(bool async) override
   {
      // Needed by the final display composition shader
      luma_settings_cbuffer_index = 13;
      luma_data_cbuffer_index = 12;
   }

   void OnCreateDevice(ID3D11Device* native_device, DeviceData& device_data) override
   {
      device_data.game = new GraphicsAnalyzerDeviceData;
   }

   DrawOrDispatchOverrideType OnDrawOrDispatch(ID3D11Device* native_device, ID3D11DeviceContext* native_device_context, CommandListData& cmd_list_data, DeviceData& device_data, reshade::api::shader_stage stages, const ShaderHashesList<OneShaderPerPipeline>& original_shader_hashes, bool is_custom_pass, bool& updated_cbuffers, std::function<void()>* original_draw_dispatch_func) override
   {
      auto& game_device_data = GetGameDeviceData(device_data);

      return DrawOrDispatchOverrideType::None; // Don't cancel the original draw call
   }
   void OnPresent(ID3D11Device* native_device, DeviceData& device_data) override
   {
   }

   void PrintImGuiAbout() override
   {
      ImGui::Text("DX11 Graphics Analyzer - Developed by Pumbo", "");
   }
};

BOOL APIENTRY DllMain(HMODULE hModule, DWORD ul_reason_for_call, LPVOID lpReserved)
{
   if (ul_reason_for_call == DLL_PROCESS_ATTACH)
   {
      Globals::SetGlobals(PROJECT_NAME, "Luma DX11 Graphics Analyzer", "https://github.com/Filoppi/Luma-Framework/");

      // [LOCAL PATCH] Dump every shader automatically from launch, so shaders seen during
      // loading (before the user can open the overlay) are captured too.
      auto_dump = true;
      // Don't automatically load custom shaders
      auto_load = false;

      // [LOCAL PATCH] Skip the display composition pass entirely.
      //
      // Why: upstream leaves this false, and then core.hpp:5746 asserts
      //   ASSERT_ONCE(target_desc.Format == DXGI_FORMAT_R16G16B16A16_FLOAT || ... R10G10B10A2_UNORM)
      // on any SDR game whose swapchain stays R8G8B8A8_UNORM: the swapchain is never upgraded
      // (swapchain_format_upgrade_type is None below) while the composition pass still runs,
      // because needs_gamma_correction is true whenever DisplayMode == SDR.
      //
      // The assert is non-fatal (debug.h turns ASSERT into a MessageBoxA in NDEBUG Dev builds),
      // but the real fix is to not run the pass at all: we only need the analyzer's tracing,
      // dump and frame-capture features, none of which go through the composition.
      //
      // NOTE: do NOT "fix" this by setting swapchain_format_upgrade_type = AllowedEnabled.
      // That makes Luma recreate the swapchain as R16G16B16A16_FLOAT, and Mafia: DE then
      // deadlocks the moment the game calls SetFullscreenState(TRUE) right after
      // ResizeBuffers (observed: ReShade.log stops dead at 14:51:48.230).
      force_disable_display_composition = true;

      swapchain_format_upgrade_type = TextureFormatUpgradesType::None;
      swapchain_upgrade_type = SwapchainUpgradeType::scRGB;

      // Upstream sets this to false ("It might break some games, but at least one can alt tab
      // quickly"). The core default is true, and core.hpp:3550 carries the author's own note
      // "TODO: test with Mafia 3 and BS2 if actually needed" - this is the same engine family,
      // so keep the protective default rather than fighting exclusive fullscreen.
      prevent_fullscreen_state = true;

      game = new GraphicsAnalyzer();
   }

   CoreMain(hModule, ul_reason_for_call, lpReserved);

   return TRUE;
}