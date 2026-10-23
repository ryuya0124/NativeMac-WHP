#pragma once
#include <mach/mach.h>
static constexpr const char *NativeMacVideoBrokerName="io.nativemac.video.broker";
static constexpr mach_msg_id_t NativeMacVideoOpenRequest=0x4e4d5601;
struct NativeMacVideoReply {
    mach_msg_header_t header;
    mach_msg_body_t body;
    mach_msg_port_descriptor_t input,output;
    int status;
};
