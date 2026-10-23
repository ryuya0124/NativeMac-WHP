# NativeMac · WHP Lab

Windows上でIntel版macOS 26を動かす、WinUI 3アプリとOpenVMM/WHP用の自作PCI・ストレージ実装です。

**macOS 26.6.2 build 25G83（Intel）の通常OSが起動し、初期設定画面を表示しました。ゲストのMetal計算4096個をRTX 5080で実行し、全結果の一致を確認しました。**

GPU名はWindows側でVMが実際に選択したVulkanアダプターから起動ごとに取得します。ゲストへ[名前の自動反映処理](native/GpuIdentityAgent/README.md)を導入すると、標準のAppleドライバーのままMetal APIにも反映されます。「NVIDIA GeForce RTX 5080」と表示した状態でGeekbench Metal全11項目を完走しました（[2378点](https://browser.geekbench.com/v7/gpu/317477)）。前回の3238点より低く、差の原因は未特定です。[名前反映の検証条件](docs/verification/gpu-metal-identity.json)を参照してください。

CPUはWHPで実行し、QEMU実行ファイル・QEMUコア・CPU命令の動的変換を使用しません。Appleの復旧DMGは原本を読み取り専用で参照します。RAM・CPUは起動前に変更できます（設定上限256 GiB・64コア）。現在の割り当てと検証は12 GiB・8コアのままです。実際に確保できる容量はホストの空きメモリなどに依存します。

2026-10-22のFHD検証では、共有RAMを64 MiBずつの独立したWindowsセクションに分け、画面停止時に起きていた長いGPUメモリ割り当て待ちを改善しました。30分で184,144フレームを描画し、約8.51億個のGPU計算結果が一致しました。3回のロック・解除、ドラッグ、ホイール、4アプリの起動・切替も確認しました。GPUハングとカーネルパニックは0件です。[検証の条件と限界](docs/verification/banked-gpu-ram.json)を参照してください。

軽量のFHD 3D診断は平均151.46完了フレーム/秒でした。大きなMetal命令送信の拒否を修正し、[プロセス限定の互換層](native/MetalCompat/README.md)を使用したGravityMark 1.89は、FHD・2万小惑星の実際の描画を確認して3回連続完走しました（各167秒、23.7～24.0fps）。別のMetal三角形ベンチマークも、投影行列の修正後に両モードを完走しました（800×600、約160fps）。ヒープ・mesh実行などは未対応で、全Metal機能や全アプリの互換性を保証する結果ではありません。新しい修正での長時間安定性も未認定です。[条件と限界](docs/verification/metal-benchmarks.json)を参照してください。

実装・検証できたもの：

- WinUI 3、WHPによるx64ゲスト実行、RTX 5080によるホスト描画プローブ。
- Microsoft OpenVMMのWHPバックエンドによるUEFI、OpenCore、AMD向けXNUパッチ。
- 原本ファイルからGPT/FAT32を読み取り専用で提供するストレージ。DMGの形式変換は行いません。
- macOS 26.6.2 build 25G83のカーネル、launchd、WindowServer、復旧GUI、Terminal。
- 修正済みMacHyperVSupportによるキーボード、マウス、ネットワーク、SCSIディスクの接続。VM専用のAPFSディスクを作成。
- 独立したReims vGPU Cライブラリー用PCIフロントエンド、Vulkan上の実GPU初期化、UEFI GOP、共有RAMによる起動フレームバッファー。
- M4 Mac miniでIntel向けMetal検証プログラムと修正済みMacHyperVSupportをクロスビルド。
- 通常OSのAppleParavirtGPUドライバー、Metalのシェーダー生成・計算・GPU完了待ち・共有バッファー読み戻し。
- WinUIからのVM起動・終了、RAM/CPU上限、同じワークスペースの二重VM起動防止。
- マウスホイールの上下スクロール。HIDを符号付き8ビットのホイールと予約1バイトに修正し、ゲストでの動作を確認。

検証結果は`artifacts/metal-probe/guest-metal.json`、OSバージョンとGPU情報は`artifacts/metal-probe/guest-report.txt`、実際のGPU描画画面は`artifacts/normal-os-gpu-verified.png`、GitHubに含めた検証結果は[Metal計算](docs/verification/guest-metal.json)、[GPU情報](docs/verification/guest-report.txt)、[起動画面](docs/verification/setup-assistant.png)、機械可読な状態は`vm/progress.json`です。Metalの`verified: true`は4096個のGPU計算結果をCPU側で照合した結果です。ホスト単体プローブやM4上での実行結果とは分けて記録しています。

CPUはx64をWHPで実行します。GPUはAppleの仮想GPUドライバー → Reims → Vulkan → RTX 5080です。MetalシェーダーのAIRからSPIR-Vへの変換はあります。Radeonの直接パススルーではありません。初期設定画面への到達を検証しました。ユーザーアカウントの設定は利用者が行います。

## ビルドと起動

必要なもの：Windows x64、.NET 10 SDK、Visual StudioのC++ x64ビルドツール、Windows SDK 10.0.26100.0、Windows Hypervisor Platformが利用可能な環境。

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/Build.ps1 -Publish
.\artifacts\app\TahoeVm.exe --start-vm --memory 12 --processors 8
```

起動選択画面では`NativeMac`（通常は2番）を選びEnterを押してください。Ctrl+Enterで既定の起動先に保存できます。ゲスト画面はGPU用の別ウィンドウに表示され、WinUIからリソースと電源を管理します。最初の起動は初期設定画面になります。

発行結果は.NET／Windows App SDKを含むフォルダー形式です。`TahoeVm.exe`だけを単独で移動せず、`artifacts/app`全体を使ってください。ビルドやアプリはWindowsの機能設定・ドライバー・既存VMを変更しません。

ネイティブ部分のみの検証：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/Build-Native.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/Test-Engine.ps1
```

GUI接続の検証用レポート：

```powershell
.\artifacts\app\TahoeVm.exe --smoke-report C:\path\ui-smoke.json
```

起動時にCPU・GPUのテストを実行し、実際の結果と表示フレーム数をJSONに保存します。macOSの起動成功を示すレポートではありません。

## VMバックエンドの開発起動

依存ソースとローカルビルド成果物は`backend/`、`artifacts/`に置きます。自作フロントエンドのソースは`native/MediaFat`と`native/VGpuPci`、上流への変更は`patches/`に保存します。

```powershell
.\scripts\Start-VM.ps1 -MemoryGiB 12 -Processors 8 -Gpu
```

実行中のREPLで`quit`を入力すると終了します。起動スクリプトはVM専用の128 GiBスパースRAWディスクを作成します。物理ディスクは使用しません。入力用RFBは127.0.0.1:5905に限定し、Reimsの画面表示とは分離しています。

表示の最大解像度はWinUIでFHD・WQHD・4K（3840×2160）から選択でき、次回起動時に適用されます。既定値はFHDです。4Kデスクトップと3840×2160のGravityMark 1.89が完走しました（平均17.3fps、167.2秒、スコア2895）。これは選択した互換アダプターでの結果で、すべてのMetalアプリへの対応を意味しません。4Kの選択方法・制限は[検証記録](docs/verification/fourk-display.json)を参照してください。コマンド起動では`--resolution 3840x2160`、PowerShellでは`-DisplayResolution 3840x2160`を指定します。ゲストの更新頻度は60Hzを既定とし、PowerShellの`-DisplayRefreshHz`で30〜240Hzに変更できます。実験中のIntel Metal互換ブリッジを既定で使用し、連続マウス移動を8msごとにまとめます。FHDのMetal描画テストでは20秒間で3043フレーム、平均約152fpsを記録しました。最新の64 MiB分割版では、3回のロック・解除と30分の描画・GPUメモリ照合を通過しました。幅広いアプリ互換性や、それ以上の長期安定性は検証中です。ビルド手順・既知の失敗・判定条件は[GPU安定性の調査](docs/GPU_STABILITY.md)を参照してください。

macOSの「システム設定 → ディスプレイ」から、起動時に設定した上限まで解像度を変更できます。4K等倍・WQHD・4K出力の1920×1080 HiDPI表示への切り替えを確認しました。Geekbench 7.1.0 CPUは[シングル2287・マルチ10415](https://browser.geekbench.com/v7/cpu/692080)で完走し、Metal版も全11項目を検証エラー0件で完走しました（[3238点](https://browser.geekbench.com/v7/gpu/317315)、他のベンチマークとの同時実行はありませんが、軽い診断操作を含むため厳密な性能比較用の測定ではありません）。[検証記録](docs/verification/geekbench7.json)を参照してください。また、Intel VM内のXcode 26.5で、変更していないMochiLogのiOS・watchOS Simulator向け[ビルドが成功](docs/verification/mochilog-vm-build.json)しました。

制約：ゲスト画面のWinUIパネル内への埋め込み、音声、長時間の互換性・性能検証は未実装／未実施です。Metal機能はゲストが報告するMetal 2です。GPUが認識されることと、すべてのmacOSアプリが正常動作することは別の検証です。

フロントエンドは32・64・128ビットのMMIOアクセスを32ビットC API操作に分解します。64ビットアクセスを拒否していた実装ではGPUリソース生成に失敗しました。修正後、通常OSのGUIとMetal計算が成功しました。

## GPUの調査結果（2026-10-21）

Intel MacはRadeonを搭載しており、AppleはAMD 500／Vega／5000／6000系列をMetal対応GPUとして記載しています。Radeon向けの既存ドライバーを使う方向は成立する研究対象です。ただし、仮想GPUのPCI IDを変更するだけで、そのドライバーが期待するハードウェアを満たせるわけではありません。

| 方式 | 確認できたこと | この実装との関係 |
|---|---|---|
| 実Radeonのパススルー | macOS向けAMDドライバーを利用できる構成がある。Windowsホスト・GPU・ゲストの組み合わせには制約がある | 未実装。GPUの切り離し・割り当ては行っていない |
| Radeon互換仮想GPU | AMDがGPU ISAを公開している。命令・コマンド・メモリ管理などを再現する開発が必要 | 調査候補。既存Radeonとして認識させるだけではGPU描画にならない |
| Appleの仮想GPUドライバーを利用 | Reims vGPUがmacOS標準ドライバーとVulkanを接続。GPUライブラリーは独立したC APIを公開している | 独立ライブラリーをOpenVMM/WHP用の自作PCIフロントエンドに接続。ゲスト内Metal計算4096個と通常OSのGUI描画を確認 |

RaphaelGPUは、このPCのRyzen内蔵GPUに近いRaphael／Granite RidgeでAppleのAMDドライバーを使う実験です。ただし、公開検証はLinux＋VFIO＋QEMU/KVMであり、本アプリのWindows／WHPで動くことの証拠にはなりません。

ReimsのWindows開発ブランチにもTahoeの動作報告がありますが、QEMU/WHPXによるもので、自作WHPエンジンへの統合・継続動作は別途検証が必要です。本プロジェクトでは独立したGPUライブラリーのみをビルドし、自作PCIフロントエンドから接続しています。QEMU用フロントエンドは使用していません。

参考資料：

- [Microsoft：Windows Hypervisor Platform](https://learn.microsoft.com/en-us/virtualization/api/hypervisor-platform/hypervisor-platform)
- [Microsoft：SwapChainPanelのDirectX連携](https://learn.microsoft.com/en-us/windows/windows-app-sdk/api/win32/microsoft.ui.xaml.media.dxinterop/nn-microsoft-ui-xaml-media-dxinterop-iswapchainpanelnative)
- [Apple：Metal GPU対応表](https://developer.apple.com/metal/capabilities/)
- [AMD：GPUアーキテクチャ・ISA資料](https://gpuopen.com/amd-gpu-architecture-programming-documentation/)
- [RaphaelGPU](https://github.com/icex/macos-raphael-igpu)
- [Reims vGPU C API](https://github.com/steelbrain/reims-vgpu/blob/master/docs/api.md)
- [Reims Windows開発ブランチの実装状況](https://github.com/tqmane/reims-vgpu/blob/windows-native-tahoe/docs/IMPLEMENTATION_STATUS.md)
- [Reims Windows開発ブランチの既知の問題](https://github.com/tqmane/reims-vgpu/blob/windows-native-tahoe/docs/KNOWN_ISSUES.md)

## 構成

`native/NativeMac.WHP/Engine.cpp`：WHPゲスト実行。`Gpu.cpp`：Direct3Dハードウェア描画。`src/TahoeVm`：WinUI 3アプリ。`scripts`：ビルド・検証。

依存ファイルの配置は[BUILDING.md](docs/BUILDING.md)、外部ソースの出典は[THIRD_PARTY.md](THIRD_PARTY.md)を参照してください。

FHDの3D検証では、LLVMビット反転・メモリアクセス処理と長い共有メモリ割り当て待ちを修正し、プロセス限定の互換層を使ったGravityMarkの描画・完走を確認しました。ヒープ作成・Mesh実行などの不足と検証の範囲は[GPU互換性一覧](docs/GPU_COMPATIBILITY.md)に記録しています。
