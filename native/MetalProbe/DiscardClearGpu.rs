// Authored Windows GPU path/visibility check. Input is LLVM bitcode assembled
// from metal2vulkan's public engine/tob_renders.ll fixture, not a guest shader.
#[cfg(windows)]
fn main() -> Result<(), Box<dyn std::error::Error>> {
    use metal2vulkan::{
        metal::{PixelFormat, PrimitiveType, TextureUsage},
        pipeline::{ColorAttachmentDescriptor, RenderPipelineDescriptor, StageSource},
    };
    use metal2vulkan_runtime::{
        Device, DeviceKind, DeviceOptions, HostMemory, LoadAction, PipelineOptions,
        RenderPassDescriptor, ResourceOptions, ScissorRect, StoreAction, TextureDescriptor,
    };
    use std::{ffi::c_void, ptr::NonNull, time::Duration};
    #[link(name = "kernel32")]
    unsafe extern "system" {
        fn CreateFileMappingW(
            file: *mut c_void,
            security: *const c_void,
            protect: u32,
            high: u32,
            low: u32,
            name: *const u16,
        ) -> *mut c_void;
        fn MapViewOfFile(
            file: *mut c_void,
            access: u32,
            high: u32,
            low: u32,
            length: usize,
        ) -> *mut c_void;
        fn UnmapViewOfFile(address: *const c_void) -> i32;
        fn CloseHandle(handle: *mut c_void) -> i32;
    }
    struct Section {
        handle: *mut c_void,
        pointer: NonNull<u8>,
    }
    impl Drop for Section {
        fn drop(&mut self) {
            unsafe {
                UnmapViewOfFile(self.pointer.as_ptr().cast());
                CloseHandle(self.handle);
            }
        }
    }
    const W: u64 = 256;
    const H: u64 = 64;
    const N: usize = (W * H * 4) as usize;
    let mut mappings = Vec::new(); // Kept until after all device objects are dropped.
    let mut options = DeviceOptions::default();
    options.kinds = vec![DeviceKind::Discrete];
    let device = Device::system_default_with(&options)?;
    let path = std::env::args()
        .nth(1)
        .ok_or("pass assembled public tob_renders bitcode")?;
    let library = device.new_library_with_compile_library(metal2vulkan::library::Library::parse(
        &std::fs::read(path)?,
    )?);
    let v = library.new_function_with_name("tob_rect")?;
    let f = library.new_function_with_name("tob_solid")?;
    let mut descriptor =
        RenderPipelineDescriptor::new(StageSource::Function(v.function_descriptor()));
    descriptor.fragment = Some(StageSource::Function(f.function_descriptor()));
    descriptor.color_attachments[0] = Some(ColorAttachmentDescriptor::new(PixelFormat::BGRA8Unorm));
    let pipeline = device.new_render_pipeline_state(&descriptor, &PipelineOptions::default())?;
    let queue = device.new_command_queue()?;
    let floats = |v: [f32; 4]| v.into_iter().flat_map(f32::to_le_bytes).collect::<Vec<_>>();
    let corners =
        device.new_buffer_with_bytes(&floats([-1., -1., 1., 1.]), ResourceOptions::shared())?;
    let green =
        device.new_buffer_with_bytes(&floats([0., 1., 0., 1.]), ResourceOptions::shared())?;
    let mut rows = Vec::new();
    for (name, load, draw, partial, expected_ways) in [
        ("discard-full", LoadAction::DontCare, true, false, (0, 1)),
        ("discard-partial", LoadAction::DontCare, true, true, (0, 1)),
        (
            "discard-no-draw",
            LoadAction::DontCare,
            false,
            false,
            (1, 0),
        ),
        ("load-full", LoadAction::Load, true, false, (1, 0)),
        ("clear-full", LoadAction::Clear, true, false, (0, 1)),
    ] {
        // SAFETY: owned, page-aligned shared section; mappings outlive the device.
        let section = unsafe {
            let handle = CreateFileMappingW(
                -1isize as *mut c_void,
                std::ptr::null(),
                4,
                0,
                N as u32,
                std::ptr::null(),
            );
            if handle.is_null() {
                return Err(std::io::Error::last_os_error().into());
            }
            let Some(pointer) = NonNull::new(MapViewOfFile(handle, 6, 0, 0, N).cast::<u8>()) else {
                CloseHandle(handle);
                return Err(std::io::Error::last_os_error().into());
            };
            std::ptr::write_bytes(pointer.as_ptr(), 0x33, N);
            Section { handle, pointer }
        };
        let pointer = section.pointer;
        mappings.push(section);
        let buffer = unsafe {
            device.new_buffer_with_bytes_no_copy(
                HostMemory::new(pointer),
                N as u64,
                ResourceOptions::shared(),
                None,
            )
        }?;
        let mut td = TextureDescriptor::texture_2d(PixelFormat::BGRA8Unorm, W, H, false);
        td.usage = TextureUsage::RENDER_TARGET | TextureUsage::SHADER_READ;
        td.resource_options = ResourceOptions::shared();
        let texture = buffer.new_texture(&td, 0, W * 4)?;
        if unsafe { texture.vk_image() }.is_none() {
            return Err("host texture is shadowed; linear path not qualified".into());
        }
        let before = device.work_counts();
        let command = queue.command_buffer()?;
        let mut pass = RenderPassDescriptor::new();
        pass.color_attachments[0].texture = Some(texture.clone());
        pass.color_attachments[0].load_action = load;
        pass.color_attachments[0].store_action = StoreAction::Store;
        let mut e = command.render_command_encoder(&pass)?;
        if draw {
            e.set_render_pipeline_state(&pipeline)?;
            e.set_vertex_buffer(Some(&corners), 0, 0)?;
            e.set_fragment_buffer(Some(&green), 0, 0)?;
            if partial {
                e.set_scissor_rect(ScissorRect::new(32, 0, 64, 32))?;
            }
            e.draw_primitives(PrimitiveType::Triangle, 0, 6, 1, 0)?;
        }
        e.end_encoding()?;
        command.commit()?;
        if command
            .wait_until_completed_for(Duration::from_secs(20))
            .is_err()
        {
            eprintln!("GPU completion timeout");
            std::process::exit(124);
        }
        if command.error().is_some() {
            return Err(format!("GPU command: {:?}", command.error()).into());
        }
        let after = device.work_counts();
        let ways = (
            after.linear_passes_in_place - before.linear_passes_in_place,
            after.linear_passes_through_copies - before.linear_passes_through_copies,
        );
        let bytes = unsafe { std::slice::from_raw_parts(pointer.as_ptr(), N) };
        let mut different = 0;
        for (i, pixel) in bytes.chunks_exact(4).enumerate() {
            let (x, y) = (i as u64 % W, i as u64 / W);
            let written = draw && (!partial || ((32..96).contains(&x) && y < 32));
            let expected = if written { [0, 255, 0, 255] } else { [0x33; 4] };
            different += pixel
                .iter()
                .zip(expected)
                .filter(|(a, b)| **a != *b)
                .count();
        }
        rows.push(serde_json::json!({"case":name,"inPlace":ways.0,"throughCopies":ways.1,"expectedInPlace":expected_ways.0,"expectedCopies":expected_ways.1,"comparedBytes":N,"mismatchingBytes":different,"passed":ways==expected_ways&&different==0}));
        if partial {
            // CPU changes both an upcoming drawn pixel and an undrawn one after completion.
            // A reused device backing must reload the first and preserve the second.
            let inside = ((4 * W + 40) * 4) as usize;
            let outside = ((48 * W + 200) * 4) as usize;
            unsafe {
                std::ptr::copy_nonoverlapping(
                    [0, 0, 255, 255].as_ptr(),
                    pointer.as_ptr().add(inside),
                    4,
                );
                std::ptr::copy_nonoverlapping(
                    [255, 0, 0, 255].as_ptr(),
                    pointer.as_ptr().add(outside),
                    4,
                );
            }
            let before = device.work_counts();
            let again = queue.command_buffer()?;
            let mut e = again.render_command_encoder(&pass)?;
            e.set_render_pipeline_state(&pipeline)?;
            e.set_vertex_buffer(Some(&corners), 0, 0)?;
            e.set_fragment_buffer(Some(&green), 0, 0)?;
            e.set_scissor_rect(ScissorRect::new(32, 0, 64, 32))?;
            e.draw_primitives(PrimitiveType::Triangle, 0, 6, 1, 0)?;
            e.end_encoding()?;
            again.commit()?;
            if again
                .wait_until_completed_for(Duration::from_secs(20))
                .is_err()
            {
                std::process::exit(124);
            }
            if again.error().is_some() {
                return Err(format!("GPU reuse: {:?}", again.error()).into());
            }
            let after = device.work_counts();
            let bytes = unsafe { std::slice::from_raw_parts(pointer.as_ptr(), N) };
            let mut different = 0;
            for (i, pixel) in bytes.chunks_exact(4).enumerate() {
                let (x, y) = (i as u64 % W, i as u64 / W);
                let expected = if i * 4 == outside {
                    [255, 0, 0, 255]
                } else if (32..96).contains(&x) && y < 32 {
                    [0, 255, 0, 255]
                } else {
                    [0x33; 4]
                };
                different += pixel
                    .iter()
                    .zip(expected)
                    .filter(|(a, b)| **a != *b)
                    .count();
            }
            let reused = after.kept_backings_made - before.kept_backings_made == 0;
            let copies = after.linear_passes_through_copies - before.linear_passes_through_copies;
            rows.push(serde_json::json!({"case":"discard-reuse-after-cpu-writes","throughCopies":copies,"reusedBacking":reused,"comparedBytes":N,"mismatchingBytes":different,"passed":reused&&copies==1&&different==0}));
        }
    }
    let passed = rows.iter().all(|r| r["passed"] == true);
    println!(
        "{}",
        serde_json::json!({"device":device.name(),"rows":rows,"passed":passed})
    );
    if !passed {
        std::process::exit(5);
    }
    Ok(())
}

#[cfg(not(windows))]
fn main() {
    eprintln!("This section-backed host probe requires Windows.");
    std::process::exit(64);
}
