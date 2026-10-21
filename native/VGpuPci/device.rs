// NativeMac PCI frontend for the independent Reims C API. CPU execution remains WHP.
use anyhow::{Context, Result};
use chipset_device::{ChipsetDevice, io::{IoError, IoResult}, mmio::MmioIntercept,
    pci::{PciConfigSpace, ByteEnabledDwordRead, ByteEnabledDwordWrite}};
use inspect::InspectMut;
use mesh::MeshPayload;
use pci_core::{capabilities::{msi_cap::MsiCapability, pci_express::PciExpressCapability},
    cfg_space_emu::{BarMemoryKind, ConfigSpaceType0Emulator, DeviceBars},
    spec::{caps::pci_express::DevicePortType, hwid::{HardwareIds, ClassCode, Subclass, ProgrammingInterface}}};
use pci_resources::{ResolvePciDeviceHandleParams, ResolvedPciDevice};
use sparse_mmap::SparseMapping;
use std::{ffi::c_void, os::windows::io::AsRawHandle};
use vm_resource::{AsyncResolveResource, ResourceResolver, ResourceId,
    declare_static_async_resolver, kind::PciDeviceHandleKind};
use vmcore::{device_state::ChangeDeviceState, interrupt::Interrupt,
    save_restore::{SaveRestore, SavedStateNotSupported, SaveError, RestoreError}};

#[repr(C)] struct MemoryRange { address:u64, length:u64, host:*mut c_void }
#[repr(C)] struct MemoryMap { ranges:*const MemoryRange, count:usize }
#[repr(C)] struct MemorySection { handle:u64, offset:u64, length:u64, flags:u32, reserved:u32 }
#[repr(C)] struct Callbacks {
    size:u32, ctx:*mut c_void, destroy:usize, create_task:usize, destroy_task:usize,
    map_memory:usize, unmap_memory:usize, read_memory:usize,
    interrupt:Option<extern "C" fn(*mut c_void,u32)>, add_trace:usize, remove_trace:usize,
}
#[repr(C)] struct Config {
    size:u32, ports:u32, registry:u64, feature:u64, connection:u32,
    iosurface:bool, isolation:bool, disable_arguments:bool,
    map:*const MemoryMap, callbacks:*const Callbacks, files:*const c_void, sections:*const MemorySection,
}
#[repr(C)] struct WindowConfig { size:u32, flags:u32, callbacks:*const c_void, width:u16, height:u16, ppi:f64 }
#[repr(C)] struct WindowCallbacks {
    size:u32, ctx:*mut c_void, destroy:usize,
    pointer:Option<extern "C" fn(*mut c_void,u16,u16,u16,u16,u32)>,
    wheel:Option<extern "C" fn(*mut c_void,i32,i32)>, key:Option<extern "C" fn(*mut c_void,u16,bool)>, close:usize,
    scroll:usize, relative:usize,
}
#[repr(C)] struct DisplayConfig {
    size:u32, serial:u32, port:u64, name:*const u8, name_length:usize,
    width:f64, height:f64, callbacks:*const c_void, window:*const WindowConfig,
}
#[repr(C)] struct DisplayCallbacks {
    size:u32, ctx:*mut c_void, destroy:usize,
    mode:Option<extern "C" fn(*mut c_void,u16,u16,u32)>,
    frame:usize, glyph:usize, show:usize, moved:usize,
}
#[repr(C)] struct DisplayCoord {x:u16,y:u16}
#[repr(C)] struct FrameTargetConfig { size:u32, width:u32, height:u32, format:u32 }
const _: () = {
    assert!(std::mem::size_of::<Config>()==64);
    assert!(std::mem::size_of::<WindowConfig>()==32);
    assert!(std::mem::size_of::<WindowCallbacks>()==72);
    assert!(std::mem::size_of::<DisplayConfig>()==64);
    assert!(std::mem::size_of::<DisplayCallbacks>()==64);
    assert!(std::mem::size_of::<DisplayCoord>()==4);
};
type Create = unsafe extern "C" fn(*const Config,*mut *mut c_void)->u32;
type Release = unsafe extern "C" fn(*mut c_void);
type Read = unsafe extern "C" fn(*mut c_void,u64)->u32;
type Write = unsafe extern "C" fn(*mut c_void,u64,u32);

fn display_resolution(value:Option<&str>)->Result<(u16,u16)> {
    match value.unwrap_or("1920x1080") {
        "1920x1080"=>Ok((1920,1080)),
        "2560x1440"=>Ok((2560,1440)),
        "3840x2160"=>Ok((3840,2160)),
        value=>anyhow::bail!("unsupported NativeMac display resolution: {value}"),
    }
}

struct Runtime {
    device:*mut c_void, display:*mut c_void,
    release:Release, display_release:Release, reset:Release, read:Read, write:Write,
    _library:libloading::Library, _interrupt:Box<Interrupt>, _views:Vec<SparseMapping>,
    _memory:guestmem::GuestMemory,
    _input:Box<WindowInput>,
    log_level:u32,
    regions:Vec<guestmem::ShareableRegion>,
}
// The C API serializes device state and supports calls from host/device threads.
// Our MMIO accesses are serialized by the OpenVMM device lock. Mappings and the
// callback context remain alive until release has joined all library threads.
unsafe impl Send for Runtime {}
impl Drop for Runtime {
    fn drop(&mut self) { unsafe {
        if !self.display.is_null() { (self.display_release)(self.display); }
        (self.release)(self.device);
    } }
}
extern "C" fn raise(ctx:*mut c_void, vector:u32) {
    if vector != 0 { tracing::error!(vector,"unexpected Reims MSI vector"); return; }
    // The box lives until rvg_device_release has joined every callback.
    unsafe { (&*ctx.cast::<Interrupt>()).deliver(); }
}
extern "C" fn log(_ctx:*mut c_void, level:u32, target:*const u8, nt:usize, message:*const u8, nm:usize) {
    // The C API lends valid UTF-8 byte ranges for the duration of this call.
    unsafe {
        let target=String::from_utf8_lossy(std::slice::from_raw_parts(target,nt));
        let message=String::from_utf8_lossy(std::slice::from_raw_parts(message,nm));
        tracing::info!(level, module=%target, message=%message,"Reims");
    }
}
impl Runtime {
    fn capture(&self)->Result<String> {
        unsafe {
            type TargetCreate=unsafe extern "C" fn(*mut c_void,*const FrameTargetConfig,*mut *mut c_void)->u32;
            type Encode=unsafe extern "C" fn(*mut c_void,*mut c_void,*const c_void,*mut *mut c_void)->u32;
            type FrameOperation=unsafe extern "C" fn(*mut c_void)->u32;
            type ReadPixels=unsafe extern "C" fn(*mut c_void,*mut c_void,usize,usize)->u32;
            let create:TargetCreate=*self._library.get(b"rvg_frame_target_create\0")?;
            let encode:Encode=*self._library.get(b"rvg_display_encode_frame\0")?;
            let commit:FrameOperation=*self._library.get(b"rvg_frame_commit\0")?;
            let wait:FrameOperation=*self._library.get(b"rvg_frame_wait\0")?;
            let read:ReadPixels=*self._library.get(b"rvg_frame_target_read_pixels\0")?;
            let target_release:Release=*self._library.get(b"rvg_frame_target_release\0")?;
            let frame_release:Release=*self._library.get(b"rvg_frame_release\0")?;
            let config=FrameTargetConfig{size:16,width:1280,height:800,format:80};
            let mut target=std::ptr::null_mut();
            anyhow::ensure!(create(self.device,&config,&mut target)==0,"GPU capture target creation failed");
            let result=(||->Result<()> {
                let mut frame=std::ptr::null_mut();
                anyhow::ensure!(encode(self.display,target,std::ptr::null(),&mut frame)==0,"GPU frame encode failed");
                let status=commit(frame);
                let completed=if status==0 {wait(frame)} else {status};
                frame_release(frame);
                anyhow::ensure!(completed==0,"GPU frame failed: {completed}");
                let mut pixels=vec![0u8;1280*800*4];
                anyhow::ensure!(read(target,pixels.as_mut_ptr().cast(),1280*4,pixels.len())==0,"GPU readback failed");
                std::fs::create_dir_all("artifacts")?;
                std::fs::write("artifacts/gpu-frame.bgra",pixels)?;
                Ok(())
            })();
            target_release(target);
            result?;
            Ok("artifacts/gpu-frame.bgra (1280x800 BGRA8, GPU-rendered readback)".into())
        }
    }
    async fn new(path:&std::path::Path, memory:guestmem::GuestMemory, interrupt:Interrupt,
        input:mesh::Sender<input_core::InputData>)->Result<Self> {
        let sharing=memory.sharing().context("GPU requires shared section-backed guest memory")?;
        let regions=sharing.get_regions().await.map_err(|e|anyhow::anyhow!("guest memory sharing: {e}"))?;
        let mut views=Vec::new(); let mut ranges=Vec::new(); let mut sections=Vec::new();
        for region in &regions {
            let length=usize::try_from(region.size)?;
            let view=SparseMapping::new(length)?;
            view.map_file(0,length,region.file.as_ref(),region.file_offset,true)?;
            ranges.push(MemoryRange{address:region.guest_address,length:region.size,host:view.as_ptr().cast()});
            sections.push(MemorySection{handle:region.file.as_raw_handle() as u64,
                offset:region.file_offset,length:region.file_offset.checked_add(region.size).context("section range overflow")?,flags:0,reserved:0});
            views.push(view);
        }
        anyhow::ensure!(!ranges.is_empty(),"no shareable RAM ranges");
        let mut interrupt=Box::new(interrupt);
        let callbacks=Callbacks{size:std::mem::size_of::<Callbacks>() as u32,
            ctx:(&mut *interrupt as *mut Interrupt).cast(),destroy:0,create_task:0,destroy_task:0,
            map_memory:0,unmap_memory:0,read_memory:0,interrupt:Some(raise),add_trace:0,remove_trace:0};
        let map=MemoryMap{ranges:ranges.as_ptr(),count:ranges.len()};
        let config=Config{size:std::mem::size_of::<Config>() as u32,ports:1,registry:0,feature:4,connection:0,
            iosurface:false,isolation:false,disable_arguments:false,map:&map,callbacks:&callbacks,
            files:std::ptr::null(),sections:sections.as_ptr()};
        // Load only the caller-selected absolute DLL; no QEMU frontend is linked.
        unsafe {
            let library=libloading::Library::new(path)?;
            let logger:*const ()=log as *const ();
            let set_log:libloading::Symbol<unsafe extern "C" fn(*const (),*mut c_void,u32)>=library.get(b"rvg_log_set_handler\0")?;
            set_log(logger,std::ptr::null_mut(),3);
            let create:Create=*library.get(b"rvg_device_create\0")?;
            let release:Release=*library.get(b"rvg_device_release\0")?;
            let display_release:Release=*library.get(b"rvg_display_release\0")?;
            let reset:Release=*library.get(b"rvg_device_reset\0")?;
            let read:Read=*library.get(b"rvg_device_mmio_read\0")?;
            let write:Write=*library.get(b"rvg_device_mmio_write\0")?;
            let mut device=std::ptr::null_mut();
            let status=create(&config,&mut device);
            anyhow::ensure!(status==0,"rvg_device_create status {status}");
            let mut runtime=Self{device,display:std::ptr::null_mut(),release,display_release,reset,read,write,
                _library:library,_interrupt:interrupt,_views:views,_memory:memory,regions,
                _input:Box::new(WindowInput::new(input)?),log_level:3};
            let create_display:libloading::Symbol<unsafe extern "C" fn(*mut c_void,*const DisplayConfig,*mut *mut c_void)->u32>=runtime._library.get(b"rvg_display_create\0")?;
            let window_callbacks=WindowCallbacks{size:std::mem::size_of::<WindowCallbacks>() as u32,
                ctx:(&mut *runtime._input as *mut WindowInput).cast(),
                destroy:0,pointer:Some(pointer),wheel:Some(wheel),key:Some(key),close:0,scroll:0,relative:0};
            let resolution=std::env::var("NATIVEMAC_DISPLAY_RESOLUTION").ok();
            let (width,height)=display_resolution(resolution.as_deref())?;
            let window=WindowConfig{size:std::mem::size_of::<WindowConfig>() as u32,flags:1,
                callbacks:(&window_callbacks as *const WindowCallbacks).cast(),width,height,ppi:110.0};
            let display_callbacks=DisplayCallbacks{size:std::mem::size_of::<DisplayCallbacks>() as u32,
                ctx:Box::into_raw(Box::new(runtime._input.display_mode.clone())).cast(),
                destroy:release_mode_context as *const () as usize,
                mode:Some(mode_changed),frame:0,glyph:0,show:0,moved:0};
            let name=b"NativeMac WHP";
            let config=DisplayConfig{size:std::mem::size_of::<DisplayConfig>() as u32,serial:1,port:0,
                name:name.as_ptr(),name_length:name.len(),width:295.0,height:185.0,
                callbacks:(&display_callbacks as *const DisplayCallbacks).cast(),window:&window};
            let status=create_display(device,&config,&mut runtime.display);
            anyhow::ensure!(status==0,"rvg_display_create status {status}");
            tracing::info!(ranges=ranges.len(),"Reims Vulkan PCI GPU initialized");
            Ok(runtime)
        }
    }
}

struct CaptureAction<'a>(&'a Runtime);
struct LogLevelAction<'a>(&'a mut Runtime);
impl InspectMut for LogLevelAction<'_> {
    fn inspect_mut(&mut self,req:inspect::Request<'_>) {
        match req.update() {
            Ok(update)=>{
                let result=(||->Result<u32> {
                    let level=update.new_value().parse::<u32>()?;
                    anyhow::ensure!(level<=5,"log level must be 0..5");
                    unsafe {
                        let set:libloading::Symbol<unsafe extern "C" fn(*const (),*mut c_void,u32)>=self.0._library.get(b"rvg_log_set_handler\0")?;
                        set(log as *const (),std::ptr::null_mut(),level);
                    }
                    self.0.log_level=level;Ok(level)
                })();
                match result {Ok(level)=>update.succeed(level),Err(error)=>update.fail(std::io::Error::other(error.to_string()))}
            },
            Err(req)=>req.value(self.0.log_level),
        }
    }
}
impl InspectMut for CaptureAction<'_> {
    fn inspect_mut(&mut self,req:inspect::Request<'_>) {
        match req.update() {
            Ok(update)=>match self.0.capture() {
                Ok(path)=>update.succeed(path),Err(error)=>update.fail(std::io::Error::other(error.to_string())),
            },
            Err(req)=>req.value("Set to 1 to capture the display through its GPU frame API"),
        }
    }
}
impl InspectMut for Runtime {
    fn inspect_mut(&mut self,req:inspect::Request<'_>) {
        let (mut guest,mut host)=(0u64,0u64);
        unsafe {
            if let Ok(counts)=self._library.get::<unsafe extern "C" fn(*mut c_void,*mut u64,*mut u64)>(b"rvg_display_present_counts\0") {
                counts(self.display,&mut guest,&mut host);
            }
        }
        let mode=self._input.display_mode.load(std::sync::atomic::Ordering::Relaxed);
        let mut cursor=DisplayCoord{x:65535,y:65535};
        unsafe {
            if let Ok(position)=self._library.get::<unsafe extern "C" fn(*mut c_void)->DisplayCoord>(b"rvg_display_cursor_position\0") {
                cursor=position(self.display);
            }
        }
        req.respond().field("guest_presents",guest).field("host_presents",host)
            .field("efi_enabled",unsafe{(self.read)(self.device,0x1200)})
            .field("binary_version",unsafe{(self.read)(self.device,0x1034)})
            .field("display_width",mode as u16).field("display_height",(mode>>16) as u16)
            .field("guest_cursor_x",cursor.x).field("guest_cursor_y",cursor.y)
            .field("pointer_events_received",self._input.motion.received.load(std::sync::atomic::Ordering::Relaxed))
            .field("pointer_reports_sent",self._input.motion.sent.load(std::sync::atomic::Ordering::Relaxed))
            .field_mut("capture",&mut CaptureAction(self))
            .field_mut("log_level",&mut LogLevelAction(self));
    }
}

#[derive(Default)]
struct MotionBuffer {
    pending:Option<input_core::MouseData>,
    buttons:u8,
}
impl MotionBuffer {
    fn push(&mut self,data:input_core::MouseData)->Vec<input_core::MouseData> {
        let mut immediate=Vec::new();
        if data.button_mask != self.buttons {
            // Preserve the final held-button position before an up, and every down/up.
            if let Some(pending)=self.pending.take() {immediate.push(pending);}
            immediate.push(data);
            self.buttons=data.button_mask;
        } else {self.pending=Some(data);}
        immediate
    }
}
struct MotionQueue {
    buffer:std::sync::Mutex<MotionBuffer>,
    send:mesh::Sender<input_core::InputData>,
    stop:std::sync::atomic::AtomicBool,
    received:std::sync::atomic::AtomicU64,
    sent:std::sync::atomic::AtomicU64,
}
impl MotionQueue {
    fn send(&self,data:input_core::MouseData) {
        self.sent.fetch_add(1,std::sync::atomic::Ordering::Relaxed);
        self.send.send(input_core::InputData::Mouse(data));
    }
}
struct WindowInput {
    send:mesh::Sender<input_core::InputData>,
    mouse:std::sync::atomic::AtomicU64,
    display_mode:std::sync::Arc<std::sync::atomic::AtomicU32>,
    motion:std::sync::Arc<MotionQueue>,
    worker:Option<std::thread::JoinHandle<()>>,
}
impl WindowInput {
    fn new(send:mesh::Sender<input_core::InputData>)->Result<Self> {
        let motion=std::sync::Arc::new(MotionQueue {
            buffer:std::sync::Mutex::new(MotionBuffer::default()),send:send.clone(),
            stop:std::sync::atomic::AtomicBool::new(false),
            received:std::sync::atomic::AtomicU64::new(0),sent:std::sync::atomic::AtomicU64::new(0),
        });
        let queue=motion.clone();
        let worker=std::thread::Builder::new().name("nativemac-mouse".into()).spawn(move || {
            while !queue.stop.load(std::sync::atomic::Ordering::Acquire) {
                {
                    let mut buffer=queue.buffer.lock().unwrap_or_else(|e|e.into_inner());
                    if let Some(data)=buffer.pending.take() {queue.send(data);}
                }
                std::thread::park_timeout(std::time::Duration::from_millis(8));
            }
        })?;
        Ok(Self{send,mouse:std::sync::atomic::AtomicU64::new(0),
            display_mode:std::sync::Arc::new(std::sync::atomic::AtomicU32::new(0)),motion,worker:Some(worker)})
    }
}
extern "C" fn mode_changed(ctx:*mut c_void,width:u16,height:u16,format:u32) {
    unsafe {(&*ctx.cast::<std::sync::Arc<std::sync::atomic::AtomicU32>>()).store(
        u32::from(width)|(u32::from(height)<<16),std::sync::atomic::Ordering::Relaxed);}
    tracing::info!(width,height,format,"guest display mode changed");
}
extern "C" fn release_mode_context(ctx:*mut c_void) {
    unsafe {drop(Box::from_raw(ctx.cast::<std::sync::Arc<std::sync::atomic::AtomicU32>>()));}
}
impl Drop for WindowInput {
    fn drop(&mut self) {
        self.motion.stop.store(true,std::sync::atomic::Ordering::Release);
        if let Some(worker)=self.worker.take() {worker.thread().unpark();let _=worker.join();}
    }
}
// USB HID keyboard usages from the window to Hyper-V's AT set-1 codes.
fn scan_code(usage:u16)->Option<u16> {
    const LETTERS:[u16;26]=[0x1e,0x30,0x2e,0x20,0x12,0x21,0x22,0x23,0x17,0x24,0x25,0x26,0x32,0x31,0x18,0x19,0x10,0x13,0x1f,0x14,0x16,0x2f,0x11,0x2d,0x15,0x2c];
    Some(match usage {
        4..=29=>LETTERS[usize::from(usage-4)], 30..=39=>usage-28,
        40=>0x1c,41=>1,42=>0x0e,43=>0x0f,44=>0x39,45=>0x0c,46=>0x0d,
        47=>0x1a,48=>0x1b,49=>0x2b,50=>0x2b,51=>0x27,52=>0x28,53=>0x29,
        54=>0x33,55=>0x34,56=>0x35,57=>0x3a,58..=67=>usage+1,68=>0x57,69=>0x58,
        70=>0xe037,71=>0x46,73=>0xe052,74=>0xe047,75=>0xe049,76=>0xe053,
        77=>0xe04f,78=>0xe051,79=>0xe04d,80=>0xe04b,81=>0xe050,82=>0xe048,
        83=>0x45,84=>0xe035,85=>0x37,86=>0x4a,87=>0x4e,88=>0xe01c,
        89=>0x4f,90=>0x50,91=>0x51,92=>0x4b,93=>0x4c,94=>0x4d,
        95=>0x47,96=>0x48,97=>0x49,98=>0x52,99=>0x53,100=>0x56,101=>0xe05d,
        135=>0x73,136=>0x70,137=>0x7d,138=>0x79,139=>0x7b,
        224=>0x1d,225=>0x2a,226=>0x38,227=>0xe05b,
        228=>0xe01d,229=>0x36,230=>0xe038,231=>0xe05c,
        _=>return None,
    })
}
extern "C" fn key(ctx:*mut c_void,usage:u16,down:bool) {
    if let Some(code)=scan_code(usage) { unsafe {
        (&*ctx.cast::<WindowInput>()).send.send(input_core::InputData::Keyboard(
            input_core::KeyboardData{code,make:down}));
    } }
}
fn axis(value:u16,size:u16)->u16 {
    ((u32::from(value.min(size.saturating_sub(1)))*32767)/u32::from(size.max(1))) as u16
}
fn read_words(offset:u64,data:&mut [u8],mut read:impl FnMut(u64)->u32) {
    for (index,word) in data.chunks_exact_mut(4).enumerate() {
        word.copy_from_slice(&read(offset+index as u64*4).to_le_bytes());
    }
}
fn write_words(offset:u64,data:&[u8],mut write:impl FnMut(u64,u32)) {
    for (index,word) in data.chunks_exact(4).enumerate() {
        write(offset+index as u64*4,u32::from_le_bytes(word.try_into().unwrap()));
    }
}
extern "C" fn pointer(ctx:*mut c_void,x:u16,y:u16,width:u16,height:u16,buttons:u32) {
    let x=axis(x,width);let y=axis(y,height);
    // OpenVMM/RFB uses left, middle, right; Reims uses left, right, middle.
    let button_mask=((buttons&1)|((buttons&2)<<1)|((buttons&4)>>1)) as u8;
    unsafe { let input=&*ctx.cast::<WindowInput>();
        input.mouse.store(u64::from(x)|(u64::from(y)<<16)|(u64::from(button_mask)<<32),std::sync::atomic::Ordering::Relaxed);
        input.motion.received.fetch_add(1,std::sync::atomic::Ordering::Relaxed);
        let mut buffer=input.motion.buffer.lock().unwrap_or_else(|e|e.into_inner());
        for event in buffer.push(input_core::MouseData{button_mask,x,y}) {input.motion.send(event);}
    }
}
extern "C" fn wheel(ctx:*mut c_void,dy:i32,_dx:i32) {
    if dy==0 {return;}
    unsafe { let input=&*ctx.cast::<WindowInput>();
        let mut buffer=input.motion.buffer.lock().unwrap_or_else(|e|e.into_inner());
        if let Some(data)=buffer.pending.take() {input.motion.send(data);}
        let mouse=input.mouse.load(std::sync::atomic::Ordering::Relaxed);
        let mut data=input_core::MouseData{x:mouse as u16,y:(mouse>>16) as u16,button_mask:(mouse>>32) as u8};
        let held=data.button_mask;
        for _ in 0..dy.unsigned_abs().min(32) {
            data.button_mask=held|if dy>0 {8} else {16};
            input.motion.send(data);
            data.button_mask=held;
            input.motion.send(data);
        }
    }
}

#[cfg(test)] mod tests {
    #[test] fn resolution_caps_are_bounded_and_reject_unknown_modes() {
        assert_eq!(super::display_resolution(None).unwrap(),(1920,1080));
        assert_eq!(super::display_resolution(Some("2560x1440")).unwrap(),(2560,1440));
        assert_eq!(super::display_resolution(Some("3840x2160")).unwrap(),(3840,2160));
        for invalid in ["0x0","7680x4320","3840x2161","3840X2160",""] {
            assert!(super::display_resolution(Some(invalid)).is_err());
        }
    }
    use super::*;
    #[test] fn continuous_motion_keeps_only_the_newest_position() {
        let mut buffer=MotionBuffer::default();
        for x in 0..1000 {assert!(buffer.push(input_core::MouseData{x,y:100,button_mask:0}).is_empty());}
        assert_eq!(buffer.pending.take().unwrap().x,999);
    }
    #[test] fn dragging_preserves_button_edges_and_final_position() {
        let mut buffer=MotionBuffer::default();
        let down=buffer.push(input_core::MouseData{x:10,y:10,button_mask:1});
        assert_eq!(down.len(),1);assert_eq!(down[0].button_mask,1);
        for x in 11..1000 {assert!(buffer.push(input_core::MouseData{x,y:10,button_mask:1}).is_empty());}
        let up=buffer.push(input_core::MouseData{x:1000,y:10,button_mask:0});
        assert_eq!(up.len(),2);
        assert_eq!((up[0].x,up[0].button_mask),(999,1));
        assert_eq!((up[1].x,up[1].button_mask),(1000,0));
        assert!(buffer.pending.is_none());
    }
    #[test] fn keyboard_preserves_extended_modifiers() {
        assert_eq!(scan_code(4),Some(0x1e));
        assert_eq!(scan_code(39),Some(0x0b));
        assert_eq!(scan_code(227),Some(0xe05b));
        assert_eq!(scan_code(228),Some(0xe01d));
        assert_eq!(scan_code(79),Some(0xe04d));
        assert_eq!(scan_code(0xffff),None);
    }
    #[test] fn pointer_scales_and_clamps_guest_pixels() {
        assert_eq!(axis(640,1280),16383);
        assert_eq!(axis(0,0),0);
        assert!(axis(u16::MAX,800)<32767);
    }
    #[test] fn qword_mmio_preserves_both_registers_and_byte_order() {
        let mut writes=Vec::new();
        write_words(0x1100,&0x123456789abcdef0u64.to_le_bytes(),|offset,value|writes.push((offset,value)));
        assert_eq!(writes,[(0x1100,0x9abcdef0),(0x1104,0x12345678)]);
        let mut bytes=[0u8;8];
        read_words(0x1100,&mut bytes,|offset|writes.iter().find(|v|v.0==offset).unwrap().1);
        assert_eq!(u64::from_le_bytes(bytes),0x123456789abcdef0);
    }
}

#[derive(InspectMut)]
pub struct Device {
    cfg_space:ConfigSpaceType0Emulator,
    #[inspect(flatten, mut)] runtime:Runtime,
    #[inspect(hex)] efi_start:u64,
    efi_length:u32,
    #[inspect(skip)] mapped_framebuffer:Option<(u64,u32)>,
    #[inspect(skip)] framebuffer:std::sync::Arc<dyn guestmem::MappedMemoryRegion>,
}
impl Device {
    fn map_framebuffer(&mut self) {
        if self.efi_length==0 { return; }
        if self.mapped_framebuffer==Some((self.efi_start,self.efi_length)) {return;}
        let length=u64::from(self.efi_length);
        if length>64*1024*1024 { tracing::error!(length,"invalid EFI framebuffer length");return; }
        let Some(end)=self.efi_start.checked_add(length) else {return;};
        for region in &self.runtime.regions {
            if self.efi_start>=region.guest_address && end<=region.guest_address+region.size {
                let offset=region.file_offset+self.efi_start-region.guest_address;
                if let Err(error)=self.framebuffer.unmap(0,64*1024*1024) {
                    tracing::error!(%error,"could not remove old EFI framebuffer mapping");return;
                }
                self.mapped_framebuffer=None;
                match self.framebuffer.map(0,region.file.as_ref(),offset,length as usize,true) {
                    Ok(())=>{self.mapped_framebuffer=Some((self.efi_start,self.efi_length));
                        tracing::info!(start=self.efi_start,length,"EFI framebuffer mapped as shared RAM");},
                    Err(error)=>tracing::error!(%error,offset,length,"EFI framebuffer mapping failed"),
                }
                return;
            }
        }
        tracing::error!(start=self.efi_start,length,"EFI framebuffer is outside guest RAM");
    }
}
impl ChipsetDevice for Device {
    fn supports_mmio(&mut self)->Option<&mut dyn MmioIntercept>{Some(self)}
    fn supports_pci(&mut self)->Option<&mut dyn PciConfigSpace>{Some(self)}
}
impl MmioIntercept for Device {
    fn mmio_read(&mut self,addr:u64,data:&mut[u8])->IoResult {
        if let Some((2,offset))=self.cfg_space.find_bar(addr) {
            return match self.runtime._memory.read_at(self.efi_start+offset,data) {
                Ok(())=>IoResult::Ok,Err(_)=>IoResult::Err(IoError::InvalidRegister)
            };
        }
        if !matches!(data.len(),4|8|16) || addr%4!=0 { return IoResult::Err(IoError::InvalidAccessSize); }
        let Some((0,offset))=self.cfg_space.find_bar(addr) else {return IoResult::Err(IoError::InvalidRegister)};
        if offset+data.len() as u64>16384 {return IoResult::Err(IoError::InvalidRegister);}
        read_words(offset,data,|offset|unsafe{(self.runtime.read)(self.runtime.device,offset)});
        IoResult::Ok
    }
    fn mmio_write(&mut self,addr:u64,data:&[u8])->IoResult {
        if let Some((2,offset))=self.cfg_space.find_bar(addr) {
            return match self.runtime._memory.write_at(self.efi_start+offset,data) {
                Ok(())=>IoResult::Ok,Err(_)=>IoResult::Err(IoError::InvalidRegister)
            };
        }
        if !matches!(data.len(),4|8|16) || addr%4!=0 { return IoResult::Err(IoError::InvalidAccessSize); }
        let Some((0,offset))=self.cfg_space.find_bar(addr) else {return IoResult::Err(IoError::InvalidRegister)};
        if offset+data.len() as u64>16384 {return IoResult::Err(IoError::InvalidRegister);}
        write_words(offset,data,|offset,value| {
            if offset==0x1210 { self.efi_start=u64::from(value)<<12; }
            if offset==0x1214 { self.efi_length=value; }
            if offset==0x1210 || offset==0x1214 { self.map_framebuffer(); }
            unsafe{(self.runtime.write)(self.runtime.device,offset,value);}
        });
        IoResult::Ok
    }
}
impl PciConfigSpace for Device {
    fn pci_cfg_read(&mut self,offset:u16,value:ByteEnabledDwordRead<'_>)->IoResult{self.cfg_space.read_byte_enabled(offset,value)}
    fn pci_cfg_write(&mut self,offset:u16,value:ByteEnabledDwordWrite)->IoResult{self.cfg_space.write_byte_enabled(offset,value)}
}
impl ChangeDeviceState for Device {
    fn start(&mut self){}
    async fn stop(&mut self){}
    async fn reset(&mut self){
        unsafe{(self.runtime.reset)(self.runtime.device);}
        self.cfg_space.reset();
        if let Err(error)=self.framebuffer.unmap(0,64*1024*1024) {
            tracing::error!(%error,"EFI framebuffer reset failed");
        }
        self.efi_start=0;self.efi_length=0;self.mapped_framebuffer=None;
    }
}
impl SaveRestore for Device {
    type SavedState=SavedStateNotSupported;
    fn save(&mut self)->std::result::Result<Self::SavedState,SaveError>{Err(SaveError::NotSupported)}
    fn restore(&mut self,state:Self::SavedState)->std::result::Result<(),RestoreError>{match state{}}
}
#[derive(MeshPayload)]
pub struct Handle { pub library:String, pub input:mesh::Sender<input_core::InputData> }
impl ResourceId<PciDeviceHandleKind> for Handle {const ID:&'static str="nativemac_reims_vgpu";}
pub struct Resolver;
declare_static_async_resolver!(Resolver,(PciDeviceHandleKind,Handle));
#[derive(Debug,thiserror::Error)]
#[error("Reims GPU initialization failed: {0:#}")]
pub struct Error(anyhow::Error);
#[async_trait::async_trait]
impl AsyncResolveResource<PciDeviceHandleKind,Handle> for Resolver {
    type Output=ResolvedPciDevice; type Error=Error;
    async fn resolve(&self,_resolver:&ResourceResolver,resource:Handle,input:ResolvePciDeviceHandleParams<'_>)->std::result::Result<Self::Output,Self::Error>{
        async {
            let msi=MsiCapability::new(0,true,false,input.dma_target.msi_target());
            let runtime=Runtime::new(std::path::Path::new(&resource.library),input.dma_target.guest_memory().clone(),msi.interrupt().context("MSI interrupt")?,resource.input).await?;
            let (framebuffer_control,framebuffer)=input.shared_mem_mapper.context("GPU requires a shared memory mapper")?
                .new_region(64*1024*1024,"reims-boot-framebuffer".into())?;
            let bars=DeviceBars::new().bar0(16384,BarMemoryKind::Intercept(input.register_mmio.new_io_region("reims-mmio",16384)))
                .bar2(64*1024*1024,BarMemoryKind::SharedMem(framebuffer_control)).below_4gb();
            let cfg_space=ConfigSpaceType0Emulator::new(HardwareIds{vendor_id:0x106b,device_id:0xeeee,revision_id:0,
                prog_if:ProgrammingInterface(0),sub_class:Subclass(2),base_class:ClassCode::DISPLAY_CONTROLLER,
                type0_sub_vendor_id:0,type0_sub_system_id:0},vec![Box::new(msi),Box::new(PciExpressCapability::new(DevicePortType::Endpoint,None))],Vec::new(),bars);
            Ok(Device{cfg_space,runtime,efi_start:0,efi_length:0,mapped_framebuffer:None,framebuffer}.into())
        }.await.map_err(Error)
    }
}
