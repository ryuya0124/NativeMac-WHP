#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include <Windows.h>
#include <d3d11.h>
#include <dxgi1_6.h>
#include <d3dcompiler.h>
#include <wrl/client.h>
#include <memory>
#include <cstdio>
#include <cstring>

using Microsoft::WRL::ComPtr;

// WinUI 3's documented SwapChainPanel interop interface.
struct __declspec(uuid("63aad0b8-7c24-40ff-85a8-640d944cc325")) PanelNative : IUnknown {
    virtual HRESULT STDMETHODCALLTYPE SetSwapChain(IDXGISwapChain* swapChain) = 0;
};

namespace {
struct GpuFailure { HRESULT hr; const char* stage; };
void CheckGpu(HRESULT hr, const char* stage) { if (FAILED(hr)) throw GpuFailure{hr, stage}; }

// GPU draws every pixel. The host submits commands; there is no WARP fallback.
constexpr char Shader[] = R"(
cbuffer Params : register(b0) { float elapsed; float3 padding; };
struct Varying { float4 pos : SV_Position; float2 uv : TEXCOORD0; };
Varying VS(uint id : SV_VertexID) {
    Varying v;
    float2 p = float2((id << 1) & 2, id & 2);
    v.uv = p;
    v.pos = float4(p * float2(2,-2) + float2(-1,1), 0, 1);
    return v;
}
float4 PS(Varying v) : SV_Target {
    float2 uv = v.uv;
    float wave = sin(uv.x * 6 + elapsed * 0.4) * 0.06;
    float glow = saturate(1 - length((uv - float2(.62,.48)) * float2(1.0,1.5)));
    float3 c = lerp(float3(.035,.055,.12), float3(.09,.45,.61), glow * glow);
    c += float3(.07,.035,.12) * (sin((uv.y + wave) * 18) * .5 + .5);
    float grid = max(step(.985, frac(uv.x * 32)), step(.985, frac(uv.y * 18)));
    c += grid * .035;
    return float4(c, 1);
}
)";

struct Renderer {
    ComPtr<ID3D11Device> device;
    ComPtr<ID3D11DeviceContext> context;
    ComPtr<IDXGISwapChain1> swap;
    ComPtr<ID3D11Texture2D> texture;
    ComPtr<ID3D11RenderTargetView> target;
    ComPtr<ID3D11VertexShader> vertex;
    ComPtr<ID3D11PixelShader> pixel;
    ComPtr<ID3D11Buffer> constants;
    ComPtr<PanelNative> panel;
    DXGI_ADAPTER_DESC1 adapter{};
    UINT width = 960, height = 540;
    UINT frames = 0;
    ~Renderer() { if (panel) panel->SetSwapChain(nullptr); }

    void Target() {
        if (swap) CheckGpu(swap->GetBuffer(0, IID_PPV_ARGS(&texture)), "GetBackBuffer");
        else {
            D3D11_TEXTURE2D_DESC desc{};
            desc.Width = width; desc.Height = height; desc.MipLevels = desc.ArraySize = 1;
            desc.Format = DXGI_FORMAT_B8G8R8A8_UNORM;
            desc.SampleDesc.Count = 1; desc.BindFlags = D3D11_BIND_RENDER_TARGET;
            CheckGpu(device->CreateTexture2D(&desc, nullptr, &texture), "CreateGpuTexture");
        }
        CheckGpu(device->CreateRenderTargetView(texture.Get(), nullptr, &target), "CreateRenderTarget");
    }
    void Create(IUnknown* inspectable) {
        ComPtr<IDXGIFactory6> factory;
        CheckGpu(CreateDXGIFactory1(IID_PPV_ARGS(&factory)), "CreateDXGIFactory");
        ComPtr<IDXGIAdapter1> selected;
        for (UINT i = 0; ; ++i) {
            ComPtr<IDXGIAdapter1> candidate;
            HRESULT hr = factory->EnumAdapterByGpuPreference(i, DXGI_GPU_PREFERENCE_HIGH_PERFORMANCE,
                IID_PPV_ARGS(&candidate));
            if (hr == DXGI_ERROR_NOT_FOUND) break;
            CheckGpu(hr, "EnumerateHardwareGpu");
            DXGI_ADAPTER_DESC1 desc{};
            CheckGpu(candidate->GetDesc1(&desc), "ReadAdapter");
            if (desc.Flags & DXGI_ADAPTER_FLAG_SOFTWARE) continue;
            D3D_FEATURE_LEVEL level;
            D3D_FEATURE_LEVEL levels[] = {D3D_FEATURE_LEVEL_11_1, D3D_FEATURE_LEVEL_11_0};
            hr = D3D11CreateDevice(candidate.Get(), D3D_DRIVER_TYPE_UNKNOWN, nullptr,
                D3D11_CREATE_DEVICE_BGRA_SUPPORT, levels, ARRAYSIZE(levels), D3D11_SDK_VERSION,
                &device, &level, &context);
            if (SUCCEEDED(hr)) { selected = candidate; adapter = desc; break; }
        }
        if (!selected) throw GpuFailure{DXGI_ERROR_UNSUPPORTED, "NoHardwareGpu_NoCpuFallback"};
        if (inspectable) {
            CheckGpu(inspectable->QueryInterface(IID_PPV_ARGS(&panel)), "QuerySwapChainPanel");
            DXGI_SWAP_CHAIN_DESC1 desc{};
            desc.Width = width; desc.Height = height;
            desc.Format = DXGI_FORMAT_B8G8R8A8_UNORM; desc.SampleDesc.Count = 1;
            desc.BufferUsage = DXGI_USAGE_RENDER_TARGET_OUTPUT; desc.BufferCount = 2;
            desc.SwapEffect = DXGI_SWAP_EFFECT_FLIP_DISCARD;
            desc.AlphaMode = DXGI_ALPHA_MODE_IGNORE;
            CheckGpu(factory->CreateSwapChainForComposition(device.Get(), &desc, nullptr, &swap),
                "CreateCompositionSwapChain");
            CheckGpu(panel->SetSwapChain(swap.Get()), "SetSwapChain");
        }
        Target();
        ComPtr<ID3DBlob> vs, ps, errors;
        CheckGpu(D3DCompile(Shader, sizeof(Shader)-1, nullptr, nullptr, nullptr, "VS", "vs_5_0", 0, 0,
            &vs, &errors), "CompileVertexShader");
        CheckGpu(D3DCompile(Shader, sizeof(Shader)-1, nullptr, nullptr, nullptr, "PS", "ps_5_0", 0, 0,
            &ps, &errors), "CompilePixelShader");
        CheckGpu(device->CreateVertexShader(vs->GetBufferPointer(), vs->GetBufferSize(), nullptr, &vertex),
            "CreateVertexShader");
        CheckGpu(device->CreatePixelShader(ps->GetBufferPointer(), ps->GetBufferSize(), nullptr, &pixel),
            "CreatePixelShader");
        D3D11_BUFFER_DESC desc{};
        desc.ByteWidth = 16; desc.Usage = D3D11_USAGE_DEFAULT; desc.BindFlags = D3D11_BIND_CONSTANT_BUFFER;
        CheckGpu(device->CreateBuffer(&desc, nullptr, &constants), "CreateConstants");
    }
    void Draw(float elapsed) {
        float params[] = {elapsed, 0, 0, 0};
        context->UpdateSubresource(constants.Get(), 0, nullptr, params, 0, 0);
        context->OMSetRenderTargets(1, target.GetAddressOf(), nullptr);
        D3D11_VIEWPORT viewport{0,0,static_cast<float>(width),static_cast<float>(height),0,1};
        context->RSSetViewports(1, &viewport);
        context->IASetPrimitiveTopology(D3D11_PRIMITIVE_TOPOLOGY_TRIANGLELIST);
        context->VSSetShader(vertex.Get(), nullptr, 0);
        context->PSSetShader(pixel.Get(), nullptr, 0);
        context->PSSetConstantBuffers(0, 1, constants.GetAddressOf());
        context->Draw(3, 0);
        if (swap) CheckGpu(swap->Present(1, 0), "Present");
        else context->Flush();
        CheckGpu(device->GetDeviceRemovedReason(), "DeviceRemoved");
        ++frames;
    }
    void VerifyPixels() {
        D3D11_TEXTURE2D_DESC desc{};
        texture->GetDesc(&desc);
        desc.BindFlags = 0; desc.MiscFlags = 0; desc.Usage = D3D11_USAGE_STAGING;
        desc.CPUAccessFlags = D3D11_CPU_ACCESS_READ;
        ComPtr<ID3D11Texture2D> readback;
        CheckGpu(device->CreateTexture2D(&desc, nullptr, &readback), "CreateReadback");
        context->CopyResource(readback.Get(), texture.Get());
        D3D11_MAPPED_SUBRESOURCE mapped{};
        CheckGpu(context->Map(readback.Get(), 0, D3D11_MAP_READ, 0, &mapped), "ReadGpuResult");
        auto sample = static_cast<unsigned char*>(mapped.pData) + (height/2)*mapped.RowPitch + (width/2)*4;
        bool good = sample[0] > 0 && sample[1] > 0 && sample[2] > 0 && sample[3] == 255;
        context->Unmap(readback.Get(), 0);
        if (!good) throw GpuFailure{E_FAIL, "GpuPixelVerification"};
    }
};

void Report(Renderer* r, HRESULT hr, const char* stage, char* output, uint32_t capacity) {
    if (!output || capacity < 4096) return;
    char name[256]{};
    if (r) WideCharToMultiByte(CP_UTF8, 0, r->adapter.Description, -1, name, sizeof(name), nullptr, nullptr);
    for (auto& ch : name) if (ch == '"' || ch == '\\') ch = '_';
    snprintf(output, capacity,
        "{\"status\":\"%s\",\"stage\":\"%s\",\"hresult\":\"0x%08X\","
        "\"adapter\":\"%s\",\"vendorId\":%u,\"deviceId\":%u,\"frames\":%u,"
        "\"hardware\":%s,\"cpuFallback\":false,\"guestGpuAccelerated\":false}",
        SUCCEEDED(hr) ? "passed" : "failed", stage, static_cast<unsigned>(hr), name,
        r ? r->adapter.VendorId : 0, r ? r->adapter.DeviceId : 0, r ? r->frames : 0,
        r && r->device ? "true" : "false");
}
}

extern "C" __declspec(dllexport) int __cdecl NmGpuCreate(IUnknown* panel,
    void** handle, char* report, uint32_t capacity) {
    if (!handle || !report || capacity < 4096) return E_INVALIDARG;
    *handle = nullptr;
    try {
        auto r = std::make_unique<Renderer>();
        r->Create(panel);
        r->Draw(0);
        if (!panel) r->VerifyPixels();
        Report(r.get(), S_OK, panel ? "SwapChainReady" : "GpuPixelsVerified", report, capacity);
        *handle = r.release();
        return S_OK;
    } catch (const GpuFailure& f) {
        Report(nullptr, f.hr, f.stage, report, capacity);
        return f.hr;
    } catch (...) {
        Report(nullptr, E_UNEXPECTED, "NativeGpuException", report, capacity);
        return E_UNEXPECTED;
    }
}

extern "C" __declspec(dllexport) int __cdecl NmGpuDraw(void* handle, float elapsed) {
    if (!handle) return E_INVALIDARG;
    try { static_cast<Renderer*>(handle)->Draw(elapsed); return S_OK; }
    catch (const GpuFailure& f) { return f.hr; }
    catch (...) { return E_UNEXPECTED; }
}
extern "C" __declspec(dllexport) void __cdecl NmGpuDestroy(void* handle) {
    delete static_cast<Renderer*>(handle);
}
