use metal2vulkan::metal::ResourceUsage;
use metal2vulkan_runtime::{
    CommandBufferStatus, Device, DeviceOptions, PipelineOptions, ResourceOptions, ResourceRef, Size,
};
use std::{
    error::Error,
    time::{Duration, Instant},
};

fn main() -> Result<(), Box<dyn Error>> {
    let path = std::env::args()
        .nth(1)
        .ok_or("pass the authored ResidentSearch.metallib")?;
    let d = Device::system_default_with(&DeviceOptions::default())?;
    let library = d.new_library_with_data(&std::fs::read(path)?)?;
    let f = library.new_function_with_name("resident_search")?;
    let started = Instant::now();
    let p = d.new_compute_pipeline_state_with_function(&f, &PipelineOptions::default())?;
    let creation_ms = started.elapsed().as_secs_f64() * 1000.;
    let q = d.new_command_queue()?;
    let n = 65536u32;
    let mut rows = Vec::new();
    for count in [1u32, 4, 16, 64, 256, 4096] {
        let mut buffers = Vec::new();
        for b in 0..count {
            let data: Vec<u8> = (0..256)
                .flat_map(|i: u32| ((b * 257 + i) ^ 0x5a5a5a5a).to_le_bytes())
                .collect();
            buffers.push(d.new_buffer_with_bytes(&data, ResourceOptions::shared())?);
        }
        let nodes: Vec<u8> = buffers
            .iter()
            .flat_map(|b| b.gpu_address().0.to_le_bytes())
            .collect();
        let nodes = d.new_buffer_with_bytes(&nodes, ResourceOptions::shared())?;
        let count_buffer =
            d.new_buffer_with_bytes(&count.to_le_bytes(), ResourceOptions::shared())?;
        let out = d.new_buffer(u64::from(n) * 4, ResourceOptions::shared())?;
        for round in 0..8 {
            let cb = q.command_buffer()?;
            let start = Instant::now();
            let mut e = cb.compute_command_encoder()?;
            e.set_compute_pipeline_state(&p)?;
            e.set_buffer(Some(&nodes), 0, 0)?;
            e.set_buffer(Some(&out), 0, 1)?;
            e.set_buffer(Some(&count_buffer), 0, 2)?;
            for b in &buffers {
                e.use_resource(ResourceRef::Buffer(b), ResourceUsage::READ)?;
            }
            e.dispatch_threads(Size::new(u64::from(n), 1, 1), Size::new(64, 1, 1))?;
            e.end_encoding()?;
            let encoded = start.elapsed().as_secs_f64() * 1000.;
            cb.commit()?;
            cb.wait_until_completed_for(Duration::from_secs(20))
                .map_err(|_| "GPU completion deadline")?;
            if cb.status() != CommandBufferStatus::Completed {
                return Err(format!("GPU command: {:?}", cb.error()).into());
            }
            let wall = start.elapsed().as_secs_f64() * 1000.;
            let gpu = match (cb.gpu_start_time(), cb.gpu_end_time()) {
                (Ok(a), Ok(b)) => Some((b - a) * 1000.),
                _ => None,
            };
            let pointer = out.contents().ok_or("shared output has no CPU address")?;
            // SAFETY: this owned shared buffer has n u32s and its command completed.
            let values =
                unsafe { std::slice::from_raw_parts(pointer.as_ptr().cast::<u32>(), n as usize) };
            for (i, &actual) in values.iter().enumerate() {
                let expected = (0..16u32).fold(0u32, |sum, j| {
                    let b = (i as u32 + j) & (count - 1);
                    let k = (i as u32 + j) & 255;
                    sum.wrapping_add((b * 257 + k) ^ 0x5a5a5a5a)
                });
                if actual != expected {
                    return Err(format!("count {count} index {i}: {actual} != {expected}").into());
                }
            }
            if round > 0 {
                rows.push(serde_json::json!({"buffers":count,"round":round,"values":n,"encodeMs":encoded,"wallMs":wall,"gpuMs":gpu,"verified":true}));
            }
        }
    }
    println!(
        "{}",
        serde_json::json!({"device":d.name(),"creationMs":creation_ms,"rows":rows,"verified":true})
    );
    Ok(())
}
