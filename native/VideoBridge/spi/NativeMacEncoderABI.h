// Authored ABI declarations measured with an authored encoder on Darwin 25.6.
// Not an Apple SDK header, and not a compatibility promise for other OS builds.
#pragma once
#include <VideoToolbox/VideoToolbox.h>
#include "CMBaseObjectSPI.h"
typedef void *NMEncoderRef;
typedef void *NMEncoderSession;
typedef uintptr_t NMEncoderFrame;
#pragma pack(push,4)
struct NMEncoderClass {
    CMBaseClassVersion version;
    OSStatus (*start)(NMEncoderRef,NMEncoderSession,CMVideoDimensions);
    OSStatus (*encode)(NMEncoderRef,NMEncoderFrame,CVPixelBufferRef,CMTime,CMTime,CFDictionaryRef,VTEncodeInfoFlags*);
    OSStatus (*complete)(NMEncoderRef,CMTime);
    OSStatus (*copySupported)(NMEncoderRef,CFDictionaryRef*);
    void *reserved[12];
};
#pragma pack(pop)
extern "C" {
CMBaseClassID VTVideoEncoderGetClassID(void);
OSStatus VTEncoderSessionSetPixelBufferAttributes(NMEncoderSession,CFDictionaryRef);
OSStatus VTEncoderSessionEmitEncodedFrame(NMEncoderSession,NMEncoderFrame,OSStatus,VTEncodeInfoFlags,CMSampleBufferRef);
OSStatus VTRegisterVideoEncoderWithInfo(FourCharCode,CFDictionaryRef,OSStatus(*)(FourCharCode,CFAllocatorRef,NMEncoderRef*));
}
