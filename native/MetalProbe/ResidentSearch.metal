#include <metal_stdlib>
using namespace metal;
struct Node { device const uint *values; };
kernel void resident_search(device const Node *nodes [[buffer(0)]],
                            device uint *output [[buffer(1)]],
                            constant uint &count [[buffer(2)]],
                            uint i [[thread_position_in_grid]]) {
    uint sum=0;
    for(uint j=0;j<16;j++) {
        device const uint *p=nodes[(i+j)&(count-1)].values;
        sum+=p[(i+j)&255];
    }
    output[i]=sum;
}
