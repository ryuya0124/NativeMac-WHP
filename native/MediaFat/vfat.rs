// A read-only GPT/FAT32 view over original host files. No disk image is
// converted or materialized: only filesystem metadata is synthesized.
use std::collections::BTreeMap;
use std::fs::File;
use std::io::{self, Read, Seek, SeekFrom};

const SECTOR: u64 = 512;
const CLUSTER: u64 = 4096;
const PARTITION_LBA: u64 = 2048;
const MAGIC: &[u8; 8] = b"NMFAT01\n";

fn invalid(message: impl Into<String>) -> io::Error {
    io::Error::new(io::ErrorKind::InvalidData, message.into())
}
fn put16(bytes: &mut [u8], at: usize, value: u16) { bytes[at..at+2].copy_from_slice(&value.to_le_bytes()); }
fn put32(bytes: &mut [u8], at: usize, value: u32) { bytes[at..at+4].copy_from_slice(&value.to_le_bytes()); }
fn put64(bytes: &mut [u8], at: usize, value: u64) { bytes[at..at+8].copy_from_slice(&value.to_le_bytes()); }
fn crc32(bytes: &[u8]) -> u32 {
    let mut crc = !0u32;
    for &byte in bytes {
        crc ^= u32::from(byte);
        for _ in 0..8 { crc = (crc >> 1) ^ (0xEDB88320 & (0u32.wrapping_sub(crc & 1))); }
    }
    !crc
}

#[derive(Debug)]
struct Node {
    name: String,
    parent: usize,
    children: Vec<usize>,
    file: Option<File>,
    len: u64,
    first: u32,
    clusters: u32,
    directory: Vec<u8>,
}
impl Node {
    fn dir(name: String, parent: usize) -> Self {
        Self { name, parent, children: Vec::new(), file: None, len: 0, first: 0, clusters: 0, directory: Vec::new() }
    }
    fn is_dir(&self) -> bool { self.file.is_none() }
}

/// Immutable FAT metadata and open handles to the original, unchanged files.
#[derive(Debug)]
pub struct VirtualFatDisk {
    nodes: Vec<Node>,
    metadata: Vec<(u64, Vec<u8>)>,
    allocated: Vec<(u32, u32, usize)>,
    data_start: u64,
    size: u64,
}

impl VirtualFatDisk {
    /// Recognizes an NMFAT01 manifest. Ordinary disk files return None.
    pub fn try_open(file: &File) -> io::Result<Option<Self>> {
        let mut manifest = file.try_clone()?;
        manifest.seek(SeekFrom::Start(0))?;
        let mut prefix = [0u8; 8];
        if let Err(error) = manifest.read_exact(&mut prefix) {
            if error.kind() == io::ErrorKind::UnexpectedEof { return Ok(None); }
            return Err(error);
        }
        if &prefix != MAGIC { return Ok(None); }
        if file.metadata()?.len() > 4 * 1024 * 1024 { return Err(invalid("FAT manifest too large")); }
        let mut json = String::new();
        manifest.read_to_string(&mut json)?;
        let value: serde_json::Value = serde_json::from_str(&json).map_err(|e| invalid(e.to_string()))?;
        let files = value.get("files").and_then(|v| v.as_array()).ok_or_else(|| invalid("Missing files array"))?;
        if files.len() > 100_000 { return Err(invalid("Too many FAT files")); }
        let mut nodes = vec![Node::dir(String::new(), 0)];
        let mut paths = BTreeMap::new();
        paths.insert(String::new(), 0usize);
        for entry in files {
            let path = entry.get("path").and_then(|v| v.as_str()).ok_or_else(|| invalid("Missing virtual path"))?;
            let source = entry.get("source").and_then(|v| v.as_str()).ok_or_else(|| invalid("Missing source path"))?;
            let parts: Vec<_> = path.split('/').collect();
            if parts.is_empty() || parts.iter().any(|p| p.is_empty() || *p == "." || *p == ".." ||
                p.encode_utf16().count() > 255 || p.chars().any(|c| c < ' ' || "\\:*?\"<>|".contains(c))) {
                return Err(invalid("Invalid FAT path"));
            }
            let mut parent = 0;
            let mut key = String::new();
            for (depth, name) in parts.iter().enumerate() {
                if depth != 0 { key.push('/'); }
                key.push_str(&name.to_lowercase());
                let last = depth + 1 == parts.len();
                if let Some(&index) = paths.get(&key) {
                    if last || !nodes[index].is_dir() { return Err(invalid("Duplicate FAT path")); }
                    parent = index;
                    continue;
                }
                let mut node = Node::dir((*name).to_owned(), parent);
                if last {
                    let source_file = File::open(source)?;
                    let info = source_file.metadata()?;
                    if !info.is_file() || info.len() > u64::from(u32::MAX) {
                        return Err(invalid("FAT32 source must be a regular file smaller than 4 GiB"));
                    }
                    node.len = info.len();
                    node.file = Some(source_file);
                }
                let index = nodes.len();
                nodes.push(node);
                nodes[parent].children.push(index);
                paths.insert(key.clone(), index);
                parent = index;
            }
        }
        let mut next = 2u32;
        let mut allocated = Vec::new();
        for index in 0..nodes.len() {
            let bytes = if nodes[index].is_dir() {
                let mut entries = if index == 0 { 0 } else { 2 };
                for &child in &nodes[index].children {
                    entries += 1 + nodes[child].name.encode_utf16().count().div_ceil(13);
                }
                (entries + 1) as u64 * 32
            } else { nodes[index].len };
            let count = u32::try_from(bytes.div_ceil(CLUSTER)).map_err(|_| invalid("FAT allocation overflow"))?;
            if count != 0 {
                nodes[index].first = next;
                nodes[index].clusters = count;
                let end = next.checked_add(count).ok_or_else(|| invalid("FAT allocation overflow"))?;
                allocated.push((next, end, index));
                next = end;
            }
        }
        // FAT32 requires at least 65,525 clusters. Leave some genuinely free space.
        let cluster_count = next.saturating_add(256).max(65_536);
        if cluster_count > 16_777_216 { return Err(invalid("Virtual FAT exceeds 64 GiB")); }
        let fat_sectors = ((u64::from(cluster_count) + 2) * 4).div_ceil(SECTOR) as u32;
        let volume_sectors = 32 + u64::from(fat_sectors) * 2 + u64::from(cluster_count) * 8;
        let disk_sectors = PARTITION_LBA + volume_sectors + 33;
        let data_start = (PARTITION_LBA + 32 + u64::from(fat_sectors) * 2) * SECTOR;
        let mut fat = vec![0u8; fat_sectors as usize * 512];
        put32(&mut fat, 0, 0x0FFFFFF8); put32(&mut fat, 4, 0x0FFFFFFF);
        for node in &nodes {
            for c in node.first..node.first + node.clusters {
                put32(&mut fat, c as usize * 4, if c + 1 == node.first + node.clusters { 0x0FFFFFFF } else { c+1 });
            }
        }
        for index in 0..nodes.len() {
            if !nodes[index].is_dir() { continue; }
            let mut entries = Vec::new();
            if index != 0 {
                entries.extend(short_entry(*b".          ", true, nodes[index].first, 0));
                let parent = nodes[index].parent;
                entries.extend(short_entry(*b"..         ", true, if parent == 0 { 0 } else { nodes[parent].first }, 0));
            }
            for &child in &nodes[index].children {
                let node = &nodes[child];
                let mut alias = *b"           ";
                alias[..8].copy_from_slice(format!("F{child:07X}").as_bytes());
                if let Some((_, extension)) = node.name.rsplit_once('.') {
                    for (i, ch) in extension.chars().filter(|c| c.is_ascii_alphanumeric()).take(3).enumerate() {
                        alias[8+i] = ch.to_ascii_uppercase() as u8;
                    }
                }
                entries.extend(long_entries(&node.name, alias));
                entries.extend(short_entry(alias, node.is_dir(), node.first, node.len as u32));
            }
            entries.resize(nodes[index].clusters as usize * CLUSTER as usize, 0);
            nodes[index].directory = entries;
        }
        let mut boot = vec![0u8; 512];
        boot[..3].copy_from_slice(&[0xEB,0x58,0x90]); boot[3..11].copy_from_slice(b"NATIVMAC");
        put16(&mut boot,11,512); boot[13]=8; put16(&mut boot,14,32); boot[16]=2;
        boot[21]=0xF8; put16(&mut boot,24,63); put16(&mut boot,26,255);
        put32(&mut boot,28,PARTITION_LBA as u32); put32(&mut boot,32,volume_sectors as u32);
        put32(&mut boot,36,fat_sectors); put32(&mut boot,44,2); put16(&mut boot,48,1); put16(&mut boot,50,6);
        boot[64]=0x80; boot[66]=0x29; put32(&mut boot,67,0x4E4D4143);
        boot[71..82].copy_from_slice(b"NATIVEMAC  "); boot[82..90].copy_from_slice(b"FAT32   ");
        boot[510..].copy_from_slice(&[0x55,0xAA]);
        let mut fsinfo=vec![0u8;512]; put32(&mut fsinfo,0,0x41615252); put32(&mut fsinfo,484,0x61417272);
        put32(&mut fsinfo,488,0xFFFFFFFF); put32(&mut fsinfo,492,next); put32(&mut fsinfo,508,0xAA550000);
        let mut protective=vec![0u8;512]; protective[450]=0xEE; put32(&mut protective,454,1);
        put32(&mut protective,458,(disk_sectors-1).min(u64::from(u32::MAX)) as u32);
        protective[510..].copy_from_slice(&[0x55,0xAA]);
        let mut partitions=vec![0u8;16*1024];
        partitions[..16].copy_from_slice(&[0x28,0x73,0x2A,0xC1,0x1F,0xF8,0xD2,0x11,0xBA,0x4B,0x00,0xA0,0xC9,0x3E,0xC9,0x3B]);
        partitions[16..32].copy_from_slice(b"NMFATPARTITION01");
        put64(&mut partitions,32,PARTITION_LBA); put64(&mut partitions,40,PARTITION_LBA+volume_sectors-1);
        for (i,c) in "NativeMac Media".encode_utf16().enumerate() { put16(&mut partitions,56+i*2,c); }
        let entries_crc=crc32(&partitions);
        let primary=gpt_header(1,disk_sectors-1,2,disk_sectors,entries_crc);
        let backup=gpt_header(disk_sectors-1,1,disk_sectors-33,disk_sectors,entries_crc);
        let base=PARTITION_LBA*SECTOR;
        let fat_offset=base+32*SECTOR;
        let metadata=vec![
            (0,protective),(SECTOR,primary),(2*SECTOR,partitions.clone()),
            (base,boot.clone()),(base+SECTOR,fsinfo.clone()),(base+6*SECTOR,boot),(base+7*SECTOR,fsinfo),
            (fat_offset,fat.clone()),(fat_offset+u64::from(fat_sectors)*SECTOR,fat),
            ((disk_sectors-33)*SECTOR,partitions),((disk_sectors-1)*SECTOR,backup),
        ];
        Ok(Some(Self {nodes,metadata,allocated,data_start,size:disk_sectors*SECTOR}))
    }

    pub fn size_bytes(&self) -> u64 { self.size }
    /// Reads logical sectors using bounded, positional reads of source files.
    pub fn read_at(&self, bytes: &mut [u8], offset: u64) -> io::Result<()> {
        let end=offset.checked_add(bytes.len() as u64).ok_or_else(|| invalid("FAT read overflow"))?;
        if end>self.size { return Err(io::Error::new(io::ErrorKind::UnexpectedEof,"FAT read outside disk")); }
        bytes.fill(0);
        for (start, content) in &self.metadata {
            copy_intersection(bytes,offset,*start,content);
        }
        if end<=self.data_start { return Ok(()); }
        let begin=offset.max(self.data_start);
        let cluster=((begin-self.data_start)/CLUSTER)+2;
        let mut pos=self.allocated.partition_point(|&(_,end,_)| u64::from(end)<=cluster);
        while let Some(&(first,end_cluster,index))=self.allocated.get(pos) {
            let start=self.data_start+(u64::from(first)-2)*CLUSTER;
            if start>=end { break; }
            let node_end=self.data_start+(u64::from(end_cluster)-2)*CLUSTER;
            let node=&self.nodes[index];
            if node.is_dir() { copy_intersection(bytes,offset,start,&node.directory); }
            else {
                let lo=offset.max(start); let hi=end.min(node_end).min(start+node.len);
                if hi>lo {
                    let part=&mut bytes[(lo-offset) as usize..(hi-offset) as usize];
                    read_file_at(node.file.as_ref().ok_or_else(|| invalid("Missing file"))?,part,lo-start)?;
                }
            }
            pos+=1;
        }
        Ok(())
    }
}

fn copy_intersection(out: &mut [u8], offset: u64, start: u64, content: &[u8]) {
    let lo=offset.max(start); let hi=(offset+out.len() as u64).min(start+content.len() as u64);
    if hi>lo { out[(lo-offset) as usize..(hi-offset) as usize].copy_from_slice(&content[(lo-start) as usize..(hi-start) as usize]); }
}
fn read_file_at(file: &File, mut bytes: &mut [u8], mut offset: u64) -> io::Result<()> {
    while !bytes.is_empty() {
        #[cfg(windows)]
        let count={ use std::os::windows::fs::FileExt; file.seek_read(bytes,offset)? };
        #[cfg(unix)]
        let count={ use std::os::unix::fs::FileExt; file.read_at(bytes,offset)? };
        if count==0 { return Err(io::Error::new(io::ErrorKind::UnexpectedEof,"Source file became shorter")); }
        offset+=count as u64; bytes=&mut bytes[count..];
    }
    Ok(())
}
fn short_entry(alias: [u8;11], dir: bool, first: u32, len: u32) -> [u8;32] {
    let mut entry=[0u8;32]; entry[..11].copy_from_slice(&alias); entry[11]=if dir {0x10} else {0x20};
    put16(&mut entry,16,0x21); put16(&mut entry,18,0x21); put16(&mut entry,24,0x21);
    put16(&mut entry,20,(first>>16) as u16); put16(&mut entry,26,first as u16); put32(&mut entry,28,len);
    entry
}
fn long_entries(name: &str, alias: [u8;11]) -> Vec<u8> {
    let chars:Vec<_>=name.encode_utf16().collect(); let count=chars.len().div_ceil(13);
    let checksum=alias.iter().fold(0u8,|sum,&c| sum.rotate_right(1).wrapping_add(c));
    let positions=[1,3,5,7,9,14,16,18,20,22,24,28,30];
    let mut result=Vec::new();
    for seq in (1..=count).rev() {
        let mut entry=[0u8;32]; entry[0]=seq as u8 | if seq==count {0x40} else {0}; entry[11]=0x0F; entry[13]=checksum;
        for (i,&at) in positions.iter().enumerate() {
            let index=(seq-1)*13+i;
            put16(&mut entry,at,if index<chars.len() {chars[index]} else if index==chars.len() {0} else {0xFFFF});
        }
        result.extend(entry);
    }
    result
}
fn gpt_header(current: u64, other: u64, entries: u64, disk_sectors: u64, crc: u32) -> Vec<u8> {
    let mut bytes=vec![0u8;512]; bytes[..8].copy_from_slice(b"EFI PART"); put32(&mut bytes,8,0x10000); put32(&mut bytes,12,92);
    put64(&mut bytes,24,current); put64(&mut bytes,32,other); put64(&mut bytes,40,34); put64(&mut bytes,48,disk_sectors-34);
    bytes[56..72].copy_from_slice(b"NMFATDISKID00001"); put64(&mut bytes,72,entries); put32(&mut bytes,80,128);
    put32(&mut bytes,84,128); put32(&mut bytes,88,crc); let checksum=crc32(&bytes[..92]); put32(&mut bytes,16,checksum);
    bytes
}

#[cfg(test)]
mod tests {
    use super::*;
    struct View<'a> { disk:&'a VirtualFatDisk, pos:u64, base:u64 }
    impl std::io::Write for View<'_> {
        fn write(&mut self, _: &[u8])->io::Result<usize>{Err(io::Error::new(io::ErrorKind::PermissionDenied,"read-only virtual media"))}
        fn flush(&mut self)->io::Result<()>{Ok(())}
    }
    impl Read for View<'_> {
        fn read(&mut self,out:&mut [u8])->io::Result<usize>{
            self.disk.read_at(out,self.base+self.pos)?; self.pos+=out.len() as u64; Ok(out.len())
        }
    }
    impl Seek for View<'_> {
        fn seek(&mut self,from:SeekFrom)->io::Result<u64>{
            let next=match from {SeekFrom::Start(n)=>i128::from(n),SeekFrom::Current(n)=>i128::from(self.pos)+i128::from(n),SeekFrom::End(n)=>i128::from(self.disk.size-self.base)+i128::from(n)};
            self.pos=u64::try_from(next).map_err(|_|invalid("negative seek"))?; Ok(self.pos)
        }
    }
    fn disk(dir:&std::path::Path, entries:serde_json::Value)->VirtualFatDisk{
        let path=dir.join("boot.nmfat"); let mut bytes=MAGIC.to_vec(); bytes.extend(serde_json::to_vec(&entries).unwrap());
        std::fs::write(&path,bytes).unwrap(); VirtualFatDisk::try_open(&File::open(path).unwrap()).unwrap().unwrap()
    }
    #[test]
    fn standard_fat_reader_reads_original_files_and_long_names(){
        let dir=tempfile::tempdir().unwrap(); let payload:Vec<_>=(0..15031u32).map(|v|(v%251) as u8).collect();
        let source=dir.path().join("original.dmg"); std::fs::write(&source,&payload).unwrap();
        let media=disk(dir.path(),serde_json::json!({"files":[
            {"path":"com.apple.recovery.boot/BaseSystem.dmg","source":source},
            {"path":"EFI/BOOT/BOOTX64.EFI","source":source}]}));
        let view=View{disk:&media,pos:0,base:PARTITION_LBA*SECTOR};
        let fs=fatfs::FileSystem::new(view,fatfs::FsOptions::new()).unwrap();
        assert_eq!(fs.fat_type(),fatfs::FatType::Fat32);
        let mut read=Vec::new(); fs.root_dir().open_file("com.apple.recovery.boot/BaseSystem.dmg").unwrap().read_to_end(&mut read).unwrap();
        assert_eq!(read,payload);
        let mut boot=Vec::new(); fs.root_dir().open_file("efi/boot/bootx64.efi").unwrap().read_to_end(&mut boot).unwrap();
        assert_eq!(boot,payload); assert_eq!(std::fs::read(source).unwrap(),payload);
    }
    #[test]
    fn rejects_duplicate_paths_traversal_and_out_of_bounds_reads(){
        let dir=tempfile::tempdir().unwrap(); let source=dir.path().join("source"); std::fs::write(&source,b"test").unwrap();
        let media=disk(dir.path(),serde_json::json!({"files":[{"path":"file","source":source}]}));
        assert!(media.read_at(&mut [0u8;512],media.size-1).is_err());
        assert!(media.read_at(&mut [0u8;512],u64::MAX).is_err());
        for paths in [vec!["../evil"],vec!["FILE","file"]] {
            let entries:Vec<_>=paths.iter().map(|p|serde_json::json!({"path":p,"source":source})).collect();
            let path=dir.path().join("bad.nmfat");let mut bytes=MAGIC.to_vec();bytes.extend(serde_json::to_vec(&serde_json::json!({"files":entries})).unwrap());
            std::fs::write(&path,bytes).unwrap();assert!(VirtualFatDisk::try_open(&File::open(path).unwrap()).is_err());
        }
    }
    #[test]
    fn gpt_headers_have_valid_checksums_and_source_is_not_expanded(){
        let dir=tempfile::tempdir().unwrap(); let source=dir.path().join("empty"); std::fs::write(&source,[]).unwrap();
        let media=disk(dir.path(),serde_json::json!({"files":[{"path":"empty","source":source}]}));
        let mut header=[0u8;512];media.read_at(&mut header,512).unwrap();assert_eq!(&header[..8],b"EFI PART");
        let expected=u32::from_le_bytes(header[16..20].try_into().unwrap());header[16..20].fill(0);assert_eq!(crc32(&header[..92]),expected);
        let mut backup=[0u8;512];media.read_at(&mut backup,media.size-512).unwrap();assert_eq!(&backup[..8],b"EFI PART");
        assert_eq!(std::fs::metadata(source).unwrap().len(),0);
    }
}
